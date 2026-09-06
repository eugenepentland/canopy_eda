//! Select whole copper records near a repair site without clearing remote nets.
const std = @import("std");
const sidecar = @import("../layout_sidecar_types.zig");
const outline = @import("outline.zig");

/// Circular repair region in board millimetres.
pub const Window = struct { x: f64, y: f64, radius: f64 };
/// Retained copper and the number of complete records removed.
pub const Result = struct { routes: sidecar.SavedRoutes, dropped: usize };

/// Remove selected tracks touching the disk and vias whose centres lie in it.
/// Tracks/arcs are atomic records: a crossing record is removed in full.
/// Swept RF paths require a whole-net operation and are refused here.
pub fn remove(
    alloc: std.mem.Allocator,
    saved: sidecar.SavedRoutes,
    nets: *const std.StringHashMapUnmanaged(void),
    window: Window,
) (std.mem.Allocator.Error || error{ProtectedRf})!Result {
    for (saved.rf_paths) |path| if (nets.contains(path.net)) return error.ProtectedRf;
    var tracks: std.ArrayList(sidecar.SavedTrack) = .empty;
    var vias: std.ArrayList(sidecar.SavedVia) = .empty;
    var dropped: usize = 0;
    for (saved.tracks) |track| {
        if (nets.contains(track.net) and touches(track, window)) {
            dropped += 1;
        } else try tracks.append(alloc, track);
    }
    for (saved.vias) |via| {
        if (nets.contains(via.net) and std.math.hypot(via.x - window.x, via.y - window.y) <= window.radius) {
            dropped += 1;
        } else try vias.append(alloc, via);
    }
    var routes = saved;
    routes.tracks = tracks.items;
    routes.vias = vias.items;
    return .{ .routes = routes, .dropped = dropped };
}

fn touches(track: sidecar.SavedTrack, window: Window) bool {
    const a: [2]f64 = .{ track.x1, track.y1 };
    const b: [2]f64 = .{ track.x2, track.y2 };
    const distance = if (track.xm != null and track.ym != null)
        arcDistance(a, .{ track.xm.?, track.ym.? }, b, window)
    else
        segmentDistance(a, b, window);
    return distance <= window.radius + track.w / 2;
}

fn segmentDistance(a: [2]f64, b: [2]f64, window: Window) f64 {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const length_sq = dx * dx + dy * dy;
    const t = if (length_sq > 0)
        std.math.clamp(((window.x - a[0]) * dx + (window.y - a[1]) * dy) / length_sq, 0, 1)
    else
        0;
    return std.math.hypot(a[0] + t * dx - window.x, a[1] + t * dy - window.y);
}

fn arcDistance(a: [2]f64, mid: [2]f64, b: [2]f64, window: Window) f64 {
    const circle = outline.arcCircle(.{ .p1 = a, .pm = mid, .p2 = b }) orelse
        return @min(segmentDistance(a, mid, window), segmentDistance(mid, b, window));
    const angle = std.math.atan2(window.y - circle.cy, window.x - circle.cx);
    const travel = @mod(if (circle.sweep >= 0) angle - circle.start_angle else circle.start_angle - angle, 2 * std.math.pi);
    if (travel <= @abs(circle.sweep))
        return @abs(std.math.hypot(window.x - circle.cx, window.y - circle.cy) - circle.radius);
    return @min(std.math.hypot(a[0] - window.x, a[1] - window.y), std.math.hypot(b[0] - window.x, b[1] - window.y));
}

// spec: Web Server - coordinate-scoped clear_routes can remove intersecting selected tracks and vias while preserving distant copper and foreign nets
test "copper window removes attached stubs but retains distant and foreign copper" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var nets: std.StringHashMapUnmanaged(void) = .empty;
    try nets.put(a, "VDD", {});
    const tracks = [_]sidecar.SavedTrack{
        .{ .x1 = -1, .y1 = 0, .x2 = 1, .y2 = 0, .w = 0.2, .net = "VDD" },
        .{ .x1 = -1, .y1 = 2, .x2 = 1, .y2 = 2, .w = 0.2, .net = "VDD", .id = "remote" },
        .{ .x1 = -1, .y1 = 0, .x2 = 1, .y2 = 0, .w = 0.2, .net = "OTHER", .id = "foreign" },
    };
    const vias = [_]sidecar.SavedVia{
        .{ .x = 0, .y = 0, .d = 0.4, .net = "VDD" },
        .{ .x = 0, .y = 2, .d = 0.4, .net = "VDD", .id = "remote-via" },
    };
    const result = try remove(a, .{ .tracks = &tracks, .vias = &vias }, &nets, .{ .x = 0, .y = 0, .radius = 0.1 });
    try std.testing.expectEqual(@as(usize, 2), result.dropped);
    try std.testing.expectEqualDeep(tracks[1..], result.routes.tracks);
    try std.testing.expectEqualDeep(vias[1..], result.routes.vias);
}

// spec: Web Server - coordinate-scoped track clearing tests actual arc copper rather than its chord or a bounding box
test "copper window follows arc sweep and track thickness" {
    const arc = sidecar.SavedTrack{ .x1 = -1, .y1 = 0, .xm = 0, .ym = 1, .x2 = 1, .y2 = 0, .w = 0.2 };
    try std.testing.expect(touches(arc, .{ .x = 0, .y = 1.15, .radius = 0.06 }));
    try std.testing.expect(!touches(arc, .{ .x = 0, .y = 0, .radius = 0.1 }));
    try std.testing.expect(!touches(arc, .{ .x = 0, .y = -1, .radius = 0.1 }));
    var reversed = arc;
    reversed.x1 = arc.x2;
    reversed.x2 = arc.x1;
    try std.testing.expect(touches(reversed, .{ .x = 0, .y = 1.15, .radius = 0.06 }));
    try std.testing.expect(!touches(reversed, .{ .x = 0, .y = -1, .radius = 0.1 }));
    const diagonal = sidecar.SavedTrack{ .x1 = -2, .y1 = -2, .x2 = 2, .y2 = 2, .w = 0.2 };
    try std.testing.expect(!touches(diagonal, .{ .x = -1, .y = 1, .radius = 0.1 }));
}

// spec: Web Server - coordinate-scoped track clearing refuses selected swept RF paths without partial deletion
test "copper window refuses partial swept RF deletion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var nets: std.StringHashMapUnmanaged(void) = .empty;
    try nets.put(a, "RF", {});
    const routes = sidecar.SavedRoutes{ .tracks = &.{}, .vias = &.{}, .rf_paths = &.{.{ .net = "RF", .layer = 0, .samples = &.{} }} };
    try std.testing.expectError(error.ProtectedRf, remove(a, routes, &nets, .{ .x = 0, .y = 0, .radius = 1 }));
}
