//! Physical track probes for swept variable-width copper paths.
//!
//! Saved layouts keep a compact constant-width centreline as the editor handle
//! for a taper. Rendering and fabrication use the path's swept polygon; rules
//! that operate on capsules receive a private chord lowering here so those
//! handles never become the physical-width authority.

const std = @import("std");
const router = @import("router.zig");
const rf_port_report = @import("rf_port_report.zig");

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

fn ownsSampleSpan(samples: []const @import("rf_path_solver.zig").Sample, a: [2]f64, b: [2]f64) bool {
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
