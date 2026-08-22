//! Final-board integration for the two-port G2 RF solver.

const std = @import("std");
const router = @import("router.zig");
const bend_smooth = @import("bend_smooth.zig");
const rf_path_solver = @import("rf_path_solver.zig");
const rf_port_frames = @import("rf_port_frames.zig");
const rf_port_report = @import("rf_port_report.zig");
const route_cleanup = @import("route_cleanup.zig");

// Give a fine-pitch IC land a little more run before the 50-ohm body reaches
// full width. One trace-width was 0.0015 mm inside the adjacent BGS12P2L6 pad's
// clearance after chord emission; 1.2 widths clears it without lengthening the
// straight entry or changing the nominal transmission-line geometry.
const pad_taper_widths = 1.2;

const FinalProbe = struct {
    taut: router.TautProbe,
    layer: u8,

    /// Test the complete-width candidate chord against live board obstacles.
    pub fn clear(self: FinalProbe, a: [2]f64, b: [2]f64, width: f64) bool {
        return self.taut.clearWidth(self.layer, a, b, width);
    }
};

/// Replace eligible point-to-point controlled-impedance nets with the best
/// feasible G2 port-frame chain. Failure is conservative: the existing copper
/// remains untouched and DRC continues to report its bend/entry defects.
pub fn passBoard(board: router.CleanupBoard) std.mem.Allocator.Error!void {
    for (0..board.placement.nets.len) |net_i| {
        if (!board.enabled(net_i) or net_i >= board.placement.rules.net.len) continue;
        const rule = board.placement.rules.net[net_i];
        if (!eligible(rule)) continue;
        const ni: i32 = @intCast(net_i);
        var mine: std.ArrayList(router.Track) = .empty;
        var layer: ?u8 = null;
        var single_layer = true;
        for (board.tracks.items) |track| {
            if (track.net != ni) continue;
            try mine.append(board.arena(), track);
            if (layer) |seen| single_layer = single_layer and seen == track.layer else layer = track.layer;
        }
        if (!single_layer or hasVia(board.vias.items, ni)) continue;
        const guide: ?[]const [2]f64 = if (mine.items.len > 0)
            longestGuide(try bend_smooth.extractChains(board.arena(), mine.items))
        else
            null;
        board.beginNet(net_i);
        const frames = rf_port_frames.forNet(
            board.placement,
            net_i,
            if (guide) |g| g[0] else .{ 0, 0 },
            if (guide) |g| g[g.len - 1] else .{ 0, 0 },
            board.trackWidth(),
            rule.rf.impedance.ohms,
        ) orelse continue;
        if (layer) |existing_layer| if (existing_layer != frames.layer) continue;
        var direct_guide: [2][2]f64 = undefined;
        const solve_guide = effectiveGuide(guide, frames, &direct_guide);
        const taut = board.tautProbe(ni);
        const probe = FinalProbe{ .taut = taut, .layer = frames.layer };
        const solved = try rf_path_solver.solve(board.arena(), .{
            .start = frames.start,
            .end = frames.end,
            .guide = solve_guide,
            .geometry = .{
                .width_mm = board.trackWidth(),
                .min_radius_ratio = if (rule.rf.min_bend_ratio > 0) rule.rf.min_bend_ratio else bend_smooth.radius_width_ratio,
                .min_entry_mm = @max(board.trackWidth(), rule.rf.escape_mm),
                .start_entry_mm = padEntry(frames.start_section.length_mm, board.trackWidth()),
                .end_entry_mm = padEntry(frames.end_section.length_mm, board.trackWidth()),
                .start_width_mm = frames.start_width_mm,
                .end_width_mm = frames.end_width_mm,
                .taper_mm = board.trackWidth() * pad_taper_widths,
            },
            .electrical = .{
                .target_z_ohm = rule.rf.impedance.ohms,
                .effective_er = effectiveEr(board),
                .band_start_hz = rule.rf.electrical.band_start_hz,
                .band_end_hz = rule.rf.max_freq_hz,
                .return_loss_target_db = rule.rf.electrical.return_loss_target_db,
                .start_section = frames.start_section,
                .end_section = frames.end_section,
            },
        }, &probe);
        var outcome = rf_port_report.fromResult(ni, solved);
        outcome.physical.layer = frames.layer;
        if (solved.success and solved.samples.len >= 2) {
            route_cleanup.removeNetTracks(board.tracks, ni);
            const before = board.tracks.items.len;
            try emit(board, solved.samples, frames.layer, ni);
            outcome.physical.emitted_tracks = board.tracks.items.len - before;
            board.clearLegacySmooth(ni);
        }
        try board.recordRfOutcome(ni, outcome);
    }
}

fn effectiveGuide(legacy: ?[]const [2]f64, frames: rf_port_frames.Pair, fallback: *[2][2]f64) []const [2]f64 {
    if (legacy) |guide| return guide;
    fallback.* = .{ frames.start.at, frames.end.at };
    return fallback;
}

fn padEntry(section_mm: f64, track_width_mm: f64) f64 {
    return section_mm + track_width_mm;
}

fn longestGuide(chains: []const bend_smooth.Chain) ?[]const [2]f64 {
    var best: ?[]const [2]f64 = null;
    var best_length: f64 = -1;
    for (chains) |chain| {
        if (chain.pts.len < 2) continue;
        var length: f64 = 0;
        for (chain.pts[1..], 1..) |point, i| length += std.math.hypot(point[0] - chain.pts[i - 1][0], point[1] - chain.pts[i - 1][1]);
        if (length > best_length) {
            best_length = length;
            best = chain.pts;
        }
    }
    return best;
}

fn eligible(rule: @import("optimizer.zig").NetRule) bool {
    return rule.rf.max_freq_hz > 0 and rule.rf.impedance.ohms > 0 and rule.rf.impedance.diff_ohms <= 0;
}

fn hasVia(vias: []const router.Via, net: i32) bool {
    for (vias) |via| if (via.net == net) return true;
    return false;
}

fn emit(board: router.CleanupBoard, samples: []const rf_path_solver.Sample, layer: u8, net: i32) !void {
    for (samples[1..], 1..) |sample, i| {
        const before = samples[i - 1];
        if (std.math.hypot(sample.at[0] - before.at[0], sample.at[1] - before.at[1]) <= 1e-7) continue;
        try board.tracks.append(board.arena(), .{
            .x1 = before.at[0],
            .y1 = before.at[1],
            .x2 = sample.at[0],
            .y2 = sample.at[1],
            .layer = layer,
            .width = (before.width_mm + sample.width_mm) / 2,
            .net = net,
        });
    }
}

fn effectiveEr(board: router.CleanupBoard) f64 {
    const dielectrics = board.placement.rules.physical.stack.dielectrics;
    if (dielectrics.len == 0 or dielectrics[0].er <= 1) return 3.6;
    return (dielectrics[0].er + 1) / 2 + (dielectrics[0].er - 1) / 4;
}

// spec: placement/rf-port-frame-routing - an unrouted point-to-point RF net falls back to its exact port-frame chord instead of waiting for a legacy maze guide
test "missing legacy guide uses exact RF port-frame endpoints" {
    const frames = rf_port_frames.Pair{
        .start = .{ .at = .{ 1.25, 2.5 }, .tangent = .{ 1, 0 } },
        .end = .{ .at = .{ 8.75, 6.5 }, .tangent = .{ 0, 1 } },
        .layer = 0,
        .start_section = .{},
        .end_section = .{},
        .start_width_mm = 0.2,
        .end_width_mm = 0.2,
    };
    var fallback: [2][2]f64 = undefined;
    const guide = effectiveGuide(null, frames, &fallback);
    try std.testing.expectEqual([2]f64{ 1.25, 2.5 }, guide[0]);
    try std.testing.expectEqual([2]f64{ 8.75, 6.5 }, guide[1]);
}

// spec: placement/rf-port-frame-routing - a cramped switch launch fits against one trace-width of straight entry even when its pad taper is longer
test "short switch launch does not charge the longer pad taper to its fit budget" {
    const width = 0.321470608;
    const section = 0.2;
    try std.testing.expectApproxEqAbs(section + width, padEntry(section, width), 1e-12);
    try std.testing.expect(padEntry(section, width) < section + width * pad_taper_widths);
}
