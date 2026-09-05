//! The router's two SECOND OPINIONS: what happens after a connection has
//! routed, when the copper it drew turns out to run far past the distance its
//! own terminals span.
//!
//! The maze answers exactly the question it is asked — cheapest path under its
//! own cost model — and that answer can still be a route no hand router would
//! draw, because two of that model's terms are stated in LATTICE units while the
//! thing being chosen is physical. A via costs `grid.g * via_cost_mult`, so the
//! identical drill prices at 1.91 mm for a 0.35 mm power net (0.477 mm pitch)
//! and at 0.51 mm for a fine-pitch signal (0.127 mm) — and the wide net is
//! precisely the one whose surface tour costs the board most. The surface-first
//! experiment (`router.tryTopLayerFirst`) has a second version of the same
//! blind spot: it accepts ANY top-layer route a short net can close, however far
//! round the board that route went, and its acceptance is final.
//!
//! Neither can be fixed by a per-step cost, because "this is the cheapest path
//! to somewhere the net should not have gone" is a property of the FINISHED
//! route against its own terminals. So it is measured post hoc — the way
//! `manhattan_route.withinDetourCap` measures the axis-only rung's output — and
//! a connection that ran past `detour_guard_ratio` is offered exactly one
//! alternative, which is kept only if it is `detour_guard_margin` cheaper by a
//! measure denominated in millimetres rather than in grid steps.
//!
//! What these deliberately CANNOT do is undo a decision made before this net's
//! turn. Measured on `board-a-lt3045-ldo`: the `VIN` strap's 8.9 mm surface tour
//! is not a mispriced via at all — by the time VIN routes, the plane-stitch pass
//! has put 25 tracks and 20 through-barrels on the board and the bottom face
//! under the strap is walled off, so the surface genuinely is the cheapest
//! remaining path (415 of 523 expanded nodes admitted a via, 291 B.Cu nodes
//! settled, and dropping `via_cost_mult` to 1.0 left the chosen path unchanged
//! at the same cost). Routing that one net BEFORE the plane pass — what any
//! explicitly named `(wave …)` does, `route_policy.NetPolicy.wave.before_planes`
//! — takes the board from 23.6 mm/19 vias to 18.5 mm/21 vias with no layer
//! preference anywhere. Scheduling, not pricing. The guard fires there, finds
//! the retry no cheaper, and correctly leaves the board alone.

const std = @import("std");
const board_layers = @import("../board_layers.zig");
const manhattan_route = @import("manhattan_route.zig");
const router = @import("router.zig");

const Track = router.Track;
const Via = router.Via;
const NetPt = router.NetPt;
const DirectRun = router.DirectRun;
/// The router's per-run context, reached through the one pub type that names it
/// rather than by widening its own visibility — the same seam
/// `manhattan_route` uses.
const Ctx = @FieldType(DirectRun, "ctx");

/// How far past its own span a connection may route before the guard gives it a
/// second chance, as a multiple of `manhattan_route.mstMm` — the shortest copper
/// that could join its terminals if obstacles and layers did not exist.
///
/// The same √2-rounded-up bound the axis-only rung uses (`detour_cap`), and for
/// the same reason: one octilinear corner costs at most √2 ≈ 1.414 times the
/// straight line it replaces, so 1.5 admits every shape that is a CORNER and
/// fires only on shapes that are a detour. It is deliberately not tight — the
/// guard is a second opinion, not a rule, and a net inside the budget must cost
/// nothing at all.
const detour_guard_ratio: f64 = 1.5;

/// What one via is worth, in millimetres of copper, when the guard compares the
/// route it already has against the retry.
///
/// Deliberately a physical weight rather than the search's own
/// `grid.g * via_cost_mult`. That price is denominated in GRID PITCHES, which
/// is right inside a search (it keeps the cost model scale-free) and wrong
/// here: the same board routed on the whole-board lattice and on the quarter
/// -pitch rescue lattice would otherwise value the identical via at 1.9 mm and
/// at 0.5 mm, and the guard would answer the same question two different ways.
/// A via's real cost to a board is its barrel plus the antipad it punches
/// through every plane — about a millimetre of copper's worth of blocked
/// routing space — so that is what it is charged.
const detour_guard_via_mm: f64 = 1.0;

/// How much cheaper a retry has to be before either guard swaps routes, as a
/// fraction of what the route already in hand costs.
///
/// A guard that took every improvement would take 3% ones, and a 3% improvement
/// is not what either of these exists to find: swapping routes moves copper
/// that the nets after this one will route around, so a marginal swap trades a
/// rounding error for real churn on a congested board. Measured on the
/// reserved-lane channel fixture, where the alternative to threading an
/// authored lane scored 9.48 against 9.82 — the guard would have bought 3.5%
/// with two drills and pulled the net off the corridor its author reserved for
/// it, while the two genuine wins on the same board (54% and 56%) clear this
/// bar without noticing it.
const detour_guard_margin: f64 = 0.9;

/// What the guard charges per straight RUN of the finished copper — its corner
/// count, read off the geometry rather than off the search.
///
/// Collinear maze steps are merged before they land, so a track IS a straight
/// run and the run count is the corner count plus one per leg. Small on
/// purpose: the guard exists to decide LAYER, and shape is the tie-break that
/// settles two routes of comparable length and via count.
const detour_guard_bend_mm: f64 = 0.1;

/// Per-decision guard trace, at debug level so a dev server / `route_experiment`
/// replay can see the guard fire without a batch route paying for it. Same
/// idiom as the island-hop ledger.
const guardLog = std.log.debug;

/// Give one connection that routed far past its own span a single second chance
/// on another face, and keep whichever route costs the board less.
///
/// The retry changes the two things that kept the route on the face it toured:
/// that face is priced at `preferred_layer_cost_mult` — the knob an author
/// reaches for by hand as `(wave … (preferred-layers …))` — and a via is priced
/// at what one costs a board rather than at how many lattice steps it is worth
/// on this net's pitch (`router.Ctx.via_cost_cap_mm`). Whichever route then
/// scores lower on `detourScore`, by `detour_guard_margin`, is the one that
/// stays.
///
/// Bounded and transactional: at most one retry, no recursion (the retry enters
/// `router.routeNetAttempt`, never `router.routeNet`), and a rejected retry is
/// replaced by the EXACT copper the first route drew — kept aside and stamped
/// back rather than re-searched, so the guard can never turn a routed net into
/// a failed one.
///
/// Returns true always: the connection was already routed when the guard was
/// called, and the guard only ever chooses which of two routes it keeps.
pub fn detourGuard(
    run: DirectRun,
    pts: []const NetPt,
    track_mark: usize,
    via_mark: usize,
) std.mem.Allocator.Error!bool {
    const ctx = run.ctx;
    if (!detourGuardEligible(ctx, run.net, pts)) return true;
    const span = try manhattan_route.mstMm(ctx.arena, pts);
    if (!(span > 0)) return true;
    const first_mm = manhattan_route.routedMm(run.tracks.items[track_mark..]);
    if (first_mm <= detour_guard_ratio * span) return true;
    const face = dominantFace(run.tracks.items[track_mark..]) orelse return true;
    const retry_preferred = offFaceLayers(ctx, face) orelse return true;

    const first_score = detourScore(run.tracks.items[track_mark..], run.vias.items[via_mark..]);
    // The first route's exact copper, so a rejected retry is UNDONE rather than
    // re-derived. Re-running the original profile would also reproduce it — the
    // rolled-back state is identical and the search is deterministic — but it
    // would spend a third maze run to learn something already known, and it
    // would put the net's survival behind one more search that could be
    // cancelled by the board deadline mid-guard.
    const kept_tracks = try ctx.arena.dupe(Track, run.tracks.items[track_mark..]);
    const kept_vias = try ctx.arena.dupe(Via, run.vias.items[via_mark..]);
    // A retry that fails a leg appends this net to the search-limited report.
    // The net is routed either way, and a routed net is not search-limited.
    const limited_mark = ctx.search_limited.items.len;

    router.rollbackDirectRun(run, track_mark, via_mark);
    const saved_preferred = ctx.preferred_layers;
    const saved_via_cap = ctx.via_cost_cap_mm;
    // Two changes, both pointed at the same thing — the reasons this connection
    // would not leave the face it detoured on. The preference prices that face
    // at `preferred_layer_cost_mult`, which is the knob an author reaches for by
    // hand; the cap prices a via by what one costs a BOARD rather than by how
    // many lattice steps it happens to be worth on this net's pitch.
    ctx.preferred_layers = retry_preferred;
    ctx.via_cost_cap_mm = detour_guard_via_mm;
    const retried = try router.routeNetAttempt(ctx, run.net, pts, run.tracks, run.vias);
    ctx.preferred_layers = saved_preferred;
    ctx.via_cost_cap_mm = saved_via_cap;

    if (retried) {
        const retry_vias = run.vias.items.len - via_mark;
        // A policy via budget binds the retry exactly as it binds the first
        // route. `max_vias = 0` never reaches here at all (it clears
        // `allow_vias`, which the eligibility rule requires), so a bypass bond
        // cannot gain a via from the guard even in principle; this covers the
        // budgets that are positive but finite.
        const within_budget = if (ctx.max_vias) |limit| retry_vias <= @as(usize, limit) else true;
        const retry_score = detourScore(run.tracks.items[track_mark..], run.vias.items[via_mark..]);
        if (within_budget and retry_score < detour_guard_margin * first_score) {
            guardLog("detour guard net={d}: accepted off-face retry ({d:.2}mm/{d}v -> {d:.2}mm/{d}v, span {d:.2}mm)", .{
                run.net,
                first_mm,
                kept_vias.len,
                manhattan_route.routedMm(run.tracks.items[track_mark..]),
                retry_vias,
                span,
            });
            return true;
        }
    }
    router.shrinkCopper(run.tracks, run.vias, track_mark, via_mark);
    try run.tracks.appendSlice(ctx.arena, kept_tracks);
    try run.vias.appendSlice(ctx.arena, kept_vias);
    router.restoreNetOcc(ctx, run.net, run.tracks.items, run.vias.items);
    ctx.search_limited.shrinkRetainingCapacity(limited_mark);
    // The kept route is whole, whatever the retry left these claiming.
    ctx.zone_partial = false;
    ctx.tree_partial = false;
    guardLog("detour guard net={d}: kept original ({d:.2}mm over a {d:.2}mm span, retry {s})", .{
        run.net,
        first_mm,
        span,
        if (retried) "no cheaper" else "failed",
    });
    return true;
}

/// May the guard offer this connection a second opinion?
///
/// Every refusal below is one of two: the route already costs what it costs
/// (no vias to be had, nowhere else to go), or something ELSE owns this net's
/// shape and a length measure must not outrank it. A diff-pair corridor and a
/// reference corridor pin the path; authored layers, waypoints and branch trees
/// are the author saying where the copper goes — a net whose plan already names
/// `(preferred-layers …)` has been given this exact instruction by hand, and
/// deriving a different one over the top of it would be the router arguing with
/// the design; and an RF net's shape belongs to the axis-only rung, which
/// applies its own, stricter detour cap already.
fn detourGuardEligible(ctx: Ctx, net: i32, pts: []const NetPt) bool {
    if (net < 0 or pts.len < 2) return false;
    // A via-free pass owns this route: the top-layer-first attempt and the
    // over-budget retry both route with `allow_vias` cleared, and so does every
    // `max_vias = 0` net.
    if (!ctx.allow_vias) return false;
    if (ctx.max_vias) |limit| if (limit == 0) return false;
    if (ctx.occ.len < 2) return false; // one signal layer: no other face exists
    if (ctx.corridor != null or ctx.reference_corridor != null) return false;
    if (ctx.pair_coupling_hard or ctx.pair_via_mask != null or ctx.reference_guide_active) return false;
    if (ctx.waypoints.len > 0 or ctx.guide_branches.len > 0) return false;
    if (router.netLayerAuthored(ctx, @intCast(net))) return false;
    if (ctx.manhattan.max_freq_hz > 0 or router.escapeActive(ctx)) return false;
    return !router.routeCancelled(ctx);
}

/// The signal layer carrying the most of `added` — the face the detour ran on,
/// and so the one the retry de-prefers. Null for copper with no length at all.
fn dominantFace(added: []const Track) ?u8 {
    var per_layer: [board_layers.max_signal_layers]f64 = @splat(0);
    for (added) |t| {
        if (t.layer >= per_layer.len) continue;
        per_layer[t.layer] += std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
    }
    var best: ?u8 = null;
    for (per_layer, 0..) |mm, layer| {
        if (mm <= 0) continue;
        if (best == null or mm > per_layer[best.?]) best = @intCast(layer);
    }
    return best;
}

/// The preferred-layer mask for the retry: every signal layer except `face`,
/// intersected with whatever the net's policy already ALLOWS. Null when that
/// leaves nothing — a net pinned to the face it detoured on has no second
/// opinion to offer, and must be left exactly as it routed.
///
/// `allowed_layers` is never widened here, only read: a policy-restricted net
/// keeps every layer restriction it arrived with, and the guard can only ever
/// change which of the layers it was already permitted it prefers.
fn offFaceLayers(ctx: Ctx, face: u8) ?u64 {
    var mask: u64 = 0;
    for (0..ctx.occ.len) |layer| {
        if (layer == face) continue;
        const bit = board_layers.SignalIndex.of(@intCast(layer)).bit() orelse continue;
        mask |= @as(u64, 1) << bit;
    }
    if (ctx.allowed_layers != 0) mask &= ctx.allowed_layers;
    return if (mask == 0) null else mask;
}

/// What one candidate route costs the board, in millimetres of copper: its
/// length, plus what its vias and its corners are worth.
///
/// The guard's own metric rather than the search's, because it is comparing two
/// FINISHED routes rather than two partial paths — the terms are the ones a
/// reader can check against the emitted geometry (`trace_mm`, the via count, the
/// straight-run count), and none of them is denominated in a lattice pitch that
/// differs between the passes this can run under.
fn detourScore(added: []const Track, added_vias: []const Via) f64 {
    return manhattan_route.routedMm(added) +
        @as(f64, @floatFromInt(added_vias.len)) * detour_guard_via_mm +
        @as(f64, @floatFromInt(added.len)) * detour_guard_bend_mm;
}

/// Judge the surface-only route the top-layer-first pass just drew, and hand
/// back the one that should stand: itself when it stayed near the net's own
/// span, else whichever of it and the ordinary via-capable route costs the board
/// less. Always true — a route is already in hand either way.
pub fn judgeSurfaceDetour(
    run: DirectRun,
    pts: []const NetPt,
    track_mark: usize,
    via_mark: usize,
) std.mem.Allocator.Error!bool {
    if (!try surfaceIsDetour(run.ctx, pts, run.tracks.items[track_mark..])) return true;
    return keepCheaperWithVias(run, pts, track_mark, via_mark);
}

/// Did this top-layer-only route run `detour_guard_ratio` past the shortest
/// copper that could join its terminals? A net with no span to measure against
/// (a single terminal) never counts as detoured.
fn surfaceIsDetour(
    ctx: Ctx,
    pts: []const NetPt,
    added: []const Track,
) std.mem.Allocator.Error!bool {
    const span = try manhattan_route.mstMm(ctx.arena, pts);
    if (!(span > 0)) return false;
    return manhattan_route.routedMm(added) > detour_guard_ratio * span;
}

/// Route this net again with layer changes permitted and keep whichever of the
/// two routes costs the board less. Always true: a surface route is already in
/// hand, and the worst case is that it is the one put back.
///
/// The same shape as `detourGuard` and for the same reason, one rung earlier:
/// the surface-first pass has drawn a detour, and the only way to know whether
/// it is a detour worth keeping is to draw the alternative and measure both.
fn keepCheaperWithVias(
    run: DirectRun,
    pts: []const NetPt,
    track_mark: usize,
    via_mark: usize,
) std.mem.Allocator.Error!bool {
    const ctx = run.ctx;
    const surface_score = detourScore(run.tracks.items[track_mark..], run.vias.items[via_mark..]);
    const kept_tracks = try ctx.arena.dupe(Track, run.tracks.items[track_mark..]);
    const kept_vias = try ctx.arena.dupe(Via, run.vias.items[via_mark..]);
    const limited_mark = ctx.search_limited.items.len;
    router.rollbackDirectRun(run, track_mark, via_mark);
    const with_vias = try router.routeNet(ctx, run.net, pts, run.tracks, run.vias);
    if (with_vias and
        detourScore(run.tracks.items[track_mark..], run.vias.items[via_mark..]) <
            detour_guard_margin * surface_score)
    {
        guardLog("detour guard net={d}: surface-first detour traded for a layer change", .{run.net});
        return true;
    }
    router.shrinkCopper(run.tracks, run.vias, track_mark, via_mark);
    try run.tracks.appendSlice(ctx.arena, kept_tracks);
    try run.vias.appendSlice(ctx.arena, kept_vias);
    router.restoreNetOcc(ctx, run.net, run.tracks.items, run.vias.items);
    ctx.search_limited.shrinkRetainingCapacity(limited_mark);
    ctx.zone_partial = false;
    ctx.tree_partial = false;
    return true;
}
