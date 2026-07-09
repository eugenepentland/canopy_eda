//! Pad collision shapes for routing + DRC. A pad is either a simple axis-aligned
//! rectangle (its bounding box) or, for a KiCad *custom* pad, its real copper
//! outline (`poly`). The router's clearance checks and the DRC verifier both
//! measure distance through this module, so what the router avoids is exactly
//! what the DRC checks — and now against the true outline, not an oversized
//! bounding box that swallows a neighbouring pad's escape corridor (a concave
//! thermal/EP pad leaves a notch where a fine-pitch signal pad sits; the box
//! buries it, the outline frees it).
//!
//! The maze pass keeps rasterising the bounding box (conservative: it just
//! routes around a little more copper than strictly needed), so only the
//! clearance *checks* consult the outline.

const std = @import("std");
const optimizer = @import("optimizer.zig");
const geometry = @import("geometry.zig");

/// A pad's world-space collision shape: its bounding box (always) plus, for a
/// custom pad, the real copper outline in world mm (`poly`; empty ⇒ the box is
/// exact). The box is the broad phase; the outline is the exact phase.
pub const Shape = struct {
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
    poly: []const [2]f64 = &.{},
};

/// Outline-simplification tolerance (mm). KiCad emits a custom pad's rounded
/// corners as ~100-200 fine arc points; collapsing them to within this distance
/// leaves ~10 corner points (concavities preserved), which is well under the
/// clearance rule yet keeps the per-pad distance maths cheap.
const SIMPLIFY_TOL_MM: f64 = 0.03;

/// World collision shape of `pad` on `part`, honouring the part's pose. A custom
/// pad carries its outline transformed into world space and simplified (box from
/// the full outline's bounds); a simple pad carries just the rotated bounding box.
pub fn worldShape(arena: std.mem.Allocator, part: optimizer.Part, pad: geometry.Pad) std.mem.Allocator.Error!Shape {
    if (pad.poly.len >= 3) {
        const wp = try arena.alloc([2]f64, pad.poly.len);
        var x0: f64 = std.math.inf(f64);
        var y0: f64 = std.math.inf(f64);
        var x1: f64 = -std.math.inf(f64);
        var y1: f64 = -std.math.inf(f64);
        for (pad.poly, 0..) |v, i| {
            const w = optimizer.worldPadCenter(part, v[0], v[1]);
            wp[i] = w;
            x0 = @min(x0, w[0]);
            y0 = @min(y0, w[1]);
            x1 = @max(x1, w[0]);
            y1 = @max(y1, w[1]);
        }
        return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1, .poly = try simplifyRing(arena, wp, SIMPLIFY_TOL_MM) };
    }
    const c = optimizer.worldPadCenter(part, pad.x, pad.y);
    // Total pad orientation = part pose + the pad's own `(pos … ROT)`. A
    // quarter turn keeps the exact axis-aligned box (byte-identical to the old
    // path); an arbitrary angle uses the conservative bbox of the rotated
    // rectangle (`|hw·cosθ|+|hh·sinθ|` etc.) — enough for a pass/fail DRC.
    const tot = part.rot + pad.rot;
    const q = @mod(@round(tot), 360);
    if (@abs(tot - @round(tot / 90) * 90) < 1e-6) {
        const swap = q == 90 or q == 270;
        const hw = if (swap) pad.h / 2 else pad.w / 2;
        const hh = if (swap) pad.w / 2 else pad.h / 2;
        return .{ .x0 = c[0] - hw, .y0 = c[1] - hh, .x1 = c[0] + hw, .y1 = c[1] + hh, .poly = &.{} };
    }
    const a = tot * std.math.pi / 180.0;
    const ca = @abs(@cos(a));
    const sa = @abs(@sin(a));
    const hw = (pad.w / 2) * ca + (pad.h / 2) * sa;
    const hh = (pad.w / 2) * sa + (pad.h / 2) * ca;
    return .{ .x0 = c[0] - hw, .y0 = c[1] - hh, .x1 = c[0] + hw, .y1 = c[1] + hh, .poly = &.{} };
}

/// Douglas–Peucker simplification of the closed ring `pts` to within `tol` mm:
/// keep the endpoints, then recursively keep the farthest point from the current
/// chord while it exceeds `tol`. Collapses dense arc points to a handful of real
/// corners (sharp corners and concavities deviate far more than `tol`, so they
/// survive), so the clearance maths run on ~10 points instead of ~200.
fn simplifyRing(arena: std.mem.Allocator, pts: []const [2]f64, tol: f64) std.mem.Allocator.Error![]const [2]f64 {
    if (pts.len < 5) return pts;
    const keep = try arena.alloc(bool, pts.len);
    @memset(keep, false);
    keep[0] = true;
    keep[pts.len - 1] = true;
    var stack: std.ArrayListUnmanaged([2]usize) = .empty;
    try stack.append(arena, .{ 0, pts.len - 1 });
    while (stack.items.len > 0) {
        const seg = stack.items[stack.items.len - 1];
        stack.items.len -= 1;
        const lo = seg[0];
        const hi = seg[1];
        if (hi <= lo + 1) continue;
        var best: usize = lo;
        var bestd: f64 = 0;
        var i: usize = lo + 1;
        while (i < hi) : (i += 1) {
            const d = segPointDist(pts[lo][0], pts[lo][1], pts[hi][0], pts[hi][1], pts[i][0], pts[i][1]);
            if (d > bestd) {
                bestd = d;
                best = i;
            }
        }
        if (bestd > tol) {
            keep[best] = true;
            try stack.append(arena, .{ lo, best });
            try stack.append(arena, .{ best, hi });
        }
    }
    var out: std.ArrayListUnmanaged([2]f64) = .empty;
    for (pts, 0..) |p, i| if (keep[i]) try out.append(arena, p);
    return out.toOwnedSlice(arena);
}

/// Distance from point (px,py) to a pad's copper: 0 when inside, else the gap to
/// the nearest edge. A custom pad measures against its real outline (the box
/// over-states the copper not just in the notches but along every recessed edge,
/// so a point just outside the box can still be well clear of the actual copper)
/// — but only once the box itself is within `slack`, since a point farther than
/// `slack` from the box is farther than `slack` from the copper too. `slack` is
/// the caller's clearance threshold (it only cares whether the gap is below it),
/// which keeps the exact O(outline) work off the far-apart majority of pairs. A
/// simple pad's box is its copper, so the box distance is always exact.
pub fn pointDist(x0: f64, y0: f64, x1: f64, y1: f64, poly: []const [2]f64, px: f64, py: f64, slack: f64) f64 {
    const dx = @max(@max(x0 - px, px - x1), 0);
    const dy = @max(@max(y0 - py, py - y1), 0);
    const bd = @sqrt(dx * dx + dy * dy);
    if (poly.len < 3 or bd >= slack) return bd;
    if (pointInPoly(poly, px, py)) return 0;
    return distPointPolyEdges(poly, px, py);
}

/// Edge-to-edge gap between two pad shapes (0 when they overlap). Both-rect uses
/// the cheap box gap; otherwise, once the boxes are within `slack` (so a real
/// gap below `slack` is even possible), the exact polygon gap is computed —
/// boxes farther apart than `slack` can't violate a `slack` rule, so the box gap
/// (a lower bound) is returned without touching the outlines.
pub fn shapeGap(a: Shape, b: Shape, slack: f64) f64 {
    const gx = @max(@max(a.x0 - b.x1, b.x0 - a.x1), 0);
    const gy = @max(@max(a.y0 - b.y1, b.y0 - a.y1), 0);
    const bgap = @sqrt(gx * gx + gy * gy);
    if ((a.poly.len < 3 and b.poly.len < 3) or bgap >= slack) return bgap;

    var abuf: [4][2]f64 = .{ .{ a.x0, a.y0 }, .{ a.x1, a.y0 }, .{ a.x1, a.y1 }, .{ a.x0, a.y1 } };
    var bbuf: [4][2]f64 = .{ .{ b.x0, b.y0 }, .{ b.x1, b.y0 }, .{ b.x1, b.y1 }, .{ b.x0, b.y1 } };
    const av: []const [2]f64 = if (a.poly.len >= 3) a.poly else abuf[0..];
    const bv: []const [2]f64 = if (b.poly.len >= 3) b.poly else bbuf[0..];

    // Overlap (gap 0) when a vertex of one shape lies inside the other.
    for (av) |v| if (pointInShape(b, v[0], v[1])) return 0;
    for (bv) |v| if (pointInShape(a, v[0], v[1])) return 0;

    // Otherwise the closest approach over every edge pair (segSegDist is 0 on a
    // crossing, so interlocking-but-vertex-outside shapes still read as touching).
    var m: f64 = std.math.inf(f64);
    var ja: usize = av.len - 1;
    for (av, 0..) |va, ia| {
        var jb: usize = bv.len - 1;
        for (bv, 0..) |vb, ib| {
            m = @min(m, segSegDist(av[ja], va, bv[jb], vb));
            jb = ib;
        }
        ja = ia;
    }
    return m;
}

/// True if (px,py) is inside the shape: inside the outline when one is present,
/// else inside the bounding box.
fn pointInShape(s: Shape, px: f64, py: f64) bool {
    if (s.poly.len >= 3) return pointInPoly(s.poly, px, py);
    return px >= s.x0 and px <= s.x1 and py >= s.y0 and py <= s.y1;
}

/// Even-odd ray cast: true if (px,py) is inside the closed polygon `poly`.
fn pointInPoly(poly: []const [2]f64, px: f64, py: f64) bool {
    var inside = false;
    var j: usize = poly.len - 1;
    for (poly, 0..) |vi, i| {
        const yi = vi[1];
        const yj = poly[j][1];
        if ((yi > py) != (yj > py)) {
            const xcross = vi[0] + (py - yi) / (yj - yi) * (poly[j][0] - vi[0]);
            if (px < xcross) inside = !inside;
        }
        j = i;
    }
    return inside;
}

/// Distance from (px,py) to the nearest edge of `poly`.
fn distPointPolyEdges(poly: []const [2]f64, px: f64, py: f64) f64 {
    var m: f64 = std.math.inf(f64);
    var j: usize = poly.len - 1;
    for (poly, 0..) |vi, i| {
        m = @min(m, segPointDist(poly[j][0], poly[j][1], vi[0], vi[1], px, py));
        j = i;
    }
    return m;
}

/// Shortest distance from point (px,py) to segment (ax,ay)→(bx,by).
fn segPointDist(ax: f64, ay: f64, bx: f64, by: f64, px: f64, py: f64) f64 {
    const dx = bx - ax;
    const dy = by - ay;
    const len2 = dx * dx + dy * dy;
    if (len2 < 1e-12) return std.math.hypot(px - ax, py - ay);
    const t = std.math.clamp(((px - ax) * dx + (py - ay) * dy) / len2, 0, 1);
    return std.math.hypot(px - (ax + t * dx), py - (ay + t * dy));
}

/// Shortest distance between segments a1→a2 and b1→b2 (0 when they cross).
fn segSegDist(a1: [2]f64, a2: [2]f64, b1: [2]f64, b2: [2]f64) f64 {
    if (segsIntersect(a1, a2, b1, b2)) return 0;
    return @min(
        @min(segPointDist(a1[0], a1[1], a2[0], a2[1], b1[0], b1[1]), segPointDist(a1[0], a1[1], a2[0], a2[1], b2[0], b2[1])),
        @min(segPointDist(b1[0], b1[1], b2[0], b2[1], a1[0], a1[1]), segPointDist(b1[0], b1[1], b2[0], b2[1], a2[0], a2[1])),
    );
}

fn orient(a: [2]f64, b: [2]f64, c: [2]f64) f64 {
    return (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]);
}

/// True if collinear point `p` lies within the bounding box of segment a→b.
fn onSeg(a: [2]f64, b: [2]f64, p: [2]f64) bool {
    return @min(a[0], b[0]) <= p[0] and p[0] <= @max(a[0], b[0]) and
        @min(a[1], b[1]) <= p[1] and p[1] <= @max(a[1], b[1]);
}

/// True when `a` and `b` have strictly opposite signs (a proper straddle).
fn opposite(a: f64, b: f64) bool {
    return (a > 0 and b < 0) or (a < 0 and b > 0);
}

/// Standard orientation test for whether segments p1→p2 and p3→p4 intersect.
fn segsIntersect(p1: [2]f64, p2: [2]f64, p3: [2]f64, p4: [2]f64) bool {
    const d1 = orient(p3, p4, p1);
    const d2 = orient(p3, p4, p2);
    const d3 = orient(p1, p2, p3);
    const d4 = orient(p1, p2, p4);
    if (opposite(d1, d2) and opposite(d3, d4)) return true;
    if (d1 == 0 and onSeg(p3, p4, p1)) return true;
    if (d2 == 0 and onSeg(p3, p4, p2)) return true;
    if (d3 == 0 and onSeg(p1, p2, p3)) return true;
    if (d4 == 0 and onSeg(p1, p2, p4)) return true;
    return false;
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

// An L pad: a top bar (y∈[2,3]) plus a right prong (x∈[2,3]), leaving a notch in
// the bottom-left (x∈[0,2], y∈[0,2]) — the shape of a thermal pad relieved around
// a corner pin. Bounding box is the full [0,3]x[0,3] square.
const L_POLY = [_][2]f64{
    .{ 0, 2 }, .{ 2, 2 }, .{ 2, 0 }, .{ 3, 0 }, .{ 3, 3 }, .{ 0, 3 }, .{ 0, 2 },
};

// spec: placement/pad_shape - a concave pad's notch reads as clear copper, its prong as covered
test "pointDist sees the notch of a concave pad as outside the copper" {
    const bx0: f64 = 0;
    const by0: f64 = 0;
    const bx1: f64 = 3;
    const by1: f64 = 3;

    // A point in the bottom-left notch: inside the bounding box but NOT on copper
    // (slack large enough to force the exact outline path).
    try testing.expect(pointDist(bx0, by0, bx1, by1, &L_POLY, 0.5, 0.5, 5.0) > 0.4);
    // A point on the top bar and on the prong: real copper, distance 0.
    try testing.expectEqual(@as(f64, 0), pointDist(bx0, by0, bx1, by1, &L_POLY, 1.5, 2.5, 5.0));
    try testing.expectEqual(@as(f64, 0), pointDist(bx0, by0, bx1, by1, &L_POLY, 2.5, 0.5, 5.0));
    // A point just outside a recessed edge still measures against the real
    // outline, not the box: the notch corner is 1.5 mm of clear copper away.
    try testing.expect(pointDist(bx0, by0, bx1, by1, &L_POLY, -0.4, 0.5, 5.0) > 0.39);
    // Far beyond the slack: the cheap box distance is returned, outline skipped.
    try testing.expect(@abs(pointDist(bx0, by0, bx1, by1, &L_POLY, 5, 1, 0.5) - 2.0) < 1e-9);
}

// spec: placement/pad_shape - simplifies a dense outline to a few corners within tolerance
test "simplifyRing collapses collinear arc points but keeps real corners" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // A unit square whose right edge carries six extra collinear points (standing
    // in for the dense arc points KiCad emits): DP drops every interior collinear
    // point and keeps the four real corners.
    const dense = [_][2]f64{
        .{ 0, 0 },   .{ 1, 0 },
        .{ 1, 0.2 }, .{ 1, 0.4 },
        .{ 1, 0.5 }, .{ 1, 0.6 },
        .{ 1, 0.8 }, .{ 1, 1 },
        .{ 0, 1 },   .{ 0, 0 },
    };
    const s = try simplifyRing(arena, &dense, 0.01);
    try testing.expect(s.len >= 4 and s.len < 8);
    // The simplified ring still classifies inside/outside correctly.
    try testing.expect(pointInPoly(s, 0.5, 0.5));
    try testing.expect(!pointInPoly(s, 1.5, 0.5));
}

// spec: placement/pad_shape - shapeGap clears a pad nested in a concave neighbour's notch
test "shapeGap frees a pad sitting in a concave pad's notch" {
    const notch = Shape{ .x0 = 0, .y0 = 0, .x1 = 3, .y1 = 3, .poly = &L_POLY };
    // A small pad sitting in the bottom-left notch — its bounding box overlaps
    // the concave pad's box, but the real outlines are well clear.
    const inset = Shape{ .x0 = 0.3, .y0 = 0.3, .x1 = 0.9, .y1 = 0.9 };
    try testing.expect(shapeGap(notch, inset, 0.5) >= 0.5);

    // Two plain rects 0.4 apart read their exact box gap.
    const r1 = Shape{ .x0 = 0, .y0 = 0, .x1 = 1, .y1 = 1 };
    const r2 = Shape{ .x0 = 1.4, .y0 = 0, .x1 = 2.4, .y1 = 1 };
    try testing.expect(@abs(shapeGap(r1, r2, 1.0) - 0.4) < 1e-9);
}

// A non-quarter part rotation drives the arbitrary-angle rotated-bbox branch:
// the box corners are centre ∓ half-extent, so a sign flip on x0/y0 would push
// the corner the wrong side of the pad centre.
test "worldShape rotated-rectangle box corners are centre minus/plus the half-extent" {
    const part = optimizer.Part{
        .ref_des = "R1",
        .kind = .passive,
        .hw = 1,
        .hh = 1,
        .pads = &.{},
        .fallback = false,
        .x = 10,
        .y = 20,
        .rot = 45,
    };
    const pad = geometry.Pad{ .number = "1", .x = 0, .y = 0, .w = 2, .h = 2 };
    const s = try worldShape(testing.allocator, part, pad);
    // hw = hh = (w/2)·cos45 + (h/2)·sin45 = √2; box centre is the pose (10,20).
    const r = @sqrt(2.0);
    try testing.expectApproxEqAbs(@as(f64, 10) - r, s.x0, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 20) - r, s.y0, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 10) + r, s.x1, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 20) + r, s.y1, 1e-9);
}
