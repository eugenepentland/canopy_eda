//! Non-terminal land overlap — copper of net X lying on a net-X pad it is not
//! CONNECTING to.
//!
//! The rule, in the board owner's own words (2026-08-12):
//!
//! > "there are also pins like 18 where there is a trace that overlaps with a
//! >  pad but the end of that trace segment doesn't go to the center point of
//! >  the pad so that should be invalid. I don't want extra copper in between
//! >  my qfn pads that could short."
//!
//! Electrically such copper is nothing — a track anywhere on a land is the same
//! node, and every clearance rule stays silent because the two objects share a
//! net. Manufacturably it is the opposite of nothing. Copper that laps a land
//! rather than terminating on it has to have come from somewhere and go
//! somewhere, and on a fine-pitch part the only route out of a land's flank is
//! the 0.2 mm corridor between it and its neighbour. Half a trace width parked
//! in that corridor is solder-bridge bait, and it is invisible to every check
//! this project had: `pad_entry` removes copper lying WHOLLY on a land, and
//! `pad_escape` disciplines the ray a connection LEAVES on, but neither has an
//! opinion about a run that merely crosses a land on its way past.
//!
//! ## The rule, stated geometrically
//!
//! Net-X copper may touch a net-X land ONLY as that land's own connection, and
//! a connection is anchored on the pad's centre. So a run of copper inside a
//! land is legal exactly when it lies on a straight ray through that centre:
//!
//!   1. every vertex strictly inside the run is AT the centre — a connection
//!      that turns while on a land turns on the centre, which is what a hand
//!      router draws when it daisy-chains one net's pads;
//!   2. every segment the run covers is aimed at the centre (its supporting
//!      LINE passes through it) — this is the test rather than "the end point
//!      is the centre" because `pad_entry` deliberately trims a terminal back
//!      to a `stub_mm` stub, which stays on the ray but stops short of the
//!      middle of the land;
//!   3. the run either contains an END of the copper (it terminates here) or
//!      contains the centre itself (it passes through).
//!
//! Anything else — a run that laps a flank, that turns beside the land, or that
//! transits without touching the centre — is a finding.
//!
//! ## Scope, and why it is drawn where it is
//!
//! The measurement is on SWEPT copper (centreline ± half width), because the
//! corridor cares where the copper's EDGE is, not where its middle is: pin 18
//! on straps-synth-lmx2595 ran its centreline exactly along the land's own
//! boundary, so a centreline test scores it zero overlap while a fab sees a
//! full half-width of metal beside the pad.
//!
//! THROUGH-HOLE pads are out of scope, as they are for `pad_entry` and
//! `pad_escape`: the barrel is the connection on every layer, so copper across
//! an annulus is not a lap.
//!
//! A land bigger than `paddle_min_half_mm` in BOTH axes is out of scope too. An
//! exposed thermal paddle is not entered on a ray — nothing anchors on its
//! centre, it is stitched wherever a via lands — and it has no flank corridor of
//! its own: it is the neighbouring lead lands' clearance, which the ordinary
//! foreign-net rules already own, that governs copper beside it.

const std = @import("std");
const pad_shape = @import("pad_shape.zig");

/// How far off the pad's centre a run's aim may sit and still count as that
/// pad's own connection (mm).
///
/// It has to absorb a coordinate that has been through a world→grid→world round
/// trip and the last bits of a float, and it must NOT absorb a real jog: the
/// shapes this rule exists to catch miss the centre by 0.07–0.42 mm on the
/// corpus. 0.02 mm is an order under the narrowest track here (0.1 mm) and well
/// under a fab's registration tolerance, so a run inside it is on the ray as
/// far as anything downstream can tell.
pub const anchor_tol_mm: f64 = 0.02;

/// Half-extent past which a land is a PADDLE rather than a lead land (mm), in
/// BOTH axes.
///
/// 1.5 mm square is larger than any discrete land in this corpus — an 0805's is
/// 1.0 × 1.45 and a 0.5 mm-pitch QFN's is 0.3 × 0.9, so every land a connection
/// actually escapes from stays in scope — and comfortably smaller than the
/// exposed paddle of the parts that have one (straps-synth-lmx2595's LMX2595
/// presents a 4.6 mm square). Past it a land stops being something a ray leaves
/// and becomes a plane a via drops into: nothing anchors on its centre, so the
/// ray rule has nothing to say about it.
pub const paddle_min_half_mm: f64 = 0.75;

const eps: f64 = 1e-9;

/// One pad this rule judges: its land box plus the outline that decides what is
/// really copper.
pub const Land = struct {
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
    poly: []const [2]f64 = &.{},

    /// The anchor every connection to this land starts from. A pad's world box
    /// is built symmetrically about its own centre (`pad_shape`), so the box
    /// centre IS the anchor — the same reading `pad_escape` draws its ray from.
    pub fn centre(self: Land) [2]f64 {
        return .{ (self.x0 + self.x1) / 2, (self.y0 + self.y1) / 2 };
    }

    /// Is this a thermal paddle / plane land rather than a lead land?
    pub fn paddle(self: Land) bool {
        return (self.x1 - self.x0) / 2 >= paddle_min_half_mm and
            (self.y1 - self.y0) / 2 >= paddle_min_half_mm;
    }
};

/// One non-terminal overlap, as a caller reports it.
pub const Finding = struct {
    /// Where the offending copper is, for a marker: the point of the run
    /// closest to the pad centre.
    at: [2]f64,
    /// How much swept copper lies on the land (mm along the centreline).
    overlap_mm: f64,
    /// How far the run's aim misses the pad centre by (mm) — the board owner's
    /// "doesn't go to the center point" measurement. For a run that turns
    /// beside the land this is the offending vertex's distance from the centre;
    /// for one that laps it, the perpendicular offset of its own line.
    miss_mm: f64,
};

/// One offending segment rewritten so every piece of copper that overlaps the
/// land is a centre-anchored connection. The unchanged portions before/after
/// the grown land are retained, while the run across the land is replaced by
/// two rays through its centre.
pub const AnchoredSegment = struct {
    points: [5][2]f64,
    len: usize,
};

fn dist(a: [2]f64, b: [2]f64) f64 {
    return std.math.hypot(b[0] - a[0], b[1] - a[1]);
}

/// The fraction interval of `a`→`b` inside the land grown by `grow`, or null.
/// Liang–Barsky against the land's box, which is the shape the corridor sees
/// (a rounded land's box corner is where the mask relief is, not more copper).
fn clip(land: Land, grow: f64, a: [2]f64, b: [2]f64) ?[2]f64 {
    var t0: f64 = 0;
    var t1: f64 = 1;
    const d = [2]f64{ b[0] - a[0], b[1] - a[1] };
    const edges = [4][2]f64{
        .{ -d[0], a[0] - (land.x0 - grow) },
        .{ d[0], (land.x1 + grow) - a[0] },
        .{ -d[1], a[1] - (land.y0 - grow) },
        .{ d[1], (land.y1 + grow) - a[1] },
    };
    for (edges) |e| {
        if (@abs(e[0]) < eps) {
            if (e[1] < 0) return null;
            continue;
        }
        const r = e[1] / e[0];
        if (e[0] < 0) {
            if (r > t1) return null;
            t0 = @max(t0, r);
        } else {
            if (r < t0) return null;
            t1 = @min(t1, r);
        }
    }
    return if (t1 > t0 + eps) .{ t0, t1 } else null;
}

/// Perpendicular distance from `c` to the infinite line through `p`,`q`.
fn lineOffset(p: [2]f64, q: [2]f64, c: [2]f64) f64 {
    const d = dist(p, q);
    if (d < eps) return dist(p, c);
    return @abs((q[0] - p[0]) * (c[1] - p[1]) - (q[1] - p[1]) * (c[0] - p[0])) / d;
}

/// Distance from `c` to the SEGMENT `p`→`q`.
fn segOffset(p: [2]f64, q: [2]f64, c: [2]f64) f64 {
    const dx = q[0] - p[0];
    const dy = q[1] - p[1];
    const l2 = dx * dx + dy * dy;
    if (l2 < eps) return dist(p, c);
    const t = std.math.clamp(((c[0] - p[0]) * dx + (c[1] - p[1]) * dy) / l2, 0, 1);
    return dist(.{ p[0] + t * dx, p[1] + t * dy }, c);
}

/// One maximal stretch of the polyline inside the grown land, by vertex index:
/// segments `from`..`to` inclusive, entering part-way through `from` and
/// leaving part-way through `to`.
const Run = struct {
    from: usize,
    to: usize,
    /// Does the stretch reach the polyline's own head / tail?
    head: bool,
    tail: bool,
    len: f64,
    /// Closest approach of the stretch to the pad centre.
    near: f64,
    at: [2]f64,
};

/// Walk `pts` against `land` (grown by `half`) and hand each maximal stretch to
/// `sink`. Segments are visited in order, so a stretch is closed the first time
/// a segment does not continue it.
fn runs(land: Land, pts: []const [2]f64, half: f64, out: *std.ArrayList(Run), arena: std.mem.Allocator) std.mem.Allocator.Error!void {
    const c = land.centre();
    var open: ?Run = null;
    for (1..pts.len) |i| {
        const cl = clip(land, half, pts[i - 1], pts[i]);
        if (cl == null) {
            if (open) |r| try out.append(arena, r);
            open = null;
            continue;
        }
        const seg = dist(pts[i - 1], pts[i]);
        const a = at(pts, i, cl.?[0]);
        const b = at(pts, i, cl.?[1]);
        const near = segOffset(a, b, c);
        const piece = seg * (cl.?[1] - cl.?[0]);
        // A stretch continues only if the previous segment left through this
        // one's start — i.e. it ran to the vertex they share.
        const joins = open != null and open.?.to == i - 1 and cl.?[0] <= eps;
        if (joins) {
            var r = open.?;
            r.to = i;
            r.tail = cl.?[1] >= 1 - eps and i == pts.len - 1;
            r.len += piece;
            if (near < r.near) {
                r.near = near;
                r.at = nearestOn(a, b, c);
            }
            open = r;
        } else {
            if (open) |r| try out.append(arena, r);
            open = .{
                .from = i,
                .to = i,
                .head = cl.?[0] <= eps and i == 1,
                .tail = cl.?[1] >= 1 - eps and i == pts.len - 1,
                .len = piece,
                .near = near,
                .at = nearestOn(a, b, c),
            };
        }
    }
    if (open) |r| try out.append(arena, r);
}

fn at(pts: []const [2]f64, i: usize, t: f64) [2]f64 {
    return .{
        pts[i - 1][0] + t * (pts[i][0] - pts[i - 1][0]),
        pts[i - 1][1] + t * (pts[i][1] - pts[i - 1][1]),
    };
}

fn nearestOn(p: [2]f64, q: [2]f64, c: [2]f64) [2]f64 {
    const dx = q[0] - p[0];
    const dy = q[1] - p[1];
    const l2 = dx * dx + dy * dy;
    if (l2 < eps) return p;
    const t = std.math.clamp(((c[0] - p[0]) * dx + (c[1] - p[1]) * dy) / l2, 0, 1);
    return .{ p[0] + t * dx, p[1] + t * dy };
}

/// The worst non-terminal overlap this polyline puts on this land, or null when
/// every stretch of it is the land's own centre-anchored connection.
///
/// `half` is the copper's half width: the test is on the metal a fab plots, not
/// on the centreline a router thinks in.
pub fn offence(
    arena: std.mem.Allocator,
    land: Land,
    pts: []const [2]f64,
    half: f64,
) std.mem.Allocator.Error!?Finding {
    if (pts.len < 2 or land.paddle()) return null;
    var found: std.ArrayList(Run) = .empty;
    try runs(land, pts, half, &found, arena);
    var worst: ?Finding = null;
    for (found.items) |r| {
        const miss = runMiss(land, pts, r) orelse continue;
        const f = Finding{ .at = r.at, .overlap_mm = r.len, .miss_mm = miss };
        if (worst == null or f.miss_mm > worst.?.miss_mm) worst = f;
    }
    return worst;
}

/// How far this stretch misses the pad centre by, or null when it is legal.
fn runMiss(land: Land, pts: []const [2]f64, r: Run) ?f64 {
    const c = land.centre();
    // (1) a vertex strictly inside the stretch must BE the centre.
    var i = r.from;
    var worst: f64 = 0;
    while (i < r.to) : (i += 1) {
        const d = dist(pts[i], c);
        if (d > anchor_tol_mm) worst = @max(worst, d);
    }
    // (2) every segment the stretch covers must be aimed at the centre.
    i = r.from;
    while (i <= r.to) : (i += 1) {
        const off = lineOffset(pts[i - 1], pts[i], c);
        if (off > anchor_tol_mm) worst = @max(worst, off);
    }
    if (worst > 0) return worst;
    // (3) it must terminate here or pass through the centre.
    if (r.head or r.tail or r.near <= anchor_tol_mm) return null;
    return r.near;
}

/// Is ONE segment's swept copper on this land without being aimed at its
/// centre — the graph-free half of the rule?
///
/// The chain-aware `offence` above is what a rewriting pass needs, because it
/// has to tell a terminal that stops short of the centre (legal: `pad_entry`
/// trims every entry back to a stub) from a run that turns beside the land
/// (not). A CHECKER has neither the chain nor the net's copper graph to hand —
/// it is handed a flat list of segments, and it must give the same answer in
/// the browser's wasm build as on the server. So it asks the question that
/// needs neither: is this segment's own LINE aimed at the pad's centre?
///
/// That is the board owner's own wording ("a trace that overlaps with a pad but
/// the end of that trace segment doesn't go to the center point of the pad"),
/// and it is exact on both of the shapes that matter: a stub trimmed back along
/// the ray is still ON the line, so it passes; a leg that laps a flank or turns
/// beside the land is off the line by the width of the corridor it is sitting
/// in, so it fails. What it cannot see — a corner that happens to fall exactly
/// on the ray — is a shape no emitter here draws.
///
/// One family of off-ray copper is exempt: an axis-aligned run whose swept
/// metal stays inside the land's own extent on the axis PERPENDICULAR to its
/// travel — `columnContained` — provided the run also reaches one of its
/// segment's ends inside the grown land (it terminates or turns here rather
/// than flying straight through). Such copper never puts metal beside the
/// land: everything it adds sits over the pad or inside the pad's own column,
/// so the corridor to the neighbouring pin holds nothing the pad itself did
/// not already put there. This is what a hand-drawn entry that misses the
/// centre by a few hundredths looks like, and what a connection to a long
/// connector finger (too narrow to be a `paddle`, far too long for its centre
/// to be the anchor) looks like. The 2026-08 barracuda/barracuda-base audit
/// measured hand-routed entries missing the ray by 0.03–0.4 mm while staying
/// wholly inside their land's column — half the boards' own-land findings —
/// with zero of them putting copper in a corridor. A fly-through that crosses
/// the land without an end inside stays a finding even when contained: copper
/// that BRIDGES across a land's column is exactly the shape the rule exists
/// for.
pub fn segmentOffence(land: Land, a: [2]f64, b: [2]f64, half: f64) ?Finding {
    if (land.paddle()) return null;
    const cl = clip(land, half, a, b) orelse return null;
    const c = land.centre();
    const off = lineOffset(a, b, c);
    if (off <= anchor_tol_mm) return null;
    if (columnContained(land, a, b, half) and (cl[0] <= eps or cl[1] >= 1 - eps)) return null;
    const p = [2]f64{ a[0] + cl[0] * (b[0] - a[0]), a[1] + cl[0] * (b[1] - a[1]) };
    const q = [2]f64{ a[0] + cl[1] * (b[0] - a[0]), a[1] + cl[1] * (b[1] - a[1]) };
    return .{ .at = nearestOn(p, q, c), .overlap_mm = dist(p, q), .miss_mm = off };
}

/// Does this axis-aligned segment's swept copper stay inside the land's extent
/// on the axis perpendicular to its run? A diagonal segment is never contained:
/// projection containment is not geometric containment once the run is off
/// axis, so the strict ray rule keeps judging it.
fn columnContained(land: Land, a: [2]f64, b: [2]f64, half: f64) bool {
    if (@abs(b[0] - a[0]) <= eps) {
        return @min(a[0], b[0]) - half >= land.x0 - eps and
            @max(a[0], b[0]) + half <= land.x1 + eps;
    }
    if (@abs(b[1] - a[1]) <= eps) {
        return @min(a[1], b[1]) - half >= land.y0 - eps and
            @max(a[1], b[1]) + half <= land.y1 + eps;
    }
    return false;
}

/// Re-anchor one offending flat segment through `land.centre()`.
///
/// The split points are the exact entry/exit of the land grown by the copper's
/// half-width. Consequently the untouched outside pieces have zero swept
/// overlap, while both replacement pieces are aimed at the centre and satisfy
/// `segmentOffence` by construction. Adjacent duplicate points are omitted.
pub fn anchorSegment(land: Land, a: [2]f64, b: [2]f64, half: f64) ?AnchoredSegment {
    if (segmentOffence(land, a, b, half) == null) return null;
    const cl = clip(land, half, a, b) orelse return null;
    const p = [2]f64{ a[0] + cl[0] * (b[0] - a[0]), a[1] + cl[0] * (b[1] - a[1]) };
    const q = [2]f64{ a[0] + cl[1] * (b[0] - a[0]), a[1] + cl[1] * (b[1] - a[1]) };
    var out = AnchoredSegment{ .points = @splat(.{ 0, 0 }), .len = 0 };
    for ([_][2]f64{ a, p, land.centre(), q, b }) |point| {
        if (out.len > 0 and dist(out.points[out.len - 1], point) <= eps) continue;
        out.points[out.len] = point;
        out.len += 1;
    }
    return if (out.len >= 2) out else null;
}

/// Does `now` dirty a land that `was` left CLEAN?
///
/// The comparison is deliberately qualitative rather than a comparison of
/// `miss_mm`, and it is deliberately one-sided:
///
///   * one-sided, because a rewrite must be refused for the harm it INTRODUCES,
///     never for harm it inherited. The rule may not cost connectivity, and a
///     guard that froze every candidate touching already-offending copper would
///     stall exactly the boards with the most to gain.
///   * qualitative, because a pass that re-anchors a chain ONE END AT A TIME
///     passes through intermediate shapes: `pad_escape.escapeChain` rewrites the
///     head, then the tail, and the head's rewrite may well move copper about on
///     a land the tail's rewrite is about to clean up. Scoring those middle
///     states by how far they miss would refuse the first half of a two-step
///     improvement. Clean-to-dirty is the transition that always means harm.
pub fn worsens(
    arena: std.mem.Allocator,
    lands: []const Land,
    was: []const [2]f64,
    now: []const [2]f64,
    half: f64,
) std.mem.Allocator.Error!bool {
    return (try dirtied(arena, lands, was, now, half)) > 0;
}

/// HOW MANY lands `now` dirties that `was` left clean — `worsens` with a
/// magnitude, so a chooser comparing candidates can prefer the one that spoils
/// fewer lands rather than only knowing that both spoil some.
pub fn dirtied(
    arena: std.mem.Allocator,
    lands: []const Land,
    was: []const [2]f64,
    now: []const [2]f64,
    half: f64,
) std.mem.Allocator.Error!usize {
    var n: usize = 0;
    for (lands) |land| {
        if ((try offence(arena, land, now, half)) == null) continue;
        if ((try offence(arena, land, was, half)) == null) n += 1;
    }
    return n;
}

/// Is `p` on the land's real copper? Used by callers that must not report a
/// finding against a point the outline says is not metal.
pub fn onLand(land: Land, p: [2]f64) bool {
    return pad_shape.pointDist(land.x0, land.y0, land.x1, land.y1, land.poly, p[0], p[1], 1) <= 1e-6;
}

const testing = std.testing;

/// A 0.3 x 0.9 mm land — a 0.5 mm-pitch QFN pad, long axis vertical — centred
/// at the origin, which is where a connection to it anchors.
const qfn_land = Land{ .x0 = -0.15, .y0 = -0.45, .x1 = 0.15, .y1 = 0.45 };

/// The default track's half width, which is the metal every measurement here is
/// taken on.
const track_half: f64 = 0.0635;

// spec: placement/land-transit - a centre-anchored ray that leaves a land once is not a finding, trimmed back to a stub or not

test "a pad's own escape ray is legal, trimmed or whole" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    // Centre-anchored, due north, straight out past the land.
    const whole = [_][2]f64{ .{ 0, 0 }, .{ 0, 0.6 } };
    try testing.expect((try offence(arena, qfn_land, &whole, track_half)) == null);
    // The same connection after `pad_entry` trimmed it to a stub: it no longer
    // reaches the centre, but it is still ON the ray, which is the test.
    const trimmed = [_][2]f64{ .{ 0, 0.33 }, .{ 0, 0.6 } };
    try testing.expect((try offence(arena, qfn_land, &trimmed, track_half)) == null);
    // And a chain that runs THROUGH the centre — a daisy chain joining this pad
    // to the net on both sides — is what a hand router draws.
    const through = [_][2]f64{ .{ 0, -0.7 }, .{ 0, 0 }, .{ 0.7, 0.7 } };
    try testing.expect((try offence(arena, qfn_land, &through, track_half)) == null);
}

// spec: placement/land-transit - an offending segment can be split locally into centre-anchored rays with no remaining own-land offence
test "anchorSegment preserves the outside run and cleans the land crossing" {
    const a = [2]f64{ -1, 0.3 };
    const b = [2]f64{ 1, 0.3 };
    const fixed = anchorSegment(qfn_land, a, b, track_half) orelse
        return testing.expect(false);
    try testing.expectEqual(a, fixed.points[0]);
    try testing.expectEqual(b, fixed.points[fixed.len - 1]);
    try testing.expect(fixed.len >= 3);
    for (1..fixed.len) |i| {
        try testing.expect(segmentOffence(qfn_land, fixed.points[i - 1], fixed.points[i], track_half) == null);
    }
}

// spec: placement/land-transit - copper that turns while still beside a land is a finding, measured by how far the corner misses the pad centre

test "the board owner's pin 18: a 45 degree ray that turns at the land's edge" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    // straps-synth-lmx2595's LMX_RFOUTBM, U1 pad 18 translated onto the origin:
    // the escape leaves at 45 degrees, reaches the land's own corner-ward edge
    // after 0.212 mm, and turns north there — so 0.3 mm of the vertical leg
    // rides the land's flank, half a trace width of it in the 0.2 mm corridor
    // to pad 19.
    const pts = [_][2]f64{ .{ 0, 0 }, .{ 0.15, 0.15 }, .{ 0.15, 1.14 } };
    const f = (try offence(arena, qfn_land, &pts, track_half)) orelse
        return testing.expect(false);
    try testing.expectApproxEqAbs(0.2121, f.miss_mm, 1e-3);
    try testing.expect(f.overlap_mm > 0.5);
    // The shape the escape rule asks for instead — north until it is clear of
    // the land, THEN the 45 degrees — is legal and exactly as long.
    const fixed = [_][2]f64{ .{ 0, 0 }, .{ 0, 0.99 }, .{ 0.15, 1.14 } };
    try testing.expect((try offence(arena, qfn_land, &fixed, track_half)) == null);
}

// spec: placement/land-transit - copper that laps or transits a land it does not terminate on is a finding even though it is the same net

test "a lap along a flank and a transit across a land are both findings" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    // A run down the land's flank, on its own business: the centreline misses
    // the land, but the metal laps it.
    const lap = [_][2]f64{ .{ 0.19, -1 }, .{ 0.19, 1 } };
    const l = (try offence(arena, qfn_land, &lap, track_half)) orelse
        return testing.expect(false);
    try testing.expectApproxEqAbs(0.19, l.miss_mm, 1e-6);
    // A transit straight across, off centre.
    const transit = [_][2]f64{ .{ -1, 0.3 }, .{ 1, 0.3 } };
    const t = (try offence(arena, qfn_land, &transit, track_half)) orelse
        return testing.expect(false);
    try testing.expectApproxEqAbs(0.3, t.miss_mm, 1e-6);
}

// spec: placement/land-transit - An axis-aligned run whose swept copper stays inside the land's own column and reaches a segment end there is the pad's connection, not an offence; a column-contained fly-through, a flank lap, and every diagonal stay judged by the strict ray rule.

test "column-contained copper that ends on the land is legal; fly-throughs and laps are not" {
    // A hand-drawn entry aimed 0.05 mm off the centre ray: swept copper
    // (x in 0.05 +/- 0.0635) stays inside the land's own +/-0.15 column and the
    // segment ends on the land, so nothing reaches the corridor.
    try testing.expect(segmentOffence(qfn_land, .{ 0.05, 0.1 }, .{ 0.05, 0.9 }, track_half) == null);
    // A connector finger 4.19 x 1.27 mm: one axis is under `paddle_min_half_mm`
    // so the ray rule is in scope, but a bar of copper lying wholly on the land
    // 2 mm from its centre puts no metal beside it.
    const finger = Land{ .x0 = -2.095, .y0 = -0.635, .x1 = 2.095, .y1 = 0.635 };
    try testing.expect(segmentOffence(finger, .{ -2.031, -0.572 }, .{ -2.031, 0.571 }, track_half) == null);
    // The same off-ray column with BOTH ends outside the land is a bridge
    // straight across it, not a connection: still a finding.
    const through = segmentOffence(qfn_land, .{ 0.05, -1 }, .{ 0.05, 1 }, track_half) orelse
        return testing.expect(false);
    try testing.expectApproxEqAbs(0.05, through.miss_mm, 1e-6);
    // A lap along the flank leaves the column sideways: still a finding.
    try testing.expect(segmentOffence(qfn_land, .{ 0.19, -1 }, .{ 0.19, 1 }, track_half) != null);
    // A transit across the short axis exits through the flank corridors even
    // though its own lateral band fits the land's long axis: still a finding.
    try testing.expect(segmentOffence(qfn_land, .{ -1, 0.3 }, .{ 1, 0.3 }, track_half) != null);
    // A diagonal is never column-contained; the strict ray rule keeps judging it.
    try testing.expect(segmentOffence(qfn_land, .{ 0.05, 0.1 }, .{ 0.08, 0.9 }, track_half) != null);
}

// spec: placement/land-transit - an exposed thermal paddle is out of scope, since nothing anchors on its centre and it has no flank corridor

test "a paddle is not judged by the ray rule" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    // straps-synth-lmx2595's U1 pad 41: a 4.6 mm square exposed pad. Ground
    // copper clipping its corner on the way past is not a lap on a lead land.
    const paddle = Land{ .x0 = -2.3, .y0 = -2.3, .x1 = 2.3, .y1 = 2.3 };
    try testing.expect(paddle.paddle());
    const clip_corner = [_][2]f64{ .{ 1.9, 2.4 }, .{ 2.4, 1.9 } };
    try testing.expect((try offence(arena, paddle, &clip_corner, track_half)) == null);
    // An 0805's land is well under the threshold on both axes, so every land a
    // connection actually escapes from stays in scope.
    const land_0805 = Land{ .x0 = -0.5, .y0 = -0.725, .x1 = 0.5, .y1 = 0.725 };
    try testing.expect(!land_0805.paddle());
}

// spec: placement/land-transit - a rewrite is refused only when it dirties a land that was clean, so inherited overlap never freezes an improvement

test "worsens is one-sided: inherited overlap does not refuse a rewrite" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const lands = [_]Land{qfn_land};
    const bad = [_][2]f64{ .{ 0, 0 }, .{ 0.15, 0.15 }, .{ 0.15, 1.14 } };
    const good = [_][2]f64{ .{ 0, 0 }, .{ 0, 0.99 }, .{ 0.15, 1.14 } };
    // Introducing the lap refuses…
    try testing.expect(try worsens(arena, &lands, &good, &bad, track_half));
    // …removing it does not, and neither does keeping what was already there.
    try testing.expect(!try worsens(arena, &lands, &bad, &good, track_half));
    try testing.expect(!try worsens(arena, &lands, &bad, &bad, track_half));
}
