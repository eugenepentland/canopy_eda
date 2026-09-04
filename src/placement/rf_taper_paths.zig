//! Recover exact swept copper for straight RF tapers emitted by `pad_neck`.
//!
//! The router keeps ordinary tracks as edit handles.  A width-changing launch
//! is therefore emitted as short, constant-width segments, but drawing those
//! segments as round-ended capsules makes their union bulge past the intended
//! straight taper.  This final-output adapter recognizes only collinear,
//! monotonic width runs on single-ended controlled-impedance nets and records
//! the endpoint widths that describe their exact butt-ended sweep.

const std = @import("std");
const bend_smooth = @import("bend_smooth.zig");
const optimizer = @import("optimizer.zig");
const rf_path_solver = @import("rf_path_solver.zig");
const rf_port_report = @import("rf_port_report.zig");
const router = @import("router.zig");
const variable_width_copper = @import("variable_width_copper.zig");

const eps: f64 = 1e-7;

fn eligible(rule: optimizer.NetRule) bool {
    return rule.rf.impedance.ohms > 0 and rule.rf.impedance.diff_ohms <= 0;
}

fn hasSuccessfulPath(outcomes: []const rf_port_report.Outcome, net: i32) bool {
    for (outcomes) |outcome| {
        if (outcome.net != net or !outcome.success) continue;
        if (!outcome.physical.gate_removed and outcome.physical.samples.len >= 2) return true;
    }
    return false;
}

fn continuesStraight(points: []const [2]f64, vertex: usize) bool {
    const a = points[vertex - 1];
    const b = points[vertex];
    const c = points[vertex + 1];
    const ab = [2]f64{ b[0] - a[0], b[1] - a[1] };
    const bc = [2]f64{ c[0] - b[0], c[1] - b[1] };
    const ab_len = std.math.hypot(ab[0], ab[1]);
    const bc_len = std.math.hypot(bc[0], bc[1]);
    if (ab_len <= eps or bc_len <= eps) return false;
    const cross = @abs(ab[0] * bc[1] - ab[1] * bc[0]);
    const dot = ab[0] * bc[0] + ab[1] * bc[1];
    return cross <= eps * ab_len * bc_len and dot > 0;
}

fn monotonicWidths(widths: []const f64) bool {
    if (widths.len < 2) return false;
    var rising = false;
    var falling = false;
    for (widths[1..], 1..) |width, i| {
        rising = rising or width > widths[i - 1] + eps;
        falling = falling or width < widths[i - 1] - eps;
    }
    return rising != falling;
}

/// The pad-neck slicer assigns each cell the wider of its two true endpoint
/// widths. At a shared boundary the narrower of the adjacent cell widths is
/// therefore the original linear profile value, for both rising and falling
/// tapers.
fn samplesForRun(
    arena: std.mem.Allocator,
    points: []const [2]f64,
    widths: []const f64,
) std.mem.Allocator.Error![]const rf_path_solver.Sample {
    const samples = try arena.alloc(rf_path_solver.Sample, points.len);
    var distance: f64 = 0;
    for (points, 0..) |point, i| {
        if (i > 0) distance += std.math.hypot(point[0] - points[i - 1][0], point[1] - points[i - 1][1]);
        const width = if (i == 0)
            widths[0]
        else if (i == widths.len)
            widths[widths.len - 1]
        else
            @min(widths[i - 1], widths[i]);
        samples[i] = .{ .at = point, .s_mm = distance, .curvature = 0, .width_mm = width };
    }
    return samples;
}

fn appendRun(
    arena: std.mem.Allocator,
    out: *std.ArrayList(rf_port_report.Outcome),
    net: i32,
    layer: u8,
    points: []const [2]f64,
    widths: []const f64,
) std.mem.Allocator.Error!void {
    if (!monotonicWidths(widths)) return;
    const samples = try samplesForRun(arena, points, widths);
    try out.append(arena, .{
        .net = net,
        .chosen = 0,
        .feasible = true,
        .success = true,
        .metrics = .{},
        .trials = &.{},
        .physical = .{
            .sample_count = samples.len,
            .emitted_tracks = widths.len,
            .samples = samples,
            .layer = layer,
        },
    });
}

fn appendChainTapers(
    arena: std.mem.Allocator,
    out: *std.ArrayList(rf_port_report.Outcome),
    net: i32,
    layer: u8,
    chain: bend_smooth.Chain,
) std.mem.Allocator.Error!void {
    if (chain.widths.len < 2 or chain.pts.len != chain.widths.len + 1) return;
    var first_leg: usize = 0;
    var vertex: usize = 1;
    while (vertex < chain.pts.len - 1) : (vertex += 1) {
        if (continuesStraight(chain.pts, vertex)) continue;
        try appendRun(arena, out, net, layer, chain.pts[first_leg .. vertex + 1], chain.widths[first_leg..vertex]);
        first_leg = vertex;
    }
    try appendRun(arena, out, net, layer, chain.pts[first_leg..], chain.widths[first_leg..]);
}

/// Preserve solver results, then add one exact swept path for every straight
/// autorouter taper that had to fall back to pad-neck slices. A successful G2
/// path already carries the authoritative full-net width profile and wins.
pub fn withExactFallbacks(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    tracks: []const router.Track,
    outcomes: []const rf_port_report.Outcome,
) std.mem.Allocator.Error![]const rf_port_report.Outcome {
    var out: std.ArrayList(rf_port_report.Outcome) = .empty;
    try out.appendSlice(arena, outcomes);
    for (0..placement.nets.len) |net_i| {
        if (net_i >= placement.rules.net.len or !eligible(placement.rules.net[net_i])) continue;
        const net: i32 = @intCast(net_i);
        if (hasSuccessfulPath(outcomes, net)) continue;
        var layers: [256]bool = @splat(false);
        for (tracks) |track| {
            if (track.net == net) layers[track.layer] = true;
        }
        for (layers, 0..) |present, layer_i| {
            if (!present) continue;
            var mine: std.ArrayList(router.Track) = .empty;
            for (tracks) |track| {
                if (track.net == net and track.layer == layer_i) try mine.append(arena, track);
            }
            const chains = try bend_smooth.extractChains(arena, mine.items);
            for (chains) |chain| try appendChainTapers(arena, &out, net, @intCast(layer_i), chain);
        }
    }
    return out.toOwnedSlice(arena);
}

// spec: placement/rf-port-frame-routing - autorouter fallback tapers are exported as exact straight-sided swept copper instead of overlapping round-ended slices
test "autorouter fallback taper recovers exact endpoint widths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const points = [_][2]f64{ .{ 0, 0 }, .{ 0.25, 0 }, .{ 0.5, 0 }, .{ 0.75, 0 } };
    const widths = [_]f64{ 1.8, 1.2, 0.6 };
    var outcomes: std.ArrayList(rf_port_report.Outcome) = .empty;
    try appendChainTapers(arena, &outcomes, 7, 0, .{
        .pts = try arena.dupe([2]f64, &points),
        .widths = try arena.dupe(f64, &widths),
    });
    try std.testing.expectEqual(@as(usize, 1), outcomes.items.len);
    const samples = outcomes.items[0].physical.samples;
    try std.testing.expectEqual(@as(f64, 1.8), samples[0].width_mm);
    try std.testing.expectEqual(@as(f64, 1.2), samples[1].width_mm);
    try std.testing.expectEqual(@as(f64, 0.6), samples[2].width_mm);
    try std.testing.expectEqual(@as(f64, 0.6), samples[3].width_mm);
    try std.testing.expectEqual(@as(f64, 0.75), samples[3].s_mm);
    const pieces = try variable_width_copper.pieces(arena, samples);
    try std.testing.expectEqual(@as(usize, 3), pieces.len);
    try std.testing.expectEqual([2]f64{ 0, 0.9 }, pieces[0].poly[0]);
    try std.testing.expectEqual([2]f64{ 0.25, 0.6 }, pieces[0].poly[1]);
}

test "fallback detection excludes width peaks and bends" {
    try std.testing.expect(monotonicWidths(&.{ 1.8, 1.2, 0.6 }));
    try std.testing.expect(monotonicWidths(&.{ 0.2, 0.4, 0.6 }));
    try std.testing.expect(!monotonicWidths(&.{ 0.2, 0.6, 0.2 }));
    try std.testing.expect(continuesStraight(&.{ .{ 0, 0 }, .{ 1, 0 }, .{ 2, 0 } }, 1));
    try std.testing.expect(!continuesStraight(&.{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 } }, 1));
}
