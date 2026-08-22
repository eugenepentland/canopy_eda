//! Board-outline polygon geometry — the shared shape math behind
//! non-rectangular board outlines: closed straight-segment polygons plus
//! native three-point arcs, with fine polylines retained for DRC consumers.
//!
//! A polygon is a closed vertex list in board mm (`[]const [2]f64`, last
//! vertex implicitly connects back to the first). Every consumer of the
//! exact shape (board-edge DRC, Gerber Edge_Cuts, the PNG renderer, the
//! viewer) reads these helpers; the placement solver itself keeps using the
//! bounding-box rectangle (`bboxRect`) as its `board_rect`, so the polygon
//! never shifts a layout.

const std = @import("std");
const numeric = @import("../numeric.zig");
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

/// A filleted polygon in both forms consumers need: `poly` is the bounded-
/// sagitta straight-segment fallback used by DRC/raster geometry, while
/// `arcs` preserves the exact circular pieces for SVG, KiCad and Gerber.
pub const FilletResult = struct {
    poly: []const [2]f64,
    arcs: []const optimizer.BoardArc,
};

const CornerFillet = struct {
    p1: [2]f64,
    pm: [2]f64,
    p2: [2]f64,
    cx: f64,
    cy: f64,
    radius: f64,
    start_angle: f64,
    sweep: f64,
};

/// Recovered center, radius, and directed sweep of a three-point native arc.
pub const ArcCircle = struct { cx: f64, cy: f64, radius: f64, start_angle: f64, sweep: f64 };

/// Recover the circumcircle and signed start→end sweep selected by the midpoint.
pub fn arcCircle(arc: optimizer.BoardArc) ?ArcCircle {
    const x1 = arc.p1[0];
    const y1 = arc.p1[1];
    const xm = arc.pm[0];
    const ym = arc.pm[1];
    const x2 = arc.p2[0];
    const y2 = arc.p2[1];
    const d = 2 * (x1 * (ym - y2) + xm * (y2 - y1) + x2 * (y1 - ym));
    if (@abs(d) < 1e-12) return null;
    const s1 = x1 * x1 + y1 * y1;
    const sm = xm * xm + ym * ym;
    const s2 = x2 * x2 + y2 * y2;
    const cx = (s1 * (ym - y2) + sm * (y2 - y1) + s2 * (y1 - ym)) / d;
    const cy = (s1 * (x2 - xm) + sm * (x1 - x2) + s2 * (xm - x1)) / d;
    const start = std.math.atan2(y1 - cy, x1 - cx);
    const mid = std.math.atan2(ym - cy, xm - cx);
    const finish = std.math.atan2(y2 - cy, x2 - cx);
    const ccw_mid = @mod(mid - start, std.math.tau);
    const ccw_end = @mod(finish - start, std.math.tau);
    return .{
        .cx = cx,
        .cy = cy,
        .radius = std.math.hypot(x1 - cx, y1 - cy),
        .start_angle = start,
        .sweep = if (ccw_mid <= ccw_end) ccw_end else ccw_end - std.math.tau,
    };
}

/// True when a tessellated fallback segment belongs to this native arc.
pub fn arcOwnsSegment(arc: optimizer.BoardArc, a: [2]f64, b: [2]f64, tolerance: f64) bool {
    const circle = arcCircle(arc) orelse return false;
    if (@abs(std.math.hypot(a[0] - circle.cx, a[1] - circle.cy) - circle.radius) > tolerance or
        @abs(std.math.hypot(b[0] - circle.cx, b[1] - circle.cy) - circle.radius) > tolerance) return false;
    return angleOnArc(circle, std.math.atan2(a[1] - circle.cy, a[0] - circle.cx), tolerance) and
        angleOnArc(circle, std.math.atan2(b[1] - circle.cy, b[0] - circle.cx), tolerance);
}

fn angleOnArc(circle: ArcCircle, angle: f64, tolerance: f64) bool {
    const angular_tol = tolerance / @max(circle.radius, tolerance);
    if (circle.sweep >= 0) return @mod(angle - circle.start_angle, std.math.tau) <= circle.sweep + angular_tol;
    return @mod(circle.start_angle - angle, std.math.tau) <= -circle.sweep + angular_tol;
}

/// Replace each polygon vertex with a tangent circular fillet of the requested
/// per-corner radius. A radius is reduced when either adjacent edge is too
/// short; each corner may consume at most 45% of an edge, leaving a real
/// straight between neighbouring fillets. Zero/invalid radii stay sharp.
pub fn filletPath(
    alloc: std.mem.Allocator,
    pts: []const [2]f64,
    radii: []const f64,
    max_sagitta: f64,
) std.mem.Allocator.Error!FilletResult {
    if (pts.len < 3 or radii.len != pts.len) return .{
        .poly = try alloc.dupe([2]f64, pts),
        .arcs = &.{},
    };
    var poly: std.ArrayList([2]f64) = .empty;
    var arcs: std.ArrayList(optimizer.BoardArc) = .empty;
    for (pts, 0..) |b, i| {
        const a = pts[(i + pts.len - 1) % pts.len];
        const c = pts[(i + 1) % pts.len];
        const f = cornerFillet(a, b, c, radii[i]) orelse {
            try appendUnique(&poly, alloc, b);
            continue;
        };
        try arcs.append(alloc, .{ .p1 = f.p1, .pm = f.pm, .p2 = f.p2 });
        try appendUnique(&poly, alloc, f.p1);
        const sag = @max(1e-4, max_sagitta);
        const step = if (f.radius <= sag)
            @abs(f.sweep)
        else
            2 * std.math.acos(std.math.clamp(1 - sag / f.radius, -1, 1));
        const raw = @ceil(@abs(f.sweep) / @max(step, 1e-3));
        const count = numeric.checkedInt(usize, std.math.clamp(raw, 1, 64)) orelse 1;
        var k: usize = 1;
        while (k < count) : (k += 1) {
            const frac = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(count));
            const ang = f.start_angle + f.sweep * frac;
            try appendUnique(&poly, alloc, .{ f.cx + f.radius * @cos(ang), f.cy + f.radius * @sin(ang) });
        }
        try appendUnique(&poly, alloc, f.p2);
    }
    return .{ .poly = try poly.toOwnedSlice(alloc), .arcs = try arcs.toOwnedSlice(alloc) };
}

fn appendUnique(list: *std.ArrayList([2]f64), alloc: std.mem.Allocator, p: [2]f64) std.mem.Allocator.Error!void {
    if (list.items.len > 0) {
        const q = list.items[list.items.len - 1];
        if (std.math.hypot(q[0] - p[0], q[1] - p[1]) <= 1e-9) return;
    }
    try list.append(alloc, p);
}

fn cornerFillet(a: [2]f64, b: [2]f64, c: [2]f64, want: f64) ?CornerFillet {
    if (!(want > 0) or !std.math.isFinite(want)) return null;
    const x1 = b[0] - a[0];
    const y1 = b[1] - a[1];
    const x2 = c[0] - b[0];
    const y2 = c[1] - b[1];
    const l1 = std.math.hypot(x1, y1);
    const l2 = std.math.hypot(x2, y2);
    if (l1 < 1e-6 or l2 < 1e-6) return null;
    const ux = x1 / l1;
    const uy = y1 / l1;
    const vx = x2 / l2;
    const vy = y2 / l2;
    const dot = std.math.clamp(ux * vx + uy * vy, -1, 1);
    const cross = ux * vy - uy * vx;
    if (@abs(cross) < 1e-6 or dot < -0.995) return null;
    const tangent = @tan(std.math.acos(dot) / 2);
    if (!(tangent > 1e-6)) return null;
    const trim = @min(want * tangent, @min(l1 * 0.45, l2 * 0.45));
    if (trim < 0.01) return null;
    const radius = trim / tangent;
    const sign: f64 = if (cross < 0) -1 else 1;
    const p1 = [2]f64{ b[0] - ux * trim, b[1] - uy * trim };
    const p2 = [2]f64{ b[0] + vx * trim, b[1] + vy * trim };
    const cx = p1[0] - uy * sign * radius;
    const cy = p1[1] + ux * sign * radius;
    const start = std.math.atan2(p1[1] - cy, p1[0] - cx);
    const finish = std.math.atan2(p2[1] - cy, p2[0] - cx);
    var sweep = finish - start;
    if (sign > 0) {
        while (sweep < 0) sweep += std.math.tau;
        while (sweep > std.math.tau) sweep -= std.math.tau;
    } else {
        while (sweep > 0) sweep -= std.math.tau;
        while (sweep < -std.math.tau) sweep += std.math.tau;
    }
    if (@abs(sweep) > std.math.pi + 1e-6) return null;
    const mid_angle = start + sweep / 2;
    return .{
        .p1 = p1,
        .pm = .{ cx + radius * @cos(mid_angle), cy + radius * @sin(mid_angle) },
        .p2 = p2,
        .cx = cx,
        .cy = cy,
        .radius = radius,
        .start_angle = start,
        .sweep = sweep,
    };
}

/// True when the closed polygon has any pair of NON-adjacent edges that
/// properly cross — a bow-tie / figure-eight the fab can't cut as one Edge.Cuts
/// profile. Edges sharing a vertex (the two neighbours of each edge, plus the
/// last↔first wrap) are skipped, so a merely concave-but-simple outline (the
/// L-board) reads as clean. Reuses the private `segIntersect` (touching counts).
pub fn selfIntersects(poly: []const [2]f64) bool {
    const n = poly.len;
    if (n < 4) return false; // a triangle can't cross itself
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const a = poly[i];
        const b = poly[(i + 1) % n];
        var j: usize = i + 1;
        while (j < n) : (j += 1) {
            // Skip the shared-vertex adjacencies: edge i vs edge i+1, and the
            // wrap pair (edge n-1 vs edge 0) — those meet at a vertex by
            // construction, not a self-crossing.
            if ((i + 1) % n == j or (j + 1) % n == i) continue;
            if (segIntersect(a, b, poly[j], poly[(j + 1) % n])) |_| return true;
        }
    }
    return false;
}

/// Twice the signed polygon area (shoelace). Zero for a degenerate outline —
/// a spike that doubles back on itself or a collinear strip — which
/// `segIntersect` (null on collinear/parallel) can't catch, so `valid` uses
/// this for the zero-area guard. Pub: the pour tracer ranks its interpolated
/// boundary loops (outer vs holes) by this same magnitude.
pub fn signedArea2(poly: []const [2]f64) f64 {
    if (poly.len < 3) return 0;
    var sum: f64 = 0;
    var j = poly.len - 1;
    for (poly, 0..) |p, i| {
        const q = poly[j];
        sum += q[0] * p[1] - p[0] * q[1];
        j = i;
    }
    return sum;
}

/// Minimum enclosed area (mm²) a written outline must have — below this the
/// polygon is treated as degenerate. Any real board dwarfs it.
const area_eps: f64 = 1e-9;

/// Fab-legal outline predicate for WRITE paths: ≥3 vertices, a non-degenerate
/// (non-zero) enclosed area, and no self-crossing edges. READ paths stay lenient
/// (a malformed polygon degrades to the bbox rectangle); this is the gate the
/// layout-save endpoint and the CLI `set_board_outline` arg parse use to reject
/// a bow-tie / zero-area shape before it can become the board profile.
pub fn valid(poly: []const [2]f64) bool {
    if (poly.len < 3) return false;
    if (@abs(signedArea2(poly)) < 2 * area_eps) return false;
    return !selfIntersects(poly);
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

// spec: placement/outline - selfIntersects flags a bow-tie but not a concave outline; valid rejects degenerate polys
test "selfIntersects and valid classify polygons" {
    // A concave-but-simple L is clean and fab-legal.
    try testing.expect(!selfIntersects(&l_poly));
    try testing.expect(valid(&l_poly));

    // A bow-tie (its diagonals cross) self-intersects and is rejected.
    const bowtie = [_][2]f64{ .{ 0, 0 }, .{ 10, 10 }, .{ 10, 0 }, .{ 0, 10 } };
    try testing.expect(selfIntersects(&bowtie));
    try testing.expect(!valid(&bowtie));

    // A convex square is clean + valid.
    const sq = [_][2]f64{ .{ 0, 0 }, .{ 4, 0 }, .{ 4, 4 }, .{ 0, 4 } };
    try testing.expect(!selfIntersects(&sq));
    try testing.expect(valid(&sq));

    // Degenerate: fewer than 3 vertices, and a zero-area collinear strip that
    // no edge-crossing test can catch — the area guard rejects both.
    const two = [_][2]f64{ .{ 0, 0 }, .{ 1, 1 } };
    try testing.expect(!valid(&two));
    const line = [_][2]f64{ .{ 0, 0 }, .{ 5, 0 }, .{ 10, 0 } };
    try testing.expect(!selfIntersects(&line));
    try testing.expect(!valid(&line));

    // A rounded-rect outline (generated internally) is simple and valid.
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const rr = try roundedRectPoly(arena_inst.allocator(), .{ .minx = 0, .miny = 0, .w = 20, .h = 10 }, 2);
    try testing.expect(!selfIntersects(rr));
    try testing.expect(valid(rr));
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

// spec: placement/outline - polygon fillets retain exact three-point arcs while producing a bounded-sagitta DRC polygon
test "filletPath preserves native rounded corners" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const square = [_][2]f64{ .{ 0, 0 }, .{ 20, 0 }, .{ 20, 10 }, .{ 0, 10 } };
    const radii = [_]f64{ 2, 2, 2, 2 };
    const result = try filletPath(arena_inst.allocator(), &square, &radii, 0.01);
    try testing.expectEqual(@as(usize, 4), result.arcs.len);
    try testing.expect(result.poly.len > square.len);
    try testing.expect(valid(result.poly));
    const circle = arcCircle(result.arcs[0]) orelse return error.TestExpectedArc;
    try testing.expectApproxEqAbs(@as(f64, 2), circle.radius, 1e-9);
    try testing.expect(arcOwnsSegment(result.arcs[0], result.poly[0], result.poly[1], 0.0001));
}
