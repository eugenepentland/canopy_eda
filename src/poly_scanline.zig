//! Even/odd scanline crossing of a simple polygon — the one primitive behind
//! "give me a point that is actually ON this pad's copper".
//!
//! Two callers want it. `placement/pad_shape.copperAnchor` picks the route
//! target and connectivity anchor for a custom pad; `export_kicad_footprint`
//! picks the anchor rectangle a KiCad custom pad is defined relative to. A
//! concave pad (a thermal/EP land with a relief notch) puts its bounding-box
//! centre in empty space, so both fall back to the widest copper interval on a
//! horizontal scanline. If the two disagreed, the exported footprint's anchor
//! and the router's target for the same pad would be different points.
//!
//! Only the interval differs from the two former copies: `pad_shape` wanted the
//! span, the exporter wanted its midpoint. That is one `+ 2` apart, not a
//! second algorithm.

const std = @import("std");

/// Footprint outlines are simplified before reaching here; this generous fixed
/// bound avoids plumbing an allocator through every pad-target query while
/// still covering raw small custom polygons. A polygon that would exceed it is
/// refused (null) rather than silently truncated to a wrong interval.
const max_crossings: usize = 512;

/// The widest even/odd-filled interval `[x0, x1]` where the horizontal line
/// `y` crosses `poly`, or null when the scanline misses the polygon (fewer
/// than two crossings) or the polygon is too complex for the fixed bound.
///
/// `poly` is a closed simple polygon given as its vertices; the closing edge
/// from the last vertex back to the first is implied.
pub fn widestInterval(poly: []const [2]f64, y: f64) ?[2]f64 {
    if (poly.len < 2) return null;
    var intersections: [max_crossings]f64 = undefined;
    var count: usize = 0;
    var previous = poly[poly.len - 1];
    for (poly) |point| {
        if ((previous[1] > y) != (point[1] > y)) {
            if (count == intersections.len) return null;
            intersections[count] = previous[0] + (y - previous[1]) /
                (point[1] - previous[1]) * (point[0] - previous[0]);
            count += 1;
        }
        previous = point;
    }
    if (count < 2) return null;
    std.mem.sort(f64, intersections[0..count], {}, std.sort.asc(f64));
    var best: ?[2]f64 = null;
    var i: usize = 0;
    while (i + 1 < count) : (i += 2) {
        const candidate = [2]f64{ intersections[i], intersections[i + 1] };
        if (best == null or candidate[1] - candidate[0] > best.?[1] - best.?[0]) best = candidate;
    }
    return best;
}

/// The midpoint of `widestInterval`, as an `(x, y)` point on the copper.
pub fn widestMidpoint(poly: []const [2]f64, y: f64) ?[2]f64 {
    const span = widestInterval(poly, y) orelse return null;
    return .{ (span[0] + span[1]) / 2, y };
}

// spec: placement/pad_shape - The widest scanline interval picks the larger copper lobe of a notched pad
test "widestInterval picks the larger lobe and its midpoint" {
    const testing = std.testing;
    // A U-shaped land: two vertical lobes joined at the bottom. At y = 3 the
    // scanline crosses four times; the right lobe (6..10) is wider than the
    // left (0..2), so it wins and the box centre (x = 5) is NOT on copper.
    const u_pad = [_][2]f64{
        .{ 0, 0 }, .{ 10, 0 }, .{ 10, 6 }, .{ 6, 6 },
        .{ 6, 1 }, .{ 2, 1 },  .{ 2, 6 },  .{ 0, 6 },
    };
    const span = widestInterval(&u_pad, 3).?;
    try testing.expectApproxEqAbs(@as(f64, 6), span[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 10), span[1], 1e-9);
    const mid = widestMidpoint(&u_pad, 3).?;
    try testing.expectApproxEqAbs(@as(f64, 8), mid[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 3), mid[1], 1e-9);
    // Below the notch the land is solid, so the whole width is one interval.
    const solid = widestInterval(&u_pad, 0.5).?;
    try testing.expectApproxEqAbs(@as(f64, 0), solid[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 10), solid[1], 1e-9);
    // A scanline that misses the polygon has no interval at all.
    try testing.expect(widestInterval(&u_pad, 9) == null);
    try testing.expect(widestMidpoint(&u_pad, -1) == null);
}
