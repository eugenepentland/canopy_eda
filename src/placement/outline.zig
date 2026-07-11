//! Board-outline polygon geometry — the shared shape math behind
//! non-rectangular board outlines (v1: closed straight-segment polygons;
//! arcs are approximated as fine polylines, e.g. the rounded-rect corners
//! `(board … (corner-radius R))` authors).
//!
//! A polygon is a closed vertex list in board mm (`[]const [2]f64`, last
//! vertex implicitly connects back to the first). Every consumer of the
//! exact shape (board-edge DRC, Gerber Edge_Cuts, the PNG renderer, the
//! viewer) reads these helpers; the placement solver itself keeps using the
//! bounding-box rectangle (`bboxRect`) as its `board_rect`, so the polygon
//! never shifts a layout.

const std = @import("std");
const optimizer = @import("optimizer.zig");

/// Even-odd ray-cast point-in-polygon test. Points exactly on an edge may
/// land on either side (callers that care use `signedInset`'s magnitude).
pub fn contains(poly: []const [2]f64, x: f64, y: f64) bool {
    if (poly.len < 3) return false;
    var inside = false;
    var j = poly.len - 1;
    for (poly, 0..) |p, i| {
        const q = poly[j];
        if ((p[1] > y) != (q[1] > y)) {
            const t = (y - p[1]) / (q[1] - p[1]);
            if (x < p[0] + t * (q[0] - p[0])) inside = !inside;
        }
        j = i;
    }
    return inside;
}

/// Minimum distance from (x,y) to the polygon's closed boundary path.
pub fn distToEdge(poly: []const [2]f64, x: f64, y: f64) f64 {
    var best = std.math.inf(f64);
    if (poly.len == 0) return best;
    var j = poly.len - 1;
    for (poly, 0..) |p, i| {
        best = @min(best, segDist(poly[j], p, x, y));
        j = i;
    }
    return best;
}

/// Signed inset of (x,y) from the outline: positive = that far INSIDE the
/// board, negative = that far outside. The polygon twin of the rectangle
/// edge-inset the board-edge DRC historically used.
pub fn signedInset(poly: []const [2]f64, x: f64, y: f64) f64 {
    const d = distToEdge(poly, x, y);
    return if (contains(poly, x, y)) d else -d;
}

/// The polygon's axis-aligned bounding box as a `BoardRect` — the rectangle
/// every bbox consumer (solver, fab `Frame` origin, view framing) derives
/// from, so bbox semantics stay centralized here.
pub fn bboxRect(poly: []const [2]f64) optimizer.BoardRect {
    var minx = std.math.inf(f64);
    var miny = std.math.inf(f64);
    var maxx = -std.math.inf(f64);
    var maxy = -std.math.inf(f64);
    for (poly) |p| {
        minx = @min(minx, p[0]);
        miny = @min(miny, p[1]);
        maxx = @max(maxx, p[0]);
        maxy = @max(maxy, p[1]);
    }
    if (minx > maxx) return .{ .minx = 0, .miny = 0, .w = 0, .h = 0 };
    return .{ .minx = minx, .miny = miny, .w = maxx - minx, .h = maxy - miny };
}

/// First crossing of segment (x1,y1)→(x2,y2) with the polygon boundary, or
/// null when the segment never touches an edge. Lets the board-edge DRC
/// catch a straight track whose endpoints are both inside but whose middle
/// cuts across a concave notch.
pub fn segCrossesEdge(poly: []const [2]f64, x1: f64, y1: f64, x2: f64, y2: f64) ?[2]f64 {
    if (poly.len < 2) return null;
    var j = poly.len - 1;
    for (poly, 0..) |p, i| {
        if (segIntersect(poly[j], p, .{ x1, y1 }, .{ x2, y2 })) |pt| return pt;
        j = i;
    }
    return null;
}

/// Number of polyline segments each rounded-rect corner arc is approximated
/// with (fine enough that the sagitta error stays well under fab tolerance
/// for any sane corner radius).
pub const corner_segs: usize = 8;

/// Build the rounded-rectangle outline polygon for `(board (size W H)
/// (corner-radius R))`: the rectangle `r` with each corner replaced by a
/// quarter-circle arc of `CORNER_SEGS` straight segments. The radius is
/// clamped to half the shorter side (a radius that large degenerates to a
/// stadium/circle-ish shape, never an invalid self-intersection). Vertices
/// are returned in one consistent winding, allocated from `alloc`.
pub fn roundedRectPoly(alloc: std.mem.Allocator, r: optimizer.BoardRect, radius: f64) std.mem.Allocator.Error![]const [2]f64 {
    const rad = @min(@max(radius, 0), @min(r.w, r.h) / 2);
    const pts = try alloc.alloc([2]f64, 4 * (corner_segs + 1));
    // Corner arc centers + start angles, traced TL → TR → BR → BL in the
    // y-down board frame (angles in standard cos/sin form).
    const corners = [4]struct { cx: f64, cy: f64, a0: f64 }{
        .{ .cx = r.minx + rad, .cy = r.miny + rad, .a0 = std.math.pi },
        .{ .cx = r.minx + r.w - rad, .cy = r.miny + rad, .a0 = 1.5 * std.math.pi },
        .{ .cx = r.minx + r.w - rad, .cy = r.miny + r.h - rad, .a0 = 0 },
        .{ .cx = r.minx + rad, .cy = r.miny + r.h - rad, .a0 = 0.5 * std.math.pi },
    };
    var n: usize = 0;
    for (corners) |c| {
        var s: usize = 0;
        while (s <= corner_segs) : (s += 1) {
            const a = c.a0 + (std.math.pi / 2.0) * @as(f64, @floatFromInt(s)) / @as(f64, @floatFromInt(corner_segs));
            pts[n] = .{ c.cx + rad * @cos(a), c.cy + rad * @sin(a) };
            n += 1;
        }
    }
    return pts;
}

/// Distance from point (x,y) to segment a→b.
fn segDist(a: [2]f64, b: [2]f64, x: f64, y: f64) f64 {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len2 = dx * dx + dy * dy;
    var t: f64 = 0;
    if (len2 > 0) t = std.math.clamp(((x - a[0]) * dx + (y - a[1]) * dy) / len2, 0, 1);
    const px = a[0] + t * dx;
    const py = a[1] + t * dy;
    return std.math.hypot(x - px, y - py);
}

/// Proper segment-segment intersection point (touching counts), or null.
fn segIntersect(a: [2]f64, b: [2]f64, c: [2]f64, d: [2]f64) ?[2]f64 {
    const r0 = b[0] - a[0];
    const r1 = b[1] - a[1];
    const s0 = d[0] - c[0];
    const s1 = d[1] - c[1];
    const denom = r0 * s1 - r1 * s0;
    if (@abs(denom) < 1e-12) return null; // parallel/collinear: no single crossing point
    const t = ((c[0] - a[0]) * s1 - (c[1] - a[1]) * s0) / denom;
    const u = ((c[0] - a[0]) * r1 - (c[1] - a[1]) * r0) / denom;
    if (t < 0 or t > 1 or u < 0 or u > 1) return null;
    return .{ a[0] + t * r0, a[1] + t * r1 };
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// L-shaped test board: 10×10 with the top-right 4×6 notch removed
/// (y grows down, so the notch is at large x, large y).
const l_poly = [_][2]f64{
    .{ 0, 0 }, .{ 10, 0 }, .{ 10, 4 }, .{ 6, 4 }, .{ 6, 10 }, .{ 0, 10 },
};

// spec: placement/outline - point-in-polygon and signed inset classify an L-shaped outline's interior, notch, and edges
test "contains and signedInset on an L-shaped outline" {
    try testing.expect(contains(&l_poly, 2, 2)); // main body
    try testing.expect(contains(&l_poly, 8, 2)); // upper arm
    try testing.expect(!contains(&l_poly, 8, 8)); // the notch (inside the bbox!)
    try testing.expect(!contains(&l_poly, -1, 5)); // fully outside

    try testing.expectApproxEqAbs(@as(f64, 2), signedInset(&l_poly, 2, 5), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -2), signedInset(&l_poly, 8, 8), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, -1), signedInset(&l_poly, -1, 5), 1e-9);

    const bb = bboxRect(&l_poly);
    try testing.expectApproxEqAbs(@as(f64, 0), bb.minx, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 10), bb.w, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 10), bb.h, 1e-9);
}

// spec: placement/outline - a segment crossing a concave notch edge reports the crossing point
test "segCrossesEdge catches a track cutting the notch" {
    // Endpoints both inside the bbox; the middle crosses the x=6 notch wall.
    const hit = segCrossesEdge(&l_poly, 2, 8, 9, 8) orelse return error.TestExpectedCrossing;
    try testing.expectApproxEqAbs(@as(f64, 6), hit[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 8), hit[1], 1e-9);
    // A segment comfortably inside never reports a crossing.
    try testing.expect(segCrossesEdge(&l_poly, 1, 1, 4, 1) == null);
}

// spec: placement/outline - rounded-rect generation clamps the radius and keeps corner points inside the rect
test "roundedRectPoly builds the corner-radius outline" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const r = optimizer.BoardRect{ .minx = 0, .miny = 0, .w = 20, .h = 10 };
    const poly = try roundedRectPoly(arena, r, 2);
    try testing.expectEqual(@as(usize, 4 * (corner_segs + 1)), poly.len);
    // The polygon's bbox is exactly the rectangle …
    const bb = bboxRect(poly);
    try testing.expectApproxEqAbs(@as(f64, 0), bb.minx, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 20), bb.w, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 10), bb.h, 1e-9);
    // … the centre is inside, and the sharp rect corner is shaved off.
    try testing.expect(contains(poly, 10, 5));
    try testing.expect(!contains(poly, 0.1, 0.1));
    // An oversized radius clamps to half the short side (no self-intersection).
    const fat = try roundedRectPoly(arena, r, 100);
    const fbb = bboxRect(fat);
    try testing.expectApproxEqAbs(@as(f64, 20), fbb.w, 1e-9);
    try testing.expect(contains(fat, 10, 5));
}
