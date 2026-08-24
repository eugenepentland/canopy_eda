//! Physical track probes for swept variable-width copper paths.
//!
//! Saved layouts keep a compact constant-width centreline as the editor handle
//! for a taper. Rendering and fabrication use the path's swept polygon; rules
//! that operate on capsules receive a private chord lowering here so those
//! handles never become the physical-width authority.

const std = @import("std");
const router = @import("router.zig");
const rf_port_report = @import("rf_port_report.zig");
const Sample = @import("rf_path_solver.zig").Sample;

const eps: f64 = 1e-9;
const miter_limit: f64 = 2;

fn samePoint(a: [2]f64, b: [2]f64) bool {
    return @abs(a[0] - b[0]) <= 1e-7 and @abs(a[1] - b[1]) <= 1e-7;
}

fn onSegment(point: [2]f64, a: [2]f64, b: [2]f64) bool {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len = std.math.hypot(dx, dy);
    if (len <= 1e-9) return samePoint(point, a);
    const cross = @abs((point[0] - a[0]) * dy - (point[1] - a[1]) * dx) / len;
    const dot = (point[0] - a[0]) * dx + (point[1] - a[1]) * dy;
    return cross <= 1e-7 and dot >= -1e-7 and dot <= len * len + 1e-7;
}

fn ownsSampleSpan(samples: []const Sample, a: [2]f64, b: [2]f64) bool {
    for (samples, 0..) |start, i| {
        if (!samePoint(start.at, a)) continue;
        for (samples[i + 1 ..], i + 1..) |finish, j| {
            if (!samePoint(finish.at, b)) continue;
            var straight = true;
            for (samples[i + 1 .. j]) |middle| {
                if (onSegment(middle.at, a, b)) continue;
                straight = false;
                break;
            }
            if (straight) return true;
        }
    }
    return false;
}

fn unit(v: [2]f64) [2]f64 {
    const len = std.math.hypot(v[0], v[1]);
    return if (len > eps) .{ v[0] / len, v[1] / len } else .{ 1, 0 };
}

fn appendPoint(arena: std.mem.Allocator, points: *std.ArrayList([2]f64), point: [2]f64) std.mem.Allocator.Error!void {
    if (points.items.len > 0 and samePoint(points.items[points.items.len - 1], point)) return;
    try points.append(arena, point);
}

const OffsetInput = struct {
    point: [2]f64,
    before: [2]f64,
    after: [2]f64,
    half: f64,
    endpoint: bool,
};

fn appendOffset(arena: std.mem.Allocator, out: *std.ArrayList([2]f64), in: OffsetInput, side: f64) std.mem.Allocator.Error!void {
    const point = in.point;
    const before = in.before;
    const after = in.after;
    const half = in.half;
    const na = [2]f64{ -before[1] * side, before[0] * side };
    const nb = [2]f64{ -after[1] * side, after[0] * side };
    if (in.endpoint) return appendPoint(arena, out, .{ point[0] + nb[0] * half, point[1] + nb[1] * half });
    var mx = na[0] + nb[0];
    var my = na[1] + nb[1];
    const ml = std.math.hypot(mx, my);
    if (ml > eps) {
        mx /= ml;
        my /= ml;
        const denom = mx * nb[0] + my * nb[1];
        const offset = if (denom > eps) half / denom else std.math.inf(f64);
        if (offset <= half * miter_limit + eps)
            return appendPoint(arena, out, .{ point[0] + mx * offset, point[1] + my * offset });
    }
    try appendPoint(arena, out, .{ point[0] + na[0] * half, point[1] + na[1] * half });
    try appendPoint(arena, out, .{ point[0] + nb[0] * half, point[1] + nb[1] * half });
}

/// Exact filled outline of a sampled variable-width centreline. Ordinary
/// corners use a bounded miter. Reversals and over-limit miters use a bevel,
/// which keeps the polygon local and prevents the inward sliver produced by
/// clamping one synthetic miter point away from both true offset edges.
pub fn outline(arena: std.mem.Allocator, samples: []const Sample) std.mem.Allocator.Error![]const [2]f64 {
    if (samples.len < 2) return &.{};
    var left: std.ArrayList([2]f64) = .empty;
    var right: std.ArrayList([2]f64) = .empty;
    for (samples, 0..) |sample, i| {
        const before = if (i == 0)
            unit(.{ samples[1].at[0] - sample.at[0], samples[1].at[1] - sample.at[1] })
        else
            unit(.{ sample.at[0] - samples[i - 1].at[0], sample.at[1] - samples[i - 1].at[1] });
        const after = if (i + 1 == samples.len)
            before
        else
            unit(.{ samples[i + 1].at[0] - sample.at[0], samples[i + 1].at[1] - sample.at[1] });
        const half = @max(sample.width_mm, eps) / 2;
        const in = OffsetInput{ .point = sample.at, .before = before, .after = after, .half = half, .endpoint = i == 0 or i + 1 == samples.len };
        try appendOffset(arena, &left, in, 1);
        try appendOffset(arena, &right, in, -1);
    }
    var polygon: std.ArrayList([2]f64) = .empty;
    try polygon.appendSlice(arena, left.items);
    var i = right.items.len;
    while (i > 0) {
        i -= 1;
        try appendPoint(arena, &polygon, right.items[i]);
    }
    return polygon.toOwnedSlice(arena);
}

/// Whether `track` is an editor handle or implementation chord belonging to a
/// swept path, without hiding unrelated branches on the same net and layer.
pub fn ownsTrack(paths: []const rf_port_report.Outcome, track: anytype) bool {
    for (paths) |path| {
        if (!path.success or path.physical.gate_removed) continue;
        if (path.net != track.net or path.physical.layer != track.layer) continue;
        const samples = path.physical.samples;
        if (samples.len < 2) continue;
        const a = [2]f64{ track.x1, track.y1 };
        const b = [2]f64{ track.x2, track.y2 };
        if (ownsSampleSpan(samples, a, b) or ownsSampleSpan(samples, b, a)) return true;
    }
    return false;
}

/// Return capsule probes matching the swept path, without exposing them as
/// persisted or editor-visible trace objects.
pub fn tracks(arena: std.mem.Allocator, routed: router.RouteResult) std.mem.Allocator.Error![]const router.Track {
    if (routed.rf_port_outcomes.len == 0) return routed.tracks;
    var out: std.ArrayList(router.Track) = .empty;
    for (routed.tracks) |track| {
        if (!ownsTrack(routed.rf_port_outcomes, track)) try out.append(arena, track);
    }
    for (routed.rf_port_outcomes) |path| {
        if (!path.success or path.physical.gate_removed) continue;
        const samples = path.physical.samples;
        if (samples.len < 2) continue;
        for (samples[1..], 1..) |sample, i| {
            const before = samples[i - 1];
            if (std.math.hypot(sample.at[0] - before.at[0], sample.at[1] - before.at[1]) <= 1e-9) continue;
            try out.append(arena, .{
                .x1 = before.at[0],
                .y1 = before.at[1],
                .x2 = sample.at[0],
                .y2 = sample.at[1],
                .layer = path.physical.layer,
                .width = (before.width_mm + sample.width_mm) / 2,
                .net = path.net,
            });
        }
    }
    return out.toOwnedSlice(arena);
}

// spec: placement/rf-port-frame-routing - a trace taper remains one swept polygon with compact edit handles while DRC lowers private width-profile chords
test "path copper replaces only its compact centreline handle with private profile chords" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const source = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.3, .net = 0 },
        .{ .x1 = 0.5, .y1 = 0, .x2 = 0.5, .y2 = 1, .layer = 0, .width = 0.3, .net = 0 },
    };
    const samples = [_]@import("rf_path_solver.zig").Sample{
        .{ .at = .{ 0, 0 }, .s_mm = 0, .curvature = 0, .width_mm = 0.1 },
        .{ .at = .{ 0.5, 0 }, .s_mm = 0.5, .curvature = 0, .width_mm = 0.2 },
        .{ .at = .{ 1, 0 }, .s_mm = 1, .curvature = 0, .width_mm = 0.3 },
    };
    const paths = [_]rf_port_report.Outcome{.{
        .net = 0,
        .chosen = 0,
        .feasible = true,
        .success = true,
        .metrics = .{},
        .trials = &.{},
        .physical = .{ .sample_count = samples.len, .samples = &samples, .layer = 0 },
    }};
    const got = try tracks(arena, .{ .tracks = &source, .vias = &.{}, .rf_port_outcomes = &paths, .routed = 1, .total = 1 });
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectApproxEqAbs(@as(f64, 0.15), got[1].width, 1e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), got[2].width, 1e-12);
    try std.testing.expectEqual(@as(f64, 1), got[0].y2); // unrelated branch survives
}

test "variable width outline bevels a sharp angled taper without an inward gap" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const samples = [_]Sample{
        .{ .at = .{ 0, 0 }, .s_mm = 0, .curvature = 0, .width_mm = 0.1 },
        .{ .at = .{ 1, 0 }, .s_mm = 1, .curvature = 0, .width_mm = 0.2 },
        .{ .at = .{ 0.2, 0.1 }, .s_mm = 1.81, .curvature = 0, .width_mm = 0.3 },
    };
    const polygon = try outline(arena_state.allocator(), &samples);
    // A near reversal exceeds the 2x miter limit, so each side contributes
    // both true offset-edge points instead of one clamped, detached point.
    try std.testing.expectEqual(@as(usize, 8), polygon.len);
    for (polygon) |point| {
        try std.testing.expect(std.math.isFinite(point[0]));
        try std.testing.expect(std.math.isFinite(point[1]));
    }
}
