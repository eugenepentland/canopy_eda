const std = @import("std");

/// A two-dimensional point in board millimetres.
pub const Point = struct { x: f64, y: f64 };
pub const max_wire_points: usize = 64;

/// Euclidean minimum spanning tree (Prim's) over `points`, appending its edges
/// as segments. An MST is planar, so the crossing metric counts only inter-net
/// tangles that placement can control.
pub fn primEdges(arena: std.mem.Allocator, points: []const [2]f64, out: *std.ArrayList([4]f64)) std.mem.Allocator.Error!void {
    const in_tree = try arena.alloc(bool, points.len);
    @memset(in_tree, false);
    in_tree[0] = true;
    var added: usize = 1;
    while (added < points.len) : (added += 1) {
        var best_i: usize = 0;
        var best_j: usize = 0;
        var best_dist: f64 = std.math.inf(f64);
        for (points, 0..) |a, i| {
            if (!in_tree[i]) continue;
            for (points, 0..) |b, j| {
                if (in_tree[j]) continue;
                const dx = a[0] - b[0];
                const dy = a[1] - b[1];
                const dist = dx * dx + dy * dy;
                if (dist < best_dist) {
                    best_dist = dist;
                    best_i = i;
                    best_j = j;
                }
            }
        }
        in_tree[best_j] = true;
        try out.append(arena, .{ points[best_i][0], points[best_i][1], points[best_j][0], points[best_j][1] });
    }
}

/// Interior crossing of segments a1→a2 and b1→b2. A shared endpoint (two
/// airwires meeting at the same pad) is not a crossing.
pub fn segmentsCross(a1: [2]f64, a2: [2]f64, b1: [2]f64, b2: [2]f64) bool {
    if (pointEqual(a1, b1) or pointEqual(a1, b2) or pointEqual(a2, b1) or pointEqual(a2, b2)) return false;
    const d1 = orient(b1, b2, a1);
    const d2 = orient(b1, b2, a2);
    const d3 = orient(a1, a2, b1);
    const d4 = orient(a1, a2, b2);
    const opposite_1 = (d1 > 0 and d2 < 0) or (d1 < 0 and d2 > 0);
    const opposite_2 = (d3 > 0 and d4 < 0) or (d3 < 0 and d4 > 0);
    return opposite_1 and opposite_2;
}

fn orient(p: [2]f64, q: [2]f64, r: [2]f64) f64 {
    return (q[0] - p[0]) * (r[1] - p[1]) - (q[1] - p[1]) * (r[0] - p[0]);
}

fn pointEqual(p: [2]f64, q: [2]f64) bool {
    return @abs(p[0] - q[0]) < 1e-6 and @abs(p[1] - q[1]) < 1e-6;
}

/// Rectilinear minimum spanning tree length (Prim, Manhattan metric). RMST is
/// a tighter placement proxy than HPWL for nets with four or more pins.
pub fn rectilinearMstLength(points: []const Point) f64 {
    var in_tree: [max_wire_points]bool = @splat(false);
    var best: [max_wire_points]f64 = undefined;
    in_tree[0] = true;
    for (1..points.len) |i| best[i] = manhattan(points[0], points[i]);
    var total: f64 = 0;
    var added: usize = 1;
    while (added < points.len) : (added += 1) {
        var best_j: usize = 0;
        var best_dist: f64 = std.math.inf(f64);
        for (1..points.len) |j| {
            if (!in_tree[j] and best[j] < best_dist) {
                best_dist = best[j];
                best_j = j;
            }
        }
        in_tree[best_j] = true;
        total += best_dist;
        for (1..points.len) |k| {
            if (!in_tree[k]) best[k] = @min(best[k], manhattan(points[best_j], points[k]));
        }
    }
    return total;
}

fn manhattan(a: Point, b: Point) f64 {
    return @abs(a.x - b.x) + @abs(a.y - b.y);
}

test "segsCross flags interior crossings and ignores shared endpoints" {
    try std.testing.expect(segmentsCross(.{ 0, 0 }, .{ 1, 1 }, .{ 0, 1 }, .{ 1, 0 }));
    try std.testing.expect(!segmentsCross(.{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 }));
    try std.testing.expect(!segmentsCross(.{ 0, 0 }, .{ 1, 1 }, .{ 0, 0 }, .{ 1, -1 }));
    try std.testing.expect(!segmentsCross(.{ 0, 0 }, .{ 1, 0 }, .{ 5, 5 }, .{ 6, 6 }));
}

// spec: placement/optimizer - multi-pin wirelength uses the rectilinear MST, which equals span when collinear and exceeds HPWL otherwise
test "rectilinearMstLength is exact on collinear pins and tighter than HPWL for a square" {
    const line = [_]Point{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 2, .y = 0 }, .{ .x = 3, .y = 0 } };
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), rectilinearMstLength(&line), 1e-12);
    const square = [_]Point{ .{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }, .{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 } };
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), rectilinearMstLength(&square), 1e-12);
    try std.testing.expect(rectilinearMstLength(&square) > 2.0);
}
