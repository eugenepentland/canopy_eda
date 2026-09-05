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

/// Degenerate-geometry floor for the fillet solve: a leg length (mm), a sine,
/// a half-angle tangent or a sweep overshoot (radians) below it is rounding
/// noise, and the corner has no fillet to build.
const geom_eps: f64 = 1e-6;

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
    if (l1 < geom_eps or l2 < geom_eps) return null;
    const ux = x1 / l1;
    const uy = y1 / l1;
    const vx = x2 / l2;
    const vy = y2 / l2;
    const dot = std.math.clamp(ux * vx + uy * vy, -1, 1);
    const cross = ux * vy - uy * vx;
    if (@abs(cross) < geom_eps or dot < -0.995) return null;
    const tangent = @tan(std.math.acos(dot) / 2);
    if (!(tangent > geom_eps)) return null;
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
    if (@abs(sweep) > std.math.pi + geom_eps) return null;
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

// ── Declared-vs-saved drift ─────────────────────────────────────────────────
//
// ONE predicate answers "did this board's outline drift from its source?", and
// every surface that reports drift calls it: `fab_readiness`'s `outline-drift`
// release finding and the board-review mechanical summary. They were once two
// hand-written comparisons — one dimensions-only, one dimensions-and-shape —
// which is how the board-a base board came to read `matches` on the review
// document and `outline-drift` on the release report at the same moment.

/// Fabrication tolerance (mm) for every declared-vs-saved outline comparison.
pub const drift_tolerance_mm: f64 = 0.01;

/// Hex characters in the outline digest an `(outline-approved "…")` clause
/// pins: enough that no two board profiles collide, few enough to read off a
/// finding message and paste into a design source by hand.
pub const digest_len: usize = 16;

/// The lowercase hex digest identifying one saved outline profile.
pub const Digest = [digest_len]u8;

/// Domain separator, so an outline digest can never equal some other
/// truncated SHA-256 this toolchain prints.
const digest_domain = "netlisp-board-outline-v1\n";

/// What the design source declares about its board outline: the `(board …)`
/// form's geometry plus the author's explicit acceptance of a saved profile.
pub const Declared = struct {
    /// `(size W H)` in mm. Zero ⇒ nothing declared, nothing to compare.
    w: f64 = 0,
    h: f64 = 0,
    /// `(corner-radius R)` in mm; 0 = square corners.
    corner_radius: f64 = 0,
    /// The digest pinned by `(outline-approved "…")`; empty ⇒ unapproved.
    /// An approval covers the PROFILE only — `(size W H)` is still compared,
    /// so the declared size stays meaningful for docs and mechanical tables.
    approved: []const u8 = "",

    /// True when the source declares an outline worth comparing against.
    pub fn present(self: Declared) bool {
        return self.w > 0 and self.h > 0;
    }
};

/// The outline a selected layout actually saved: the bbox rectangle every
/// consumer derives, plus the exact profile when it is not a plain rectangle.
pub const Saved = struct {
    rect: optimizer.BoardRect,
    poly: ?[]const [2]f64 = null,
    arcs: []const optimizer.BoardArc = &.{},
};

/// How the saved outline stands against the declaration.
pub const Verdict = enum {
    /// No declared outline, or no saved outline — nothing was compared.
    not_compared,
    /// Dimensions and profile both match the declaration.
    matches,
    /// The profile is not the declared rectangle, but the source pinned this
    /// exact profile with `(outline-approved …)`, and the size still matches.
    approved,
    /// The saved bbox differs from the declared `(size W H)`.
    dimensions,
    /// The size matches but the profile is neither the declared rectangle nor
    /// an approved one.
    shape,
    /// Both the size and the profile disagree.
    dimensions_and_shape,
    /// An `(outline-approved …)` clause pins a digest this outline no longer
    /// has: the approval is stale and says nothing about what was saved.
    stale_approval,

    /// True for every verdict a fabrication release must block on.
    pub fn drifted(self: Verdict) bool {
        return switch (self) {
            .not_compared, .matches, .approved => false,
            .dimensions, .shape, .dimensions_and_shape, .stale_approval => true,
        };
    }

    /// Summary-table wording: what drifted, not merely that something did.
    pub fn label(self: Verdict) []const u8 {
        return switch (self) {
            .not_compared => "not compared",
            .matches => "matches",
            .approved => "approved shape",
            .dimensions => "DRIFT (size)",
            .shape => "DRIFT (shape)",
            .dimensions_and_shape => "DRIFT (size + shape)",
            .stale_approval => "DRIFT (stale approval)",
        };
    }
};

/// One outline comparison: the verdict plus the saved profile's digest — the
/// exact string an `(outline-approved …)` clause has to pin, so the author
/// never has to go looking for it.
pub const Drift = struct {
    verdict: Verdict = .not_compared,
    /// All-zero when nothing was compared.
    digest: Digest = @splat('0'),
};

/// Whether an approval clause applies to the outline in hand.
const Approval = enum { none, honored, stale };

/// THE declared-vs-saved outline predicate. Dimensions are always compared
/// against `(size W H)`; the profile matches when it is the declared
/// rectangle (optionally filleted by `(corner-radius R)`) or when the source
/// pinned this exact profile's digest.
pub fn compare(
    alloc: std.mem.Allocator,
    declared: Declared,
    saved: ?Saved,
) std.mem.Allocator.Error!Drift {
    const s = saved orelse return .{};
    if (!declared.present()) return .{};
    const d = try digest(alloc, s);
    const approval = approvalOf(declared.approved, d);
    if (approval == .stale) return .{ .verdict = .stale_approval, .digest = d };
    const sized = @abs(s.rect.w - declared.w) <= drift_tolerance_mm and
        @abs(s.rect.h - declared.h) <= drift_tolerance_mm;
    const shaped = approval == .honored or try declaredShape(alloc, declared, s);
    return .{ .digest = d, .verdict = if (!sized and !shaped)
        .dimensions_and_shape
    else if (!sized)
        .dimensions
    else if (!shaped)
        .shape
    else if (approval == .honored)
        .approved
    else
        .matches };
}

fn approvalOf(pinned: []const u8, actual: Digest) Approval {
    if (pinned.len == 0) return .none;
    return if (std.ascii.eqlIgnoreCase(pinned, &actual)) .honored else .stale;
}

/// True when the saved profile is exactly the shape `(board …)` describes.
fn declaredShape(
    alloc: std.mem.Allocator,
    declared: Declared,
    saved: Saved,
) std.mem.Allocator.Error!bool {
    const corners = rectCorners(saved.rect);
    if (!(declared.corner_radius > 0)) {
        return saved.arcs.len == 0 and
            (saved.poly == null or polygonEquivalent(saved.poly.?, &corners, drift_tolerance_mm));
    }
    const radii: [4]f64 = @splat(declared.corner_radius);
    const expected = try filletPath(alloc, &corners, &radii, drift_tolerance_mm);
    const poly = saved.poly orelse return false;
    return polygonEquivalent(poly, expected.poly, drift_tolerance_mm) and
        arcsEquivalent(saved.arcs, expected.arcs, drift_tolerance_mm);
}

/// The `outline-drift` finding text for a drifted comparison. Every variant
/// names the way out: an unapproved profile carries the digest to paste, a
/// wrong size says that approving cannot fix a size, and a stale pin names
/// both the pinned and the current digest.
pub fn driftMessage(
    alloc: std.mem.Allocator,
    declared: Declared,
    saved: Saved,
    drift: Drift,
) std.mem.Allocator.Error![]const u8 {
    const pinned = declared.approved[0..@min(declared.approved.len, 64)];
    if (drift.verdict == .stale_approval) return std.fmt.allocPrint(
        alloc,
        "saved fabrication outline no longer matches its (outline-approved \"{s}\") pin: this outline is " ++
            "{d:.3} x {d:.3} mm with {d} native arcs and digests to \"{s}\" — re-approve with that digest " ++
            "if the change is intended",
        .{ pinned, saved.rect.w, saved.rect.h, saved.arcs.len, &drift.digest },
    );
    const tail: []const u8 = switch (drift.verdict) {
        .shape => try std.fmt.allocPrint(
            alloc,
            "; if that profile is the approved one, pin it with (outline-approved \"{s}\") under (board …)",
            .{&drift.digest},
        ),
        .dimensions, .dimensions_and_shape => "; (outline-approved …) approves a profile, never a size, " ++
            "so correct (size W H) first",
        else => "",
    };
    return std.fmt.allocPrint(
        alloc,
        "saved fabrication outline is {d:.3} x {d:.3} mm with {d} native arcs, but source declares " ++
            "{d:.3} x {d:.3} mm and {d:.3} mm corner radius{s}",
        .{ saved.rect.w, saved.rect.h, saved.arcs.len, declared.w, declared.h, declared.corner_radius, tail },
    );
}

/// Canonical digest of a saved outline's PROFILE.
///
/// Three deliberate normalizations make the value a property of the shape
/// rather than of the file it came out of: coordinates are taken relative to
/// the outline's own bounding box (a layout that shifts inside the board
/// frame keeps its digest, and the declared size is compared separately);
/// they are quantized to whole micrometres (re-serializing 2.18 as
/// 2.1799999999999997 digests identically); and the profile is the NOMINAL
/// contour — native arcs plus the straight edges between them — so changing
/// the fillet sagitta cannot invalidate every pinned approval in the corpus.
/// A real geometry change (a moved notch, a different corner radius) does
/// change it, which is the whole point of pinning one.
pub fn digest(alloc: std.mem.Allocator, saved: Saved) std.mem.Allocator.Error!Digest {
    const corners = rectCorners(saved.rect);
    const poly: []const [2]f64 = saved.poly orelse &corners;
    const bb = bboxRect(poly);
    const items = try profileItems(alloc, poly, saved.arcs);
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    hash.update(digest_domain);
    if (items.len > 0) {
        const tokens = try alloc.alloc([]const u8, items.len);
        for (items, tokens) |item, *token| token.* = try itemToken(alloc, item, bb.minx, bb.miny);
        const start = smallestToken(tokens);
        for (0..tokens.len) |k| {
            hash.update(tokens[(start + k) % tokens.len]);
            hash.update("\n");
        }
    }
    var full: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    hash.final(&full);
    const hex = std.fmt.bytesToHex(full, .lower);
    var short: Digest = undefined;
    @memcpy(&short, hex[0..digest_len]);
    return short;
}

fn rectCorners(r: optimizer.BoardRect) [4][2]f64 {
    return .{
        .{ r.minx, r.miny },
        .{ r.minx + r.w, r.miny },
        .{ r.minx + r.w, r.miny + r.h },
        .{ r.minx, r.miny + r.h },
    };
}

/// One piece of the nominal contour: a straight edge or a native arc.
const ProfileItem = union(enum) {
    line: [2][2]f64,
    arc: optimizer.BoardArc,
};

/// Tolerance (mm) for deciding a tessellated polygon edge belongs to a native
/// arc: far below the coarsest chord a 0.01 mm sagitta produces, far above
/// any sidecar coordinate rounding.
const arc_owner_tolerance_mm: f64 = 1e-3;

/// A chord endpoint belongs to an arc when it lies on the arc's span OR is
/// one of its two ends. The explicit endpoint case matters: at exactly the
/// start angle `arcOwnsSegment`'s modular sweep test sits on a knife edge, so
/// a coordinate rounded a nanometre the wrong way would otherwise split the
/// first chord of a fillet off into a phantom straight — and change a digest
/// that nothing about the board had changed.
fn arcHasPoint(arc: optimizer.BoardArc, p: [2]f64) bool {
    return pointNear(p, arc.p1, arc_owner_tolerance_mm) or
        pointNear(p, arc.p2, arc_owner_tolerance_mm) or
        arcOwnsSegment(arc, p, p, arc_owner_tolerance_mm);
}

fn arcOwnerOf(arcs: []const optimizer.BoardArc, a: [2]f64, b: [2]f64) ?usize {
    for (arcs, 0..) |arc, i| {
        if (arcHasPoint(arc, a) and arcHasPoint(arc, b)) return i;
    }
    return null;
}

/// The nominal contour in traversal order: every run of tessellated chords is
/// folded back into the single arc that owns it, and every remaining edge is
/// its own straight item.
fn profileItems(
    alloc: std.mem.Allocator,
    poly: []const [2]f64,
    arcs: []const optimizer.BoardArc,
) std.mem.Allocator.Error![]const ProfileItem {
    const n = poly.len;
    if (n < 3) return &.{};
    const owners = try alloc.alloc(?usize, n);
    for (owners, 0..) |*owner, i| owner.* = arcOwnerOf(arcs, poly[i], poly[(i + 1) % n]);
    var items: std.ArrayList(ProfileItem) = .empty;
    var previous: ?usize = null;
    const start = profileStart(owners);
    for (0..n) |k| {
        const i = (start + k) % n;
        if (owners[i]) |owner| {
            const continues = previous != null and previous.? == owner;
            if (!continues) try items.append(alloc, .{ .arc = arcs[owner] });
        } else {
            try items.append(alloc, .{ .line = .{ poly[i], poly[(i + 1) % n] } });
        }
        previous = owners[i];
    }
    return items.toOwnedSlice(alloc);
}

/// An edge index where one contour item ends and the next begins, so the
/// traversal never splits one arc's chord run across the wrap.
fn profileStart(owners: []const ?usize) usize {
    for (owners, 0..) |owner, i| if (owner == null) return i;
    for (owners, 0..) |owner, i| {
        const previous = owners[(i + owners.len - 1) % owners.len];
        if (previous == null or owner.? != previous.?) return i;
    }
    return 0;
}

/// Quantize a millimetre coordinate to whole micrometres.
fn micron(v: f64) i64 {
    return numeric.checkedInt(i64, v * 1000) orelse 0;
}

fn itemToken(
    alloc: std.mem.Allocator,
    item: ProfileItem,
    ox: f64,
    oy: f64,
) std.mem.Allocator.Error![]const u8 {
    return switch (item) {
        .line => |seg| std.fmt.allocPrint(alloc, "L {d} {d} {d} {d}", .{
            micron(seg[0][0] - ox), micron(seg[0][1] - oy),
            micron(seg[1][0] - ox), micron(seg[1][1] - oy),
        }),
        .arc => |arc| std.fmt.allocPrint(alloc, "A {d} {d} {d} {d} {d} {d}", .{
            micron(arc.p1[0] - ox), micron(arc.p1[1] - oy),
            micron(arc.pm[0] - ox), micron(arc.pm[1] - oy),
            micron(arc.p2[0] - ox), micron(arc.p2[1] - oy),
        }),
    };
}

/// Rotate the contour to start at its smallest token, so which vertex a
/// writer happened to start the polygon at is not part of the identity.
fn smallestToken(tokens: []const []const u8) usize {
    var best: usize = 0;
    for (tokens, 0..) |token, i| {
        if (std.mem.order(u8, token, tokens[best]) == .lt) best = i;
    }
    return best;
}

fn pointNear(a: [2]f64, b: [2]f64, tolerance: f64) bool {
    return @abs(a[0] - b[0]) <= tolerance and @abs(a[1] - b[1]) <= tolerance;
}

/// Same closed vertex ring up to start offset and winding direction.
fn polygonEquivalent(a: []const [2]f64, b: []const [2]f64, tolerance: f64) bool {
    if (a.len != b.len or a.len == 0) return false;
    for (b, 0..) |candidate, offset| {
        if (!pointNear(a[0], candidate, tolerance)) continue;
        var forward = true;
        var reverse = true;
        for (a, 0..) |point, index| {
            if (!pointNear(point, b[(offset + index) % b.len], tolerance)) forward = false;
            if (!pointNear(point, b[(offset + b.len - index) % b.len], tolerance)) reverse = false;
        }
        if (forward or reverse) return true;
    }
    return false;
}

fn arcNear(a: optimizer.BoardArc, b: optimizer.BoardArc, tolerance: f64) bool {
    const forward = pointNear(a.p1, b.p1, tolerance) and pointNear(a.pm, b.pm, tolerance) and pointNear(a.p2, b.p2, tolerance);
    const reverse = pointNear(a.p1, b.p2, tolerance) and pointNear(a.pm, b.pm, tolerance) and pointNear(a.p2, b.p1, tolerance);
    return forward or reverse;
}

/// Same arc ring up to start offset and winding direction.
fn arcsEquivalent(a: []const optimizer.BoardArc, b: []const optimizer.BoardArc, tolerance: f64) bool {
    if (a.len != b.len or a.len == 0) return false;
    for (b, 0..) |candidate, offset| {
        if (!arcNear(a[0], candidate, tolerance)) continue;
        var forward = true;
        var reverse = true;
        for (a, 0..) |arc, index| {
            if (!arcNear(arc, b[(offset + index) % b.len], tolerance)) forward = false;
            if (!arcNear(arc, b[(offset + b.len - index) % b.len], tolerance)) reverse = false;
        }
        if (forward or reverse) return true;
    }
    return false;
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

/// Board-A-class notched outline: a rectangle whose bottom edge carries a
/// rectangular recess, big fillets on the board corners and small ones in the
/// recess — the profile `(size W H)` plus one `(corner-radius R)` cannot
/// express, and therefore the one an approval clause exists for.
const notch_pts = [_][2]f64{
    .{ 0, 0 },   .{ 40, 0 },  .{ 40, 20 }, .{ 25, 20 },
    .{ 25, 14 }, .{ 15, 14 }, .{ 15, 20 }, .{ 0, 20 },
};
const notch_radii = [_]f64{ 2, 2, 2, 0.9, 0.9, 0.9, 0.9, 2 };

/// Re-serialize the tessellated polygon with sub-micrometre coordinate noise
/// while the native arcs stay exact — the shape a sidecar round-trip leaves.
fn jitteredPoly(alloc: std.mem.Allocator, saved: Saved, noise: f64) !Saved {
    const poly = try alloc.dupe([2]f64, saved.poly.?);
    for (poly) |*p| {
        p[0] += noise;
        p[1] -= noise;
    }
    return .{ .rect = bboxRect(poly), .poly = poly, .arcs = saved.arcs };
}

/// The same closed contour written starting at a different vertex.
fn rotatedOutline(alloc: std.mem.Allocator, saved: Saved, by: usize) !Saved {
    const poly = try alloc.alloc([2]f64, saved.poly.?.len);
    for (poly, 0..) |*p, i| p.* = saved.poly.?[(i + by) % poly.len];
    const arcs = try alloc.alloc(optimizer.BoardArc, saved.arcs.len);
    for (arcs, 0..) |*arc, i| arc.* = saved.arcs[(i + by) % arcs.len];
    return .{ .rect = saved.rect, .poly = poly, .arcs = arcs };
}

/// The recess cut `deeper` mm further into the board — a real geometry change.
fn deeperNotch(alloc: std.mem.Allocator, deeper: f64) !Saved {
    const pts = try alloc.dupe([2]f64, &notch_pts);
    pts[4][1] -= deeper;
    pts[5][1] -= deeper;
    const filleted = try filletPath(alloc, pts, &notch_radii, 0.01);
    return .{ .rect = bboxRect(filleted.poly), .poly = filleted.poly, .arcs = filleted.arcs };
}

fn notchedOutline(alloc: std.mem.Allocator, dx: f64, dy: f64, sagitta: f64) !Saved {
    const pts = try alloc.dupe([2]f64, &notch_pts);
    for (pts) |*p| {
        p[0] += dx;
        p[1] += dy;
    }
    const filleted = try filletPath(alloc, pts, &notch_radii, sagitta);
    return .{ .rect = bboxRect(filleted.poly), .poly = filleted.poly, .arcs = filleted.arcs };
}

// spec: placement/outline - the saved-outline digest identifies the nominal profile, surviving float jitter, arc tessellation, start vertex and board position while a moved notch changes it
test "the outline digest is canonical over the profile, not its serialization" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const alloc = arena_inst.allocator();

    const saved = try notchedOutline(alloc, 0, 0, 0.01);
    try testing.expectEqual(@as(usize, notch_pts.len), saved.arcs.len);
    const base = try digest(alloc, saved);
    try testing.expectEqual(digest_len, base.len);

    // Sub-micrometre float jitter — a re-serialized 2.18 coming back as
    // 2.1799999999999997 — is formatting, not geometry.
    const jittered = try jitteredPoly(alloc, saved, 1e-10);
    try testing.expectEqualSlices(u8, &base, &(try digest(alloc, jittered)));

    // A finer fillet tessellation is the same board: the digest is taken over
    // native arcs plus the straights between them, never over the chords.
    const finer = try notchedOutline(alloc, 0, 0, 0.002);
    try testing.expect(finer.poly.?.len > saved.poly.?.len);
    try testing.expectEqualSlices(u8, &base, &(try digest(alloc, finer)));

    // Nor is the vertex a writer happened to start at part of the identity.
    const rotated = try rotatedOutline(alloc, saved, 7);
    try testing.expectEqualSlices(u8, &base, &(try digest(alloc, rotated)));

    // Nor where the board sits in the layout frame — the declared size is
    // compared on its own, so the digest is the shape alone.
    const moved = try notchedOutline(alloc, 7.5, -3.25, 0.01);
    try testing.expectEqualSlices(u8, &base, &(try digest(alloc, moved)));

    // Real geometry, however, does change it: a recess 0.5 mm deeper.
    const changed = try digest(alloc, try deeperNotch(alloc, 0.5));
    try testing.expect(!std.mem.eql(u8, &base, &changed));
}

// spec: placement/outline - the shared drift predicate always compares the declared dimensions, accepts a profile the source pinned by digest, and reports an outdated pin as a stale approval
test "compare approves a pinned profile, keeps the size check, and flags a stale pin" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const alloc = arena_inst.allocator();
    const saved = try notchedOutline(alloc, 0, 0, 0.01);
    const declared: Declared = .{ .w = 40, .h = 20 };

    // Unapproved, the notch is shape drift — and the message carries the exact
    // digest to paste back into the source, so closing the loop is copy-paste.
    const unapproved = try compare(alloc, declared, saved);
    try testing.expectEqual(Verdict.shape, unapproved.verdict);
    try testing.expect(unapproved.verdict.drifted());
    const open_msg = try driftMessage(alloc, declared, saved, unapproved);
    try testing.expect(std.mem.indexOf(u8, open_msg, &unapproved.digest) != null);
    try testing.expect(std.mem.indexOf(u8, open_msg, "(outline-approved") != null);

    // Pinned, that same profile is clean.
    const pinned: Declared = .{ .w = 40, .h = 20, .approved = &unapproved.digest };
    const honored = try compare(alloc, pinned, saved);
    try testing.expectEqual(Verdict.approved, honored.verdict);
    try testing.expect(!honored.verdict.drifted());

    // The approval covers the profile and never the size: a board that is not
    // the declared 40 mm wide still drifts with the pin in place.
    const resized: Declared = .{ .w = 41, .h = 20, .approved = &unapproved.digest };
    try testing.expectEqual(Verdict.dimensions, (try compare(alloc, resized, saved)).verdict);

    // A pin that no longer matches is its own, distinctly-worded finding
    // naming both digests — never a silent approval of unseen geometry.
    const stale_pin = "0123456789abcdef";
    const stale_decl: Declared = .{ .w = 40, .h = 20, .approved = stale_pin };
    const stale = try compare(alloc, stale_decl, saved);
    try testing.expectEqual(Verdict.stale_approval, stale.verdict);
    const stale_msg = try driftMessage(alloc, stale_decl, saved, stale);
    try testing.expect(std.mem.indexOf(u8, stale_msg, stale_pin) != null);
    try testing.expect(std.mem.indexOf(u8, stale_msg, &stale.digest) != null);
    try testing.expect(std.mem.indexOf(u8, stale_msg, "no longer matches") != null);

    // Plain rectangles and RF-style rounded rectangles are untouched.
    const rect: Saved = .{ .rect = .{ .minx = 0, .miny = 0, .w = 81, .h = 24.8 } };
    try testing.expectEqual(Verdict.matches, (try compare(alloc, .{ .w = 81, .h = 24.8 }, rect)).verdict);
    const rf_corners = [_][2]f64{ .{ 0, 0 }, .{ 81, 0 }, .{ 81, 24.8 }, .{ 0, 24.8 } };
    const rf_radii: [4]f64 = @splat(2);
    const rf = try filletPath(alloc, &rf_corners, &rf_radii, 0.01);
    const rf_saved: Saved = .{ .rect = rect.rect, .poly = rf.poly, .arcs = rf.arcs };
    const rf_declared: Declared = .{ .w = 81, .h = 24.8, .corner_radius = 2 };
    try testing.expectEqual(Verdict.matches, (try compare(alloc, rf_declared, rf_saved)).verdict);

    // Nothing declared, or nothing saved, is compared rather than guessed at.
    try testing.expectEqual(Verdict.not_compared, (try compare(alloc, .{}, saved)).verdict);
    try testing.expectEqual(Verdict.not_compared, (try compare(alloc, declared, null)).verdict);
}
