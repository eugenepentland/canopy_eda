//! Manhattan (axis-only) routing for `(max-freq …)` nets — the first rung of the
//! per-net ladder, and the only one whose copper is horizontal and vertical
//! runs alone.
//!
//! The ordinary maze moves on eight headings, so an RF trace threading a dense
//! board comes out as a meander: many short 45° facets, each one an impedance
//! discontinuity and each one a corner the bend smoother must fillet with a
//! radius it has no room for. What a hand router draws instead is a few long
//! straights meeting at square corners, spaced far enough apart that each corner
//! can carry a wide arc.
//!
//! `attempt` reaches for that shape in two tiers. The DIRECT tier (`directTier`)
//! draws a two-terminal net between its pad centres with no lattice anywhere: one
//! straight run when the pads are near enough to collinear, else one square elbow
//! with two full-length legs. That geometry is what makes the bend smoother work
//! — its per-corner budget is a function of the neighbouring segment lengths, so
//! a corner between two long clean legs opens to a wide sweep while the same
//! corner between lattice-quantized fragments starves. The MAZE tier below it
//! keeps the discipline for everything the direct tier cannot draw (multi-drop
//! trees, cross-layer pairs, blocked elbows) and is where the rest of this module
//! lives, expressed as three pieces the router hangs off one flag
//! (`State.active`):
//!
//!   * the maze expands only its four AXIS neighbours (`router.dijkstra` skips
//!     its diagonal relaxations), so no 45° step exists to be found;
//!   * every heading change is priced at `turn_cost_mult` grid pitches
//!     (`State.turnCost`). This is load-bearing, not cosmetic: on an axis
//!     lattice EVERY monotone path between two nodes has the same length, so
//!     without a corner price the search would settle on an arbitrary staircase
//!     — strictly worse copper than the octilinear meander it replaced. The
//!     price is the only thing separating the L from the staircase;
//!   * an off-grid pad centre joins the raster through the axis L (`axisStub`)
//!     instead of the `octilinear.elbows` axis-then-45° join.
//!
//! Vias, layer masks, budgets and every clearance oracle are untouched: the
//! attempt narrows which SHAPES are reachable and nothing else, and an accepted
//! route lands through the same terminal-tree seam as any other.
//!
//! `attempt` is transactional. Anything it cannot close — no path, a pad it
//! cannot join on the axes, an oracle refusal, copper that came out off-axis
//! anyway (`allAxis`, the backstop for the join seams this module does not own),
//! or a closure that only happened by running far past the net's own span
//! (`detour_cap`) — is rolled back whole, and the caller's existing ladder then
//! runs on exactly the state it would have seen. A net that declares no
//! `(max-freq …)` never enters here at all.
//!
//! The two acceptance tests are deliberately POST-HOC rather than search terms.
//! "Axis-only" and "no farther than it needs to go" are properties of a finished
//! route, and stating them as cost functions would mean approximating both
//! inside a search that can then still miss; measuring the copper is exact, and
//! a refusal is free — it costs only the fallback that was going to run anyway,
//! which routinely draws the shorter trace because it may cut the corner at 45°.
//!
//! One assumption is worth naming: the attempt grows an ordinary terminal tree,
//! so it does not offer a POUR-backed net its plane connection first the way the
//! full ladder does. A `(max-freq …)` net with a filled zone of its own is not a
//! shape this router has met — an RF signal's pour is its neighbour's ground,
//! not its own — and if one appears, the worst case is that it routes as real
//! copper (or declines and takes the zone path on the next rung).

const std = @import("std");
const optimizer = @import("optimizer.zig");
const octilinear = @import("octilinear.zig");
const diff_pairs = @import("diff_pairs.zig");
const route_policy = @import("route_policy.zig");
const router = @import("router.zig");

/// What one corner costs the axis-only search, as a multiple of the grid pitch.
///
/// Sized as a preference, not a wall: the search will accept a path four grid
/// steps longer to lose a corner, which collapses any staircase into its L while
/// still letting a genuinely boxed-in net turn as often as it must. A hard
/// refusal would be wrong — an unroutable RF net is a worse outcome than a
/// three-corner one.
pub const turn_cost_mult: f64 = 4.0;

/// Longest segment (mm) whose heading `allAxis` ignores. The weld that bridges
/// one clearance halo, and the join seam's last-resort direct stub, each emit at
/// most one sub-halo segment at whatever angle closes the gap; refusing a whole
/// route over copper this short would trade a clean RF trace for an open net,
/// which is the trade those seams already decline to make.
const axis_tolerance_mm: f64 = 0.001;

/// The router's per-net axis-only state, carried on its route context.
///
/// `max_freq_hz`/`diff_paired` describe the net whose turn it is (restated at
/// the router's one per-net params seam); `active` is true only for the span of
/// one `attempt`, and it is what every axis-only branch in the maze reads.
pub const State = struct {
    /// True while the axis-only attempt owns the search. Every other route —
    /// including every other rung of an RF net's own ladder — sees false and
    /// behaves exactly as it did before this module existed.
    active: bool = false,
    /// `(max-freq HZ)` of the net now routing; 0 = not RF, so no attempt.
    max_freq_hz: f64 = 0,
    /// The net now routing is one half of a declared differential pair, whose
    /// coupled construction owns its shape and its corners.
    diff_paired: bool = false,

    /// The extra cost the move `from_key` → `to_key` pays for changing heading.
    ///
    /// Two prices, one seam. While the axis-only attempt is running a corner
    /// costs `turn_cost_mult` (4) grid pitches, which is what collapses an
    /// otherwise-free staircase into its L — on an axis lattice every monotone
    /// path is the same length, so the corner price is the ONLY thing that can
    /// tell those apart. Every other leg pays the ordinary octilinear nudge
    /// (`router.bend_cost_mult`, 0.15 pitches): the 8-neighbour lattice at
    /// least prices a detour by length, so it needs only enough to break the
    /// exact ties between equal-length interleavings.
    ///
    /// The two also read the turn differently, and deliberately. The axis
    /// attempt counts it ALWAYS: it is buying the corner outright, and
    /// silencing the count on a pinned leg would not preserve a shape, it would
    /// produce a staircase. The ordinary price goes through the gated `turned`,
    /// so a leg whose shape an explicit constraint already owns — a diff-pair
    /// coupling corridor (hug your twin) or a reference corridor (follow the
    /// replayed path) — pays nothing and runs on the pre-existing cost model to
    /// the bit. Those are electrical/intent constraints; a corner preference is
    /// cosmetic and must never outrank them. Measured: a 0.6-pitch bend price
    /// pulled a coupled leg clean out of its corridor and detoured it the wrong
    /// way around an obstacle, away from its twin.
    pub fn turnCost(self: State, g: f64, lat: octilinear.Lattice, from_key: usize, to_key: usize) f64 {
        if (self.active) {
            const turns = octilinear.turnedAlways(lat, from_key, to_key);
            return g * turn_cost_mult * @as(f64, @floatFromInt(turns));
        }
        const turns = octilinear.turned(lat, from_key, to_key);
        return g * router.bend_cost_mult * @as(f64, @floatFromInt(turns));
    }
};

/// The axis-only state for net `net_i` on `placement` — what the router restates
/// at each per-net boundary. `active` is deliberately reset to false here: the
/// flag belongs to one attempt, never to a net.
pub fn stateFor(placement: optimizer.Placement, net_i: usize) State {
    const rf = if (net_i < placement.rules.net.len) placement.rules.net[net_i].rf else optimizer.Rf{};
    return .{ .max_freq_hz = rf.max_freq_hz, .diff_paired = paired(placement.diff_pairs, net_i) };
}

/// Is `net_i` either half of a declared differential pair?
fn paired(pairs: []const diff_pairs.DiffPair, net_i: usize) bool {
    for (pairs) |dp| if (dp.p == net_i or dp.n == net_i) return true;
    return false;
}

/// What the eligibility rule reads, lifted off the route context so the rule can
/// be stated — and tested — without one.
const Gate = struct {
    state: State,
    /// This leg's shape is already pinned: a diff-pair coupling corridor (hug
    /// your twin), its hard via/coupling variants, or a reference corridor
    /// (follow the replayed path).
    pinned: bool,
    /// The net authors a guide-branch TREE — `(guides (between-pins …))` or
    /// `(branches …)` — which names a corridor per drop and a terminal order to
    /// walk them in. Plain `(waypoints …)` deliberately do NOT set this; see
    /// `attempt`.
    guided: bool,
};

/// The gate inputs for the net `run` is about to route.
fn gateFor(run: router.DirectRun) Gate {
    const ctx = run.ctx;
    return .{
        .state = ctx.manhattan,
        .pinned = ctx.corridor != null or ctx.pair_coupling_hard or ctx.pair_via_mask != null or
            ctx.reference_guide_active or ctx.reference_corridor != null,
        .guided = ctx.guide_branches.len > 0 or authorsTree(ctx, run.net),
    };
}

/// Does this net's wave author a guide-branch tree?
///
/// Read from the POLICY rather than only from `ctx.guide_branches`, because a
/// two-terminal `(guides …)` is lowered to a waypoint chain before the ladder
/// runs (`guide_branch.resolve` → `.chain`) and would otherwise arrive here
/// indistinguishable from the plain `(waypoints …)` this rung now accepts. The
/// author asked for a tree either way.
fn authorsTree(ctx: @FieldType(router.DirectRun, "ctx"), net: i32) bool {
    if (net < 0) return false;
    const net_i: usize = @intCast(net);
    if (net_i >= ctx.net_policy.len) return false;
    return route_policy.hasBranchTree(ctx.net_policy[net_i]);
}

/// May the net now routing take the axis-only attempt?
///
/// RF discipline is the reason it exists, and every refusal below is the same
/// refusal: something ELSE already owns this leg's shape, and a corner
/// preference must never outrank it. A diff-pair member's centreline is
/// constructed rather than searched; a pinned corridor names the path; and a
/// guide-branch tree names a corridor per drop that this attempt cannot walk.
fn eligible(g: Gate) bool {
    if (!(g.state.max_freq_hz > 0) or g.state.diff_paired) return false;
    return !g.pinned and !g.guided;
}

/// Route one net's terminal tree on the axes alone, or leave nothing behind.
///
/// The maze tier is the router's own terminal-tree grower, run under
/// `State.active` — which is the whole difference: same tree, same oracles, same
/// acceptance, four neighbours instead of eight and a price per corner.
///
/// A net carrying plain `(waypoints …)` DOES come through here, with the
/// waypoints cleared for the span of the attempt. On barracuda those waypoints
/// were authored by earlier routing campaigns as a way to buy a clean shape —
/// `lo-drive-rounded`'s stated reason is "one remote elbow with long horizontal
/// and vertical arms, leaving enough tangent length for the full RF bend radius",
/// which is this rung's native output — so honouring the letter of the guide
/// while ignoring its purpose would be the wrong reading. They are restored on
/// EVERY exit: `routeNet`'s own save/restore covers authored-TREE nets only, and
/// the fallback ladder's waypoint chain and `retryDeferredWaypoints` must see the
/// field exactly as it was.
///
/// Returns false — with the copper lists, the occupancy, the waypoints, the
/// partial-tree flags and the search-limited report all restored — for a net that
/// is not eligible, for a tree that does not close, for one that closes with
/// off-axis copper, and for one that closes only by detouring past `detour_cap`.
pub fn attempt(
    run: router.DirectRun,
    pts: []const router.NetPt,
) std.mem.Allocator.Error!bool {
    const ctx = run.ctx;
    if (!eligible(gateFor(run))) return false;
    const track_mark = run.tracks.items.len;
    const via_mark = run.vias.items.len;
    // A failed attempt must not leave this net named in the search-limited
    // report: it is about to be routed again by the ordinary ladder, and a net
    // that routes is not search-limited. Appends are the only mutation a leg
    // makes to that set here, so the recorded length restores it exactly.
    const limited_mark = ctx.search_limited.items.len;
    const saved_waypoints = ctx.waypoints;
    ctx.waypoints = &.{};
    ctx.manhattan.active = true;
    defer {
        ctx.manhattan.active = false;
        ctx.waypoints = saved_waypoints;
    }
    errdefer router.rollbackDirectRun(run, track_mark, via_mark);
    // The direct tier first: one shape, drawn between the pad centres
    // themselves. It is exempt from both post-hoc measures below — a lone
    // straight is deliberately off the compass (`nearlyCollinear`), and a
    // two-segment L is 1.0-1.414× its own span by construction, so the detour
    // budget it would be judged against is satisfied before it is measured.
    if (try directTier(run, pts)) return true;
    if (try router.tryMazeTerminalTree(ctx, run.net, pts, run.tracks, run.vias, 1) and
        allAxis(run.tracks.items[track_mark..]) and
        try withinDetourCap(ctx.arena, run.tracks.items[track_mark..], pts)) return true;
    router.rollbackDirectRun(run, track_mark, via_mark);
    ctx.search_limited.shrinkRetainingCapacity(limited_mark);
    // A partial tree is a claim on copper the ordinary ladder reads before it
    // decides how hard to retry. This attempt left none, so it must claim none.
    ctx.zone_partial = false;
    ctx.tree_partial = false;
    return false;
}

/// Copper an accepted axis route may lay, as a multiple of the shortest copper
/// that could possibly join its terminals (`mstMm`).
///
/// The bound is √2 rounded up. A single-corner Manhattan L costs |dx| + |dy|,
/// which is at most √2 ≈ 1.414 times the straight line it replaces — worst case
/// exactly, for the perpendicular equal-arm elbow — so 1.5 admits every clean
/// shape this rung exists to produce and refuses everything that is a DETOUR
/// rather than a corner.
///
/// Measured on barracuda: `RF1_HPF`, a 0.61 mm hop, closed axis-only at 1.78 mm
/// (2.9×) by going the long way around an obstacle, against a requirement that a
/// smoothed RF route not run farther than it needs to. Grid quantization counts
/// against this budget too, which is deliberate: on a hop that short, a route
/// that cannot stay near its own span is exactly the complaint.
const detour_cap: f64 = 1.5;

/// Does `added` stay inside the detour budget for the terminals it joins?
///
/// Judged AFTER the tree closes, because the cheap-to-state property ("this
/// route is not much longer than the net is wide") is the one the requirement is
/// written in, and no search cost function expresses it directly. A refusal
/// costs only the fallback the caller was going to run anyway — and the ordinary
/// ladder, which may cut the corner at 45°, routinely draws the shorter trace.
fn withinDetourCap(
    arena: std.mem.Allocator,
    added: []const router.Track,
    pts: []const router.NetPt,
) std.mem.Allocator.Error!bool {
    return routedMm(added) <= detour_cap * try mstMm(arena, pts);
}

/// Routed copper length (mm) in `added`. Vias carry no planar length, so they
/// are not part of the measure.
///
/// Shared with the router's own detour guard (`router.detourGuard`), which asks
/// the same post-hoc question of an ordinary net that this module asks of an RF
/// one — "did this route run much farther than the net is wide?" — so both read
/// one spelling of the measure rather than each carrying a copy.
pub fn routedMm(added: []const router.Track) f64 {
    var mm: f64 = 0;
    for (added) |t| mm += std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
    return mm;
}

/// Length (mm) of the Euclidean minimum spanning tree over `pts` — the shortest
/// copper that could join these terminals if obstacles, layers and angle
/// discipline did not exist, and so the natural denominator for "how far past
/// its own span did this route run?". Two terminals reduce to the pad-to-pad
/// distance; fewer than two span nothing.
///
/// O(n²) Prim over the arena: a net has a handful of terminals, and the exact
/// tree matters more here than the asymptotics.
///
/// Shared with `router.detourGuard` for the same reason `routedMm` is: one
/// denominator, one spelling. Two terminals reduce to the pad-to-pad distance,
/// which is the guard's terminal-pair case for free.
pub fn mstMm(arena: std.mem.Allocator, pts: []const router.NetPt) std.mem.Allocator.Error!f64 {
    if (pts.len < 2) return 0;
    const best = try arena.alloc(f64, pts.len);
    const joined = try arena.alloc(bool, pts.len);
    @memset(joined, false);
    for (best) |*d| d.* = std.math.inf(f64);
    best[0] = 0;
    var total: f64 = 0;
    for (0..pts.len) |_| {
        var pick: usize = pts.len;
        for (0..pts.len) |i| {
            if (joined[i]) continue;
            if (pick == pts.len or best[i] < best[pick]) pick = i;
        }
        joined[pick] = true;
        total += best[pick];
        for (0..pts.len) |i| {
            if (joined[i]) continue;
            best[i] = @min(best[i], apart(.{ pts[pick].x, pts[pick].y }, .{ pts[i].x, pts[i].y }));
        }
    }
    return total;
}

/// Join `a` to `b` with axis-aligned copper alone: the straight run when the
/// pair already lines up, else whichever of the two L corners clears.
///
/// Candidates are ordered by bending LATE, so the copper leaves the congested
/// end straight and turns out in open space: the same principle as
/// `octilinear.elbow`, and as the RF straight-escape reserve.
///
/// `seam` is the caller's own join seam — `clear(a, b) bool` and `seg(a, b)
/// !void`, exactly the contract `octilinear.emitJoin` takes — so this stays pure
/// geometry and reuses the router's existing oracle rather than a second one.
///
/// False means no axis join exists, and the caller has no diagonal to fall back
/// on without leaving the discipline. Nothing is drawn unless BOTH legs cleared,
/// so a false return leaves no half-finished stub.
pub fn axisStub(seam: anytype, a: [2]f64, b: [2]f64) std.mem.Allocator.Error!bool {
    if (!axisApart(a, b)) {
        if (!seam.clear(a, b)) return false;
        try seam.seg(a, b);
        return true;
    }
    var cand = octilinear.axisElbows(a, b);
    if (@abs(b[1] - a[1]) > @abs(b[0] - a[0])) cand = .{ cand[1], cand[0] };
    for (cand) |mid| {
        if (!seam.clear(a, mid) or !seam.clear(mid, b)) continue;
        try seam.seg(a, mid);
        try seam.seg(mid, b);
        return true;
    }
    return false;
}

/// The direct tier's join seam: the router's own exact-clearance segment probe
/// and emitter, in the `clear`/`seg` shape `axisStub` takes.
///
/// Deliberately NOT the pad-join seam `gateStub` uses. That one is layer-BLIND,
/// which is the right chooser for a sub-pitch stub (it should stay off the far
/// face's lands too) but the wrong gate for a whole trace, which would then be
/// refused for passing over a bottom-side pad it never touches. This is the
/// oracle the router's own direct primitives use: layer-aware pads, vias and
/// copper, plus the board outline, filled zones and reserved lanes.
const DirectSeam = struct {
    path: router.DirectPath,
    tracks: *std.ArrayList(router.Track),

    fn clear(self: DirectSeam, a: [2]f64, b: [2]f64) bool {
        return router.clearDoglegSegment(self.path, a, b);
    }

    fn seg(self: DirectSeam, a: [2]f64, b: [2]f64) std.mem.Allocator.Error!void {
        return router.emitDoglegSegment(self.path, a, b, self.tracks);
    }
};

/// The direct tier: a two-terminal single-layer RF net drawn as ONE clean shape,
/// pad centre to pad centre, with no lattice anywhere.
///
/// This is the tier the user is actually judging. The maze below draws the right
/// ARCHETYPE but snaps to the lattice, and the off-grid pad centres then need
/// join stubs mid-run — so the polyline arrives at the bend smoother fragmented
/// by micro-jogs, and its per-corner budget starves on the short pieces. Two
/// full-length legs meeting at one corner give the smoother the long clean
/// neighbours it needs to open that corner to the maximum the shorter leg hosts,
/// which is the wide sweep the trace is for.
///
/// Everything else — multi-drop trees, and pairs that need a via to change layer
/// — is the maze tier's job, and so is any pair whose shapes are all blocked.
fn directTier(run: router.DirectRun, pts: []const router.NetPt) std.mem.Allocator.Error!bool {
    if (pts.len != 2 or pts[0].layer != pts[1].layer) return false;
    const ctx = run.ctx;
    const layer = pts[0].layer;
    if (!router.layerInMask(ctx.allowed_layers, layer)) return false;
    if (!router.layerInMask(ctx.preferred_layers, layer)) return false;
    const seam = DirectSeam{ .path = run.path(layer), .tracks = run.tracks };
    return directPair(seam, pts[0], pts[1], ctx.rf.escape_mm, ctx.params.track_width);
}

/// One straight run if the pair is near enough to collinear, else whichever
/// square elbow both pads accept. Nothing is drawn unless the whole shape
/// cleared, so a false return leaves the maze tier a clean board.
///
/// `reserve` is the net's straight pad-escape distance (0 = none). Every
/// candidate must honour it at BOTH pads, and a tier that cannot honour it draws
/// nothing at all: the reserve wants a Z — out along the axis, across, back —
/// and the shape this tier exists to draw has no third segment. The maze tier
/// below prices the reserve in its own cost model and produces that Z, which is
/// the pre-existing behaviour for such a net (`router`'s rf-escape regression).
fn directPair(
    seam: anytype,
    from: router.NetPt,
    to: router.NetPt,
    reserve: f64,
    width: f64,
) std.mem.Allocator.Error!bool {
    const a = [2]f64{ from.x, from.y };
    const b = [2]f64{ to.x, to.y };
    if (nearlyCollinear(a, b, width) and
        escapeHonoured(from, b, reserve, width) and
        escapeHonoured(to, a, reserve, width) and
        seam.clear(a, b))
    {
        try seam.seg(a, b);
        return true;
    }
    if (!axisApart(a, b)) return false;
    var cand = octilinear.axisElbows(a, b);
    if (elbowFlipped(from, to, reserve)) cand = .{ cand[1], cand[0] };
    for (cand) |mid| {
        if (!escapeHonoured(from, mid, reserve, width)) continue;
        if (!escapeHonoured(to, mid, reserve, width)) continue;
        if (!seam.clear(a, mid) or !seam.clear(mid, b)) continue;
        try seam.seg(a, mid);
        try seam.seg(mid, b);
        return true;
    }
    return false;
}

/// Should the y-first elbow be tried before the x-first one? A declared escape
/// axis decides when there is one (`escapeAxis`); otherwise bend LATE, putting
/// the long leg on the first pad and the corner out in open space.
fn elbowFlipped(from: router.NetPt, to: router.NetPt, reserve: f64) bool {
    if (escapeAxis(from, to, reserve > 0)) |axis| return axis == 1;
    return @abs(to.y - from.y) > @abs(to.x - from.x);
}

/// Does the leg leaving `pt` toward `next` satisfy that pad's straight-escape
/// reserve — running ALONG the pad's outward axis, outward, for at least
/// `reserve` mm?
///
/// Trivially true when the net declares no reserve or the pad names no axis. The
/// `width` slack lets the straight candidate qualify: a sub-width sideways drift
/// is inside the trace itself and is not a bend for the reserve to forbid.
fn escapeHonoured(pt: router.NetPt, next: [2]f64, reserve: f64, width: f64) bool {
    if (!(reserve > 0)) return true;
    const axis = axisOf(pt.out) orelse return true;
    const delta = [2]f64{ next[0] - pt.x, next[1] - pt.y };
    const along = if (axis == 0) delta[0] else delta[1];
    const across = if (axis == 0) delta[1] else delta[0];
    if (along * (if (axis == 0) pt.out[0] else pt.out[1]) <= 0) return false;
    return @abs(across) <= width and @abs(along) >= reserve;
}

/// Is the pair close enough to one axis that a corner would be a JOG rather than
/// a bend — its perpendicular offset no wider than the trace itself?
///
/// This is the one place an RF net's copper may leave the compass, and the
/// exemption is the whole point: a lone segment has no direction transition at
/// all, which is what the angle discipline exists to buy. Barracuda's RF1 filter
/// chain hops sit tenths of a millimetre off-axis over a few millimetres, and
/// squaring that up produces a pair of micro-facets INSIDE the trace's own width
/// — measurably worse copper than a hair-off-axis straight, and nothing a bend
/// radius can rescue. Bounding it by the track width keeps the exemption to
/// exactly that case: a pair a full trace-width apart gets the elbow.
///
/// What keeps the straight alive to the finished board is worth stating, because
/// two later passes could each have eaten it and neither does. The straighteners
/// leave it alone structurally: a whole-net straight is a TWO-POINT chain, and
/// `straighten.straightenPts` returns a chain shorter than three points
/// untouched, so its `.octilinear` gates are never reached. The pad-escape
/// post-pass (`pad_escape.passBoard`) WOULD re-anchor it — it rebuilds each pad
/// end onto the pad's outward axis, which turns a 1.15° straight into exactly
/// the axis-then-45° facet pair this exists to remove — but it skips any net
/// with a declared escape reserve, and every resolved `(max-freq …)` class
/// carries one (`net_rules.default_rf_escape_mm`). Measured both ways on the
/// 3 mm / 0.06 mm fixture: with the reserve declared the copper comes back as
/// one segment, without it as three.
fn nearlyCollinear(a: [2]f64, b: [2]f64, width: f64) bool {
    return @min(@abs(b[0] - a[0]), @abs(b[1] - a[1])) <= width;
}

/// Which elbow to try first when a pad names an outward escape axis: 0 for the
/// x-first corner, 1 for the y-first. Null when the net carries no escape
/// reserve or neither pad names a direction — `axisStub` then bends late.
///
/// `from`'s own axis decides directly (the leg leaving it is the first one).
/// Failing that, `to`'s decides the OTHER way round, because the leg arriving at
/// `to` always runs perpendicular to the leg leaving `from`.
fn escapeAxis(from: router.NetPt, to: router.NetPt, escape: bool) ?u1 {
    if (!escape) return null;
    if (axisOf(from.out)) |near| return near;
    const far = axisOf(to.out) orelse return null;
    return if (far == 0) 1 else 0;
}

/// 0 when `out` points mostly along x, 1 when mostly along y, null for a pad
/// that names no outward direction.
fn axisOf(out: [2]f64) ?u1 {
    if (out[0] == 0 and out[1] == 0) return null;
    return if (@abs(out[0]) >= @abs(out[1])) 0 else 1;
}

/// True when `a`→`b` needs a corner to stay on the axes — i.e. it is neither
/// horizontal nor vertical. Exact, rather than `octilinear.isAxisAligned`'s 1°
/// angular tolerance, because this decides what gets EMITTED: a pair half a
/// degree off horizontal must be drawn as an L with a short second leg, not as
/// one segment that is almost, but not, axis-aligned.
fn axisApart(a: [2]f64, b: [2]f64) bool {
    return @abs(b[0] - a[0]) >= 1e-9 and @abs(b[1] - a[1]) >= 1e-9;
}

/// Straight-line distance (mm) between two points.
fn apart(a: [2]f64, b: [2]f64) f64 {
    return std.math.hypot(b[0] - a[0], b[1] - a[1]);
}

/// Is every segment in `added` horizontal or vertical?
///
/// The backstop for the join seams this module does not own. The maze's own path
/// is axis-only by construction once the diagonal steps are suppressed, but a
/// leg still reaches its pads through router code carrying its own octilinear
/// fallbacks, and a multi-leg tree welds to its earlier copper. Rather than
/// thread the discipline into each of those and hope none was missed, the
/// attempt MEASURES its output and declines a route that is not what it claims
/// to be — a decline costs only the fallback the caller was going to run anyway.
///
/// In practice this is also what keeps MULTI-leg trees out. A second leg welds to
/// the net's earlier copper through a bridge that is off-axis by construction and
/// as long as one clearance halo — far past `axis_tolerance_mm` — so a
/// three-terminal RF net normally declines here (measured on a three-pad fixture)
/// and takes the ordinary ladder. That is the right trade for now: RF nets are
/// overwhelmingly two-pin, and a decline costs nothing.
fn allAxis(added: []const router.Track) bool {
    for (added) |t| {
        if (@min(@abs(t.x2 - t.x1), @abs(t.y2 - t.y1)) > axis_tolerance_mm) return false;
    }
    return true;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const geometry = @import("geometry.zig");
const flat_netlist = @import("../flat_netlist.zig");

/// The RF class every fixture declares. Only its presence matters here; the
/// value is barracuda's K-band ceiling.
const rf_hz: f64 = 12e9;
const rf_net: i32 = 0;

const rf_pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "J1", .pin = "1" }, .{ .ref_des = "J2", .pin = "1" } };
/// The 0.4 mm square every fixture part starts with — the RF terminals keep it,
/// and a blocker keeps it until `Board.block` resizes it.
const small_pad = geometry.Pad{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 };

/// A board carrying one two-pad RF net plus four un-netted blockers, so a route
/// can be forced around real copper. The blockers start parked in the corners;
/// `block` moves and resizes one into the corridor.
const Board = struct {
    parts: [6]optimizer.Part,
    /// Blocker pad copper, one per `parts[2..]`. Held here rather than inside
    /// each part because a part's `pads` is a SLICE: it cannot point at its own
    /// storage until the board has a stable home, which `placement` gives it.
    pads: [4]geometry.Pad,
    rules: [1]optimizer.NetRule,
    nets: [1]optimizer.FlatNet,

    /// Move blocker `i` to a `w`×`h` pad centred on (x, y).
    fn block(self: *Board, i: usize, x: f64, y: f64, w: f64, h: f64) void {
        self.pads[i] = .{ .number = "1", .x = 0, .y = 0, .w = w, .h = h };
        self.parts[2 + i] = .{
            .ref_des = self.parts[2 + i].ref_des,
            .kind = .passive,
            .hw = w / 2,
            .hh = h / 2,
            .pads = &.{},
            .fallback = false,
            .x = x,
            .y = y,
        };
    }

    fn placement(self: *Board) optimizer.Placement {
        for (0..self.pads.len) |i| self.parts[2 + i].pads = self.pads[i .. i + 1];
        return .{
            .parts = &self.parts,
            .links = &.{},
            .loops = &.{},
            .stubs = &.{},
            .instances = &.{},
            .nets = &self.nets,
            .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
            .minx = -1,
            .miny = -1,
            .maxx = 13,
            .maxy = 11,
            .generated = true,
            .rules = .{ .net = &self.rules, .plane_nets = &.{}, .copper_layers = 2 },
        };
    }
};

/// A one-pad part at (x, y). Only J1/J2 are named by `rf_pins`, so every other
/// ref-des is an inert copper blocker.
fn part1(ref: []const u8, x: f64, y: f64) optimizer.Part {
    return .{ .ref_des = ref, .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &.{}, .fallback = false, .x = x, .y = y };
}

/// The RF net's two pads at (2, 3) and (11, 8) — deliberately offset on BOTH
/// axes, so no straight run is available and the route has to choose its
/// corners. `max_freq = 0` declares no RF class: the baseline every routed-shape
/// assertion is made against.
fn board(max_freq: f64) Board {
    return .{
        .parts = .{
            .{ .ref_des = "J1", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &.{small_pad}, .fallback = false, .x = 2, .y = 3 },
            .{ .ref_des = "J2", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &.{small_pad}, .fallback = false, .x = 11, .y = 8 },
            part1("B1", 0.5, 10.5),
            part1("B2", 12.5, 0.5),
            part1("B3", 0.5, 0.5),
            part1("B4", 12.5, 10.5),
        },
        .pads = .{ small_pad, small_pad, small_pad, small_pad },
        .rules = .{.{ .rf = .{ .max_freq_hz = max_freq } }},
        .nets = .{.{ .name = "RF_IN", .pins = &rf_pins }},
    };
}

/// Barracuda's `RF1_HPF` in miniature: a SHORT diagonal hop — the two terminals
/// move to (2, 3) and (3.4, 4.4), `hop_span_mm` apart — with a wall across the
/// gap between them. Neither router can cross it (the fixtures also forbid vias),
/// so both must round its right-hand end, which costs about 5.6 mm: 2.8× the
/// span, and well past `detour_cap`. The ordinary ladder may cut those corners at
/// 45°; the axis rung may not, so this is the board where it has to decline.
fn hopBoard(max_freq: f64) Board {
    var b = board(max_freq);
    b.parts[0].x = hop_a[0];
    b.parts[0].y = hop_a[1];
    b.parts[1].x = hop_b[0];
    b.parts[1].y = hop_b[1];
    b.block(0, 2.7, 3.7, 3.6, 0.4);
    return b;
}

/// Barracuda's `U13`→`U16` LO run in miniature, and the exact shape the user is
/// judging: an 8 mm drop with a 1.5 mm sideways offset. The archetype is a long
/// vertical leg leaving J1 and a short horizontal leg into J2, meeting at one
/// corner the bend smoother then opens.
fn elbowBoard() Board {
    var b = board(rf_hz);
    b.parts[0].x = 3;
    b.parts[0].y = 2;
    b.parts[1].x = 4.5;
    b.parts[1].y = 10;
    return b;
}

/// The RF1 filter-chain hop in miniature: 3 mm apart with a 0.06 mm sideways
/// offset, well under one 0.127 mm trace width. Squaring this up would put a pair
/// of facets inside the trace's own width; one straight run has no transition at
/// all.
fn collinearBoard(max_freq: f64) Board {
    var b = board(max_freq);
    // A resolved `(max-freq …)` class always carries a straight pad-escape
    // reserve (`net_rules.default_rf_escape_mm` = 1 mm unless authored
    // otherwise), and that reserve is what exempts the net from the pad-escape
    // post-pass. A fixture that sets `max_freq_hz` alone is not a board.
    if (max_freq > 0) b.rules[0].rf.escape_mm = 1.0;
    b.parts[0].x = 2;
    b.parts[0].y = 3;
    b.parts[1].x = 5;
    b.parts[1].y = 3.06;
    return b;
}

const hop_a = [2]f64{ 2, 3 };
const hop_b = [2]f64{ 3.4, 4.4 };
/// Pad-to-pad distance on `hopBoard` — the two-terminal Euclidean MST, so the
/// denominator `withinDetourCap` judges that board's routes against.
const hop_span_mm: f64 = 1.9798989873223332;
/// No layer changes: a via would let either router hop the wall in a straight
/// line, and then there is no detour to decline.
const no_vias = [_]route_policy.NetPolicy{.{ .max_vias = 0 }};

/// Every track the RF net laid, on either face.
fn rfTracks(arena: std.mem.Allocator, r: router.RouteResult) std.mem.Allocator.Error![]const router.Track {
    var out: std.ArrayList(router.Track) = .empty;
    for (r.tracks) |t| {
        if (t.net == rf_net) try out.append(arena, t);
    }
    return out.items;
}

/// Length (mm) of the longest segment in `tracks` that runs neither horizontally
/// nor vertically and is not part of one of `arcs` — the copper this attempt has
/// to answer for. 0 when the route is rectilinear apart from its arcs.
///
/// The filter is needed because a `(max-freq …)` net's FINISHED copper is never
/// purely rectilinear even when the attempt succeeds: the bend smoother replaces
/// each corner with a tangent arc and ships it as sagitta-bounded chords. Those
/// are deliberate signal, not meander — and `arcs` names exactly which corner
/// each belongs to — so they are excluded by the arc that owns them rather than
/// by a length threshold that would pin the smoother's radius policy. Pass an
/// empty `arcs` to measure a plain net, which has none.
fn longestStrayMm(tracks: []const router.Track, arcs: []const router.Arc) f64 {
    var worst: f64 = 0;
    for (tracks) |t| {
        const dx = t.x2 - t.x1;
        const dy = t.y2 - t.y1;
        if (@min(@abs(dx), @abs(dy)) <= axis_tolerance_mm) continue;
        if (onSomeArc(arcs, t)) continue;
        worst = @max(worst, std.math.hypot(dx, dy));
    }
    return worst;
}

/// Does `t` belong to some arc's corner cut? Every vertex of an arc's chord
/// tessellation lies within the arc's own reach of its midpoint (its endpoints
/// are the farthest, for any sweep up to a half turn), so a same-net same-layer
/// segment with both ends inside that reach is one of its chords — no need to
/// reconstruct the circle.
fn onSomeArc(arcs: []const router.Arc, t: router.Track) bool {
    for (arcs) |a| {
        if (a.net != t.net or a.layer != t.layer) continue;
        const reach = @max(apart(a.pm, a.p1), apart(a.pm, a.p2)) + axis_tolerance_mm;
        if (apart(a.pm, .{ t.x1, t.y1 }) <= reach and apart(a.pm, .{ t.x2, t.y2 }) <= reach) return true;
    }
    return false;
}

/// How many horizontal/vertical segments `tracks` holds. Collinear maze steps
/// are merged into one track before they land, so on rectilinear copper this is
/// the straight-run count — one more than the number of corners.
fn axisSegCount(tracks: []const router.Track) usize {
    var n: usize = 0;
    for (tracks) |t| {
        if (@min(@abs(t.x2 - t.x1), @abs(t.y2 - t.y1)) <= axis_tolerance_mm) n += 1;
    }
    return n;
}

/// Centreline radius (mm) of one recorded arc — the circumradius of its three
/// points. Infinite for three collinear points, which is not an arc.
fn arcRadius(a: router.Arc) f64 {
    const cross = @abs((a.pm[0] - a.p1[0]) * (a.p2[1] - a.p1[1]) -
        (a.pm[1] - a.p1[1]) * (a.p2[0] - a.p1[0]));
    if (cross < 1e-12) return std.math.inf(f64);
    return apart(a.p1, a.pm) * apart(a.pm, a.p2) * apart(a.p1, a.p2) / (2 * cross);
}

/// The constant coordinate of an axis-aligned track, and which axis it runs
/// along: `.vertical` pins x, `.horizontal` pins y. Null for anything else.
const AxisRun = struct { vertical: bool, at: f64, len: f64 };

fn axisRunOf(t: router.Track) ?AxisRun {
    const dx = @abs(t.x2 - t.x1);
    const dy = @abs(t.y2 - t.y1);
    if (@min(dx, dy) > axis_tolerance_mm) return null;
    if (dx <= dy) return .{ .vertical = true, .at = t.x1, .len = dy };
    return .{ .vertical = false, .at = t.y1, .len = dx };
}

/// Does `tracks` hold an axis run of the requested orientation pinned within
/// `tol` of `at`, at least `min_len` long? How a fixture states an L archetype
/// without depending on where the bend smoother trimmed the corner back to.
fn hasAxisRun(tracks: []const router.Track, vertical: bool, at: f64, min_len: f64, tol: f64) bool {
    for (tracks) |t| {
        const run = axisRunOf(t) orelse continue;
        if (run.vertical != vertical or @abs(run.at - at) > tol) continue;
        if (run.len >= min_len) return true;
    }
    return false;
}

/// Does any track pass within `r` mm of `at`? How a fixture asks whether the
/// route actually went through an authored waypoint — measured to the SEGMENT,
/// because a waypoint is normally crossed mid-run rather than landed on.
fn touchesNear(tracks: []const router.Track, at: [2]f64, r: f64) bool {
    for (tracks) |t| {
        const dx = t.x2 - t.x1;
        const dy = t.y2 - t.y1;
        const len2 = dx * dx + dy * dy;
        const raw = if (len2 < 1e-18) 0 else ((at[0] - t.x1) * dx + (at[1] - t.y1) * dy) / len2;
        const u = std.math.clamp(raw, 0, 1);
        if (apart(at, .{ t.x1 + u * dx, t.y1 + u * dy }) <= r) return true;
    }
    return false;
}

// spec: placement/manhattan-route - an RF net routes on horizontal and vertical runs alone, while the same board without the class keeps its diagonals
test "an RF net comes out rectilinear and a plain net is left alone" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Baseline: no `(max-freq …)`. The pads are offset on both axes, so the
    // ordinary octilinear maze takes a long 45° shortcut — which is what makes
    // this board a test rather than a coincidence.
    var plain = board(0);
    const before = try router.route(arena, plain.placement(), .{});
    try testing.expectEqual(@as(usize, 1), before.routed);
    const plain_tracks = try rfTracks(arena, before);
    try testing.expect(longestStrayMm(plain_tracks, before.arcs) > 3);

    // Declaring the class turns the same connection rectilinear: the ONLY
    // off-axis copper left is the bend smoother's arc chords, and every one of
    // those is claimed by the arc that owns it — measured stray, exactly zero.
    var rf = board(rf_hz);
    const after = try router.route(arena, rf.placement(), .{});
    try testing.expectEqual(@as(usize, 1), after.routed);
    const rf_tracks = try rfTracks(arena, after);
    try testing.expect(rf_tracks.len > 0);
    try testing.expectApproxEqAbs(@as(f64, 0), longestStrayMm(rf_tracks, after.arcs), 1e-9);
    // Rectilinear, not truncated: a Manhattan path is LONGER than the octilinear
    // one by construction — that is the trade — so the copper must at least
    // still span the pads it connects.
    try testing.expect(routedMm(rf_tracks) > routedMm(plain_tracks));
}

// spec: placement/manhattan-route - the axis-only search buys long straights instead of a staircase of ninety degree corners
test "an RF route around an obstacle keeps its corner count low" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // A tall bar between the pads. The straight-through L's are blocked, so the
    // route must step around it — exactly where an UNPRICED axis lattice
    // produces a staircase, since every monotone path over the detour costs the
    // same length and only the corner price can tell them apart.
    var rf = board(rf_hz);
    rf.block(0, 6.5, 3.0, 0.8, 6.0);
    const routed = try router.route(arena, rf.placement(), .{});
    try testing.expectEqual(@as(usize, 1), routed.routed);
    const tracks = try rfTracks(arena, routed);
    try testing.expectApproxEqAbs(@as(f64, 0), longestStrayMm(tracks, routed.arcs), 1e-9);
    // Each straight run is one merged track, so the run count is the corner
    // count plus one. A staircase over this 6 mm bar would run to dozens at the
    // sub-millimetre lattice pitch; this detour measures SEVEN runs, and twelve
    // leaves headroom without letting a staircase back through.
    try testing.expect(axisSegCount(tracks) <= 12);
}

/// A seam that records what the direct tier drew, with a disc of vetoed space —
/// enough to state the tier's shape choices without a whole board around them.
const PairSeam = struct {
    arena: std.mem.Allocator,
    out: *std.ArrayList([2][2]f64),
    blocked: [2]f64 = .{ 1e9, 1e9 },
    r: f64 = 0,

    fn clear(self: PairSeam, a: [2]f64, b: [2]f64) bool {
        for (0..33) |i| {
            const t = @as(f64, @floatFromInt(i)) / 32.0;
            const x = a[0] + t * (b[0] - a[0]);
            const y = a[1] + t * (b[1] - a[1]);
            if (apart(.{ x, y }, self.blocked) < self.r) return false;
        }
        return true;
    }

    fn seg(self: PairSeam, a: [2]f64, b: [2]f64) std.mem.Allocator.Error!void {
        try self.out.append(self.arena, .{ a, b });
    }
};

fn term(x: f64, y: f64) router.NetPt {
    return .{ .x = x, .y = y, .layer = 0 };
}

// spec: placement/manhattan-route - a near-collinear RF pair is drawn as one straight run rather than squared up into facets inside its own trace width
test "the direct tier draws a sub-width offset straight and a real offset as an elbow" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var out: std.ArrayList([2][2]f64) = .empty;
    const open = PairSeam{ .arena = arena, .out = &out };

    // Barracuda's RF1 filter hop: 3 mm apart, 0.06 mm off — inside one 0.127 mm
    // trace width. ONE segment, pad centre to pad centre, no corner at all.
    try testing.expect(try directPair(open, term(2, 3), term(5, 3.06), 0, 0.127));
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual([2]f64{ 2, 3 }, out.items[0][0]);
    try testing.expectEqual([2]f64{ 5, 3.06 }, out.items[0][1]);

    // A full trace width of offset is a bend, not a jog: two segments.
    out = .empty;
    try testing.expect(try directPair(open, term(2, 3), term(5, 3.5), 0, 0.127));
    try testing.expectEqual(@as(usize, 2), out.items.len);

    // Nothing is half-drawn when every shape is vetoed.
    out = .empty;
    const sealed = PairSeam{ .arena = arena, .out = &out, .blocked = .{ 3.5, 3.25 }, .r = 4 };
    try testing.expect(!try directPair(sealed, term(2, 3), term(5, 3.5), 0, 0.127));
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

// spec: placement/manhattan-route - a sub-width-offset RF straight reaches the finished board as one segment, while the same geometry without the class is re-anchored into facets
test "a near-collinear RF straight survives the finish and a plain net does not" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // 3 mm apart, 0.06 mm off — one 1.15° segment. It has to come back out of
    // the whole pipeline intact: the straighteners leave a two-point chain alone
    // (nothing to pull taut), and the pad-escape post-pass skips a net that
    // declares an escape reserve, which every resolved `(max-freq …)` class does.
    var rf = collinearBoard(rf_hz);
    const routed = try router.route(arena, rf.placement(), .{});
    try testing.expectEqual(@as(usize, 1), routed.routed);
    const tracks = try rfTracks(arena, routed);
    try testing.expectEqual(@as(usize, 1), tracks.len);
    try testing.expectEqual(@as(usize, 0), routed.arcs.len);
    // Pad centre to pad centre, exactly — no lattice node, no re-anchoring.
    try testing.expect(touchesNear(tracks, .{ 2, 3 }, 1e-6));
    try testing.expect(touchesNear(tracks, .{ 5, 3.06 }, 1e-6));

    // The same geometry with no RF class takes neither the tier nor the
    // exemption: it is re-anchored on the pads' outward axes into an
    // axis-then-45° path, which is the octilinear discipline doing its job.
    var plain = collinearBoard(0);
    const before = try router.route(arena, plain.placement(), .{});
    try testing.expectEqual(@as(usize, 1), before.routed);
    const plain_tracks = try rfTracks(arena, before);
    try testing.expect(plain_tracks.len > 1);
    try testing.expect(longestStrayMm(plain_tracks, before.arcs) > 0);
}

// spec: placement/manhattan-route - an offset RF pair is drawn as one square elbow of two full-length legs, so the bend smoother has room to open the corner
test "an RF elbow gives the bend smoother two clean legs and one corner" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Barracuda's U13→U16 shape: 8 mm of drop, 1.5 mm of offset.
    var rf = elbowBoard();
    const routed = try router.route(arena, rf.placement(), .{});
    try testing.expectEqual(@as(usize, 1), routed.routed);
    const tracks = try rfTracks(arena, routed);
    // Exactly two straight runs — the maze tier's lattice fragments would read
    // as many more — and exactly one corner between them.
    try testing.expectEqual(@as(usize, 2), axisSegCount(tracks));
    try testing.expectEqual(@as(usize, 1), routed.arcs.len);
    // The corner opens to most of what the SHORT leg can host, which is the
    // whole reason the tier hands the smoother full-length legs: measured
    // R = 1.373 mm against a 1.5 mm leg, so half the leg is a floor with room
    // to spare and does not pin the smoother's radius policy.
    try testing.expect(arcRadius(routed.arcs[0]) >= 0.5 * 1.5);
    // …and nothing was flagged as under-radius.
    try testing.expectEqual(@as(usize, 0), routed.sharp_bends.len);
}

// spec: placement/manhattan-route - an offset RF pair bends late, leaving the first pad along the long leg and turning in open space
test "an RF elbow puts its long leg on the first terminal" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // J1 (3, 2) → J2 (4.5, 10). Bending LATE puts the corner at (3, 10): the
    // long vertical run leaves J1 and the short horizontal one enters J2 — the
    // archetype a hand router draws, and the one the user asked for. Bending
    // early would corner at (4.5, 2) instead, which these assertions exclude.
    var rf = elbowBoard();
    const routed = try router.route(arena, rf.placement(), .{});
    try testing.expectEqual(@as(usize, 1), routed.routed);
    const tracks = try rfTracks(arena, routed);
    // Trimmed lengths, so assert well under the 8 mm / 1.5 mm the legs start at.
    try testing.expect(hasAxisRun(tracks, true, 3, 6, 0.01)); // long, pinned to J1's x
    try testing.expect(hasAxisRun(tracks, false, 10, 0.5, 0.01)); // short, pinned to J2's y
    // The early-bend corner's runs are absent: no vertical at J2's x, no
    // horizontal at J1's y.
    try testing.expect(!hasAxisRun(tracks, true, 4.5, 0.5, 0.01));
    try testing.expect(!hasAxisRun(tracks, false, 2, 0.5, 0.01));
}

// spec: placement/manhattan-route - an RF pair whose straight and both elbows are blocked falls through to the maze tier and still routes
test "an RF pair with every direct shape blocked takes the maze tier" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // J1 (2, 3) → J2 (9, 7), with a blocker on the straight and one on each
    // elbow's long leg. The maze can still weave a rectilinear path inside the
    // detour budget, so the net routes — as more than the two runs the direct
    // tier would have drawn.
    var rf = board(rf_hz);
    rf.parts[1].x = 9;
    rf.parts[1].y = 7;
    rf.block(0, 5.5, 5, 0.7, 0.7); // on the straight
    rf.block(1, 9, 5, 0.7, 0.7); // on the bend-early leg
    rf.block(2, 2, 5, 0.7, 0.7); // on the bend-late leg
    const routed = try router.route(arena, rf.placement(), .{});
    try testing.expectEqual(@as(usize, 1), routed.routed);
    try testing.expect(axisSegCount(try rfTracks(arena, routed)) >= 3);
}

// spec: placement/manhattan-route - a cross-layer RF pair skips the direct tier, since one segment cannot change layer
test "a cross-layer RF pair routes through the maze tier and its via" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var rf = board(rf_hz);
    rf.parts[1].side = .bottom;
    const routed = try router.route(arena, rf.placement(), .{});
    try testing.expectEqual(@as(usize, 1), routed.routed);
    var vias: usize = 0;
    for (routed.vias) |v| {
        if (v.net == rf_net) vias += 1;
    }
    try testing.expect(vias > 0);
}

// spec: placement/manhattan-route - a declared pad escape axis decides which elbow an RF pair tries first, and a sub-width offset is drawn straight
test "the escape axis orders the elbows and the collinear test bounds the exemption" {
    // A pad escaping along x wants the leg that LEAVES it horizontal — the
    // x-first corner, candidate 0.
    const east = router.NetPt{ .x = 0, .y = 0, .layer = 0, .out = .{ 1, 0 } };
    const south = router.NetPt{ .x = 3, .y = 4, .layer = 0, .out = .{ 0, 1 } };
    const bare = router.NetPt{ .x = 3, .y = 4, .layer = 0 };
    try testing.expectEqual(@as(?u1, 0), escapeAxis(east, bare, true));
    // The FAR pad's axis decides the other way round: the leg arriving there is
    // perpendicular to the leg that left. A pad escaping along y is served by
    // the x-first corner too, so `from` takes the horizontal leg.
    try testing.expectEqual(@as(?u1, 0), escapeAxis(bare, south, true));
    // No reserve declared, or no pad naming an axis: `axisStub` bends late.
    try testing.expectEqual(@as(?u1, null), escapeAxis(east, south, false));
    try testing.expectEqual(@as(?u1, null), escapeAxis(bare, bare, true));

    // The straight exemption is bounded by the trace itself: an offset under one
    // width is a jog, one at a full width is a bend.
    try testing.expect(nearlyCollinear(.{ 0, 0 }, .{ 3, 0.06 }, 0.127));
    try testing.expect(!nearlyCollinear(.{ 0, 0 }, .{ 3, 0.2 }, 0.127));
    try testing.expect(!nearlyCollinear(.{ 0, 0 }, .{ 1.5, 8 }, 0.127));
    // A dead-on pair is trivially collinear, whatever the width.
    try testing.expect(nearlyCollinear(.{ 0, 0 }, .{ 3, 0 }, 0.127));
}

// spec: placement/manhattan-route - a direct shape that cannot give a declared escape reserve its straight run is not drawn at all, leaving the reserve to the maze tier
test "the escape reserve rejects a leg that turns too soon or leaves the wrong way" {
    const east = router.NetPt{ .x = 0, .y = 0, .layer = 0, .out = .{ 1, 0 } };
    const w: f64 = 0.3;
    // A 1.5 mm reserve wants 1.5 mm of +x before anything else happens.
    try testing.expect(escapeHonoured(east, .{ 3, 0 }, 1.5, w));
    // Half a millimetre of +x and then a corner does not honour it — this is
    // barracuda's rf-escape fixture, and why the tier declines it outright.
    try testing.expect(!escapeHonoured(east, .{ 0.5, 0 }, 1.5, w));
    // Leaving along the wrong axis, or the wrong way down the right one, fails
    // however long the leg is.
    try testing.expect(!escapeHonoured(east, .{ 0, 5 }, 1.5, w));
    try testing.expect(!escapeHonoured(east, .{ -3, 0 }, 1.5, w));
    // A sub-width sideways drift is inside the trace, not a bend…
    try testing.expect(escapeHonoured(east, .{ 3, 0.2 }, 1.5, w));
    try testing.expect(!escapeHonoured(east, .{ 3, 0.6 }, 1.5, w));
    // …and a net that declares no reserve, or a pad that names no axis, is
    // unconstrained.
    try testing.expect(escapeHonoured(east, .{ 0, 5 }, 0, w));
    try testing.expect(escapeHonoured(.{ .x = 0, .y = 0, .layer = 0 }, .{ 0, 5 }, 1.5, w));
}

// spec: placement/manhattan-route - a plain waypointed RF net takes the axis attempt and its waypoint goes unused when the attempt closes
test "a waypointed RF net is routed rectilinear rather than through its waypoint" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Barracuda's `(waypoints …)` on RF nets were authored by earlier ROUTING
    // campaigns to buy a clean elbow — which is what this rung produces
    // natively — so a plain waypoint is a means, not a shape the author owns.
    // The waypoint here sits well off any sensible path; the copper must ignore
    // it and come out rectilinear instead.
    var rf = board(rf_hz);
    const waypoints = [_]route_policy.Waypoint{.{ .x = 6, .y = 9.5, .layer = 0 }};
    const policies = [_]route_policy.NetPolicy{.{ .waypoints = &waypoints }};
    const routed = try router.routeWithOptions(arena, rf.placement(), .{}, .{ .net = &policies });
    try testing.expectEqual(@as(usize, 1), routed.routed);
    const tracks = try rfTracks(arena, routed);
    try testing.expectApproxEqAbs(@as(f64, 0), longestStrayMm(tracks, routed.arcs), 1e-9);
    try testing.expect(!touchesNear(tracks, .{ 6, 9.5 }, 1.0));
}

// spec: placement/manhattan-route - a declined axis attempt hands its net back to the waypoint machinery with the authored waypoints intact
test "a waypointed RF net the axis attempt declines still routes through its waypoint" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // The wall makes every axis closure a detour past `detour_cap`, so the
    // attempt declines — and the waypoint it cleared for its own span has to be
    // back in place for the ladder below. The proof is which way the copper goes
    // round: the natural detour is to the RIGHT, and this waypoint is on the
    // LEFT, so a route through it can only come from waypoints that survived.
    var rf = hopBoard(rf_hz);
    const waypoints = [_]route_policy.Waypoint{.{ .x = 0.5, .y = 3.7, .layer = 0 }};
    const policies = [_]route_policy.NetPolicy{.{ .waypoints = &waypoints, .max_vias = 0 }};
    const routed = try router.routeWithOptions(arena, rf.placement(), .{}, .{ .net = &policies });
    try testing.expectEqual(@as(usize, 1), routed.routed);
    try testing.expect(touchesNear(try rfTracks(arena, routed), .{ 0.5, 3.7 }, 1.0));
}

// spec: placement/manhattan-route - an authored guide-branch tree still owns its RF net's shape and refuses the axis attempt
test "a guide-branch tree keeps its RF net on the guided ladder" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // An authored `(guides …)` limb on a TWO-terminal net is lowered to a
    // waypoint chain before the ladder runs, so by the time this rung is asked
    // it looks exactly like the plain `(waypoints …)` it now accepts. The gate
    // therefore reads the POLICY, not the lowered form: the author asked for a
    // tree, and a tree owns its net's shape. The proof is the copper — it still
    // detours through the limb's own point, which no axis route goes near.
    var rf = board(rf_hz);
    const limb = [_]route_policy.Waypoint{
        .{ .x = 5, .y = 6, .layer = 0 },
        .{ .x = 9, .y = 7, .layer = 0 },
    };
    const branches = [_]route_policy.GuideBranch{.{ .waypoints = &limb }};
    const policies = [_]route_policy.NetPolicy{.{ .wave = .{ .branches = &branches } }};
    const routed = try router.routeWithOptions(arena, rf.placement(), .{}, .{ .net = &policies });
    try testing.expectEqual(@as(usize, 1), routed.routed);
    try testing.expect(touchesNear(try rfTracks(arena, routed), .{ 5, 6 }, 1.0));
}

// spec: placement/manhattan-route - an axis closure that only exists as a long detour is declined, so a short RF hop is never lengthened to keep its corners square
test "an RF hop whose only axis closure is a wall detour falls back to the ladder" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var rf = hopBoard(rf_hz);
    const routed = try router.routeWithOptions(arena, rf.placement(), .{}, .{ .net = &no_vias });
    try testing.expectEqual(@as(usize, 1), routed.routed);
    const tracks = try rfTracks(arena, routed);
    try testing.expect(tracks.len > 0);
    // An ACCEPTED axis route is bounded by `detour_cap` × span by construction,
    // so copper longer than that can only have come from the ladder below. This
    // is the whole point of the cap: a 2.9× wall detour with square corners is
    // worse copper than the short diagonal the ordinary router draws.
    try testing.expect(routedMm(tracks) > detour_cap * hop_span_mm);
}

// spec: placement/manhattan-route - declaring RF discipline never costs a board a routed net, because a declined axis attempt rolls back and the ordinary ladder runs unchanged
test "an RF net in a tight slot routes exactly as often as the same net without the class" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Staggered bars leave a slot the axis lattice has a far harder time
    // threading than the 45° maze does. Whether the attempt closes it or gives
    // up, the outcome the board sees must be identical either way.
    for ([2][4]f64{ .{ 6.0, 2.0, 0.8, 5.0 }, .{ 5.0, 6.0, 0.8, 7.0 } }) |bar| {
        var plain = board(0);
        plain.block(0, bar[0], bar[1], bar[2], bar[3]);
        plain.block(1, bar[0] + 1.4, 11 - bar[1], bar[2], bar[3]);
        const before = try router.route(arena, plain.placement(), .{});

        var rf = board(rf_hz);
        rf.block(0, bar[0], bar[1], bar[2], bar[3]);
        rf.block(1, bar[0] + 1.4, 11 - bar[1], bar[2], bar[3]);
        const after = try router.route(arena, rf.placement(), .{});

        try testing.expectEqual(before.routed, after.routed);
    }
}

// spec: placement/manhattan-route - a differential pair member, a pinned corridor, an authored guide and a plain net are all refused the axis-only attempt
test "eligibility refuses every net whose shape something else owns" {
    const rf = State{ .max_freq_hz = rf_hz };
    const open = Gate{ .state = rf, .pinned = false, .guided = false };
    try testing.expect(eligible(open));
    // No RF class declared: the ladder is byte-for-byte unchanged for this net.
    try testing.expect(!eligible(.{ .state = .{}, .pinned = false, .guided = false }));
    // A declared pair's coupled construction owns its centreline…
    try testing.expect(!eligible(.{
        .state = .{ .max_freq_hz = rf_hz, .diff_paired = true },
        .pinned = false,
        .guided = false,
    }));
    // …as do a corridor that already names the path, and a guide-branch tree
    // whose per-drop corridors this attempt cannot walk. Plain `(waypoints …)`
    // are deliberately absent from this list — they set neither flag.
    try testing.expect(!eligible(.{ .state = rf, .pinned = true, .guided = false }));
    try testing.expect(!eligible(.{ .state = rf, .pinned = false, .guided = true }));
}

// spec: placement/manhattan-route - the detour budget admits a clean elbow and refuses a route that runs far past its own span
test "the detour cap measures a route against its terminals' minimum spanning tree" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Two terminals: the MST is the pad-to-pad line, here 3√2 on the diagonal.
    const pair = [_]router.NetPt{
        .{ .x = 0, .y = 0, .layer = 0 },
        .{ .x = 3, .y = 3, .layer = 0 },
    };
    try testing.expectApproxEqAbs(@as(f64, 3 * std.math.sqrt2), try mstMm(arena, &pair), 1e-9);

    // The perpendicular equal-arm elbow — the WORST a clean single corner can
    // cost — is 3 + 3 = 6, exactly √2 times that line. It is admitted, which is
    // what makes the cap a shape allowance rather than a length one.
    const elbow = [_]router.Track{ leg(0, 0, 3, 0), leg(3, 0, 3, 3) };
    try testing.expectApproxEqAbs(@as(f64, 6), routedMm(&elbow), 1e-9);
    try testing.expect(try withinDetourCap(arena, &elbow, &pair));

    // Barracuda's `RF1_HPF` ratio — 12.6 mm of copper across a 4.24 mm span,
    // 2.97× — is a wall detour, not a corner, and is refused.
    const detour = [_]router.Track{ leg(0, 0, 6.3, 0), leg(6.3, 0, 6.3, 3), leg(6.3, 3, 3, 3) };
    try testing.expect(routedMm(&detour) > 2.9 * mstOf(pair));
    try testing.expect(!try withinDetourCap(arena, &detour, &pair));

    // Three terminals span the two SHORT edges, not the perimeter: a tree that
    // costs 2 mm must not be judged against the 2 + 2 + 2√2 loop around them.
    const tee = [_]router.NetPt{
        .{ .x = 0, .y = 0, .layer = 0 },
        .{ .x = 2, .y = 0, .layer = 0 },
        .{ .x = 0, .y = 2, .layer = 0 },
    };
    try testing.expectApproxEqAbs(@as(f64, 4), try mstMm(arena, &tee), 1e-9);
    // A single terminal spans nothing, so nothing but empty copper fits it.
    try testing.expectApproxEqAbs(@as(f64, 0), try mstMm(arena, tee[0..1]), 1e-9);
}

fn leg(x1: f64, y1: f64, x2: f64, y2: f64) router.Track {
    return .{ .x1 = x1, .y1 = y1, .x2 = x2, .y2 = y2, .layer = 0, .width = 0.127, .net = rf_net };
}

/// The pad-to-pad distance of a two-terminal set, for a test that states a ratio
/// without re-deriving the tree.
fn mstOf(pair: [2]router.NetPt) f64 {
    return apart(.{ pair[0].x, pair[0].y }, .{ pair[1].x, pair[1].y });
}

// spec: placement/manhattan-route - a corner costs the axis-only search four grid pitches and every other route the ordinary octilinear nudge, with a shape-pinned leg paying nothing
test "turnCost prices a corner at four pitches for the axis attempt and a nudge for everyone else" {
    const nx: usize = 4;
    const nodes: usize = 12;
    var prev: [24]i64 = @splat(-1);
    prev[5] = 4; // reached node 5 heading east
    const lat = octilinear.Lattice{ .nx = nx, .nodes = nodes, .prev = &prev };
    const g: f64 = 0.4;
    const active = State{ .active = true, .max_freq_hz = rf_hz };
    // Turning north at 5 costs the configured multiple of the grid pitch…
    try testing.expectApproxEqAbs(g * turn_cost_mult, active.turnCost(g, lat, 5, 1), 1e-12);
    // …carrying straight on costs nothing…
    try testing.expectApproxEqAbs(@as(f64, 0), active.turnCost(g, lat, 5, 6), 1e-12);
    // …and a via carries no heading, so a layer change is never a corner.
    try testing.expectApproxEqAbs(@as(f64, 0), active.turnCost(g, lat, 5, 5 + nodes), 1e-12);
    // Every other route pays the ordinary octilinear nudge for the same corner —
    // a fraction of the axis attempt's price, because the 8-neighbour lattice
    // already charges a detour by length and needs only the ties broken.
    const idle = State{ .max_freq_hz = rf_hz };
    try testing.expectApproxEqAbs(g * router.bend_cost_mult, idle.turnCost(g, lat, 5, 1), 1e-12);
    try testing.expect(router.bend_cost_mult < turn_cost_mult);
    try testing.expectApproxEqAbs(@as(f64, 0), idle.turnCost(g, lat, 5, 6), 1e-12);
    // …and nothing at all on a leg whose shape an explicit constraint already
    // pins, where a corner preference must not reorder anything. The axis
    // attempt is exempt from the exemption: it is buying the corner outright.
    const pinned = octilinear.Lattice{ .nx = nx, .nodes = nodes, .prev = &prev, .enabled = false };
    try testing.expectApproxEqAbs(@as(f64, 0), idle.turnCost(g, pinned, 5, 1), 1e-12);
    try testing.expectApproxEqAbs(g * turn_cost_mult, active.turnCost(g, pinned, 5, 1), 1e-12);
}

/// A join seam for the `axisStub` test, in the same shape the router's own one
/// has: `clear` vetoes any leg passing within `r` of `blocked`, and `seg`
/// records what was drawn.
const Seam = struct {
    arena: std.mem.Allocator,
    out: *std.ArrayList([2][2]f64),
    blocked: [2]f64,
    r: f64,

    fn clear(self: Seam, a: [2]f64, b: [2]f64) bool {
        for (0..33) |i| {
            const t = @as(f64, @floatFromInt(i)) / 32.0;
            const x = a[0] + t * (b[0] - a[0]);
            const y = a[1] + t * (b[1] - a[1]);
            if (std.math.hypot(x - self.blocked[0], y - self.blocked[1]) < self.r) return false;
        }
        return true;
    }

    fn seg(self: Seam, a: [2]f64, b: [2]f64) std.mem.Allocator.Error!void {
        try self.out.append(self.arena, .{ a, b });
    }
};

// spec: placement/manhattan-route - the axis join emits an L only when both legs clear and reports failure rather than falling back to a diagonal
test "axisStub takes the late bend, straightens an aligned pair and refuses a blocked join" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var out: std.ArrayList([2][2]f64) = .empty;
    const open = Seam{ .arena = arena, .out = &out, .blocked = .{ 100, 100 }, .r = 1 };

    // (0,0) → (6,2): the x-first corner (6,0) is farther from `a` than the
    // y-first corner (0,2), so the LATE bend is tried and taken first.
    try testing.expect(try axisStub(open, .{ 0, 0 }, .{ 6, 2 }));
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqual([2]f64{ 6, 0 }, out.items[0][1]);
    try testing.expectEqual([2]f64{ 6, 2 }, out.items[1][1]);

    // Blocking that corner falls to the OTHER L, never to a diagonal.
    out = .empty;
    const corner_blocked = Seam{ .arena = arena, .out = &out, .blocked = .{ 5, 0 }, .r = 1.5 };
    try testing.expect(try axisStub(corner_blocked, .{ 0, 0 }, .{ 6, 2 }));
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqual([2]f64{ 0, 2 }, out.items[0][1]);

    // An already-aligned pair is one straight run and no corner at all.
    out = .empty;
    try testing.expect(try axisStub(open, .{ 0, 0 }, .{ 6, 0 }));
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual([2]f64{ 6, 0 }, out.items[0][1]);

    // With both L's vetoed the join fails and — the part that matters — draws
    // nothing, so the caller's rollback has nothing half-finished to undo.
    out = .empty;
    const sealed = Seam{ .arena = arena, .out = &out, .blocked = .{ 3, 1 }, .r = 4 };
    try testing.expect(!try axisStub(sealed, .{ 0, 0 }, .{ 6, 2 }));
    try testing.expectEqual(@as(usize, 0), out.items.len);
}

// spec: placement/manhattan-route - an accepted axis-only route is measured for the off-axis copper its join seams can still emit
test "allAxis forgives a sub-micron join stub and refuses real diagonal copper" {
    const straight = [_]router.Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 4, .y2 = 0, .layer = 0, .width = 0.127, .net = rf_net },
        .{ .x1 = 4, .y1 = 0, .x2 = 4, .y2 = 3, .layer = 0, .width = 0.127, .net = rf_net },
    };
    try testing.expect(allAxis(&straight));
    // A weld bridging one clearance halo is off-axis by construction and far
    // shorter than the tolerance; refusing the route over it would trade the
    // clean trace for an open net.
    const welded = straight ++ [_]router.Track{
        .{ .x1 = 4, .y1 = 3, .x2 = 4.0002, .y2 = 3.0002, .layer = 0, .width = 0.127, .net = rf_net },
    };
    try testing.expect(allAxis(&welded));
    // A real 45° leg is exactly what the attempt exists to avoid.
    const meander = straight ++ [_]router.Track{
        .{ .x1 = 4, .y1 = 3, .x2 = 5, .y2 = 4, .layer = 0, .width = 0.127, .net = rf_net },
    };
    try testing.expect(!allAxis(&meander));
    // Nothing routed is trivially compliant.
    try testing.expect(allAxis(&.{}));
}
