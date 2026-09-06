//! `netlisp power-flow` — why each power rail solved the way it did.
//!
//! The DRC says `power_width_envelope … incomplete-load-terminals` and stops.
//! That names the verdict and hides the evidence: WHICH consumer of the rail
//! failed to resolve, and whether it failed because none of its pins are on
//! this net, because its pad was not found, or because the copper it sits on
//! never reaches the source. Answering that used to mean adding a printf to
//! `power_integrity.zig` and rebuilding. This is that answer, kept.
//!
//!   netlisp power-flow [--project-dir <d>] [--layout <name>] [--net <name>]
//!                      [--text] <design>
//!
//! It is READ-ONLY: it evaluates the design, restores the saved layout exactly
//! as the PCB page does, and writes to stdout. It writes no file and starts no
//! server.
//!
//! JSON is the default because the interesting question ("which load has zero
//! contacts?") is a filter, not a read:
//!
//!   netlisp power-flow --project-dir projects/designs board-a-base \
//!     | jq '.rails[] | select(.flow.typical.status != "solved")
//!           | {net, loads: [.flow.loads[] | select(.contacts == 0) | .ref]}'
//!
//! `--text` prints the same facts as an aligned table for a human.
//!
//! Every number here comes from the SAME two entry points the DRC and the PCB
//! page use — `power_integrity.analyzeCopper` for the per-rail diagnosis and
//! `power_integrity.routedPowerRequirementsMemoZones` for the per-conductor
//! required-versus-actual — so a rail this command calls solved is a rail the
//! board's own screens call solved.

const std = @import("std");
const infra_fs = @import("infra/fs.zig");
const json_writer = @import("json_writer.zig");
const modules_mod = @import("serve/modules.zig");
const pcb_layout_page = @import("serve/pcb_layout_page.zig");
const power_integrity = @import("placement/power_integrity.zig");
const power_integrity_json = @import("power_integrity_json.zig");
const router = @import("placement/router.zig");
const Evaluator = @import("eval/evaluator.zig").Evaluator;

/// Every writer in this file can allocate (the JSON string escaper does), so
/// they share `json_writer`'s error set rather than the narrower writer one.
const WriteError = json_writer.WriteError;

pub const FlowError = std.mem.Allocator.Error || std.Io.Writer.Error || error{ PowerFlowUsage, UnresolvedBoard };

/// Parsed `power-flow` invocation.
pub const Args = struct {
    project_dir: []const u8 = "projects/designs",
    /// Saved layout to restore; null shows the design's starred (★) layout,
    /// which is what the PCB page and the DRC see.
    layout: ?[]const u8 = null,
    /// Report only this rail (exact or leaf-suffix match); null reports all.
    net: ?[]const u8 = null,
    /// Human table instead of JSON.
    text: bool = false,
    name: []const u8 = "",
};

fn parseArgs(args: []const []const u8) FlowError!Args {
    var out: Args = .{};
    var named = false;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (std.mem.eql(u8, a, "--project-dir") and i + 1 < args.len) {
            i += 1;
            out.project_dir = args[i];
        } else if (std.mem.eql(u8, a, "--layout") and i + 1 < args.len) {
            i += 1;
            out.layout = args[i];
        } else if (std.mem.eql(u8, a, "--net") and i + 1 < args.len) {
            i += 1;
            out.net = args[i];
        } else if (std.mem.eql(u8, a, "--text")) {
            out.text = true;
        } else if (std.mem.startsWith(u8, a, "--")) {
            return error.PowerFlowUsage;
        } else if (named) {
            // One board per run: the output is one document, and a second
            // positional is far more likely a typo'd flag than a request.
            return error.PowerFlowUsage;
        } else {
            out.name = a;
            named = true;
        }
    }
    if (!named) return error.PowerFlowUsage;
    return out;
}

/// Run `netlisp power-flow`.
pub fn cmdPowerFlow(allocator: std.mem.Allocator, argv: []const []const u8) FlowError!void {
    const parsed = try parseArgs(argv);
    var buf: [64 * 1024]u8 = undefined;
    var fw = std.Io.File.stdout().writer(infra_fs.currentIo(), &buf);
    try run(allocator, &fw.interface, parsed);
}

fn run(allocator: std.mem.Allocator, w: *std.Io.Writer, args: Args) FlowError!void {
    var board_state = std.heap.ArenaAllocator.init(allocator);
    defer board_state.deinit();
    const alloc = board_state.allocator();

    var eval = Evaluator.init(alloc, args.project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    const solved = pcb_layout_page.solveForRequest(
        alloc,
        args.project_dir,
        args.name,
        .{ .layout = args.layout },
        &eval,
        &module_res,
    ) catch {
        try w.print("# {s} UNRESOLVED\n", .{args.name});
        try w.flush();
        return error.UnresolvedBoard;
    };
    const routed = solved.restored.routes orelse router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 };
    const zones = solved.shown_zones.user;
    const analysis = try power_integrity.analyzeCopper(alloc, solved.placement, routed, zones, null);
    const required = try power_integrity.routedPowerRequirementsMemoZones(alloc, solved.placement, routed, null, zones);

    const report: Report = .{ .args = args, .routed = routed, .analysis = analysis, .required = required };
    if (args.text) try writeText(w, report) else try writeReportJson(w, report);
    try w.flush();
}

/// One board's answer, in the terms both renderers read.
const Report = struct {
    args: Args,
    routed: router.RouteResult,
    analysis: power_integrity.Analysis,
    required: power_integrity.PowerRequirements,
};

/// Does this rail pass the `--net` filter? An exact match or a leaf match, the
/// same latitude `power_integrity` itself gives a hierarchical rail name.
fn selected(args: Args, net: []const u8) bool {
    const want = args.net orelse return true;
    if (std.ascii.eqlIgnoreCase(want, net)) return true;
    return std.mem.endsWith(u8, net, want) and net.len > want.len and net[net.len - want.len - 1] == '/';
}

// ── JSON ────────────────────────────────────────────────────────────────────

fn writeReportJson(w: *std.Io.Writer, report: Report) WriteError!void {
    try w.writeAll("{\"design\":");
    try json_writer.writeString(w, report.args.name);
    try w.writeAll(",\"layout\":");
    if (report.args.layout) |layout| try json_writer.writeString(w, layout) else try w.writeAll("null");
    try w.print(",\"tracks\":{d},\"vias\":{d},\"rails\":[", .{ report.routed.tracks.len, report.routed.vias.len });
    var first = true;
    for (report.analysis.nets) |net| {
        if (!selected(report.args, net.name)) continue;
        if (!first) try w.writeByte(',');
        first = false;
        try writeRailJson(w, report, net);
    }
    try w.writeAll("],\"voltage_budgets\":[");
    first = true;
    for (report.required.voltage) |v| {
        if (!voltageSelected(report, v.net)) continue;
        if (!first) try w.writeByte(',');
        first = false;
        try w.print("{{\"net_index\":{d},\"limit_v\":{d},\"copper_temperature_c\":{d},\"supply_drop_v\":", .{ v.net, v.budget.limit_v, v.budget.copper_temperature_c });
        try writeOptionalNumber(w, v.supply_drop_v);
        try w.writeAll(",\"return_drop_v\":");
        try writeOptionalNumber(w, v.return_drop_v);
        try w.writeAll(",\"load\":");
        try json_writer.writeString(w, v.load);
        try w.writeAll(",\"reason\":");
        try json_writer.writeString(w, v.reason);
        try w.print(",\"exceeded\":{s}}}", .{boolWord(v.exceeded())});
    }
    try w.writeAll("]}\n");
}

fn voltageSelected(report: Report, index: usize) bool {
    if (report.args.net == null) return true;
    for (report.analysis.nets) |net| {
        if (net.index == index) return selected(report.args, net.name);
    }
    return false;
}

fn writeRailJson(w: *std.Io.Writer, report: Report, net: power_integrity.Net) WriteError!void {
    try w.writeAll("{\"net\":");
    try json_writer.writeString(w, net.name);
    try w.print(",\"net_index\":{d},\"source\":", .{net.index});
    try json_writer.writeString(w, net.demand.source);
    try w.writeAll(",\"demand_typical_a\":");
    try writeOptionalNumber(w, net.demand.typical_a);
    try w.writeAll(",\"demand_maximum_a\":");
    try writeOptionalNumber(w, net.demand.maximum_a);
    // `writeFlow` emits the key too, so this is only the separator.
    try w.writeByte(',');
    try power_integrity_json.writeFlow(w, net.flow);
    try w.writeAll(",\"tracks\":[");
    for (net.tracks, 0..) |track, i| {
        if (i > 0) try w.writeByte(',');
        const geometry = report.routed.tracks[track.route_index];
        try w.print("{{\"route_index\":{d},\"layer\":{d},\"width_mm\":{d},\"capacity_a\":{d},\"current_typical_a\":", .{
            track.route_index, geometry.layer, geometry.width, track.capacity_a,
        });
        try writeOptionalNumber(w, track.current_typical_a);
        try w.writeAll(",\"current_maximum_a\":");
        try writeOptionalNumber(w, track.current_maximum_a);
        try w.writeAll(",\"required\":");
        try writeRequiredWidthJson(w, requiredWidth(report, track.route_index));
        try w.writeByte('}');
    }
    try w.writeAll("],\"vias\":[");
    for (net.vias, 0..) |via, i| {
        if (i > 0) try w.writeByte(',');
        try w.print("{{\"route_index\":{d},\"capacity_a\":{d},\"current_typical_a\":", .{ via.route_index, via.capacity_a });
        try writeOptionalNumber(w, via.current_typical_a);
        try w.writeAll(",\"current_maximum_a\":");
        try writeOptionalNumber(w, via.current_maximum_a);
        try w.writeAll(",\"required\":");
        try writeRequiredViaJson(w, requiredVia(report, via.route_index));
        try w.writeByte('}');
    }
    try w.writeAll("]}");
}

fn writeRequiredWidthJson(w: *std.Io.Writer, want: ?power_integrity.LocalWidth) WriteError!void {
    const width = want orelse return w.writeAll("null");
    try w.print("{{\"width_mm\":{d},\"envelope\":{s},\"reason\":", .{ width.width_mm, boolWord(width.envelope) });
    try json_writer.writeString(w, width.reason);
    try w.writeByte('}');
}

fn writeRequiredViaJson(w: *std.Io.Writer, want: ?power_integrity.ViaCurrent) WriteError!void {
    const via = want orelse return w.writeAll("null");
    try w.print("{{\"current_a\":{d},\"capacity_a\":{d},\"barrels\":{d},\"envelope\":{s},\"reason\":", .{
        via.current_a, via.capacity_a, via.requiredCount(), boolWord(via.envelope),
    });
    try json_writer.writeString(w, via.reason);
    try w.writeByte('}');
}

fn writeOptionalNumber(w: *std.Io.Writer, value: ?f64) WriteError!void {
    if (value) |number| return w.print("{d}", .{number});
    return w.writeAll("null");
}

fn boolWord(value: bool) []const u8 {
    return if (value) "true" else "false";
}

fn requiredWidth(report: Report, route_index: usize) ?power_integrity.LocalWidth {
    if (route_index >= report.required.tracks.len) return null;
    return report.required.tracks[route_index];
}

fn requiredVia(report: Report, route_index: usize) ?power_integrity.ViaCurrent {
    if (route_index >= report.required.vias.len) return null;
    return report.required.vias[route_index];
}

// ── Text ────────────────────────────────────────────────────────────────────

fn writeText(w: *std.Io.Writer, report: Report) WriteError!void {
    try w.print("# {s} tracks={d} vias={d}\n", .{ report.args.name, report.routed.tracks.len, report.routed.vias.len });
    for (report.analysis.nets) |net| {
        if (!selected(report.args, net.name)) continue;
        try w.print("\n{s}  typical={s} maximum={s}\n", .{
            net.name, net.flow.typical.status.name(), net.flow.maximum.status.name(),
        });
        try w.writeAll("  demand typ=");
        try writeAmps(w, net.demand.typical_a);
        try w.writeAll(" max=");
        try writeAmps(w, net.demand.maximum_a);
        try w.print("  source=\"{s}\"  unplaced typ={d:.4}A max={d:.4}A\n", .{
            net.demand.source, net.flow.typical.unplaced_a, net.flow.maximum.unplaced_a,
        });
        if (net.flow.islands > 0) {
            try w.print("  copper islands under the canonical contact policy: {d}\n", .{net.flow.islands});
        }
        for (net.flow.sources) |source| {
            try w.print("  source-terminal {s} contacts={d}{s}\n", .{
                source.terminal, source.contacts, if (source.contacts == 0) "   <-- resolved to no pad" else "",
            });
        }
        for (net.flow.loads) |load| try writeLoadText(w, load);
        for (report.required.voltage) |v| {
            if (v.net != net.index) continue;
            try w.print("  voltage {s}: modeled {d:.3} mV / {d:.3} mV budget at {d} C — {s}{s}\n", .{
                v.load,                                 v.knownDrop() * 1000,                                             v.budget.limit_v * 1000, v.budget.copper_temperature_c,
                if (v.exceeded()) "EXCEEDED; " else "", if (v.reason.len > 0) v.reason else "supply and return verified",
            });
        }
        try writeConductorsText(w, report, net);
    }
}

fn writeLoadText(w: *std.Io.Writer, load: power_integrity.LoadFlow) WriteError!void {
    try w.print("  load {s} net={s} pins=", .{ load.ref, load.net });
    if (load.pins.len == 0) try w.writeAll("-");
    for (load.pins, 0..) |pin, i| try w.print("{s}{s}", .{ if (i > 0) "," else "", pin });
    try w.writeAll(" typ=");
    try writeAmps(w, load.draw.typical_a);
    try w.writeAll(" max=");
    try writeAmps(w, load.draw.maximum_a);
    try w.print(" contacts={d} complete={s} placed={s}/{s}{s}\n", .{
        load.contacts,
        boolWord(load.complete),
        boolWord(load.placed.typical),
        boolWord(load.placed.maximum),
        unresolvedNote(load),
    });
}

/// The one-line diagnosis a reader is actually after: which of the three ways
/// a load fails to resolve this one took.
fn unresolvedNote(load: power_integrity.LoadFlow) []const u8 {
    if (load.contacts == 0) return "   <-- no pad of this load is on the rail's copper";
    if (!load.complete) return "   <-- only some of its declared pins resolved to pads";
    if (!load.placed.typical or !load.placed.maximum) return "   <-- resolved, but the source never reaches it";
    return "";
}

fn writeConductorsText(w: *std.Io.Writer, report: Report, net: power_integrity.Net) WriteError!void {
    for (net.tracks) |track| {
        const want = requiredWidth(report, track.route_index) orelse continue;
        const geometry = report.routed.tracks[track.route_index];
        if (geometry.width + 1e-9 >= want.width_mm) continue;
        try w.print("  track #{d} l={d} width={d:.3}mm required={d:.3}mm envelope={s} reason={s}\n", .{
            track.route_index, geometry.layer, geometry.width, want.width_mm, boolWord(want.envelope), want.reason,
        });
    }
    for (net.vias) |via| {
        const want = requiredVia(report, via.route_index) orelse continue;
        if (want.current_a <= want.capacity_a + 1e-9) continue;
        try w.print("  via #{d} current={d:.4}A capacity={d:.4}A barrels={d} envelope={s} reason={s}\n", .{
            via.route_index, want.current_a, want.capacity_a, want.requiredCount(), boolWord(want.envelope), want.reason,
        });
    }
}

fn writeAmps(w: *std.Io.Writer, value: ?f64) WriteError!void {
    if (value) |amps| return w.print("{d:.4}A", .{amps});
    return w.writeAll("-");
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: power-flow - the CLI parses the project dir, the saved layout, the rail filter and the text-output flag with one positional design name
test "power-flow CLI parses flags and one positional" {
    const parsed = try parseArgs(&.{ "--project-dir", "p", "--layout", "star", "--net", "V_3V3D", "--text", "board-a-base" });
    try testing.expectEqualStrings("p", parsed.project_dir);
    try testing.expectEqualStrings("star", parsed.layout.?);
    try testing.expectEqualStrings("V_3V3D", parsed.net.?);
    try testing.expect(parsed.text);
    try testing.expectEqualStrings("board-a-base", parsed.name);

    // JSON is the default, and the default project dir is the served library.
    const bare = try parseArgs(&.{"board-a"});
    try testing.expect(!bare.text);
    try testing.expect(bare.net == null);
    try testing.expectEqualStrings("projects/designs", bare.project_dir);

    // A run with no design named, an unknown flag, or a second positional is a
    // usage error rather than a silently empty or wrong-board report.
    try testing.expectError(error.PowerFlowUsage, parseArgs(&.{"--text"}));
    try testing.expectError(error.PowerFlowUsage, parseArgs(&.{ "--nets", "V", "b" }));
    try testing.expectError(error.PowerFlowUsage, parseArgs(&.{ "a", "b" }));
}

// spec: power-flow - the rail filter matches a rail by its exact name or by its hierarchical leaf, and never by a bare substring
test "the rail filter matches an exact name and a hierarchy leaf" {
    const filter = Args{ .net = "V_3V3D", .name = "b" };
    try testing.expect(selected(filter, "V_3V3D"));
    try testing.expect(selected(filter, "v_3v3d"));
    try testing.expect(selected(filter, "mcu/V_3V3D"));
    try testing.expect(!selected(filter, "V_3V3D_SENSE"));
    try testing.expect(!selected(filter, "V_5V0"));
    // No filter reports every rail.
    try testing.expect(selected(.{ .name = "b" }, "anything"));
}

// spec: power-flow - a board that fails to solve reports UNRESOLVED and fails the command rather than printing an empty report
test "an unresolvable board fails the command instead of printing an empty report" {
    var out = std.Io.Writer.Allocating.init(testing.allocator);
    defer out.deinit();
    const args = try parseArgs(&.{ "--project-dir", "/nonexistent-netlisp-project", "no-such-board" });
    try testing.expectError(error.UnresolvedBoard, run(testing.allocator, &out.writer, args));
    try testing.expect(std.mem.indexOf(u8, out.written(), "# no-such-board UNRESOLVED") != null);
}

// spec: power-flow - an unresolved load is annotated with which of the three resolution failures it hit
test "each load resolution failure gets its own explanation" {
    try testing.expect(std.mem.indexOf(u8, unresolvedNote(.{
        .ref = "U1",
        .net = "V",
        .pins = &.{},
        .draw = .{},
        .contacts = 0,
        .complete = false,
        .placed = .{},
    }), "no pad") != null);
    try testing.expect(std.mem.indexOf(u8, unresolvedNote(.{
        .ref = "U1",
        .net = "V",
        .pins = &.{},
        .draw = .{},
        .contacts = 2,
        .complete = false,
        .placed = .{},
    }), "only some") != null);
    try testing.expect(std.mem.indexOf(u8, unresolvedNote(.{
        .ref = "U1",
        .net = "V",
        .pins = &.{},
        .draw = .{},
        .contacts = 2,
        .complete = true,
        .placed = .{},
    }), "never reaches") != null);
    try testing.expectEqualStrings("", unresolvedNote(.{
        .ref = "U1",
        .net = "V",
        .pins = &.{},
        .draw = .{},
        .contacts = 2,
        .complete = true,
        .placed = .{ .typical = true, .maximum = true },
    }));
}
