//! Pad collision shapes for routing + DRC. A pad is either a simple axis-aligned
//! rectangle (its bounding box) or an exact polygon for custom and rounded
//! pads. The router's clearance checks and the DRC verifier both
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
const poly_scanline = @import("../poly_scanline.zig");

/// A pad's world-space collision shape: its bounding box (always) plus, for a
/// non-rectangular pad, the real copper outline in world mm (`poly`; empty ⇒
/// the box is exact). The box is the broad phase; the outline is the exact phase.
pub const Shape = struct {
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
    poly: []const [2]f64 = &.{},
};

/// Return a deterministic point on the pad's actual copper. For rectangular
/// lands this is the bounding-box centre. A concave custom pad may put that
/// point in a relief notch, so use the widest copper interval on the centre
/// scanline instead (and fall back to an edge-midpoint scanline for shapes
/// whose centreline misses every lobe). Route targets and connectivity reports
/// must never aim at empty space merely because it is inside the pad's box.
pub fn copperAnchor(shape: Shape) [2]f64 {
    const center = [2]f64{ (shape.x0 + shape.x1) / 2, (shape.y0 + shape.y1) / 2 };
    if (shape.poly.len < 3 or pointInPoly(shape.poly, center[0], center[1])) return center;
    if (poly_scanline.widestInterval(shape.poly, center[1])) |span|
        return .{ (span[0] + span[1]) / 2, center[1] };
    for (shape.poly, 0..) |point, i| {
        const previous = shape.poly[if (i == 0) shape.poly.len - 1 else i - 1];
        const y = (previous[1] + point[1]) / 2;
        if (poly_scanline.widestInterval(shape.poly, y)) |span|
            return .{ (span[0] + span[1]) / 2, y };
    }
    return center;
}

/// Outline-simplification tolerance (mm). KiCad emits a custom pad's rounded
/// corners as ~100-200 fine arc points; collapsing them to within this distance
/// leaves ~10 corner points (concavities preserved), which is well under the
/// clearance rule yet keeps the per-pad distance maths cheap.
const simplify_tol_mm: f64 = 0.03;
const rounded_corner_steps: usize = 8;

fn shapeFromWorldPoly(poly: []const [2]f64) Shape {
    var x0 = std.math.inf(f64);
    var y0 = std.math.inf(f64);
    var x1 = -std.math.inf(f64);
    var y1 = -std.math.inf(f64);
    for (poly) |point| {
        x0 = @min(x0, point[0]);
        y0 = @min(y0, point[1]);
        x1 = @max(x1, point[0]);
        y1 = @max(y1, point[1]);
    }
    return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1, .poly = poly };
}

/// A part's keep-out courtyard as its four REAL world corners, ordered around
/// the rectangle so consecutive pairs are its edges.
///
/// `optimizer.worldCourtyard` returns this polygon's axis-aligned bounding BOX,
/// which is up to √2 wider per axis once the part leaves a quarter turn — a
/// 4.8 × 6.0 mm courtyard at 45° boxes to 7.6 mm square, twice its own area,
/// and its inner corner is a point the part does not occupy at all. The box is
/// a sound cheap cull (it contains the courtyard at every pose); it is the
/// wrong shape to enforce as the keepout itself. Corners run through
/// `worldPadCenter`, so the bottom-side mirror lands on the body rather than on
/// the centre alone — the same reason a custom pad's outline is transformed
/// per vertex above.
pub fn worldCourtyardCorners(part: optimizer.Part) [4][2]f64 {
    const local = [4][2]f64{ .{ -part.hw, -part.hh }, .{ part.hw, -part.hh }, .{ part.hw, part.hh }, .{ -part.hw, part.hh } };
    var out: [4][2]f64 = undefined;
    for (local, 0..) |v, i| out[i] = optimizer.worldPadCenter(&part, part.ccx + v[0], part.ccy + v[1]);
    return out;
}

/// Polygonize a KiCad roundrect closely enough that a 0.127 mm trace can use
/// the legal corner corridor instead of colliding with the pad's square bbox.
fn worldRoundrect(
    arena: std.mem.Allocator,
    part: optimizer.Part,
    pad: geometry.Pad,
) std.mem.Allocator.Error!Shape {
    const center = optimizer.worldPadCenter(&part, pad.x, pad.y);
    const ratio = if (pad.rratio() > 0) pad.rratio() else geometry.default_rratio;
    const radius = @min(@max(ratio, 0) * @min(pad.w, pad.h), @min(pad.w, pad.h) / 2);
    const hw = pad.w / 2;
    const hh = pad.h / 2;
    const total = (part.rot + pad.rot) * std.math.pi / 180.0;
    const ca = @cos(total);
    const sa = @sin(total);
    const poly = try arena.alloc([2]f64, 4 * (rounded_corner_steps + 1));
    const corner_centers = [4][2]f64{
        .{ hw - radius, hh - radius },
        .{ -hw + radius, hh - radius },
        .{ -hw + radius, -hh + radius },
        .{ hw - radius, -hh + radius },
    };
    for (corner_centers, 0..) |corner, ci| {
        for (0..rounded_corner_steps + 1) |step| {
            const phase = @as(f64, @floatFromInt(ci)) +
                @as(f64, @floatFromInt(step)) / @as(f64, @floatFromInt(rounded_corner_steps));
            const angle = phase * std.math.pi / 2;
            const lx = corner[0] + radius * @cos(angle);
            const ly = corner[1] + radius * @sin(angle);
            poly[ci * (rounded_corner_steps + 1) + step] = .{
                center[0] + lx * ca - ly * sa,
                center[1] + lx * sa + ly * ca,
            };
        }
    }
    return shapeFromWorldPoly(poly);
}

/// World collision shape of `pad` on `part`, honouring the part's pose. A custom
/// pad carries its outline transformed into world space and simplified (box from
/// the full outline's bounds); a rectangular pad carries its four real corners
/// once the pose leaves a quarter turn; a circle carries a conservative round
/// outline; an oval keeps the bounding box.
pub fn worldShape(arena: std.mem.Allocator, part: optimizer.Part, pad: geometry.Pad) std.mem.Allocator.Error!Shape {
    if (pad.poly.len >= 3) {
        const wp = try arena.alloc([2]f64, pad.poly.len);
        var x0: f64 = std.math.inf(f64);
        var y0: f64 = std.math.inf(f64);
        var x1: f64 = -std.math.inf(f64);
        var y1: f64 = -std.math.inf(f64);
        for (pad.poly, 0..) |v, i| {
            const w = optimizer.worldPadCenter(&part, v[0], v[1]);
            wp[i] = w;
            x0 = @min(x0, w[0]);
            y0 = @min(y0, w[1]);
            x1 = @max(x1, w[0]);
            y1 = @max(y1, w[1]);
        }
        return .{ .x0 = x0, .y0 = y0, .x1 = x1, .y1 = y1, .poly = try simplifyRing(arena, wp, simplify_tol_mm) };
    }
    if (std.mem.eql(u8, pad.shape, "roundrect")) return worldRoundrect(arena, part, pad);
    const c = optimizer.worldPadCenter(&part, pad.x, pad.y);
    if (std.mem.eql(u8, pad.shape, "circle") and pad.w == pad.h) return worldCircle(arena, c, pad.w / 2);
    // Total pad orientation = part pose + the pad's own `(pos … ROT)`. A
    // quarter turn keeps the exact axis-aligned box (byte-identical to the old
    // path).
    const tot = part.rot + pad.rot;
    const q = @mod(@round(tot), 360);
    if (@abs(tot - @round(tot / 90) * 90) < 1e-6) {
        const swap = q == 90 or q == 270;
        const hw = if (swap) pad.h / 2 else pad.w / 2;
        const hh = if (swap) pad.w / 2 else pad.h / 2;
        return .{ .x0 = c[0] - hw, .y0 = c[1] - hh, .x1 = c[0] + hw, .y1 = c[1] + hh, .poly = &.{} };
    }
    // Off a quarter turn a rectangular pad is STILL a rectangle — just not an
    // axis-aligned one — so it carries its four real corners. Its bounding box
    // is `|hw·cosθ|+|hh·sinθ|` per axis, up to √2 wider than the copper in BOTH
    // axes at once: a square land at 45° boxes to twice its own area, and every
    // consumer that measures clearance through this shape (DRC, the router's
    // checks, the via fence, the pour, generated silkscreen) then holds copper
    // off a square keepout the pad does not own. Only a 90° increment hid it,
    // which is why the same footprint reads correctly at 0/90/180/270 and
    // oversized at 45 (the rf-switch-eval SMPM launches: J1/J6/J8 exact, the
    // four 45° ones J2–J5 square).
    //
    // `pointDist`/`shapeGap`/`segmentDist` all measure the box first and only
    // walk an outline once the box is within the caller's slack, so the exact
    // corners cost nothing until a neighbour is close enough for them to matter.
    //
    // An `oval` is a stadium whose corners a rectangle would invent, so it keeps
    // the conservative box: over-stating round copper is the safe direction, and
    // this module has no arc primitive to state it exactly.
    if (!std.mem.eql(u8, pad.shape, "circle") and !std.mem.eql(u8, pad.shape, "oval")) {
        const pa = pad.rot * std.math.pi / 180.0;
        const pca = @cos(pa);
        const psa = @sin(pa);
        const hw = pad.w / 2;
        const hh = pad.h / 2;
        const local = [4][2]f64{ .{ -hw, -hh }, .{ hw, -hh }, .{ hw, hh }, .{ -hw, hh } };
        const poly = try arena.alloc([2]f64, local.len);
        // The pad's own rotation turns it inside the FOOTPRINT frame; the part
        // transform (rotation and the bottom-side mirror alike) is then applied
        // per corner by `worldPadCenter`, exactly as the custom-outline path
        // above does — so a mirrored pad's corners land on its real copper
        // rather than on the un-mirrored rectangle's.
        for (local, 0..) |v, i| {
            poly[i] = optimizer.worldPadCenter(&part, pad.x + v[0] * pca - v[1] * psa, pad.y + v[0] * psa + v[1] * pca);
        }
        return shapeFromWorldPoly(poly);
    }
    const a = tot * std.math.pi / 180.0;
    const ca = @abs(@cos(a));
    const sa = @abs(@sin(a));
    const hw = (pad.w / 2) * ca + (pad.h / 2) * sa;
    const hh = (pad.w / 2) * sa + (pad.h / 2) * ca;
    return .{ .x0 = c[0] - hw, .y0 = c[1] - hh, .x1 = c[0] + hw, .y1 = c[1] + hh, .poly = &.{} };
}

/// A circle as a small circumscribed polygon. The half-step phase puts an EDGE
/// tangent to every cardinal point, so the polygon's box stays exactly the
/// circle's box while the outline contains (never under-states) the true land.
/// That conservative direction is important for DRC and pour clearance: the
/// approximation may hold copper off by a few microns, but can never admit it
/// inside the authored circle. Thirty-two sides keep the largest excess below
/// 0.5% of the radius without burdening common BGA footprints with dense rings.
const circle_steps: usize = 32;

fn worldCircle(arena: std.mem.Allocator, c: [2]f64, radius: f64) std.mem.Allocator.Error!Shape {
    const poly = try arena.alloc([2]f64, circle_steps);
    const step = 2 * std.math.pi / @as(f64, @floatFromInt(circle_steps));
    const vertex_radius = radius / @cos(step / 2);
    for (poly, 0..) |*point, i| {
        const angle = (@as(f64, @floatFromInt(i)) + 0.5) * step;
        point.* = .{ c[0] + vertex_radius * @cos(angle), c[1] + vertex_radius * @sin(angle) };
    }
    return .{
        .x0 = c[0] - radius,
        .y0 = c[1] - radius,
        .x1 = c[0] + radius,
        .y1 = c[1] + radius,
        .poly = poly,
    };
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
    var stack: std.ArrayList([2]usize) = .empty;
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
    var out: std.ArrayList([2]f64) = .empty;
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

/// Shortest distance from segment `a`→`b` to a pad's copper, or +inf when the
/// whole segment stays outside the pad's `window`-inflated bounding box. The
/// slab clip makes runtime depend on the small portion near the pad instead of
/// the full trace length; 0.05 mm samples match the DRC pass/fail geometry.
pub fn segmentDist(shape: Shape, a: [2]f64, b: [2]f64, window: f64) f64 {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    var f0: f64 = 0;
    var f1: f64 = 1;
    if (@abs(dx) > 1e-12) {
        const lo = (shape.x0 - window - a[0]) / dx;
        const hi = (shape.x1 + window - a[0]) / dx;
        f0 = @max(f0, @min(lo, hi));
        f1 = @min(f1, @max(lo, hi));
    } else if (a[0] < shape.x0 - window or a[0] > shape.x1 + window) return std.math.inf(f64);
    if (@abs(dy) > 1e-12) {
        const lo = (shape.y0 - window - a[1]) / dy;
        const hi = (shape.y1 + window - a[1]) / dy;
        f0 = @max(f0, @min(lo, hi));
        f1 = @min(f1, @max(lo, hi));
    } else if (a[1] < shape.y0 - window or a[1] > shape.y1 + window) return std.math.inf(f64);
    if (f0 > f1) return std.math.inf(f64);
    const clipped_len = std.math.hypot(dx, dy) * (f1 - f0);
    const steps: usize = @max(1, @as(usize, @intFromFloat(@ceil(clipped_len / 0.05))));
    var best = std.math.inf(f64);
    var i: usize = 0;
    while (i <= steps) : (i += 1) {
        const f = f0 + (f1 - f0) * @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
        best = @min(best, pointDist(
            shape.x0,
            shape.y0,
            shape.x1,
            shape.y1,
            shape.poly,
            a[0] + f * dx,
            a[1] + f * dy,
            best,
        ));
    }
    return best;
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
///
/// Each edge contributes `segPointDist`'s geometry, but the scan compares the
/// SQUARED closest-point deltas and takes a single root on the winner: `hypot`
/// is monotonic in that square, so the argmin edge — and hence the value
/// returned — is the same one the per-edge form picked, at one root instead of
/// `poly.len`. `pour.polySignedInset` already runs this trade over the board
/// outline; this is the pad-side twin, and it matters because a roundrect pad is
/// a 36-point ring (`rounded_corner_steps`) that the pour's foreign-copper
/// stamping walks once per raster cell in the pad's window — 36 roots per cell
/// was the largest single cost left in a barracuda DRC.
fn distPointPolyEdges(poly: []const [2]f64, px: f64, py: f64) f64 {
    var best2: f64 = std.math.inf(f64);
    var bdx: f64 = 0;
    var bdy: f64 = 0;
    var j: usize = poly.len - 1;
    for (poly, 0..) |vi, i| {
        const d = segPointDelta(poly[j][0], poly[j][1], vi[0], vi[1], px, py);
        const d2 = d[0] * d[0] + d[1] * d[1];
        if (d2 < best2) {
            best2 = d2;
            bdx = d[0];
            bdy = d[1];
        }
        j = i;
    }
    return std.math.hypot(bdx, bdy);
}

/// The (Δx, Δy) from (px,py) to its closest point on segment (ax,ay)→(bx,by) —
/// `segPointDist` before the root, so a scan over many edges can defer it.
fn segPointDelta(ax: f64, ay: f64, bx: f64, by: f64, px: f64, py: f64) [2]f64 {
    const dx = bx - ax;
    const dy = by - ay;
    const len2 = dx * dx + dy * dy;
    if (len2 < 1e-12) return .{ px - ax, py - ay };
    const t = std.math.clamp(((px - ax) * dx + (py - ay) * dy) / len2, 0, 1);
    return .{ px - (ax + t * dx), py - (ay + t * dy) };
}

/// Shortest distance from point (px,py) to segment (ax,ay)→(bx,by).
pub fn segPointDist(ax: f64, ay: f64, bx: f64, by: f64, px: f64, py: f64) f64 {
    const d = segPointDelta(ax, ay, bx, by, px, py);
    return std.math.hypot(d[0], d[1]);
}

/// The closest point on segment `(ax,ay)-(bx,by)` to `(px,py)`, plus its
/// distance — `segPointDist`'s twin for callers that need the witness point
/// (a weld target, a bridge endpoint) and not just the gap.
pub const SegClosest = struct { d: f64, x: f64, y: f64 };

/// Closest point on segment `(ax,ay)-(bx,by)` to `(px,py)`, plus its distance.
pub fn closestOnSeg(ax: f64, ay: f64, bx: f64, by: f64, px: f64, py: f64) SegClosest {
    const dx = bx - ax;
    const dy = by - ay;
    const len2 = dx * dx + dy * dy;
    if (len2 < 1e-12) return .{ .d = std.math.hypot(px - ax, py - ay), .x = ax, .y = ay };
    const u = std.math.clamp(((px - ax) * dx + (py - ay) * dy) / len2, 0, 1);
    const cx = ax + u * dx;
    const cy = ay + u * dy;
    return .{ .d = std.math.hypot(px - cx, py - cy), .x = cx, .y = cy };
}

/// Midpoint of the closest approach between segments a1→a2 and b1→b2, taken
/// from the nearest endpoint projection (exact unless the segments cross, where
/// any point of the overlap is equally the spot).
///
/// WHERE two pieces of copper come closest, as opposed to `segSegDist`'s how
/// far. The keepout escape gate is a disc around a pad, so both engines that
/// answer "is this halo suspended here" — `drc_keepout`'s finding and the
/// router's own direct/dogleg probe — have to name the same place, or one
/// forgives an approach the other refuses.
pub fn segSegMid(a1: [2]f64, a2: [2]f64, b1: [2]f64, b2: [2]f64) [2]f64 {
    var best = std.math.inf(f64);
    var mid = [2]f64{ (a1[0] + a2[0] + b1[0] + b2[0]) / 4, (a1[1] + a2[1] + b1[1] + b2[1]) / 4 };
    for ([2][2]f64{ a1, a2 }) |p| {
        const c = closestOnSeg(b1[0], b1[1], b2[0], b2[1], p[0], p[1]);
        if (c.d >= best) continue;
        best = c.d;
        mid = .{ (p[0] + c.x) / 2, (p[1] + c.y) / 2 };
    }
    for ([2][2]f64{ b1, b2 }) |p| {
        const c = closestOnSeg(a1[0], a1[1], a2[0], a2[1], p[0], p[1]);
        if (c.d >= best) continue;
        best = c.d;
        mid = .{ (p[0] + c.x) / 2, (p[1] + c.y) / 2 };
    }
    return mid;
}

/// Shortest distance between segments a1→a2 and b1→b2 (0 when they cross).
pub fn segSegDist(a1: [2]f64, a2: [2]f64, b1: [2]f64, b2: [2]f64) f64 {
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
const l_poly = [_][2]f64{
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
    try testing.expect(pointDist(bx0, by0, bx1, by1, &l_poly, 0.5, 0.5, 5.0) > 0.4);
    // A point on the top bar and on the prong: real copper, distance 0.
    try testing.expectEqual(@as(f64, 0), pointDist(bx0, by0, bx1, by1, &l_poly, 1.5, 2.5, 5.0));
    try testing.expectEqual(@as(f64, 0), pointDist(bx0, by0, bx1, by1, &l_poly, 2.5, 0.5, 5.0));
    // A point just outside a recessed edge still measures against the real
    // outline, not the box: the notch corner is 1.5 mm of clear copper away.
    try testing.expect(pointDist(bx0, by0, bx1, by1, &l_poly, -0.4, 0.5, 5.0) > 0.39);
    // Far beyond the slack: the cheap box distance is returned, outline skipped.
    try testing.expect(@abs(pointDist(bx0, by0, bx1, by1, &l_poly, 5, 1, 0.5) - 2.0) < 1e-9);
}

test "copper anchor avoids a concave pad's empty bounding-box centre" {
    const anchor = copperAnchor(.{ .x0 = 0, .y0 = 0, .x1 = 3, .y1 = 3, .poly = &l_poly });
    try testing.expect(anchor[0] >= 2 and anchor[0] <= 3);
    try testing.expectApproxEqAbs(@as(f64, 1.5), anchor[1], 1e-12);
    try testing.expect(pointDist(0, 0, 3, 3, &l_poly, anchor[0], anchor[1], 5) == 0);
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

/// The per-edge minimum-of-roots `distPointPolyEdges` replaced — the reference
/// its single-root scan has to reproduce.
fn minEdgeDist(poly: []const [2]f64, px: f64, py: f64) f64 {
    var m: f64 = std.math.inf(f64);
    var j: usize = poly.len - 1;
    for (poly, 0..) |vi, i| {
        m = @min(m, segPointDist(poly[j][0], poly[j][1], vi[0], vi[1], px, py));
        j = i;
    }
    return m;
}

// spec: placement/pad_shape - the polygon distance scan returns the per-edge minimum with a single root
test "distPointPolyEdges equals a per-edge minimum of segPointDist" {
    // The scan picks its edge by SQUARED distance and roots only the winner.
    // That is sound only while the argmin agrees with the per-edge minimum of
    // the roots, so probe an L-ring whose edges differ in length and
    // orientation: outside each face, off both convex and reflex corners,
    // inside the notch (where two edges compete), and on an edge itself.
    const ring = [_][2]f64{ .{ 0, 0 }, .{ 3, 0 }, .{ 3, 1 }, .{ 1, 1 }, .{ 1, 3 }, .{ 0, 3 } };
    const probes = [_][2]f64{
        .{ -0.5, 1.5 },  .{ 1.5, -0.5 }, .{ 3.5, 0.5 },  .{ 0.5, 3.5 },
        .{ -0.4, -0.4 }, .{ 3.4, 1.4 },  .{ 1.4, 3.4 },  .{ -0.3, 3.3 },
        .{ 2.0, 2.0 },   .{ 1.5, 1.5 },  .{ 1.05, 2.9 }, .{ 2.9, 1.05 },
        .{ 0.5, 0.5 },   .{ 0.5, 2.5 },  .{ 2.5, 0.5 },  .{ 1.0, 1.0 },
        .{ 3.0, 0.5 },   .{ 0.0, 1.5 },  .{ 1.5, 1.0 },  .{ 1.0, 1.5 },
    };
    for (probes) |p| {
        try testing.expectEqual(minEdgeDist(&ring, p[0], p[1]), distPointPolyEdges(&ring, p[0], p[1]));
    }
}

// spec: placement/pad_shape - shapeGap clears a pad nested in a concave neighbour's notch
test "shapeGap frees a pad sitting in a concave pad's notch" {
    const notch = Shape{ .x0 = 0, .y0 = 0, .x1 = 3, .y1 = 3, .poly = &l_poly };
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
    const pad = geometry.Pad{ .number = "1", .x = 2, .y = 0, .w = 2, .h = 2 };
    const s = try worldShape(testing.allocator, part, pad);
    defer testing.allocator.free(s.poly);
    // hw = hh = (w/2)·cos45 + (h/2)·sin45 = √2; the off-centre pad itself
    // rotates by 45°, proving the footprint transform does not fall back to 0°.
    const r = @sqrt(2.0);
    try testing.expectApproxEqAbs(@as(f64, 10), s.x0, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 20), s.y0, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 10) + 2 * r, s.x1, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 20) + 2 * r, s.y1, 1e-9);
}

// spec: placement/pad_shape - a rectangular pad off a quarter turn carries its four rotated corners, so its keepout is the land and not the land's square bounding box
test "a 45-degree rectangular land measures against its corners, not its box" {
    // The Amphenol 925-143J-51PT SMPM signal land, on a launch rotated 45° — the
    // rf-switch-eval case. Its box is 1.293 mm square where the copper is
    // 0.5588 × 1.27 mm, so a box test claims 2.35× the land's own area.
    const part = optimizer.Part{
        .ref_des = "J2",
        .kind = .hub,
        .hw = 2.4,
        .hh = 3,
        .pads = &.{},
        .fallback = false,
        .rot = 45,
    };
    const pad = geometry.Pad{ .number = "P$2", .x = 0, .y = 2.21, .w = 0.5588, .h = 1.27 };
    const s = try worldShape(testing.allocator, part, pad);
    defer testing.allocator.free(s.poly);
    try testing.expectEqual(@as(usize, 4), s.poly.len);

    // The box is unchanged — it is still the broad phase every caller filters on.
    const half = (0.5588 / 2.0 + 1.27 / 2.0) * @cos(std.math.pi / 4.0);
    const c = optimizer.worldPadCenter(&part, pad.x, pad.y);
    try testing.expectApproxEqAbs(c[0] - half, s.x0, 1e-9);
    try testing.expectApproxEqAbs(c[1] + half, s.y1, 1e-9);

    // Its corner is a corner of the BOX only: the rotated land cannot reach
    // maximum +x and minimum −y at once, so that point is 0.2794 mm (half the
    // land's width) of clear board — where the box called it copper.
    const gap = pointDist(s.x0, s.y0, s.x1, s.y1, s.poly, c[0] + half, c[1] - half, 5.0);
    try testing.expectApproxEqAbs(@as(f64, 0.2794), gap, 1e-6);
    // The land's own copper still reads as copper, so nothing has been narrowed.
    try testing.expectEqual(@as(f64, 0), pointDist(s.x0, s.y0, s.x1, s.y1, s.poly, c[0], c[1], 5.0));
}

/// Twice the signed area of a closed ring. Its SIGN is the winding, which a
/// mirror reverses and a rotation cannot.
fn ringWinding(poly: []const [2]f64) f64 {
    var sum: f64 = 0;
    var j: usize = poly.len - 1;
    for (poly, 0..) |p, i| {
        sum += (poly[j][0] - p[0]) * (poly[j][1] + p[1]);
        j = i;
    }
    return sum;
}

// spec: placement/pad_shape - a rotated rectangular pad on a bottom-side part carries corners mirrored with the part
test "a rotated land on a bottom-side part mirrors its corners with the part" {
    const front = optimizer.Part{
        .ref_des = "J2",
        .kind = .hub,
        .hw = 1,
        .hh = 1,
        .pads = &.{},
        .fallback = false,
        .rot = 45,
    };
    var back = front;
    back.side = .bottom;
    // The pad carries a rotation of its OWN, so its outline is not symmetric
    // under the mirror: this is the case that separates "mirror the footprint
    // point, then rotate the part" from "rotate by part.rot + pad.rot about a
    // mirrored centre", which agree for every pad whose own rotation is zero.
    const pad = geometry.Pad{ .number = "1", .x = 2, .y = 0, .w = 2, .h = 1, .rot = 30 };

    const fs = try worldShape(testing.allocator, front, pad);
    defer testing.allocator.free(fs.poly);
    const bs = try worldShape(testing.allocator, back, pad);
    defer testing.allocator.free(bs.poly);

    // A mirror reverses the ring's winding; a rotation never does. Equal signs
    // would mean the bottom land was merely rotated to a mirrored centre.
    try testing.expect(ringWinding(fs.poly) * ringWinding(bs.poly) < 0);
    // And it flips the pad's own rotation SENSE against the part's: the land
    // stands at 45+30 = 75° on the front face and 45−30 = 15° on the back, so
    // the two faces do not even share a bounding box.
    const front_half = 1.0 * @cos(75.0 * std.math.pi / 180.0) + 0.5 * @sin(75.0 * std.math.pi / 180.0);
    const back_half = 1.0 * @cos(15.0 * std.math.pi / 180.0) + 0.5 * @sin(15.0 * std.math.pi / 180.0);
    try testing.expectApproxEqAbs(2 * front_half, fs.x1 - fs.x0, 1e-9);
    try testing.expectApproxEqAbs(2 * back_half, bs.x1 - bs.x0, 1e-9);
    // Both faces share the pad's own copper, so the centre is copper on each.
    const bc = optimizer.worldPadCenter(&back, pad.x, pad.y);
    try testing.expectEqual(@as(f64, 0), pointDist(bs.x0, bs.y0, bs.x1, bs.y1, bs.poly, bc[0], bc[1], 5.0));
}

// spec: placement/pad_shape - a circle carries a round collision outline while an oval conservatively keeps its bounding box
test "a circle measures against its round outline while an oval keeps its box" {
    const part = optimizer.Part{
        .ref_des = "J2",
        .kind = .hub,
        .hw = 1,
        .hh = 1,
        .pads = &.{},
        .fallback = false,
        .rot = 0,
    };
    // The circle's broad-phase box is exact, while its conservative polygon
    // frees the box corner that used to produce a square copper-pour antipad.
    const circle = geometry.Pad{ .number = "1", .x = 0, .y = 0, .w = 1, .h = 1, .shape = "circle" };
    const cs = try worldShape(testing.allocator, part, circle);
    defer testing.allocator.free(cs.poly);
    try testing.expectEqual(@as(usize, circle_steps), cs.poly.len);
    try testing.expectApproxEqAbs(@as(f64, -0.5), cs.x0, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.5), cs.x1, 1e-9);
    try testing.expectEqual(@as(f64, 0), pointDist(cs.x0, cs.y0, cs.x1, cs.y1, cs.poly, 0, 0, 5));
    try testing.expect(pointDist(cs.x0, cs.y0, cs.x1, cs.y1, cs.poly, 0.5, 0.5, 5) > 0.20);

    // An oval's ends are round, so its corners are the rectangle's invention.
    var angled = part;
    angled.rot = 45;
    const oval = geometry.Pad{ .number = "2", .x = 0, .y = 0, .w = 2, .h = 1, .shape = "oval" };
    const os = try worldShape(testing.allocator, angled, oval);
    try testing.expectEqual(@as(usize, 0), os.poly.len);
    try testing.expectApproxEqAbs(@as(f64, (1.0 + 0.5) * @cos(std.math.pi / 4.0)), os.x1, 1e-9);
}

test "worldShape roundrect preserves a legal corner trace corridor" {
    const part = optimizer.Part{
        .ref_des = "R1",
        .kind = .passive,
        .hw = 1,
        .hh = 1,
        .pads = &.{},
        .fallback = false,
    };
    const pad = geometry.Pad{
        .number = "1",
        .x = 163.28,
        .y = 91.5,
        .w = 0.46,
        .h = 0.4,
        .shape = "roundrect",
        .overrides = .{ .rratio = 0.25 },
    };
    const shape = try worldShape(testing.allocator, part, pad);
    defer testing.allocator.free(shape.poly);
    const a = [2]f64{ 162.7829, 91.353499 };
    const b = [2]f64{ 163.045899, 91.0905 };
    try testing.expect(shape.poly.len > 4);
    try testing.expect(segmentDist(shape, a, b, 0.3) >= 0.1905 - 1e-6);
}
