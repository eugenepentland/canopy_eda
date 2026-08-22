//! Pad-escape discipline — how generated copper LEAVES the pad it connects to.
//!
//! The rule, in the board owner's own words (2026-08-11):
//!
//! > "If a trace is connecting to a pad: within 0.15 mm of the pad it must be a
//! >  SINGLE trace at a 45-degree increment (0, 45, 90, 135, 180, 225, 270,
//! >  315). From the CENTER of the pad there needs to be a trace at one of those
//! >  angles escaping out of the pad to at least 0.15 mm beyond the pad edge —
//! >  and after that it's free to do whatever it wants."
//!
//! So every connection to a pad is ONE straight ray: anchored at the pad's own
//! centre, on one of the eight compass headings, running until it is
//! `pad_escape_clear_mm` clear of the land — no bend, no branch, no second
//! trace inside that zone. Past the clearance point the route is unconstrained,
//! which is what makes the rule cheap: it governs the first fraction of a
//! millimetre of each connection and nothing else.
//!
//! Why it is worth a pass of its own. A pad is the one place a reader, a
//! photoplotter and a hand-editor all need the copper to say the same thing:
//! *this* trace serves *this* pad, from its centre, in one direction. Copper
//! that meets a land tangentially, that starts a hair off the centre, or that
//! turns a corner while still on the pad, says something weaker — and every one
//! of those shapes was on the boards before this pass (measured 2026-08-11 over
//! five modules at both effort tiers: 501 generated pad entries, 35 of them
//! compliant).
//!
//! ## The ladder, and what it replaces
//!
//! `pad_entry.zig` used to own this seam with the OPPOSITE convention: it
//! trimmed each terminal back so at most `pad_entry.stub_mm` of copper lay
//! inside the land, which is how it killed the lap joints (copper drawn ALONG a
//! pad rather than into it). Centre anchoring supersedes that trim — but not the
//! prohibition, because a centre-anchored 45° ray is by construction not a lap:
//! it crosses the outline exactly once, radially, and it is the only copper of
//! its connection inside the land. The two rules are ONE ladder, in this order:
//!
//!   0. `via_centre.passBoard` — put every same-net barrel standing in a land
//!      on that land's centre, and drop the copper the land already provides
//!      (a pad whose net continues only through a via on its own land then has
//!      no stub to escape with, on either face);
//!   1. `pad_entry.passBoard` — remove the laps and the copper lying wholly on
//!      a land (a failed escape joins nothing the solid pad does not);
//!   2. this pass — re-anchor what it can at the centre on a legal ray.
//!
//! An end whose every heading is blocked keeps rung 1's geometry. The rule may
//! never cost connectivity, so a blocked escape is a counted fallback, never a
//! failed net: this pass only ever rewrites copper it has probed at DRC
//! clearance, and refuses the whole end otherwise.
//!
//! ## WHICH heading, and why it is not the first one that clears
//!
//! The ray has to point somewhere, and that choice decides the shape of the
//! whole connection. Taking the first heading in the fan that cleared meant
//! taking whichever way the MAZE's first lattice step happened to go, and a
//! lattice step is axis-aligned: a bypass cap 1.5 mm diagonally off its hub pad
//! left west, ran its 0.46 mm ray, and then turned 90° to come down onto the
//! pad. That is the shape the board owner objected to (2026-08-11: "it keeps
//! doing these 90 degree bends right out of the pad … I want it to do a 45
//! degree angle if there is space, which there is"). The same pad reached on the
//! DIAGONAL heading leaves on the line the connection actually wants, needs no
//! square corner, and — because a diagonal is the shorter way to a diagonal
//! neighbour — spends LESS copper.
//!
//! So every heading in the fan is built and scored (`chooseEscape`): fewest
//! square corners, then fewest TOTAL bends, then shortest, then lowest fan
//! index, with only candidates within `mitre_budget_mm` of the shortest allowed
//! to compete. Nothing about the rule itself changes — each candidate is the
//! same probed, via-safe, junction-safe rewrite the pass always emitted — only
//! which of them is kept.
//!
//! Total bends is the second key because square corners alone do not separate
//! the two shapes a reader actually tells apart. An escape that leaves on the
//! maze's heading and then mitres costs one 45° corner; the SAME connection
//! escaping on the heading that points at its partner costs none, and is
//! usually the shorter of the two as well. Scoring on square corners only, both
//! score zero and the tie falls to the lowest fan index — which is the maze's
//! own heading, so the mitred shape wins by default. Counting every bend after
//! the square ones puts the dead-straight escape first without ever letting a
//! 45° corner outrank a 90° one.
//!
//! ## The copper an end ALREADY has is one of the candidates
//!
//! A compliant end — centre-anchored, octilinear, straight past the land — used
//! to return before the fan was built at all, on the reasoning that the rule was
//! already satisfied so there was nothing to do. But the rule governs the first
//! half-millimetre and the SCORE governs the rest, and an end can satisfy the
//! one while drawing the other badly: straps-synth-lmx2595's `LMX_VREFVCO2`
//! leaves C13's land due west on a perfectly legal 0.6 mm ray and then turns 90°
//! south, because west is where the maze went and nothing ever re-read that
//! choice (2026-08-12: *"there are still pins like this green one that
//! definitely could've been escaped out at a 45 degrees angle and there would be
//! no bend"*). Half of the corpus's surviving near-pad right angles were this
//! one shape.
//!
//! So compliance is no longer an exit; it is an ENTRY. The end's own copper
//! joins the fan as the candidate to beat — held first in the list, so it wins
//! every tie, and exempt from `mitre_budget_mm`, because keeping what you
//! already have spends nothing and the budget bounds spending. It is replaced
//! only by a candidate that STRICTLY beats it on the score and clears every
//! guard; on any tie, any refusal, or an empty fan it keeps its copper byte for
//! byte. That is also what makes the pass a fixed point: `escapeHead` iterates
//! until no candidate beats what it holds, so a second run over its own output
//! finds the same "nothing better" and rewrites nothing.
//!
//! The second half of the same idea is WHERE the ray rejoins the route. The
//! first vertex past the escape zone is usually the maze's own first bend, and
//! a lattice bend is square, so joining to it can only meet it at 90°. Each
//! heading therefore also offers rejoining one or two vertices further along
//! (`max_tail_skip`) — the octilinear elbow then draws the 45° the connection
//! was heading for, and the maze's step disappears into it. Only a vertex
//! sitting ON the exit qualifies (`skip_reach_mm`): further out, a vertex is
//! somebody's routing decision, not lattice noise, and is left alone.
//!
//! ## Scope
//!
//!   * SMD lands only. A THROUGH-HOLE pad is exempt: the barrel is the
//!     connection on every layer, so copper crossing the annulus is not an
//!     escape to discipline (the same call `pad_entry` makes).
//!   * `(max-freq …)` escape-ruled nets are exempt. Their straight reserve is
//!     AUTHORED and longer than this floor, it is measured from the pad anchor
//!     by `bend_smooth`, and their corners are arcs that pass owns — an
//!     authored reserve outranks the 0.15 mm default, which applies where
//!     nothing is authored.
//!   * A declared differential pair is rewritten PAIRWISE (`passPair`), never
//!     leg by leg: both legs take the same heading and the same escape length
//!     at each end, so the pair gains equal copper and its skew survives.
//!   * Hand-drawn copper and saved layouts are not rewritten at all — this pass
//!     runs inside the router's finish, so it governs GENERATED copper only.

const std = @import("std");
const bypass_intent = @import("bypass_intent.zig");
const bend_smooth = @import("bend_smooth.zig");
const land_transit = @import("land_transit.zig");
const diff_pairs = @import("diff_pairs.zig");
const octilinear = @import("octilinear.zig");
const optimizer = @import("optimizer.zig");
const pad_entry = @import("pad_entry.zig");
const pad_grid = @import("pad_grid.zig");
const pad_shape = @import("pad_shape.zig");
const route_cleanup = @import("route_cleanup.zig");
const router = @import("router.zig");
const via_centre = @import("via_centre.zig");

/// How far past the pad's edge a connection must run STRAIGHT before it may do
/// anything else (mm). The board owner's own figure, and the one number the
/// whole rule rests on: it is roughly one default track width (0.127 mm), so
/// the disciplined stretch is as long as the copper is wide — enough that the
/// escape reads as a direction rather than a tangency, short enough that it
/// costs a route nothing but its first bend's position.
///
/// It coincides with `straighten.terminal_keep_mm`, and deliberately so: that
/// constant is the same idea seen from the chamfer's side ("do not eat the last
/// 0.15 mm of a pad-side arm"), so a corner the chamfer is allowed to cut can
/// never land inside the zone this pass reserves.
pub const pad_escape_clear_mm: f64 = 0.15;

/// The eight headings a pad escape may take: 0°, 45°, … 315°, as exact unit
/// vectors. Written out rather than derived from `@cos`/`@sin` so a diagonal's
/// two components are bit-identical — the emitted ray is then exactly 45°, not
/// 45° ± an ulp, on every platform.
const headings = [8][2]f64{
    .{ 1, 0 },
    .{ std.math.sqrt1_2, std.math.sqrt1_2 },
    .{ 0, 1 },
    .{ -std.math.sqrt1_2, std.math.sqrt1_2 },
    .{ -1, 0 },
    .{ -std.math.sqrt1_2, -std.math.sqrt1_2 },
    .{ 0, -1 },
    .{ std.math.sqrt1_2, -std.math.sqrt1_2 },
};

/// How far the escape may swivel off the heading the route already leaves on:
/// the fan tries that heading, then ±45°, then ±90°, and stops. A heading
/// pointing BACK past the pad is never an escape — the copper would leave the
/// land only to walk around it to reach the route it serves — so an end with no
/// forward heading free keeps what it has instead.
const fan_len: usize = 5;

/// Widest deviation from a true right angle still counted as a SQUARE corner,
/// as the cosine of the corner angle — sin(5°), the tolerance
/// `straighten.isRightAngle` judges the same shape by. The two must agree: this
/// is the count the escape chooser minimises, and that is the pass that would
/// otherwise have to cut what it leaves behind.
const square_tol_cos: f64 = 0.0871557;

/// How much extra copper an escape may spend to trade a SQUARE corner for a
/// 45° one (mm).
///
/// The heading a connection already leaves on is not usually the heading that
/// draws it best. A bypass cap 1.5 mm off its hub pad leaves west because the
/// maze's first lattice step went west, runs its 0.46 mm ray, and then has to
/// turn 90° to come down onto the pad — the shape the board owner objected to
/// (2026-08-11: "it keeps doing these 90 degree bends right out of the pad …
/// I want it to do a 45 degree angle if there is space, which there is"). The
/// SAME pad reached on the DIAGONAL heading leaves on the line it actually
/// wants and needs no square corner at all.
///
/// So the fan is scored, not taken first-clear. 0.5 mm is the budget because it
/// is the scale of the thing being bought: an escape ray is 0.4–0.6 mm long, so
/// half a millimetre is at most one ray's worth of copper spent to straighten
/// a connection — enough to let a diagonal heading win the case above (which
/// is in fact SHORTER), and far too little to pay for a detour around the pad.
///
/// It is deliberately NOT widened for the bend term, even though a diagonal can
/// in principle be √2 longer than the L it replaces. In octilinear geometry the
/// two objectives point the same way: the shortest octilinear path between two
/// points already turns the fewest corners, so a candidate that removes a bend
/// is normally the shorter one and needs no allowance at all. Measured over the
/// six-board corpus (2026-08-12), re-scoring compliant ends on this key SAVED
/// copper rather than spending it — 1252.20 mm of trace fell to 1247.64 mm, with
/// five of the six boards shrinking, the sixth (lmk05318b-clock) growing 0.05 mm
/// and the worst single net (barracuda's V_22V) growing 0.67 mm. The board
/// owner's own example, straps-synth-lmx2595's `LMX_VREFVCO2`, lost its right
/// angle AND 0.35 mm of the 2.46 mm it had. A budget widened for a case the
/// geometry does not produce would only buy detours.
///
/// The copper an end ALREADY holds is exempt from this filter: the budget bounds
/// what a rewrite may SPEND, and keeping what is already on the board spends
/// nothing. Without the exemption an incumbent more than a budget longer than
/// the shortest candidate would be dropped from the comparison entirely and
/// replaced by whatever was shortest, corners regardless.
const mitre_budget_mm: f64 = 0.5;

/// How many times `escapeHead` may re-score an end before it settles.
///
/// Each accepted rewrite strictly lowers the score, and the fan is re-centred on
/// the heading the winner actually left by (`baseHeading` reads the copper it is
/// given), so a rewrite can open headings the previous round never reached. The
/// loop therefore runs to CONVERGENCE rather than once: it stops when nothing in
/// the fan beats what it holds, which is precisely the question a second run of
/// the whole pass would ask — so the pass is a fixed point by construction, not
/// by luck.
///
/// Four is a safety ceiling on a loop that terminates on its own (the score is a
/// strict lexicographic order over two bounded integers and a length that only
/// falls). Measured over the corpus, every end settles in ONE round and none has
/// ever reached the ceiling; it exists so a pathological chain cannot spin, and
/// hitting it would cost only maximality, never safety — the copper written is
/// still a probed, guard-cleared candidate.
const escape_rounds: usize = 4;

/// How many vertices of the tail an escape may rejoin PAST.
///
/// The vertex immediately beyond the escape zone is usually the MAZE's own
/// first bend, and a lattice bend is square: a QFN pin whose partner sits
/// diagonally away comes out as "0.6 mm straight, 0.11 mm sideways, then the
/// diagonal it wanted all along", and the join has no choice but to meet that
/// 0.11 mm step at 90°. Rejoining one vertex further along lets the same
/// octilinear elbow draw the 45° instead — the maze's step was never load
/// bearing, it was the lattice's way of saying "diagonal".
///
/// Two is the cap, and it is a deliberate ceiling rather than a tuning knob:
/// this pass owns the first half-millimetre of a connection, not its route, and
/// a skip that could run the length of a tail would let a finish-time pass
/// redraw a whole net through a two-segment probe. Every skipped candidate is
/// still probed leg by leg and still refused if it would strand a via or a
/// junction, so the cap is about SCOPE, not safety.
const max_tail_skip: usize = 2;

/// How far from the ray's exit a vertex may sit and still be skippable (mm).
///
/// The count above bounds how MANY vertices a skip may swallow; this bounds
/// WHICH, and it is the load-bearing half. A vertex a fraction of a millimetre
/// past the exit is lattice noise — the maze quantising a diagonal into a step
/// — and absorbing it is the whole point. A vertex further out is a decision
/// some earlier pass made about where the copper goes, and this pass has no
/// business overruling it: `net_topology` deliberately runs a stacked passive
/// pair's copper across their own lands rather than down the lane in front of
/// them, and a skip that reached that far would redraw exactly that.
///
/// 0.3 mm is one router lattice step (the grid pitch is track width +
/// clearance, 0.254 mm at the default class) plus slack, so it takes in the
/// jogs measured on straps-synth-lmx2595 (0.03–0.18 mm) and nothing that could
/// be a routing decision.
const skip_reach_mm: f64 = 0.3;

/// Float slack for the geometry tests — well below fab resolution, so it only
/// absorbs coordinates that have been through a world→grid→world round trip.
const eps: f64 = 1e-9;

/// How close to the pad's centre an anchor must be to count as ON it. The pass
/// emits the centre exactly; this only tolerates the last bits of a float.
const centre_tol_mm: f64 = 1e-6;

/// Via-matching tolerance (mm), as in `pad_entry`.
const via_snap: f64 = 0.01;

/// One pad a connection may terminate on: its land box plus the outline that
/// decides what is really copper.
const Pad = struct {
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,
    poly: []const [2]f64 = &.{},

    /// The anchor every connection to this pad starts from. Netlisp builds a
    /// pad's world box symmetrically about its own centre (`pad_shape`), so the
    /// box centre IS the pad anchor; the one shape that could disagree (a
    /// polygon land whose outline is lopsided in its own bbox) is caught by the
    /// `onLand` test before anything is drawn from here.
    fn centre(self: Pad) [2]f64 {
        return .{ (self.x0 + self.x1) / 2, (self.y0 + self.y1) / 2 };
    }
};

fn dist(a: [2]f64, b: [2]f64) f64 {
    return std.math.hypot(b[0] - a[0], b[1] - a[1]);
}

/// Is `p` on the pad's real copper?
fn onLand(pad: Pad, p: [2]f64) bool {
    return pad_shape.pointDist(pad.x0, pad.y0, pad.x1, pad.y1, pad.poly, p[0], p[1], 1) <= centre_tol_mm;
}

fn inBox(pad: Pad, p: [2]f64) bool {
    return p[0] >= pad.x0 - eps and p[0] <= pad.x1 + eps and
        p[1] >= pad.y0 - eps and p[1] <= pad.y1 + eps;
}

/// How far the escape ray must run from the pad centre along `dir`: out to the
/// land's edge on that heading, plus the clearance.
///
/// The land's edge is taken from its BOX, which for a rounded or oval pad sits
/// outside the copper — so the ray clears the real outline by at least the
/// margin asked for. Conservative in the only direction that matters.
fn escapeReach(pad: Pad, dir: [2]f64) f64 {
    const c = pad.centre();
    var out = std.math.inf(f64);
    if (@abs(dir[0]) > eps) out = @min(out, (pad.x1 - c[0]) / @abs(dir[0]));
    if (@abs(dir[1]) > eps) out = @min(out, (pad.y1 - c[1]) / @abs(dir[1]));
    return out + pad_escape_clear_mm;
}

/// The length of the straight run leaving `pts[0]` — collinear vertices merged,
/// so a route the maze happened to split does not read as a bend.
fn straightRun(pts: []const [2]f64) f64 {
    var out = dist(pts[0], pts[1]);
    for (2..pts.len) |i| {
        if (!collinear(pts[0], pts[i - 1], pts[i])) break;
        out = dist(pts[0], pts[i]);
    }
    return out;
}

/// Do a, b, c lie on one straight line, with c beyond b?
fn collinear(a: [2]f64, b: [2]f64, c: [2]f64) bool {
    const d1 = [2]f64{ b[0] - a[0], b[1] - a[1] };
    const d2 = [2]f64{ c[0] - b[0], c[1] - b[1] };
    const l1 = std.math.hypot(d1[0], d1[1]);
    const l2 = std.math.hypot(d2[0], d2[1]);
    if (l1 < eps or l2 < eps) return false;
    const cross = @abs(d1[0] * d2[1] - d1[1] * d2[0]);
    return cross <= 1e-6 * l1 * l2 and d1[0] * d2[0] + d1[1] * d2[1] > 0;
}

/// Does this chain END already obey the rule — anchored on the pad's centre, on
/// a 45° heading, straight until it is clear of the land?
fn compliantEnd(pts: []const [2]f64, pad: Pad) bool {
    if (pts.len < 2) return false;
    if (dist(pts[0], pad.centre()) > centre_tol_mm) return false;
    if (!octilinear.isOctilinear(pts[0], pts[1])) return false;
    const run = straightRun(pts);
    if (run < eps) return false;
    const dir = [2]f64{ (pts[1][0] - pts[0][0]) / dist(pts[0], pts[1]), (pts[1][1] - pts[0][1]) / dist(pts[0], pts[1]) };
    return run + centre_tol_mm >= escapeReach(pad, dir);
}

/// The heading index the route currently leaves on, snapped to the compass —
/// the heading whose direction the copper's own points along most strongly.
///
/// Chosen by dot product rather than by an angle, so there is no float→int cast
/// to mis-round at a boundary, and a tie (a heading exactly between two
/// compass points) always resolves to the lower index — which is what keeps the
/// pass deterministic.
fn baseHeading(pts: []const [2]f64, c: [2]f64) ?usize {
    for (pts[1..]) |p| {
        if (dist(p, c) < eps) continue;
        var best: usize = 0;
        var best_dot = -std.math.inf(f64);
        for (headings, 0..) |h, i| {
            const dot = (p[0] - c[0]) * h[0] + (p[1] - c[1]) * h[1];
            if (dot <= best_dot) continue;
            best_dot = dot;
            best = i;
        }
        return best;
    }
    return null;
}

/// The `k`-th heading of the search fan around `base`: straight on first, then
/// ±45°, ±90°, … so the least disturbing escape is always tried first.
fn fanHeading(base: usize, k: usize) [2]f64 {
    const mag: isize = @intCast((k + 1) / 2);
    const sign: isize = if (k % 2 == 1) 1 else -1;
    const idx: usize = @intCast(@mod(@as(isize, @intCast(base)) + sign * mag, headings.len));
    return headings[idx];
}

/// The part of the chain that lies BEYOND the escape zone: the first vertex
/// farther than `reach` from the pad centre, and everything after it.
///
/// Null when the whole chain stays inside the zone — a connection shorter than
/// the escape the rule asks for, which no ray can serve.
fn beyondZone(pts: []const [2]f64, c: [2]f64, reach: f64) ?[]const [2]f64 {
    for (pts[1..], 1..) |p, i| {
        if (dist(p, c) > reach + eps) return pts[i..];
    }
    return null;
}

/// One of the net's own vias, as this pass needs it: where the barrel stands
/// and how wide its copper is.
const Barrel = struct { at: [2]f64, r: f64 };

/// Does the polyline pass within `reach` of `p` — i.e. does copper drawn along
/// it touch the object standing there?
fn nearPolyline(p: [2]f64, pts: []const [2]f64, reach: f64) bool {
    for (1..pts.len) |i| {
        if (pointSeg(p, pts[i - 1], pts[i]) <= reach + eps) return true;
    }
    return false;
}

/// Would the rewrite take copper OFF a barrel?
///
/// Every via the old copper touches must still be touched by the new copper.
/// A chain END sitting on a barrel is the obvious case — it is a via terminal
/// that happens to stand on a land, not a pad escape — but the costly one is
/// subtler: a barrel the old copper merely brushed as it ran down the land,
/// which a centre-anchored ray then leaves behind. Both open the net when the
/// finish's single-layer-via sweep drops the abandoned barrel and the loose-end
/// cascade follows it. (Measured: `lmk05318b-clock`'s LMK_CAP_PLL1 and
/// barracuda's V_12V, one net each.) Such an end keeps what it has, counted as
/// a fallback — connectivity outranks the rule.
fn stripsVia(vias: []const Barrel, was: []const [2]f64, now: []const [2]f64, half: f64) bool {
    for (vias) |v| {
        if (!nearPolyline(v.at, was, v.r + half)) continue;
        if (!nearPolyline(v.at, now, v.r + half)) return true;
    }
    return false;
}

/// One candidate escape: where it starts, where the disciplined stretch ends,
/// and how long that stretch is.
const Ray = struct { at: [2]f64, exit: [2]f64, reach: f64 };

/// Join the ray's exit to the route beyond the zone, octilinearly, probing every
/// leg. Null when nothing clears — the caller then tries the next heading.
///
/// A corner is never allowed back INSIDE the zone: that would put a second bend
/// within the clearance the rule reserves for one straight trace.
fn joinBeyond(
    comptime Context: type,
    arena: std.mem.Allocator,
    ray: Ray,
    tail: []const [2]f64,
    ctx: Context,
    comptime clear: fn (Context, [2]f64, [2]f64) bool,
) std.mem.Allocator.Error!?[][2]f64 {
    if (dist(ray.exit, tail[0]) <= eps) return try chainOf(arena, &.{ ray.at, ray.exit }, tail[1..]);
    if (octilinear.isOctilinear(ray.exit, tail[0])) {
        if (!clear(ctx, ray.exit, tail[0])) return null;
        return try chainOf(arena, &.{ ray.at, ray.exit }, tail);
    }
    // Bend LATE, as `octilinear.elbow` does: the corner farther from the pad
    // leaves the crowded ground next to the land on one heading and turns out
    // in open board. Both candidates are the same total length.
    var cand = octilinear.elbows(ray.exit, tail[0]);
    if (dist(ray.exit, cand[1]) > dist(ray.exit, cand[0])) cand = .{ cand[1], cand[0] };
    for (cand) |mid| {
        if (dist(mid, ray.at) < ray.reach - eps) continue;
        if (dist(ray.exit, mid) > eps and !clear(ctx, ray.exit, mid)) continue;
        if (dist(mid, tail[0]) > eps and !clear(ctx, mid, tail[0])) continue;
        return try chainOf(arena, &.{ ray.at, ray.exit, mid }, tail);
    }
    return null;
}

fn chainOf(
    arena: std.mem.Allocator,
    head: []const [2]f64,
    tail: []const [2]f64,
) std.mem.Allocator.Error![][2]f64 {
    const out = try arena.alloc([2]f64, head.len + tail.len);
    @memcpy(out[0..head.len], head);
    @memcpy(out[head.len..], tail);
    return out;
}

/// One end's rewrite job: the chain, the land it terminates on, its own copper
/// half-width, the net's vias (no rewrite may take copper off one), the net's
/// other lands (nor off one of those) and the points at which the net's OTHER
/// copper touches this chain (no rewrite may drop one of those either — it is a
/// junction, and losing it opens the net).
const EndJob = struct {
    pts: []const [2]f64,
    pad: Pad,
    half: f64 = 0,
    vias: []const Barrel = &.{},
    pads: []const Pad = &.{},
    joins: []const [2]f64 = &.{},
};

/// Would the rewrite take copper off a same-net LAND the old copper served?
///
/// A chain does not only END on pads. `net_topology` deliberately threads a
/// daisy chain THROUGH the lands between its two ends — straps-synth-lmx2595's
/// `LO_BIAS_A` runs C19 → R6 → R5 → L1 and turns 90° on each land it crosses —
/// and those middle pads are held to the net by nothing but the copper lying on
/// them. The direct line between the chain's ends is shorter and straighter than
/// the daisy chain, so a re-aimed escape would take it and silently strand two
/// resistors. (This guard only became load-bearing when compliant ends started
/// competing: such a chain leaves both its end lands legally, so the pass used
/// to return before it ever looked.)
///
/// So, as with a via and with a junction: every land the old copper covered must
/// still be covered by the new. A pad counts as served when the copper passes
/// within one half-width of its anchor, which is the centre every escape on it
/// is drawn from.
fn dropsPad(pads: []const Pad, was: []const [2]f64, now: []const [2]f64, half: f64) bool {
    for (pads) |pad| {
        const c = pad.centre();
        if (!nearPolyline(c, was, half)) continue;
        if (!nearPolyline(c, now, half)) return true;
    }
    return false;
}

/// Would the rewrite park copper ON a same-net land that it does not connect
/// to — a lap along a flank, or a corner turned while still beside the pad?
///
/// `dropsPad` above asks the opposite question (is a land the old copper served
/// still served), and the two together are what "this connection belongs to
/// that pad" means: every land the copper touches must be one it terminates on
/// or runs through the centre of, and every land it used to reach it must still
/// reach. Without this one the chooser actively PREFERS the lap: re-aiming a
/// chain's far end may rejoin one vertex further along (`max_tail_skip`) and so
/// redraw the near end's escape as well, and a diagonal that clips the near
/// land's corner turns one corner where the disciplined ray turns two.
/// straps-synth-lmx2595's `LMX_RFOUTBM` is exactly that: re-aiming R9's end
/// replaced U1 pad 18's 0.6 mm northward ray with a 0.21 mm diagonal that
/// stopped on the land's own edge and turned north along it, leaving half a
/// track width in the 0.2 mm corridor to pad 19 (2026-08-12: *"I don't want
/// extra copper in between my qfn pads that could short"*).
///
/// The test is MONOTONE (`land_transit.worsens`): a candidate is refused for
/// the overlap it INTRODUCES, never for one it inherited, so an end whose
/// copper already laps a land can still be improved.
fn lapsCount(
    arena: std.mem.Allocator,
    pads: []const Pad,
    was: []const [2]f64,
    now: []const [2]f64,
    half: f64,
) std.mem.Allocator.Error!usize {
    var lands: std.ArrayList(land_transit.Land) = .empty;
    for (pads) |p| try lands.append(arena, .{ .x0 = p.x0, .y0 = p.y0, .x1 = p.x1, .y1 = p.y1, .poly = p.poly });
    return land_transit.dirtied(arena, lands.items, was, now, half);
}

/// Would the rewrite drop a junction with the rest of the net?
///
/// A chain end is a terminal by construction, but another chain of the same net
/// may well join it in FRONT of the land — the very shape this rule forbids —
/// and copper that no longer reaches that point opens the net. So, as with a
/// via: every junction the old copper touched must still be touched by the new.
/// "Touch" is one full track width between centrelines, which is what every
/// graph that decides connectivity reads as one node.
fn dropsJoin(joins: []const [2]f64, was: []const [2]f64, now: []const [2]f64, half: f64) bool {
    for (joins) |j| {
        if (!nearPolyline(j, was, half * 2)) continue;
        if (!nearPolyline(j, now, half * 2)) return true;
    }
    return false;
}

/// One heading's finished rewrite, as the chooser compares them: the copper it
/// draws, how long that copper is, how many SQUARE corners it leaves and how
/// many corners of any kind.
///
/// `held` marks the candidate that is not a rewrite at all — the copper the end
/// already carries. It is exempt from the mitre budget and wins every tie, so an
/// end is only ever redrawn by something that strictly beats what is on the
/// board (see `mitre_budget_mm` and the module header).
const Candidate = struct {
    pts: []const [2]f64,
    len: f64,
    squares: usize,
    bends: usize = 0,
    /// How many same-net lands this candidate dirties that the copper it would
    /// replace left clean (`lapsCount`). The FIRST key of the score, so no
    /// number of corners saved can buy a lap.
    dirty: usize = 0,
    held: bool = false,
};

/// The copper this polyline would lay down.
fn polylineLength(pts: []const [2]f64) f64 {
    var out: f64 = 0;
    for (1..pts.len) |i| out += dist(pts[i - 1], pts[i]);
    return out;
}

/// How many RIGHT-ANGLE corners this polyline turns.
///
/// Collinear steps are merged on the way through — the emitter collapses them
/// (`emitPolyline`), so a run the maze happened to split must not read as a
/// corner here either — and a corner is square when the two headings meeting at
/// it are perpendicular to within `square_tol_cos`.
fn squareCorners(pts: []const [2]f64) usize {
    var count: usize = 0;
    var prev: ?[2]f64 = null;
    for (1..pts.len) |i| {
        const d = dist(pts[i - 1], pts[i]);
        if (d < eps) continue;
        const u = [2]f64{ (pts[i][0] - pts[i - 1][0]) / d, (pts[i][1] - pts[i - 1][1]) / d };
        if (prev) |p| {
            if (@abs(p[0] * u[0] + p[1] * u[1]) <= square_tol_cos) count += 1;
        }
        prev = u;
    }
    return count;
}

/// How many corners of ANY kind this polyline turns — the second key of the
/// score, after the square ones.
///
/// A corner counts when the two headings meeting at it differ at all, judged by
/// the same cross-product tolerance `collinear` uses, so a straight run the maze
/// happened to split into two segments is one run here as it is everywhere else
/// in this file. A reversal (the copper doubling back on itself) is a corner
/// however small the cross product, which is what the dot-product half catches.
fn bendCorners(pts: []const [2]f64) usize {
    var count: usize = 0;
    var prev: ?[2]f64 = null;
    for (1..pts.len) |i| {
        const d = dist(pts[i - 1], pts[i]);
        if (d < eps) continue;
        const u = [2]f64{ (pts[i][0] - pts[i - 1][0]) / d, (pts[i][1] - pts[i - 1][1]) / d };
        if (prev) |p| {
            const cross = @abs(p[0] * u[1] - p[1] * u[0]);
            const dot = p[0] * u[0] + p[1] * u[1];
            if (cross > 1e-6 or dot <= 0) count += 1;
        }
        prev = u;
    }
    return count;
}

/// Does `cd` beat `b`? Fewest LAPPED LANDS, then fewest square corners, then
/// fewest bends of any kind, then shortest — a strict lexicographic order, so
/// equal candidates leave the incumbent (or the earlier fan index) in place.
///
/// Lapping is the first key rather than a refusal for one reason: when EVERY
/// candidate laps a land, a refusal leaves the end with the copper it already
/// has, corners and all, while a key still takes the best of a bad set. Above
/// the corner keys because that is the board owner's own ordering — copper in
/// the corridor between two pins is worse than a corner (2026-08-12: *"I don't
/// want extra copper in between my qfn pads that could short"*) — and because
/// the incumbent always scores zero here (it dirties nothing relative to
/// itself), so a clean end is never traded for a square-free lap.
fn better(cd: Candidate, b: Candidate) bool {
    if (cd.dirty != b.dirty) return cd.dirty < b.dirty;
    if (cd.squares != b.squares) return cd.squares < b.squares;
    if (cd.bends != b.bends) return cd.bends < b.bends;
    return cd.len + eps < b.len;
}

/// The heading to escape on, out of the ones that cleared: FEWEST square
/// corners, then fewest total bends, then shortest, then lowest fan index.
///
/// Only candidates within `mitre_budget_mm` of the shortest may compete, so a
/// mitre is bought with a bounded amount of copper and never with a detour — but
/// a HELD candidate (the copper the end already carries) is exempt, because
/// keeping it spends nothing. The tie-breaks are total orders on values the
/// geometry fixes, and the list is walked in order with the incumbent first and
/// the fan in index order, so the choice is deterministic — the same board comes
/// out of two runs byte-identical.
fn chooseEscape(cands: []const Candidate) ?Candidate {
    if (cands.len == 0) return null;
    var min_len = cands[0].len;
    for (cands[1..]) |cd| min_len = @min(min_len, cd.len);
    var best: ?Candidate = null;
    for (cands) |cd| {
        if (!cd.held and cd.len > min_len + mitre_budget_mm) continue;
        const b = best orelse {
            best = cd;
            continue;
        };
        if (better(cd, b)) best = cd;
    }
    return best;
}

/// One escape the chooser may take: the `k`-th heading of the fan around
/// `base`, rejoining the route `skip` vertices along its tail.
const Choice = struct { base: usize, k: usize, skip: usize };

/// The copper `pick` would draw, or null when it does not clear or would leave
/// something the old copper carried behind.
fn escapeOn(
    comptime Context: type,
    arena: std.mem.Allocator,
    job: EndJob,
    pick: Choice,
    ctx: Context,
    comptime clear: fn (Context, [2]f64, [2]f64) bool,
) std.mem.Allocator.Error!?[][2]f64 {
    const c = job.pad.centre();
    const dir = fanHeading(pick.base, pick.k);
    const reach = escapeReach(job.pad, dir);
    const ray = Ray{
        .at = c,
        .exit = .{ c[0] + dir[0] * reach, c[1] + dir[1] * reach },
        .reach = reach,
    };
    const tail = beyondZone(job.pts, c, reach) orelse return null;
    if (pick.skip >= tail.len) return null;
    // Only lattice noise sitting on the exit may be skipped — never a vertex
    // far enough out to be somebody's routing decision (see `skip_reach_mm`).
    for (tail[0..pick.skip]) |p| {
        if (dist(p, ray.exit) > skip_reach_mm) return null;
    }
    if (!clear(ctx, ray.at, ray.exit)) return null;
    const built = (try joinBeyond(Context, arena, ray, tail[pick.skip..], ctx, clear)) orelse return null;
    // Nothing the old copper carried may be left behind by the new.
    if (stripsVia(job.vias, job.pts, built, job.half)) return null;
    if (dropsPad(job.pads, job.pts, built, job.half)) return null;
    if (dropsJoin(job.joins, job.pts, built, job.half)) return null;
    return built;
}

/// ONE round of re-scoring this end: the copper it should carry instead of what
/// it has, or null when nothing in the fan beats what it holds.
///
/// Every heading in the fan is BUILT and the best of them taken (see
/// `chooseEscape`) rather than the first that clears: which heading a pad
/// leaves on decides whether the connection bends at 45° or at 90°, and the
/// heading the maze happened to leave on is not usually the one that draws it
/// straight. When the end is ALREADY compliant its own copper joins the fan as
/// the candidate to beat, so a legal-but-badly-aimed escape is re-read instead
/// of being waved through — and is kept byte for byte unless something strictly
/// better clears.
fn escapeStep(
    comptime Context: type,
    arena: std.mem.Allocator,
    job: EndJob,
    ctx: Context,
    comptime clear: fn (Context, [2]f64, [2]f64) bool,
) std.mem.Allocator.Error!?[]const [2]f64 {
    const c = job.pad.centre();
    const base = baseHeading(job.pts, c) orelse return null;
    // Is there room for the escape this connection needs? A hop whose
    // continuation sits closer to the pad centre than the escape on the heading
    // it leaves by cannot be made compliant by ANY ray — the copper would have
    // to leave the pad, pass the point it is serving, and come back. Such an end
    // keeps what it has and is counted as a fallback, like a blocked one.
    if (beyondZone(job.pts, c, escapeReach(job.pad, fanHeading(base, 0))) == null) return null;
    var cands: std.ArrayList(Candidate) = .empty;
    // The copper already on the board goes in FIRST, when the rule already
    // permits it: first place means it wins every tie, so only a strictly better
    // candidate can displace copper that is legal where it stands.
    if (compliantEnd(job.pts, job.pad)) try cands.append(arena, .{
        .pts = job.pts,
        .len = polylineLength(job.pts),
        .squares = squareCorners(job.pts),
        .bends = bendCorners(job.pts),
        .held = true,
    });
    for (0..fan_len) |k| {
        for (0..max_tail_skip + 1) |skip| {
            const pick = Choice{ .base = base, .k = k, .skip = skip };
            const built = (try escapeOn(Context, arena, job, pick, ctx, clear)) orelse continue;
            try cands.append(arena, .{
                .pts = built,
                .len = polylineLength(built),
                .squares = squareCorners(built),
                .bends = bendCorners(built),
                .dirty = try lapsCount(arena, job.pads, job.pts, built, job.half),
            });
        }
    }
    const best = chooseEscape(cands.items) orelse return null;
    return if (best.held) null else best.pts;
}

/// Re-anchor the HEAD of a chain onto its pad's centre and send it out on a
/// legal 45° ray, or null when no heading beats the copper the end already has
/// (the caller then keeps it, and counts it).
///
/// Scoring runs to CONVERGENCE rather than once. A rewrite re-aims the escape,
/// and `baseHeading` reads whatever copper it is given, so the next round's fan
/// is centred on the heading the winner actually left by and can reach headings
/// the first round never tried. Iterating until nothing beats what is held asks
/// exactly the question a second run of the whole pass would ask — which is what
/// makes this pass a fixed point instead of merely a step towards one.
fn escapeHead(
    comptime Context: type,
    arena: std.mem.Allocator,
    job: EndJob,
    ctx: Context,
    comptime clear: fn (Context, [2]f64, [2]f64) bool,
) std.mem.Allocator.Error!?[]const [2]f64 {
    if (job.pts.len < 2) return null;
    if (!onLand(job.pad, job.pad.centre())) return null;
    var cur = job.pts;
    var moved = false;
    for (0..escape_rounds) |_| {
        var round = job;
        round.pts = cur;
        cur = (try escapeStep(Context, arena, round, ctx, clear)) orelse break;
        moved = true;
    }
    return if (moved) cur else null;
}

/// One chain's rewrite job: the copper, the net's SMD lands, its vias, and the
/// vertices of the net's OTHER copper on this layer (a junction with any of
/// them pins the copper it sits on).
const ChainJob = struct {
    pts: []const [2]f64,
    pads: []const Pad,
    half: f64 = 0,
    vias: []const Barrel = &.{},
    joins: []const [2]f64 = &.{},
};

/// Both ends of one chain, re-anchored where the rule can be met. Null when
/// neither end moved.
fn escapeChain(
    comptime Context: type,
    arena: std.mem.Allocator,
    job: ChainJob,
    ctx: Context,
    comptime clear: fn (Context, [2]f64, [2]f64) bool,
) std.mem.Allocator.Error!?[]const [2]f64 {
    // A CYCLE has no ends to discipline: its two "ends" are one point, so
    // re-anchoring the first would leave the second walking back out to it and
    // the copper doubles over itself. (Duplicated copper — the same segment
    // emitted twice, which the finish does leave behind — reads as exactly such
    // a two-node cycle; rewriting one cost barracuda's V_12V its westward
    // branch and with it a routed net.)
    if (dist(job.pts[0], job.pts[job.pts.len - 1]) <= eps) return null;
    var work = job.pts;
    var changed = false;
    for (0..2) |end| {
        if (end == 1) work = try reversed(arena, work);
        if (padAt(job.pads, work[0])) |pad| {
            const one = EndJob{
                .pts = work,
                .pad = pad,
                .half = job.half,
                .vias = job.vias,
                .pads = job.pads,
                .joins = job.joins,
            };
            if (try escapeHead(Context, arena, one, ctx, clear)) |cut| {
                work = cut;
                changed = true;
            }
        }
        if (end == 1) work = try reversed(arena, work);
    }
    // …and only then, for a short hop whose BOTH ends sit on lands, ask whether
    // planning the two rays and the jog between them TOGETHER draws it better.
    // Last, because the per-end passes are the floor: the joint plan is taken
    // only when it strictly beats what they left, so this can never be a
    // regression, only an improvement they could not express.
    if (try jointPlan(Context, arena, job, work, ctx, clear)) |joined| {
        work = joined;
        changed = true;
    }
    return if (changed) work else null;
}

/// Longest chain the JOINT planner will redraw, end to end (mm).
///
/// The planner throws the maze's route away and draws the connection from
/// scratch, so its scope has to be "a hop between two neighbouring parts", not
/// "a route". 4 mm is a hop: it covers a bypass cap and the pin it serves, two
/// adjacent passives, a strap and its resistor — the copper the board owner
/// keeps photographing — and it is under `net_topology.direct_span_mm`'s 6 mm,
/// the span past which a plain net's direct path is already abandoned. A longer
/// chain crossed somebody's board for a reason, and a three-legged probe is not
/// enough evidence to overrule that.
const joint_span_mm: f64 = 4.0;

/// Plan BOTH ends of a short pad-to-pad chain TOGETHER — the shape neither end
/// can reach on its own.
///
/// `escapeHead` owns one end: it re-aims that end's ray and rejoins the copper
/// the other end left behind. That is enough when only one end is wrong, and it
/// is structurally not enough when the connection's shape is decided by BOTH
/// reaches at once. straps-synth-lmx2595's `LMX_VBIASVARAC` is the case: U1 pad
/// 33 escapes 0.6 mm south (exactly its reach, so it is compliant and held) and
/// C11 escapes 1.37 mm on the diagonal (likewise), and the 0.18 mm jog between
/// those two legal rays can only meet the southward one at 90 degrees. Every
/// single-ended candidate either keeps that corner or shortens a ray below its
/// own reach. Planned together the same connection is
/// `45 degrees out of U1 → a 0.42 mm jog → 45 degrees into C11`: no square
/// corner, and 2.046 mm against the 2.152 mm on the board — SHORTER than the
/// shape it replaces.
///
/// It is a full redraw, so it is fenced accordingly: both ends must terminate
/// on their own SMD lands, the chain must be shorter than `joint_span_mm`, every
/// leg is probed at DRC clearance like any other candidate, every existing guard
/// applies (a via, a junction or a same-net land the old copper carried must
/// still be carried, and lapping a clean land is scored against it), the result
/// must stay within `mitre_budget_mm` of what it replaces, and it must STRICTLY
/// beat it. On any refusal the chain keeps its copper byte for byte.
///
/// All EIGHT headings are enumerated at each end rather than a fan around the
/// current one. The fan exists to keep a re-aim close to the copper it edits;
/// this planner is not editing, it is drawing, and a heading pointing back past
/// its pad simply loses on length. Enumerating the whole compass also makes the
/// pass independent of the copper it is handed, which is what makes it a fixed
/// point: run over its own output it enumerates the identical set, finds its own
/// shape among them, and returns null on the tie.
fn jointPlan(
    comptime Context: type,
    arena: std.mem.Allocator,
    job: ChainJob,
    cur: []const [2]f64,
    ctx: Context,
    comptime clear: fn (Context, [2]f64, [2]f64) bool,
) std.mem.Allocator.Error!?[]const [2]f64 {
    if (cur.len < 2 or polylineLength(cur) > joint_span_mm) return null;
    const pad_a = padAt(job.pads, cur[0]) orelse return null;
    const pad_b = padAt(job.pads, cur[cur.len - 1]) orelse return null;
    const ca = pad_a.centre();
    const cb = pad_b.centre();
    if (dist(ca, cb) < eps) return null;
    if (!onLand(pad_a, ca) or !onLand(pad_b, cb)) return null;
    var best = Candidate{
        .pts = cur,
        .len = polylineLength(cur),
        .squares = squareCorners(cur),
        .bends = bendCorners(cur),
        .held = true,
    };
    const budget = best.len + mitre_budget_mm;
    for (headings) |da| {
        const ra = escapeReach(pad_a, da);
        const xa = [2]f64{ ca[0] + da[0] * ra, ca[1] + da[1] * ra };
        if (!clear(ctx, ca, xa)) continue;
        for (headings) |db| {
            const rb = escapeReach(pad_b, db);
            const xb = [2]f64{ cb[0] + db[0] * rb, cb[1] + db[1] * rb };
            if (!clear(ctx, cb, xb)) continue;
            for (0..3) |variant| {
                const built = (try jointOn(Context, arena, .{
                    .ends = .{ ca, cb },
                    .exits = .{ xa, xb },
                    .reach = .{ ra, rb },
                }, variant, ctx, clear)) orelse continue;
                if (polylineLength(built) > budget + eps) continue;
                if (stripsVia(job.vias, cur, built, job.half)) continue;
                if (dropsPad(job.pads, cur, built, job.half)) continue;
                if (dropsJoin(job.joins, cur, built, job.half)) continue;
                const cand = Candidate{
                    .pts = built,
                    .len = polylineLength(built),
                    .squares = squareCorners(built),
                    .bends = bendCorners(built),
                    .dirty = try lapsCount(arena, job.pads, cur, built, job.half),
                };
                if (better(cand, best)) best = cand;
            }
        }
    }
    return if (best.held) null else best.pts;
}

/// One joint candidate's geometry: the two pad centres, the two escape exits,
/// and each ray's reach (no corner may fall back inside either escape zone).
const Joint = struct {
    ends: [2][2]f64,
    exits: [2][2]f64,
    reach: [2]f64,
};

/// The copper joining the two exits, `variant` picking how: 0 = they already
/// meet or a single octilinear run joins them, 1/2 = the two octilinear elbows.
/// Null when this variant does not apply, puts a corner back inside an escape
/// zone, or does not clear.
fn jointOn(
    comptime Context: type,
    arena: std.mem.Allocator,
    j: Joint,
    variant: usize,
    ctx: Context,
    comptime clear: fn (Context, [2]f64, [2]f64) bool,
) std.mem.Allocator.Error!?[][2]f64 {
    const gap = dist(j.exits[0], j.exits[1]);
    var mid: ?[2]f64 = null;
    if (variant == 0) {
        if (gap > eps and !octilinear.isOctilinear(j.exits[0], j.exits[1])) return null;
    } else {
        if (gap <= eps or octilinear.isOctilinear(j.exits[0], j.exits[1])) return null;
        mid = octilinear.elbows(j.exits[0], j.exits[1])[variant - 1];
    }
    // No vertex may sit inside the clearance either ray reserves for itself.
    if (dist(j.exits[1], j.ends[0]) < j.reach[0] - eps) return null;
    if (dist(j.exits[0], j.ends[1]) < j.reach[1] - eps) return null;
    if (mid) |m| {
        if (dist(m, j.ends[0]) < j.reach[0] - eps) return null;
        if (dist(m, j.ends[1]) < j.reach[1] - eps) return null;
    }
    var pts: std.ArrayList([2]f64) = .empty;
    try pts.append(arena, j.ends[0]);
    try pts.append(arena, j.exits[0]);
    if (mid) |m| try pts.append(arena, m);
    if (gap > eps) try pts.append(arena, j.exits[1]);
    try pts.append(arena, j.ends[1]);
    for (1..pts.items.len) |i| {
        if (dist(pts.items[i - 1], pts.items[i]) <= eps) continue;
        if (!clear(ctx, pts.items[i - 1], pts.items[i])) return null;
    }
    return pts.items;
}

fn reversed(arena: std.mem.Allocator, pts: []const [2]f64) std.mem.Allocator.Error![][2]f64 {
    const out = try arena.alloc([2]f64, pts.len);
    for (pts, 0..) |p, i| out[pts.len - 1 - i] = p;
    return out;
}

/// The pad `p` sits on, or null when the point is on none of them.
fn padAt(pads: []const Pad, p: [2]f64) ?Pad {
    for (pads) |pad| {
        if (inBox(pad, p) and onLand(pad, p)) return pad;
    }
    return null;
}

// ── Board seam ─────────────────────────────────────────────────────────────

/// The clearance probe pinned to one layer, so the geometry above stays free of
/// the router's obstacle model.
const LayerProbe = struct {
    probe: router.TautProbe,
    layer: u8,

    fn clear(self: LayerProbe, a: [2]f64, b: [2]f64) bool {
        return self.probe.clear(self.layer, a, b);
    }
};

/// Give every generated pad connection on a finished board its escape ray.
///
/// Runs at the very end of the finish, after `pad_entry` (which it calls — see
/// the ladder in the module header) and after the last straighten pass, because
/// the gloss reads a chain's pad end as a fixed anchor and would re-straighten
/// the ray away. Nets outside a scoped route's selection are left byte-identical.
pub fn passBoard(board: router.CleanupBoard) std.mem.Allocator.Error!void {
    try via_centre.passBoard(board);
    try pad_entry.passBoard(board);
    const ctx = board.ctx;
    const placement = board.placement;
    var touched = false;
    for (placement.diff_pairs) |dp| {
        if (try passPair(board, dp)) touched = true;
    }
    for (0..placement.nets.len) |net_i| {
        if (!netSelected(ctx.selected_nets, net_i)) continue;
        if (escapeRuled(placement, net_i) or bypass_intent.exactNet(placement, net_i) or inDiffPair(placement, net_i)) continue;
        const ni: i32 = @intCast(net_i);
        router.setNetParams(ctx, placement, net_i);
        router.rebuildCopperIndex(ctx, board.tracks.items, board.vias.items);
        const rebuilt = (try escapeNet(board, ni)) orelse continue;
        route_cleanup.removeNetTracks(board.tracks, ni);
        try board.tracks.appendSlice(ctx.arena, rebuilt);
        touched = true;
    }
    if (touched) router.copperCompacted(ctx);
}

/// One net's copper with every pad end re-anchored, or null when nothing moved.
fn escapeNet(board: router.CleanupBoard, ni: i32) std.mem.Allocator.Error!?[]const router.Track {
    const arena = board.ctx.arena;
    const pads = try netPads(arena, board.ctx.obs, ni);
    if (pads.len == 0) return null;
    var vias: std.ArrayList(Barrel) = .empty;
    for (board.vias.items) |v| if (v.net == ni) try vias.append(arena, .{ .at = .{ v.x, v.y }, .r = v.dia / 2 });
    const probe = router.TautProbe{
        .run = .{ .ctx = board.ctx, .net = ni, .tracks = board.tracks, .vias = board.vias },
    };
    var out: std.ArrayList(router.Track) = .empty;
    var changed = false;
    var layer: u8 = 0;
    const top = maxLayer(board.tracks.items, ni);
    while (true) : (layer += 1) {
        var segs: std.ArrayList(router.Track) = .empty;
        for (board.tracks.items) |t| {
            if (t.net != ni or t.layer != layer or segLen(t) < eps) continue;
            try segs.append(arena, t);
        }
        if (segs.items.len > 0) {
            const seam = LayerProbe{ .probe = probe, .layer = layer };
            const chains = try bend_smooth.extractChains(arena, segs.items);
            for (chains, 0..) |chain, ci| {
                const width = if (chain.widths.len > 0) chain.widths[0] else segs.items[0].width;
                const job = ChainJob{
                    .pts = chain.pts,
                    .pads = pads,
                    .half = width / 2,
                    .vias = vias.items,
                    .joins = try otherVertices(arena, chains, ci),
                };
                const pts = try escapeChain(LayerProbe, arena, job, seam, LayerProbe.clear);
                if (pts != null) changed = true;
                try emitPolyline(arena, &out, .{ .pts = pts orelse chain.pts, .layer = layer, .width = width, .net = ni });
            }
        }
        if (layer >= top) break;
    }
    return if (changed) try out.toOwnedSlice(arena) else null;
}

/// Every vertex of this layer's OTHER chains of the same net — where a rewrite
/// would break the net if it dropped the copper under one.
fn otherVertices(
    arena: std.mem.Allocator,
    chains: []const bend_smooth.Chain,
    skip: usize,
) std.mem.Allocator.Error![]const [2]f64 {
    var out: std.ArrayList([2]f64) = .empty;
    for (chains, 0..) |chain, i| {
        if (i == skip) continue;
        try out.appendSlice(arena, chain.pts);
    }
    return out.toOwnedSlice(arena);
}

/// One emitted polyline: its points and the copper identity they carry.
const Emit = struct {
    pts: []const [2]f64,
    layer: u8,
    width: f64,
    net: i32,
};

/// Emit a polyline as tracks, collapsing collinear vertices on the way out.
///
/// The ray and the join it grows into are frequently collinear (an escape that
/// simply continues into the route it serves), and so is a chain the rewrite did
/// not touch. Emitting one segment per straight run instead of one per vertex is
/// the same operation `route_cleanup.collapseCollinearNets` performs earlier in
/// the finish — identical copper, fewer objects for a reader, KiCad and the DRC
/// to carry.
fn emitPolyline(
    arena: std.mem.Allocator,
    out: *std.ArrayList(router.Track),
    e: Emit,
) std.mem.Allocator.Error!void {
    if (e.pts.len < 2) return;
    var from = e.pts[0];
    for (1..e.pts.len) |k| {
        if (dist(from, e.pts[k]) < eps) continue;
        if (k + 1 < e.pts.len and collinear(from, e.pts[k], e.pts[k + 1])) continue;
        try out.append(arena, .{
            .x1 = from[0],
            .y1 = from[1],
            .x2 = e.pts[k][0],
            .y2 = e.pts[k][1],
            .layer = e.layer,
            .width = e.width,
            .net = e.net,
        });
        from = e.pts[k];
    }
}

/// This net's SMD lands. Through-hole pads are left out: the barrel is the
/// connection on every layer, so copper across the annulus is not an escape.
fn netPads(
    arena: std.mem.Allocator,
    obs: []const pad_grid.PadObs,
    net: i32,
) std.mem.Allocator.Error![]const Pad {
    var out: std.ArrayList(Pad) = .empty;
    for (obs) |o| {
        if (o.net != net or o.thru) continue;
        try out.append(arena, .{ .x0 = o.x0, .y0 = o.y0, .x1 = o.x1, .y1 = o.y1, .poly = o.poly });
    }
    return out.toOwnedSlice(arena);
}

/// Is this net's escape length authored by a `(max-freq …)` rule? Such a net
/// keeps its own longer straight reserve and its arcs.
fn escapeRuled(placement: optimizer.Placement, net_i: usize) bool {
    return net_i < placement.rules.net.len and placement.rules.net[net_i].rf.escape_mm > 0;
}

fn inDiffPair(placement: optimizer.Placement, net_i: usize) bool {
    for (placement.diff_pairs) |dp| {
        if (dp.p == net_i or dp.n == net_i) return true;
    }
    return false;
}

fn netSelected(selected: []const bool, net_i: usize) bool {
    return selected.len == 0 or (net_i < selected.len and selected[net_i]);
}

fn maxLayer(tracks: []const router.Track, ni: i32) u8 {
    var m: u8 = 0;
    for (tracks) |t| {
        if (t.net == ni and t.layer > m) m = t.layer;
    }
    return m;
}

fn segLen(t: router.Track) f64 {
    return std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
}

// ── Differential pairs ─────────────────────────────────────────────────────

/// A pair's two legs as this pass needs them: one straight segment each, on one
/// layer, with the pads their ends sit on. `a`/`b` index the two ENDS of the
/// pair; `[0]`/`[1]` index the P and N legs.
const PairLegs = struct {
    at: [2][2][2]f64,
    pad: [2][2]Pad,
    seg: [2]router.Track,
    layer: u8,
    net: [2]i32,
};

/// Re-draw a declared differential pair's straight legs with escape rays, both
/// legs sharing one heading and one escape length at each end.
///
/// That sharing is the whole point: a pair is only a pair while its two legs
/// stay the same length, and giving each leg its own escape decision would put
/// the skew back that `diff_direct`'s straight construction had just removed.
/// Both legs gain exactly the same two vectors, so their length difference —
/// and with it the pair's skew — is preserved to the last float.
///
/// Only the shape `diff_direct.directLegs` draws is handled: one straight
/// segment per leg, pad centre to pad centre. A coupled pair's copper belongs
/// to `diff_route`'s construction, which mitres and length-matches it as a
/// unit, and is left alone.
fn passPair(board: router.CleanupBoard, dp: diff_pairs.DiffPair) std.mem.Allocator.Error!bool {
    const ctx = board.ctx;
    if (!netSelected(ctx.selected_nets, dp.p) or !netSelected(ctx.selected_nets, dp.n)) return false;
    if (escapeRuled(board.placement, dp.p) or escapeRuled(board.placement, dp.n)) return false;
    const legs = (try pairLegs(board, dp)) orelse return false;
    if (pairCompliant(legs)) return false;
    const built = (try pairGeometry(board, legs)) orelse return false;
    for (0..2) |leg| {
        try emitPolyline(ctx.arena, board.tracks, .{
            .pts = &built[leg],
            .layer = legs.layer,
            .width = legs.seg[leg].width,
            .net = legs.net[leg],
        });
    }
    return true;
}

/// The pair's legs, or null unless both nets carry exactly one straight segment
/// on one layer with both ends on their own SMD lands.
fn pairLegs(board: router.CleanupBoard, dp: diff_pairs.DiffPair) std.mem.Allocator.Error!?PairLegs {
    const arena = board.ctx.arena;
    const nets = [2]i32{ @intCast(dp.p), @intCast(dp.n) };
    var at: [2][2][2]f64 = undefined;
    var pad: [2][2]Pad = undefined;
    var seg: [2]router.Track = undefined;
    var layer: ?u8 = null;
    for (nets, 0..) |ni, leg| {
        seg[leg] = singleSegment(board.tracks.items, ni) orelse return null;
        if (layer) |l| {
            if (l != seg[leg].layer) return null;
        } else layer = seg[leg].layer;
        const pads = try netPads(arena, board.ctx.obs, ni);
        const ends = [2][2]f64{ .{ seg[leg].x1, seg[leg].y1 }, .{ seg[leg].x2, seg[leg].y2 } };
        for (ends, 0..) |e, end| {
            pad[end][leg] = padAt(pads, e) orelse return null;
            at[end][leg] = e;
        }
    }
    // The N leg's ends may have come off the board in the other order; pair
    // them with P's by proximity so end A of one is end A of the other.
    if (dist(at[0][0], at[0][1]) + dist(at[1][0], at[1][1]) >
        dist(at[0][0], at[1][1]) + dist(at[1][0], at[0][1]))
    {
        std.mem.swap([2]f64, &at[0][1], &at[1][1]);
        std.mem.swap(Pad, &pad[0][1], &pad[1][1]);
    }
    return .{ .at = at, .pad = pad, .seg = seg, .layer = layer.?, .net = nets };
}

/// A net's one non-degenerate track, or null when it has none or several.
fn singleSegment(tracks: []const router.Track, ni: i32) ?router.Track {
    var found: ?router.Track = null;
    for (tracks) |t| {
        if (t.net != ni or segLen(t) < eps) continue;
        if (found != null) return null;
        found = t;
    }
    return found;
}

/// Are all four of the pair's ends already compliant?
fn pairCompliant(legs: PairLegs) bool {
    for (0..2) |end| {
        for (0..2) |leg| {
            const pts = [2][2]f64{ legs.at[end][leg], legs.at[1 - end][leg] };
            if (!compliantEnd(&pts, legs.pad[end][leg])) return false;
        }
    }
    return true;
}

/// How much longer one leg of a pair may come out than the other, over what the
/// copper it replaces already differed by (mm).
///
/// A pair's legs are the same net twice over, and their LENGTH DIFFERENCE is the
/// electrical property the pair exists to control — a skew budget is measured in
/// tens of microns, while this rule's whole subject is cosmetic. So the rewrite
/// is offered to a pair only when it can be drawn without spending skew: the
/// clearing candidate with the closest-matched legs wins, and if even that one
/// is worse than the copper it would replace, the pair keeps what it has.
const skew_slack_mm: f64 = 0.005;

/// Both legs' four-point polylines: pad centre, escape, escape, pad centre —
/// or null when no heading pair clears for both legs, or when the best of them
/// would cost the pair more skew than `skew_slack_mm`.
///
/// The pair's own copper comes OFF the board before anything is probed: the two
/// legs are different nets, so each one's old segment is foreign copper to the
/// other's probe and would refuse every candidate. On a refusal the originals go
/// straight back, so a pair this cannot serve keeps exactly the copper it had.
fn pairGeometry(board: router.CleanupBoard, legs: PairLegs) std.mem.Allocator.Error!?[2][4][2]f64 {
    const base = pairBase(legs);
    const was = skew(.{
        .{ legs.at[0][0], legs.at[0][0], legs.at[1][0], legs.at[1][0] },
        .{ legs.at[0][1], legs.at[0][1], legs.at[1][1], legs.at[1][1] },
    });
    for (0..2) |leg| route_cleanup.removeNetTracks(board.tracks, legs.net[leg]);
    router.rebuildCopperIndex(board.ctx, board.tracks.items, board.vias.items);
    // Shortest first, among the candidates that clear AND do not spend skew:
    // the pair's length difference is a hard filter, its copper length the
    // tie-break, so the legs come out as direct as the rule allows.
    var best: ?[2][4][2]f64 = null;
    var best_len = std.math.inf(f64);
    for (0..fan_len) |ka| {
        for (0..fan_len) |kb| {
            const cand = pairCandidate(legs, .{ fanHeading(base[0], ka), fanHeading(base[1], kb) });
            if (skew(cand) > was + skew_slack_mm) continue;
            const len = legLength(cand, 0) + legLength(cand, 1);
            if (len >= best_len) continue;
            if (!pairClears(board, legs, cand)) continue;
            best = cand;
            best_len = len;
        }
    }
    if (best) |cand| return cand;
    for (legs.seg) |t| try board.tracks.append(board.ctx.arena, t);
    router.rebuildCopperIndex(board.ctx, board.tracks.items, board.vias.items);
    return null;
}

/// The length difference between a pair's two legs — its skew, as the copper
/// carries it.
fn skew(cand: [2][4][2]f64) f64 {
    return @abs(legLength(cand, 0) - legLength(cand, 1));
}

fn legLength(cand: [2][4][2]f64, leg: usize) f64 {
    var out: f64 = 0;
    for (1..cand[leg].len) |k| out += dist(cand[leg][k - 1], cand[leg][k]);
    return out;
}

/// The heading index each end's escapes start their search from: along the line
/// joining the two ends' midpoints, so the pair leaves each end pointing at the
/// other — the direction its straight legs already run.
fn pairBase(legs: PairLegs) [2]usize {
    const mid = [2][2]f64{
        .{ (legs.at[0][0][0] + legs.at[0][1][0]) / 2, (legs.at[0][0][1] + legs.at[0][1][1]) / 2 },
        .{ (legs.at[1][0][0] + legs.at[1][1][0]) / 2, (legs.at[1][0][1] + legs.at[1][1][1]) / 2 },
    };
    return .{
        baseHeading(&.{ mid[0], mid[1] }, mid[0]) orelse 0,
        baseHeading(&.{ mid[1], mid[0] }, mid[1]) orelse 0,
    };
}

/// The two legs' polylines for one choice of headings. Each end's escape length
/// is the LONGER of the two legs' requirements there, so both legs get the same
/// vector and the pair's skew is untouched.
fn pairCandidate(legs: PairLegs, dir: [2][2]f64) [2][4][2]f64 {
    var out: [2][4][2]f64 = undefined;
    var reach: [2]f64 = undefined;
    for (0..2) |end| {
        reach[end] = @max(
            escapeReach(legs.pad[end][0], dir[end]),
            escapeReach(legs.pad[end][1], dir[end]),
        );
    }
    for (0..2) |leg| {
        for (0..2) |end| {
            const c = legs.pad[end][leg].centre();
            const e = [2]f64{ c[0] + dir[end][0] * reach[end], c[1] + dir[end][1] * reach[end] };
            out[leg][if (end == 0) 0 else 3] = c;
            out[leg][if (end == 0) 1 else 2] = e;
        }
    }
    return out;
}

/// Does this candidate clear — every leg probed against the board at its own
/// net's parameters, and the two legs keeping the copper clearance the board
/// demands between two nets?
///
/// The gap is checked here rather than by the probe because the pair's own
/// copper is off the board while candidates are tried (see `pairGeometry`), so
/// neither leg is foreign copper to the other's probe. `need` is the same sum
/// DRC applies — half of each leg's width plus the clearance.
fn pairClears(board: router.CleanupBoard, legs: PairLegs, cand: [2][4][2]f64) bool {
    for (0..2) |leg| {
        router.setNetParams(board.ctx, board.placement, @intCast(legs.net[leg]));
        const probe = router.TautProbe{ .run = .{
            .ctx = board.ctx,
            .net = legs.net[leg],
            .tracks = board.tracks,
            .vias = board.vias,
        } };
        for (1..cand[leg].len) |k| {
            if (dist(cand[leg][k - 1], cand[leg][k]) < eps) continue;
            if (!probe.clear(legs.layer, cand[leg][k - 1], cand[leg][k])) return false;
        }
    }
    const need = (legs.seg[0].width + legs.seg[1].width) / 2 + board.ctx.params.clearance;
    return legGap(cand) + eps >= need;
}

/// The closest approach between the two legs — the pair's own coupling floor,
/// which a rewrite may never tighten.
fn legGap(cand: [2][4][2]f64) f64 {
    var out = std.math.inf(f64);
    for (1..cand[0].len) |i| {
        for (1..cand[1].len) |j| {
            out = @min(out, segGap(cand[0][i - 1], cand[0][i], cand[1][j - 1], cand[1][j]));
        }
    }
    return out;
}

/// The exact distance between two segments. Two segments that do not cross are
/// closest at one of their four endpoints, which is what makes this closed
/// form rather than a sample.
fn segGap(a0: [2]f64, a1: [2]f64, b0: [2]f64, b1: [2]f64) f64 {
    if (crosses(a0, a1, b0, b1)) return 0;
    return @min(
        @min(pointSeg(a0, b0, b1), pointSeg(a1, b0, b1)),
        @min(pointSeg(b0, a0, a1), pointSeg(b1, a0, a1)),
    );
}

/// Do the two segments properly cross?
fn crosses(a0: [2]f64, a1: [2]f64, b0: [2]f64, b1: [2]f64) bool {
    const d1 = side(b0, b1, a0);
    const d2 = side(b0, b1, a1);
    const d3 = side(a0, a1, b0);
    const d4 = side(a0, a1, b1);
    return ((d1 > 0) != (d2 > 0)) and ((d3 > 0) != (d4 > 0));
}

fn side(a: [2]f64, b: [2]f64, p: [2]f64) f64 {
    return (b[0] - a[0]) * (p[1] - a[1]) - (b[1] - a[1]) * (p[0] - a[0]);
}

fn pointSeg(p: [2]f64, a: [2]f64, b: [2]f64) f64 {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const len2 = dx * dx + dy * dy;
    if (len2 < eps) return dist(p, a);
    const t = std.math.clamp(((p[0] - a[0]) * dx + (p[1] - a[1]) * dy) / len2, 0, 1);
    return dist(p, .{ a[0] + t * dx, a[1] + t * dy });
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A 0.3 x 0.9 mm land — a 0.5 mm-pitch QFN pad, long axis vertical — centred
/// at the origin, which is where the router anchors a terminal on it.
const qfn_pad = Pad{ .x0 = -0.15, .y0 = -0.45, .x1 = 0.15, .y1 = 0.45 };

/// A test board: axis-aligned boxes a segment may not touch.
const Board = struct {
    walls: []const [4]f64 = &.{},

    fn clear(self: Board, a: [2]f64, b: [2]f64) bool {
        for (self.walls) |w| {
            if (hits(w, a, b)) return false;
        }
        return true;
    }
};

fn hits(wall: [4]f64, from: [2]f64, to: [2]f64) bool {
    for (0..201) |i| {
        const t = @as(f64, @floatFromInt(i)) / 200.0;
        const x = from[0] + t * (to[0] - from[0]);
        const y = from[1] + t * (to[1] - from[1]);
        if (x >= wall[0] and x <= wall[2] and y >= wall[1] and y <= wall[3]) return true;
    }
    return false;
}

/// The escape ray a rewritten chain begins with, as (heading, length).
fn rayOf(pts: []const [2]f64) [3]f64 {
    return .{ pts[1][0] - pts[0][0], pts[1][1] - pts[0][1], dist(pts[0], pts[1]) };
}

/// A 0.62 x 0.56 mm land — an 0402 bypass cap's terminal — centred at the
/// origin. The board owner's own example was drawn on one of these.
const cap_pad = Pad{ .x0 = -0.31, .y0 = -0.28, .x1 = 0.31, .y1 = 0.28 };

/// A 0.9 x 0.9 mm land — straps-synth-lmx2595's C13, the bypass cap the board
/// owner's second complaint was drawn on. Its west reach is 0.6 mm, which is
/// where the square corner sat.
const bypass_pad = Pad{ .x0 = -0.45, .y0 = -0.45, .x1 = 0.45, .y1 = 0.45 };

// spec: placement/pad-escape - an escape that is already compliant still competes against the whole fan, so a legal ray aimed the wrong way is re-read instead of waved through

test "a compliant escape aimed the wrong way is re-aimed off its square corner" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    // straps-synth-lmx2595's LMX_VREFVCO2 — C13 pad 1 -> U1 pad 29, the cap end
    // first, translated onto the origin. The escape is LEGAL: centre-anchored,
    // due west, straight for its full 0.6 mm reach. It is also aimed away from
    // the pin it serves, so the copper turns 90 degrees the instant it is clear
    // of the land (2026-08-12: "there are still pins like this green one that
    // definitely could've been escaped out at a 45 degrees angle").
    const pts = [_][2]f64{
        .{ 0, 0 },
        .{ -0.6, 0 },
        .{ -0.6, 0.8935 },
        .{ -1.1565, 1.45 },
        .{ -1.34, 1.45 },
    };
    // The old early-out's premise: by the rule alone there is nothing to fix.
    try testing.expect(compliantEnd(&pts, bypass_pad));
    try testing.expectEqual(@as(usize, 1), squareCorners(&pts));
    const job = EndJob{ .pts = &pts, .pad = bypass_pad };
    const out = (try escapeHead(Board, arena, job, .{}, Board.clear)) orelse
        return testing.expect(false);
    // Re-read against the whole fan, the same connection leaves on the diagonal
    // that points at the pin — no square corner, and LESS copper than the L it
    // replaces, so nothing was bought with a detour.
    try testing.expectEqual([2]f64{ 0, 0 }, out[0]);
    try testing.expect(compliantEnd(out, bypass_pad));
    try testing.expectEqual(@as(usize, 0), squareCorners(out));
    try testing.expect(polylineLength(out) + eps < polylineLength(&pts));
}

// spec: placement/pad-escape - the pass is a fixed point, so running it again over its own output rewrites nothing

test "a second pass over the pass's own output changes nothing" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    // Every shape this pass has an opinion about: the re-aimed compliant escape
    // above, the off-centre entry, and the maze's lattice step.
    const green = [_][2]f64{ .{ 0, 0 }, .{ -0.6, 0 }, .{ -0.6, 0.8935 }, .{ -1.1565, 1.45 }, .{ -1.34, 1.45 } };
    const off_centre = [_][2]f64{ .{ 0, -0.33 }, .{ 0, -0.51 }, .{ 1.5, -0.51 } };
    const lattice = [_][2]f64{ .{ 0, 0.33 }, .{ 0, 0.6 }, .{ 0.11, 0.6 }, .{ 0.65, 1.14 } };
    const cases = [_]struct { pts: []const [2]f64, pad: Pad }{
        .{ .pts = &green, .pad = bypass_pad },
        .{ .pts = &off_centre, .pad = qfn_pad },
        .{ .pts = &lattice, .pad = qfn_pad },
    };
    for (cases) |cs| {
        const first = (try escapeHead(Board, arena, .{ .pts = cs.pts, .pad = cs.pad }, .{}, Board.clear)) orelse
            return testing.expect(false);
        // Applied to its own output the pass finds nothing better and declines
        // to rewrite — so the copper a board carries after one run is what it
        // carries after any number of them.
        try testing.expect((try escapeHead(Board, arena, .{ .pts = first, .pad = cs.pad }, .{}, Board.clear)) == null);
    }
}

// spec: placement/pad-escape - the score counts total bends after square corners, so an escape that draws the connection straight beats one that leaves on the maze's heading and then mitres

test "a straight escape beats one that mitres after the pad" {
    var mitred = [_][2]f64{ .{ 0, 0 }, .{ 0.6, 0 }, .{ 1.4, 0.8 } }; // one 45 corner
    var straight = [_][2]f64{ .{ 0, 0 }, .{ 1.4, 1.4 } }; // none
    // Neither turns a SQUARE corner, so square count alone cannot separate them
    // and the tie would fall to the lowest fan index — the maze's own heading,
    // which is the mitred one.
    try testing.expectEqual(@as(usize, 0), squareCorners(&mitred));
    try testing.expectEqual(@as(usize, 0), squareCorners(&straight));
    try testing.expectEqual(@as(usize, 1), bendCorners(&mitred));
    try testing.expectEqual(@as(usize, 0), bendCorners(&straight));
    const cands = [_]Candidate{
        .{ .pts = &mitred, .len = 1.731, .squares = 0, .bends = 1 },
        .{ .pts = &straight, .len = 1.980, .squares = 0, .bends = 0 },
    };
    const won = chooseEscape(&cands) orelse return testing.expect(false);
    try testing.expectEqual(@as(usize, 0), won.bends);
    // …but only after square corners, which still outrank everything: a straight
    // run that turns a right angle never beats a mitre that does not.
    var square = [_][2]f64{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 } };
    const over = [_]Candidate{
        .{ .pts = &mitred, .len = 1.731, .squares = 0, .bends = 1 },
        .{ .pts = &square, .len = 1.5, .squares = 1, .bends = 1 },
    };
    const kept = chooseEscape(&over) orelse return testing.expect(false);
    try testing.expectEqual(@as(usize, 0), kept.squares);
    // A run the maze split into collinear steps turns nothing at all.
    var split = [_][2]f64{ .{ 0, 0 }, .{ 0, -0.3 }, .{ 0, -0.9 } };
    try testing.expectEqual(@as(usize, 0), bendCorners(&split));
}

// spec: placement/pad-escape - a rewrite never drops a same-net land the old copper covered, so re-aiming an escape cannot strand a part daisy-chained between the ends

test "a land the old copper ran across is never left behind" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const half = 0.0635;
    // straps-synth-lmx2595's LO_BIAS_A: C19 -> R6 -> R5 -> L1, a daisy chain that
    // turns 90 degrees ON each land it crosses. Both END escapes are legal, so
    // the pass now looks at it — and the direct line between the ends is both
    // shorter and straighter than the chain, which would strand R6 and R5.
    const pads = [_]Pad{
        .{ .x0 = -0.31, .y0 = -0.28, .x1 = 0.31, .y1 = 0.28 }, // C19.1, at the origin
        .{ .x0 = -1.32, .y0 = -0.28, .x1 = -0.70, .y1 = 0.28 }, // R6.1
        .{ .x0 = -1.32, .y0 = -1.28, .x1 = -0.70, .y1 = -0.72 }, // R5.2
        .{ .x0 = -0.32, .y0 = -1.28, .x1 = 0.30, .y1 = -0.72 }, // L1.1
    };
    const pts = [_][2]f64{ .{ 0, 0 }, .{ -1.01, 0 }, .{ -1.01, -1 }, .{ -0.01, -1 } };
    const job = EndJob{ .pts = &pts, .pad = pads[0], .half = half, .pads = &pads };
    const built = try escapeHead(Board, arena, job, .{}, Board.clear);
    // Either the end kept its copper, or what replaced it still covers both
    // middle lands — never the third thing, which would open the net.
    try testing.expect(built == null or !dropsPad(&pads, &pts, built.?, half));
    // The guard itself: the direct line between the two ends drops them both,
    // and copper that still crosses them does not.
    const direct = [_][2]f64{ .{ 0, 0 }, .{ -0.01, -1 } };
    try testing.expect(dropsPad(&pads, &pts, &direct, half));
    try testing.expect(!dropsPad(&pads, &pts, &pts, half));
}

// spec: placement/pad-escape - the escape is chosen for the connection it draws, so every fan heading and rejoin point is built and the candidate leaving the fewest square corners wins

test "a square corner right out of the pad is replaced by a 45 degree one" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    // straps-synth-lmx2595's C4 -> U1 pad 21, translated onto the origin: the
    // maze left the land WEST, ran 0.46 mm, turned 90 degrees south and only
    // then took the diagonal it wanted. Somewhere in the fan is a rewrite that
    // needs no square corner at all — and it is the shorter one.
    const pts = [_][2]f64{
        .{ -0.19, 0 },
        .{ -0.46, 0 },
        .{ -0.46, -0.28 },
        .{ -0.95, -0.77 },
        .{ -1.55, -0.77 },
    };
    const job = EndJob{ .pts = &pts, .pad = cap_pad, .vias = &.{} };
    const out = (try escapeHead(Board, arena, job, .{}, Board.clear)) orelse
        return testing.expect(false);
    try testing.expectEqual([2]f64{ 0, 0 }, out[0]);
    try testing.expect(compliantEnd(out, cap_pad));
    try testing.expectEqual(@as(usize, 0), squareCorners(out));
    // …and it did not buy that with copper: the rewrite the pass used to take —
    // straight on (west, the base of the fan), rejoining at the first vertex —
    // turns a square corner AND is the longer of the two.
    const straight_on = (try escapeOn(Board, arena, job, .{ .base = 4, .k = 0, .skip = 0 }, .{}, Board.clear)) orelse
        return testing.expect(false);
    try testing.expectEqual(@as(usize, 1), squareCorners(straight_on));
    try testing.expect(polylineLength(out) < polylineLength(straight_on));
}

// spec: placement/pad-escape - an escape may rejoin the route past the maze's own first bend when that bend is lattice noise sitting on its exit, and never past a vertex far enough out to be a routing decision

test "the join may skip the maze's own first bend rather than meet it square" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    // straps-synth-lmx2595's U1 pad 19 -> R8, translated onto the origin: out
    // of the QFN land 0.6 mm north, 0.11 mm sideways — the lattice's way of
    // saying "diagonal" — and then the diagonal. Meeting that 0.11 mm step is
    // the square corner; rejoining past it is the same length and has none.
    const pts = [_][2]f64{ .{ 0, 0.33 }, .{ 0, 0.6 }, .{ 0.11, 0.6 }, .{ 0.65, 1.14 } };
    const job = EndJob{ .pts = &pts, .pad = qfn_pad, .vias = &.{} };
    const at_bend = (try escapeOn(Board, arena, job, .{ .base = 2, .k = 0, .skip = 0 }, .{}, Board.clear)) orelse
        return testing.expect(false);
    try testing.expectEqual(@as(usize, 1), squareCorners(at_bend));
    const past_bend = (try escapeOn(Board, arena, job, .{ .base = 2, .k = 0, .skip = 1 }, .{}, Board.clear)) orelse
        return testing.expect(false);
    try testing.expectEqual(@as(usize, 0), squareCorners(past_bend));
    try testing.expect(polylineLength(past_bend) <= polylineLength(at_bend) + eps);
    // A skip past the end of the tail is not a rewrite at all.
    try testing.expect((try escapeOn(Board, arena, job, .{ .base = 2, .k = 0, .skip = 9 }, .{}, Board.clear)) == null);
    // Neither is one that would swallow a vertex too far out to be lattice
    // noise: the same chain with its step a millimetre along keeps its corner.
    const far = [_][2]f64{ .{ 0, 0.33 }, .{ 0, 0.6 }, .{ 1.1, 0.6 }, .{ 1.64, 1.14 } };
    const far_job = EndJob{ .pts = &far, .pad = qfn_pad, .vias = &.{} };
    try testing.expect((try escapeOn(Board, arena, far_job, .{ .base = 2, .k = 0, .skip = 1 }, .{}, Board.clear)) == null);
    // …and the pass as a whole leaves this connection square-free.
    const out = (try escapeHead(Board, arena, job, .{}, Board.clear)) orelse
        return testing.expect(false);
    try testing.expect(compliantEnd(out, qfn_pad));
    try testing.expectEqual(@as(usize, 0), squareCorners(out));
}

// spec: placement/pad-escape - a heading wins on corners only while its copper stays within the mitre budget of the shortest candidate, so a mitre is never bought with a detour

test "a square-free heading that costs more than the mitre budget is refused" {
    var pts_a = [_][2]f64{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 } }; // one square corner
    var pts_b = [_][2]f64{ .{ 0, 0 }, .{ 1, 1 } }; // none, but long
    const near = [_]Candidate{
        .{ .pts = &pts_a, .len = 2.0, .squares = 1 },
        .{ .pts = &pts_b, .len = 2.4, .squares = 0 },
    };
    // 0.4 mm over the shortest is inside the budget: the mitre is worth it.
    const mitred = chooseEscape(&near) orelse return testing.expect(false);
    try testing.expectEqual(@as(usize, 0), mitred.squares);
    const far = [_]Candidate{
        .{ .pts = &pts_a, .len = 2.0, .squares = 1 },
        .{ .pts = &pts_b, .len = 2.0 + mitre_budget_mm + 0.01, .squares = 0 },
    };
    // A hair over it is a detour, and the square corner is kept instead.
    const kept = chooseEscape(&far) orelse return testing.expect(false);
    try testing.expectEqual(@as(usize, 1), kept.squares);
    try testing.expect(chooseEscape(&.{}) == null);
}

// spec: placement/pad-escape - headings tied on square corners, total bends and length resolve to the lowest fan index, so the escape choice stays deterministic

test "a tie between fan headings resolves to the one tried first" {
    var first = [_][2]f64{ .{ 0, 0 }, .{ 1, 0 } };
    var second = [_][2]f64{ .{ 0, 0 }, .{ 0, 1 } };
    const tied = [_]Candidate{
        .{ .pts = &first, .len = 1.0, .squares = 1 },
        .{ .pts = &second, .len = 1.0, .squares = 1 },
    };
    const won = chooseEscape(&tied) orelse return testing.expect(false);
    try testing.expectEqual(@as(f64, 1), won.pts[1][0]);
    // Collinear steps are one run, so a split straight line turns no corner.
    const split = [_][2]f64{ .{ 0, 0 }, .{ 0, -0.3 }, .{ 0, -0.9 }, .{ 0.6, -1.5 } };
    try testing.expectEqual(@as(usize, 0), squareCorners(&split));
}

// spec: placement/pad-escape - a connection to a pad is anchored on the pad centre and leaves it straight on a 45 degree heading until it is clear of the land
test "an off-centre entry is re-anchored on the centre and sent out on a compass ray" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    // What `pad_entry`'s trim leaves: the copper starts 0.12 mm inside the land's
    // south edge, runs out and away.
    const pts = [_][2]f64{ .{ 0, -0.33 }, .{ 0, -0.51 }, .{ 1.5, -0.51 } };
    const job = EndJob{ .pts = &pts, .pad = qfn_pad, .vias = &.{} };
    const out = (try escapeHead(Board, arena, job, .{}, Board.clear)) orelse
        return testing.expect(false);
    // Anchored exactly on the pad centre…
    try testing.expectEqual([2]f64{ 0, 0 }, out[0]);
    // …straight north (the heading it already left on), out past the land's
    // 0.45 mm half-length by the full clearance.
    const ray = rayOf(out);
    try testing.expectApproxEqAbs(@as(f64, 0), ray[0], 1e-12);
    try testing.expectApproxEqAbs(-(0.45 + pad_escape_clear_mm), ray[1], 1e-12);
    try testing.expect(compliantEnd(out, qfn_pad));
}

// spec: placement/pad-escape - copper that already leaves the pad centre straight and clear competes as the candidate to beat and is kept byte-identical unless something strictly better clears
test "a compliant entry nothing beats is not rewritten" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const pts = [_][2]f64{ .{ 0, 0 }, .{ 0, -1.2 }, .{ 1.0, -2.2 } };
    try testing.expect(compliantEnd(&pts, qfn_pad));
    const job = EndJob{ .pts = &pts, .pad = qfn_pad, .vias = &.{} };
    try testing.expect((try escapeHead(Board, arena, job, .{}, Board.clear)) == null);
    // …and it is a TIE that keeps it, not an absent comparison: the fan does
    // build this very shape (straight on, rejoining at the first vertex), and
    // the incumbent holds because equal is not better. Copper already on the
    // board is only ever displaced by something strictly better.
    const rebuilt = (try escapeOn(Board, arena, job, .{ .base = 6, .k = 0, .skip = 0 }, .{}, Board.clear)) orelse
        return testing.expect(false);
    try testing.expectEqual(squareCorners(&pts), squareCorners(rebuilt));
    try testing.expectEqual(bendCorners(&pts), bendCorners(rebuilt));
    try testing.expectApproxEqAbs(polylineLength(&pts), polylineLength(rebuilt), 1e-12);
}

// spec: placement/pad-escape - an entry that bends before it is clear of the land is not compliant, and neither is one on an arbitrary heading
test "the compliance test names a short run and an off-compass heading" {
    // Straight and centred, but it turns 0.05 mm past the land's edge.
    const early_bend = [_][2]f64{ .{ 0, 0 }, .{ 0, -0.5 }, .{ 1, -0.5 } };
    try testing.expect(!compliantEnd(&early_bend, qfn_pad));
    // Centred and long, but 20° off the compass.
    const off_compass = [_][2]f64{ .{ 0, 0 }, .{ 0.5, -1.4 } };
    try testing.expect(!compliantEnd(&off_compass, qfn_pad));
    // Straight, on the compass, long enough — but anchored off the centre.
    const off_centre = [_][2]f64{ .{ 0.05, 0 }, .{ 0.05, -1.4 } };
    try testing.expect(!compliantEnd(&off_centre, qfn_pad));
    // Collinear vertices are one run, not a bend.
    const split = [_][2]f64{ .{ 0, 0 }, .{ 0, -0.3 }, .{ 0, -0.9 }, .{ 1, -1.9 } };
    try testing.expect(compliantEnd(&split, qfn_pad));
}

// spec: placement/pad-escape - a blocked escape falls back to the copper it already had rather than costing the connection
test "an escape blocked on every heading refuses the rewrite" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const pts = [_][2]f64{ .{ 0, -0.33 }, .{ 0, -0.51 }, .{ 1.5, -0.51 } };
    const job = EndJob{ .pts = &pts, .pad = qfn_pad, .vias = &.{} };
    // A wall ringing the land: no ray can reach its clearance point.
    const walls = [_][4]f64{.{ -1.2, -1.2, 1.2, 1.2 }};
    const board = Board{ .walls = &walls };
    try testing.expect((try escapeHead(Board, arena, job, board, Board.clear)) == null);
}

// spec: placement/pad-escape - an escape whose straight-on heading is blocked swivels to the next compass heading rather than giving up
test "a blocked heading is replaced by the nearest one that clears" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const pts = [_][2]f64{ .{ 0, -0.33 }, .{ 0, -0.9 }, .{ 1.5, -0.9 } };
    // A wall straight north of the land only.
    const walls = [_][4]f64{.{ -0.05, -0.75, 0.05, -0.55 }};
    const job = EndJob{ .pts = &pts, .pad = qfn_pad, .vias = &.{} };
    const out = (try escapeHead(Board, arena, job, .{ .walls = &walls }, Board.clear)) orelse
        return testing.expect(false);
    try testing.expectEqual([2]f64{ 0, 0 }, out[0]);
    try testing.expect(compliantEnd(out, qfn_pad));
    // …and it is a real compass heading, not a nudge off the blocked one.
    try testing.expect(octilinear.isOctilinear(out[0], out[1]));
    try testing.expect(@abs(out[1][0]) > eps);
}

// spec: placement/pad-escape - a connection shorter than the escape the rule asks for keeps the copper it has
test "a hop with no room for a full escape is left alone" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    // A hop to a neighbour 0.5 mm away, on a land that needs 0.6 mm of escape in
    // that direction: no ray can clear the land without passing the very point
    // it is serving, so the copper is left as it is.
    const pts = [_][2]f64{ .{ 0, -0.33 }, .{ 0, -0.5 } };
    const job = EndJob{ .pts = &pts, .pad = qfn_pad, .vias = &.{} };
    try testing.expect((try escapeHead(Board, arena, job, .{}, Board.clear)) == null);
    // The same hop to a neighbour far enough out IS re-anchored.
    const room = [_][2]f64{ .{ 0, -0.33 }, .{ 0, -0.75 } };
    const far = EndJob{ .pts = &room, .pad = qfn_pad, .vias = &.{} };
    try testing.expect((try escapeHead(Board, arena, far, .{}, Board.clear)) != null);
}

// spec: placement/pad-escape - a rewrite never leaves a via the old copper carried, so re-anchoring cannot abandon a barrel
test "every via the old copper carried is still carried by the new" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const half = 0.0635;
    // A 0.9 mm square land — a bypass cap's pad, wide enough that copper down
    // one side of it is nowhere near the centre.
    const land = Pad{ .x0 = -0.45, .y0 = -0.45, .x1 = 0.45, .y1 = 0.45 };
    const pts = [_][2]f64{ .{ 0.35, -0.3 }, .{ 0.35, -1.4 } };
    // The shape that opened `lmk05318b-clock`'s LMK_CAP_PLL1: the chain ends on
    // a barrel standing on the land, so its terminal is the via, not the pad.
    const on_end = [_]Barrel{.{ .at = .{ 0.35, -0.3 }, .r = 0.15 }};
    const job = EndJob{ .pts = &pts, .pad = land, .half = half, .vias = &on_end };
    const built = try escapeHead(Board, arena, job, .{}, Board.clear);
    // Either the end kept its copper, or what replaced it still reaches the
    // barrel — never the third thing, which is what opened that net.
    try testing.expect(built == null or !stripsVia(&on_end, &pts, built.?, half));
    // The guard itself. A barrel the copper merely BRUSHES counts too — that is
    // barracuda's V_12V, where the abandoned via took the whole net with it.
    const moved = [_][2]f64{ .{ 0, 0 }, .{ 0, -1.4 } };
    const brushed = [_]Barrel{.{ .at = .{ 0.5, -0.5 }, .r = 0.1 }};
    try testing.expect(stripsVia(&brushed, &pts, &moved, half));
    try testing.expect(stripsVia(&on_end, &pts, &moved, half));
    // …and a barrel the new copper still reaches is no reason to refuse.
    const on_far = [_]Barrel{.{ .at = .{ 0, -1.4 }, .r = 0.15 }};
    try testing.expect(!stripsVia(&on_far, &pts, &moved, half));
}

// spec: placement/pad-escape - both ends of a pad-to-pad chain get their own escape ray
test "a pad-to-pad chain is re-anchored at both ends" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const far = Pad{ .x0 = -0.15, .y0 = 2.55, .x1 = 0.15, .y1 = 3.45 };
    const pads = [_]Pad{ qfn_pad, far };
    // The land-run shape: a straight run between the two lands, but sitting
    // 0.06 mm off both centres, so neither end is anchored.
    const pts = [_][2]f64{ .{ 0.06, -0.3 }, .{ 0.06, 3.3 } };
    const job = ChainJob{ .pts = &pts, .pads = &pads, .vias = &.{} };
    const out = (try escapeChain(Board, arena, job, .{}, Board.clear)) orelse
        return testing.expect(false);
    try testing.expectEqual([2]f64{ 0, 0 }, out[0]);
    try testing.expectEqual([2]f64{ 0, 3 }, out[out.len - 1]);
    try testing.expect(compliantEnd(out, qfn_pad));
    const back = try reversed(arena, out);
    try testing.expect(compliantEnd(back, far));
}

// spec: placement/pad-escape - a short chain whose two ends both sit on lands is planned as one shape, so a jog between two legal rays is not forced to meet one of them square
test "a short pad-to-pad hop is planned end to end and loses its square corner" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    // straps-synth-lmx2595's LMX_VBIASVARAC, in board coordinates: U1 pad 33's
    // 0.3 x 0.9 QFN land at (1.25, -2.95) and C11 pad 1's 0.9 x 0.95 land at
    // (2.40, -4.52). Both ends of the copper on the board are COMPLIANT — 0.6 mm
    // south is pad 33's reach to the micron, and the 1.37 mm diagonal is C11's —
    // so no single-ended re-aim has anything to say, and the 0.18 mm jog between
    // the two legal rays can only meet the southward one at 90 degrees.
    const pin = Pad{ .x0 = 1.10, .y0 = -3.40, .x1 = 1.40, .y1 = -2.50 };
    const cap = Pad{ .x0 = 1.95, .y0 = -4.995, .x1 = 2.85, .y1 = -4.045 };
    const pads = [_]Pad{ pin, cap };
    const on_board = [_][2]f64{
        .{ 1.25, -2.95 },
        .{ 1.25, -3.55 },
        .{ 1.43, -3.55 },
        .{ 2.40, -4.52 },
    };
    try testing.expect(compliantEnd(&on_board, pin));
    try testing.expectEqual(@as(usize, 1), squareCorners(&on_board));
    const job = ChainJob{ .pts = &on_board, .pads = &pads, .half = 0.0635 };
    const out = (try jointPlan(Board, arena, job, &on_board, .{}, Board.clear)) orelse
        return testing.expect(false);
    // Planned as one shape it leaves BOTH lands on the diagonal, jogs once in
    // open board, and turns no square corner — for LESS copper than the L it
    // replaces, so nothing was bought.
    try testing.expectEqual(@as(usize, 0), squareCorners(out));
    try testing.expect(polylineLength(out) + eps < polylineLength(&on_board));
    try testing.expectEqual([2]f64{ 1.25, -2.95 }, out[0]);
    try testing.expectEqual([2]f64{ 2.40, -4.52 }, out[out.len - 1]);
    try testing.expect(compliantEnd(out, pin));
    const back = try reversed(arena, out);
    try testing.expect(compliantEnd(back, cap));
    // And it is a fixed point: run over its own output, the identical
    // enumeration finds this same shape and nothing strictly beats it.
    try testing.expect((try jointPlan(Board, arena, job, out, .{}, Board.clear)) == null);
}

// spec: placement/pad-escape - the joint plan is bounded to a hop and refused whenever it does not strictly beat the copper it would replace
test "the joint plan leaves a long chain and an already-straight hop alone" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const far = Pad{ .x0 = -0.15, .y0 = 5.55, .x1 = 0.15, .y1 = 6.45 };
    const pads = [_]Pad{ qfn_pad, far };
    // A chain longer than the hop the planner is scoped to: it crossed the
    // board for a reason, and a three-legged probe is not evidence enough to
    // overrule that.
    const long_run = [_][2]f64{ .{ 0, 0 }, .{ 0, 3 }, .{ 0.4, 3.4 }, .{ 0, 3.8 }, .{ 0, 6 } };
    try testing.expect(polylineLength(&long_run) > joint_span_mm);
    const long_job = ChainJob{ .pts = &long_run, .pads = &pads, .half = 0.0635 };
    try testing.expect((try jointPlan(Board, arena, long_job, &long_run, .{}, Board.clear)) == null);
    // …and a hop already drawn as one straight run between two centres has
    // nothing to beat, so it is left byte for byte.
    const near = Pad{ .x0 = -0.15, .y0 = 1.55, .x1 = 0.15, .y1 = 2.45 };
    const near_pads = [_]Pad{ qfn_pad, near };
    const straight = [_][2]f64{ .{ 0, 0 }, .{ 0, 2 } };
    const near_job = ChainJob{ .pts = &straight, .pads = &near_pads, .half = 0.0635 };
    try testing.expect((try jointPlan(Board, arena, near_job, &straight, .{}, Board.clear)) == null);
}

// spec: placement/pad-escape - the escape reach is measured to the land's own edge on the heading it leaves by, plus the clearance
test "the escape reach follows the land's edge on each heading" {
    // North: half the 0.9 mm length, plus the clearance.
    try testing.expectApproxEqAbs(0.45 + pad_escape_clear_mm, escapeReach(qfn_pad, .{ 0, -1 }), 1e-12);
    // East: half the 0.3 mm width, plus the clearance.
    try testing.expectApproxEqAbs(0.15 + pad_escape_clear_mm, escapeReach(qfn_pad, .{ 1, 0 }), 1e-12);
    // North-east: out to whichever edge the diagonal meets first (the east one).
    try testing.expectApproxEqAbs(
        0.15 * std.math.sqrt2 + pad_escape_clear_mm,
        escapeReach(qfn_pad, headings[7]),
        1e-12,
    );
}

// spec: placement/pad-escape - a ring of copper has no ends to discipline and is left exactly as it is
test "a cycle is not re-anchored" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const pads = [_]Pad{qfn_pad};
    // Duplicated copper — the same segment emitted twice — reads as a two-node
    // ring. Its two "ends" are one point, so re-anchoring the first would leave
    // the second walking back out to it and the copper would double over.
    const ring = [_][2]f64{ .{ 0, -0.3 }, .{ 0, -1.5 }, .{ 0, -0.3 } };
    const job = ChainJob{ .pts = &ring, .pads = &pads };
    try testing.expect((try escapeChain(Board, arena, job, .{}, Board.clear)) == null);
}

// spec: placement/pad-escape - lapping a same-net land the connection does not serve is the first key of the escape score, so no number of corners saved buys copper into a pad's flank
test "a rewrite that would leave the other end lapping its own land is refused" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    // straps-synth-lmx2595's LMX_RFOUTBM, both lands translated so U1 pad 18
    // sits at the origin: a 0.3 x 0.9 QFN land, and R9 pad 1's 0.54 x 0.64 land
    // 1.14 mm north and 0.15 mm east of it. Re-aiming R9's end may rejoin one
    // vertex further along, and the candidate that does turns ONE corner where
    // the disciplined pair of rays turns two -- by drawing a 0.21 mm diagonal
    // that stops on pad 18's own edge and runs north along it, half a track
    // width into the 0.2 mm corridor to pad 19.
    const r9 = Pad{ .x0 = -0.12, .y0 = 0.82, .x1 = 0.42, .y1 = 1.46 };
    const pads = [_]Pad{ qfn_pad, r9 };
    const lapping = [_][2]f64{ .{ 0.15, 1.14 }, .{ 0.15, 0.15 }, .{ 0, 0 } };
    const clean = [_][2]f64{ .{ 0.15, 1.14 }, .{ 0.15, 0.67 }, .{ 0, 0.52 }, .{ 0, 0 } };
    const half = 0.0635;
    // Both end on R9's centre and on pad 18's, and the lapping one turns FEWER
    // corners for no more copper -- which is why the guard has to exist.
    try testing.expect(polylineLength(&lapping) <= polylineLength(&clean) + eps);
    try testing.expect(bendCorners(&lapping) < bendCorners(&clean));
    try testing.expectEqual(@as(usize, 1), try lapsCount(arena, &pads, &clean, &lapping, half));
    // The count is one-sided, so copper that already laps a land can always be
    // improved: going the other way spoils nothing.
    try testing.expectEqual(@as(usize, 0), try lapsCount(arena, &pads, &lapping, &clean, half));
    // …and the score puts that ahead of every corner key, so the lapping shape
    // loses to the clean one despite turning fewer corners for no more copper.
    const dirty = Candidate{
        .pts = &lapping,
        .len = polylineLength(&lapping),
        .squares = squareCorners(&lapping),
        .bends = bendCorners(&lapping),
        .dirty = 1,
    };
    const tidy = Candidate{
        .pts = &clean,
        .len = polylineLength(&clean),
        .squares = squareCorners(&clean),
        .bends = bendCorners(&clean),
        .dirty = 0,
    };
    try testing.expect(better(tidy, dirty));
    try testing.expect(!better(dirty, tidy));
}

// spec: placement/pad-escape - a rewrite never drops a junction the old copper carried, so no re-anchor can open a net
test "a junction the old copper carried is never dropped" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const half = 0.0635;
    const pts = [_][2]f64{ .{ 0, -0.33 }, .{ 0, -0.51 }, .{ 1.5, -0.51 } };
    // Another chain of the same net ends ON this one, just in front of the land
    // — the very shape the rule forbids, and one a re-anchor could leave behind.
    const joined = [_][2]f64{.{ 0.5, -0.45 }};
    const job = EndJob{ .pts = &pts, .pad = qfn_pad, .half = half, .joins = &joined };
    const built = try escapeHead(Board, arena, job, .{}, Board.clear);
    try testing.expect(built == null or !dropsJoin(&joined, &pts, built.?, half));
    // The guard itself: copper that no longer reaches the junction is refused,
    // copper that still does is not.
    const away = [_][2]f64{ .{ 0, 0 }, .{ 0, -0.6 }, .{ 1.41, -0.6 }, .{ 1.5, -0.51 } };
    try testing.expect(dropsJoin(&joined, &pts, &away, half));
    try testing.expect(!dropsJoin(&.{.{ 1.5, -0.51 }}, &pts, &away, half));
}

// spec: placement/pad-escape - a differential pair keeps its old copper unless the rewrite can be drawn without spending skew
test "a pair candidate is scored by the length difference it leaves" {
    // Two legs of equal length carry no skew…
    const even = [2][4][2]f64{
        .{ .{ 0, 0 }, .{ 0.5, 0 }, .{ 2, 0 }, .{ 2.5, 0 } },
        .{ .{ 0, 1 }, .{ 0.5, 1 }, .{ 2, 1 }, .{ 2.5, 1 } },
    };
    try testing.expectApproxEqAbs(@as(f64, 0), skew(even), 1e-12);
    // …and one leg reaching further carries exactly the difference, which is
    // what the pair path compares against the copper it would replace.
    const uneven = [2][4][2]f64{
        .{ .{ 0, 0 }, .{ 0.5, 0 }, .{ 2, 0 }, .{ 2.5, 0 } },
        .{ .{ 0, 1 }, .{ 0.5, 1 }, .{ 2, 1 }, .{ 2.8, 1 } },
    };
    try testing.expectApproxEqAbs(@as(f64, 0.3), skew(uneven), 1e-12);
}

// spec: placement/pad-escape - both legs of a differential pair take the same escape heading and length at each end, so the rewrite cannot add skew
test "a pair's two legs gain identical escape vectors" {
    // straps-synth-lmx2595's OSCIN pair: two 0402 lands 1.1 mm apart feeding two
    // QFN pins 0.5 mm apart, 1.27 mm across — the shape `diff_direct` draws.
    const cap = [2]Pad{
        .{ .x0 = -0.28, .y0 = -0.70, .x1 = 0.28, .y1 = -0.40 },
        .{ .x0 = -0.28, .y0 = 0.40, .x1 = 0.28, .y1 = 0.70 },
    };
    const pin = [2]Pad{
        .{ .x0 = 1.12, .y0 = -0.40, .x1 = 1.42, .y1 = -0.10 },
        .{ .x0 = 1.12, .y0 = 0.10, .x1 = 1.42, .y1 = 0.40 },
    };
    const legs = PairLegs{
        .at = .{
            .{ .{ 0, -0.55 }, .{ 0, 0.55 } },
            .{ .{ 1.27, -0.25 }, .{ 1.27, 0.25 } },
        },
        .pad = .{ cap, pin },
        .seg = .{
            .{ .x1 = 0, .y1 = -0.55, .x2 = 1.27, .y2 = -0.25, .layer = 0, .width = 0.127, .net = 1 },
            .{ .x1 = 0, .y1 = 0.55, .x2 = 1.27, .y2 = 0.25, .layer = 0, .width = 0.127, .net = 2 },
        },
        .layer = 0,
        .net = .{ 1, 2 },
    };
    const cand = pairCandidate(legs, .{ headings[0], headings[4] });
    // Each leg starts and ends on its own pad centre…
    try testing.expectEqual([2]f64{ 0, -0.55 }, cand[0][0]);
    try testing.expectEqual([2]f64{ 1.27, -0.25 }, cand[0][3]);
    // …and the two legs' escape vectors are identical, so neither leg gains a
    // millimetre the other does not.
    try testing.expectEqual(
        [2]f64{ cand[0][1][0] - cand[0][0][0], cand[0][1][1] - cand[0][0][1] },
        [2]f64{ cand[1][1][0] - cand[1][0][0], cand[1][1][1] - cand[1][0][1] },
    );
    try testing.expectEqual(
        [2]f64{ cand[0][2][0] - cand[0][3][0], cand[0][2][1] - cand[0][3][1] },
        [2]f64{ cand[1][2][0] - cand[1][3][0], cand[1][2][1] - cand[1][3][1] },
    );
    // The escape is the LONGER of the two lands' requirements, so both legs
    // clear their own land.
    try testing.expect(compliantEnd(&cand[0], cap[0]));
    try testing.expect(compliantEnd(&cand[1], cap[1]));
}
