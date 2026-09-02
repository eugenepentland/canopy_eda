//! JSON surface for the PCB viewer's click-to-inspect trace analysis.

const std = @import("std");
const json_writer = @import("../json_writer.zig");
const optimizer = @import("../placement/optimizer.zig");
const router = @import("../placement/router.zig");
const trace_em = @import("../placement/trace_em.zig");

/// Emit the model metadata and all controlled-net analyses into the page blob.
pub fn write(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: ?router.RouteResult,
) std.Io.Writer.Error!void {
    try w.writeAll(
        ",\"trace_em\":{\"model\":\"2.5D quasi-TEM\",\"method\":\"cascaded stackup-derived transmission-line sections\"," ++
            "\"assumptions\":{\"loss_tangent\":" ++ std.fmt.comptimePrint("{d}", .{trace_em.assumed_loss_tangent}) ++
            ",\"copper_conductivity_s_per_m\":" ++ std.fmt.comptimePrint("{d}", .{trace_em.copper_conductivity_s_per_m}) ++
            ",\"soldermask\":false,\"roughness\":false,\"radiation\":false,\"coupling\":false},\"analyses\":[",
    );
    const route = routed orelse {
        try w.writeAll("]}");
        return;
    };
    var first = true;
    for (placement.nets, 0..) |net, net_index| {
        const analysis = (trace_em.analyzeNet(alloc, placement, route, net_index) catch null) orelse continue;
        if (!first) try w.writeByte(',');
        first = false;
        try w.writeAll("{\"net\":");
        try json_writer.writeScriptString(w, net.name);
        try w.writeAll(",\"class\":");
        try json_writer.writeScriptString(w, if (net_index < placement.rules.net.len) placement.rules.net[net_index].class.name else "");
        try w.writeAll(",\"status\":");
        try json_writer.writeScriptString(w, analysis.status.name());
        try w.writeAll(",\"via_model_valid_to_hz\":");
        if (analysis.via_model.valid_to_hz) |valid_to_hz|
            try w.print("{d}", .{valid_to_hz})
        else
            try w.writeAll("null");
        try w.print(",\"via_model_target_synthesized_antipad\":{}", .{analysis.via_model.target_synthesized_antipad});
        try w.print(",\"via_model_inner_stub_unmodeled\":{}", .{analysis.via_model.inner_stub_unmodeled});
        try w.print(
            ",\"target_ohms\":{d},\"band_start_hz\":{d},\"band_stop_hz\":{d},\"band_assumed\":{}," ++
                "\"ground_gap_mm\":{d},\"ground_gap_max_mm\":{d},\"width_derived\":{},\"return_loss_target_db\":{d}," ++
                "\"via_count\":{d},\"total_length_mm\":{d},\"delay_ps\":{d}," ++
                "\"z0_min_ohms\":{d},\"z0_max_ohms\":{d},\"z0_weighted_ohms\":{d}," ++
                "\"ground_gap_min_mm\":{d},\"ground_gap_used_max_mm\":{d},\"ground_gap_capped_length_mm\":{d}," ++
                "\"worst_return_loss_db\":{d},\"worst_insertion_loss_db\":{d},\"sections\":[",
            .{
                analysis.target.ohms,
                analysis.target.band.start_hz,
                analysis.target.band.stop_hz,
                analysis.target.band.assumed,
                analysis.target.ground_gap_mm,
                analysis.target.ground_gap_max_mm,
                analysis.target.width_derived,
                analysis.target.band.return_loss_db,
                analysis.via_count,
                analysis.summary.total_length_mm,
                analysis.summary.delay_ps,
                analysis.summary.z0.min_ohms,
                analysis.summary.z0.max_ohms,
                analysis.summary.z0.weighted_ohms,
                analysis.summary.ground_gap.min_mm,
                analysis.summary.ground_gap.max_mm,
                analysis.summary.ground_gap.capped_length_mm,
                analysis.summary.worst_return_loss_db,
                analysis.summary.worst_insertion_loss_db,
            },
        );
        for (analysis.sections, 0..) |section, i| {
            if (i > 0) try w.writeByte(',');
            try w.print(
                "{{\"x1\":{d},\"y1\":{d},\"x2\":{d},\"y2\":{d},\"l\":{d},\"physical_layer\":{d}," ++
                    "\"width_mm\":{d},\"length_mm\":{d},\"z0_ohms\":{d},\"er_eff\":{d}," ++
                    "\"ground_gap_mm\":{d},\"gap_capped\":{},\"structure\":",
                .{ section.from[0], section.from[1], section.to[0], section.to[1], section.layers.route, section.layers.physical, section.width_mm, section.length_mm, section.electrical.z0_ohms, section.electrical.er_eff, section.electrical.ground_gap_mm, section.electrical.gap_capped },
            );
            try json_writer.writeScriptString(w, section.electrical.structure);
            try w.writeByte('}');
        }
        try w.writeAll("],\"sweep\":[");
        for (analysis.samples, 0..) |sample, i| {
            if (i > 0) try w.writeByte(',');
            try w.print(
                "{{\"frequency_hz\":{d},\"return_loss_db\":{d},\"insertion_loss_db\":{d}," ++
                    "\"zin_re_ohms\":{d},\"zin_im_ohms\":{d},\"s11_phase_deg\":{d}}}",
                .{ sample.frequency_hz, sample.return_loss_db, sample.insertion_loss_db, sample.zin_re_ohms, sample.zin_im_ohms, sample.s11_phase_deg },
            );
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]}");
}
