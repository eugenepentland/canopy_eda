const std = @import("std");

/// Rotate a local point counter-clockwise in the board's y-down coordinate
/// frame. Right-angle poses stay exact; arbitrary editor poses use sin/cos.
pub fn rotate(x: f64, y: f64, degrees: f64) [2]f64 {
    // Solver poses overwhelmingly use these exact quarter turns. Avoid the
    // floating modulo in Debug before falling back to normalized editor angles.
    if (degrees == 0 or degrees == 360 or degrees == -360) return .{ x, y };
    if (degrees == 90 or degrees == -270) return .{ -y, x };
    if (degrees == 180 or degrees == -180) return .{ -x, -y };
    if (degrees == 270 or degrees == -90) return .{ y, -x };
    const r = @mod(degrees, 360.0);
    if (@abs(r) < 1e-12) return .{ x, y };
    if (@abs(r - 90) < 1e-12) return .{ -y, x };
    if (@abs(r - 180) < 1e-12) return .{ -x, -y };
    if (@abs(r - 270) < 1e-12) return .{ y, -x };
    const a = r * std.math.pi / 180.0;
    const c = @cos(a);
    const s = @sin(a);
    return .{ x * c - y * s, x * s + y * c };
}

/// Axis-aligned half-extents of a rectangle after rotation.
pub fn aabbHalf(hw: f64, hh: f64, degrees: f64) [2]f64 {
    if (degrees == 0 or degrees == 180 or degrees == -180)
        return .{ @abs(hw), @abs(hh) };
    if (degrees == 360 or degrees == -360)
        return .{ @abs(hw), @abs(hh) };
    if (degrees == 90 or degrees == -90 or degrees == 270 or degrees == -270)
        return .{ @abs(hh), @abs(hw) };
    const r = rotate(hw, hh, degrees);
    const q = rotate(hw, -hh, degrees);
    return .{ @max(@abs(r[0]), @abs(q[0])), @max(@abs(r[1]), @abs(q[1])) };
}

/// How deeply two oriented rectangles interpenetrate, and a point inside the
/// region they share.
pub const Penetration = struct { depth: f64, x: f64, y: f64 };

/// Signed area of the triangle (e0, e1, p) — its SIGN says which side of the
/// line e0→e1 the point falls on, whichever way the edge is wound.
fn side(e0: [2]f64, e1: [2]f64, p: [2]f64) f64 {
    return (e1[0] - e0[0]) * (p[1] - e0[1]) - (e1[1] - e0[1]) * (p[0] - e0[0]);
}

fn centroid(poly: []const [2]f64) [2]f64 {
    var sx: f64 = 0;
    var sy: f64 = 0;
    for (poly) |p| {
        sx += p[0];
        sy += p[1];
    }
    const n: f64 = @floatFromInt(poly.len);
    return .{ sx / n, sy / n };
}

/// The extent of `r`'s corners along the unit direction (ax, ay): {min, max}.
fn project(r: [4][2]f64, ax: f64, ay: f64) [2]f64 {
    var lo = std.math.inf(f64);
    var hi = -std.math.inf(f64);
    for (r) |p| {
        const d = p[0] * ax + p[1] * ay;
        lo = @min(lo, d);
        hi = @max(hi, d);
    }
    return .{ lo, hi };
}

/// Where segment q→p crosses the line e0→e1, by the ratio of the two endpoints'
/// signed areas. Called only when they straddle it, so the denominator is
/// non-zero.
fn lineCross(q: [2]f64, p: [2]f64, e0: [2]f64, e1: [2]f64) [2]f64 {
    const sq = side(e0, e1, q);
    const sp = side(e0, e1, p);
    const t = sq / (sq - sp);
    return .{ q[0] + (p[0] - q[0]) * t, q[1] + (p[1] - q[1]) * t };
}

/// Sutherland–Hodgman clip of the convex polygon `in` against the half-plane of
/// edge e0→e1 that holds `ref`. Writes into `out` and returns its length;
/// clipping a quad by four half-planes tops out at eight vertices.
fn clipHalfPlane(in: []const [2]f64, out: *[8][2]f64, e0: [2]f64, e1: [2]f64, ref: [2]f64) usize {
    const sref = side(e0, e1, ref);
    var n: usize = 0;
    var j: usize = in.len - 1;
    for (in, 0..) |p, k| {
        const q = in[j];
        const keep_p = side(e0, e1, p) * sref >= 0;
        const keep_q = side(e0, e1, q) * sref >= 0;
        if (keep_p != keep_q and n < out.len) {
            out[n] = lineCross(q, p, e0, e1);
            n += 1;
        }
        if (keep_p and n < out.len) {
            out[n] = p;
            n += 1;
        }
        j = k;
    }
    return n;
}

/// The region two convex quads share, as up to eight vertices, or an empty
/// slice when they are disjoint.
fn quadIntersection(a: [4][2]f64, b: [4][2]f64, buf: *[8][2]f64, scratch: *[8][2]f64) []const [2]f64 {
    var cur: []const [2]f64 = a[0..];
    const ref = centroid(b[0..]);
    var into = buf;
    var spare = scratch;
    for (0..4) |i| {
        const n = clipHalfPlane(cur, into, b[i], b[(i + 1) % 4], ref);
        if (n == 0) return &.{};
        cur = into[0..n];
        const swap = into;
        into = spare;
        spare = swap;
    }
    return cur;
}

/// Do two ORIENTED rectangles interpenetrate, and if so by how much and where?
/// Null covers both disjoint and exactly touching.
///
/// Corners come in around each rectangle, so consecutive pairs are its edges
/// and a rectangle contributes only two separating-axis candidates (the other
/// two edges are parallel). Depth is the shallowest overlap over those axes —
/// the distance one part would have to move to come clear — and the point is
/// the centroid of the region they actually share, so a caller drawing a marker
/// puts it inside the clash rather than between the two centres.
///
/// This is the whole reason to have it: a rectangle's axis-aligned bounding box
/// grows by up to √2 per axis off a quarter turn, so two parts a hand's breadth
/// apart on the diagonal read as overlapping when only their boxes do.
pub fn obbPenetration(a: [4][2]f64, b: [4][2]f64) ?Penetration {
    var depth = std.math.inf(f64);
    for ([_][4][2]f64{ a, b }) |r| {
        for (0..2) |e| {
            const ex = r[e + 1][0] - r[e][0];
            const ey = r[e + 1][1] - r[e][1];
            const len = std.math.hypot(ex, ey);
            if (len < 1e-12) continue;
            const pa = project(a, ex / len, ey / len);
            const pb = project(b, ex / len, ey / len);
            const overlap = @min(pa[1], pb[1]) - @max(pa[0], pb[0]);
            if (overlap <= 0) return null;
            depth = @min(depth, overlap);
        }
    }
    if (!std.math.isFinite(depth)) return null;
    var buf: [8][2]f64 = undefined;
    var scratch: [8][2]f64 = undefined;
    const shared = quadIntersection(a, b, &buf, &scratch);
    // A separating axis already proved they overlap, so an empty clip can only
    // be a degenerate rectangle; the midpoint of the two centres is the best
    // point left to name.
    const at = if (shared.len > 0) centroid(shared) else centroid(&[_][2]f64{ centroid(a[0..]), centroid(b[0..]) });
    return .{ .depth = depth, .x = at[0], .y = at[1] };
}

/// The same rectangle moved `d` along both axes.
fn slid(r: [4][2]f64, d: f64) [4][2]f64 {
    var out: [4][2]f64 = undefined;
    for (r, 0..) |p, i| out[i] = .{ p[0] + d, p[1] + d };
    return out;
}

// spec: placement/pose_math - two oriented rectangles report the penetration and a point inside the region they share, and none at all when a separating axis exists
test "oriented-rectangle penetration separates what the bounding boxes cannot" {
    // Two 4 × 1 mm rectangles lying end to end along the 45-degree diagonal.
    // Each one's bounding box is 3.536 mm square, so the boxes always overlap
    // long after the rectangles have parted.
    const half = @sqrt(0.5);
    const a = [4][2]f64{ .{ -2 * half + 0.5 * half, -2 * half - 0.5 * half }, .{ 2 * half + 0.5 * half, 2 * half - 0.5 * half }, .{ 2 * half - 0.5 * half, 2 * half + 0.5 * half }, .{ -2 * half - 0.5 * half, -2 * half + 0.5 * half } };

    // Centres 4.5 mm apart along that diagonal: 0.5 mm of clear board between
    // two 4 mm rectangles, while their boxes still overlap by 0.354 mm.
    try std.testing.expectEqual(@as(?Penetration, null), obbPenetration(a, slid(a, 4.5 * half)));

    // Centres 3 mm apart: 1 mm of real interpenetration, centred at 1.5 mm
    // along the diagonal from the first rectangle's own centre.
    const hit = obbPenetration(a, slid(a, 3.0 * half)).?;
    try std.testing.expectApproxEqAbs(@as(f64, 1), hit.depth, 1e-9);
    try std.testing.expectApproxEqAbs(1.5 * half, hit.x, 1e-9);
    try std.testing.expectApproxEqAbs(1.5 * half, hit.y, 1e-9);
}

// spec: placement/pose_math - arbitrary-angle pose math keeps exact right angles and bounds a 45-degree rectangle
test "pose math handles right-angle and 45-degree transforms" {
    try std.testing.expectEqual([2]f64{ 0, 1 }, rotate(1, 0, 90));
    const root_half = @sqrt(0.5);
    const p = rotate(1, 0, 45);
    try std.testing.expectApproxEqAbs(root_half, p[0], 1e-12);
    try std.testing.expectApproxEqAbs(root_half, p[1], 1e-12);
    const ext = aabbHalf(2, 1, 45);
    try std.testing.expectApproxEqAbs(3 * root_half, ext[0], 1e-12);
    try std.testing.expectApproxEqAbs(3 * root_half, ext[1], 1e-12);
}
