//! JSON surface for the PCB viewer's click-to-inspect power-copper screen.
//!
//! Every design-derived string here — net names, source terminals, capacitor
//! ref-des/value, the emitted SPICE deck — goes out through
//! `json_writer.writeScriptString`, never the plain `writeString`. `write` is
//! called on two paths: inline into the PCB page's `<script>const PCB=…` blob,
//! and into the `application/json` deferred/`?pdn=1` responses. The script-safe
//! form is what the first path needs, and it is ordinary JSON — a net named
//! like a closing script tag decodes back byte-for-byte for the second — so one
//! writer serves both rather than two rules that can drift apart.

const std = @import("std");
const optimizer = @import("placement/optimizer.zig");
const router = @import("placement/router.zig");
const power_integrity = @import("placement/power_integrity.zig");
const pdn_impedance = @import("placement/pdn_impedance.zig");
const pour = @import("placement/pour.zig");
const json_writer = @import("json_writer.zig");

/// Separate ownership domains for retained JSON facts and large disposable
/// fill rasters.
pub const Allocators = struct {
    output: std.mem.Allocator,
    scratch: std.mem.Allocator,
};

/// Whether the AC impedance sweep rides this payload or is left for a separate
/// `?pdn=1` response.
///
/// The sweep is the most expensive thing in the editor's deferred payload —
/// 6.3 s of 13.5 s on board-a, because `pdn_impedance` rasters every relevant
/// plane and then walks each decoupling loop against it — and the ONLY thing
/// that reads it is the PDN section of the track/via properties inspector.
/// Nothing paints, no chip counts, and no export depends on it, so making the
/// board's visible diagnostics wait behind it was pure cost.
pub const AcMode = enum {
    /// Compute and embed it here (a one-shot or non-deferring render).
    included,
    /// Emit `"ac": null` — the marker the viewer reads as "fetch it yourself".
    deferred,
};

/// The solved board every screen below reads.
pub const Inputs = struct {
    placement: optimizer.Placement,
    routed: ?router.RouteResult,
    zones: []const pour.UserZone,
    base_edge: ?pour.EdgeField,
    /// Whether the AC sweep rides this payload. Ignored by `writeAcResponse`,
    /// which IS the deferred answer.
    ac: AcMode = .included,
};

/// Emit the model metadata and routed power-copper screen into a page blob.
pub fn write(w: *std.Io.Writer, allocators: Allocators, in: Inputs) std.Io.Writer.Error!void {
    const alloc = allocators.output;
    const placement = in.placement;
    const zones = in.zones;
    const base_edge = in.base_edge;
    try w.print(
        ",\"power_integrity\":{{\"model\":\"IPC-2221 continuous-current screen\"," ++
            "\"assumptions\":{{\"temperature_rise_c\":{d},\"via_plating_mm\":{d}," ++
            "\"branch_mode\":\"resistive KCL over traces, vias, and computed fill components with conservative fallback\",\"plane_mode\":\"computed fill connectivity plus enforced-minimum-width capacity proof; no sheet current-density mesh\"}},\"nets\":[",
        .{ power_integrity.temperature_rise_c, placement.rules.physical.via_plating_mm },
    );
    const route = in.routed orelse {
        try w.writeAll("]}");
        return;
    };
    const analysis = power_integrity.analyzeCopper(alloc, placement, route, zones, base_edge) catch {
        try w.writeAll("]}");
        return;
    };
    for (analysis.nets, 0..) |net, ni| {
        if (ni > 0) try w.writeByte(',');
        try w.writeAll("{\"net\":");
        try json_writer.writeScriptString(w, net.name);
        try w.print(",\"net_index\":{d},\"source\":", .{net.index});
        try json_writer.writeScriptString(w, net.demand.source);
        try w.writeAll(",\"source_terminals\":[");
        for (net.demand.source_terminals, 0..) |terminal, terminal_index| {
            if (terminal_index > 0) try w.writeByte(',');
            try json_writer.writeScriptString(w, terminal);
        }
        try w.writeByte(']');
        try w.writeAll(",\"flow_typical_status\":");
        try json_writer.writeScriptString(w, net.flow.typical.status.name());
        try w.writeAll(",\"flow_maximum_status\":");
        try json_writer.writeScriptString(w, net.flow.maximum.status.name());
        try w.writeAll(",\"demand_typical_a\":");
        try writeOptionalNumber(w, net.demand.typical_a);
        try w.writeAll(",\"demand_maximum_a\":");
        try writeOptionalNumber(w, net.demand.maximum_a);
        try w.writeAll(",\"source_typical_a\":");
        try writeOptionalNumber(w, net.demand.source_typical_a);
        try w.writeAll(",\"source_maximum_a\":");
        try writeOptionalNumber(w, net.demand.source_maximum_a);
        try w.writeAll(",\"tracks\":[");
        for (net.tracks, 0..) |track, ti| {
            if (ti > 0) try w.writeByte(',');
            const geometry = route.tracks[track.route_index];
            try w.print(
                "{{\"x1\":{d},\"y1\":{d},\"x2\":{d},\"y2\":{d},\"l\":{d},\"width_mm\":{d}," ++
                    "\"physical_layer\":{d},\"foil_mm\":{d},\"capacity_a\":{d},\"resistance_mohm\":{d}," ++
                    "\"required_width_typical_mm\":",
                .{ geometry.x1, geometry.y1, geometry.x2, geometry.y2, geometry.layer, geometry.width, track.physical_layer, track.foil_mm, track.capacity_a, track.resistance_ohm * 1000.0 },
            );
            try writeOptionalNumber(w, track.required_width_typical_mm);
            try w.writeAll(",\"required_width_maximum_mm\":");
            try writeOptionalNumber(w, track.required_width_maximum_mm);
            try w.writeAll(",\"current_typical_a\":");
            try writeOptionalNumber(w, track.current_typical_a);
            try w.writeAll(",\"current_maximum_a\":");
            try writeOptionalNumber(w, track.current_maximum_a);
            try w.writeAll(",\"drop_typical_v\":");
            try writeOptionalNumber(w, track.drop_typical_v);
            try w.writeAll(",\"drop_maximum_v\":");
            try writeOptionalNumber(w, track.drop_maximum_v);
            try w.writeByte('}');
        }
        try w.writeAll("],\"vias\":[");
        for (net.vias, 0..) |via, vi| {
            if (vi > 0) try w.writeByte(',');
            const geometry = route.vias[via.route_index];
            try w.print(
                "{{\"x\":{d},\"y\":{d},\"diameter_mm\":{d},\"drill_mm\":{d},\"plating_mm\":{d}," ++
                    "\"barrel_area_mm2\":{d},\"capacity_a\":{d},\"resistance_mohm\":{d},\"required_count_typical\":",
                .{ geometry.x, geometry.y, geometry.dia, geometry.drill, via.plating_mm, via.barrel_area_mm2, via.capacity_a, via.resistance_ohm * 1000.0 },
            );
            try writeOptionalInteger(w, via.required_count_typical);
            try w.writeAll(",\"required_count_maximum\":");
            try writeOptionalInteger(w, via.required_count_maximum);
            try w.writeAll(",\"current_typical_a\":");
            try writeOptionalNumber(w, via.current_typical_a);
            try w.writeAll(",\"current_maximum_a\":");
            try writeOptionalNumber(w, via.current_maximum_a);
            try w.writeAll(",\"drop_typical_v\":");
            try writeOptionalNumber(w, via.drop_typical_v);
            try w.writeAll(",\"drop_maximum_v\":");
            try writeOptionalNumber(w, via.drop_maximum_v);
            try w.writeByte('}');
        }
        try w.writeAll("],\"planes\":[");
        for (net.planes, 0..) |plane, pi| {
            if (pi > 0) try w.writeByte(',');
            try w.writeAll("{\"kind\":");
            try json_writer.writeScriptString(w, plane.kind.name());
            try w.print(
                ",\"physical_layer\":{d},\"foil_mm\":{d},\"component_count\":{d},\"fill_coarsened\":{s}," ++
                    "\"design_min_width_mm\":{d},\"capacity_a_per_mm\":{d},\"capacity_at_design_min_a\":{d},\"required_neck_typical_mm\":",
                .{ plane.physical_layer, plane.foil_mm, plane.component_count, if (plane.fill_coarsened) "true" else "false", plane.design_min_width_mm, plane.capacity_a_per_mm, plane.capacity_at_design_min_a },
            );
            try writeOptionalNumber(w, plane.required_neck_typical_mm);
            try w.writeAll(",\"required_neck_maximum_mm\":");
            try writeOptionalNumber(w, plane.required_neck_maximum_mm);
            try w.writeAll(",\"typical_status\":");
            try json_writer.writeScriptString(w, plane.typical_status.name());
            try w.writeAll(",\"maximum_status\":");
            try json_writer.writeScriptString(w, plane.maximum_status.name());
            try w.writeByte('}');
        }
        try w.writeAll("],");
        try writeFlow(w, net.flow);
        try w.writeByte('}');
    }
    try w.writeAll("],\"ac\":");
    // A null here is not "no PDN" — an absent key is. It tells the viewer the
    // sweep exists and is one `?pdn=1` fetch away (see `pcb_board.js`'s
    // `loadPdnSweep`), which is why the unrouted early return above emits
    // neither: there is nothing to fetch for a board with no copper.
    if (in.ac == .deferred) {
        try w.writeAll("null}");
        return;
    }
    try writeAc(w, allocators, placement, route, zones, base_edge);
    try w.writeByte('}');
}

/// The complete `?pdn=1` response: the sweep alone, under the layout rev the
/// viewer checks it against. The `ac` value is the same object `write` embeds
/// when it is not deferred, so a viewer that fetched it drops the value
/// straight into `PCB.power_integrity.ac`.
pub fn writeAcResponse(w: *std.Io.Writer, allocators: Allocators, in: Inputs, rev: i64) std.Io.Writer.Error!void {
    try w.print("{{\"rev\":{d},\"ac\":", .{rev});
    if (in.routed) |route| {
        try writeAc(w, allocators, in.placement, route, in.zones, in.base_edge);
    } else {
        try w.writeAll("null");
    }
    try w.writeByte('}');
}

fn writeAc(
    w: *std.Io.Writer,
    allocators: Allocators,
    placement: optimizer.Placement,
    route: router.RouteResult,
    zones: []const pour.UserZone,
    base_edge: ?pour.EdgeField,
) std.Io.Writer.Error!void {
    const alloc = allocators.output;
    try w.writeAll("{\"model\":\"routed, computed-pour, and via-plane lumped RLC / target impedance screen\",\"rails\":[");
    const ac = pdn_impedance.analyzeCopper(alloc, allocators.scratch, placement, route, zones, base_edge) catch {
        try w.writeAll("]}");
        return;
    };
    for (ac.rails, 0..) |rail, ri| {
        if (ri > 0) try w.writeByte(',');
        try writeAcRail(w, alloc, rail);
    }
    try w.writeAll("]}");
}

fn writeAcRail(w: *std.Io.Writer, alloc: std.mem.Allocator, rail: pdn_impedance.Rail) std.Io.Writer.Error!void {
    try w.writeAll("{\"net\":");
    try json_writer.writeScriptString(w, rail.net);
    try w.print(",\"ripple_v\":{d},\"step_current_a\":", .{rail.ripple_v});
    try writeOptionalNumber(w, rail.step_current_a);
    try w.print(",\"step_assumed\":{s},\"target_ohm\":", .{if (rail.step_assumed) "true" else "false"});
    try writeOptionalNumber(w, rail.target_ohm);
    try w.print(",\"source_resistance_ohm\":{d},\"source_inductance_h\":{d},\"source_assumed\":{s},\"verdict_max_hz\":{d},\"worst_frequency_hz\":{d},\"worst_magnitude_ohm\":{d},\"passes\":", .{
        rail.source_resistance_ohm,
        rail.source_inductance_h,
        if (rail.source_assumed) "true" else "false",
        rail.verdict_max_hz,
        rail.worst_frequency_hz,
        rail.worst_magnitude_ohm,
    });
    if (rail.passes) |pass| try w.writeAll(if (pass) "true" else "false") else try w.writeAll("null");
    var coverage_complete = rail.capacitors.len > 0;
    for (rail.capacitors) |cap| {
        const ground_proven = std.mem.eql(u8, cap.path_kind.ground, "computed-pour") or
            std.mem.eql(u8, cap.path_kind.ground, "computed-via-plane");
        if (std.mem.eql(u8, cap.path_kind.power, "fallback") or !ground_proven) {
            coverage_complete = false;
            break;
        }
    }
    try w.print(",\"path_coverage_complete\":{s},\"path_coverage_reason\":", .{if (coverage_complete) "true" else "false"});
    if (coverage_complete)
        try w.writeAll("null")
    else if (rail.capacitors.len == 0)
        try json_writer.writeScriptString(w, "no bound decoupling capacitors were extracted")
    else
        try json_writer.writeScriptString(w, "one or more capacitor legs use fallback or estimated geometry");
    try w.writeAll(",\"points\":[");
    for (rail.points, 0..) |point, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("[{d},{d},{d}]", .{ point.frequency_hz, point.magnitude_ohm, point.phase_deg });
    }
    try w.writeAll("],\"peaks\":[");
    for (rail.peaks, 0..) |peak, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"frequency_hz\":{d},\"magnitude_ohm\":{d},\"above_target\":{s}}}", .{ peak.frequency_hz, peak.magnitude_ohm, if (peak.above_target) "true" else "false" });
    }
    try w.writeAll("],\"capacitors\":[");
    for (rail.capacitors, 0..) |cap, i| {
        if (i > 0) try w.writeByte(',');
        try writeAcCap(w, cap);
    }
    try w.writeAll("],\"spice\":");
    var spice_buf: std.Io.Writer.Allocating = .init(alloc);
    defer spice_buf.deinit();
    pdn_impedance.writeSpice(&spice_buf.writer, rail) catch return error.WriteFailed;
    try json_writer.writeScriptString(w, spice_buf.written());
    try w.writeByte('}');
}

fn writeAcCap(w: *std.Io.Writer, cap: pdn_impedance.Capacitor) std.Io.Writer.Error!void {
    try w.writeAll("{\"ref\":");
    try json_writer.writeScriptString(w, cap.ref_des);
    try w.writeAll(",\"target_ref\":");
    try json_writer.writeScriptString(w, cap.target_ref_des);
    try w.writeAll(",\"target_pin\":");
    try json_writer.writeScriptString(w, cap.target_pin);
    try w.writeAll(",\"value\":");
    try json_writer.writeScriptString(w, cap.value);
    try w.writeAll(",\"model_source\":");
    try json_writer.writeScriptString(w, cap.model_source);
    try w.writeAll(",\"power_path_kind\":");
    try json_writer.writeScriptString(w, cap.path_kind.power);
    try w.writeAll(",\"ground_path_kind\":");
    try json_writer.writeScriptString(w, cap.path_kind.ground);
    try w.print(",\"capacitance_f\":{d},\"effective_factor\":{d},\"esr_ohm\":{d},\"intrinsic_esl_h\":{d},\"mounting_inductance_h\":{d},\"power_path_mm\":{d},\"ground_path_mm\":{d},\"model_estimated\":{s},\"mounted_srf_hz\":{d},\"removal_impact_db\":{d},\"ideal_mount_improvement_db\":{d},\"ineffective\":{s}}}", .{
        cap.capacitance_f,
        cap.effective_factor,
        cap.esr_ohm,
        cap.intrinsic_esl_h,
        cap.mounting_inductance_h,
        cap.power_path_mm,
        cap.ground_path_mm,
        if (cap.model_estimated) "true" else "false",
        cap.mounted_srf_hz,
        cap.removal_impact_db,
        cap.ideal_mount_improvement_db,
        if (cap.ineffective) "true" else "false",
    });
}

/// Why one rail solved the way it did, under `"flow"`.
///
/// Public because `power_flow_cli.zig` reports the SAME object offline: the
/// script-safe escaping is ordinary JSON, so one writer serves the page blob
/// and the CLI rather than two copies that can drift apart.
///
/// The status words alone never said WHICH consumer a rail failed on, so an
/// `incomplete-load-terminals` verdict was un-actionable from the page. This
/// carries the per-terminal source tally and the per-load resolution beside
/// them: a load with `contacts: 0` was never found on the rail's copper, one
/// with `complete: false` had only some of its pins found, and a resolved load
/// with `placed: false` sits on copper the source cannot reach.
pub fn writeFlow(w: *std.Io.Writer, flow: power_integrity.Flow) std.Io.Writer.Error!void {
    try w.writeAll("\"flow\":{\"typical\":");
    try writeAxisFlow(w, flow.typical);
    try w.writeAll(",\"maximum\":");
    try writeAxisFlow(w, flow.maximum);
    try w.writeAll(",\"sources\":[");
    for (flow.sources, 0..) |source, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"terminal\":");
        try json_writer.writeScriptString(w, source.terminal);
        try w.print(",\"contacts\":{d}}}", .{source.contacts});
    }
    try w.writeAll("],\"loads\":[");
    for (flow.loads, 0..) |load, i| {
        if (i > 0) try w.writeByte(',');
        try writeLoadFlow(w, load);
    }
    try w.print("],\"islands\":{d}}}", .{flow.islands});
}

fn writeAxisFlow(w: *std.Io.Writer, axis: power_integrity.AxisFlow) std.Io.Writer.Error!void {
    try w.writeAll("{\"status\":");
    try json_writer.writeScriptString(w, axis.status.name());
    try w.print(",\"unplaced_a\":{d}}}", .{axis.unplaced_a});
}

fn writeLoadFlow(w: *std.Io.Writer, load: power_integrity.LoadFlow) std.Io.Writer.Error!void {
    try w.writeAll("{\"ref\":");
    try json_writer.writeScriptString(w, load.ref);
    try w.writeAll(",\"net\":");
    try json_writer.writeScriptString(w, load.net);
    try w.writeAll(",\"pins\":[");
    for (load.pins, 0..) |pin, i| {
        if (i > 0) try w.writeByte(',');
        try json_writer.writeScriptString(w, pin);
    }
    try w.writeAll("],\"i_typ\":");
    try writeOptionalNumber(w, load.draw.typical_a);
    try w.writeAll(",\"i_max\":");
    try writeOptionalNumber(w, load.draw.maximum_a);
    try w.print(",\"contacts\":{d},\"complete\":{s},\"placed\":{{\"typical\":{s},\"maximum\":{s}}}}}", .{
        load.contacts,
        if (load.complete) "true" else "false",
        if (load.placed.typical) "true" else "false",
        if (load.placed.maximum) "true" else "false",
    });
}

fn writeOptionalNumber(w: *std.Io.Writer, value: ?f64) std.Io.Writer.Error!void {
    if (value) |number| return w.print("{d}", .{number});
    return w.writeAll("null");
}

fn writeOptionalInteger(w: *std.Io.Writer, value: ?usize) std.Io.Writer.Error!void {
    if (value) |number| return w.print("{d}", .{number});
    return w.writeAll("null");
}

test "PDN capacitor JSON serializes finite computed-pour provenance for both legs" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeAcCap(&out.writer, .{
        .ref_des = "C1",
        .target_ref_des = "U1",
        .target_pin = "1",
        .value = "100nF",
        .model_source = "fixture",
        .capacitance_f = 100e-9,
        .effective_factor = 1,
        .esr_ohm = 0.02,
        .intrinsic_esl_h = 0.4e-9,
        .mounting_inductance_h = 0.8e-9,
        .power_path_mm = 1.2,
        .ground_path_mm = 1.4,
        .path_kind = .{ .power = "computed-pour", .ground = "computed-pour" },
        .model_estimated = false,
        .mounted_srf_hz = 10e6,
    });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"power_path_kind\":\"computed-pour\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"ground_path_kind\":\"computed-pour\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"mounting_inductance_h\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "\"mounting_inductance_h\":0,") == null);
}

// spec: Web Server - Power-integrity net and terminal names in the PCB blob are escaped for the script element, so neither can close the tag
test "power-integrity JSON escapes a closing script tag in every design-derived string" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    // `write` embeds this payload inline in the PCB page's `<script>const PCB=`
    // blob, so a capacitor ref-des or value spelling a tag break would close it
    // for every viewer of the board.
    const evil = "</script><script>alert(1)</script>";
    var out: std.Io.Writer.Allocating = .init(alloc);
    try writeAcCap(&out.writer, .{
        .ref_des = evil,
        .target_ref_des = evil,
        .target_pin = evil,
        .value = evil,
        .model_source = evil,
        .capacitance_f = 100e-9,
        .effective_factor = 1,
        .esr_ohm = 0.02,
        .intrinsic_esl_h = 0.4e-9,
        .mounting_inductance_h = 0.8e-9,
        .power_path_mm = 1.2,
        .ground_path_mm = 1.4,
        .path_kind = .{ .power = "computed-pour", .ground = "computed-pour" },
        .model_estimated = false,
        .mounted_srf_hz = 10e6,
    });
    const json = out.written();

    // Nothing an HTML parser reads as a tag survives…
    try std.testing.expect(std.mem.indexOf(u8, json, "</script>") == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, json, '<') == null);
    try std.testing.expectEqual(
        @as(usize, 5),
        std.mem.count(u8, json, "\\u003c/script>\\u003cscript>alert(1)\\u003c/script>"),
    );

    // …and the escape is ordinary JSON, so this module's OTHER consumer — the
    // `application/json` deferred and `?pdn=1` responses — reads the exact
    // strings back. That is why one writer serves both paths.
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, json, .{});
    try std.testing.expectEqualStrings(evil, parsed.object.get("ref").?.string);
    try std.testing.expectEqualStrings(evil, parsed.object.get("value").?.string);
    try std.testing.expectEqualStrings(evil, parsed.object.get("target_pin").?.string);

    // Every string in this module goes out through the script-safe writer. The
    // needle is split so this assertion is not its own counterexample.
    const source = @embedFile("power_integrity_json.zig");
    const unsafe_sink = "json_writer." ++ "writeString(";
    try std.testing.expect(std.mem.indexOf(u8, source, unsafe_sink) == null);
}

// spec: Web Server - Each power net in the PCB blob carries a "flow" object naming its per-axis status, unplaced current, per-terminal source contacts and per-load resolution
test "the power-integrity flow object pins the per-load diagnosis keys" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var out: std.Io.Writer.Allocating = .init(alloc);
    // `writeFlow` emits the KEY and its object, exactly as `write` splices it
    // into a net; the braces here are the enclosing net object.
    try out.writer.writeByte('{');
    try writeFlow(&out.writer, .{
        .typical = .{ .status = .incomplete_load_terminals, .unplaced_a = 0.25 },
        .maximum = .{ .status = .solved_partial, .unplaced_a = 0.5 },
        .sources = &.{ .{ .terminal = "reg/VOUT", .contacts = 2 }, .{ .terminal = "missing/VOUT", .contacts = 0 } },
        .loads = &.{.{
            .ref = "mcu/U1",
            .net = "V3P3",
            .pins = &.{ "12", "34" },
            .draw = .{ .typical_a = 0.1, .maximum_a = 0.2 },
            .contacts = 0,
            .complete = false,
            .placed = .{},
        }},
    });
    try out.writer.writeByte('}');

    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, alloc, out.written(), .{});
    const flow = parsed.object.get("flow").?.object;
    try std.testing.expectEqualStrings("incomplete-load-terminals", flow.get("typical").?.object.get("status").?.string);
    try std.testing.expectEqual(@as(f64, 0.25), flow.get("typical").?.object.get("unplaced_a").?.float);
    try std.testing.expectEqualStrings("solved-partial", flow.get("maximum").?.object.get("status").?.string);

    // The terminal that resolved to no pad IS the `no-source-terminal` answer,
    // so its zero has to survive to the page.
    const sources = flow.get("sources").?.array;
    try std.testing.expectEqual(@as(usize, 2), sources.items.len);
    try std.testing.expectEqual(@as(i64, 0), sources.items[1].object.get("contacts").?.integer);

    const load = flow.get("loads").?.array.items[0].object;
    try std.testing.expectEqualStrings("mcu/U1", load.get("ref").?.string);
    try std.testing.expectEqualStrings("V3P3", load.get("net").?.string);
    try std.testing.expectEqualStrings("34", load.get("pins").?.array.items[1].string);
    try std.testing.expectEqual(@as(f64, 0.1), load.get("i_typ").?.float);
    try std.testing.expectEqual(@as(f64, 0.2), load.get("i_max").?.float);
    try std.testing.expectEqual(@as(i64, 0), load.get("contacts").?.integer);
    try std.testing.expectEqual(false, load.get("complete").?.bool);
    try std.testing.expectEqual(false, load.get("placed").?.object.get("typical").?.bool);
    try std.testing.expectEqual(false, load.get("placed").?.object.get("maximum").?.bool);

    // A rail that solved reports no unplaced current and a placed load.
    var clean: std.Io.Writer.Allocating = .init(alloc);
    try writeFlow(&clean.writer, .{
        .typical = .{ .status = .solved },
        .maximum = .{ .status = .solved },
        .loads = &.{.{
            .ref = "U1",
            .net = "V3P3",
            .pins = &.{"1"},
            .draw = .{ .typical_a = 0.1, .maximum_a = 0.1 },
            .contacts = 1,
            .complete = true,
            .placed = .{ .typical = true, .maximum = true },
        }},
    });
    try std.testing.expect(std.mem.indexOf(u8, clean.written(), "\"unplaced_a\":0") != null);
    try std.testing.expect(std.mem.indexOf(u8, clean.written(), "\"placed\":{\"typical\":true,\"maximum\":true}") != null);
}
