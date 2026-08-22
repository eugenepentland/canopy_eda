//! JSON surface for the PCB viewer's click-to-inspect power-copper screen.

const std = @import("std");
const optimizer = @import("placement/optimizer.zig");
const router = @import("placement/router.zig");
const power_integrity = @import("placement/power_integrity.zig");
const pdn_impedance = @import("placement/pdn_impedance.zig");
const pour = @import("placement/pour.zig");
const json_writer = @import("json_writer.zig");

/// Emit the model metadata and routed power-copper screen into a page blob.
pub fn write(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: ?router.RouteResult,
    zones: []const pour.UserZone,
    base_edge: ?pour.EdgeField,
) std.Io.Writer.Error!void {
    try w.print(
        ",\"power_integrity\":{{\"model\":\"IPC-2221 continuous-current screen\"," ++
            "\"assumptions\":{{\"temperature_rise_c\":{d},\"via_plating_mm\":{d}," ++
            "\"branch_mode\":\"resistive KCL over traces, vias, and computed fill components with conservative fallback\",\"plane_mode\":\"computed fill connectivity plus enforced-minimum-width capacity proof; no sheet current-density mesh\"}},\"nets\":[",
        .{ power_integrity.temperature_rise_c, placement.rules.physical.via_plating_mm },
    );
    const route = routed orelse {
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
        try writeString(w, net.name);
        try w.print(",\"net_index\":{d},\"source\":", .{net.index});
        try writeString(w, net.demand.source);
        try w.writeAll(",\"source_terminals\":[");
        for (net.demand.source_terminals, 0..) |terminal, terminal_index| {
            if (terminal_index > 0) try w.writeByte(',');
            try writeString(w, terminal);
        }
        try w.writeByte(']');
        try w.writeAll(",\"flow_typical_status\":");
        try writeString(w, net.typical_status.name());
        try w.writeAll(",\"flow_maximum_status\":");
        try writeString(w, net.maximum_status.name());
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
            try writeString(w, plane.kind.name());
            try w.print(
                ",\"physical_layer\":{d},\"foil_mm\":{d},\"component_count\":{d},\"fill_coarsened\":{s}," ++
                    "\"design_min_width_mm\":{d},\"capacity_a_per_mm\":{d},\"capacity_at_design_min_a\":{d},\"required_neck_typical_mm\":",
                .{ plane.physical_layer, plane.foil_mm, plane.component_count, if (plane.fill_coarsened) "true" else "false", plane.design_min_width_mm, plane.capacity_a_per_mm, plane.capacity_at_design_min_a },
            );
            try writeOptionalNumber(w, plane.required_neck_typical_mm);
            try w.writeAll(",\"required_neck_maximum_mm\":");
            try writeOptionalNumber(w, plane.required_neck_maximum_mm);
            try w.writeAll(",\"typical_status\":");
            try writeString(w, plane.typical_status.name());
            try w.writeAll(",\"maximum_status\":");
            try writeString(w, plane.maximum_status.name());
            try w.writeByte('}');
        }
        try w.writeAll("]}");
    }
    try w.writeAll("],\"ac\":");
    try writeAc(w, alloc, placement, route);
    try w.writeByte('}');
}

fn writeAc(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    route: router.RouteResult,
) std.Io.Writer.Error!void {
    try w.writeAll("{\"model\":\"routed lumped RLC / target impedance screen\",\"rails\":[");
    const ac = pdn_impedance.analyze(alloc, placement, route) catch {
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
    try writeString(w, rail.net);
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
    try writeString(w, spice_buf.written());
    try w.writeByte('}');
}

fn writeAcCap(w: *std.Io.Writer, cap: pdn_impedance.Capacitor) std.Io.Writer.Error!void {
    try w.writeAll("{\"ref\":");
    try writeString(w, cap.ref_des);
    try w.writeAll(",\"target_ref\":");
    try writeString(w, cap.target_ref_des);
    try w.writeAll(",\"target_pin\":");
    try writeString(w, cap.target_pin);
    try w.writeAll(",\"value\":");
    try writeString(w, cap.value);
    try w.writeAll(",\"model_source\":");
    try writeString(w, cap.model_source);
    try w.print(",\"capacitance_f\":{d},\"effective_factor\":{d},\"esr_ohm\":{d},\"intrinsic_esl_h\":{d},\"mounting_inductance_h\":{d},\"power_path_mm\":{d},\"ground_path_mm\":{d},\"routed_power_path\":{s},\"model_estimated\":{s},\"mounted_srf_hz\":{d},\"removal_impact_db\":{d},\"ideal_mount_improvement_db\":{d},\"ineffective\":{s}}}", .{
        cap.capacitance_f,
        cap.effective_factor,
        cap.esr_ohm,
        cap.intrinsic_esl_h,
        cap.mounting_inductance_h,
        cap.power_path_mm,
        cap.ground_path_mm,
        if (cap.routed_power_path) "true" else "false",
        if (cap.model_estimated) "true" else "false",
        cap.mounted_srf_hz,
        cap.removal_impact_db,
        cap.ideal_mount_improvement_db,
        if (cap.ineffective) "true" else "false",
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

fn writeString(w: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    json_writer.writeString(w, value) catch |err| switch (err) {
        error.WriteFailed => return error.WriteFailed,
        // `std.Io.Writer` does not allocate, but json_writer's generic error
        // surface also serves allocating writers. Collapse that impossible
        // member here instead of adding a panic to the page path.
        error.OutOfMemory => return error.WriteFailed,
    };
}
