//! Deterministic routing display score. This weighted scalar trades completion
//! against geometry and must not decide adoption. Compare geometry errors,
//! then connectivity, then geometry costs when choosing a board.
//!
//! Every input is derivable from what the existing routing-result surfaces
//! (`/api/pcb-describe?route=1`, the route-review replay, the
//! `route_experiment` tool) already hold; no surface has to invent a
//! measurement. The formula AND the two measurements it needs beyond the plain
//! counters (`bendCount`, `qualityWarnCount`) all live here, so two surfaces
//! that feed the same terms cannot disagree about a board — and a surface that
//! feeds fewer of them is under-penalising rather than measuring differently
//! (see `Inputs`).
//!
//! v2 formula (higher is better):
//!   1000·completion − 0.5·vias − 0.1·trace_mm − 0.05·bends
//!     − 1·quality_warns − 50·drc_errors
//! `completion` = routed / total (a board with no routable nets is complete,
//! not a divide-by-zero failure — see `completionFraction`). `drc_errors`
//! counts ERROR-severity DRC violations only; `quality_warns` is the narrow
//! slice of WARNING-severity findings the router inflicts on itself.
//!
//! ## What changed from v1, and why
//!
//! v1 was `1000·completion − 2·vias − 0.1·trace_mm − 50·drc_errors`. It had two
//! measured defects, both of which made it disagree with the router it judges.
//!
//! **The via was priced 20× too dear.** At 2.0 a via cost the same as 20 mm of
//! copper, while the maze itself prices a layer change at `via_cost_mult` (4.0,
//! `router.zig`) grid steps ≈ 1.02 mm — so the search preferred a board the
//! judge then rejected. Measured on `bcuda-lt3045-ldo` (layout
//! "layout 06-22 15:25"): the design's `(preferred-layers "B.Cu")` wave on VIN
//! spends 2 extra vias and buys back 5.14 mm of copper and 3 corners, and v1
//! scored the better board DOWN, 959.64 → 956.15. At 0.5 a via still costs a
//! real 5 mm of trace — a drill, an annular ring, a reliability joint, board
//! area — but it can no longer veto a shorter, straighter route on its own.
//!
//! **Self-inflicted geometry was free.** Bends and the router's own DRC
//! WARNINGS both scored exactly 0, so the score could not see the defects the
//! router's own DRC was already reporting — on that same fixture the surface
//! route leaves 39 `dangling_copper`/`land_transit` warnings against the B.Cu
//! route's 24, a 15-point difference v1 rounded to nothing. Two terms close
//! that:
//!
//!   • `bends` at 0.05 — a corner is an impedance and etch discontinuity worth
//!     about half a millimetre of trace. A twenty-corner staircase loses to a
//!     straight run of the same length.
//!   • `quality_warns` at 1.0 — one warning costs 10 mm of trace or 2 vias:
//!     loud enough to steer a tie, still 50× below a fab-blocking error, and
//!     scoped to the two kinds the ROUTER creates (`dangling_copper`,
//!     `land_transit`, see `qualityWarnCount`) so an advisory warning about the
//!     board's design can never move the routing verdict.
//!
//! Completion (1000) and the DRC-error weight (50) are deliberately unchanged:
//! geometry can outweigh an additional completed net. An open net is
//! charged exactly once (through completion — `drc.errorCount` drops
//! `net_open` for precisely this reason).

const std = @import("std");
const drc = @import("drc.zig");
const route_result = @import("route_result.zig");

/// The formula version. Bump it whenever the weights or the shape of `score`
/// change, so a stored score is only ever compared against another of the same
/// version (the describe/replay JSON tags each score with `score_v`).
pub const formula_version: u32 = 2;

/// Reward for a fully routed board (completion == 1.0). The dominant term: a
/// complete board earns this before any penalty, so completion always outweighs
/// via/trace/bend/DRC noise.
pub const completion_weight: f64 = 1000.0;
/// Penalty per via — each layer change costs a drill, an annular ring, and a
/// reliability joint. Held near the maze's OWN via price (~1 mm of trace, see
/// the module header) so the search and the judge want the same board.
pub const via_penalty: f64 = 0.5;
/// Penalty per millimetre of routed copper — shorter routing is weakly better.
pub const trace_mm_penalty: f64 = 0.1;
/// Penalty per direction change along a routed chain (see `bendCount`) — a
/// corner is worth about half a millimetre of trace.
pub const bend_penalty: f64 = 0.05;
/// Penalty per self-inflicted DRC WARNING (see `qualityWarnCount`) — copper the
/// board can be fabricated with, but that a better route would not have drawn.
pub const quality_warn_penalty: f64 = 1.0;
/// Penalty per ERROR-severity DRC violation — each one is fab-blocking, so it
/// weighs far more than a via yet still can't erase a completion gain alone.
pub const drc_error_penalty: f64 = 50.0;

/// The routing-result fields the score reads — every one derivable from what
/// the describe/replay surfaces already hold. `drc_errors` is ERROR-severity
/// DRC violations only (the caller filters warnings out before constructing
/// this, normally via `drc.errorCount`).
///
/// `bends` and `quality_warns` default to 0 so a surface that does not yet
/// measure them still compiles and still produces a valid score. A caller that
/// CAN measure them must, through the shared helpers below: two boards scored
/// with different terms populated are not comparable, however equal their
/// `score_v`.
pub const Inputs = struct {
    routed: usize,
    total: usize,
    vias: usize,
    trace_mm: f64,
    drc_errors: usize,
    /// Direction changes along the routed copper — `bendCount(alloc, tracks)`.
    bends: usize = 0,
    /// Self-inflicted DRC warnings — `qualityWarnCount(violations)`.
    quality_warns: usize = 0,
};

/// Completion fraction, `routed / total`, clamped to the documented empty-board
/// convention: a board with no routable nets (`total == 0`) is fully complete
/// (1.0), not a divide-by-zero failure — there was nothing to fail to route.
pub fn completionFraction(routed: usize, total: usize) f64 {
    if (total == 0) return 1.0;
    return @as(f64, @floatFromInt(routed)) / @as(f64, @floatFromInt(total));
}

/// The v2 routing score (higher is better) — a pure, deterministic function of
/// `in` with no clock or RNG, so the same routing result always scores the same.
pub fn score(in: Inputs) f64 {
    return completion_weight * completionFraction(in.routed, in.total) -
        via_penalty * @as(f64, @floatFromInt(in.vias)) -
        trace_mm_penalty * in.trace_mm -
        bend_penalty * @as(f64, @floatFromInt(in.bends)) -
        quality_warn_penalty * @as(f64, @floatFromInt(in.quality_warns)) -
        drc_error_penalty * @as(f64, @floatFromInt(in.drc_errors));
}

// ── Shared measurement helpers ──────────────────────────────────────────────
//
// These exist so every surface feeding `score` counts the SAME way. A bend
// count that each caller re-derived would drift the moment one of them handled
// a T-junction or a zero-length segment differently, and two scores counted
// differently are not comparable even at the same `formula_version`.

/// Two copper endpoints are the same VERTEX when they lie within this distance
/// (mm) of each other. Router-emitted chain joins share bitwise-identical
/// coordinates; the tolerance is here so copper that has round-tripped through
/// a text format still chains.
pub const bend_join_tol_mm: f64 = 1e-6;

/// A chain vertex counts as a BEND only when the run deviates from straight by
/// more than this many degrees. Below it the corner is a grid/rounding artifact
/// of a split collinear run, not a turn anyone etched.
pub const bend_min_deg: f64 = 1.0;

/// `cos(bend_min_deg)`. Two unit directions leaving one vertex have dot product
/// −1 when the run passes straight through and −cos θ for a turn of θ, so the
/// vertex is a bend exactly when `dot > -bend_cos_min`.
const bend_cos_min: f64 = @cos(bend_min_deg * std.math.pi / 180.0);

/// One endpoint of one routed segment, carrying the unit direction that leaves
/// it along its own segment.
const BendEnd = struct {
    net: i32,
    layer: u8,
    x: f64,
    y: f64,
    dx: f64,
    dy: f64,
};

fn bendEndLess(_: void, a: BendEnd, b: BendEnd) bool {
    if (a.net != b.net) return a.net < b.net;
    if (a.layer != b.layer) return a.layer < b.layer;
    if (a.x != b.x) return a.x < b.x;
    return a.y < b.y;
}

/// Do these two endpoints meet at one vertex? Same net, same copper layer, and
/// coincident within `bend_join_tol_mm`.
fn sameVertex(a: BendEnd, b: BendEnd) bool {
    return a.net == b.net and a.layer == b.layer and
        @abs(a.x - b.x) <= bend_join_tol_mm and @abs(a.y - b.y) <= bend_join_tol_mm;
}

/// THE canonical bend count for a routed board — direction changes along the
/// routed copper, counted once per corner.
///
/// Same-net same-layer segments chain through shared endpoints (within
/// `bend_join_tol_mm`); a vertex where exactly two of them meet is an INTERIOR
/// vertex of one chain, and it is a bend when the two segments deviate from
/// collinear by more than `bend_min_deg`. Deliberate exclusions, each because
/// there is no single honest answer otherwise:
///
///   • A vertex where one segment ends (degree 1) is a chain END — a pad
///     landing or a via drop, not a turn.
///   • A vertex where three or more segments meet is a BRANCH. A star net
///     legitimately forks there and no one corner is "the" bend; charging every
///     pair would make a fork cost more than the detour that avoided it.
///   • A layer change is not a bend: the two sides sit in different layer
///     groups, so each contributes a chain end. The via term already prices it.
///   • Zero-length segments carry no direction and are skipped entirely.
///
/// Pure and deterministic — `alloc` backs one scratch array of endpoints that
/// is freed before return, and the sort is stable, so the same tracks always
/// yield the same count regardless of allocator or input order.
///
/// Not to be confused with `route_shape_score.Metrics.bends`, which chains
/// copper the same way but is a BENCH instrument: it counts every deviation
/// however small (no `bend_min_deg` floor, so grid-split runs inflate it), and
/// reaching it means paying for a whole `drc.TrackAdditionGate` over the board
/// plus a placement this scoring path does not have. The score needs a cheap,
/// placement-free number on every route; the bench needs the removable-bend
/// classification. Neither feeds the other.
pub fn bendCount(alloc: std.mem.Allocator, tracks: []const route_result.Track) std.mem.Allocator.Error!usize {
    if (tracks.len == 0) return 0;
    const ends = try alloc.alloc(BendEnd, tracks.len * 2);
    defer alloc.free(ends);

    var n: usize = 0;
    for (tracks) |t| {
        const dx = t.x2 - t.x1;
        const dy = t.y2 - t.y1;
        const len = std.math.hypot(dx, dy);
        if (!(len > bend_join_tol_mm)) continue;
        ends[n] = .{ .net = t.net, .layer = t.layer, .x = t.x1, .y = t.y1, .dx = dx / len, .dy = dy / len };
        ends[n + 1] = .{ .net = t.net, .layer = t.layer, .x = t.x2, .y = t.y2, .dx = -dx / len, .dy = -dy / len };
        n += 2;
    }
    const items = ends[0..n];
    std.mem.sort(BendEnd, items, {}, bendEndLess);

    var bends: usize = 0;
    var i: usize = 0;
    while (i < items.len) {
        var j = i + 1;
        while (j < items.len and sameVertex(items[i], items[j])) : (j += 1) {}
        if (j - i == 2) {
            const dot = items[i].dx * items[i + 1].dx + items[i].dy * items[i + 1].dy;
            if (dot > -bend_cos_min) bends += 1;
        }
        i = j;
    }
    return bends;
}

/// THE canonical `quality_warns` count — WARNING-severity DRC findings of the
/// kinds the ROUTER inflicts on the board itself:
///
///   • `dangling_copper` — a routed section whose deletion changes nothing.
///     Pure artifact copper the route should never have drawn.
///   • `land_transit` — same-net copper lapping a land instead of terminating
///     on it, which pushes the run into the corridor beside a fine-pitch pad.
///
/// Every other warning kind is excluded ON PURPOSE. A sharp-bend radius, a
/// diff-pair skew, a ground-via budget, an implicit junction on imported
/// copper: those are advisories about the DESIGN or about copper the router did
/// not author, and letting them move the routing verdict is how a score starts
/// rejecting good routes for reasons the router cannot act on.
pub fn qualityWarnCount(violations: []const drc.Violation) usize {
    var n: usize = 0;
    for (violations) |v| {
        if (v.severity != .warn) continue;
        switch (v.kind) {
            .dangling_copper, .land_transit => n += 1,
            else => {},
        }
    }
    return n;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: placement/route-score - a fully routed board with no vias, copper, bends, warnings, or DRC errors scores the completion weight
test "a perfect route scores the completion weight" {
    const s = score(.{ .routed = 5, .total = 5, .vias = 0, .trace_mm = 0, .drc_errors = 0 });
    try testing.expectEqual(completion_weight, s);
}

// spec: placement/route-score - each via, mm of copper, bend, quality warning, and DRC error lowers the score by its named weight
test "a partial route subtracts each weighted penalty" {
    // 75% complete, 2 vias, 10 mm copper, 4 bends, 3 quality warns, 1 DRC error:
    //   1000·0.75 − 0.5·2 − 0.1·10 − 0.05·4 − 1·3 − 50·1
    //   = 750 − 1 − 1 − 0.2 − 3 − 50 = 694.8.
    const s = score(.{
        .routed = 3,
        .total = 4,
        .vias = 2,
        .trace_mm = 10,
        .drc_errors = 1,
        .bends = 4,
        .quality_warns = 3,
    });
    try testing.expectApproxEqAbs(@as(f64, 694.8), s, 1e-9);
}

// spec: placement/route-score - a board with no routable nets counts as fully complete rather than a divide-by-zero
test "an empty board is fully complete, not a divide-by-zero" {
    try testing.expectEqual(@as(f64, 1.0), completionFraction(0, 0));
    const s = score(.{ .routed = 0, .total = 0, .vias = 0, .trace_mm = 0, .drc_errors = 0 });
    try testing.expectEqual(completion_weight, s);
    // v2's new terms are defaulted, so an empty board scores exactly what it
    // scored under v1 — the convention did not move with the formula.
    const spelled = score(.{
        .routed = 0,
        .total = 0,
        .vias = 0,
        .trace_mm = 0,
        .drc_errors = 0,
        .bends = 0,
        .quality_warns = 0,
    });
    try testing.expectEqual(completion_weight, spelled);
}

// spec: placement/route-score - more vias, longer copper, more bends, more quality warnings, or more DRC errors never raise the score
test "each penalty dimension is monotonically non-increasing" {
    const base_in = Inputs{
        .routed = 4,
        .total = 4,
        .vias = 1,
        .trace_mm = 5,
        .drc_errors = 0,
        .bends = 2,
        .quality_warns = 1,
    };
    const base = score(base_in);

    var more = base_in;
    more.vias += 1;
    try testing.expect(score(more) < base);

    more = base_in;
    more.trace_mm += 1;
    try testing.expect(score(more) < base);

    more = base_in;
    more.drc_errors += 1;
    try testing.expect(score(more) < base);

    more = base_in;
    more.bends += 1;
    try testing.expect(score(more) < base);

    more = base_in;
    more.quality_warns += 1;
    try testing.expect(score(more) < base);
}

// spec: placement/route-score - the display score can trade an additional completed net for geometry and is not an adoption policy
test "display score can trade a completed net for sixteen vias on Barracuda" {
    const fewer = score(.{ .routed = 119, .total = 130, .vias = 0, .trace_mm = 0, .drc_errors = 0 });
    const more = score(.{ .routed = 120, .total = 130, .vias = 16, .trace_mm = 0, .drc_errors = 0 });
    try testing.expect(more < fewer);
}

/// The v1 weights, spelled out, so the tests below can show what v2 changed
/// rather than assert it. Deliberately a private copy: nothing in the shipping
/// path may score a board this way again.
fn scoreV1(in: Inputs) f64 {
    return 1000.0 * completionFraction(in.routed, in.total) -
        2.0 * @as(f64, @floatFromInt(in.vias)) -
        0.1 * in.trace_mm -
        50.0 * @as(f64, @floatFromInt(in.drc_errors));
}

// spec: placement/route-score - spending vias to shorten and straighten a route now scores as the improvement it is, where v1 rejected it
test "the B.Cu detour trade scores better under v2 than the surface route" {
    // Both boards MEASURED through `route_experiment` on `bcuda-lt3045-ldo`,
    // layout "layout 06-22 15:25", read-only, one plan apart:
    //
    //   surface  (pcb-plan (route (wave "rest" (rest))))          — VIN on F.Cu
    //   b_cu     the design's authored plan, which adds
    //            (wave "vin" (nets "VIN") (preferred-layers "B.Cu"))
    //
    // Both route 5/5 with zero fab-blocking DRC, so only the geometry terms
    // move: the B.Cu run spends 2 extra vias and buys back 5.14 mm of copper,
    // 3 corners, and 15 of the router's own self-inflicted warnings.
    const surface = Inputs{
        .routed = 5,
        .total = 5,
        .vias = 19,
        .trace_mm = 23.613,
        .drc_errors = 0,
        .bends = 19,
        .quality_warns = 39,
    };
    const b_cu = Inputs{
        .routed = 5,
        .total = 5,
        .vias = 21,
        .trace_mm = 18.473,
        .drc_errors = 0,
        .bends = 16,
        .quality_warns = 24,
    };

    // v1 charged 4 points for the two vias and could see nothing else: it scored
    // the better board DOWN by 3.49 and the loop dutifully reverted it.
    try testing.expectApproxEqAbs(@as(f64, 959.6387), scoreV1(surface), 1e-4);
    try testing.expectApproxEqAbs(@as(f64, 956.1527), scoreV1(b_cu), 1e-4);
    try testing.expect(scoreV1(b_cu) < scoreV1(surface));

    // v2 accepts it by 14.66:
    //   −0.5·2 vias + 0.1·5.140 mm + 0.05·3 bends + 1·15 warns
    //   = −1 + 0.514 + 0.15 + 15 = +14.664.
    try testing.expectApproxEqAbs(@as(f64, 948.1887), score(surface), 1e-4);
    try testing.expectApproxEqAbs(@as(f64, 962.8527), score(b_cu), 1e-4);
    try testing.expect(score(b_cu) > score(surface));
    try testing.expectApproxEqAbs(@as(f64, 14.664), score(b_cu) - score(surface), 1e-4);
}

// spec: placement/route-score - two vias buy back their own cost from a millimetre of copper and a dozen corners, which v1 could never repay
test "the v2 via price lets copper and corners outweigh a pair of vias" {
    // The exchange rate the audit measured against, isolated from any one
    // board: 2 vias for 3.1 mm of copper. v1 priced the pair at 4 points, which
    // 3.1 mm (0.31) could not repay at ANY bend count, because v1 had none.
    const base = Inputs{ .routed = 8, .total = 8, .vias = 6, .trace_mm = 90, .drc_errors = 0, .bends = 40 };
    var swap = base;
    swap.vias += 2;
    swap.trace_mm -= 3.1;

    // v2 charges the pair 1 point, so the copper alone recovers a third of it
    // and the corners the layer swap straightens carry the rest. 13 is short by
    // a hair, 14 clears it — the tipping point, pinned so a future weight change
    // has to look at it.
    try testing.expect(score(swap) < score(base));
    swap.bends = base.bends - 13;
    try testing.expect(score(swap) < score(base));
    swap.bends = base.bends - 14;
    try testing.expect(score(swap) > score(base));
    try testing.expectApproxEqAbs(@as(f64, 0.01), score(swap) - score(base), 1e-9);

    // v1 rejects every one of those, however straight the result: the whole
    // bend dimension was invisible to it.
    try testing.expect(scoreV1(swap) < scoreV1(base));
}

// spec: placement/route-score - a via is priced within an order of magnitude of the maze's own via cost, so the search and the score want the same board
test "a via costs five millimetres of trace, not twenty" {
    const with_via = score(.{ .routed = 1, .total = 1, .vias = 1, .trace_mm = 0, .drc_errors = 0 });
    const with_5mm = score(.{ .routed = 1, .total = 1, .vias = 0, .trace_mm = 5, .drc_errors = 0 });
    try testing.expectApproxEqAbs(with_via, with_5mm, 1e-9);
}

const Track = route_result.Track;

fn seg(x1: f64, y1: f64, x2: f64, y2: f64, layer: u8, net: i32) Track {
    return .{ .x1 = x1, .y1 = y1, .x2 = x2, .y2 = y2, .layer = layer, .width = 0.2, .net = net };
}

// spec: placement/route-score - a straight run split into segments has no bends, and each corner in a chain counts once
test "bendCount counts corners, not segment joins" {
    const a = testing.allocator;
    try testing.expectEqual(@as(usize, 0), try bendCount(a, &.{}));

    // Three collinear segments = one straight run = no bends.
    const straight = [_]Track{
        seg(0, 0, 1, 0, 0, 3),
        seg(1, 0, 2, 0, 0, 3),
        seg(2, 0, 3, 0, 0, 3),
    };
    try testing.expectEqual(@as(usize, 0), try bendCount(a, &straight));

    // An L: one interior vertex, turned 90°.
    const elbow = [_]Track{
        seg(0, 0, 1, 0, 0, 3),
        seg(1, 0, 1, 1, 0, 3),
    };
    try testing.expectEqual(@as(usize, 1), try bendCount(a, &elbow));

    // A staircase: every interior vertex of the chain turns.
    const stair = [_]Track{
        seg(0, 0, 1, 0, 0, 3),
        seg(1, 0, 1, 1, 0, 3),
        seg(1, 1, 2, 1, 0, 3),
        seg(2, 1, 2, 2, 0, 3),
    };
    try testing.expectEqual(@as(usize, 3), try bendCount(a, &stair));
}

// spec: placement/route-score - bend chains never span a net, a layer, a branch, or a zero-length segment
test "bendCount chains only same-net same-layer degree-two vertices" {
    const a = testing.allocator;

    // Same geometry, different nets: two chain ends, no interior vertex.
    const cross_net = [_]Track{
        seg(0, 0, 1, 0, 0, 3),
        seg(1, 0, 1, 1, 0, 4),
    };
    try testing.expectEqual(@as(usize, 0), try bendCount(a, &cross_net));

    // Same geometry, different layers — this is a via drop, which the via term
    // already prices; the corner is not also a bend.
    const cross_layer = [_]Track{
        seg(0, 0, 1, 0, 0, 3),
        seg(1, 0, 1, 1, 1, 3),
    };
    try testing.expectEqual(@as(usize, 0), try bendCount(a, &cross_layer));

    // A T-junction: three segments meet, so no single corner is "the" bend.
    const branch = [_]Track{
        seg(0, 0, 1, 0, 0, 3),
        seg(1, 0, 2, 0, 0, 3),
        seg(1, 0, 1, 1, 0, 3),
    };
    try testing.expectEqual(@as(usize, 0), try bendCount(a, &branch));

    // A zero-length segment has no direction, so it is dropped rather than
    // counted as a third arm: the corner it sits on stays a degree-two vertex
    // and still reads as the one bend it is.
    const degenerate = [_]Track{
        seg(0, 0, 1, 0, 0, 3),
        seg(1, 0, 1, 0, 0, 3),
        seg(1, 0, 1, 1, 0, 3),
    };
    try testing.expectEqual(@as(usize, 1), try bendCount(a, &degenerate));
}

// spec: placement/route-score - a sub-degree jog is a rounding artifact, not a bend
test "bendCount ignores deviations below one degree" {
    const a = testing.allocator;
    // ~0.057° off collinear (1 mm run, 1 µm rise) — below the threshold.
    const jog = [_]Track{
        seg(0, 0, 1, 0, 0, 3),
        seg(1, 0, 2, 0.001, 0, 3),
    };
    try testing.expectEqual(@as(usize, 0), try bendCount(a, &jog));
    // ~2.86° off collinear (1 mm run, 50 µm rise) — a real corner.
    const turn = [_]Track{
        seg(0, 0, 1, 0, 0, 3),
        seg(1, 0, 2, 0.05, 0, 3),
    };
    try testing.expectEqual(@as(usize, 1), try bendCount(a, &turn));
    // The threshold really is `bend_min_deg`: a hair under it does not count, a
    // hair over it does.
    const rad = bend_min_deg * std.math.pi / 180.0;
    const under = [_]Track{
        seg(0, 0, 1, 0, 0, 3),
        seg(1, 0, 1 + @cos(rad * 0.99), @sin(rad * 0.99), 0, 3),
    };
    try testing.expectEqual(@as(usize, 0), try bendCount(a, &under));
    const over = [_]Track{
        seg(0, 0, 1, 0, 0, 3),
        seg(1, 0, 1 + @cos(rad * 1.01), @sin(rad * 1.01), 0, 3),
    };
    try testing.expectEqual(@as(usize, 1), try bendCount(a, &over));
}

// spec: placement/route-score - the score's warning term counts only the self-inflicted geometry kinds, never advisory warnings or errors
test "qualityWarnCount counts dangling copper and land transits only" {
    const v = [_]drc.Violation{
        .{ .x = 0, .y = 0, .gap = 0, .clearance = 0, .kind = .dangling_copper, .severity = .warn },
        .{ .x = 0, .y = 0, .gap = 0, .clearance = 0, .kind = .land_transit, .severity = .warn },
        .{ .x = 0, .y = 0, .gap = 0, .clearance = 0, .kind = .land_transit, .severity = .warn },
        // Advisory warnings about the design, not about copper the router drew.
        .{ .x = 0, .y = 0, .gap = 0, .clearance = 0, .kind = .implicit_junction, .severity = .warn },
        .{ .x = 0, .y = 0, .gap = 0, .clearance = 0, .kind = .single_layer_via, .severity = .warn },
        // Errors belong to the 50-point term, never to this one.
        .{ .x = 0, .y = 0, .gap = 0, .clearance = 0, .kind = .track_track, .severity = .err },
        .{ .x = 0, .y = 0, .gap = 0, .clearance = 0, .kind = .dangling_copper, .severity = .err },
    };
    try testing.expectEqual(@as(usize, 3), qualityWarnCount(&v));
    try testing.expectEqual(@as(usize, 0), qualityWarnCount(&.{}));
}
