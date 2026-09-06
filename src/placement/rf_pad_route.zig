//! RF paths built from pad launch rays, before any raster search. A path is a
//! straight, the forward intersection of two rays, or two launches joined by
//! one segment. Rotating the parts rotates the construction, including 45°.
const std = @import("std");
const direct = @import("router_direct.zig");
const pad_exit = @import("pad_exit.zig");

const Point = [2]f64;
const eps = 1e-7;
const samples = 16;

const Ray = struct {
    at: Point,
    dir: Point,

    fn from(pt: pad_exit.NetPt) ?Ray {
        const v = pt.rf_out orelse pt.out;
        const len = std.math.hypot(v[0], v[1]);
        if (len < eps) return null;
        return .{ .at = .{ pt.x, pt.y }, .dir = .{ v[0] / len, v[1] / len } };
    }

    fn point(self: Ray, t: f64) Point {
        return .{ self.at[0] + t * self.dir[0], self.at[1] + t * self.dir[1] };
    }
};

fn sub(a: Point, b: Point) Point {
    return .{ a[0] - b[0], a[1] - b[1] };
}

fn dot(a: Point, b: Point) f64 {
    return a[0] * b[0] + a[1] * b[1];
}

fn cross(a: Point, b: Point) f64 {
    return a[0] * b[1] - a[1] * b[0];
}

fn distance(a: Point, b: Point) f64 {
    return std.math.hypot(a[0] - b[0], a[1] - b[1]);
}

fn clear(path: direct.DirectPath, pts: []const Point) bool {
    for (pts[1..], 0..) |b, i| if (!direct.clearDoglegSegment(path, pts[i], b)) return false;
    return true;
}

fn emit(run: direct.DirectRun, layer: u8, pts: []const Point) std.mem.Allocator.Error!void {
    for (pts[1..], 0..) |b, i| try direct.emitDoglegSegment(run.path(layer), pts[i], b, run.tracks);
}

/// Tangent length per unit fillet radius for a turn between two segments.
fn tangent(a: Point, b: Point) ?f64 {
    const len = std.math.hypot(a[0], a[1]) * std.math.hypot(b[0], b[1]);
    if (len < eps) return null;
    const cosine = std.math.clamp(dot(a, b) / len, -1, 1);
    if (cosine < -0.99) return null;
    return @sqrt(@max(0, (1 - cosine) / (1 + cosine)));
}

/// Largest common radius the two turns can share without consuming the pad
/// launches or overlapping on the connecting segment. The clearance oracle
/// and bend smoother still judge the actual fillets afterward.
fn radiusRoom(pts: [4]Point, reserve: f64) f64 {
    const a = sub(pts[1], pts[0]);
    const b = sub(pts[2], pts[1]);
    const c = sub(pts[3], pts[2]);
    // Never construct a backtracking bridge merely to gain turning room.
    if (dot(a, b) < -eps or dot(b, c) < -eps) return 0;
    const ta = tangent(a, b) orelse return 0;
    const tb = tangent(b, c) orelse return 0;
    if (ta + tb < eps) return 0;
    var radius = distance(pts[1], pts[2]) / (ta + tb);
    if (ta > eps) radius = @min(radius, @max(0, distance(pts[0], pts[1]) - reserve) / ta);
    if (tb > eps) radius = @min(radius, @max(0, distance(pts[2], pts[3]) - reserve) / tb);
    return radius;
}

/// Try the simplest ray topology first. For offset rays, prefer the legal
/// bridge that leaves the most common fillet room, then the shortest path.
/// A failed construction emits no copper and leaves obstacle routing intact.
pub fn attempt(run: direct.DirectRun, pts: []const pad_exit.NetPt) std.mem.Allocator.Error!bool {
    if (pts.len != 2 or pts[0].layer != pts[1].layer) return false;
    if (!@import("router_ctx.zig").layerInMask(run.ctx.allowed_layers, pts[0].layer)) return false;
    const a = Ray.from(pts[0]) orelse return false;
    const b = Ray.from(pts[1]) orelse return false;
    const delta = sub(b.at, a.at);
    const span = distance(a.at, b.at);
    if (span < eps) return false;
    const path = run.path(pts[0].layer);
    const straight = @abs(cross(delta, a.dir)) < eps and @abs(cross(delta, b.dir)) < eps;
    if (straight and dot(delta, a.dir) > 0 and dot(delta, b.dir) < 0) {
        const line = [_]Point{ a.at, b.at };
        if (!clear(path, &line)) return false;
        try emit(run, pts[0].layer, &line);
        return true;
    }
    const reserve = if (run.ctx.rf.escape_automatic) run.ctx.params.track_width / 2 else run.ctx.rf.escape_mm;
    const det = cross(a.dir, b.dir);
    if (@abs(det) > eps) {
        const ta = cross(delta, b.dir) / det;
        const tb = cross(delta, a.dir) / det;
        if (ta >= reserve and tb >= reserve) {
            const elbow = [_]Point{ a.at, a.point(ta), b.at };
            if (clear(path, &elbow)) {
                try emit(run, pts[0].layer, &elbow);
                return true;
            }
        }
    }
    const room = span - 2 * reserve;
    if (room <= eps) return false;
    var best: ?[4]Point = null;
    var best_radius: f64 = 0;
    var best_length = std.math.inf(f64);
    for (0..samples + 1) |i| {
        for (0..samples + 1) |j| {
            const candidate = [4]Point{ a.at, a.point(reserve + room * @as(f64, @floatFromInt(i)) / samples), b.point(reserve + room * @as(f64, @floatFromInt(j)) / samples), b.at };
            const radius = radiusRoom(candidate, reserve);
            if (radius < best_radius - eps or radius < eps) continue;
            const length = distance(candidate[0], candidate[1]) + distance(candidate[1], candidate[2]) + distance(candidate[2], candidate[3]);
            if (length > 1.6 * span) continue;
            if (radius <= best_radius + eps and length >= best_length) continue;
            if (!clear(path, &candidate)) continue;
            best = candidate;
            best_radius = radius;
            best_length = length;
        }
    }
    const result = best orelse return false;
    try emit(run, pts[0].layer, &result);
    return true;
}

// spec: placement/router - RF launch rays construct a straight, a forward elbow, a rotated elbow or one offset bridge without raster jogs
test "RF launch rays choose consistent straight elbow and offset topologies" {
    const ctx_mod = @import("router_ctx.zig");
    const tracks_mod = @import("route_result.zig");
    const s = @sqrt(@as(f64, 0.5));
    const cases = [_]struct { a: Point, b: Point, da: Point, db: Point, count: usize }{
        .{ .a = .{ 3, 4 }, .b = .{ 6, 4 }, .da = .{ 1, 0 }, .db = .{ -1, 0 }, .count = 1 },
        .{ .a = .{ 3, 4 }, .b = .{ 6, 1 }, .da = .{ 1, 0 }, .db = .{ 0, 1 }, .count = 2 },
        .{ .a = .{ 3, 4 }, .b = .{ 6, 3 }, .da = .{ s, -s }, .db = .{ -1, 0 }, .count = 2 },
        .{ .a = .{ 3, 4 }, .b = .{ 6, 5 }, .da = .{ 1, 0 }, .db = .{ -1, 0 }, .count = 3 },
    };
    for (cases) |case| {
        var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var ctx = ctx_mod.Ctx{ .arena = arena, .grid = .{ .ox = 0, .oy = 0, .g = 0.1, .nx = 100, .ny = 100 }, .obs = &.{}, .reach = 0.25, .occ = try ctx_mod.allocLayerGrids(arena, 2, 10000), .resv = try ctx_mod.allocLayerGrids(arena, 2, 10000), .params = .{}, .base = .{} };
        var tracks: std.ArrayList(tracks_mod.Track) = .empty;
        var vias: std.ArrayList(tracks_mod.Via) = .empty;
        const run = direct.DirectRun{ .ctx = &ctx, .net = 0, .tracks = &tracks, .vias = &vias };
        const pts = [_]pad_exit.NetPt{
            .{ .x = case.a[0], .y = case.a[1], .layer = 0, .rf_out = case.da },
            .{ .x = case.b[0], .y = case.b[1], .layer = 0, .rf_out = case.db },
        };
        try std.testing.expect(try attempt(run, &pts));
        try std.testing.expectEqual(case.count, tracks.items.len);
        const first = tracks.items[0];
        const last = tracks.items[tracks.items.len - 1];
        const launch = Point{ first.x2 - first.x1, first.y2 - first.y1 };
        const entry = Point{ last.x1 - last.x2, last.y1 - last.y2 };
        try std.testing.expectApproxEqAbs(@as(f64, 0), cross(launch, case.da), eps);
        try std.testing.expectApproxEqAbs(@as(f64, 0), cross(entry, case.db), eps);
        try std.testing.expect(dot(launch, case.da) > 0 and dot(entry, case.db) > 0);
        try std.testing.expectEqual(@as(usize, 0), vias.items.len);
        direct.rollbackDirectRun(run, 0, 0);
        // Every simple shape intersects this foreign wall. Refusing it must
        // leave no prefix behind for the ordinary routing fallback to inherit.
        const wall = [_]@import("pad_grid.zig").PadObs{.{ .x0 = 4.4, .x1 = 4.6, .y0 = 0, .y1 = 10, .net = 1, .thru = true }};
        ctx.obs = &wall;
        try std.testing.expect(!try attempt(run, &pts));
        try std.testing.expectEqual(@as(usize, 0), tracks.items.len);
    }
}
