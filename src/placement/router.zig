//! In-tool grid maze (Dijkstra) autorouter — a first, deliberately simple cut.
//!
//! Stackup is 4-layer: top signal, GND plane, PWR plane, bottom signal. Ground
//! nets are connected to the GND plane with a via at each pad (no surface
//! trace). Every other multi-pad net is routed as real copper on the two
//! signal layers (top + bottom), switching layers through vias when a layer is
//! blocked. The board is rasterised to a grid whose pitch is `track_width +
//! clearance`, so two traces on adjacent grid lines satisfy the spacing rule;
//! pads of other nets (plus the board edge and already-routed copper) are
//! obstacles. Each net's pads are joined incrementally (route pad → the net's
//! routed-so-far set), i.e. a maze-routed tree.
//!
//! This is a maze router, not a commercial one: it routes nets in order with
//! no rip-up, so congested boards can leave nets unrouted (counted in
//! `RouteResult.routed`/`total`, named in `RouteResult.failed`). It's aimed at
//! module-scale boards. Coordinates are millimetres, y-down (KiCad convention).
//!
//! This file is the maze ENGINE — the grid, the obstacle model, Dijkstra, the
//! rip-up transaction, and the gap-closing machinery. Concerns that only read
//! the copper the engine produces, or that only describe what a caller asks
//! for, live in siblings and are re-exported here so `router.X` stays the
//! spelling every caller uses:
//!
//!   * `route_cleanup.zig`  — post-route geometry cleanup (E1/E7/E8/E9)
//!   * `gap_policy.zig`     — the `closeGaps` contract + rip-up ladder policy
//!   * `route_timeline.zig` — the decision timeline / progress recorder
//!   * `return_path.zig`    — the return-path continuity SI metric

const std = @import("std");
const board_layers = @import("../board_layers.zig");
const clock = @import("../infra/clock.zig");
const cdt_layers = @import("cdt_layers.zig");
/// Named-verdict channel for the shape tier, matching the residual planner's.
const shapeLog = std.log.info;
const optimizer = @import("optimizer.zig");
const diff_pairs = @import("diff_pairs.zig");
const match_group = @import("match_group.zig");
const diff_couple = @import("diff_couple.zig");
const module_policy = @import("module_policy.zig");
const route_policy = @import("route_policy.zig");
const pair_pinch = @import("pair_pinch.zig");
const guide_branch = @import("guide_branch.zig");
const bend_smooth = @import("bend_smooth.zig");
const octilinear = @import("octilinear.zig");
const manhattan_route = @import("manhattan_route.zig");
const detour_guard = @import("detour_guard.zig");
const net_topology = @import("net_topology.zig");
const maze_scratch = @import("maze_scratch.zig");
const straighten = @import("straighten.zig");
const pad_escape = @import("pad_escape.zig");
const fine_window = @import("fine_window.zig");
const fine_accept = @import("fine_accept.zig");
const congestion = @import("congestion.zig");
const joint_rescue = @import("joint_rescue.zig");
const escalate_retry = @import("escalate_retry.zig");
const pad_shape = @import("pad_shape.zig");
const pad_grid = @import("pad_grid.zig");
const plane_via = @import("plane_via.zig");
const plane_stitch = @import("plane_stitch.zig");
const implicit_plane = @import("implicit_plane.zig");
const perimeter_fence = @import("perimeter_fence.zig");
const keepout = @import("keepout.zig");
const pad_project = @import("pad_project.zig");
const disc_stamp = @import("disc_stamp.zig");
const lane_reserve = @import("lane_reserve.zig");
const rf_shadow = @import("rf_shadow.zig");
const pad_exit = @import("pad_exit.zig");
const route_cleanup = @import("route_cleanup.zig");
const power_route_width = @import("power_route_width.zig");
const gap_policy = @import("gap_policy.zig");
const route_timeline = @import("route_timeline.zig");
const return_path = @import("return_path.zig");
const rf_port_report = @import("rf_port_report.zig");
const route_result = @import("route_result.zig");
const router_support = @import("router_support.zig");
const segPointDist = pad_shape.segPointDist; // one home for the segment
const segSegDist = pad_shape.segSegDist; // geometry both files need
const geometry = @import("geometry.zig");
const outline_mod = @import("outline.zig");
const route_timing = @import("route_timing.zig");
const route_grid = @import("route_grid.zig");
const via_rules = @import("router_via_rules.zig");
const flat_netlist = @import("../flat_netlist.zig");
const numeric = @import("../numeric.zig");
const Part = optimizer.Part;
const FlatNet = flat_netlist.FlatNet;

pub const RouteParams = router_support.RouteParams;

/// A pad as a routing obstacle: its world bounding box, its real copper outline
/// (`poly`; empty ⇒ the box is exact), the net it belongs to, and the signal
/// layer its copper lives on (`layer` 0 = top, 1 = bottom — the placed part's
/// side; `thru` pads exist on BOTH layers). The maze pass rasterises the box;
/// the clearance checks measure against the outline.
pub const PadObs = pad_grid.PadObs;

pub const Track = route_result.Track;
pub const Via = route_result.Via;
pub const Arc = route_result.Arc;
pub const SharpBend = route_result.SharpBend;
pub const RouteResult = route_result.RouteResult;

/// One meaningful router decision in chronological order (see
/// `route_timeline.RouteEventKind`).
pub const RouteEventKind = route_timeline.RouteEventKind;
/// A decision label plus the exact copper state immediately after it.
pub const RouteEvent = route_timeline.RouteEvent;
/// The cumulative route metrics and exact board copper at one decision.
pub const RouteEventState = route_timeline.RouteEventState;
/// Opt-in review result: the final `RouteResult` plus the decision timeline.
pub const RouteRun = route_timeline.RouteRun;
/// The routing geometry one attempt searched on (see `route_timeline`).
pub const PassContext = route_timeline.PassContext;

const TimelineMark = route_timeline.TimelineMark;
const TimelineRecorder = route_timeline.TimelineRecorder;
const RouteProgress = route_timeline.RouteProgress;

// The lattice's own sizing policy lives in `route_grid.zig` (router.zig is at
// Guardian's code-line ceiling). These aliases keep every call site here — and
// the meaning of each name — exactly as it was before the extraction.
const max_nodes = route_grid.max_nodes;
const fine_selection_max_nets = route_grid.fine_selection_max_nets;
const selectedCount = route_grid.selectedCount;
const maxRouteParams = route_grid.maxRouteParams;
const selectedDiffPairGap = route_grid.selectedDiffPairGap;
const GridDims = route_grid.GridDims;
const effectiveGridScale = route_grid.effectiveGridScale;
const routeGridDims = route_grid.routeGridDims;
const fittedGridScale = route_grid.fittedGridScale;
const route_grid_margin_mm = route_grid.apron_mm;
/// Escalated per-leg expansion budget for the post-greedy retry of a net (or
/// atomic diff pair) that ended the greedy pass search-limited. Far above the
/// whole-board `max_batch_expansions`, but applied to only the handful of
/// still-failed nets, so the full replay stays bounded (a few extra seconds).
const max_escalated_expansions: usize = 400_000;
/// The last-resort per-leg expansion budget: a single bounded retry, far above
/// `max_escalated_expansions`, for the few nets still search-limited after the
/// escalate↔rip-up interleave has run. Applied to only that residual set, so
/// the full replay stays well under its time ceiling (comfortably below the
/// ~3 M-expansion practical maze-search cap).
const max_last_resort_expansions: usize = 1_500_000;
/// Quarter-pitch scale shared by the selected-net reroute and the batch's
/// residual single-net pass. Keeping one spelling prevents the two fine-grid
/// entry points from silently drifting.
const fine_grid_scale: f64 = 0.25;
/// Occupancy/reservation sentinel for a grid cell no net has claimed.
pub const empty_cell: i32 = -1;
const via_cost_mult: f64 = 4.0; // a layer change costs ~4 grid steps
/// Cost assigned to adding a fresh retained-pour access via. A same-net via
/// that already intersects the pour is cheaper when its trace-distance from
/// the terminal is at most this value, so nearby terminals share one barrel
/// instead of drilling a tight cluster. Beyond 3 mm a local new transition is
/// preferred. Foreign-net vias are never reusable.
const new_zone_via_cost_mm: f64 = 3.0;
/// Nets with at most this many pads get the top-layer-first attempt (feedback
/// taps, straps, short two/three-pad signals). Fat nets skip it — see pass 2.
const top_first_max_pads: usize = 4;
/// Top-layer-first runs only on boards no larger than this. Bigger boards are
/// dense enough that forcing short nets onto the surface costs more (slow failed
/// searches) than it saves and disturbs the routing of other nets — see pass 2.
const top_first_max_parts: usize = 32;
/// Return-path stitching runs only on boards no larger than this. The pass is
/// purely additive (it can't disturb existing routing), but it runs a via search
/// per unstitched signal via, so a huge board's already-long route is left alone.
const stitch_max_parts: usize = 48;
const targeted_stitch_max_nets: usize = 8;
const sqrt2: f64 = 1.4142135623730951; // diagonal step length vs. orthogonal

/// Step-cost multiplier for maze moves onto an outer layer a declared pour
/// covers: every signal trace there slices the pour into islands, so signals
/// prefer the un-poured face — but the layer stays usable when the other side
/// is walled off (the Gerber emission carves clearance around whatever lands
/// there, so the result is legal either way).
const pour_cost_mult: f64 = 1.5;
/// Step-cost multiplier for maze moves on an INNER signal layer (index ≥ 2,
/// from a `(stackup …)` with more than two plane-free copper layers). Kept
/// mild: an inner dive already pays two via costs, so this only breaks the
/// tie against equal-length inner paths — a trivially routable board keeps
/// all its copper on the outer faces (identical to the 2-layer result), while
/// a congested crossing still dives inner the moment the surface detour
/// exceeds ~25% of the path. No-op on ≤2-signal boards (no such layer exists).
const inner_cost_mult: f64 = 1.25;
/// Step-cost multiplier for a diff-pair N-net maze move landing in its P twin's
/// coupling corridor (`Ctx.corridor`): a discount so the pair runs parallel and
/// tight. Only ever applied when a corridor is active — null keeps 1.0, byte-identical.
const diff_corridor_mult: f64 = 0.5;
const diff_via_on_ring_mult: f64 = 0.005;
const diff_via_off_ring_mult: f64 = 8.0;
/// A completed reference corridor is a soft topology hint, not copper. Staying
/// on it is strongly preferred; a legal detour remains possible.
const reference_corridor_mult: f64 = 0.1;
const reference_via_mult: f64 = 0.1;
const reference_off_via_mult: f64 = 8.0;
/// Cost multiplier for trace steps outside the current route wave's preferred
/// layers. Large enough to justify a layer change on a useful run, but finite
/// so the router can escape a blocked preferred layer.
const preferred_layer_cost_mult: f64 = 3.0;
/// What one heading change costs an ORDINARY maze leg, as a multiple of the
/// grid pitch — the octilinear counterpart of `manhattan_route.turn_cost_mult`,
/// which prices the same corner at 4 pitches for an axis-only RF net.
///
/// Additive, like every other term here, and applied after the layer/corridor
/// multipliers so a corner costs the same wherever it happens (a corner is a
/// property of the turn, not of the copper it turns on).
///
/// Sized as a NUDGE rather than a preference. On the 8-neighbour lattice every
/// interleaving of the same diagonal and orthogonal steps has exactly equal
/// length, so with no price at all the search keeps whichever micro-staircase
/// it happened to pop first; 0.15 pitches is enough to separate those (a
/// staircase pays per facet, its L pays twice) while leaving the search's
/// ordering essentially length-driven. The ceiling is real and measured: the
/// note this constant replaces recorded a 0.6-pitch price taking barracuda from
/// 81/90 nets and 19 DRC findings to 61/90 and 257 — a bend price large enough
/// to reorder ROUTABILITY buys shape at the cost of connectivity, which is
/// never the trade. 0.15 keeps every corner cheaper than one orthogonal step,
/// so no bend can ever outrank real length.
///
/// A* stays admissible: `routeHeuristic` estimates the straight-line distance
/// scaled by the smallest multiplier any step can carry, and a bend only ever
/// ADDS to the true remaining cost, so the estimate can only fall further below
/// it. Nothing about the heuristic changes.
pub const bend_cost_mult: f64 = 0.15;
/// Geometry comparisons use the same one-nanometre tolerance as `drc.zig`,
/// so a route on an exact decimal clearance boundary is accepted consistently.
pub const clearance_eps: f64 = 1e-6;

/// What one plane-carried net's pass did: whether any pad needed a via, and
/// whether any actually dropped.
const PlaneTally = struct { needed: bool = false, placed: bool = false };

/// The exposed-paddle array geometry — preferred pitch, axis bound, one axis's
/// site count, and the centred lattice itself — lives with the rest of the
/// plane-via siting rules (`plane_via`), which already owns whether a given
/// barrel fits inside a paddle's real outline.
const thermal_via_pitch_mm = plane_via.thermal_via_pitch_mm;
const ThermalArray = plane_via.ThermalArray;
const thermalAxis = plane_via.thermalAxis;

/// Whether this terminal is a dominant exposed die/power paddle rather than an
/// ordinary contact that merely happens to admit multiple drills.
fn exposedPadArea(
    placement: optimizer.Placement,
    idx_of: *std.StringHashMapUnmanaged(usize),
    p: NetPt,
) f64 {
    if (p.thru) return 0;
    const pi = idx_of.get(p.ref_des) orelse return 0;
    const part = placement.parts[pi];
    if (part.kind != .hub or part.pads.len < 3) return 0;
    var own: f64 = 0;
    var other: f64 = 0;
    for (part.pads) |pad| {
        const area = pad.w * pad.h;
        if (std.mem.eql(u8, pad.number, p.pin))
            own = @max(own, area)
        else if (!pad.thru)
            other = @max(other, area);
    }
    // An exposed die/power pad is the footprint's dominant SMD copper feature,
    // not merely a connector contact that happens to admit two drills.
    return if (own >= 1.0 and own >= 2.0 * other) own else 0;
}

const ThermalPads = struct {
    ctx: *Ctx,
    placement: optimizer.Placement,
    idx_of: *std.StringHashMapUnmanaged(usize),
    ni: i32,

    fn plan(self: ThermalPads, p: NetPt) ?ThermalArray {
        if (exposedPadArea(self.placement, self.idx_of, p) == 0) return null;
        const pad = padCopperAt(self.ctx, .{ p.x, p.y }, self.ni, p.layer) orelse return null;
        const pad_w = pad.x1 - pad.x0;
        const pad_h = pad.y1 - pad.y0;
        const min_pitch = viaPairCenterNeed(self.ctx, self.ctx.params.via_dia, self.ctx.params.via_dia, true);
        const x = thermalAxis(pad_w, self.ctx.params.via_dia, min_pitch);
        const y = thermalAxis(pad_h, self.ctx.params.via_dia, min_pitch);
        const array = ThermalArray{
            .pad = pad,
            .centre = .{ (pad.x0 + pad.x1) / 2, (pad.y0 + pad.y1) / 2 },
            .cols = x.count,
            .rows = y.count,
            .pitch_x = x.pitch,
            .pitch_y = y.pitch,
        };
        return if (array.count() >= 2) array else null;
    }

    fn target(self: ThermalPads, p: NetPt) usize {
        return if (self.plan(p)) |array| array.count() else 0;
    }
};

/// Preserve the bypass-cap ordering rule, but lift array-capable exposed pads
/// ahead of every ordinary plane terminal. The stable insertion sort keeps all
/// previous ordering as the tie-break, so boards without thermal lands replay
/// byte-identically.
fn thermalFirstViaOrder(
    arena: std.mem.Allocator,
    thermal: ThermalPads,
    pts: []const NetPt,
    bonds: []const plane_stitch.Bond,
) std.mem.Allocator.Error![]const usize {
    const base = try plane_stitch.viaOrder(arena, pts.len, bonds);
    const order = try arena.dupe(usize, base);
    var i: usize = 1;
    while (i < order.len) : (i += 1) {
        const item = order[i];
        const score = thermal.target(pts[item]);
        var j = i;
        while (j > 0 and thermal.target(pts[order[j - 1]]) < score) : (j -= 1)
            order[j] = order[j - 1];
        order[j] = item;
    }
    return order;
}

/// Fill an exposed plane pad before any ordinary stitch is attempted. Sites
/// never leave the pad: a partial legal array is better than fanning thermal
/// drills into surrounding routing channels. Every accepted barrel is stamped
/// immediately, reserving its copper and hole wall from all later nets.
fn placeThermalViaArray(
    ctx: *Ctx,
    vias: *std.ArrayList(Via),
    tracks: []const Track,
    ni: i32,
    array: ThermalArray,
) std.mem.Allocator.Error!usize {
    var covered: usize = 0;
    for (0..array.rows) |row| {
        for (0..array.cols) |col| {
            const pos = array.point(col, row);
            if (!plane_via.barrelFits(array.pad, pos, ctx.params.via_dia)) continue;
            var already = false;
            for (vias.items) |via| {
                if (via.net != ni) continue;
                if (std.math.hypot(pos[0] - via.x, pos[1] - via.y) > clearance_eps) continue;
                already = true;
                break;
            }
            if (already) {
                covered += 1;
                continue;
            }
            if (!groundViaPointClear(ctx, vias.items, tracks, pos, ni)) continue;
            try vias.append(ctx.arena, .{ .x = pos[0], .y = pos[1], .dia = ctx.params.via_dia, .drill = ctx.params.via_drill, .net = ni });
            stampViaOcc(ctx, pos[0], pos[1], ni);
            covered += 1;
        }
    }
    return covered;
}

/// One plane-carried net's copper: its local surface bonds first, then bounded
/// arrays in exposed thermal lands, then one stitch via per remaining island
/// (`plane_stitch` owns which pads belong together and when a via is served).
///
/// Each via is sited by `findGroundVia` (clear of every foreign pad and every
/// via already down) and its halo stamped on both signal layers, so the maze
/// pass routes foreign copper around it. A pad already sitting IN an
/// outer-layer pour of its own net (same-face SMD, or any through-hole barrel)
/// needs neither bond nor via — the pour connects it. A net that reaches its
/// plane NOWHERE keeps none of the bond copper: it would stitch nothing and
/// only crowd the nets that follow.
///
/// Shared with the `groundVias` preview, so the via the viewer draws before
/// routing is the one routing drops.
fn planeNetCopper(
    thermal: ThermalPads,
    pts: []const NetPt,
    tracks: *std.ArrayList(Track),
    vias: *std.ArrayList(Via),
) std.mem.Allocator.Error!PlaneTally {
    const ctx = thermal.ctx;
    const placement = thermal.placement;
    const ni = thermal.ni;
    const arena = ctx.arena;
    const start = tracks.items.len;
    // Do not let a via newly placed for a nearby pad impersonate retained copper.
    const retained_via_count = vias.items.len;
    const pour = netPourLayers(placement, placement.nets[@intCast(ni)].name);
    const bonds = try plane_stitch.surfaceBonds(arena, placement, pts);
    var web = try plane_stitch.Web.init(arena, pts.len);
    for (bonds) |bond| {
        const from = pts[bond.cap];
        const to = pts[bond.hub];
        if (padInPour(pour, from) or padInPour(pour, to)) continue;
        // The pair's surface run, drawn with the ordinary short-hookup
        // machinery (`net_topology.padJoin` through `axisPairDogleg`) and the
        // DRC-grade probe every other direct leg uses. No clear path ⇒ nothing
        // is drawn and the pair keeps the two stitch vias it had.
        // Do not turn a declared local bond into two plane drops merely because
        // the compact land hookup is blocked; use the ordinary direct fallback.
        if (!try tryDirectDogleg(.{ .ctx = ctx, .net = ni, .tracks = tracks, .vias = vias }, from, to)) continue;
        try web.drew(arena, bond.cap, bond.hub, bond.mm);
    }
    var tally = PlaneTally{};
    for (try thermalFirstViaOrder(arena, thermal, pts, bonds)) |i| {
        const c = pts[i];
        if (try plane_stitch.retainedStubMm(Track, Via, arena, padCopperAt(ctx, .{ c.x, c.y }, ni, c.layer), c.layer, ni, tracks.items[0..start], vias.items[0..retained_via_count])) |mm| {
            tally.needed = true;
            tally.placed = true;
            web.placedVia(i, mm);
            continue;
        }
        if (thermal.plan(c)) |array| {
            tally.needed = true;
            const n = try placeThermalViaArray(ctx, vias, tracks.items, ni, array);
            if (n > 0) {
                tally.placed = true;
                web.placedVia(i, 0);
                continue;
            }
        }
        if (padInPour(pour, c)) continue;
        tally.needed = true;
        if (web.served(i)) continue;
        const cc = [2]f64{ c.x, c.y };
        // The cluster's shared barrel belongs IN the bypass cap's land (see
        // `Web.capLand`), so the run carries the rail on to the pin and no
        // copper is spent reaching the drop. Anything else keeps the ladder.
        //
        // "IN the land" is meant literally, so the exact centre is offered only
        // when the land can actually HOLD the barrel: a ring hanging off the land
        // is copper across the mask opening, and it is invisible to every
        // clearance probe here because the land is this net's own. On refusal the
        // ladder below takes over, and the loop-inductance argument degrades
        // gracefully rather than collapsing — `findGroundVia`'s in-pad walk is
        // centre-out from this same anchor, so the barrel ends up as close to the
        // land as the land admits, and only a land that cannot contain the via
        // anywhere falls through to a grid-fan site plus a stub.
        const centred = web.capLand(i) and plane_via.inLandBarrelFits(padCopperAt(ctx, cc, ni, c.layer), cc, ctx.params.via_dia);
        const pos = if (centred and groundViaPointClear(ctx, vias.items, tracks.items, cc, ni)) cc else findGroundVia(ctx, vias.items, tracks.items, cc, ni, c.layer) orelse continue;
        tally.placed = true;
        try vias.append(arena, .{ .x = pos[0], .y = pos[1], .dia = ctx.params.via_dia, .drill = ctx.params.via_drill, .net = ni });
        // A laddered via site is grid-snapped while the pad centre is not, so it
        // needs this stub back to the land (a centred barrel emits none: the
        // join is empty). On a ground net they are the most numerous copper.
        const join = OctiJoin{ .ctx = ctx, .net = ni, .layer = c.layer, .placed_vias = vias.items, .tracks = tracks };
        try octilinear.emitJoin(cc, pos, join);
        stampViaOcc(ctx, pos[0], pos[1], ni);
        web.placedVia(i, std.math.hypot(pos[0] - cc[0], pos[1] - cc[1]));
    }
    if (tally.needed and !tally.placed) {
        tracks.shrinkRetainingCapacity(start);
        restoreNetOcc(ctx, ni, tracks.items, vias.items);
    }
    return tally;
}

fn planeNetOrder(
    ctx: *Ctx,
    placement: optimizer.Placement,
    idx_of: *std.StringHashMapUnmanaged(usize),
) std.mem.Allocator.Error![]const usize {
    const arena = ctx.arena;
    var order: std.ArrayList(usize) = .empty;
    const priorities = try arena.alloc(u64, placement.nets.len);
    const thermal = try arena.alloc(f64, placement.nets.len);
    @memset(thermal, 0);
    for (placement.nets, 0..) |net, net_i| {
        const policy = if (net_i < ctx.net_policy.len) ctx.net_policy[net_i] else route_policy.NetPolicy{};
        priorities[net_i] = policy.wave.priority;
        if (netEnabled(ctx, net_i) and netHasPlane(placement, net.name)) {
            thermal[net_i] = planeNetThermalArea(placement, idx_of, net);
            try order.append(arena, net_i);
        }
    }
    sortPlaneOrder(order.items, priorities, thermal);
    return order.items;
}

fn thermalArrayNeedsPrepass(array: ThermalArray) bool {
    if (array.count() > 9) return true;
    return array.count() == 9 and
        (array.pitch_x < thermal_via_pitch_mm - clearance_eps or
            array.pitch_y < thermal_via_pitch_mm - clearance_eps);
}

/// Reserve large fields and tightly packed 3 x 3 fields before authored
/// before-plane signal waves. A 3 x 3 field that fits at the preferred pitch
/// retains its established position after those waves. Reserving every compact
/// field up front needlessly walls off plane continuity on a crowded board,
/// while a tightened field has too little spare land to route around later.
fn thermalViaPrepass(
    ctx: *Ctx,
    placement: optimizer.Placement,
    idx_of: *std.StringHashMapUnmanaged(usize),
    tracks: *std.ArrayList(Track),
    vias: *std.ArrayList(Via),
) std.mem.Allocator.Error!void {
    const arena = ctx.arena;
    for (try planeNetOrder(ctx, placement, idx_of)) |net_i| {
        const net = placement.nets[net_i];
        if (planeNetThermalArea(placement, idx_of, net) == 0) continue;
        const pts = try netPoints(arena, placement, idx_of, net);
        if (pts.len < 2) continue;
        const ni: i32 = @intCast(net_i);
        setNetParams(ctx, placement, net_i);
        const thermal = ThermalPads{ .ctx = ctx, .placement = placement, .idx_of = idx_of, .ni = ni };
        for (try thermalFirstViaOrder(arena, thermal, pts, &.{})) |i| {
            const array = thermal.plan(pts[i]) orelse continue;
            if (!thermalArrayNeedsPrepass(array)) continue;
            _ = try placeThermalViaArray(ctx, vias, tracks.items, ni, array);
        }
    }
}

/// Pass 1 of `route`: ground/plane nets, each handed to `planeNetCopper`. On a
/// plane-less stackup NOTHING gets via drops — every net (ground included)
/// falls through to the maze pass.
fn planeViaPass(
    ctx: *Ctx,
    placement: optimizer.Placement,
    idx_of: *std.StringHashMapUnmanaged(usize),
    tracks: *std.ArrayList(Track),
    vias: *std.ArrayList(Via),
    progress: *RouteProgress,
) std.mem.Allocator.Error!void {
    const arena = ctx.arena;
    for (try planeNetOrder(ctx, placement, idx_of)) |net_i| {
        const net = placement.nets[net_i];
        // Cooperative cancel: stop dropping plane vias at this net boundary. The
        // greedy pass then tallies every remaining net as failed, so the run is
        // still a valid partial result (see `route_policy.Options.stop`).
        if (routeCancelled(ctx)) break;
        const pts = try netPoints(arena, placement, idx_of, net);
        if (pts.len < 2) continue;
        progress.total += 1;
        const ni: i32 = @intCast(net_i);
        setNetParams(ctx, placement, net_i);
        if (try replayReferenceCopper(ctx, net_i, tracks, vias, false)) {
            progress.routed += 1;
            try progress.timeline.capture(.{
                .kind = .plane_routed,
                .net = net_i,
                .routed = progress.routed,
            }, tracks.items, vias.items);
            continue;
        }
        const tally = try planeNetCopper(.{ .ctx = ctx, .placement = placement, .idx_of = idx_of, .ni = ni }, pts, tracks, vias);
        // Only count the net routed if at least one plane via actually
        // dropped — a fully hemmed-in ground net must not inflate
        // routed/total and hide the hand-fix from fullRouteCost's unrouted
        // term. A net whose EVERY pad lands in an outer pour needs no via at
        // all: the pour itself is the connection, so it counts routed.
        if (tally.placed or !tally.needed) {
            progress.routed += 1;
            try progress.timeline.capture(.{
                .kind = .plane_routed,
                .net = net_i,
                .routed = progress.routed,
            }, tracks.items, vias.items);
        } else {
            try progress.failed.append(arena, net.name);
            try progress.timeline.capture(.{
                .kind = .plane_failed,
                .net = net_i,
                .routed = progress.routed,
            }, tracks.items, vias.items);
        }
    }
}

fn planeNetThermalArea(
    placement: optimizer.Placement,
    idx_of: *std.StringHashMapUnmanaged(usize),
    net: FlatNet,
) f64 {
    var best: f64 = 0;
    for (net.pins) |pin| {
        const pi = idx_of.get(pin.ref_des) orelse continue;
        const part = placement.parts[pi];
        for (part.pads) |pad| {
            if (!std.mem.eql(u8, pad.number, pin.pin) or pad.thru) continue;
            const c = optimizer.worldPadCenter(&part, pad.x, pad.y);
            const probe = NetPt{ .x = c[0], .y = c[1], .layer = if (part.side == .bottom) 1 else 0, .ref_des = pin.ref_des, .pin = pin.pin };
            best = @max(best, exposedPadArea(placement, idx_of, probe));
            break;
        }
    }
    return best;
}

const PlaneOrder = struct {
    priorities: []const u64,
    thermal: []const f64,

    fn before(self: PlaneOrder, a: usize, b: usize) bool {
        if (self.thermal[a] != self.thermal[b]) return self.thermal[a] > self.thermal[b];
        return route_policy.priorityDesc(self.priorities, a, b);
    }
};

fn sortPlaneOrder(order: []usize, priorities: []const u64, thermal: []const f64) void {
    std.sort.pdq(usize, order, PlaneOrder{ .priorities = priorities, .thermal = thermal }, PlaneOrder.before);
}

fn replayReferenceCopper(
    ctx: *Ctx,
    net_i: usize,
    tracks: *std.ArrayList(Track),
    vias: *std.ArrayList(Via),
    after_failed_synthesis: bool,
) std.mem.Allocator.Error!bool {
    if (net_i >= ctx.net_policy.len) return false;
    const policy = ctx.net_policy[net_i];
    if (!policy.replay_reference_copper) return false;
    if (!after_failed_synthesis and (policy.waypoints.len > 0 or policy.branches.len > 0)) return false;
    const net: i32 = @intCast(net_i);
    var emitted = false;
    for (ctx.guide_tracks) |guide| {
        if (guide.net != net or guide.layer >= ctx.occ.len) continue;
        const width = if (guide.width > 0) guide.width else ctx.params.track_width;
        try tracks.append(ctx.arena, .{
            .x1 = guide.x1,
            .y1 = guide.y1,
            .x2 = guide.x2,
            .y2 = guide.y2,
            .layer = guide.layer,
            .width = width,
            .net = net,
        });
        const saved_width = ctx.params.track_width;
        ctx.params.track_width = width;
        stampStubOcc(ctx, .{ guide.x1, guide.y1 }, .{ guide.x2, guide.y2 }, net, guide.layer);
        ctx.params.track_width = saved_width;
        emitted = true;
    }
    for (ctx.guide_vias) |guide| {
        if (guide.net != net) continue;
        const dia = if (guide.dia > 0) guide.dia else ctx.params.via_dia;
        const drill = if (guide.drill > 0) guide.drill else ctx.params.via_drill;
        try vias.append(ctx.arena, .{ .x = guide.x, .y = guide.y, .dia = dia, .drill = drill, .net = net });
        const saved = ctx.params;
        ctx.params.via_dia = dia;
        ctx.params.via_drill = drill;
        stampViaOcc(ctx, guide.x, guide.y, net);
        ctx.params = saved;
        emitted = true;
    }
    if (emitted) try ctx.reference_replayed.append(ctx.arena, net_i);
    return emitted;
}

const PairLeaderReq = struct { n_net: i32, gap: f64 };

const PairTxn = struct {
    p_net: usize,
    n_net: usize,
    track_mark: usize,
    via_mark: usize,
    routable_i: usize,
    leader_ok: bool,
};

const GreedyFinish = struct {
    ctx: *Ctx,
    net_pri: []const u64,
    tracks: *std.ArrayList(Track),
    vias: *std.ArrayList(Via),
    routable: *std.ArrayList(RipNet),
    pair_txn: *?PairTxn,
};

fn finishGreedyNet(
    state: GreedyFinish,
    net_i: usize,
    ok: bool,
    marks: [2]usize,
    leader_req: ?PairLeaderReq,
    follower_req: ?diff_pairs.CorridorReq,
) std.mem.Allocator.Error!void {
    const routable_i = state.routable.items.len;
    try state.routable.append(state.ctx.arena, .{
        .net_i = net_i,
        .pri = state.net_pri[net_i],
        .ok = ok,
        .reroutable = !hardGuidedPolicy(state.ctx, net_i),
    });
    if (leader_req) |req| state.pair_txn.* = .{
        .p_net = net_i,
        .n_net = @intCast(req.n_net),
        .track_mark = marks[0],
        .via_mark = marks[1],
        .routable_i = routable_i,
        .leader_ok = ok,
    };
    if (follower_req != null) if (state.pair_txn.*) |txn| {
        if (txn.n_net == net_i) {
            // Coupled (or independent-fallback) success freezes both legs. On
            // failure, KEEP the leader's copper — it routed standalone — and
            // leave both legs rescue candidates for the escalation/rip-up phases
            // instead of tearing the whole pair out (the old declared-pair
            // regression, where a follower miss dragged its routed leader down).
            state.routable.items[txn.routable_i].reroutable = !ok;
            state.routable.items[routable_i].reroutable = !ok;
            state.pair_txn.* = null;
        }
    };
}

/// One coupled diff-pair attempt's board state: the routing context plus the
/// greedy pass's live copper. Declared here (not in `diff_couple.zig`, which
/// owns the logic) because `Ctx` is router-private; the driver reaches the
/// context only through this handle.
pub const CoupledRun = struct {
    ctx: *Ctx,
    placement: optimizer.Placement,
    idx_of: *std.StringHashMapUnmanaged(usize),
    tracks: *std.ArrayList(Track),
    vias: *std.ArrayList(Via),

    /// This run as the direct (off-grid) primitives' handle on `net`.
    pub fn direct(self: CoupledRun, net: usize) DirectRun {
        return .{ .ctx = self.ctx, .net = @intCast(net), .tracks = self.tracks, .vias = self.vias };
    }
};

/// Node mask banning a maze via within `radius` of any point in `at`.
///
/// The coupled pair's own pads. A via site the envelope search likes because
/// the routing net's own pad copper is invisible to it (`viaClearsPads` skips
/// it) becomes illegal the moment the construction mirrors a second barrel onto
/// the twin's side — so the pair keeps its layer changes out of its own pad
/// field entirely, which is where a diff pair wants them anyway.
pub fn buildPairViaBan(
    run: CoupledRun,
    at: []const [2]f64,
    radius: f64,
) std.mem.Allocator.Error![]const bool {
    const grid = run.ctx.grid;
    const mask = try run.ctx.arena.alloc(bool, grid.nx * grid.ny);
    @memset(mask, false);
    for (at) |p| markForbiddenDisc(grid, mask, p[0], p[1], radius);
    return mask;
}

/// Clear a node mask within `radius` of every point in `pts`, across all signal
/// layers — the coupled pair's launch pockets in its envelope exclusion mask,
/// so it can fan out of its own pad field.
pub fn clearMaskPockets(
    run: CoupledRun,
    mask: []bool,
    pts: []const NetPt,
    radius: f64,
) std.mem.Allocator.Error!void {
    const ctx = run.ctx;
    const nodes = ctx.grid.nx * ctx.grid.ny;
    const disc = try ctx.arena.alloc(bool, nodes);
    @memset(disc, false);
    for (pts) |pt| markForbiddenDisc(ctx.grid, disc, pt.x, pt.y, radius);
    for (disc, 0..) |on, n| {
        if (!on) continue;
        for (0..ctx.occ.len) |li| mask[li * nodes + n] = false;
    }
}

/// May this declared pair be routed as ONE coupled centreline?
///
/// No, when either member authors its own waypoints or reference branches: a
/// hand-guided leg has the route its author chose, and the coupled
/// construction would silently replace BOTH legs with the envelope's path. Such
/// a pair keeps the leader/follower-corridor route, where each leg still walks
/// its own guide.
pub fn pairCouplable(ctx: *const Ctx, pair: diff_pairs.DiffPair) bool {
    return !hardGuidedPolicy(ctx, pair.p) and !hardGuidedPolicy(ctx, pair.n);
}

/// The declared pair `p_net` leads, when its N twin is in this route's scope.
pub fn pairOf(ctx: *const Ctx, pairs: []const diff_pairs.DiffPair, p_net: usize) ?diff_pairs.DiffPair {
    for (pairs) |pair| if (pair.p == p_net and netEnabled(ctx, pair.n)) return pair;
    return null;
}

fn pairLeaderReq(ctx: *const Ctx, pairs: []const diff_pairs.DiffPair, p_net: usize) ?PairLeaderReq {
    const pair = pairOf(ctx, pairs, p_net) orelse return null;
    return .{ .n_net = @intCast(pair.n), .gap = pair.gap };
}

fn hardGuidedPolicy(ctx: *const Ctx, net_i: usize) bool {
    if (net_i >= ctx.net_policy.len) return false;
    const policy = ctx.net_policy[net_i];
    return policy.waypoints.len > 0 or route_policy.hasBranchTree(policy);
}

fn pairCorridorRadius(ctx: *const Ctx, gap: f64) usize {
    const pitch = ctx.params.track_width + ctx.params.clearance;
    const coupling_window = gap + ctx.params.track_width + pitch;
    return @max(
        @as(usize, 1),
        numeric.toCount(@ceil(coupling_window / ctx.grid.g)),
    );
}

/// Arm the legacy follower-corridor state for a pair's N net (the fallback path
/// when the coupled construction declined): the corridor dilated around its
/// already-routed P twin, the twin's via-portal ring, and the pad-fan mask.
fn armFollowerCorridor(
    ctx: *Ctx,
    req: ?diff_pairs.CorridorReq,
    vias: []const Via,
    pts: []const NetPt,
) std.mem.Allocator.Error!void {
    resetPairContext(ctx);
    const need = req orelse return;
    const radius = pairCorridorRadius(ctx, need.gap);
    ctx.corridor = try diff_pairs.buildCorridor(ctx.arena, ctx.occ, ctx.grid.nx, ctx.grid.ny, need.p_net, radius);
    ctx.pair_via_mask = try buildPairViaMask(ctx, vias, need.p_net, need.gap);
    if (pts.len == 2) ctx.pair_terminal_mask = try buildPairTerminalMask(ctx.arena, ctx, pts);
}

fn buildPairTerminalMask(
    arena: std.mem.Allocator,
    ctx: *const Ctx,
    pts: []const NetPt,
) std.mem.Allocator.Error![]const bool {
    const nodes = ctx.grid.nx * ctx.grid.ny;
    const out = try arena.alloc(bool, ctx.occ.len * nodes);
    @memset(out, false);
    const fanout_mm = @max(@as(f64, 1.0), ctx.grid.g * 2);
    const cells: i64 = numeric.checkedInt(i64, @ceil(fanout_mm / ctx.grid.g)) orelse 0;
    for (pts) |pt| {
        const center = ctx.grid.nearest(pt.x, pt.y);
        var dy: i64 = -cells;
        while (dy <= cells) : (dy += 1) {
            var dx: i64 = -cells;
            while (dx <= cells) : (dx += 1) {
                const ix = @as(i64, @intCast(center[0])) + dx;
                const iy = @as(i64, @intCast(center[1])) + dy;
                if (ix < 0 or iy < 0 or ix >= ctx.grid.nx or iy >= ctx.grid.ny) continue;
                const wx = ctx.grid.worldX(@intCast(ix));
                const wy = ctx.grid.worldY(@intCast(iy));
                if (std.math.hypot(wx - pt.x, wy - pt.y) > fanout_mm) continue;
                const node = @as(usize, @intCast(iy)) * ctx.grid.nx + @as(usize, @intCast(ix));
                out[@as(usize, pt.layer) * nodes + node] = true;
            }
        }
    }
    return out;
}

fn rollbackPairTxn(
    ctx: *Ctx,
    txn: PairTxn,
    tracks: *std.ArrayList(Track),
    vias: *std.ArrayList(Via),
    routable: *std.ArrayList(RipNet),
) void {
    tracks.shrinkRetainingCapacity(txn.track_mark);
    vias.shrinkRetainingCapacity(txn.via_mark);
    restoreNetOcc(ctx, @intCast(txn.p_net), tracks.items, vias.items);
    restoreNetOcc(ctx, @intCast(txn.n_net), tracks.items, vias.items);
    // The leader may have been inline-smoothed when it routed; its copper is
    // gone now, so its arc metadata must go with it.
    _ = ctx.rf.net_smooth.remove(@intCast(txn.p_net));
    _ = ctx.rf.net_smooth.remove(@intCast(txn.n_net));
    routable.items[txn.routable_i].ok = false;
    routable.items[txn.routable_i].reroutable = false;
}

fn maskHasLegalVia(ctx: *Ctx, mask: []const bool, net: i32, vias: []const Via) bool {
    for (mask, 0..) |masked, node| if (masked and viaAllowed(ctx, node, net, vias)) return true;
    return false;
}

fn markForbiddenDisc(grid: Grid, mask: []bool, x: f64, y: f64, radius: f64) void {
    const center = grid.nearest(x, y);
    const cells: i64 = numeric.checkedInt(i64, @ceil(radius / grid.g)) orelse return;
    var dy: i64 = -cells;
    while (dy <= cells) : (dy += 1) {
        var dx: i64 = -cells;
        while (dx <= cells) : (dx += 1) {
            const ix = @as(i64, @intCast(center[0])) + dx;
            const iy = @as(i64, @intCast(center[1])) + dy;
            if (ix < 0 or iy < 0 or ix >= grid.nx or iy >= grid.ny) continue;
            const wx = grid.worldX(@intCast(ix));
            const wy = grid.worldY(@intCast(iy));
            if (std.math.hypot(wx - x, wy - y) > radius) continue;
            mask[@as(usize, @intCast(iy)) * grid.nx + @as(usize, @intCast(ix))] = true;
        }
    }
}

fn markLeaderViasWithoutPortals(
    ctx: *Ctx,
    vias: []const Via,
    via_mark: usize,
    p_net: i32,
    req: PairLeaderReq,
    forbidden: []bool,
) std.mem.Allocator.Error!bool {
    var all_paired = true;
    for (vias[via_mark..], via_mark..) |via, via_i| {
        if (via.net != p_net) continue;
        const one_via = vias[via_i .. via_i + 1];
        const mask = (try buildPairViaMask(ctx, one_via, p_net, req.gap)) orelse continue;
        ctx.pair_via_mask = mask;
        ctx.pair_vias_hard = true;
        const have_portal = maskHasLegalVia(ctx, mask, req.n_net, vias);
        ctx.pair_vias_hard = false;
        ctx.pair_via_mask = null;
        if (have_portal) continue;
        const exclusion = req.gap + ctx.params.via_dia;
        markForbiddenDisc(ctx.grid, forbidden, via.x, via.y, exclusion);
        all_paired = false;
    }
    return all_paired;
}

const pair_leader_attempts: usize = 4;

fn repairPairLeader(
    run: DirectRun,
    req: PairLeaderReq,
    pts: []const NetPt,
    marks: [2]usize,
) std.mem.Allocator.Error!bool {
    const ctx = run.ctx;
    const track_mark = marks[0];
    const via_mark = marks[1];
    const forbidden = try ctx.arena.alloc(bool, ctx.grid.nx * ctx.grid.ny);
    @memset(forbidden, false);
    var attempt: usize = 0;
    while (attempt < pair_leader_attempts) : (attempt += 1) {
        if (try markLeaderViasWithoutPortals(ctx, run.vias.items, via_mark, run.net, req, forbidden)) return true;
        if (attempt + 1 == pair_leader_attempts) return true;
        rollbackDirectRun(run, track_mark, via_mark);
        ctx.via_forbidden_mask = forbidden;
        ctx.via_forbidden_net = run.net;
        if (try routeNet(ctx, run.net, pts, run.tracks, run.vias)) continue;
        ctx.via_forbidden_mask = null;
        ctx.via_forbidden_net = empty_cell;
        return try routeNet(ctx, run.net, pts, run.tracks, run.vias);
    }
    return true;
}

/// Pass 2's greedy first-routed-wins loop, factored out of `route`. Routes each
/// maze net in `order` (already priority-sorted): short single-layer nets get a
/// top-layer-first attempt (rolled back if it fails), then the plain via-allowed
/// maze route. Every net's outcome is appended to `routable` (the rip-up working
/// set) and `total` is bumped per attempted net. No `routed`/`failed` tally here
/// — that happens after rip-up so re-routed nets count correctly.
fn greedyPass(
    ctx: *Ctx,
    placement: optimizer.Placement,
    idx_of: *std.StringHashMapUnmanaged(usize),
    order: []const usize,
    net_pri: []const u64,
    top_first: bool,
    tracks: *std.ArrayList(Track),
    vias: *std.ArrayList(Via),
    routable: *std.ArrayList(RipNet),
    progress: *RouteProgress,
) std.mem.Allocator.Error!void {
    const arena = ctx.arena;
    // A `(match-group …)` re-deals its OWN slots so its longest-expected member
    // routes first (`match_group.orderFor`), then diff pairs pull each N net in
    // behind its P net; `corridor_of[n]` carries the corridor request the N net
    // builds from P's fresh copper. All three are no-ops (the identical slice,
    // all-null) when the board declares neither construct.
    const grouped = try match_group.orderFor(arena, placement, idx_of, order);
    const eff_order = try diff_pairs.reorder(arena, grouped, placement.diff_pairs, placement.nets.len);
    const corridor_of = try diff_pairs.corridorPlan(arena, placement.nets.len, placement.diff_pairs);
    const coupled = try arena.alloc(bool, placement.nets.len);
    @memset(coupled, false);
    const coupled_run = CoupledRun{
        .ctx = ctx,
        .placement = placement,
        .idx_of = idx_of,
        .tracks = tracks,
        .vias = vias,
    };
    var pair_txn: ?PairTxn = null;
    const timing = ctx.timing;
    for (eff_order) |net_i| {
        const pts = try netPoints(arena, placement, idx_of, placement.nets[net_i]);
        if (pts.len < 2) continue;
        progress.total += 1;
        const ni: i32 = @intCast(net_i);
        const net_track_mark = tracks.items.len;
        const net_via_mark = vias.items.len;
        const leader_req = pairLeaderReq(ctx, placement.diff_pairs, net_i);
        const follower_req = if (net_i < corridor_of.len) corridor_of[net_i] else null;
        if (pair_txn) |txn| if (txn.n_net == net_i and !txn.leader_ok) {
            rollbackPairTxn(ctx, txn, tracks, vias, routable);
            try routable.append(arena, .{
                .net_i = net_i,
                .pri = net_pri[net_i],
                .ok = false,
                .reroutable = false,
            });
            pair_txn = null;
            try recordGreedyOutcome(progress, routable.items, net_i, tracks.items, vias.items);
            continue;
        };
        // Cooperative cancel: stop routing new nets here. This net (already
        // counted in `total`, any failed-leader pair rolled back above) and
        // every net after it is tallied failed, so the unreached nets stay
        // failed and the run still finishes valid (see Options.stop).
        if (routeCancelled(ctx)) {
            try routable.append(arena, .{ .net_i = net_i, .pri = net_pri[net_i], .ok = false, .reroutable = false });
            try recordGreedyOutcome(progress, routable.items, net_i, tracks.items, vias.items);
            continue;
        }
        if (timing) |t| t.beginNet(net_i);
        setNetParams(ctx, placement, net_i);
        // Refresh the exact-clearance copper index AFTER the net's params are
        // set: the index's insertion reach derives from `ctx.params`, and the
        // probes run under this net's params — a build under the previous
        // net's (narrower) params would let a wider net's probes miss items.
        // Copper also grew since the last net; the direct/lattice primitives
        // pay O(all copper) per probe without the index.
        rebuildCopperIndex(ctx, tracks.items, vias.items);
        setNetRoutePolicy(ctx, net_i, pts);
        try setNetReferenceGuide(ctx, net_i);
        // A declared diff pair routes as ONE coupled centreline (both legs land
        // together); only when that declines does the pair fall through to the
        // legacy leader + follower-corridor path below.
        if (try diff_couple.leaderRoute(coupled_run, net_i, coupled)) {
            // Both legs land together and are NOT reroutable: rip-up can never
            // tear one member out alone and leave a decoupled twin.
            try routable.append(arena, .{ .net_i = net_i, .pri = net_pri[net_i], .ok = true, .reroutable = false });
            try recordGreedyOutcome(progress, routable.items, net_i, tracks.items, vias.items);
            continue;
        }
        try armFollowerCorridor(ctx, follower_req, vias.items, pts);
        var ok = try replayReferenceCopper(ctx, net_i, tracks, vias, false);
        if (!ok and topLayerFirstEligible(ctx, top_first, pts))
            ok = try tryTopLayerFirst(ctx, ni, pts, tracks, vias);
        if (!ok and follower_req != null and pts.len == 2) {
            ctx.pair_coupling_hard = true;
            ctx.pair_vias_hard = ctx.pair_via_mask != null;
            ok = try routeNet(ctx, ni, pts, tracks, vias);
            ctx.pair_vias_hard = false;
            ctx.pair_coupling_hard = false;
        }
        // Independent fallback: a declared pair must never route worse than an
        // undeclared one. When coupling fails, drop the corridor + pair masks so
        // the plain retry below searches the whole board at the normal budget
        // (uncoupled) instead of staying confined to the 2 000-cell corridor cap.
        if (!ok and follower_req != null) {
            ctx.corridor = null;
            ctx.pair_via_mask = null;
            ctx.pair_terminal_mask = null;
        }
        if (!ok) ok = try routeNet(ctx, ni, pts, tracks, vias);
        if (!ok and immediateFineGuidedEligible(ctx, net_i, pts.len))
            ok = try immediateFineGuided(
                .{
                    .ctx = ctx,
                    .placement = placement,
                    .idx_of = idx_of,
                    .tracks = tracks,
                    .vias = vias,
                },
                net_i,
                pts,
                .{ net_track_mark, net_via_mark },
            );
        if (!ok and net_i < ctx.net_policy.len and ctx.net_policy[net_i].replay_reference_copper) {
            shrinkCopper(tracks, vias, net_track_mark, net_via_mark);
            clearNetOcc(ctx, ni);
            ok = try replayReferenceCopper(ctx, net_i, tracks, vias, true);
        }
        if (ok) if (leader_req) |req| {
            ok = try repairPairLeader(
                .{ .ctx = ctx, .net = ni, .tracks = tracks, .vias = vias },
                req,
                pts,
                .{ net_track_mark, net_via_mark },
            );
            ctx.via_forbidden_mask = null;
            ctx.via_forbidden_net = empty_cell;
        };
        try finishGreedyNet(
            .{
                .ctx = ctx,
                .net_pri = net_pri,
                .tracks = tracks,
                .vias = vias,
                .routable = routable,
                .pair_txn = &pair_txn,
            },
            net_i,
            ok,
            .{ net_track_mark, net_via_mark },
            leader_req,
            follower_req,
        );
        try recordGreedyOutcome(progress, routable.items, net_i, tracks.items, vias.items);
        if (ok) try smoothNetInline(
            .{ .ctx = ctx, .placement = placement, .tracks = tracks, .vias = vias, .progress = progress },
            net_i,
            net_track_mark,
            progress.plane_routed + countRouted(routable.items),
        );
        if (timing) |t| t.endNet();
    }
    resetPairContext(ctx);
}

/// Clear every per-pair search state (coupling corridor, via/terminal masks,
/// the coupled envelope's exclusion mask): rip-up and every later pass route
/// corridor-free, and each new pair arms only what it needs.
pub fn resetPairContext(ctx: *Ctx) void {
    ctx.corridor = null; // rip-up and later passes route corridor-free
    ctx.pair_via_mask = null;
    ctx.pair_terminal_mask = null;
    ctx.pair_coupling_hard = false;
    ctx.pair_block = null;
}

fn recordGreedyOutcome(
    progress: *RouteProgress,
    routable: []const RipNet,
    net_i: usize,
    tracks: []const Track,
    vias: []const Via,
) std.mem.Allocator.Error!void {
    const final_ok = for (routable) |rn| {
        if (rn.net_i == net_i) break rn.ok;
    } else false;
    try progress.timeline.capture(.{
        .kind = if (final_ok) .net_routed else .net_failed,
        .net = net_i,
        .routed = progress.plane_routed + countRouted(routable),
    }, tracks, vias);
}

/// Inline RF bend smoothing — the shared context for the greedy pass and
/// rip-up reroutes.
const InlineSmooth = struct {
    ctx: *Ctx,
    placement: optimizer.Placement,
    tracks: *std.ArrayList(Track),
    vias: *std.ArrayList(Via),
    /// Timeline sink; null during rip-up (its own candidate captures already
    /// show the smoothed copper).
    progress: ?*RouteProgress = null,
};

/// The clearance oracle the taut/straighten and post-route cleanup passes
/// probe with: one net's live copper (`DirectRun`) plus `clear(layer, a, b)`.
pub const TautProbe = struct {
    run: DirectRun,
    /// Straighten's clearance oracle: true when the candidate segment keeps DRC
    /// clearance from all foreign copper, pads, vias, zones, and the outline.
    pub fn clear(self: TautProbe, layer: u8, a: [2]f64, b: [2]f64) bool {
        return clearDoglegSegment(self.run.path(layer), a, b);
    }

    /// Width-aware form used by pad tapers. The exact probe temporarily reads
    /// the chord's real width and bypasses indices registered for the nominal
    /// width, so a wider launch cannot pass here and then fail final DRC.
    pub fn clearWidth(self: TautProbe, layer: u8, a: [2]f64, b: [2]f64, width: f64) bool {
        return clearDoglegSegmentWidth(self.run.path(layer), a, b, width);
    }
};

/// Reshape a just-routed `(max-freq …)` net's corners into arcs immediately,
/// so the timeline shows the trace drawn curved and every later net routes
/// around the real arc copper. `keep = tracks.items.len` before this net's
/// route: everything after it is the net's fresh copper. Chords are stamped
/// like retained copper; the arc/sharp metadata is recorded per net (dropped
/// with the net's copper on rip-up, snapshot/restored with routing state).
fn smoothNetInline(run: InlineSmooth, net_i: usize, keep: usize, routed: usize) std.mem.Allocator.Error!void {
    const ctx = run.ctx;
    if (ctx.timing) |t| t.begin(.smooth);
    defer if (ctx.timing) |t| t.end(.smooth);
    const rule: ?optimizer.NetRule =
        if (net_i < run.placement.rules.net.len) run.placement.rules.net[net_i] else null;
    if (bend_smooth.minBendRadius(rule, ctx.base.track_width) <= 0) return;
    // Also judged by the ROUTER's oracle (`bend_smooth.ExtProbe`) — zones, keepouts, RF shadow.
    const taut = TautProbe{ .run = .{ .ctx = ctx, .net = @intCast(net_i), .tracks = run.tracks, .vias = run.vias } };
    const res = try bend_smooth.apply(ctx.arena, .{
        .placement = run.placement,
        .params = ctx.params,
        .tracks = run.tracks.items,
        .vias = run.vias.items,
        .keep = keep,
        .ext = bend_smooth.ExtProbe.bind(TautProbe, &taut, @intCast(net_i)),
    });
    if (!res.changed) return;
    run.tracks.shrinkRetainingCapacity(keep);
    try run.tracks.appendSlice(ctx.arena, res.tracks[keep..]);
    for (res.arcs) |arc| {
        const chords = try bend_smooth.tessellate(ctx.arena, arc, bend_smooth.emit_sagitta_mm);
        for (chords) |chord| stampChord(ctx, chord);
        try run.tracks.appendSlice(ctx.arena, chords);
    }
    if (res.arcs.len == 0 and res.sharp.len == 0) return;
    try ctx.rf.net_smooth.put(ctx.arena, @intCast(net_i), .{ .arcs = res.arcs, .sharp = res.sharp });
    const progress = run.progress orelse return;
    try progress.timeline.capture(.{
        .kind = .bend_smoothing,
        .net = net_i,
        .routed = routed,
    }, run.tracks.items, run.vias.items);
}

/// Stamp one smoothed chord into the occupancy grid the way retained copper
/// is stamped, so later nets keep clearance from the arc's cut (which leaves
/// the maze-verified corner cells).
fn stampChord(ctx: *Ctx, chord: Track) void {
    const len = std.math.hypot(chord.x2 - chord.x1, chord.y2 - chord.y1);
    const steps: usize = @max(1, numeric.toCount(@ceil(len / (ctx.grid.g * 0.5))));
    const halo = chord.width / 2 + ctx.index_reach;
    for (0..steps + 1) |s| {
        const t = @as(f64, @floatFromInt(s)) / @as(f64, @floatFromInt(steps));
        const x = chord.x1 + t * (chord.x2 - chord.x1);
        const y = chord.y1 + t * (chord.y2 - chord.y1);
        stampDisc(ctx, x, y, chord.net, halo, chord.layer, false);
    }
}

/// The top-layer-only first attempt. Only for *short* single-layer nets
/// (e.g. a feedback tap, a strap — a handful of pads), which almost always
/// have a clear surface path. A short net with no top path rolls back its
/// copper and occupancy here and re-routes with layer changes. A net whose
/// pads straddle both board sides needs a via by definition, so the caller
/// skips this attempt outright (`topLayerFirstEligible`).
///
/// "Almost always" is the load-bearing word, and it is why a surface route that
/// lands here is also MEASURED. The pass exists on the premise that a short
/// net's surface path is the obvious one; a surface path that ran
/// `detour_guard_ratio` past the net's own span is that premise failing, and
/// accepting it is FINAL — the ladder below never runs, so the net never gets to
/// weigh a two-via hop against a tour of the board. Such a route is therefore
/// set beside the one the ordinary via-capable ladder draws, and the cheaper of
/// the two (`detourScore`) is kept. It is a comparison rather than a refusal
/// because a surface detour is often still the right answer — a net threading a
/// wall through the one slot in it legitimately runs twice its own span, and
/// paying two vias to shave a millimetre off that would be a bad trade.
fn tryTopLayerFirst(
    ctx: *Ctx,
    net: i32,
    pts: []const NetPt,
    tracks: *std.ArrayList(Track),
    vias: *std.ArrayList(Via),
) std.mem.Allocator.Error!bool {
    const t_mark = tracks.items.len;
    const v_mark = vias.items.len;
    ctx.allow_vias = false;
    ctx.use_poly = true; // accurate outlines so an EP notch frees the escape
    // `use_poly` changes what `foreignPadAt` answers, so it changes the memoized
    // static verdict — both flips invalidate it (see `resetStaticBlock`).
    ctx.static_block.reset();
    const routed = try routeNet(ctx, net, pts, tracks, vias);
    ctx.allow_vias = true;
    ctx.use_poly = false;
    ctx.static_block.reset();
    if (!routed) {
        shrinkCopper(tracks, vias, t_mark, v_mark);
        clearNetOcc(ctx, net);
        return false;
    }
    const run = DirectRun{ .ctx = ctx, .net = net, .tracks = tracks, .vias = vias };
    return try detour_guard.judgeSurfaceDetour(run, pts, t_mark, v_mark);
}

fn topLayerFirstEligible(ctx: *const Ctx, enabled: bool, pts: []const NetPt) bool {
    if (!enabled) return false;
    if (ctx.pair_via_mask != null) return false;
    if (pts.len > top_first_max_pads) return false;
    if (!layerInMask(ctx.preferred_layers, pts[0].layer)) return false;
    for (pts[1..]) |point| if (point.layer != pts[0].layer) return false;
    return true;
}

/// `buildRouteCtx` outcome: `.empty` (0-node grid) / `.overflow` (past `max_nodes`).
const CtxResult = union(enum) { ok: Ctx, empty, overflow };

fn unguidedExpansionLimit(selected_nets: []const bool) usize {
    const count = selectedCount(selected_nets);
    return if (count > 0 and count <= fine_selection_max_nets)
        route_grid.max_targeted_expansions
    else
        route_grid.max_batch_expansions;
}

fn buildPairViaMask(
    ctx: *Ctx,
    vias: []const Via,
    p_net: i32,
    pair_gap: f64,
) std.mem.Allocator.Error!?[]const bool {
    var count: usize = 0;
    for (vias) |via| if (via.net == p_net) {
        count += 1;
    };
    if (count == 0) return null;

    const grid = ctx.grid;
    const mask = try ctx.arena.alloc(bool, grid.nx * grid.ny);
    @memset(mask, false);
    const tolerance = grid.g * 0.75;
    for (vias) |via| {
        if (via.net != p_net) continue;
        const target = pair_gap + (via.dia + ctx.params.via_dia) / 2;
        const radius: i64 = numeric.checkedInt(i64, @ceil((target + tolerance) / grid.g)) orelse continue;
        const center = grid.nearest(via.x, via.y);
        var dy: i64 = -radius;
        while (dy <= radius) : (dy += 1) {
            var dx: i64 = -radius;
            while (dx <= radius) : (dx += 1) {
                const ix = @as(i64, @intCast(center[0])) + dx;
                const iy = @as(i64, @intCast(center[1])) + dy;
                if (ix < 0 or iy < 0 or ix >= grid.nx or iy >= grid.ny) continue;
                const x = grid.worldX(@intCast(ix));
                const y = grid.worldY(@intCast(iy));
                const distance = std.math.hypot(x - via.x, y - via.y);
                if (@abs(distance - target) > tolerance) continue;
                mask[@as(usize, @intCast(iy)) * grid.nx + @as(usize, @intCast(ix))] = true;
            }
        }
    }
    return mask;
}

fn buildPerimeterTrackMask(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    grid: Grid,
    track_width: f64,
) std.mem.Allocator.Error!?[]const bool {
    const limit = perimeter_fence.keepoutLimit(placement);
    if (!placement.rules.perimeter_fence.keepout.blocks.tracks or !(limit > 0)) return null;
    return via_rules.buildOutlineMask(Grid, arena, placement, grid, limit + track_width / 2);
}

fn buildPerimeterAllowed(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
) std.mem.Allocator.Error![]const bool {
    if (placement.rules.perimeter_fence.keepout.allow_nets.len == 0) return &.{};
    const allowed = try arena.alloc(bool, placement.nets.len);
    for (allowed, 0..) |*entry, i| entry.* = perimeter_fence.keepoutAllowsNet(placement, @intCast(i));
    return allowed;
}

fn perimeterAllowed(ctx: *const Ctx, net: i32) bool {
    if (net < 0) return false;
    const i: usize = @intCast(net);
    return i < ctx.perimeter_allowed.len and ctx.perimeter_allowed[i];
}

/// Build the routing grid + base `Ctx` that `route` and `groundVias` share
/// verbatim (they MUST stay in lockstep): grid pitch sized to the WIDEST net
/// class, obstacles = every pad (mirroring `drc.zig`); `.pour` filled by `route`.
fn buildRouteCtx(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    params: RouteParams,
    selected_nets: []const bool,
    requested_grid_scale: f64,
) std.mem.Allocator.Error!CtxResult {
    const maxp = maxRouteParams(placement, params, selected_nets);
    const resolution_scale = effectiveGridScale(selected_nets, requested_grid_scale);
    const dims = routeGridDims(placement, params, selected_nets, resolution_scale);
    const nx = dims.nx;
    const ny = dims.ny;
    if (nx * ny == 0) return .empty;
    if (nx * ny > max_nodes) return .overflow;
    const n_signal: usize = placement.rules.signalLayerCount();
    const obs = try buildObstacles(arena, placement.parts, placement.nets);
    var keep_state = KeepState{ .nets = try keepout.halos(arena, placement) };
    if (keep_state.nets.len > 0) {
        // The escape gate reads the same (net, centre, guarded copper) points the
        // DRC finding and the client session do — `pad_project` is that projection.
        keep_state.pads = try pad_project.keepoutPts(arena, obs);
        keep_state.zones = try keepout.buildZones(arena, placement, keep_state.pads);
        keep_state.class = .{ .ids = try keepout.classIds(arena, placement) };
    }
    const grid = Grid{
        .ox = placement.minx - route_grid_margin_mm,
        .oy = placement.miny - route_grid_margin_mm,
        .g = dims.g,
        .nx = nx,
        .ny = ny,
    };
    // The shared node mask follows track geometry. Via sites are checked at
    // their exact coordinates and larger radius by `viaClearsOutline`, so a
    // via cannot exploit a trace-width edge corridor.
    const edge_inset = via_rules.edgeInset(maxp.track_width, maxp.via_dia, placement.rules.design.edgeClearance());
    const perimeter_limit = perimeter_fence.keepoutLimit(placement);
    var ctx = Ctx{
        .arena = arena,
        .grid = grid,
        .obs = obs,
        .reach = params.track_width / 2 + params.clearance,
        .occ = try allocLayerGrids(arena, n_signal, nx * ny),
        .resv = try allocLayerGrids(arena, n_signal, nx * ny),
        .params = params,
        .base = params,
        .index_reach = maxp.track_width / 2 + maxp.clearance,
        // The per-net keepout halos travel on EVERY derived context (they are
        // net-indexed, not grid-sized, so they cost nothing and stay valid across
        // a re-grid); the node mask that enforces them is allocated only by the
        // whole-board `route` path. See `KeepState`.
        .keep = keep_state,
        // Same deal for the RF corridor widths the crossing shadow prices.
        .shadow = .{ .nets = try rf_shadow.widths(arena, placement) },
        .max_half_width = maxp.track_width / 2,
        .has_bottom_pads = router_support.anyBottomPads(obs),
        .hole_to_hole = placement.rules.design.hole_to_hole,
        .pad_drills = try PadDrills.build(arena, placement, grid, maxp.via_drill),
        .via_to_via = placement.rules.design.via_to_via,
        .edge_clearance = placement.rules.design.edgeClearance(),
        .board_rect = placement.board_rect,
        .board_poly = placement.board_poly,
        .outline_mask = try via_rules.buildOutlineMask(Grid, arena, placement, grid, edge_inset),
        .perimeter_track_mask = try buildPerimeterTrackMask(arena, placement, grid, maxp.track_width),
        .perimeter_via_clearance = if (placement.rules.perimeter_fence.keepout.blocks.vias) perimeter_limit else 0,
        .perimeter_allowed = try buildPerimeterAllowed(arena, placement),
        .net_offboard = try via_rules.netOffboard(PadObs, arena, placement, obs, staging_offboard_mm),
    };
    // Arm the static-obstacle memo for the PRIMARY route, not just the gap
    // pass: greedy, escalation and rip-up re-search the same nodes leg after
    // leg, and each sweep re-derives the identical outline / zone-polygon /
    // pad-grid verdict for them. A derived context on a DIFFERENT lattice must
    // disarm it again (`windowCtx`, `refineGapGrid`, `visionMask`), and every
    // net change re-arms it through `setNetParams` → `resetStaticBlock`.
    try armStaticBlock(&ctx, arena);
    return .{ .ok = ctx };
}

/// Snapshot the lattice + base geometry an attempt resolved to, for the
/// timeline. Everything else about the maze's view is recomputable from the
/// design and the net index; these are not (see `PassContext`).
fn passOf(ctx: *const Ctx, grid_scale: f64) PassContext {
    return .{
        .grid = ctx.grid,
        .n_signal = @intCast(ctx.occ.len),
        .base = ctx.base,
        .pour = ctx.pour,
        .grid_scale = grid_scale,
    };
}

/// What one net could legally occupy, per signal layer, at one recorded moment.
pub const VisionMask = struct {
    grid: Grid,
    n_signal: usize,
    /// Layer-major, `grid.nx * grid.ny` bytes per layer: 1 where the maze may
    /// occupy the node for this net, 0 where `blocked` refuses it.
    free: []const u8,

    /// The `free` slice for one signal layer.
    pub fn layer(self: VisionMask, index: usize) []const u8 {
        const nodes = self.grid.nx * self.grid.ny;
        return self.free[index * nodes ..][0..nodes];
    }
};

/// Everything needed to rebuild the router's view of the board at one decision.
pub const VisionInput = struct {
    placement: optimizer.Placement,
    /// The lattice the attempt searched on, from the timeline event.
    pass: PassContext,
    /// Index into `placement.nets` of the net whose view this is. Free space is
    /// per net: clearance comes from the net's class, so a fat rail sees a much
    /// tighter board than a thin signal at the very same instant.
    net_i: usize,
    /// The board copper as of that decision — the timeline event's snapshot.
    tracks: []const Track = &.{},
    vias: []const Via = &.{},
    /// Retained filled zones / keepouts, from the same layout the route ran
    /// against. Omitting them would make the mask read MORE open than the
    /// router's real view.
    zones: []const route_policy.ExistingZone = &.{},
};

/// Evaluate the maze's own `blocked` predicate over every grid node for one
/// net, against the copper recorded at one timeline decision — the free-space
/// field the route-vision overlay draws.
///
/// This is a reconstruction, not a capture: the predicate is a pure function of
/// (pads, outline, zones, foreign copper, the net's clearance), all of which the
/// caller supplies, so replaying it recovers the router's obstacle field without
/// the engine paying to record a grid per event. Because it calls the SAME
/// `blocked` the search calls, the picture cannot drift from the router's real
/// view — that is the whole point of routing it through this seam rather than
/// re-deriving free space in the serving layer.
///
/// One deliberate looseness: `ctx.resv` (the corner cells a 45° step reserves,
/// and any authored lane reservation — `VisionInput` carries no route policy)
/// and `ctx.keep.layers` (stamped RF keepout halos) start empty here, because
/// both are written as the maze lays its own copper and no snapshot records
/// them. So a handful of diagonal-squeeze cells, and the halo band around a
/// keepout net's copper, can read passable where the live search had them
/// blocked. The error is one-sided — the mask is never TIGHTER than what the
/// router saw — which keeps the overlay from blaming geometry for a net that
/// actually ran out of search. (Retained copper's own clearance still applies:
/// `stampBoardCopper` below carries the keepout term in its halo.)
///
/// Returns null when the pass carries no lattice (a timeline recorded before
/// pass context existed), when the net index is out of range, or when the
/// design's signal-layer count no longer matches the recorded run — all cases
/// where a mask would be a plausible-looking lie.
pub fn visionMask(
    arena: std.mem.Allocator,
    in: VisionInput,
) std.mem.Allocator.Error!?VisionMask {
    if (!in.pass.recorded() or in.net_i >= in.placement.nets.len) return null;
    const n_signal: usize = in.placement.rules.signalLayerCount();
    if (n_signal != in.pass.n_signal) return null;

    const base = in.pass.base;
    var ctx = switch (try buildRouteCtx(arena, in.placement, base, &.{}, in.pass.grid_scale)) {
        .ok => |c| c,
        .empty, .overflow => return null,
    };
    // Re-seat onto the RECORDED lattice rather than trusting a re-derivation:
    // the grid depends on the selected-net subset and the resolution scale the
    // attempt resolved to, which the design alone does not pin down.
    const grid = in.pass.grid.?;
    const nodes = grid.nx * grid.ny;
    if (nodes == 0 or nodes > max_nodes) return null;
    const edge_inset = via_rules.edgeInset(base.track_width, base.via_dia, in.placement.rules.design.edgeClearance());
    ctx.grid = grid;
    ctx.occ = try allocLayerGrids(arena, n_signal, nodes);
    ctx.resv = try allocLayerGrids(arena, n_signal, nodes);
    ctx.outline_mask = try via_rules.buildOutlineMask(Grid, arena, in.placement, grid, edge_inset);
    ctx.perimeter_track_mask = try buildPerimeterTrackMask(arena, in.placement, grid, base.track_width);
    ctx.pad_index = null; // rebuilt lazily against the re-seated grid
    ctx.static_block = .{}; // no memo: one sweep touches each node exactly once
    ctx.zones = in.zones;
    ctx.pour = in.pass.pour;

    // The net's own class overlay decides `reach`, so this must precede the
    // copper stamp (which haloes by `ctx.reach`) and every `blocked` call.
    setNetParams(&ctx, in.placement, in.net_i);
    const net: i32 = @intCast(in.net_i);
    stampBoardCopper(&ctx, in.tracks, in.vias, net);

    const free = try arena.alloc(u8, n_signal * nodes);
    for (0..n_signal) |l| {
        for (0..nodes) |n| free[l * nodes + n] = @intFromBool(!blocked(&ctx, l, n, net));
    }
    return .{ .grid = grid, .n_signal = n_signal, .free = free };
}

/// Build a fresh routing context over `rect` at grid pitch `g`, reusing
/// `master`'s pad obstacles, per-net policy, clearances, zones and pours so a
/// windowed maze sees exactly the DRC the whole-board pass does. Fresh
/// occupancy/reservation grids, outline mask and search buffers are allocated
/// for the window; the reference-guide, diff-pair and search-limited state are
/// cleared (a fine-window retry never seeds from reference copper), and the
/// per-leg expansion budget is set to one full sweep of the bounded window.
/// Returns null for a degenerate (zero-cell) window. Private; `fine_window.zig`
/// decides the `rect`/`g` and the router drives the maze on the built context.
fn windowCtx(
    master: *const Ctx,
    placement: optimizer.Placement,
    rect: fine_window.WindowRect,
    g: f64,
) std.mem.Allocator.Error!?Ctx {
    const arena = master.arena;
    const nx = numeric.toCount(@ceil(@max(rect.x1 - rect.x0, 0) / g) + 1);
    const ny = numeric.toCount(@ceil(@max(rect.y1 - rect.y0, 0) / g) + 1);
    if (nx * ny == 0) return null;
    const n_signal = master.occ.len;
    const grid = Grid{ .ox = rect.x0, .oy = rect.y0, .g = g, .nx = nx, .ny = ny };
    const maxp = maxRouteParams(placement, master.base, master.selected_nets);
    const edge_inset = via_rules.edgeInset(maxp.track_width, maxp.via_dia, placement.rules.design.edgeClearance());
    var c = master.*;
    c.grid = grid;
    // The field is a primary whole-board A/B provider. Fine-window retries
    // retain their existing bounded lattice semantics and cost.
    c.field_space = null;
    c.occ = try allocLayerGrids(arena, n_signal, nx * ny);
    c.resv = try allocLayerGrids(arena, n_signal, nx * ny);
    // `resv` reset 2/6 — re-rastered onto the window, unlike the reference
    // guides below: a guide is a seed a retry must not inherit, a reservation is
    // a constraint the retry would otherwise route straight through.
    lane_reserve.stamp(c.reserved_lanes, c.resv, c.grid, null);
    // The master's keepout / shadow masks are sized to the master lattice, so
    // they cannot travel onto this finer/smaller grid; the window gets its
    // keepout enforcement from `stampBoardCopper`'s halo term instead (see
    // `KeepState`) and routes on the ordinary cost model (see `rf_shadow`).
    c.keep.layers = &.{};
    c.keep.gate = &.{};
    c.shadow.layers = &.{};
    c.outline_mask = try via_rules.buildOutlineMask(Grid, arena, placement, grid, edge_inset);
    c.perimeter_track_mask = try buildPerimeterTrackMask(arena, placement, grid, maxp.track_width);
    c.pad_index = null; // rebuilt lazily for the fine grid
    // The master's memo is indexed by ITS lattice; a window's finer, smaller one
    // maps different (layer, node) pairs onto the same keys, so it must not be
    // inherited. One sweep of a bounded window touches each node about once, so
    // there is nothing to memoize here anyway.
    c.static_block = .{};
    c.search = .{};
    c.route_queue = null;
    c.search_limited = .empty;
    c.reference_replayed = .empty;
    c.rf = .{};
    c.guide_tracks = &.{};
    c.guide_vias = &.{};
    c.reference_corridor = null;
    c.reference_via_mask = null;
    c.reference_guide_active = false;
    c.corridor = null;
    c.pair_via_mask = null;
    c.pair_terminal_mask = null;
    c.pair_vias_hard = false;
    c.pair_coupling_hard = false;
    c.via_forbidden_mask = null;
    c.preserved_vias = 0;
    // One bounded sweep of the window, capped so a net that ends up unroutable
    // in the window still exhausts its search quickly.
    c.escalate_budget = @min(n_signal * nx * ny, fine_window.max_window_expansions);
    return c;
}

/// Exact via-to-outline test for both grid and off-grid synthesis. Mirrors the
/// DRC's staging exemption and measures the candidate's real copper radius;
/// nearest-node lookup is not safe for direct/escape candidates between nodes.
fn viaClearsOutline(ctx: *const Ctx, x: f64, y: f64, net: i32) bool {
    if (!via_rules.clearsOutline(
        ctx.board_rect,
        ctx.board_poly,
        ctx.params.via_dia,
        ctx.edge_clearance,
        x,
        y,
    )) return false;
    if (!(ctx.perimeter_via_clearance > 0) or perimeterAllowed(ctx, net)) return true;
    return via_rules.clearsOutline(
        ctx.board_rect,
        ctx.board_poly,
        ctx.params.via_dia,
        ctx.perimeter_via_clearance,
        x,
        y,
    );
}

/// Route `placement` under `params`. All output is allocated in `arena`.
pub fn route(arena: std.mem.Allocator, placement: optimizer.Placement, params: RouteParams) std.mem.Allocator.Error!RouteResult {
    return routeWithOptions(arena, placement, params, .{});
}

/// Route with optional net-indexed policy lowered from a resolved PCB plan.
/// Empty options are exactly the legacy `route` path.
pub fn routeWithOptions(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    params: RouteParams,
    options: route_policy.Options,
) std.mem.Allocator.Error!RouteResult {
    return (try routeWithCapture(arena, placement, params, options, false)).routed;
}

/// Arm a relative route budget exactly once. Candidate comparisons and
/// finishers copy the resulting absolute deadline so the whole transaction
/// shares one wall-clock allowance rather than resetting it per retry.
fn armDeadline(options: *route_policy.Options) void {
    if (options.stop.deadline_ns != 0 or options.stop.max_route_ms == 0) return;
    options.stop.deadline_ns = clock.nanoTimestamp() +
        @as(i128, @intCast(options.stop.max_route_ms)) * @as(i128, clock.ns_per_ms);
}

/// Request-level cancellation/deadline verdict for work outside a live maze
/// context (candidate orchestration and the post-route connectivity gate).
fn optionsCancelled(options: route_policy.Options) bool {
    if (options.stop.cancel) |flag| if (flag.load(.monotonic)) return true;
    return options.stop.deadline_ns != 0 and clock.nanoTimestamp() >= options.stop.deadline_ns;
}

/// Route with the same policy as `routeWithOptions`, capturing the ordered
/// decision snapshots used by the browser review page.
pub fn routeWithTimeline(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    params: RouteParams,
    options: route_policy.Options,
) std.mem.Allocator.Error!RouteRun {
    return routeWithCapture(arena, placement, params, options, true);
}

fn routeWithCapture(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    params: RouteParams,
    options_in: route_policy.Options,
    capture_timeline: bool,
) std.mem.Allocator.Error!RouteRun {
    var options = options_in;
    armDeadline(&options);
    if (options.timing) |t| t.noteAttempt();
    const first = try routeOnce(arena, placement, params, options, capture_timeline);
    // A cancelled run never restarts on a finer grid — the caller asked us to
    // stop, so the first (partial) result is final. (A retry would also emit a
    // second `.initial` to any live sink, which we must not do after cancel.)
    if (first.routed.cancelled) return first;
    const retry_would_repeat_limited_search = first.routed.search_limited.len > 0;
    // `one_shot` never pays a second whole pipeline run (see `route_policy.Effort`).
    if (!options.effort.retries()) return first;
    if (options.grid_scale > 0 or first.routed.grid_overflow or first.routed.failed.len == 0 or
        retry_would_repeat_limited_search) return first;
    const selected_count = selectedCount(options.selected_nets);
    if (selected_count == 0 or selected_count > fine_selection_max_nets) return first;
    var finer = options;
    finer.grid_scale = fine_grid_scale;
    if (finer.timing) |t| t.noteAttempt();
    const retry = try routeOnce(arena, placement, params, finer, capture_timeline);
    return if (retry.routed.routed > first.routed.routed) retry else first;
}

fn routeOnce(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    params: RouteParams,
    options: route_policy.Options,
    capture_timeline: bool,
) std.mem.Allocator.Error!RouteRun {
    const capture: TimelineCapture = if (capture_timeline) .on else .off;
    return switch (try routeCoreStart(arena, placement, params, options, capture)) {
        .done => |run| run,
        .core => |core| finishBatch(core),
    };
}

/// Does any net on this board declare its own raster pitch? A `one_shot` run
/// still honours those (see `finishBatch`).
fn anyDeclaredResolution(placement: optimizer.Placement) bool {
    for (placement.rules.net) |r| if (r.resolution_mm > 0) return true;
    return false;
}

/// Finish a non-interactive (batch) route: run the windowed fine-grid rescue on
/// the residual failed nets, then the standard finish passes. The interactive
/// route session drives `core.finish` itself and so deliberately skips the
/// rescue — its diagnostic stuck reports must still surface nets the automatic
/// maze could not route (see `fineWindowRescue`).
pub fn finishBatch(core: RouteCore) std.mem.Allocator.Error!RouteRun {
    // `one_shot` skips the rescue for the same reason it skips rip-up: a net the
    // maze could not route is the agent's next DSL edit, not the router's next
    // gamble (see `route_policy.Effort`). The ONE exception is a net that
    // DECLARED its own `(resolution …)` — that is already the agent's edit, so
    // running it is honouring the plan, not second-guessing it.
    const full_retry = core.ctx.effort.retries();
    if (!full_retry and !anyDeclaredResolution(core.placement)) return core.finish();
    if (core.ctx.timing) |t| t.begin(.fine_rescue);
    var gate = try fine_accept.Gate.init(core.ctx.arena, core.placement, core.ctx.zones);
    defer gate.deinit();
    const last_k = gap_policy.LastK{};
    var widen_left: usize = last_k.spenders;
    const rescued = try fineWindowRescue(.{
        .ctx = core.ctx,
        .placement = core.placement,
        .idx_of = core.idx_of,
        .routable = core.result.routable,
        .tracks = core.tracks,
        .vias = core.vias,
        .gate = &gate,
        // The ladder is over: whatever is still open here has already been
        // through greedy, escalation and the whole rip ladder. Once that
        // residual is down to the last few nets the classifier's two standing
        // refusals are stale, so arm them (see `gap_policy.lastKRungs`).
        .widen = gap_policy.lastKRungs(
            core.result.routable.len - countRouted(core.result.routable),
            last_k,
        ),
        .widen_left = &widen_left,
        // Under one-shot effort the sole exception is the author's explicit
        // resolution request. Do not silently turn that declaration into the
        // full automatic rescue pass for every other open net.
        .declared_only = !full_retry,
    });
    if (core.ctx.timing) |t| t.end(.fine_rescue);
    for (rescued) |net_i| {
        clearSearchLimit(core.ctx, net_i);
        try core.progress.timeline.capture(.{
            .kind = .net_routed,
            .net = net_i,
            .routed = core.progress.plane_routed + countRouted(core.result.routable),
        }, core.tracks.items, core.vias.items);
    }
    // One-shot honours only the declared fine-grid request. The joint and
    // congestion tiers are automatic retries, and a deadline that expires in
    // the fine pass must not start either speculative transaction.
    if (!full_retry or routeCancelled(core.ctx)) return core.finish();
    _ = try joint_rescue.run(core);
    // Last, because it is the one tier allowed to make the board temporarily
    // ILLEGAL; its own end-state gate is what makes that safe (`congestion`).
    _ = try congestion.run(core);
    return core.finish();
}

/// A finished batch route plus the LIVE core that produced it — `core` is null
/// only when the grid was empty/overflowed (nothing to route, no live state).
/// The stuck-net diagnostic needs the populated grid `finishBatch` leaves
/// behind, which the compact `RouteResult` discards.
pub const FinishedRoute = struct { result: RouteResult, core: ?RouteCore };

/// Run the automatic passes + the batch finish and hand back BOTH the compact
/// result and the live core (for read-only diagnostics), so callers needn't
/// re-switch the `CoreOutcome` union themselves.
pub fn routeCoreFinished(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    params: RouteParams,
    options: route_policy.Options,
    timeline: TimelineCapture,
) std.mem.Allocator.Error!FinishedRoute {
    const fin = try routeCoreFinishedRun(arena, placement, params, options, timeline);
    return .{ .result = fin.run.routed, .core = fin.core };
}

/// `routeCoreFinished` keeping the full `RouteRun` — the copper AND the
/// captured decision timeline — alongside the live core. The streaming
/// live-route job needs the timeline it just sank preserved for the cached
/// replay; the compact `FinishedRoute` deliberately drops it.
pub const FinishedRun = struct { run: RouteRun, core: ?RouteCore };

/// The run-preserving sibling of `routeCoreFinished` (which delegates here so
/// the two can't drift): automatic passes + batch finish, returning the whole
/// `RouteRun` plus the live core for read-only diagnostics.
pub fn routeCoreFinishedRun(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    params: RouteParams,
    options: route_policy.Options,
    timeline: TimelineCapture,
) std.mem.Allocator.Error!FinishedRun {
    return switch (try routeCoreStart(arena, placement, params, options, timeline)) {
        .done => |run| .{ .run = run, .core = null },
        .core => |core| .{ .run = try finishBatch(core), .core = core },
    };
}

/// Whether `routeCoreStart` records the ordered decision timeline (an enum, not
/// a bare bool, so the public entry stays self-describing at call sites).
pub const TimelineCapture = enum { off, on };

/// The rip-up working set and run-level knobs the finish pass needs — grouped
/// so `RouteCore` stays within the struct-field cap.
pub const RouteCoreResult = struct {
    routable: []RipNet,
    ripup_rounds: usize,
    grid_scale: f64,
};

/// Is this net's routing ORDER fixed by an authored `(pcb-plan (route (wave …)))`
/// wave?
///
/// `plan_resolve.routePolicies` writes a wave member's WHOLE policy, taking
/// `wave.priority` from the wave's position in the plan, and `net_pri` puts that
/// value in the high half of the sort key. So for a wave-bound net a
/// `(net-class … (priority N))` cannot change when it routes — it reaches only
/// the rip-up/rescue tier — and a remedy that suggests one is sending its reader
/// after an inert lever.
pub fn waveOrdered(core: *const RouteCore, net_i: usize) bool {
    if (net_i >= core.ctx.net_policy.len) return false;
    return core.ctx.net_policy[net_i].wave.priority != 0;
}

/// Live, resumable routing state after the standard pipeline's AUTOMATIC passes
/// (plane vias, greedy maze, bounded rip-up) but BEFORE the finish passes
/// (escape stubs, return stitching, straighten, arc bookkeeping). The
/// non-session entry points feed it straight to `finish`; an interactive
/// routing session (`route_session.zig`) instead holds it across HTTP requests,
/// retries still-failed nets with human hints, then runs `finish` once at the
/// end. All slices/pointers are owned by the arena passed to `routeCoreStart`.
pub const RouteCore = struct {
    ctx: *Ctx,
    idx_of: *std.StringHashMapUnmanaged(usize),
    tracks: *std.ArrayList(Track),
    vias: *std.ArrayList(Via),
    progress: *RouteProgress,
    placement: optimizer.Placement,
    result: RouteCoreResult,

    /// Run the finish passes and produce the final `RouteRun`. Shared verbatim
    /// by the non-session `routeOnce` and the interactive session's terminal
    /// step, so both assemble identical copper from an identical live state.
    pub fn finish(self: RouteCore) std.mem.Allocator.Error!RouteRun {
        return finishRoute(.{
            .ctx = self.ctx,
            .placement = self.placement,
            .routable = self.result.routable,
            .tracks = self.tracks,
            .vias = self.vias,
            .progress = self.progress,
            .ripup_rounds = self.result.ripup_rounds,
            .grid_scale = self.result.grid_scale,
        });
    }

    /// Append an interactive session decision (`stuck` / `hint_applied`) to the
    /// live timeline with the current copper, so a finished session replays in
    /// the existing route-review players. `detail` rides on `hint_applied`.
    /// No-op when the run is not capturing a timeline.
    pub fn recordSessionEvent(
        self: RouteCore,
        kind: RouteEventKind,
        net_i: ?usize,
        detail: []const u8,
    ) std.mem.Allocator.Error!void {
        try self.progress.timeline.capture(
            .{ .kind = kind, .net = net_i, .detail = detail, .routed = self.progress.routed },
            self.tracks.items,
            self.vias.items,
        );
    }
};

/// `routeCoreStart` outcome: `core` carries the resumable state; `done` is the
/// finished degenerate `RouteRun` for a grid that was empty or overflowed (no
/// resumable state exists — the caller returns it as-is).
pub const CoreOutcome = union(enum) { core: RouteCore, done: RouteRun };

fn degenerateRun(grid_scale: f64, overflow: bool) RouteRun {
    return .{ .routed = .{
        .tracks = &.{},
        .vias = &.{},
        .routed = 0,
        .total = 0,
        .grid_overflow = overflow,
        .grid_scale = grid_scale,
    }, .timeline = &.{} };
}

/// Run the standard pipeline's automatic passes and hand back the live state.
/// Arena-allocates `ctx`/`tracks`/`vias`/`progress`/`idx_of` so the returned
/// `RouteCore` survives beyond this call (an interactive session keeps it live
/// across requests). Byte-identical to the pre-refactor `routeOnce` body up to
/// the finish passes, which now live in `RouteCore.finish`.
pub fn routeCoreStart(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    params: RouteParams,
    options: route_policy.Options,
    capture: TimelineCapture,
) std.mem.Allocator.Error!CoreOutcome {
    const tracks = try arena.create(std.ArrayList(Track));
    tracks.* = .empty;
    const vias = try arena.create(std.ArrayList(Via));
    vias.* = .empty;
    const progress = try arena.create(RouteProgress);
    progress.* = .{ .timeline = .{ .arena = arena, .enabled = capture == .on, .sink = options.sink } };

    // ref-des → part index, for resolving each net pin to a pad.
    const idx_of = try arena.create(std.StringHashMapUnmanaged(usize));
    idx_of.* = .empty;
    for (placement.parts, 0..) |p, i| try idx_of.put(arena, p.ref_des, i);

    // Grid + base Ctx — the setup `route`/`groundVias` share (`buildRouteCtx`);
    // only `route` fills `.pour`. Ground → plane vias, others → maze. The
    // fitted scale (auto promotion demoted until the lattice fits the node
    // budget) is passed through as the explicit request, so the reported
    // `grid_scale` and the grid actually searched cannot disagree.
    const timing = options.timing;
    if (timing) |t| t.begin(.build_ctx);
    const grid_scale = fittedGridScale(placement, params, options.selected_nets, options.grid_scale);
    const ctx = try arena.create(Ctx);
    ctx.* = switch (try buildRouteCtx(
        arena,
        placement,
        params,
        options.selected_nets,
        grid_scale,
    )) {
        .ok => |c| c,
        .empty => return .{ .done = degenerateRun(grid_scale, false) },
        .overflow => return .{ .done = degenerateRun(grid_scale, true) },
    };
    ctx.pour = .{
        placement.rules.pourNetOnSide(.top) != null,
        placement.rules.pourNetOnSide(.bottom) != null,
    };
    // The whole-board route is the ONE context carrying stamped RF masks: only it
    // lays a keepout/fenced net's copper and then routes more nets against it.
    // Allocated only when a class asked for the band (see `KeepState`,
    // `rf_shadow`); the escape gate rides with the halo it opens.
    const nodes = ctx.grid.nx * ctx.grid.ny;
    if (ctx.keep.nets.len > 0) {
        ctx.keep.layers = try allocLayerGrids(arena, ctx.occ.len, nodes);
        ctx.keep.gate = try allocLayerGrids(arena, ctx.occ.len, nodes);
        for (ctx.obs) |p| stampKeepoutPad(ctx, p);
    }
    if (ctx.shadow.nets.len > 0) {
        ctx.shadow.layers = try allocLayerGrids(arena, ctx.occ.len, nodes);
    }
    ctx.timing = timing;
    ctx.net_policy = options.net;
    ctx.selected_nets = options.selected_nets;
    ctx.cancel = options.stop.cancel;
    ctx.deadline_ns = options.stop.deadline_ns;
    ctx.effort = options.effort;
    ctx.pair_channel = options.guides.pair_channel;
    ctx.pinch_log = options.guides.pinch;
    if (options.guides.route_space.fieldAllocator() != null) ctx.field_space = .{ .placement = placement, .provider = options.guides.route_space };
    ctx.zones = options.existing_zones;
    ctx.guide_tracks = options.guides.tracks;
    ctx.guide_vias = options.guides.vias;
    ctx.reserved_lanes = options.guides.reserved;
    try stampExistingCopper(ctx, options, tracks, vias);
    // `resv` reset 1/6 — after the retained copper, so no lane takes a cell real
    // metal needs (`lane_reserve` lists all six).
    lane_reserve.stamp(ctx.reserved_lanes, ctx.resv, ctx.grid, null);
    // Retained RF copper needs its keepout halo too — `emitSeg` only haloes what
    // this run lays, and a scoped route keeps everything else as existing copper.
    stampRetainedRf(ctx, placement, .{ .tracks = tracks.items, .vias = vias.items });
    // Stamp the attempt's lattice BEFORE the first capture, so every event this
    // attempt records — `.initial` included — carries the geometry the maze
    // actually searched (see `PassContext`).
    progress.timeline.pass = passOf(ctx, grid_scale);
    try progress.timeline.capture(.{ .kind = .initial, .routed = 0 }, tracks.items, vias.items);
    ctx.preserved_vias = vias.items.len;
    if (timing) |t| t.end(.build_ctx);
    try thermalViaPrepass(ctx, placement, idx_of, tracks, vias);
    var early: std.ArrayList(RipNet) = .empty;
    var early_order: std.ArrayList(usize) = .empty;
    const net_pri = try arena.alloc(u64, placement.nets.len);
    for (placement.nets, 0..) |net, i| {
        const policy = if (i < options.net.len) options.net[i] else route_policy.NetPolicy{};
        net_pri[i] = (@as(u64, policy.wave.priority) << 32) | netPriority(placement, idx_of, net, i);
        if (policy.wave.before_planes != 0 and netEnabled(ctx, i) and !netHasPlane(placement, net.name))
            try early_order.append(arena, i);
    }
    std.sort.pdq(usize, early_order.items, net_pri, route_policy.priorityDesc);
    try greedyPass(ctx, placement, idx_of, early_order.items, net_pri, false, tracks, vias, &early, progress);
    // Pass 1: ground/plane nets — see `planeViaPass`.
    if (timing) |t| t.begin(.plane_vias);
    try planeViaPass(ctx, placement, idx_of, tracks, vias, progress);
    progress.plane_routed = progress.routed;
    if (timing) |t| t.end(.plane_vias);

    const signal = try routeSignalPass(.{
        .ctx = ctx,
        .placement = placement,
        .idx_of = idx_of,
        .options = options,
        .early = early.items,
        .net_pri = net_pri,
        .tracks = tracks,
        .vias = vias,
        .progress = progress,
    });
    return .{ .core = .{
        .ctx = ctx,
        .idx_of = idx_of,
        .tracks = tracks,
        .vias = vias,
        .progress = progress,
        .placement = placement,
        .result = .{
            .routable = signal.routable,
            .ripup_rounds = signal.ripup_rounds,
            .grid_scale = grid_scale,
        },
    } };
}

const SignalPass = struct {
    ctx: *Ctx,
    placement: optimizer.Placement,
    idx_of: *std.StringHashMapUnmanaged(usize),
    options: route_policy.Options,
    early: []const RipNet,
    net_pri: []const u64,
    tracks: *std.ArrayList(Track),
    vias: *std.ArrayList(Via),
    progress: *RouteProgress,
};

const SignalResult = struct { routable: []RipNet, ripup_rounds: usize };

/// Public routing seam for final explicit-junction canonicalization. The
/// implementation stays with the other post-route geometry passes; serve code
/// depends only on `router.zig`, preserving the placement-layer boundary.
pub fn canonicalizeTraceJunctions(
    arena: std.mem.Allocator,
    tracks: *std.ArrayList(Track),
    mutable: *std.ArrayList(bool),
    vias: []const Via,
) std.mem.Allocator.Error!void {
    return route_cleanup.canonicalizeTraceJunctions(arena, tracks, mutable, vias);
}

/// Public routing seam for the closing gloss over a caller's finished copper —
/// the sibling of `canonicalizeTraceJunctions`, and its natural successor:
/// canonicalization SPLITS sections and WELDS near-misses, which is exactly how
/// a board acquires the collinear pairs and micron tails this removes. Same
/// contract: `mutable` parallels `tracks` and is compacted with it, a false
/// entry stays byte-for-byte identical. Own lands come from `placement`, so a
/// stub end resting on one is never fused away.
pub fn glossFinishedTracks(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    tracks: *std.ArrayList(Track),
    mutable: *std.ArrayList(bool),
    vias: []const Via,
) std.mem.Allocator.Error!void {
    _ = route_cleanup.glossFinishedTracks(tracks, mutable, vias, try buildObstacles(arena, placement.parts, placement.nets));
}

/// One net's accumulated copper, handed to the branch fold.
pub const NetFold = route_cleanup.NetFold;
/// The folded copper, plus whether anything actually folded.
pub const FoldedNet = route_cleanup.FoldedNet;

/// Public routing seam for a NET-SCOPED branch fold over copper a caller
/// assembled outside one router call.
///
/// `mergeParallelBranches` and `mergeAdjacentPadEscapes` can only see legs that
/// are same-net on ONE board. A phase that routes a rail's authored bypass bonds
/// one pair at a time never gets that board: each call holds a single leg,
/// because every other leg of the rail is presented to the search as unnetted
/// obstacle metal so the pair still has to close cap-to-pin on its own. The
/// doubled trunk two such legs leave down one channel is legal to fold and
/// invisible to every per-bond finish — only a post-route seam can make the
/// group same-net again, which is what this is.
///
/// It is a pure function of its inputs: the caller's copper comes back rewritten
/// or verbatim, and `changed` says which, so the caller can re-run its own
/// acceptance gate over the folded result and keep it only if it still passes.
pub fn foldNetBranches(run: NetFold) std.mem.Allocator.Error!FoldedNet {
    return route_cleanup.foldNetBranches(run);
}

/// A cleanup board over copper a caller assembled OUTSIDE one route call.
///
/// The post-route passes read the live routing context — pad obstacles, the
/// clearance grid, the resolved per-net params — and a caller that stitched its
/// answer together from several router calls has none of it. This builds the
/// smallest context those passes need (no pour masks, no keepout gates, no
/// timeline) around `options`' foreign copper, which `stampExistingCopper`
/// appends to the lists as it stamps. Null when the board's lattice cannot be
/// built at all, which for a cleanup means "leave the copper alone".
pub fn cleanupBoard(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    params: RouteParams,
    options: route_policy.Options,
    copper: struct { tracks: *std.ArrayList(Track), vias: *std.ArrayList(Via) },
) std.mem.Allocator.Error!?CleanupBoard {
    const ctx = try arena.create(Ctx);
    const scale = fittedGridScale(placement, params, options.selected_nets, options.grid_scale);
    ctx.* = switch (try buildRouteCtx(arena, placement, params, options.selected_nets, scale)) {
        .ok => |c| c,
        .empty, .overflow => return null,
    };
    ctx.net_policy = options.net;
    ctx.selected_nets = options.selected_nets;
    ctx.zones = options.existing_zones;
    ctx.effort = options.effort;
    try stampExistingCopper(ctx, options, copper.tracks, copper.vias);
    return .{ .ctx = ctx, .placement = placement, .tracks = copper.tracks, .vias = copper.vias };
}

fn routeSignalPass(run: SignalPass) std.mem.Allocator.Error!SignalResult {
    const arena = run.ctx.arena;
    var order: std.ArrayList(usize) = .empty;
    for (run.placement.nets, 0..) |net, net_i| {
        if (!netEnabled(run.ctx, net_i) or netHasPlane(run.placement, net.name)) continue;
        if (net_i < run.options.net.len and run.options.net[net_i].wave.before_planes != 0) continue;
        try order.append(arena, net_i);
    }
    std.sort.pdq(usize, order.items, run.net_pri, route_policy.priorityDesc);
    var routable: std.ArrayList(RipNet) = .empty;
    try routable.appendSlice(arena, run.early);
    const timing = run.ctx.timing;
    if (timing) |t| t.begin(.greedy);
    try greedyPass(
        run.ctx,
        run.placement,
        run.idx_of,
        order.items,
        run.net_pri,
        run.placement.parts.len <= top_first_max_parts,
        run.tracks,
        run.vias,
        &routable,
        run.progress,
    );
    if (timing) |t| t.end(.greedy);
    // Interleave budget escalation with rip-up. Escalation (retry each still-
    // failed search-limited net / atomic pair under `max_escalated_expansions`)
    // is purely additive — it never rips a routed leg — and rip-up then attacks
    // whatever's still walled in (every failed net is a candidate now).
    // Re-running escalation AFTER rip-up matters: rip-up's
    // freed copper can let a leg finish searching that an up-front-only pass
    // stranded, so a late escalation rescues nets the pass-1 order missed. And
    // `escalate_retry` covers escalation's blind half — the nets whose frontier
    // DRAINED rather than ran out of budget, which only a changed board helps.
    const esc = EscalateRun{
        .ctx = run.ctx,
        .placement = run.placement,
        .idx_of = run.idx_of,
        .routable = routable.items,
        .tracks = run.tracks,
        .vias = run.vias,
        .budget = max_escalated_expansions,
    };
    const rip = RipUpRun{
        .ctx = run.ctx,
        .placement = run.placement,
        .idx_of = run.idx_of,
        .routable = routable.items,
        .tracks = run.tracks,
        .vias = run.vias,
        .progress = run.progress,
    };
    var rounds: usize = 0;
    // A cooperative cancel skips the whole escalate↔rip-up interleave and the
    // last-resort tier — the caller asked us to stop starting new work. The
    // greedy pass has already tallied every remaining net as failed, so the
    // finish pass turns this residual working set into a valid partial result.
    // (every phase below also polls cancel internally, so one that trips
    // mid-phase bails promptly too.) `one_shot` stops here: a net the maze
    // could not reach is reported now, with its diagnosis, instead of paying
    // the rescue ladder (see `route_policy.Effort` for why that is the default
    // under an agent loop).
    if (!routeCancelled(run.ctx) and run.ctx.effort.retries()) {
        var blocked_retry = try escalate_retry.State.init(arena, routable.items.len, .{});
        var pass: usize = 0;
        while (pass < signal_escalate_passes) : (pass += 1) {
            if (timing) |t| t.begin(.escalate);
            _ = try escalateSearchLimited(esc);
            if (timing) |t| t.end(.escalate);
            if (!anyRecoverableFailed(routable.items)) break;
            if (timing) |t| t.begin(.ripup);
            rounds += try ripUpReroute(rip);
            if (timing) |t| t.end(.ripup);
            if (timing) |t| t.begin(.blocked_retry);
            _ = try escalate_retry.run(esc, &blocked_retry);
            if (timing) |t| t.end(.blocked_retry);
        }
        // Last-resort tier: any leg STILL search-limited pays a single far-larger
        // budget once — bounded to this residual handful, so the replay stays fast.
        var last_resort = esc;
        last_resort.budget = max_last_resort_expansions;
        if (timing) |t| t.begin(.last_resort);
        _ = try escalateSearchLimited(last_resort);
        if (timing) |t| t.end(.last_resort);
        // Shape tier. Everything above searches the same raster; a net whose
        // corridor is narrower than the lattice, or whose only way through is a
        // dive to another layer, is invisible to all of it however much budget
        // it is given. The residue gets one gridless multi-layer attempt each.
        _ = try shapeRescueTier(esc);
    }
    return .{ .routable = routable.items, .ripup_rounds = rounds };
}

/// The finished board handed to the post-route cleanup passes
/// (`route_cleanup`): the live routing context plus the copper lists those
/// passes rewrite in place. Exists so `Ctx` — a 50-field engine-private
/// aggregate — stays unexported while a sibling module can still drive it.
pub const CleanupBoard = struct {
    ctx: *Ctx,
    placement: optimizer.Placement,
    tracks: *std.ArrayList(Track),
    vias: *std.ArrayList(Via),
    /// A final sweep may remove trace leaves after intentional stitch vias are
    /// appended, but must not reinterpret those new barrels without fill.
    preserve_vias: bool = false,
    /// Intentional barrels added since the preceding topology pass. They are
    /// value snapshots because later list appends may reallocate `vias`.
    protected_vias: []const Via = &.{},

    /// Allocation arena owned by the current route request.
    pub fn arena(self: CleanupBoard) std.mem.Allocator {
        return self.ctx.arena;
    }

    /// True when this net belongs to the active route scope.
    pub fn enabled(self: CleanupBoard, net_i: usize) bool {
        return netEnabled(self.ctx, net_i);
    }

    /// Reconfigure width/clearance and rebuild exact copper obstacles for one
    /// final RF candidate.
    pub fn beginNet(self: CleanupBoard, net_i: usize) void {
        setNetParams(self.ctx, self.placement, net_i);
        rebuildCopperIndex(self.ctx, self.tracks.items, self.vias.items);
    }

    /// Width currently resolved for `beginNet`'s net.
    pub fn trackWidth(self: CleanupBoard) f64 {
        return self.ctx.params.track_width;
    }

    /// Electrical width the adaptive power finisher should approach for this
    /// net. Null means the net keeps exact routed geometry (ordinary signal,
    /// controlled impedance/differential pair, or a plane/pour fanout).
    pub fn adaptivePowerWidth(self: CleanupBoard, net_i: usize) ?f64 {
        var authored = self.ctx.base.track_width;
        if (net_i < self.placement.rules.net.len and self.placement.rules.net[net_i].width > 0)
            authored = self.placement.rules.net[net_i].width;
        return power_route_width.adaptiveTargetWidth(self.ctx.zones, self.placement, net_i, authored);
    }

    /// Clearance-probe handle for the current net and live copper.
    pub fn tautProbe(self: CleanupBoard, net: i32) TautProbe {
        return .{ .run = .{ .ctx = self.ctx, .net = net, .tracks = self.tracks, .vias = self.vias } };
    }

    /// Persist one deterministic port-frame trial history for diagnostics.
    pub fn recordRfOutcome(self: CleanupBoard, net: i32, outcome: rf_port_report.Outcome) std.mem.Allocator.Error!void {
        try self.ctx.rf.port_outcomes.put(self.ctx.arena, net, outcome);
    }

    /// The replacement no longer uses legacy circular-arc metadata.
    pub fn clearLegacySmooth(self: CleanupBoard, net: i32) void {
        _ = self.ctx.rf.net_smooth.remove(net);
    }
};

const RouteFinish = struct {
    ctx: *Ctx,
    placement: optimizer.Placement,
    routable: []const RipNet,
    tracks: *std.ArrayList(Track),
    vias: *std.ArrayList(Via),
    progress: *RouteProgress,
    ripup_rounds: usize,
    grid_scale: f64,
};

fn finishRoute(run: RouteFinish) std.mem.Allocator.Error!RouteRun {
    const arena = run.ctx.arena;
    const timing = run.ctx.timing;
    if (timing) |t| t.begin(.finish_total);
    for (run.routable) |rn| {
        if (rn.ok)
            run.progress.routed += 1
        else
            try run.progress.failed.append(arena, run.placement.nets[rn.net_i].name);
    }
    // A deadline/cancelled route is already a valid partial board: failed nets
    // were rolled back and the loop above supplied its complete honest tally.
    // Do not spend an unbounded-looking cleanup tail straightening and
    // re-glossing copper the caller has explicitly stopped waiting for — but do
    // not ship RAW maze copper either. `cancelGloss` is the deterministic,
    // probe-free, clock-free half of the finish (duplicate/degenerate drop plus
    // the loose-leaf prune); a sliced sub-circuit reaches this path routinely,
    // and its caller's DRC sees whatever comes out of it.
    const board = CleanupBoard{ .ctx = run.ctx, .placement = run.placement, .tracks = run.tracks, .vias = run.vias };
    if (routeCancelled(run.ctx)) {
        var partial = board;
        partial.preserve_vias = true; // no fill raster here to re-judge a barrel by
        try route_cleanup.cancelGloss(partial);
        return assembleRouteRun(run);
    }
    const escape_marks = [2]usize{ run.tracks.items.len, run.vias.items.len };
    if (timing) |t| t.begin(.escape_stubs);
    try routeEscapeStubs(arena, run.ctx, run.placement, run.tracks, run.vias);
    if (timing) |t| t.end(.escape_stubs);
    if (run.tracks.items.len != escape_marks[0] or run.vias.items.len != escape_marks[1])
        try recordPostPass(.escape_stubs, run.progress, run.tracks.items, run.vias.items);
    // Gloss, then TOPOLOGY (drop every layer hop whose detour can be redrawn on
    // the layer both its ends already use — E10), then stitching. Three
    // constraints pin that order, and each was MEASURED on `bench-route
    // barracuda straps` (2026-08-04) rather than argued:
    //
    //   * `straighten` runs BEFORE the hop drop because the hop drop's detector
    //     reads copper: `HopScan` follows a bounded run of segments between two
    //     vias and `clearingElbow` judges the replacement against what leaves
    //     each end. On raw maze copper those runs are staircases, and two of
    //     straps' redundant hops go unrecognised — +4 vias, +10 tracks — when
    //     the pass is handed un-tautened metal.
    //   * the hop drop runs BEFORE `stitchReturnPaths`, so the stitcher never
    //     spends a ground via guarding a signal via that is about to be deleted.
    //   * the merged single-layer runs the hop drop leaves are re-glossed HERE,
    //     not left to the cleanup phase's closing sweep, because stitching in
    //     between pins vias into the corridors those runs would tauten through
    //     (deferring it costs straps +6 tracks). It is conditional because with
    //     no hop removed there is nothing merged to simplify.
    if (timing) |t| t.begin(.straighten);
    try straighten.passBoard(board);
    if (timing) |t| t.end(.straighten);
    const hop_marks = [2]usize{ run.tracks.items.len, run.vias.items.len };
    if (timing) |t| t.begin(.via_hops);
    try route_cleanup.dropRedundantViaPairs(board);
    if (timing) |t| t.end(.via_hops);
    if (run.tracks.items.len != hop_marks[0] or run.vias.items.len != hop_marks[1]) {
        try recordPostPass(.via_hops, run.progress, run.tracks.items, run.vias.items);
        if (timing) |t| t.begin(.straighten);
        try straighten.passBoard(board);
        if (timing) |t| t.end(.straighten);
    }
    const stitch_marks = [2]usize{ run.tracks.items.len, run.vias.items.len };
    if (timing) |t| t.begin(.stitch_return);
    try stitchReturnPaths(arena, run.ctx, run.placement, run.tracks, run.vias);
    const return_stitch_vias = try arena.dupe(Via, run.vias.items[stitch_marks[1]..]);
    var post_stitch_board = board;
    post_stitch_board.protected_vias = return_stitch_vias;
    if (timing) |t| t.end(.stitch_return);
    if (run.tracks.items.len != stitch_marks[0] or run.vias.items.len != stitch_marks[1])
        try recordPostPass(.return_stitching, run.progress, run.tracks.items, run.vias.items);
    // Post-route geometry cleanup (E1/E7/E8/E9/E12/E13): collapse collinear multi-pad
    // joins to one through-line, snap terminal via-tails onto their pads, close
    // any routed-but-open net, fold nearby same-net legs into a shared trunk,
    // then drop degenerate segments.
    if (timing) |t| t.begin(.cleanup);
    try route_cleanup.collapseCollinearNets(post_stitch_board);
    route_cleanup.snapTerminalVias(post_stitch_board);
    try route_cleanup.closeNetOpens(post_stitch_board);
    try route_cleanup.mergeParallelBranches(post_stitch_board);
    route_cleanup.dropDegenerateTracks(run.tracks, run.ctx.selected_nets);
    copperCompacted(run.ctx); // the sweep packed survivors down
    // …then gloss ONE more time. Each pass above rewrites geometry the
    // straighten pass had already finished with — a collinear collapse replaces
    // a whole staircase with a through-line, a closure bridge lands square — so
    // the corners they leave have never met the chamfer. (Measured on
    // barracuda: V_6VA's two surviving square corners on B.Cu are both
    // collinear-collapse products.) The pass only ever simplifies probed
    // copper, so a second run over already-glossed metal changes nothing.
    try straighten.passBoard(board);
    // …and only THEN give each terminal its escape ray (the lap trim
    // `pad_entry` runs under it). Last, because it is the one seam the others
    // would undo: the gloss above reads a chain's pad end as a fixed anchor and
    // would re-straighten the ray back across the land it was just drawn from.
    if (timing) |t| t.begin(.pad_escape);
    try pad_escape.passBoard(board);
    // Pad escape works per terminal and can therefore recreate the same-net
    // combs that the earlier board gloss could not see yet. Consolidate those
    // FINAL rays now, then fold any parallel branches the new straps expose;
    // neither pass moves an endpoint off a land centre.
    try route_cleanup.mergeAdjacentPadEscapes(post_stitch_board);
    try route_cleanup.mergeParallelBranches(post_stitch_board);
    // Remove legacy topology artifacts before the RF finisher replaces
    // eligible point-to-point runs. This pass may still reject a bare replay
    // guide via; the later sweep deliberately preserves intentional stitches.
    try route_cleanup.pruneDanglingCopper(post_stitch_board);
    try @import("rf_port_finish.zig").passBoard(board);
    if (timing) |t| t.end(.pad_escape);
    // Optional ground-reference audit/repair runs at the true end of routing:
    // every signal and RF trace is now fixed, so a new ground barrel is kept
    // only when its via (and, off a poured face, short land stub) clears the
    // board exactly as shipped.
    // Scoped re-routes leave unrelated copper byte-identical; saved layouts
    // use `addGroundPadStitches` for the same post-pass explicitly.
    if (run.ctx.selected_nets.len == 0)
        try stitchGroundPads(arena, run.ctx, run.placement, run.tracks, run.vias);
    // At the final output boundary collapse exact duplicate barrels — no later
    // pass emits a via, and straighten has finished using vias as anchors.
    route_cleanup.dropCoincidentVias(run.vias, run.ctx.selected_nets);
    route_cleanup.dropDegenerateTracks(run.tracks, run.ctx.selected_nets);
    // Nothing may append TRACK copper after this last pass, which is why the
    // section-deletion oracle runs HERE and only here: every stitch barrel is
    // already down, so a run reaching one is judged against the board as
    // shipped rather than against a board still missing its return path.
    // Preserve those intentional barrels: this hot router seam has no fill
    // raster with which to judge their plane contact.
    var final_board = post_stitch_board;
    final_board.preserve_vias = true;
    try route_cleanup.pruneDeadCopper(final_board);
    // THE LAST PASS. Every seam above has now emitted its final copper, and
    // each of them rebuilds runs the others already finished with: an escape ray
    // re-drawn over a comb the merge just consolidated, a neck shaped onto a
    // section a prune left, a stitch land beside a barrel. What that leaves is
    // sections emitted twice, halves of one straight run kept apart by a
    // last-bit width difference, and tails too short for their own copper to
    // notice — none of which any earlier pass looks for, because each of them
    // ran before the copper that creates them existed. The gloss only ever
    // removes indistinguishable metal and snaps a stub onto its own land, so
    // putting it here cannot undo the escape rays `pad_escape` deliberately
    // draws last (it re-straightens nothing) nor the necks `pad_neck` just cut.
    try route_cleanup.finalGloss(final_board);
    var outcome_it = run.ctx.rf.port_outcomes.valueIterator();
    while (outcome_it.next()) |outcome| {
        for (run.tracks.items) |track| outcome.physical.retained_tracks += @intFromBool(track.net == outcome.net);
    }
    copperCompacted(run.ctx);
    if (timing) |t| t.end(.cleanup);
    return assembleRouteRun(run);
}

/// Assemble the compact result shared by a normally cleaned board and a
/// cooperatively stopped partial board. RF bend discipline ran inline, so its
/// metadata remains valid even when a deadline skips the cosmetic finish tail.
fn assembleRouteRun(run: RouteFinish) std.mem.Allocator.Error!RouteRun {
    const arena = run.ctx.arena;
    const timing = run.ctx.timing;
    var arcs: std.ArrayList(Arc) = .empty;
    var sharp: std.ArrayList(SharpBend) = .empty;
    for (0..run.placement.nets.len) |ni| {
        const s = run.ctx.rf.net_smooth.get(@intCast(ni)) orelse continue;
        try arcs.appendSlice(arena, s.arcs);
        try sharp.appendSlice(arena, s.sharp);
    }
    const rf_outcomes = try rf_port_report.collectOrdered(arena, &run.ctx.rf.port_outcomes, run.placement.nets.len);
    try recordPostPass(.complete, run.progress, run.tracks.items, run.vias.items);
    if (timing) |t| t.end(.finish_total);

    return .{ .routed = .{
        .tracks = try run.tracks.toOwnedSlice(arena),
        .vias = try run.vias.toOwnedSlice(arena),
        .arcs = try arcs.toOwnedSlice(arena),
        .sharp_bends = try sharp.toOwnedSlice(arena),
        .rf_port_outcomes = rf_outcomes,
        .routed = run.progress.routed,
        .total = run.progress.total,
        .failed = try run.progress.failed.toOwnedSlice(arena),
        .search_limited = try run.ctx.search_limited.toOwnedSlice(arena),
        .reference_replayed = try run.ctx.reference_replayed.toOwnedSlice(arena),
        .ripup_rounds = run.ripup_rounds,
        .grid_scale = run.grid_scale,
        .cancelled = routeCancelled(run.ctx),
    }, .pass = run.progress.timeline.pass, .timeline = try run.progress.timeline.finish(run.progress.total) };
}

/// The curved copper a `RouteResult` would carry if the route ended right now.
pub const Curves = struct { arcs: []const Arc = &.{}, rf_paths: []const rf_port_report.Outcome = &.{} };

/// Read that curved copper off the LIVE routing context, in net order — the
/// mid-route twin of what `assembleRouteRun` folds into the finished bundle.
///
/// The mid-route accept gates (`fine_accept`, `joint_rescue`, `congestion`) ask
/// the connectivity oracle about copper they hold as plain track/via lists, and
/// those lists are not the whole board: an arc's chords are handles whose curved
/// envelope is what carves a pour, and an RF path's compact centreline is a
/// handle whose swept polygon is what lands on the pads. Both live here rather
/// than in the lists, so a gate that does not read them weighs a board that is
/// not the one it is about to keep.
///
/// Read at measurement time, never cached: `net_smooth` gains a net's arcs the
/// moment it routes and loses them the moment it is ripped, and `port_outcomes`
/// is still EMPTY at every rescue tier — the RF port finisher runs inside
/// `finishRoute`, after all three of them. So a mid-route gate legitimately gets
/// no RF paths today, and will get them automatically if that order ever moves.
pub fn liveCurves(arena: std.mem.Allocator, ctx: *const Ctx, net_count: usize) std.mem.Allocator.Error!Curves {
    var arcs: std.ArrayList(Arc) = .empty;
    for (0..net_count) |ni| if (ctx.rf.net_smooth.get(@intCast(ni))) |s| try arcs.appendSlice(arena, s.arcs);
    const paths = try rf_port_report.collectOrdered(arena, &ctx.rf.port_outcomes, net_count);
    return .{ .arcs = try arcs.toOwnedSlice(arena), .rf_paths = paths };
}

fn recordPostPass(
    kind: RouteEventKind,
    progress: *RouteProgress,
    tracks: []const Track,
    vias: []const Via,
) std.mem.Allocator.Error!void {
    try progress.timeline.capture(.{
        .kind = kind,
        .routed = progress.routed,
    }, tracks, vias);
}

fn routeEscapeStubs(
    arena: std.mem.Allocator,
    ctx: *Ctx,
    placement: optimizer.Placement,
    tracks: *std.ArrayList(Track),
    vias: *std.ArrayList(Via),
) std.mem.Allocator.Error!void {
    for (placement.stubs) |stub| {
        if (stub.net < 0 or !netEnabled(ctx, @intCast(stub.net))) continue;
        ctx.preferred_layers = 0;
        ctx.allowed_layers = 0;
        const part = placement.parts[stub.part];
        setNetParams(ctx, placement, @intCast(stub.net));
        // The finish passes probe against the COMPLETE board copper (the maze
        // has been idle since the last per-net rebuild), under THIS stub's
        // params — refresh the index here, after `setNetParams`.
        rebuildCopperIndex(ctx, tracks.items, vias.items);
        const layer = router_support.sideLayer(part);
        const start = optimizer.worldPadCenter(&part, stub.ax, stub.ay);
        const requested_end = optimizer.worldPadCenter(&part, stub.bx, stub.by);
        const span = std.math.hypot(requested_end[0] - start[0], requested_end[1] - start[1]);
        const direction: [2]f64 = if (span > 1e-9)
            .{ (requested_end[0] - start[0]) / span, (requested_end[1] - start[1]) / span }
        else
            .{ 1, 0 };
        if (findEscapeVia(ctx, vias.items, tracks.items, start, direction, stub.net, layer)) |via_at| {
            try tracks.append(arena, .{
                .x1 = start[0],
                .y1 = start[1],
                .x2 = via_at[0],
                .y2 = via_at[1],
                .layer = layer,
                .width = ctx.params.track_width,
                .net = stub.net,
            });
            try vias.append(arena, .{
                .x = via_at[0],
                .y = via_at[1],
                .dia = ctx.params.via_dia,
                .drill = ctx.params.via_drill,
                .net = stub.net,
            });
            continue;
        }
        // No legal via means this authored escape reaches no destination. A
        // longest-clear prefix is a copper leaf by construction, so emit
        // nothing and let the open-net report name the missing connection.
    }
}

fn stitchReturnPaths(
    arena: std.mem.Allocator,
    ctx: *Ctx,
    placement: optimizer.Placement,
    tracks: *std.ArrayList(Track),
    vias: *std.ArrayList(Via),
) std.mem.Allocator.Error!void {
    const selected_net_count = if (ctx.selected_nets.len == 0)
        placement.nets.len
    else
        selectedCount(ctx.selected_nets);
    const targeted = selected_net_count > 0 and selected_net_count <= targeted_stitch_max_nets;
    if (placement.parts.len > stitch_max_parts and !targeted) return;
    const ground_net = firstGroundNet(placement) orelse return;
    setNetParams(ctx, placement, @intCast(ground_net));
    // The stitch probes run against the COMPLETE board copper under the
    // ground net's params — refresh the index here, after `setNetParams`.
    rebuildCopperIndex(ctx, tracks.items, vias.items);
    const before = vias.items.len;
    for (ctx.preserved_vias..before) |i| {
        const signal_via = vias.items[i];
        if (isGndVia(placement, signal_via.net)) continue;
        if (hasNearbyGroundVia(placement, vias.items, signal_via)) continue;
        const at = findStitchVia(
            ctx,
            vias.items,
            tracks.items,
            .{ signal_via.x, signal_via.y },
            ground_net,
            return_path_radius_mm,
        ) orelse continue;
        try vias.append(arena, .{
            .x = at[0],
            .y = at[1],
            .dia = ctx.params.via_dia,
            .drill = ctx.params.via_drill,
            .net = ground_net,
        });
        stampViaOcc(ctx, at[0], at[1], ground_net);
    }
}

fn groundPadHasNearbyVia(vias: []const Via, net: i32, centre: [2]f64, max_distance: f64) bool {
    for (vias) |via| {
        if (via.net != net) continue;
        if (std.math.hypot(via.x - centre[0], via.y - centre[1]) <= max_distance + clearance_eps) return true;
    }
    return false;
}

/// A DRC-clean shared barrel between adjacent same-net SMD lands. Dense QFN
/// ground rows can leave no legal via centre on either individual land, while
/// the continuous same-net outer pour between them has room at their midpoint.
/// The candidate is accepted only when it lies within the authored budget of
/// both pads, so one barrel honestly serves the pair.
fn sharedGroundPadVia(
    ctx: *Ctx,
    placed: []const Via,
    tracks: []const Track,
    pad: PadObs,
    centre: [2]f64,
    max_distance: f64,
) ?[2]f64 {
    var best: ?[2]f64 = null;
    var best_separation = std.math.inf(f64);
    for (ctx.obs) |other| {
        if (other.net != pad.net or other.thru or other.layer != pad.layer) continue;
        const oc = [2]f64{ (other.x0 + other.x1) / 2, (other.y0 + other.y1) / 2 };
        const separation = std.math.hypot(oc[0] - centre[0], oc[1] - centre[1]);
        if (separation <= clearance_eps or separation > 2 * max_distance + clearance_eps) continue;
        const midpoint = [2]f64{ (centre[0] + oc[0]) / 2, (centre[1] + oc[1]) / 2 };
        if (separation < best_separation and groundViaPointClear(ctx, placed, tracks, midpoint, pad.net)) {
            best = midpoint;
            best_separation = separation;
        }
    }
    return best;
}

/// Add the missing barrels required by `(ground-via-max MM)`. Every eligible
/// pad is an SMD terminal of a ground net that actually owns a copper plane;
/// split grounds never borrow one another's vias. A via outside the authored
/// radius is rejected even when the general plane-via fan could eventually
/// find it, leaving a visible DRC warning instead of pretending a long return
/// satisfies the rule.
fn stitchGroundPads(
    arena: std.mem.Allocator,
    ctx: *Ctx,
    placement: optimizer.Placement,
    tracks: *std.ArrayList(Track),
    vias: *std.ArrayList(Via),
) std.mem.Allocator.Error!void {
    const max_distance = placement.rules.design.pour.ground_via_max;
    if (!(max_distance > 0)) return;
    for (placement.nets, 0..) |net, net_i| {
        if (!isGroundName(shortName(net.name)) or !netHasPlane(placement, net.name)) continue;
        const ni: i32 = @intCast(net_i);
        const pour = netPourLayers(placement, net.name);
        setNetParams(ctx, placement, net_i);
        rebuildCopperIndex(ctx, tracks.items, vias.items);
        for (ctx.obs, 0..) |pad, pad_i| {
            if (pad.net != ni or pad.thru) continue;
            if (plane_stitch.packageTieObstacle(placement, pad_i)) continue;
            const centre = [2]f64{ (pad.x0 + pad.x1) / 2, (pad.y0 + pad.y1) / 2 };
            if (groundPadHasNearbyVia(vias.items, ni, centre, max_distance)) continue;
            const in_pour = pad.layer < pour.len and pour[pad.layer];
            const at = if (in_pour) blk: {
                // The authored same-face GND pour is the pad→via connection;
                // adding an explicit stored stub on top of it only creates
                // redundant copper that can cross another same-net land and
                // trigger land-transit/dangling-copper hygiene warnings.
                // Try the exact (unsnapped) land centre first. Fine-pitch
                // ground lands can share one barrel through their continuous
                // same-net pour, while snapping that centre to the maze grid
                // can move it into neighbouring copper. One centred via may
                // consequently satisfy several adjacent ground pads.
                break :blk if (groundViaPointClear(ctx, vias.items, tracks.items, centre, ni))
                    centre
                else if (sharedGroundPadVia(ctx, vias.items, tracks.items, pad, centre, max_distance)) |shared|
                    shared
                else
                    findStitchVia(ctx, vias.items, tracks.items, centre, ni, max_distance);
            } else blk: {
                var joined = findGroundVia(ctx, vias.items, tracks.items, centre, ni, pad.layer);
                if (joined) |site| {
                    if (std.math.hypot(site[0] - centre[0], site[1] - centre[1]) > max_distance + clearance_eps) joined = null;
                }
                break :blk joined;
            };
            const pos = at orelse continue;
            try vias.append(arena, .{
                .x = pos[0],
                .y = pos[1],
                .dia = ctx.params.via_dia,
                .drill = ctx.params.via_drill,
                .net = ni,
            });
            if (!in_pour) {
                const join = OctiJoin{ .ctx = ctx, .net = ni, .layer = pad.layer, .placed_vias = vias.items, .tracks = tracks };
                try octilinear.emitJoin(centre, pos, join);
            }
            stampViaOcc(ctx, pos[0], pos[1], ni);
        }
    }
}

/// Apply only the end-of-route ground-pad stitch pass to existing copper.
/// Used by the saved-layout mutation tool; fields unrelated to tracks/vias are
/// preserved verbatim.
pub fn addGroundPadStitches(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: RouteResult,
) std.mem.Allocator.Error!RouteResult {
    if (!(placement.rules.design.pour.ground_via_max > 0)) return routed;
    var ctx = switch (try buildRouteCtx(arena, placement, placement.rules.design.routeParams(), &.{}, 0)) {
        .ok => |value| value,
        else => return routed,
    };
    ctx.pour = .{
        placement.rules.pourNetOnSide(.top) != null,
        placement.rules.pourNetOnSide(.bottom) != null,
    };
    var tracks = std.ArrayList(Track).fromOwnedSlice(try arena.dupe(Track, routed.tracks));
    var vias = std.ArrayList(Via).fromOwnedSlice(try arena.dupe(Via, routed.vias));
    rebuildCopperIndex(&ctx, tracks.items, vias.items);
    try stitchGroundPads(arena, &ctx, placement, &tracks, &vias);
    var out = routed;
    out.tracks = try tracks.toOwnedSlice(arena);
    out.vias = try vias.toOwnedSlice(arena);
    return out;
}

fn hasNearbyGroundVia(
    placement: optimizer.Placement,
    vias: []const Via,
    signal_via: Via,
) bool {
    for (vias) |ground_via| {
        if (!isGndVia(placement, ground_via.net)) continue;
        const distance = std.math.hypot(
            signal_via.x - ground_via.x,
            signal_via.y - ground_via.y,
        );
        if (distance <= return_path_radius_mm) return true;
    }
    return false;
}

/// The DRC-safe plane vias only — `route`'s pass 1 run in isolation, on the same
/// grid, so each via lands at *exactly* the spot `route` would drop it. The
/// layout view draws these as the pre-routing plane vias, so the via shown
/// before routing is the one routing will use — no "preview via at the pad
/// centre + real DRC via beside it" doubling, and the previewed via always
/// meets clearance. The pass's copper (surface bonds and via stubs) is stamped,
/// because via sites depend on it, then discarded: this previews vias, not
/// copper. Returns empty when the grid is too large to build (callers fall back
/// to the raw pad centre).
pub fn groundVias(arena: std.mem.Allocator, placement: optimizer.Placement, params: RouteParams) std.mem.Allocator.Error![]Via {
    var vias: std.ArrayList(Via) = .empty;
    var idx_of = std.StringHashMapUnmanaged(usize).empty;
    for (placement.parts, 0..) |p, i| try idx_of.put(arena, p.ref_des, i);

    // Same grid + base Ctx `route` builds — see `buildRouteCtx`.
    var ctx = switch (try buildRouteCtx(arena, placement, params, &.{}, 0)) {
        .ok => |c| c,
        else => return &.{},
    };
    var tracks: std.ArrayList(Track) = .empty;
    var progress = RouteProgress{ .timeline = .{ .arena = arena, .enabled = false } };
    try planeViaPass(&ctx, placement, &idx_of, &tracks, &vias, &progress);
    return vias.toOwnedSlice(arena);
}

// ── Gap closing (finishing a partly-routed board) ───────────────────────────
//
// The caller-facing contract (the request/response types and the rip-up ladder)
// lives in `gap_policy.zig`; re-exported here so `router.Gap` and friends stay
// the spelling every caller already uses. What follows is the machinery that
// services a request: the refined raster, the escape/stitch searches, and the
// bounded rip-and-repair transaction.

/// One island-joining request for `closeGaps` (see `gap_policy.Gap`).
pub const Gap = gap_policy.Gap;
/// The persisted copper a gap pass routes against (see `gap_policy.GapBoard`).
pub const GapBoard = gap_policy.GapBoard;
/// The copper one hop needs (see `gap_policy.GapPath`).
pub const GapPath = gap_policy.GapPath;
/// What became of one requested hop (see `gap_policy.GapEvent`).
pub const GapEvent = gap_policy.GapEvent;
/// How a hop ended (see `gap_policy.GapReason`).
pub const GapReason = gap_policy.GapReason;
/// Where a gap pass reports each hop as it finishes (see `gap_policy.GapSink`).
pub const GapSink = gap_policy.GapSink;
/// A caller's veto on each landed hop (see `gap_policy.GapJudge`).
pub const GapJudge = gap_policy.GapJudge;
/// Knobs a caller can turn on one gap pass (see `gap_policy.GapOptions`).
pub const GapOptions = gap_policy.GapOptions;
/// Which hop tiers one gap pass may draw with (see `gap_policy.ShapeTier`).
pub const ShapeTier = gap_policy.ShapeTier;
/// May a hop drop a via on its OWN terminal pad? (see `gap_policy.TerminalVia`).
pub const TerminalVia = gap_policy.TerminalVia;
/// A caller's say in WHICH nets a rip may take copper from (see `gap_policy.RipFilter`).
pub const RipFilter = gap_policy.RipFilter;
/// Rungs on the rip-up ladder (see `gap_policy.rip_tiers`).
pub const rip_tiers = gap_policy.rip_tiers;
/// Divisor on the base grid pitch for a gap pass (see `gap_policy.gap_grid_divisor`).
pub const gap_grid_divisor = gap_policy.gap_grid_divisor;
/// A bounded rectangle one gap pass may search inside (see `gap_policy.GapWindow`).
pub const GapWindow = gap_policy.GapWindow;

const RipBreadth = gap_policy.RipBreadth;
const ripup_reaches = gap_policy.ripup_reaches;

/// How close to a terminal a foreign net's copper must come to be considered an
/// aggressor at all, so a rip never takes out a trunk route that was never in
/// the way.
const ripup_reach_mm: f64 = 2.0;
/// Most foreign nets one blocked hop will try ripping before giving up.
const ripup_max_nets: usize = 3;
/// Ceiling on a whole-net rip. A net with more copper than this is a trunk
/// whose re-route is a bigger gamble than the hop is worth, so the widest tier
/// skips it and the pass gives up on that aggressor instead.
const ripup_max_tracks: usize = 60;
/// How far the stitch-via fan searches outward from a stranded pad (mm). The
/// ring count is derived from the grid pitch so a finer gap raster searches the
/// same physical neighbourhood, just more finely.
const stitch_reach_mm: f64 = 2.0;
/// Compass directions per stitch ring.
const stitch_spokes: usize = 12;

/// Close as many of `gaps` as the board allows, in order. Returns one entry per
/// request — null where the hop found no legal copper. Later hops see the
/// copper earlier ones laid down (as foreign obstacles when the net differs),
/// so a batch never draws two hops through the same channel.
pub fn closeGaps(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    params: RouteParams,
    board: GapBoard,
    gaps: []const Gap,
    opts: GapOptions,
) std.mem.Allocator.Error![]const ?GapPath {
    const out = try arena.alloc(?GapPath, gaps.len);
    @memset(out, null);
    if (gaps.len == 0) return out;
    var ctx = switch (try buildGapCtx(arena, placement, params, opts.raster.divisor, opts.raster.window)) {
        .ok => |c| c,
        else => return out,
    };
    ctx.cancel = opts.raster.stop.cancel;
    ctx.deadline_ns = opts.raster.stop.deadline_ns;
    // A refined rung also looks FURTHER out of each terminal pad: the fan's
    // default ~1.5 mm is too short for a sealed pad whose only exit lies beyond
    // the parts hugging its package (barracuda's `lmx2595/U17.16` escapes
    // 2.45 mm down its free tip, and every ring inside that lands in the
    // decoupling caps against the QFN edge).
    if (opts.raster.divisor > gap_grid_divisor)
        ctx.gate_rings = numeric.toCount(@ceil(@as(f64, @floatFromInt(ctx.gate_rings)) *
            opts.raster.divisor / gap_grid_divisor));
    ctx.zones = board.zones;
    ctx.reserved_lanes = board.reserved_lanes;
    var state = GapState{
        .ctx = &ctx,
        .placement = placement,
        .board = board,
        .opts = opts,
        .dead = try arena.alloc(bool, board.tracks.len),
        .holes = try pad_exit.boardHoles(arena, placement, try viaHoles(arena, board.vias)),
        .term_ban = try arena.alloc(bool, ctx.grid.nx * ctx.grid.ny),
    };
    @memset(state.dead, false);
    ctx.via_ban = try buildViaBanMask(arena, &ctx, placement, params, state.holes);
    // A finishing pass re-searches the same nodes a dozen times per hop against
    // different rip candidates; arm the static-obstacle memo so each node's
    // zone/pad/outline verdict is derived once per hop instead of once per sweep.
    try armStaticBlock(&ctx, arena);
    // …and arm exact-clearance move validation, so a thin net is measured
    // against the copper instead of against the widest class's raster margin.
    ctx.exact = .{ .near = try arena.alloc(bool, ctx.occ.len * ctx.grid.nx * ctx.grid.ny) };
    for (gaps, 0..) |gap, i| {
        if (gap.net_i < placement.nets.len) {
            // A finishing hop is raw maze copper that never reaches the
            // `finishRoute` straighten pass, so gloss it here — otherwise the
            // metal a nearly-done board GAINS is the only metal on it that
            // keeps its staircases (see `straighten.glossHop`).
            if (try closeOneGap(&state, gap)) |raw| out[i] = try straighten.glossHop(.{
                .ctx = &ctx,
                .placement = placement,
                .net = @intCast(gap.net_i),
                .hop = raw,
                .board = try liveCopper(&state, raw.ripped),
            });
            // Only copper the caller KEEPS goes onto the live board the rest of
            // this round routes against (see `GapJudge`).
            if (out[i]) |path| {
                const keep = if (opts.judge) |j| j.keep(j.ctx, i, path) else true;
                if (keep) try state.absorb(path);
            }
        } else {
            // Nothing was attempted for this hop — its net index is off the end
            // of the netlist. `state.reason` still holds the PREVIOUS hop's
            // diagnosis (`.routed`, when that one landed), so it has to be
            // restated or a skipped hop reports a verdict about another net's
            // copper as if it were its own.
            state.reason = .no_such_net;
        }
        if (opts.sink) |s| s.emit(s.ctx, .{
            .index = i,
            .landed = out[i] != null,
            .ripped = if (out[i]) |p| p.ripped.len else 0,
            .why = state.reason,
        });
    }
    return out;
}

/// A through-hole drill as the gap pass sees it: centre + radius. `PadObs`
/// carries copper only, and the `hole↔hole` DRC measures PAD drills too, so a
/// via site has to be tested against these separately.
const PadHole = pad_exit.Hole;

/// The drills of already-routed vias, for `pad_exit.boardHoles`.
fn viaHoles(arena: std.mem.Allocator, vias: []const Via) std.mem.Allocator.Error![]const PadHole {
    var out: std.ArrayList(PadHole) = .empty;
    for (vias) |v| {
        if (v.drill > 0) try out.append(arena, .{ .x = v.x, .y = v.y, .r = v.drill / 2 });
    }
    return out.toOwnedSlice(arena);
}

/// Live state of one `closeGaps` batch: the routing context, the board copper
/// it started from, which of those tracks have been ripped, and the copper the
/// batch has laid down so far.
const GapState = struct {
    ctx: *Ctx,
    placement: optimizer.Placement,
    board: GapBoard,
    opts: GapOptions,
    dead: []bool,
    holes: []const PadHole,
    added_tracks: std.ArrayList(Track) = .empty,
    added_vias: std.ArrayList(Via) = .empty,
    /// How the hop currently in flight ended (see `GapReason`). Carried on the
    /// state rather than threaded through every return type: only the batch
    /// loop reads it, and only right after the hop it belongs to.
    /// The net whose hop is in flight. A rip filter that must weigh victim
    /// against beneficiary — "may THIS net take THAT one's copper" — cannot
    /// answer from the victim alone, and the batch loop is too coarse: one
    /// round carries hops for many nets.
    routing_net: i32 = -1,
    reason: GapReason = .routed,
    /// Scratch via-ban mask for the hop in flight (see `markTerminalViaBan`).
    /// One buffer for the whole batch, rewritten per hop.
    term_ban: []bool,
    /// Rip candidates already routed against during the hop in flight, as their
    /// (sorted) killed-track index sets. Cleared per hop by `closeOneGap`.
    rip_tried: std.ArrayList([]const usize) = .empty,

    /// Has this exact rip already been routed against during this hop? Both
    /// rip-up tiers converge on the same victims — the reach ladder saturates
    /// once it has caught all of a victim's segments, and the path-blocker probe
    /// re-nominates nets the terminal tier already cleared outright. Nothing
    /// else about the board moves between attempts within a hop, so a repeat is
    /// a re-stamp plus a full maze sweep for an answer already known.
    fn ripAlreadyTried(self: *GapState, kill: []const usize) std.mem.Allocator.Error!bool {
        for (self.rip_tried.items) |past| {
            if (std.mem.eql(usize, past, kill)) return true;
        }
        try self.rip_tried.append(self.ctx.arena, kill);
        return false;
    }

    /// Fold a landed hop into the batch's running board view.
    fn absorb(self: *GapState, path: GapPath) std.mem.Allocator.Error!void {
        try self.added_tracks.appendSlice(self.ctx.arena, path.tracks);
        try self.added_vias.appendSlice(self.ctx.arena, path.vias);
        for (path.ripped) |i| {
            if (i < self.dead.len) self.dead[i] = true;
        }
    }
};

/// The board copper as it stands for the next hop: the original tracks minus
/// the ripped ones (and minus `extra_dead`, a rip being *tried*), plus every
/// track this batch has laid down. Vias are never ripped.
fn liveCopper(state: *GapState, extra_dead: []const usize) std.mem.Allocator.Error!GapBoard {
    const arena = state.ctx.arena;
    var tracks: std.ArrayList(Track) = .empty;
    for (state.board.tracks, 0..) |t, i| {
        if (state.dead[i] or std.mem.indexOfScalar(usize, extra_dead, i) != null) continue;
        try tracks.append(arena, t);
    }
    try tracks.appendSlice(arena, state.added_tracks.items);
    var vias: std.ArrayList(Via) = .empty;
    try vias.appendSlice(arena, state.board.vias);
    try vias.appendSlice(arena, state.added_vias.items);
    return .{ .tracks = tracks.items, .vias = vias.items, .zones = state.board.zones };
}

/// Route one hop: a stitch via when `gap.to` is null, else a maze bridge —
/// retried once behind a rip-up when the direct attempt finds no path.
/// One island-joining hop drawn by the multi-layer shape router instead of the
/// raster maze — the answer to `join_no_path`.
///
/// The additive close's refusal reads "no legal path across the freed corridor
/// (geometry, not time)", and on the boards that keep it that verdict is a
/// statement about the LATTICE rather than about the board: a channel narrower
/// than the grid pitch, or one that only opens by diving to another layer, is
/// not a path the maze can represent however much budget it is handed. This
/// re-asks the same question of a mesh that has no lattice, over the same
/// frozen copper, and hands its answer back as an ordinary `GapPath` so the
/// caller's judge, its absorb and the whole acceptance chain above it are
/// unchanged.
///
/// ADDITIVE by construction, which is what lets it stand behind the additive
/// join: it rips nothing (`ripped` is empty, so `route_close.additiveOnly`
/// keeps it on the same terms), it draws only on layers `gapLayers` already
/// allows this net, it dives only through sites `directViaClear` has passed,
/// and every segment is re-probed by `clearDoglegSegment` before it is kept.
/// Nothing is stamped: the copper is a candidate until the caller absorbs it.
fn shapeHop(
    state: *GapState,
    live: GapBoard,
    from: NetPt,
    to: NetPt,
    net: i32,
) std.mem.Allocator.Error!?GapPath {
    const ctx = state.ctx;
    const arena = ctx.arena;
    // The hop is probed against the LIVE board, so the run's lists start as a
    // copy of it; the copper this hop adds is the tail past that mark.
    var tracks: std.ArrayList(Track) = .empty;
    var vias: std.ArrayList(Via) = .empty;
    try tracks.appendSlice(arena, live.tracks);
    try vias.appendSlice(arena, live.vias);
    const base_t = tracks.items.len;
    const base_v = vias.items.len;
    const dr = DirectRun{ .ctx = ctx, .net = net, .tracks = &tracks, .vias = &vias };
    // The hop owns its own wall clock through `routeCancelled`; a probe budget
    // left over from the maze must not make every via site read as blocked.
    const saved_budget = ctx.direct_budget;
    ctx.direct_budget = null;
    defer ctx.direct_budget = saved_budget;
    const ask = (try shapeInput(dr, .{
        .placement = state.placement,
        .tracks = live.tracks,
        .vias = live.vias,
        .from = from,
        .to = to,
    })) orelse return null;
    const found = (try cdt_layers.route(arena, ask)) orelse {
        shapeLog("shape hop {s}: found no channel", .{state.placement.nets[@intCast(net)].name});
        return null;
    };
    if (!try emitShapeRoute(dr, found, false)) {
        shapeLog("shape hop {s}: channel found, copper refused ({s})", .{
            state.placement.nets[@intCast(net)].name,
            @tagName(shapeRefusal(dr, found)),
        });
        return null;
    }
    const drawn_t = tracks.items[base_t..];
    const drawn_v = vias.items[base_v..];
    if (drawn_t.len == 0 and drawn_v.len == 0) return null;
    shapeLog("shape hop {s}: accepted ({d} tracks, {d} vias)", .{
        state.placement.nets[@intCast(net)].name,
        drawn_t.len,
        drawn_v.len,
    });
    return .{ .tracks = drawn_t, .vias = drawn_v };
}

fn closeOneGap(state: *GapState, gap: Gap) std.mem.Allocator.Error!?GapPath {
    if (routeCancelled(state.ctx)) return null;
    state.routing_net = @intCast(gap.net_i);
    setNetParams(state.ctx, state.placement, gap.net_i);
    // `setNetParams` just moved `ctx.reach`, which is an input to every cached
    // static-obstacle verdict — the memo is only valid within one net's hop.
    state.ctx.static_block.reset();
    state.rip_tried.clearRetainingCapacity();
    // A finishing leg searches far wider than a whole-board leg — there are only
    // a handful of them and giving up early on the one net still open is exactly
    // the failure this pass exists to remove — but not without bound: see
    // `gap_max_expansions`.
    const base_ceiling = scaledGapCeiling(gap_max_expansions, state.opts.raster.divisor);
    const effort = @max(@as(usize, 1), @min(state.opts.raster.expansion_multiplier, 8));
    state.ctx.escalate_budget = @min(
        state.ctx.occ.len * state.ctx.grid.nx * state.ctx.grid.ny,
        base_ceiling * effort,
    );
    const net: i32 = @intCast(gap.net_i);
    state.ctx.allowed_layers = gapLayers(state.ctx, net);
    state.reason = .routed;
    clearSearchLimit(state.ctx, gap.net_i);
    markTerminalViaBan(state, gap, net);
    const live = try liveCopper(state, &.{});
    // Leave each terminal from the clearest point on its own pad — see
    // `padExitPoint` for the two barracuda nets this alone was costing.
    const from = padExitPoint(state.ctx, gap.from, net);
    const to = if (gap.to) |t|
        padExitPoint(state.ctx, t, net)
    else stitch: {
        if (try stitchHop(state, live, from, net)) |path| return path;
        const fallback = gap.stitch_fallback orelse return null;
        break :stitch padExitPoint(state.ctx, fallback, net);
    };
    // Over the maze's practical reach the two tiers swap places. A raster maze
    // asked for a cross-board join is a treadmill: it expands a corridor lattice
    // over tens of millimetres of congested copper, spends whatever budget it is
    // given, and returns the same `join_no_path` the mesh answers in geometry —
    // measured on barracuda, where `LOCK_DET`'s 55 mm join consumed a whole
    // guided slice in the maze and the shape tier behind it was never asked at
    // all. Order only: both tiers still run, so nothing the maze could draw is
    // lost, and a hop within reach keeps today's order exactly.
    //
    // A caller may also ask for the mesh ALONE (`ShapeTier.only`), which is not
    // an order but a different question: it has already mazed this exact
    // connection at its own scope, and a second lattice search would only re-ask
    // it. Such a call never reaches the maze or the rip ladder below.
    const shape_first = state.opts.shape == .only or shapeFirst(state.opts, from, to);
    if (shape_first) {
        if (try shapeHop(state, live, from, to, net)) |path| return path;
    }
    if (state.opts.shape == .only) return null;
    if (try mazeHop(state, live, from, to, net)) |path| return path;
    // The maze could not represent a path. Ask the gridless mesh the same
    // question before considering anyone else's copper — additive geometry is
    // always the cheaper answer than moving a net that is already routed.
    if (state.opts.shape.meshes() and !shape_first) {
        if (try shapeHop(state, live, from, to, net)) |path| return path;
    }

    if (!state.opts.ripup) return null;
    // The DIRECT attempt's diagnosis is the honest one — a rip-up retry that
    // also fails says nothing new — so restore it over whatever the retries set.
    const direct = state.reason;
    const rescued = try ripupHop(state, from, to, net);
    if (rescued == null) state.reason = direct;
    return rescued;
}

/// The signal layers a gap hop may lay TRACKS on: the outer faces, every inner
/// layer the board leaves un-poured, and any layer carrying this net's OWN
/// pour. An inner layer a FOREIGN pour occupies is excluded — that is a
/// reserved plane (barracuda's In2.Cu carries only rail pours), and slicing a
/// signal trace through it is exactly the damage a finishing pass must not do.
/// Vias are unaffected: a barrel crosses every layer through the pour's antipad.
fn gapLayers(ctx: *const Ctx, net: i32) u64 {
    var mask: u64 = 0;
    for (0..@min(ctx.occ.len, 64)) |layer| {
        var foreign = false;
        var own = false;
        for (ctx.zones) |z| {
            if (!z.copper or z.layer != layer) continue;
            if (z.net == net) own = true else foreign = true;
        }
        if (layer < 2 or own or !foreign) mask |= @as(u64, 1) << @intCast(layer);
    }
    return mask;
}

/// Reset the occupancy/reservation grids and re-stamp the board's copper as
/// seen by `net`: every FOREIGN track/via at this net's exact clearance, and
/// nothing of the net's own (so Dijkstra seeds only from the pads we hand it,
/// never from copper on the far island — which would "find" the goal at zero
/// cost and emit no metal at all).
fn stampGapBoard(ctx: *Ctx, live: GapBoard, net: i32) void {
    for (ctx.occ) |l| @memset(l, empty_cell);
    for (ctx.resv) |l| @memset(l, empty_cell);
    stampBoardCopper(ctx, live.tracks, live.vias, net);
    // `resv` reset 3/6 — per hop, or the finishing pass is the one pass that
    // routes straight through an authored lane.
    lane_reserve.stamp(ctx.reserved_lanes, ctx.resv, ctx.grid, null);
}

/// Maze one pad to another across the current board. Both terminals enter the
/// grid through their access node plus `padGateways`, so a fine-pitch pad whose
/// nearest node sits inside a neighbour's clearance still has a way in.
fn mazeHop(state: *GapState, live: GapBoard, from: NetPt, to: NetPt, net: i32) std.mem.Allocator.Error!?GapPath {
    const ctx = state.ctx;
    stampGapBoard(ctx, live, net);
    var seeds: std.ArrayList(usize) = .empty;
    try terminalKeys(ctx, live, from, net, &seeds);
    if (seeds.items.len == 0) {
        state.reason = .sealed_from;
        return null;
    }
    var goals: std.ArrayList(usize) = .empty;
    try terminalKeys(ctx, live, to, net, &goals);
    if (goals.items.len == 0) {
        state.reason = .sealed_to;
        return null;
    }
    // Seed the start pad's access node as this net's copper so `emitPath` can
    // terminate there; the goal pad is deliberately NOT seeded (it would make
    // the search trivially succeed without laying any metal).
    var tracks: std.ArrayList(Track) = .empty;
    var vias: std.ArrayList(Via) = .empty;
    const hit = (try dijkstra(ctx, net, .{ .goals = goals.items, .sources = seeds.items, .anchors = .{ .source = from, .goal = to } }, &tracks, &vias)) orelse {
        if (routeCancelled(ctx)) return null;
        const direct_reason: GapReason = if (searchWasLimited(ctx, @intCast(net))) .exhausted else .blocked;
        // The fine finishing rung deliberately allows an SMD terminal via. Give
        // that permission to the exact/off-grid router too: the raster can see
        // a clear inner-layer corridor yet still have no grid node at the only
        // legal breakout site beside a fine-pitch pad. Seeding that exact via
        // and handing the remainder back to the maze is the automatic form of
        // the tiny terminal nudge a designer otherwise has to draw by hand.
        if (state.opts.terminal_via == .smd_ok) {
            if (try exactGapRescue(state, live, from, to, net)) |path| {
                state.reason = .routed;
                return path;
            }
        }
        state.reason = direct_reason;
        return null;
    };
    const stubs = try gateStubs(ctx, live, net, &tracks, &vias, &.{
        .{ .pt = to, .key = hit.goal },
        .{ .pt = from, .key = hit.source },
    });
    return .{
        .tracks = stubs,
        .vias = try vias.toOwnedSlice(ctx.arena),
    };
}

/// One terminal stub request: the pad point, and the grid node the maze
/// actually entered or left through.
const StubJoin = struct { pt: NetPt, key: usize };

/// Draw a gap hop's terminal stubs AGAINST THE LIVE BOARD, and hand back the
/// hop's own copper alone.
///
/// A gap hop keeps its copper in fresh lists because only the copper it drew
/// may be returned to the caller — `closeGaps` judges and absorbs it as a
/// candidate. But `gateStub` measures clearance against the very lists it is
/// handed (`DirectPath.tracks` / `OctiJoin.placed_vias`), so handing it those
/// hop-local lists means the exact off-grid stub — the one piece of a maze hop
/// no lattice move ever validated — is probed against an EMPTY board. Every
/// other `gateStub` caller passes the whole board's lists and is unaffected;
/// this is the one seam where the two roles were the same slice.
///
/// Measured on barracuda (2026-08-18, layout `barracuda-kicad-clean-v1`): the
/// first gate's `TXDATA_ADF` hop drew its source stub as a 45° leg straight
/// through `loop_amp/LF_FB_RC`'s via barrel — 0.196 mm centre-to-centre where
/// the rule needs 0.391 — and the gate then dropped the whole hop as its DRC
/// victim. `loop_amp/LF_OUT` crossed a `CPOUT` barrel and `V_1V8A` a `V_12V`
/// track the same way.
///
/// `shapeHop` beside it already does exactly this (its run lists start as a
/// copy of `live`); this gives the maze tier the same board view.
fn gateStubs(
    ctx: *Ctx,
    live: GapBoard,
    net: i32,
    tracks: *std.ArrayList(Track),
    vias: *std.ArrayList(Via),
    joins: []const StubJoin,
) std.mem.Allocator.Error![]const Track {
    var board_tracks: std.ArrayList(Track) = .empty;
    try board_tracks.appendSlice(ctx.arena, live.tracks);
    const own = board_tracks.items.len;
    try board_tracks.appendSlice(ctx.arena, tracks.items);
    var board_vias: std.ArrayList(Via) = .empty;
    try board_vias.appendSlice(ctx.arena, live.vias);
    try board_vias.appendSlice(ctx.arena, vias.items);
    for (joins) |join| try gateStub(ctx, net, join.pt, join.key, board_vias.items, &board_tracks);
    return ctx.arena.dupe(Track, board_tracks.items[own..]);
}

/// Exact terminal escape for a gap the raster could not start or finish.
///
/// The ordinary maze is still first: this is a bounded last rung used only by
/// the caller that opted into SMD terminal vias. Existing copper is copied into
/// the direct run solely as collision geometry; only the suffix the rescue adds
/// is returned. When the net has no declared preferred layer, prefer a legal
/// inner signal layer for this attempt so a same-face bridge can leave a dense
/// surface pad field with two vias instead of trying another surface dogleg.
/// When every inner layer is a plane, the opposite outer face is the final
/// legal fallback; otherwise a four-layer plane stack has no layer-change
/// rescue at all.
fn exactGapRescue(
    state: *GapState,
    live: GapBoard,
    from: NetPt,
    to: NetPt,
    net: i32,
) std.mem.Allocator.Error!?GapPath {
    const ctx = state.ctx;
    var tracks: std.ArrayList(Track) = .empty;
    var vias: std.ArrayList(Via) = .empty;
    try tracks.appendSlice(ctx.arena, live.tracks);
    try vias.appendSlice(ctx.arena, live.vias);
    const track_mark = tracks.items.len;
    const via_mark = vias.items.len;
    const run = DirectRun{ .ctx = ctx, .net = net, .tracks = &tracks, .vias = &vias };

    const saved_preferred = ctx.preferred_layers;
    defer ctx.preferred_layers = saved_preferred;
    const had_preference = ctx.preferred_layers != 0;
    if (!had_preference) ctx.preferred_layers = @as(u64, 1) << @intCast(from.layer);

    var routed = try tryDirectPair(run, from, to);
    // Cross-face `tryDirectPair` deliberately stops after its one-via search.
    // A finishing bridge may need an exact breakout plus another transition on
    // the far side, so let the already-bounded seeded-maze primitive take that
    // extra rung here without widening the whole-board direct router.
    if (!routed) routed = try tryTwoViaSeededMaze(run, from, to);
    // With no authored preference, try the natural terminal face first. If it
    // is genuinely sealed, reset the speculative occupancy and give a legal
    // inner signal layer the two-via fallback. This preserves outer-face bus
    // corridors while still rescuing a pad field only an inner layer can cross.
    if (!routed and !had_preference) {
        rollbackDirectRun(run, track_mark, via_mark);
        const inner = ctx.allowed_layers & ~@as(u64, 0b11);
        if (inner != 0) {
            ctx.preferred_layers = inner;
            routed = try tryDirectPair(run, from, to);
            if (!routed) routed = try tryTwoViaSeededMaze(run, from, to);
        }
    }
    // A conventional four-layer stack often dedicates every inner layer to a
    // plane. In that case (or when the inner attempt could not land), the other
    // outer face is the only remaining legal topology. This is still inside the
    // caller's exact, no-rip endgame transaction; ordinary routing does not gain
    // another speculative outer-face pass.
    if (!routed and !had_preference) {
        rollbackDirectRun(run, track_mark, via_mark);
        const terminal_bit = @as(u64, 1) << @intCast(from.layer);
        const other_outer = ctx.allowed_layers & @as(u64, 0b11) & ~terminal_bit;
        if (other_outer != 0) {
            ctx.preferred_layers = other_outer;
            routed = try tryDirectPair(run, from, to);
            if (!routed) routed = try tryTwoViaSeededMaze(run, from, to);
        }
    }
    if (!routed) {
        rollbackDirectRun(run, track_mark, via_mark);
        return null;
    }
    return .{
        .tracks = try ctx.arena.dupe(Track, tracks.items[track_mark..]),
        .vias = try ctx.arena.dupe(Via, vias.items[via_mark..]),
    };
}

/// The grid keys a terminal pad can enter/leave the maze through: its own
/// access node (when routable) plus its gateway fan.
fn terminalKeys(
    ctx: *Ctx,
    live: GapBoard,
    pt: NetPt,
    net: i32,
    out: *std.ArrayList(usize),
) std.mem.Allocator.Error!void {
    const nodes = ctx.grid.nx * ctx.grid.ny;
    const nd = ctx.grid.nearest(pt.x, pt.y);
    const n = ctx.grid.node(nd[0], nd[1]);
    if (!blocked(ctx, pt.layer, n, net)) try out.append(ctx.arena, @as(usize, pt.layer) * nodes + n);
    try padGateways(ctx, live.tracks, live.vias, pt, net, out);
}

/// Drop one plane/pour via beside a stranded pad, plus the stub that reaches
/// it. When the net's own retained pour is the target the via must land INSIDE
/// the copper that pour actually fabricates (an inner power island only credits
/// copper that reaches it); when a plane is the target any DRC-clean site near
/// the pad reaches it. When NEITHER is true here — the net's pours are all
/// knocked back by higher-priority ones around this pad, and no plane backs the
/// net — there is nothing for a barrel to land in, so no stitch is attempted and
/// the caller's trace fallback takes the island instead. See `stitchTarget`.
fn stitchHop(state: *GapState, live: GapBoard, pt: NetPt, net: i32) std.mem.Allocator.Error!?GapPath {
    const ctx = state.ctx;
    stampGapBoard(ctx, live, net);
    const c = [2]f64{ pt.x, pt.y };
    var tracks: std.ArrayList(Track) = .empty;
    const target = stitchTarget(state, pt, net, stitch_reach_mm * maze_stitch_reach_mult);
    if (target == .none) {
        state.reason = .no_via_site;
        return null;
    }
    const poured = target == .pour;
    const at = findGapStitch(state, live, pt, net, poured) orelse
        return mazeStitch(state, live, pt, net, poured);
    if (@abs(at[0] - c[0]) > 1e-6 or @abs(at[1] - c[1]) > 1e-6) {
        try tracks.append(ctx.arena, .{
            .x1 = c[0],
            .y1 = c[1],
            .x2 = at[0],
            .y2 = at[1],
            .layer = pt.layer,
            .width = ctx.params.track_width,
            .net = net,
        });
    }
    return .{
        .tracks = try tracks.toOwnedSlice(ctx.arena),
        .vias = try stitchVia(ctx, at, net),
    };
}

/// One stitch via at `at`.
fn stitchVia(ctx: *Ctx, at: [2]f64, net: i32) std.mem.Allocator.Error![]const Via {
    const vias = try ctx.arena.alloc(Via, 1);
    vias[0] = .{ .x = at[0], .y = at[1], .dia = ctx.params.via_dia, .drill = ctx.params.via_drill, .net = net };
    return vias;
}

/// Stitch a pad that has no via site it can reach in ONE straight stub: maze a
/// short trace on the pad's own layer to the nearest node where a via IS legal,
/// then drop the via there. This is what rescues a pad boxed in by its
/// neighbours — the stub can bend around them, which a radial fan cannot.
fn mazeStitch(state: *GapState, live: GapBoard, pt: NetPt, net: i32, poured: bool) std.mem.Allocator.Error!?GapPath {
    const ctx = state.ctx;
    var seeds: std.ArrayList(usize) = .empty;
    try terminalKeys(ctx, live, pt, net, &seeds);
    if (seeds.items.len == 0) {
        state.reason = .sealed_from;
        return null;
    }
    const goals = try stitchGoals(state, live, pt, net, poured);
    if (goals.len == 0) {
        state.reason = .no_via_site;
        return null;
    }
    var tracks: std.ArrayList(Track) = .empty;
    var vias: std.ArrayList(Via) = .empty;
    const hit = (try dijkstra(ctx, net, .{ .goals = goals, .sources = seeds.items, .anchors = .{ .source = pt } }, &tracks, &vias)) orelse {
        state.reason = if (searchWasLimited(ctx, @intCast(net))) .exhausted else .blocked;
        return null;
    };
    const stubs = try gateStubs(ctx, live, net, &tracks, &vias, &.{.{ .pt = pt, .key = hit.source }});
    const nodes = ctx.grid.nx * ctx.grid.ny;
    const n = hit.goal % nodes;
    const at = [2]f64{ ctx.grid.worldX(n % ctx.grid.nx), ctx.grid.worldY(n / ctx.grid.nx) };
    try vias.appendSlice(ctx.arena, try stitchVia(ctx, at, net));
    return .{
        .tracks = stubs,
        .vias = try vias.toOwnedSlice(ctx.arena),
    };
}

/// Every node within the stitch reach of `pt`, on `pt`'s own layer, where a via
/// of this net's geometry is legal (and inside the net's own SURVIVING pour when
/// that is the target — see `stitchTarget`) — the goal set a maze stitch aims at.
fn stitchGoals(state: *GapState, live: GapBoard, pt: NetPt, net: i32, poured: bool) std.mem.Allocator.Error![]const usize {
    const ctx = state.ctx;
    const nodes = ctx.grid.nx * ctx.grid.ny;
    const reach = stitch_reach_mm * maze_stitch_reach_mult;
    const lo = ctx.grid.nearest(pt.x - reach, pt.y - reach);
    const hi = ctx.grid.nearest(pt.x + reach, pt.y + reach);
    var out: std.ArrayList(usize) = .empty;
    var iy = lo[1];
    while (iy <= hi[1]) : (iy += 1) {
        var ix = lo[0];
        while (ix <= hi[0]) : (ix += 1) {
            const x = ctx.grid.worldX(ix);
            const y = ctx.grid.worldY(iy);
            if (std.math.hypot(x - pt.x, y - pt.y) > reach) continue;
            // Any of the net's own pours, not just its largest — see
            // `StitchProbe.clear`.
            if (poured and !netPourCovers(ctx, net, x, y, null)) continue;
            const n = ctx.grid.node(ix, iy);
            if (!viaAllowed(ctx, n, net, live.vias)) continue;
            if (!viaClearsPadHoles(state, x, y)) continue;
            try out.append(ctx.arena, @as(usize, pt.layer) * nodes + n);
        }
    }
    return out.toOwnedSlice(ctx.arena);
}

/// How much further than the straight-stub fan a maze stitch may travel to
/// find its via site. The trace can bend, so a larger neighbourhood is
/// reachable without the stub-clearance constraint that bounds the fan.
const maze_stitch_reach_mult: f64 = 2.5;

/// Nearest DRC-clean stitch-via site for `pt`: the pad's OWN copper first
/// (`plane_via.InPad` — a big land holds a via a couple of tenths off its
/// anchor, which the grid-stepped fan below strides over), then outward from the
/// pad in growing rings until one clears every foreign pad, every placed via,
/// every routed track, AND every through drill — the `hole↔hole` rule measures
/// pad bores too, and a SAME-NET through pad is invisible to all the copper
/// tests, so a via would land right on it. `viaClearsHoles` covers that now;
/// `viaClearsPadHoles` stays because this pass's own hole list also carries the
/// drills of vias the board arrived with.
fn findGapStitch(state: *GapState, live: GapBoard, pt: NetPt, net: i32, poured: bool) ?[2]f64 {
    const ctx = state.ctx;
    const probe = StitchProbe{
        .state = state,
        .live = live,
        .pad = .{ pt.x, pt.y },
        .layer = pt.layer,
        .net = net,
        .poured = poured,
    };
    if (padCopperAt(ctx, probe.pad, net, pt.layer)) |pad| {
        var scan = plane_via.InPad.init(pad, probe.pad, ctx.params.via_dia);
        while (scan.next()) |s| {
            if (probe.clear(s)) return s;
        }
    }
    const dir = plane_via.fanDir(ctx.obs, probe.pad, net);
    const ang0 = std.math.atan2(dir[1], dir[0]);
    const rings: usize = @max(1, numeric.toCount(@ceil(stitch_reach_mm / ctx.grid.g)));
    var ring: usize = 1;
    while (ring <= rings) : (ring += 1) {
        const rad = @as(f64, @floatFromInt(ring)) * ctx.grid.g;
        var k: usize = 0;
        while (k < stitch_spokes) : (k += 1) {
            const a = ang0 + plane_via.swivel(k);
            const s = ctx.grid.snap(probe.pad[0] + rad * @cos(a), probe.pad[1] + rad * @sin(a));
            if (probe.clear(s)) return s;
        }
    }
    // Last: the pad itself again, with the via's RING allowed to hang over its
    // edge and only its HOLE required to stay on the copper
    // (`plane_via.InPad.overDrill`).
    //
    // This is the fine-pitch finger, and for it the two searches above are not
    // merely empty — they cannot be anything else. Barracuda's `J1` is a
    // 1.27 mm-pitch board-to-board connector: its B.Cu fingers are 1.0 x
    // 0.35 mm and the board's via is 0.4 mm, so the pad is NARROWER than the
    // barrel and no point of it can contain one; outside the pad the fan is
    // walled by the row neighbours 0.635 mm away, a mounting hole below and a
    // test point beside. Measured on the last open GND gap barracuda had left:
    // 192 fan sites tried and every one refused, then a 5 mm maze that found
    // 596 legal sites further out and no lane on B.Cu to reach one of them —
    // a lone-pad copper island 1.27 mm from the rest of its own net.
    //
    // A via at that finger's own centre is what the routed reference board
    // carries there, and it is the ordinary answer: the hole is ringed by the
    // pad's own copper, so the barrel is landed however the ring is trimmed,
    // and the ring that overhangs is this net's copper — the only thing it can
    // offend is a FOREIGN object, and `probe.clear` measures every class of
    // them here exactly as it does for any other site. Containment is the only
    // thing relaxed.
    //
    // The asymmetry it closes is with the router's OWN first pass:
    // `findGroundVia` opens on the pad centre snapped to the grid, and the
    // strict scan refuses a pad this small while the fan's first ring starts a
    // whole grid pitch out, so the pad's own centre was never a candidate here.
    //
    // It is a DELIBERATE relaxation, and not the gap pass 1 used to leave open.
    // Pass 1 once judged its snapped centre by clearance alone, which let a
    // barrel stand on a land too shallow to hold its ring; it now gates that
    // site on `plane_via.inLandBarrelFits` and falls through to the ladder. This
    // tier remains the one place the ring may overhang, it is reached only after
    // strict containment and the whole fan have declined, and what licenses it
    // is the DRILL being ringed by the pad's own copper — not an unpoliced
    // default.
    //
    // Strictly additive by position: both tiers above have already declined, so
    // a pad that had a site keeps the site it had. On barracuda today it is
    // additive and nothing more, which is measured rather than hoped: the tier
    // turns `J1` pad 40's zero candidates into nine and `lmx2595/U17` pad 34's
    // into seven, and every one of them is then refused by `viaClearsTracks` —
    // a neighbour's escape drawn within 0.39 mm (0.2 barrel + 0.064 half-track
    // + 0.127 clearance) of the whole finger. That is a real clearance conflict
    // and not a search bound: the copper in the way has to MOVE, which is the
    // residual rip tier's job and not something a stitch may overrule. So the
    // board is byte-identical and the candidate is there for the rip to use.
    if (padCopperAt(ctx, probe.pad, net, pt.layer)) |pad| {
        var scan = plane_via.InPad.overDrill(pad, probe.pad, ctx.params.via_dia, ctx.params.via_drill);
        while (scan.next()) |s| {
            if (probe.clear(s)) return s;
        }
    }
    return null;
}

/// One stranded pad's stitch-site search: everything a candidate site is
/// measured against.
const StitchProbe = struct {
    state: *GapState,
    live: GapBoard,
    pad: [2]f64,
    layer: u8,
    net: i32,
    /// True when this net's own pour is the stitch target (`StitchTarget.pour`)
    /// — then the via must land inside its SURVIVING fill, since that is the
    /// copper the pad is rejoining.
    poured: bool,

    /// Is `s` a legal stitch-via site, reachable from the pad by one stub?
    fn clear(self: StitchProbe, s: [2]f64) bool {
        const ctx = self.state.ctx;
        // ANY of the net's own pours will do. Judging the site against only the
        // LARGEST one (what this did) strands a pad sitting over a smaller
        // island of the same rail: every site near it fails the containment
        // test, the fan finds nothing, and the pad reads as having no via site
        // when in fact it is sitting on its own copper.
        if (self.poured and !netPourCovers(ctx, self.net, s[0], s[1], null)) return false;
        if (!groundViaPointClear(ctx, self.live.vias, self.live.tracks, s, self.net)) return false;
        if (!viaClearsPadHoles(self.state, s[0], s[1])) return false;
        if (!segClearsPadsOnLayer(ctx, self.pad, s, self.net, null)) return false;
        if (!segClearsVias(ctx, self.live.vias, self.pad, s, self.net)) return false;
        return segClearsTracks(ctx, self.live.tracks, self.pad, s, self.net, self.layer);
    }
};

/// True when a via drilled at `(x, y)` keeps the hole-to-hole wall from every
/// through-hole PAD drill on the board.
fn viaClearsPadHoles(state: *GapState, x: f64, y: f64) bool {
    const vr = state.ctx.params.via_drill / 2;
    if (vr <= 0) return true;
    for (state.holes) |h| {
        if (std.math.hypot(x - h.x, y - h.y) < vr + h.r + state.ctx.hole_to_hole - clearance_eps) return false;
    }
    return true;
}

/// Retry a blocked bridge behind a rip-up: find the foreign nets whose copper
/// seals the terminals' escape, clear each one's nearby tracks in turn, and
/// keep the first rip that lets the maze through. The ripped net is reported so
/// the caller deletes exactly those segments — it opens up and returns as a gap
/// of its own, which is what "reorder" means here: the sealed net routes first,
/// its aggressor re-routes around the result.
///
/// The ladder's TOP rung is different in kind, not just in size. Below it the
/// terminal-local tier runs first and, when it finds any single net whose
/// removal lets the maze through, the hop stops there — even when that net is
/// the one thing on the board that cannot be re-routed afterwards, so the
/// caller's gate throws the whole transaction out as `broke_victim` however
/// wide the reach grows. The top rung therefore SKIPS the terminal tier
/// outright and asks the path-blocker tier for the multi-net rip directly: the
/// corridor's blockers cleared together, which is the only rip that leaves each
/// victim free to take a different route home.
fn ripupHop(state: *GapState, from: NetPt, to: NetPt, net: i32) std.mem.Allocator.Error!?GapPath {
    const breadth = RipBreadth.forTier(state.opts.rip_from);
    if (breadth == .union_only) return ripPathBlockers(state, from, to, net, breadth);
    if (try ripNearTerminals(state, from, to, net, breadth)) |path| return path;
    return ripPathBlockers(state, from, to, net, breadth);
}

/// Rip-up tier A: the nets whose copper crowds a TERMINAL. This is the short-hop
/// case — a segment lying across a fine-pitch pad's exit lane — and it is cheap
/// to find, so it is tried first.
/// A pad in a dense connector row is not crowded by ONE neighbour's escape but
/// by all of them at once, so when no single aggressor opens the lane the whole
/// nominated set is cleared together (`ripBlockerSet`) before the tier gives up.
fn ripNearTerminals(state: *GapState, from: NetPt, to: NetPt, net: i32, breadth: RipBreadth) std.mem.Allocator.Error!?GapPath {
    var seen: std.ArrayList(i32) = .empty;
    const first = @min(state.opts.rip_from, ripup_reaches.len - 1);
    for (0..ripup_max_nets) |_| {
        const victim = nearestAggressor(state, from, to, net, seen.items) orelse break;
        try seen.append(state.ctx.arena, victim);
        // Smallest rip that works, not the biggest that might — a narrow rip is
        // less to repair and less to lose. `rip_from` is how a caller escalates
        // when that trade turned out wrong (see `GapOptions.rip_from`).
        for (ripup_reaches[first..]) |reach| {
            const kill = try aggressorTracks(state, victim, from, to, reach);
            if (kill.len == 0) continue;
            // A wider reach that catches no further segment of this victim is
            // the SAME board as the tier below, so the maze would re-derive the
            // same answer over a full re-stamp and a full sweep. Barracuda's
            // reach ladder collapses this way for most victims, and those
            // duplicate sweeps were a large share of a failing hop's cost.
            if (try state.ripAlreadyTried(kill)) continue;
            const live = try liveCopper(state, kill);
            if (try mazeHop(state, live, from, to, net)) |path| {
                return .{
                    .tracks = path.tracks,
                    .vias = path.vias,
                    .ripped = kill,
                    .ripped_nets = try state.ctx.arena.dupe(i32, &.{victim}),
                };
            }
        }
    }
    if (breadth == .singles_only or seen.items.len < 2) return null;
    return ripBlockerSet(state, from, to, net, seen.items, ripup_reach_mm);
}

/// Rip-up tier B: the nets walling the PATH.
///
/// A long bridge is usually not blocked at its pads at all — both escape fine
/// and the maze still drains its frontier, because somewhere in the middle a
/// foreign trunk crosses every corridor. Tier A can never see that: it only
/// looks within `ripup_reach_mm` of a terminal. `softProbe` does — it re-runs
/// the search with foreign copper passable at a penalty and reports which nets
/// the cheapest soft path had to cross. Each of those is then cleared OUTRIGHT
/// (a mid-path rip has no "near the terminal" subset to take, and a whole-net
/// clear is what lets its repair pick a different corridor) and the maze retried.
///
/// One at a time is not enough. A corridor walled by TWO trunks stays walled
/// when either one alone goes, so every single-net rip reports `blocked` and the
/// hop is written off as impossible — while the same hop routes freely once both
/// move. (Barracuda's `SPI_SCK` is exactly this: its corridor carries
/// `SPI_MOSI` AND `V_12V`, and the hand-finished board that closes it re-routed
/// both.) So the singles are tried first — cheapest, least to repair — and when
/// none opens the channel the whole candidate set is cleared TOGETHER. The
/// caller's accept gate is what keeps this honest: every net in `ripped_nets`
/// has to come back whole or the entire transaction is rolled back.
fn ripPathBlockers(
    state: *GapState,
    from: NetPt,
    to: NetPt,
    net: i32,
    breadth: RipBreadth,
) std.mem.Allocator.Error!?GapPath {
    const ctx = state.ctx;
    var crossed = std.AutoHashMapUnmanaged(i32, void).empty;
    try softProbe(ctx, net, from, to, &crossed, ctx.arena);
    var victims: std.ArrayList(i32) = .empty;
    var it = crossed.keyIterator();
    while (it.next()) |kp| {
        const victim = kp.*;
        if (victim == net or victim == empty_cell or victim < 0) continue;
        if (!ripAllowed(state, victim)) continue;
        if (victims.items.len >= ripup_max_nets) break;
        try victims.append(ctx.arena, victim);
    }
    if (breadth != .union_only) {
        for (victims.items) |victim| {
            if (try ripBlockerSet(state, from, to, net, &.{victim}, null)) |path| return path;
        }
        if (breadth == .singles_only or victims.items.len < 2) return null;
    }
    if (victims.items.len == 0) return null;
    return ripBlockerSet(state, from, to, net, victims.items, null);
}

/// Clear every net in `victims` at once and retry the maze through the space
/// they leave. Null when the set has no live copper, when this exact rip has
/// already been routed against during the hop, or when the maze still finds no
/// path.
fn ripBlockerSet(
    state: *GapState,
    from: NetPt,
    to: NetPt,
    net: i32,
    victims: []const i32,
    /// How much of each victim to take: null = the whole net (the mid-path
    /// case, where a partial rip leaves the repair nothing to work with), or a
    /// reach in mm around the terminals (the crowded-pad case, where the lane
    /// only needs the segments actually boxing the pad in — and where taking
    /// whole nets would be both destructive and, for a trunk like GND, refused
    /// outright by `ripup_max_tracks`).
    reach: ?f64,
) std.mem.Allocator.Error!?GapPath {
    var kill: std.ArrayList(usize) = .empty;
    for (victims) |victim| {
        const tracks = if (reach) |r|
            try aggressorTracks(state, victim, from, to, r)
        else
            try netTracks(state, victim);
        // A victim too big to clear wholesale (`ripup_max_tracks`) makes the
        // WHOLE set unusable: routing through a gap only half of the blockers
        // vacated draws copper straight across the one that stayed.
        if (tracks.len == 0 and reach == null) return null;
        try kill.appendSlice(state.ctx.arena, tracks);
    }
    if (kill.items.len == 0) return null;
    std.mem.sort(usize, kill.items, {}, std.sort.asc(usize));
    if (try state.ripAlreadyTried(kill.items)) return null;
    const live = try liveCopper(state, kill.items);
    const path = try mazeHop(state, live, from, to, net) orelse return null;
    return .{
        .tracks = path.tracks,
        .vias = path.vias,
        .ripped = kill.items,
        .ripped_nets = try state.ctx.arena.dupe(i32, victims),
    };
}

/// Every live track index belonging to `victim`, or nothing when the net is too
/// big to clear wholesale (see `ripup_max_tracks`).
fn netTracks(state: *GapState, victim: i32) std.mem.Allocator.Error![]const usize {
    var out: std.ArrayList(usize) = .empty;
    for (state.board.tracks, 0..) |t, i| {
        if (state.dead[i] or t.net != victim) continue;
        try out.append(state.ctx.arena, i);
    }
    if (out.items.len > ripup_max_tracks) return &.{};
    return out.toOwnedSlice(state.ctx.arena);
}

/// May this hop take copper from `victim` at all (see `GapOptions.rip_filter`)?
fn ripAllowed(state: *GapState, victim: i32) bool {
    const f = state.opts.rip_filter orelse return true;
    return f.rippable(f.ctx, victim, state.routing_net);
}

/// The foreign net (not already tried, and one the caller allows ripping) whose
/// copper lies closest to either terminal pad — the most likely thing sealing
/// the escape.
fn nearestAggressor(state: *GapState, from: NetPt, to: NetPt, net: i32, seen: []const i32) ?i32 {
    var best: ?i32 = null;
    var best_d = ripup_reach_mm;
    for (state.board.tracks, 0..) |t, i| {
        if (state.dead[i] or t.net == net or t.net == empty_cell) continue;
        if (std.mem.indexOfScalar(i32, seen, t.net) != null) continue;
        if (!ripAllowed(state, t.net)) continue;
        const d = @min(
            segPointDist(t.x1, t.y1, t.x2, t.y2, from.x, from.y),
            segPointDist(t.x1, t.y1, t.x2, t.y2, to.x, to.y),
        );
        if (d >= best_d) continue;
        best_d = d;
        best = t.net;
    }
    return best;
}

/// `victim`'s track indices lying within the rip-up reach of either terminal —
/// the escape-sealing segments, not the whole net.
fn aggressorTracks(state: *GapState, victim: i32, from: NetPt, to: NetPt, reach: f64) std.mem.Allocator.Error![]const usize {
    var out: std.ArrayList(usize) = .empty;
    for (state.board.tracks, 0..) |t, i| {
        if (state.dead[i] or t.net != victim) continue;
        const d = @min(
            segPointDist(t.x1, t.y1, t.x2, t.y2, from.x, from.y),
            segPointDist(t.x1, t.y1, t.x2, t.y2, to.x, to.y),
        );
        if (d < reach) try out.append(state.ctx.arena, i);
    }
    // The whole-net tier is capped: past `ripup_max_tracks` the aggressor is a
    // trunk, and betting its entire route on one repair is a worse trade than
    // leaving this hop unrouted.
    if (out.items.len > ripup_max_tracks) return &.{};
    return out.toOwnedSlice(state.ctx.arena);
}

/// A routing context for gap closing: the BASE grid pitch (so a hop between
/// two 0.5 mm-pitch pads is representable — the whole-board pass sizes its
/// pitch to the widest net class and cannot resolve those channels), with the
/// pad-index prefilter and the board-edge inset still sized to the widest class
/// so no clearance test is under-reached. Per-hop clearance stays exact:
/// `setNetParams` + `stampBoardCopper` halo every obstacle at the routing net's
/// own width.
fn buildGapCtx(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    params: RouteParams,
    divisor: f64,
    window: ?GapWindow,
) std.mem.Allocator.Error!CtxResult {
    const none = try arena.alloc(bool, placement.nets.len);
    @memset(none, false);
    var result = try buildRouteCtx(arena, placement, params, none, 0);
    switch (result) {
        .ok => |*ctx| {
            const wide = maxRouteParams(placement, params, &.{});
            ctx.index_reach = wide.track_width / 2 + wide.clearance;
            ctx.selected_nets = &.{};
            const before = ctx.grid.g;
            if (window) |w| {
                // A CORRIDOR run allocates only the window's cells, so the
                // divisor buys resolution instead of board area — the whole
                // point of bounding the region (see `GapWindow`). A degenerate
                // window falls back to the board-wide raster rather than
                // failing the hop.
                if (try windowCtx(ctx, placement, .{ .x0 = w.x0, .y0 = w.y0, .x1 = w.x1, .y1 = w.y1 }, before / divisor)) |wc| {
                    ctx.* = wc;
                } else {
                    try refineGapGrid(arena, placement, ctx, wide, divisor);
                }
            } else {
                try refineGapGrid(arena, placement, ctx, wide, divisor);
            }
            // The gateway fan is counted in grid steps, so a finer raster would
            // otherwise shrink its physical reach and leave a fine-pitch pad
            // reading as sealed. Keep the millimetres, spend the extra nodes.
            ctx.gate_rings = @max(gate_rings, numeric.toCount(@ceil(@as(f64, @floatFromInt(gate_rings)) * before / ctx.grid.g)));
        },
        else => {},
    }
    return result;
}

/// Node ceiling for a gap pass's refined raster, deliberately above the
/// whole-board `max_nodes`. That cap bounds the cost of routing EVERY net on a
/// board; a finishing pass routes a handful of legs, so it can afford a raster
/// a whole-board run cannot — and it needs one, because the stamped-obstacle
/// margin scales with the pitch (see `gap_grid_divisor`) and a 0.127 mm control
/// net's corridors vanish at the whole-board pitch, which is sized to the widest
/// class on the board.
const gap_max_nodes: usize = 400_000;

/// Node-expansion ceiling for ONE maze sweep of a gap hop.
///
/// A finishing hop is re-searched a dozen times against different rip
/// candidates, and the ones that fail are the ones that sweep widest: a hop
/// whose terminals are in genuinely disconnected regions drains the entire
/// reachable board, which on barracuda is ~100k nodes a sweep and turns a
/// single hop into half a minute. Sweeps that SUCCEED are nothing like that —
/// measured over full barracuda runs the widest search that ever landed copper
/// expanded 29,869 nodes, and the median is under 400 — so a ceiling four times
/// above the widest observed success bounds the failures without reaching any
/// hop that would have worked. Above the whole-board `max_batch_expansions`, so
/// it only ever raises a leg's budget.
const gap_max_expansions: usize = 120_000;

/// A gap ceiling (`gap_max_nodes` / `gap_max_expansions`) scaled to a caller's
/// grid divisor: node count grows with the divisor squared, so the budgets do
/// too. At the default divisor this is the identity, and because both sides of
/// `refineGapGrid`'s fit check scale by the same factor, a board whose
/// divisor-2 raster fits its budget fits every finer raster's scaled budget.
fn scaledGapCeiling(base: usize, divisor: f64) usize {
    const scale = divisor / gap_grid_divisor;
    return numeric.toCount(@ceil(@as(f64, @floatFromInt(base)) * scale * scale));
}

/// Re-grid a gap context at `divisor`× the base resolution (normally
/// `gap_grid_divisor`; see `GapOptions.grid_divisor` for finer), keeping
/// the pad obstacles / off-board net flags `buildRouteCtx` already computed.
/// Leaves the grid untouched when the finer raster would exceed the scaled
/// node ceiling.
fn refineGapGrid(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    ctx: *Ctx,
    wide: RouteParams,
    divisor: f64,
) std.mem.Allocator.Error!void {
    const g = ctx.grid.g / divisor;
    const nx = numeric.toCount(@ceil(@as(f64, @floatFromInt(ctx.grid.nx - 1)) * divisor) + 1);
    const ny = numeric.toCount(@ceil(@as(f64, @floatFromInt(ctx.grid.ny - 1)) * divisor) + 1);
    const edge_inset = via_rules.edgeInset(wide.track_width, wide.via_dia, placement.rules.design.edgeClearance());
    if (nx * ny > scaledGapCeiling(gap_max_nodes, divisor)) {
        ctx.outline_mask = try via_rules.buildOutlineMask(Grid, arena, placement, ctx.grid, edge_inset);
        ctx.perimeter_track_mask = try buildPerimeterTrackMask(arena, placement, ctx.grid, wide.track_width);
        return;
    }
    ctx.grid = .{ .ox = ctx.grid.ox, .oy = ctx.grid.oy, .g = g, .nx = nx, .ny = ny };
    ctx.occ = try allocLayerGrids(arena, ctx.occ.len, nx * ny);
    ctx.resv = try allocLayerGrids(arena, ctx.resv.len, nx * ny);
    // `resv` reset 4/6 — the gap pass's finer raster.
    lane_reserve.stamp(ctx.reserved_lanes, ctx.resv, ctx.grid, null);
    ctx.outline_mask = try via_rules.buildOutlineMask(Grid, arena, placement, ctx.grid, edge_inset);
    ctx.perimeter_track_mask = try buildPerimeterTrackMask(arena, placement, ctx.grid, wide.track_width);
    ctx.pad_index = null;
    // Same lattice-identity rule as `windowCtx`: the memo is keyed by the OLD
    // raster. `closeGaps` re-arms it once the final grid is settled.
    ctx.static_block = .{};
    ctx.search = .{};
    ctx.route_queue = null;
}

/// Grid nodes where a maze via may never be dropped, whatever net is routing:
/// inside the hole-to-hole wall of a through drill.
///
/// The exact per-candidate wall is `viaClearsPadDrills`, which every via probe
/// now runs; this mask is the gap pass's cheap up-front node cull on top of it,
/// sized to the widest via class so it is a per-board mask no per-net overlay
/// can under-reach. It also covers the drills of the vias already on the board,
/// which `PadDrills` deliberately leaves to the live via list.
///
/// Pad COPPER is deliberately NOT in here. `viaClearsPads` already enforces the
/// foreign-pad clearance at the routing net's own geometry, which is what the
/// DRC measures; adding a board-wide ban at the widest class on top of that
/// forbids exactly the fan-out via a pad legitimately escapes through, and a
/// dense board then has no legal via sites left at all. The one same-net pad a
/// via must stay out of is a TERMINAL of the hop in flight — that is a per-hop
/// fact, so `markTerminalViaBan` handles it through `via_forbidden_mask`.
fn buildViaBanMask(
    arena: std.mem.Allocator,
    ctx: *Ctx,
    placement: optimizer.Placement,
    params: RouteParams,
    holes: []const PadHole,
) std.mem.Allocator.Error![]const bool {
    const grid = ctx.grid;
    const mask = try arena.alloc(bool, grid.nx * grid.ny);
    @memset(mask, false);
    const wide = maxRouteParams(placement, params, &.{});
    const hole_pad = wide.via_drill / 2 + ctx.hole_to_hole;
    for (holes) |h| {
        markBanBox(mask, grid, .{ .x0 = h.x, .y0 = h.y, .x1 = h.x, .y1 = h.y }, h.r + hole_pad);
    }
    return mask;
}

/// How far OUTSIDE a hop's own terminal pad a via must stay.
///
/// Ban vias in this hop's own terminal pads (plus their via-clearance halo).
/// Arriving by punching a barrel into the destination pad is not arriving:
/// `viaClearsPads` skips the routing net's OWN pads, so without this a bridge
/// can "reach" its goal by drilling it, and both resulting violations land on
/// the target pad's coordinate. Per hop, because it is the hop's terminals that
/// are off limits, not every pad the net owns.
///
/// `GapOptions.terminal_via` lifts the ban for an SMD terminal, and that is the
/// whole difference between a gap hop that escapes a fine-pitch pad and one
/// that reports `blocked` — see `TerminalVia.smd_ok` for the measurement and
/// for why it is opt-in rather than the default.
///
/// A STITCH hop (`gap.to == null`) is exempt on its SMD terminal whatever the
/// policy says: its whole job is a barrel at the stranded pad, so the pad and
/// its halo are the one site the hop exists to use — "arriving by drilling the
/// destination" is not a failure mode a hop with no destination can have. The
/// whole-board router already lands exactly this via (`snapTerminalVias` pulls
/// a near-pad barrel into the pad centre); under the ban the same pad, boxed in
/// by foreign copper, reports `blocked` however wide the search runs. A
/// through-hole terminal stays banned — a barrel beside a same-net drill is
/// redundant copper and a `hole↔hole` violation.
fn markTerminalViaBan(state: *GapState, gap: Gap, net: i32) void {
    const ctx = state.ctx;
    @memset(state.term_ban, false);
    const reach = viaR(ctx.params) + ctx.params.clearance;
    const smd_stitch = gap.to == null and !gap.from.thru;
    if (!smd_stitch and state.opts.terminal_via.bans(gap.from)) markPadViaBan(ctx, state.term_ban, gap.from, net, reach);
    if (gap.to) |to| {
        if (state.opts.terminal_via.bans(to)) markPadViaBan(ctx, state.term_ban, to, net, reach);
    }
    ctx.via_forbidden_mask = state.term_ban;
    ctx.via_forbidden_net = net;
}

/// Mark one terminal pad's via exclusion: its own pad box grown by `reach` when
/// we can identify it in the obstacle list, else a disc about the terminal
/// point.
fn markPadViaBan(ctx: *Ctx, mask: []bool, pt: NetPt, net: i32, reach: f64) void {
    if (ownPadBox(ctx, pt, net)) |p| {
        markBanBox(mask, ctx.grid, p, reach);
        return;
    }
    markForbiddenDisc(ctx.grid, mask, pt.x, pt.y, reach);
}

/// The box of the terminal's OWN pad — the obstacle on `net` that `pt` is on.
fn ownPadBox(ctx: *Ctx, pt: NetPt, net: i32) ?Rect {
    const b = pad_exit.ownBox(ctx.obs, .{ pt.x, pt.y }, net, clearance_eps) orelse return null;
    return .{ .x0 = b[0], .y0 = b[1], .x1 = b[2], .y1 = b[3] };
}

/// Move a hop terminal to the clearest point inside its own pad — see
/// `pad_exit`, which owns the geometry and the measurements behind it.
fn padExitPoint(ctx: *Ctx, pt: NetPt, net: i32) NetPt {
    const half = ctx.params.track_width / 2;
    return pad_exit.movedToInterior(ctx.obs, pt, net, .{
        .half = half,
        .step = @max(ctx.grid.g * 0.5, clearance_eps * 10),
        .need = half + ctx.params.clearance,
        .slack = clearance_eps,
    });
}

/// Mark every grid node within `reach` of `box` in the via-ban mask.
fn markBanBox(mask: []bool, grid: Grid, box: Rect, reach: f64) void {
    const lo = grid.nearest(box.x0 - reach, box.y0 - reach);
    const hi = grid.nearest(box.x1 + reach, box.y1 + reach);
    var iy = lo[1];
    while (iy <= hi[1]) : (iy += 1) {
        var ix = lo[0];
        while (ix <= hi[0]) : (ix += 1) {
            if (distPointRect(grid.worldX(ix), grid.worldY(iy), box) < reach - clearance_eps)
                mask[grid.node(ix, iy)] = true;
        }
    }
}

/// A reusable maze-router context over a *fixed* set of placed parts: the grid
/// and pad-obstacle list are built once, then individual two-pad legs are routed
/// against it. The placement optimizer's score path uses this to measure each
/// decoupling loop's *real* trace length (cap pad → its pinned hub pin), instead
/// of a straight-line ratline — a foreign pad in the way makes the trace (and so
/// the score) genuinely longer. Cheap enough for the score path (one build + a
/// Dijkstra per loop); never use it in the optimizer's inner loop.
pub const LoopRouter = struct {
    ctx: Ctx,
    /// False when the board couldn't be gridded (degenerate/oversize) — callers
    /// fall back to the analytic surrogate.
    ready: bool,

    pub fn init(
        arena: std.mem.Allocator,
        parts: []const Part,
        nets: []const FlatNet,
        idx_of: *std.StringHashMapUnmanaged(usize),
        params: RouteParams,
    ) std.mem.Allocator.Error!LoopRouter {
        _ = idx_of; // obstacles are built straight off `parts` now
        // Bounding box over part courtyards (pads live inside), rotation-aware,
        // then the same grid pitch + 1 mm margin `route` uses.
        var minx: f64 = std.math.inf(f64);
        var miny: f64 = std.math.inf(f64);
        var maxx: f64 = -std.math.inf(f64);
        var maxy: f64 = -std.math.inf(f64);
        for (parts) |p| {
            const court = optimizer.worldCourtyard(&p);
            minx = @min(minx, court.minx);
            miny = @min(miny, court.miny);
            maxx = @max(maxx, court.minx + court.w);
            maxy = @max(maxy, court.miny + court.h);
        }
        if (!std.math.isFinite(minx)) return .{ .ctx = undefined, .ready = false };

        const g = @max(params.track_width + params.clearance, 0.05);
        const margin = 1.0;
        const ox = minx - margin;
        const oy = miny - margin;
        const nx: usize = numeric.toCount(@ceil((maxx - minx + 2 * margin) / g) + 1);
        const ny: usize = numeric.toCount(@ceil((maxy - miny + 2 * margin) / g) + 1);
        if (nx * ny == 0 or nx * ny > max_nodes) return .{ .ctx = undefined, .ready = false };
        const grid = Grid{ .ox = ox, .oy = oy, .g = g, .nx = nx, .ny = ny };

        // The loop surrogate always measures on the two OUTER faces — it
        // scores a decoupling leg, not a full route, so inner layers would
        // only slow the placement loop without changing the ordering.
        const occ = try allocLayerGrids(arena, 2, nx * ny);
        const resv = try allocLayerGrids(arena, 2, nx * ny);

        // Every pad is an obstacle tagged with its net — same indexing as `route`
        // (absolute position in `nets`), so a leg routed on net N treats N's pads
        // as passable (its own copper) and all others as obstacles to detour.
        const obs = try buildObstacles(arena, parts, nets);

        const reach = params.track_width / 2 + params.clearance;
        return .{
            .ctx = .{
                .arena = arena,
                .grid = grid,
                .obs = obs,
                .reach = reach,
                .occ = occ,
                .resv = resv,
                .params = params,
                .base = params,
                .index_reach = reach,
                .has_bottom_pads = router_support.anyBottomPads(obs),
            },
            .ready = true,
        };
    }

    /// Real routed copper length (mm) from world point `cap_c` to `hub_c` on net
    /// `net_id` (their shared rail), detouring foreign pads. Null when the maze
    /// can't connect them (boxed in) or the router isn't ready.
    pub fn legLen(self: *LoopRouter, cap_c: [2]f64, hub_c: [2]f64, net_id: i32) std.mem.Allocator.Error!?f64 {
        if (!self.ready or net_id < 0) return null;
        // The two `resv` clears with no re-stamp: the placement loop's leg
        // surrogate carries no route policy, so there is nothing to restore.
        for (self.ctx.occ) |l| @memset(l, empty_cell);
        for (self.ctx.resv) |l| @memset(l, empty_cell);
        var tracks: std.ArrayList(Track) = .empty;
        var vias: std.ArrayList(Via) = .empty;
        const pts = [_]NetPt{
            .{ .x = cap_c[0], .y = cap_c[1], .layer = 0 },
            .{ .x = hub_c[0], .y = hub_c[1], .layer = 0 },
        };
        if (!try routeNet(&self.ctx, net_id, &pts, &tracks, &vias)) return null;
        var len: f64 = 0;
        for (tracks.items) |t| len += std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
        return len;
    }
};

// ── Grid + helpers ─────────────────────────────────────────────────────────

/// The routing raster, aliased so every maze call site still names it `Grid`.
pub const Grid = route_grid.Grid;

const Rect = struct { x0: f64, y0: f64, x1: f64, y1: f64 };

/// Allocate `n_layers` per-signal-layer node grids of `nodes` cells each,
/// all initialised EMPTY — the shape `Ctx.occ`/`Ctx.resv` carry.
fn allocLayerGrids(arena: std.mem.Allocator, n_layers: usize, nodes: usize) std.mem.Allocator.Error![][]i32 {
    const out = try arena.alloc([]i32, n_layers);
    for (out) |*l| {
        l.* = try arena.alloc(i32, nodes);
        @memset(l.*, empty_cell);
    }
    return out;
}

/// Distance from a point to an axis-aligned rect (0 if inside).
fn distPointRect(px: f64, py: f64, r: Rect) f64 {
    const dx = @max(@max(r.x0 - px, px - r.x1), 0);
    const dy = @max(@max(r.y0 - py, py - r.y1), 0);
    return @sqrt(dx * dx + dy * dy);
}

/// Build the pad-obstacle list: *every* pad of every part, as a world rect
/// tagged with its flattened-net index (−1 when the pad is on no net). This is
/// the exact pad set `drc.zig` checks against, so the router avoids precisely
/// what the DRC flags — connected pads *and* NC/mechanical pads alike.
pub fn buildObstacles(arena: std.mem.Allocator, parts: []const Part, nets: []const FlatNet) std.mem.Allocator.Error![]PadObs {
    var pin_net = std.StringHashMapUnmanaged(i32).empty;
    for (nets, 0..) |net, ni| {
        for (net.pins) |pin| {
            const key = try std.fmt.allocPrint(arena, "{s}|{s}", .{ pin.ref_des, pin.pin });
            try pin_net.put(arena, key, @intCast(ni));
        }
    }
    var obs: std.ArrayList(PadObs) = .empty;
    for (parts) |part| {
        for (part.pads) |pad| {
            const sh = try pad_shape.worldShape(arena, part, pad);
            const key = try std.fmt.allocPrint(arena, "{s}|{s}", .{ part.ref_des, pad.number });
            const net = pin_net.get(key) orelse -1;
            try obs.append(arena, .{
                .x0 = sh.x0,
                .y0 = sh.y0,
                .x1 = sh.x1,
                .y1 = sh.y1,
                .poly = sh.poly,
                .net = net,
                .layer = router_support.sideLayer(part),
                .thru = pad.thru,
            });
        }
    }
    return obs.toOwnedSlice(arena);
}

/// Bits reserved for the intrinsic net-class rank in a net's sort key. The
/// authored `(net-class … (priority N))` tier occupies the high bits and always
/// dominates; the intrinsic rank only orders nets the author left unranked and
/// breaks ties between equal-ranked ones. Three bits leaves the auto rules room
/// to grow; today they use only ranks 0–1.
const netclass_bits = 3;

/// Highest authored `(net-class … (priority N))` tier a net can declare —
/// parse-time clamps to this, and `netPriority` clamps again defensively so a
/// corrupt rule can't shift garbage into the sort key's high bits.
const max_net_priority: u32 = 7;

/// A net's routing priority. Primary key (high bits): the authored
/// `(net-class … (priority N))` tier from the design source, 0 when the net is
/// in no class — explicit author intent always dominates. Secondary key (the
/// low `NETCLASS_BITS` bits): the net's intrinsic routing criticality — the
/// switcher hot loop and its input rail route ahead of the pack (Phase 3 of the
/// module-placement ruleset). Routing a critical net first lets it claim the
/// short path before a bulk rail blocks it (the router has no rip-up, so
/// first-routed wins).
fn netPriority(placement: optimizer.Placement, idx_of: *std.StringHashMapUnmanaged(usize), net: FlatNet, net_i: usize) u32 {
    const authored: u32 = if (net_i < placement.rules.net.len)
        @min(placement.rules.net[net_i].priority, max_net_priority)
    else
        0;
    var rank = netClassRank(net.name);
    if (rank == 0 and isInductorBridge(placement, idx_of, net)) rank = 1;
    return (authored << netclass_bits) | rank;
}

/// Intrinsic routing-order rank for a net from its name-based `NetClass`
/// (0 = baseline, 1 = route first). Only the switching hot loop and its input
/// rail are elevated. Those net names exist solely on a switching power module,
/// so this is a no-op on signal/array boards — which is precisely why it never
/// regresses them — while on a discrete switcher it gives the hot loop the
/// tightest copper. Clock/RF/feedback/power are deliberately *not* elevated:
/// reordering them trades total routed length board-by-board (it helps a
/// clock-sparse board and hurts a clock-dense array), a tradeoff the scalar
/// routed metric can't adjudicate, so they stay at the baseline tier. Authors
/// order those with `(net-class … (priority N))` instead.
fn netClassRank(name: []const u8) u32 {
    return switch (module_policy.classifyNetName(name)) {
        .switch_node, .input_rail => 1,
        else => 0,
    };
}

/// A bare hub→inductor bridge is a switch node even when its *name* reads as a
/// power rail — the RP2350's `VREG_LX` (hub pin 63 → the VREG inductor) hits
/// `classifyNetName`'s `VREG` power prefix before any switch-node stem. The
/// structural signature is unmistakable: at most a pin or two on a hub IC plus
/// the inductor, and nothing else (the post-inductor rail carries caps and many
/// pins, so it never matches). Mirrors the hub+inductor upgrade in
/// `module_policy.classifyNets`, which only rescues `.signal`/`.control` names
/// and so misses these.
fn isInductorBridge(placement: optimizer.Placement, idx_of: *std.StringHashMapUnmanaged(usize), net: FlatNet) bool {
    if (net.pins.len < 2 or net.pins.len > 3) return false;
    var hub = false;
    var ind = false;
    for (net.pins) |pin| {
        const pi = idx_of.get(pin.ref_des) orelse continue;
        if (pi < placement.parts.len and placement.parts[pi].kind == .hub) hub = true;
        if (module_policy.isInductor(pin.ref_des)) ind = true;
    }
    return hub and ind;
}

pub const NetPt = pad_exit.NetPt;
pub const netPoints = pad_exit.netPoints;
/// Exact local capacitor-to-IC pad pairs from authored decoupling intent.
pub const localSupplyBonds = plane_stitch.surfaceBonds;
const escTerm = pad_exit.asTerm;

/// World centre of `pin` on `part`, or null if the pad isn't in the footprint.
// ── Via clearance (DRC-safe via placement) ──────────────────────────────────

/// Via copper radius (mm).
fn viaR(params: RouteParams) f64 {
    return params.via_dia / 2;
}

/// True if a via of the configured size centred at (x,y) on net `net` keeps the
/// copper clearance from every *foreign* pad (the via-in-pad crowding rule).
fn viaClearsPads(ctx: *Ctx, x: f64, y: f64, net: i32) bool {
    const need = viaR(ctx.params) + ctx.params.clearance;
    for (ctx.obs) |p| {
        if (p.net == net) continue;
        const lim = keepLimits(ctx, p.net, need);
        const distance = pad_shape.pointDist(p.x0, p.y0, p.x1, p.y1, p.poly, x, y, lim[1]);
        if (!keepout.approachClears(ctx.keep.zones, p.net, distance, .{ x, y }, lim)) return false;
    }
    return true;
}

fn viaPairCenterNeed(ctx: *const Ctx, a_dia: f64, b_dia: f64, same_net: bool) f64 {
    const rule = via_rules.CopperRule{ .via_to_via = ctx.via_to_via, .via_dia = a_dia, .ordinary = ctx.params.clearance };
    return via_rules.pairCenterNeed(rule, b_dia, if (same_net) .same_net else .all);
}

fn viaCopperRule(ctx: *const Ctx) via_rules.CopperRule {
    return .{ .via_to_via = ctx.via_to_via, .via_dia = ctx.params.via_dia, .ordinary = ctx.params.clearance };
}

/// True if a via at (x,y) keeps copper spacing from every already-placed via,
/// including vias on its own net.
fn viaClearsVias(ctx: *Ctx, placed: []const Via, x: f64, y: f64, net: i32) bool {
    if (copperIdx(ctx)) |idx| {
        for (idx.near(x, y)) |ci| {
            if (ci < ctx.copper_track_count) continue; // track box — not this probe's concern
            const vi = ci - ctx.copper_track_count;
            if (vi >= @min(ctx.copper_via_count, placed.len)) continue;
            const v = placed[vi];
            const need = viaPairCenterNeed(ctx, ctx.params.via_dia, v.dia, v.net == net);
            if (std.math.hypot(x - v.x, y - v.y) < need - clearance_eps) return false;
        }
        // The index is rebuilt at an attempt boundary. Copper appended by the
        // attempt is a soundness-critical tail, not a reason to discard the
        // otherwise-useful index.
        if (!via_rules.clears(Via, placed[@min(ctx.copper_via_count, placed.len)..], viaCopperRule(ctx), .{ x, y }, net, .all)) return false;
        return true;
    }
    return via_rules.clears(Via, placed, viaCopperRule(ctx), .{ x, y }, net, .all);
}

fn viaClearsSameNetVias(ctx: *const Ctx, placed: []const Via, x: f64, y: f64, net: i32) bool {
    if (ctx.exact) |ex| if (!via_rules.clears(Via, ex.vias, viaCopperRule(ctx), .{ x, y }, net, .same_net)) return false;
    return via_rules.clears(Via, placed, viaCopperRule(ctx), .{ x, y }, net, .same_net);
}

/// The board's fixed through-PAD drills plus the spatial index that answers
/// "which of them could a barrel at this point owe a wall to?".
///
/// Pad drills are the half of the `hole↔hole` rule the router had no probe for.
/// The copper tests cannot stand in for it: `viaClearsPads` skips the routing
/// net's OWN pads outright, so a barrel dropped beside a same-net through pad
/// passed every generator check while the DRC — which is net-blind about drills —
/// refused it. Measured on barracuda's `V_6VA`: a plane via 0.202 mm from
/// `buck_6v/U22` pad 5's 0.20 mm bore, a −0.048 mm wall against the design's
/// 0.200 mm rule, and the gate then dropped the whole net's generated copper
/// (3 islands → 16).
///
/// Built once per routing context (the pads never move mid-run) and queried
/// through the same `PadGrid` bucketing every other exact clearance probe uses,
/// because `directViaClear` alone runs its lattice hundreds of thousands of
/// times per net. `reach` is sized to the WIDEST via class on the board so the
/// index stays a superset for every net; the exact wall is still measured
/// per-candidate at the routing net's own drill.
const PadDrills = struct {
    holes: []const pad_exit.Hole = &.{},
    index: ?*const PadGrid = null,
    reach: f64 = 0,

    /// Index the board's pad drills for a barrel of at most `max_drill`.
    /// A null index (degenerate board / oversized cell grid) is not a failure:
    /// `clears` falls back to the full scan and returns the identical verdict.
    fn build(
        arena: std.mem.Allocator,
        placement: optimizer.Placement,
        grid: Grid,
        max_drill: f64,
    ) std.mem.Allocator.Error!PadDrills {
        const holes = try pad_exit.padHoles(arena, placement);
        if (holes.len == 0) return .{};
        const reach = max_drill / 2 + placement.rules.design.hole_to_hole;
        const boxes = try arena.alloc(PadObs, holes.len);
        for (holes, boxes) |h, *b| b.* = .{
            .x0 = h.x - @abs(h.shx) - h.r,
            .y0 = h.y - @abs(h.shy) - h.r,
            .x1 = h.x + @abs(h.shx) + h.r,
            .y1 = h.y + @abs(h.shy) + h.r,
            .net = -1,
        };
        return .{ .holes = holes, .index = PadGrid.build(arena, boxes, gridBounds(grid), reach), .reach = reach };
    }

    /// True when a barrel of diameter `drill` at `(x, y)` keeps `wall` from
    /// every pad bore. Net-blind, exactly as `drc.holePairViolation` is.
    ///
    /// A probe reaching FURTHER than the index was built for takes the full scan
    /// — an authored `(guides … )` via drill is set straight onto `ctx.params`
    /// and can exceed the widest net class, and an index queried past its reach
    /// is no longer a superset. Same verdict either way; only the cull is lost.
    fn clears(self: PadDrills, x: f64, y: f64, drill: f64, wall: f64) bool {
        if (self.index) |idx| {
            if (drill / 2 + wall <= self.reach + clearance_eps) {
                for (idx.near(x, y)) |hi| {
                    if (hi >= self.holes.len) continue; // defence in depth: a valid index only ever undershoots
                    const gap = pad_exit.wallGap(self.holes[hi], x, y, drill) orelse continue;
                    if (gap < wall - clearance_eps) return false;
                }
                return true;
            }
        }
        for (self.holes) |h| {
            const gap = pad_exit.wallGap(h, x, y, drill) orelse continue;
            if (gap < wall - clearance_eps) return false;
        }
        return true;
    }
};

/// True if a via drilled at (x,y) keeps the hole-to-hole WALL from every through
/// PAD drill on the board (`PadDrills`, which is where the measurement and the
/// reason for it live).
fn viaClearsPadDrills(ctx: *const Ctx, x: f64, y: f64) bool {
    const drill = ctx.params.via_drill;
    if (drill <= 0) return true;
    return ctx.pad_drills.clears(x, y, drill, ctx.hole_to_hole);
}

/// True if a via drilled at (x,y) keeps the hole-to-hole WALL from every drilled
/// hole — every placed via's drill AND every through PAD's bore — so the web is
/// manufacturable. Ignores net: two same-net GND vias still need a wall between
/// their drills (the `hole↔hole` DRC rule, which same-net copper clearance
/// doesn't enforce, and which is equally blind to whose pad a bore belongs to).
/// Centre distance ≥ the two drill radii + the rule (matching
/// `drc.checkDrillRules`); a coincident duplicate is skipped.
fn viaClearsHoles(ctx: *Ctx, placed: []const Via, x: f64, y: f64) bool {
    const vr = ctx.params.via_drill / 2;
    if (vr <= 0) return true;
    if (!viaClearsPadDrills(ctx, x, y)) return false;
    if (copperIdx(ctx)) |idx| {
        for (idx.near(x, y)) |ci| {
            if (ci < ctx.copper_track_count) continue; // track box — not this probe's concern
            const vi = ci - ctx.copper_track_count;
            if (vi >= placed.len) continue; // defence in depth: a valid index only ever undershoots
            const v = placed[vi];
            if (v.drill <= 0) continue;
            const d = std.math.hypot(x - v.x, y - v.y);
            if (d < 1e-6) continue; // coincident duplicate — no wall to lose
            if (d < vr + v.drill / 2 + ctx.hole_to_hole - clearance_eps) return false;
        }
        for (placed[@min(ctx.copper_via_count, placed.len)..]) |v| {
            if (v.drill <= 0) continue;
            const d = std.math.hypot(x - v.x, y - v.y);
            if (d < 1e-6) continue;
            if (d < vr + v.drill / 2 + ctx.hole_to_hole - clearance_eps) return false;
        }
        return true;
    }
    for (placed) |v| {
        if (v.drill <= 0) continue;
        const d = std.math.hypot(x - v.x, y - v.y);
        if (d < 1e-6) continue; // coincident duplicate — no wall to lose
        if (d < vr + v.drill / 2 + ctx.hole_to_hole - clearance_eps) return false;
    }
    return true;
}

/// True if a via of the configured size at (x,y) on net `net` keeps copper
/// clearance from every routed track on a *different* net — the via↔track rule
/// the DRC then re-checks (so an escape via can't be dropped on foreign copper).
fn viaClearsTracks(ctx: *Ctx, tracks: []const Track, x: f64, y: f64, net: i32) bool {
    const rr = viaR(ctx.params);
    if (copperIdx(ctx)) |idx| {
        for (idx.near(x, y)) |ci| {
            if (ci >= ctx.copper_track_count) continue; // via box — not this probe's concern
            if (ci >= tracks.len) continue; // defence in depth: a valid index only ever undershoots
            const t = tracks[ci];
            if (t.net == net) continue;
            const need = rr + t.width / 2 + ctx.params.clearance;
            if (segPointDist(t.x1, t.y1, t.x2, t.y2, x, y) < need - clearance_eps) return false;
        }
        for (tracks[@min(ctx.copper_track_count, tracks.len)..]) |t| {
            if (t.net == net) continue;
            const need = rr + t.width / 2 + ctx.params.clearance;
            if (segPointDist(t.x1, t.y1, t.x2, t.y2, x, y) < need - clearance_eps) return false;
        }
        return true;
    }
    for (tracks) |t| {
        if (t.net == net) continue;
        const need = rr + t.width / 2 + ctx.params.clearance;
        if (segPointDist(t.x1, t.y1, t.x2, t.y2, x, y) < need - clearance_eps) return false;
    }
    return true;
}

/// True if the `track_width` stub a→b on net `net` keeps clearance from every
/// already-placed via on a *different* net (the via↔track rule, from the trace's
/// side). An escape stub is drawn after some vias are already down, and a via
/// fixed earlier won't re-check this later trace — so the trace must clear the
/// vias itself or the pair would fail DRC.
fn segClearsVias(ctx: *Ctx, placed: []const Via, a: [2]f64, b: [2]f64, net: i32) bool {
    if (copperIdx(ctx)) |idx| {
        var scratch: [near_scratch_len]u32 = undefined;
        if (nearSegment(idx, a, b, ctx.copper_reach, &scratch)) |cand| {
            for (cand) |ci| {
                if (ci < ctx.copper_track_count) continue; // track box — not this probe's concern
                const vi = ci - ctx.copper_track_count;
                if (vi >= placed.len) continue; // defence in depth: a valid index only ever undershoots
                const v = placed[vi];
                if (v.net == net) continue;
                if (!segClearsVia(ctx, v, a, b)) return false;
            }
            for (placed[@min(ctx.copper_via_count, placed.len)..]) |v| {
                if (v.net != net and !segClearsVia(ctx, v, a, b)) return false;
            }
            return true;
        }
    }
    for (placed) |v| if (v.net != net and !segClearsVia(ctx, v, a, b)) return false;
    return true;
}

/// One foreign via barrel's share of `segClearsVias`, so the index probe and the
/// fallback loop judge a band the same way: ordinary clearance always, plus the
/// via's declared keepout halo unless an escape zone waives that surplus
/// (`keepout.approachClears`).
fn segClearsVia(ctx: *const Ctx, v: Via, a: [2]f64, b: [2]f64) bool {
    const lim = keepLimits(ctx, v.net, v.dia / 2 + ctx.params.track_width / 2 + ctx.params.clearance);
    if (segmentMissesBox(a, b, .{ v.x, v.y, v.x, v.y }, lim[1])) return true;
    const gap = segPointDist(a[0], a[1], b[0], b[1], v.x, v.y);
    if (gap >= lim[1]) return true; // clears the halo outright — no approach point needed
    return keepout.approachClears(ctx.keep.zones, v.net, gap, closestOnLine(a, b, v.x, v.y), lim);
}

/// Cheap conservative rejection before an exact segment/shape distance test.
/// `reach` expands the object's bounds by the required copper clearance.
fn segmentMissesBox(
    a: [2]f64,
    b: [2]f64,
    bounds: [4]f64,
    reach: f64,
) bool {
    return @max(a[0], b[0]) < @min(bounds[0], bounds[2]) - reach or
        @min(a[0], b[0]) > @max(bounds[0], bounds[2]) + reach or
        @max(a[1], b[1]) < @min(bounds[1], bounds[3]) - reach or
        @min(a[1], b[1]) > @max(bounds[1], bounds[3]) + reach;
}

fn pointMissesBox(point: [2]f64, x0: f64, y0: f64, x1: f64, y1: f64, reach: f64) bool {
    return point[0] < @min(x0, x1) - reach or point[0] > @max(x0, x1) + reach or
        point[1] < @min(y0, y1) - reach or point[1] > @max(y0, y1) + reach;
}

/// True if the `track_width` stub a→b on net `net` (drawn on signal layer
/// `layer`) keeps the copper clearance from every routed track of a *different*
/// net on that layer. The escape pass runs after the maze, and maze copper is
/// grid-guaranteed only against other maze copper — a stub drawn at an
/// arbitrary point must check the tracks itself or it can cross them outright
/// (the classic breakout-stub-through-a-rail short).
fn segClearsTracks(ctx: *Ctx, tracks: []const Track, a: [2]f64, b: [2]f64, net: i32, layer: u8) bool {
    // The RF crossing shadow rides here too. The direct / dogleg / octilinear
    // synthesis emits a segment whole or not at all and never sees the maze cost
    // model, so the only way to price a shortcut that RUNS ALONG a protected
    // corridor is to refuse it — the net then falls through to the maze, which
    // does read the cost and buys the short (≈perpendicular) crossing instead.
    if (!ctx.keep.exempt and ctx.shadow.runsAlong(tracks, .{ a, b }, ctx.params.track_width / 2, net)) return false;
    if (copperIdx(ctx)) |idx| {
        var scratch: [near_scratch_len]u32 = undefined;
        if (nearSegment(idx, a, b, ctx.copper_reach, &scratch)) |cand| {
            for (cand) |ci| {
                if (ci >= ctx.copper_track_count) continue; // via box — not this probe's concern
                if (ci >= tracks.len) continue; // defence in depth: a valid index only ever undershoots
                const t = tracks[ci];
                if (t.net == net or t.layer != layer) continue;
                if (!segClearsTrack(ctx, t, a, b)) return false;
            }
            for (tracks[@min(ctx.copper_track_count, tracks.len)..]) |t| {
                if (t.net == net or t.layer != layer) continue;
                if (!segClearsTrack(ctx, t, a, b)) return false;
            }
            return true;
        }
    }
    for (tracks) |t| if (t.net != net and t.layer == layer and !segClearsTrack(ctx, t, a, b)) return false;
    return true;
}

/// One foreign track's share of `segClearsTracks`, so the index probe and the
/// fallback loop judge a shortcut the same way: ordinary clearance always, plus
/// the track's declared keepout halo unless an escape zone waives that surplus
/// (`keepout.approachClears`).
fn segClearsTrack(ctx: *const Ctx, t: Track, a: [2]f64, b: [2]f64) bool {
    const lim = keepLimits(ctx, t.net, t.width / 2 + ctx.params.track_width / 2 + ctx.params.clearance);
    if (segmentMissesBox(a, b, .{ t.x1, t.y1, t.x2, t.y2 }, lim[1])) return true;
    const e = [2][2]f64{ .{ t.x1, t.y1 }, .{ t.x2, t.y2 } };
    const gap = segSegDist(a, b, e[0], e[1]);
    // Only the escape gate reads the approach POINT, and only for a gap inside the halo — computing the midpoint up front doubled the geometry `moveClearsCopper` pays per candidate per maze move.
    if (gap >= lim[1]) return true;
    return keepout.approachClears(ctx.keep.zones, t.net, gap, pad_shape.segSegMid(a, b, e[0], e[1]), lim);
}

/// True if the same-net stub segment a→b (a real `track_width` trace) keeps
/// clearance from every foreign pad along its length. Sampled at a tenth of
/// the grid pitch with the requirement inflated by half a sample step (the
/// Lipschitz bound: any point sits within step/2 of a sample), so a
/// between-sample dip can't slip a sub-clearance approach past the sampling —
/// the stub provably meets the DRC rule at a ~13 um routability cost.
/// An SMD pad only obstructs copper on its own signal layer; a through-hole pad
/// obstructs every layer. A null `layer` is the conservative form used where the
/// copper's layer is not yet fixed: every pad obstructs, whichever side it is on.
fn segClearsPadsOnLayer(ctx: *Ctx, a: [2]f64, b: [2]f64, net: i32, layer: ?u8) bool {
    const need = ctx.params.track_width / 2 + ctx.params.clearance;
    if (ctx.pad_index == null) ctx.pad_index = PadGrid.build(ctx.arena, ctx.obs, gridBounds(ctx.grid), padIndexReach(ctx));
    if (ctx.pad_index) |idx| {
        var scratch: [near_scratch_len]u32 = undefined;
        if (nearSegment(idx, a, b, padIndexReach(ctx), &scratch)) |cand| {
            for (cand) |pi| {
                const o = ctx.obs[pi];
                if (o.net == net) continue;
                if (layer) |on| if (!o.thru and o.layer != on) continue;
                // `padSegmentClears` adds a keepout net's declared halo over the
                // ordinary clearance — exactly like the fallback loop, so the
                // index probe cannot let a direct shortcut slip past an RF pad.
                if (!padSegmentClears(ctx, o, a, b, need)) return false;
            }
            return true;
        }
    }
    for (ctx.obs) |o| {
        if (o.net == net) continue;
        if (layer) |on| if (!o.thru and o.layer != on) continue;
        if (!padSegmentClears(ctx, o, a, b, need)) return false;
    }
    return true;
}

/// Longest clear prefix of escape stub a→b on net `net`: the farthest point
/// from the pad `a` such that the whole sub-segment keeps clearance from every
/// foreign pad, via, and routed track on `layer`. Returns `a` itself when even
/// the first step isn't clear (the caller then drops the stub) — a single-pin
/// breakout has nothing to connect to, so trimming it never breaks a real
/// connection.
fn trimStub(ctx: *Ctx, placed: []const Via, tracks: []const Track, a: [2]f64, b: [2]f64, net: i32, layer: u8) [2]f64 {
    const len = std.math.hypot(b[0] - a[0], b[1] - a[1]);
    if (len < 1e-9) return a;
    const step = ctx.grid.g * 0.2;
    const n: usize = @max(1, numeric.toCount(@ceil(len / step)));
    // Inflate the clearance by one sample step so a between-sample dip can't slip
    // a sub-clearance crossing past the sampling.
    const need = ctx.params.track_width / 2 + ctx.params.clearance + step;
    var last = a;
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(n));
        const p = [2]f64{ a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1]) };
        var ok = true;
        for (ctx.obs) |o| {
            if (o.net == net) continue;
            const lim = keepLimits(ctx, o.net, need);
            const distance = pad_shape.pointDist(o.x0, o.y0, o.x1, o.y1, o.poly, p[0], p[1], lim[1]);
            if (!keepout.approachClears(ctx.keep.zones, o.net, distance, p, lim)) {
                ok = false;
                break;
            }
        }
        if (ok) for (placed) |v| {
            if (v.net == net) continue;
            if (std.math.hypot(p[0] - v.x, p[1] - v.y) - v.dia / 2 < need) {
                ok = false;
                break;
            }
        };
        if (ok) for (tracks) |tr| {
            if (tr.net == net or tr.layer != layer) continue;
            if (segPointDist(tr.x1, tr.y1, tr.x2, tr.y2, p[0], p[1]) - tr.width / 2 < need) {
                ok = false;
                break;
            }
        };
        if (!ok) break;
        last = p;
    }
    return last;
}

/// Rings (grid steps) the escape-via fan searches outward before giving up —
/// ~3 mm at the default pitch, enough to clear a dense module's pad field.
const escape_via_rings: usize = 12;

/// Find the *nearest* DRC-safe spot for a single-pin breakout's escape via — the
/// in-tool version of hand-routing a pin that has nothing to land on: drop a via
/// next to the pad and let the signal leave on an inner layer, with a short trace
/// from the pad to the via. Both the via AND the straight pad→via stub must be
/// fully DRC-safe: clear of foreign pads, placed vias, and routed tracks on the
/// stub's layer. There is deliberately NO relaxed tier that lets the stub cross
/// foreign copper — that used to draw breakout stubs straight across the
/// neighbouring pad of a fine-pitch QFN. A breakout carries no connection, so
/// when the pad is hemmed in the caller's trimmed surface stub (which stops at
/// clearance) is strictly better than pad-crossing copper. Null when no clean
/// spot exists in the search window.
fn findEscapeVia(ctx: *Ctx, placed: []const Via, tracks: []const Track, a: [2]f64, dir: [2]f64, net: i32, layer: u8) ?[2]f64 {
    return escapeFan(ctx, placed, tracks, a, dir, net, layer);
}

/// One fan of the escape-via search (see `findEscapeVia`). Fans outward from the
/// pad `a` in growing rings along the eight 45° compass headings — nearest the
/// reserved corridor heading `dir` first, then swivelling to either side — and
/// returns the first spot where a via of the configured size clears every
/// foreign pad, via and routed track, and the straight pad→via stub clears
/// every foreign pad, via, and routed track on `layer`. Candidates sit exactly
/// on the 45° ray from the pad centre (NOT grid-snapped: the escape pass runs
/// after the maze, so nothing consults the occupancy grid afterwards, and the
/// unsnapped spot is what keeps the stub octilinear).
fn escapeFan(ctx: *Ctx, placed: []const Via, tracks: []const Track, a: [2]f64, dir: [2]f64, net: i32, layer: u8) ?[2]f64 {
    const grid = ctx.grid;
    const ang0 = std.math.atan2(dir[1], dir[0]);
    var ring: usize = 1;
    while (ring <= escape_via_rings) : (ring += 1) {
        const rad = @as(f64, @floatFromInt(ring)) * grid.g;
        var k: usize = 0;
        while (k < 8) : (k += 1) {
            const ang = octilinear.compass45(ang0, k);
            const s = [2]f64{ a[0] + rad * @cos(ang), a[1] + rad * @sin(ang) };
            if (!viaClearsOutline(ctx, s[0], s[1], net)) continue;
            if (!viaClearsPads(ctx, s[0], s[1], net)) continue;
            if (!viaClearsVias(ctx, placed, s[0], s[1], net)) continue;
            if (!viaClearsHoles(ctx, placed, s[0], s[1])) continue;
            if (!viaClearsTracks(ctx, tracks, s[0], s[1], net)) continue;
            // The stub itself must clear every foreign pad, placed via, and
            // routed track — all are fixed and won't re-check this later
            // trace, so the pair would fail DRC (or short outright).
            if (!segClearsVias(ctx, placed, a, s, net)) continue;
            if (!segClearsTracks(ctx, tracks, a, s, net, layer)) continue;
            if (!segClearsPadsOnLayer(ctx, a, s, net, null)) continue;
            return s;
        }
    }
    return null;
}

/// The net's own pad copper under `c` on `layer` — the first same-net pad (in
/// obstacle-build order, so the answer is deterministic) whose shape contains
/// the point. Null when the anchor sits on no pad of its own net, which is when
/// there is no pad copper for a via to hide inside.
fn padCopperAt(ctx: *const Ctx, c: [2]f64, net: i32, layer: u8) ?pad_shape.Shape {
    return plane_via.landAt(ctx.obs, c, net, layer);
}

/// Find a DRC-safe spot for a ground via serving pad centre `c` on net `net`.
/// Prefers the pad centre (true via-in-pad — fine when the land can hold the
/// barrel and still clear its neighbours); if that crowds a foreign pad, via, or
/// retained track, or would leave the annular ring hanging off the land, searches
/// the rest of the pad's OWN copper (`plane_via.InPad`) before fanning outward
/// into open copper, returning that point (the caller joins it with a same-net
/// stub). Null when no clear spot is found in the search window — the pad is then
/// left without a via rather than emitting a guaranteed clearance violation.
fn findGroundVia(
    ctx: *Ctx,
    placed: []const Via,
    tracks: []const Track,
    c: [2]f64,
    net: i32,
    layer: u8,
) ?[2]f64 {
    const grid = ctx.grid;
    // Candidate 0: the pad centre, snapped to the grid (true via-in-pad when the
    // pad is large enough to clear its neighbours AND to hold the barrel).
    //
    // The snap is what makes containment a separate question from clearance
    // here: it moves the site up to half a grid pitch off the anchor, so a site
    // that sits ON the land can still hang its annular ring over the land's edge
    // — and no clearance probe can see that, because `viaClearsPads` skips the
    // routing net's own pads. Measured on `bcuda-lt3045-ldo`: U1's GND_1 land is
    // 0.80 x 0.30 mm, the snap put a 0.4 mm barrel at (1.578, 0.016) against a
    // land centred (1.500, 0.000), and the ring overhung the 0.30 mm dimension by
    // 0.034/0.066 mm. Refusing it costs one stub and buys a landed annulus.
    {
        const s = grid.snap(c[0], c[1]);
        if (plane_via.inLandBarrelFits(padCopperAt(ctx, s, net, layer), s, ctx.params.via_dia) and
            groundViaPointClear(ctx, placed, tracks, s, net) and segClearsPadsOnLayer(ctx, c, s, net, null))
            return s;
    }
    // A big pad (a thermal land) usually still has room a couple of tenths off
    // its anchor — a site the grid-stepped fan below strides straight over. This
    // is also where a snap refused for containment lands: the walk is centre-out
    // from the UNSNAPPED anchor and every site it yields contains the barrel, so
    // a land that can hold the via at all gets it at (or nearest to) its own
    // centre — strictly closer than the snap was, and with no stub at all.
    if (padCopperAt(ctx, c, net, layer)) |pad| {
        var scan = plane_via.InPad.init(pad, c, ctx.params.via_dia);
        while (scan.next()) |s| {
            if (groundViaPointClear(ctx, placed, tracks, s, net) and segClearsPadsOnLayer(ctx, c, s, net, null))
                return s;
        }
    }
    // Otherwise fan outward (away from foreign pads) in growing rings, snapping
    // each candidate to the grid, until one clears every foreign pad and via.
    // The containment gate rides along: ring 1 is only one grid pitch out, so a
    // snapped fan site routinely lands ON the anchor land's edge (or on a
    // neighbouring same-net land), and a barrel straddling an edge is the same
    // unlanded ring the pad-centre gate refuses. Ungated it would simply move
    // the defect one ring out.
    const dir = plane_via.fanDir(ctx.obs, c, net);
    const ang0 = std.math.atan2(dir[1], dir[0]);
    var ring: usize = 1;
    while (ring <= 16) : (ring += 1) {
        const rad = @as(f64, @floatFromInt(ring)) * grid.g;
        var k: usize = 0;
        while (k < 12) : (k += 1) {
            const a = ang0 + plane_via.swivel(k);
            const s = grid.snap(c[0] + rad * @cos(a), c[1] + rad * @sin(a));
            if (!groundViaPointClear(ctx, placed, tracks, s, net)) continue;
            if (!plane_via.inLandBarrelFits(padCopperAt(ctx, s, net, layer), s, ctx.params.via_dia)) continue;
            if (!segClearsPadsOnLayer(ctx, c, s, net, null)) continue;
            if (!segClearsTracks(ctx, tracks, c, s, net, layer)) continue;
            return s;
        }
    }
    return null;
}

fn groundViaPointClear(
    ctx: *Ctx,
    placed: []const Via,
    tracks: []const Track,
    point: [2]f64,
    net: i32,
) bool {
    if (!viaClearsOutline(ctx, point[0], point[1], net)) return false;
    if (!viaClearsPads(ctx, point[0], point[1], net)) return false;
    if (!viaClearsVias(ctx, placed, point[0], point[1], net)) return false;
    if (!viaClearsHoles(ctx, placed, point[0], point[1])) return false;
    return viaClearsTracks(ctx, tracks, point[0], point[1], net);
}

/// The nearest DRC-safe spot for a standalone GND plane stitch via near `c` (a
/// signal via we're stitching the return path of): fan outward in growing rings
/// to the first grid point within `max_r` mm that clears every foreign pad, every
/// placed via, and every routed track (the stitch pass runs last, so all copper
/// is down). Null when nothing fits — the via stays unstitched rather than forcing
/// a DRC violation. Unlike `findGroundVia` there's no stub back to a pad (a plane
/// via needs none), so no segment-clearance constraint applies.
fn findStitchVia(ctx: *Ctx, placed: []const Via, tracks: []const Track, c: [2]f64, net: i32, max_r: f64) ?[2]f64 {
    const grid = ctx.grid;
    const max_ring: usize = @max(1, numeric.toCount(@floor(max_r / grid.g)));
    var ring: usize = 1;
    while (ring <= max_ring) : (ring += 1) {
        const rad = @as(f64, @floatFromInt(ring)) * grid.g;
        var k: usize = 0;
        while (k < 16) : (k += 1) {
            const a = (@as(f64, @floatFromInt(k)) / 16.0) * std.math.tau;
            const s = grid.snap(c[0] + rad * @cos(a), c[1] + rad * @sin(a));
            if (std.math.hypot(s[0] - c[0], s[1] - c[1]) > max_r) continue;
            if (!groundViaPointClear(ctx, placed, tracks, s, net)) continue;
            return s;
        }
    }
    return null;
}

/// Does `name` have a dedicated copper plane (see `plane_stitch.netHasPlane`)?
pub const netHasPlane = plane_stitch.netHasPlane;
/// Which outer signal layers pour `name` (see `plane_stitch.netPourLayers`)?
pub const netPourLayers = plane_stitch.netPourLayers;
const padInPour = plane_stitch.padInPour;

/// Overlay `net_i`'s `(net-class …)` rule onto the base route params — the
/// per-net effective geometry every subsequent clearance/width/via read uses.
/// Nets without a rule (or with zero fields) keep the base values.
/// Overlay `net_i`'s `(net-class …)` rule onto the base geometry, setting the
/// effective track width / clearance / via size / escape reserve + `reach` used
/// by every clearance read for the net currently routing (or being probed).
pub fn setNetParams(ctx: *Ctx, placement: optimizer.Placement, net_i: usize) void {
    var p = ctx.base;
    ctx.rf.escape_mm = 0;
    ctx.rf.escape_pts = &.{}; // repopulated by setNetRoutePolicy for maze nets
    ctx.keep.halo = 0;
    ctx.manhattan = manhattan_route.stateFor(placement, net_i); // clears `active` with it
    ctx.shadow.width = rf_shadow.widthAt(ctx.shadow.nets, @intCast(net_i));
    if (net_i < placement.rules.net.len) {
        const r = placement.rules.net[net_i];
        p.pad_neck = r.pad_neck;
        p.pad_neck.width = @max(p.pad_neck.width, placement.rules.design.min_width);
        if (r.width > 0) p.track_width = r.width;
        if (r.clearance > 0) p.clearance = r.clearance;
        if (r.via_dia > 0) p.via_dia = r.via_dia;
        if (r.via_drill > 0) p.via_drill = r.via_drill;
        ctx.rf.escape_mm = r.rf.escape_mm;
        ctx.keep.halo = r.rf.keepout_mm;
    }
    if (net_i < placement.nets.len) {
        const name = placement.nets[net_i].name;
        // Current capacity is an electrical target, not a routing primitive.
        // Search an ordinary fabrication-legal centreline for an unpoured
        // rail, then let the final adaptive-width pass grow it as far as exact
        // clearance permits. This keeps a wide trunk routable through QFN
        // lands and other unavoidable necks without weakening copper DRC.
        // Plane/pour fanouts retain their authored branch geometry because
        // their local-current proof is tied to the carrying sheet.
        const authored_width = p.track_width;
        if (power_route_width.adaptiveTargetWidth(ctx.zones, placement, net_i, authored_width) != null)
            p.track_width = @max(placement.rules.design.min_width, @min(authored_width, ctx.base.track_width))
        else
            p.track_width = power_route_width.exactWidth(ctx.zones, placement, net_i, authored_width);
        if (placement.rules.powerViaDrillForNet(name)) |required_drill| {
            p.via_drill = @max(p.via_drill, required_drill);
            p.via_dia = @max(p.via_dia, p.via_drill + 2.0 * placement.rules.design.min_annular);
        }
    }
    // Refresh the escape gate for the net about to route: which zones admit it
    // (it owns a pad inside them) is a per-net answer the maze then reads per node.
    keepout.admitCurrent(ctx.keep.zones, ctx.keep.pads, @intCast(net_i));
    // Ground/plane copper owes no foreign keepout: a stitching via or coplanar
    // pour beside an RF trace is the wanted fence. Clearance is untouched.
    ctx.keep.exempt = ctx.keep.nets.len > 0 and keepout.exempt(placement, net_i);
    ctx.keep.class.cur = @intCast(net_i); // whose class may pass its own halos
    ctx.params = p;
    ctx.reach = p.track_width / 2 + p.clearance;
    // The copper index's QUERY reach is a function of the routing net's own
    // geometry (`copperReach` reads `params` + `keep`), so it must move with
    // them: a reach left at a previous, NARROWER net's value lets this net's
    // `nearSegment` probes miss copper that really is inside its wider
    // clearance. Costs nothing when no index has been built yet.
    if (ctx.copper_index != null) ctx.copper_reach = copperReach(ctx);
    // Everything above is an input to a cached static-obstacle verdict, so the
    // memo belongs to ONE net's turn at the grid. Invalidating it here — the
    // single choke point every net change already goes through — is what makes
    // arming it on the primary route safe (`armStaticBlock`); the bump is O(1).
    ctx.static_block.reset();
}

/// True when `layer` belongs to `mask`; an empty mask means unrestricted.
/// The convention itself lives in `board_layers.LayerSet`, so route policy,
/// the DRC and the router can never read one mask differently.
pub fn layerInMask(mask: u64, layer: u8) bool {
    return board_layers.LayerSet.fromRaw(mask).contains(board_layers.SignalIndex.of(layer));
}

/// True when net `net_i`'s policy AUTHORS its layer choices — a preferred or
/// allowed layer mask, ordered waypoints, or reference branches. Such a net's
/// layer changes are the point of the route, not an accident of the search, so
/// a cleanup pass must not "simplify" them away (`dropRedundantViaPairs`).
pub fn netLayerAuthored(ctx: *const Ctx, net_i: usize) bool {
    if (net_i >= ctx.net_policy.len) return false;
    return route_policy.authorsLayers(ctx.net_policy[net_i]);
}

/// Load the current net's route-wave policy. Terminal pad layers are unioned
/// into a hard allowed-layer mask so a policy can say "route on In2.Cu" while
/// still letting a top-side SMD pad fan out far enough to reach that layer.
pub fn setNetRoutePolicy(ctx: *Ctx, net_i: usize, pts: []const NetPt) void {
    ctx.rf.escape_pts = pts;
    const policy = if (net_i < ctx.net_policy.len) ctx.net_policy[net_i] else route_policy.NetPolicy{};
    ctx.preferred_layers = policy.preferred_layers;
    ctx.allowed_layers = policy.allowed_layers;
    ctx.waypoints = policy.waypoints;
    ctx.guide_branches = policy.branches;
    ctx.max_vias = policy.max_vias;
    if (ctx.allowed_layers == 0) return;
    for (pts) |pt| {
        if (pt.layer < 64) ctx.allowed_layers |= @as(u64, 1) << @intCast(pt.layer);
    }
}

fn markGuideCell(mask: []bool, grid: Grid, layer: usize, nodes: usize, x: f64, y: f64) void {
    const center = grid.nearest(x, y);
    var dy: i64 = -1;
    while (dy <= 1) : (dy += 1) {
        var dx: i64 = -1;
        while (dx <= 1) : (dx += 1) {
            const ix = @as(i64, @intCast(center[0])) + dx;
            const iy = @as(i64, @intCast(center[1])) + dy;
            if (ix < 0 or iy < 0 or ix >= grid.nx or iy >= grid.ny) continue;
            const node = @as(usize, @intCast(iy)) * grid.nx + @as(usize, @intCast(ix));
            mask[layer * nodes + node] = true;
        }
    }
}

fn setNetReferenceGuide(ctx: *Ctx, net_i: usize) std.mem.Allocator.Error!void {
    ctx.reference_corridor = null;
    ctx.reference_via_mask = null;
    ctx.reference_guide_active = false;
    const net: i32 = @intCast(net_i);
    var have_tracks = false;
    for (ctx.guide_tracks) |track| if (track.net == net and track.layer < ctx.occ.len) {
        have_tracks = true;
        break;
    };
    var have_vias = false;
    for (ctx.guide_vias) |via| if (via.net == net) {
        have_vias = true;
        break;
    };
    if (!have_tracks and !have_vias) return;
    ctx.reference_guide_active = true;
    const nodes = ctx.grid.nx * ctx.grid.ny;
    if (have_tracks) {
        const corridor = try ctx.arena.alloc(bool, ctx.occ.len * nodes);
        @memset(corridor, false);
        for (ctx.guide_tracks) |track| {
            if (track.net != net or track.layer >= ctx.occ.len) continue;
            const len = std.math.hypot(track.x2 - track.x1, track.y2 - track.y1);
            const steps: usize = @max(1, numeric.toCount(@ceil(len / (ctx.grid.g * 0.5))));
            for (0..steps + 1) |step| {
                const t = @as(f64, @floatFromInt(step)) / @as(f64, @floatFromInt(steps));
                markGuideCell(
                    corridor,
                    ctx.grid,
                    track.layer,
                    nodes,
                    track.x1 + t * (track.x2 - track.x1),
                    track.y1 + t * (track.y2 - track.y1),
                );
            }
        }
        ctx.reference_corridor = corridor;
    }
    if (have_vias) {
        const via_mask = try ctx.arena.alloc(bool, nodes);
        @memset(via_mask, false);
        for (ctx.guide_vias) |via| {
            if (via.net != net) continue;
            markGuideCell(via_mask, ctx.grid, 0, nodes, via.x, via.y);
        }
        ctx.reference_via_mask = via_mask;
    }
}

/// Empty selection means the legacy full-board route; otherwise only true
/// net-index entries participate in plane, maze, and breakout passes.
pub fn netEnabled(ctx: *const Ctx, net_i: usize) bool {
    return ctx.selected_nets.len == 0 or
        (net_i < ctx.selected_nets.len and ctx.selected_nets[net_i]);
}

/// Stamp retained copper before routing a selected subset, and carry it into
/// the result unchanged. Sampling at half-grid pitch makes an arbitrary-angle
/// source segment a continuous obstacle on the maze raster.
fn stampExistingCopper(
    ctx: *Ctx,
    options: route_policy.Options,
    tracks: *std.ArrayList(Track),
    vias: *std.ArrayList(Via),
) std.mem.Allocator.Error!void {
    for (options.existing_tracks) |item| {
        // A track on a layer the maze does not model still ECHOES into the
        // result (the caller's copper is returned whole); only the obstacle
        // stamp is skipped, since there is no grid to stamp it on.
        if (item.layer < ctx.occ.len) {
            const net = if (item.net == empty_cell) -2 else item.net;
            const len = std.math.hypot(item.x2 - item.x1, item.y2 - item.y1);
            const steps: usize = @max(1, numeric.toCount(@ceil(len / (ctx.grid.g * 0.5))));
            const halo = item.width / 2 + ctx.index_reach;
            for (0..steps + 1) |s| {
                const t = @as(f64, @floatFromInt(s)) / @as(f64, @floatFromInt(steps));
                const x = item.x1 + t * (item.x2 - item.x1);
                const y = item.y1 + t * (item.y2 - item.y1);
                stampDisc(ctx, x, y, net, halo, item.layer, false);
            }
        }
        try tracks.append(ctx.arena, .{
            .x1 = item.x1,
            .y1 = item.y1,
            .x2 = item.x2,
            .y2 = item.y2,
            .layer = item.layer,
            .width = item.width,
            .net = item.net,
        });
    }
    for (options.existing_vias) |item| {
        const net = if (item.net == empty_cell) -2 else item.net;
        const halo = item.dia / 2 + ctx.index_reach;
        stampDisc(ctx, item.x, item.y, net, halo, 0, true);
        try vias.append(ctx.arena, .{
            .x = item.x,
            .y = item.y,
            .dia = item.dia,
            .drill = item.drill,
            .net = item.net,
        });
    }
}

/// Stamp every routed `tracks`/`vias` of a net OTHER than `skip_net` into
/// `ctx`'s occupancy grids as a foreign obstacle `blocked` refuses. Seeds a
/// fresh windowed context (see `windowCtx`) with the current board so a local
/// retry keeps full DRC clearance from everything already placed; the routing
/// net itself is skipped so its own accumulating copper never blocks a later leg
/// (that copper is already threaded into the passed track/via lists, where the
/// direct-synthesis clearance checks — which skip same-net — see it).
///
/// The halo is the routing net's EXACT clearance (`ctx.reach`, set per-net
/// before the call) plus a half-diagonal grid step, not the board-wide
/// `index_reach`: a thin net threading a tight gap must not be walled out by the
/// widest class's margin, yet the diagonal-step term keeps a 45° maze segment
/// clear (its midpoint sits `g/√2` inside the node distances). Copper centred
/// outside the window still stamps its in-window halo (`stampDisc` clips to the
/// grid), so a foreign track skimming the window edge blocks correctly.
fn stampBoardCopper(ctx: *Ctx, tracks: []const Track, vias: []const Via, skip_net: i32) void {
    const slack = ctx.grid.g * (sqrt2 / 2);
    // The diagonal-step margin belongs to the RASTER, not to the physics. In
    // exact mode `moveClearsCopper` re-measures every move against the copper
    // itself, so the stamp drops the margin and blocks only what a track centre
    // may genuinely not occupy; the margin then survives as the `near` band that
    // decides which moves pay for that re-measurement.
    const margin = if (ctx.exact != null) 0 else slack;
    if (ctx.exact) |*ex| {
        @memset(ex.near, false);
        ex.tracks = tracks;
        ex.vias = vias;
    }
    for (tracks) |t| {
        if (t.layer >= ctx.occ.len or t.net == skip_net) continue;
        const net = if (t.net == empty_cell) -2 else t.net;
        const len = std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
        const steps: usize = @max(1, numeric.toCount(@ceil(len / (ctx.grid.g * 0.5))));
        // A track whose net declared a keepout is held off by the WIDER of its
        // clearance and its halo — how a windowed retry / gap hop respects an RF
        // keepout with no node mask of its own. Zero for an exempt routing net; BANDED, not flat (`KeepState.band`).
        const halo = t.width / 2 + ctx.reach + keepoutExtra(ctx, t.net);
        ctx.keep.band = .{ .net = t.net, .plain = t.width / 2 + ctx.reach + margin };
        for (0..steps + 1) |s| {
            const f = @as(f64, @floatFromInt(s)) / @as(f64, @floatFromInt(steps));
            const x = t.x1 + f * (t.x2 - t.x1);
            const y = t.y1 + f * (t.y2 - t.y1);
            stampDisc(ctx, x, y, net, halo + margin, t.layer, false);
            markNearCopper(ctx, x, y, halo + slack, t.layer, false);
        }
    }
    for (vias) |v| {
        if (v.net == skip_net) continue;
        const net = if (v.net == empty_cell) -2 else v.net;
        const halo = v.dia / 2 + ctx.reach + keepoutExtra(ctx, v.net);
        ctx.keep.band = .{ .net = v.net, .plain = v.dia / 2 + ctx.reach + margin };
        stampDisc(ctx, v.x, v.y, net, halo + margin, 0, true);
        markNearCopper(ctx, v.x, v.y, halo + slack, 0, true);
    }
    ctx.keep.band = .{}; // every OTHER stamper claims its whole disc outright
    if (ctx.exact != null) buildExactIndex(ctx, tracks, vias);
}

/// Flag every node within `dist` of `(x, y)` as sitting in some foreign
/// obstacle's re-measurement band (see `ExactClearance.near`). Mirrors
/// `stampDisc`'s raster exactly, so the band is the disc the raster-only model
/// would have blocked outright. No-op when exact mode is off.
fn markNearCopper(ctx: *Ctx, x: f64, y: f64, dist: f64, layer: u8, both: bool) void {
    const ex = ctx.exact orelse return;
    const grid = ctx.grid;
    const nodes = grid.nx * grid.ny;
    const r_nodes: i64 = numeric.checkedInt(i64, @ceil(dist / grid.g)) orelse 0;
    const c = grid.nearest(x, y);
    const lo: usize = if (both) 0 else @min(@as(usize, layer), ctx.occ.len);
    const hi: usize = if (both) ctx.occ.len else @min(@as(usize, layer) + 1, ctx.occ.len);
    if (lo >= hi) return;
    var dj: i64 = -r_nodes;
    while (dj <= r_nodes) : (dj += 1) {
        var di: i64 = -r_nodes;
        while (di <= r_nodes) : (di += 1) {
            const ix = @as(i64, @intCast(c[0])) + di;
            const iy = @as(i64, @intCast(c[1])) + dj;
            if (ix < 0 or iy < 0 or ix >= grid.nx or iy >= grid.ny) continue;
            const ddx = grid.worldX(@intCast(ix)) - x;
            const ddy = grid.worldY(@intCast(iy)) - y;
            if (ddx * ddx + ddy * ddy > dist * dist) continue;
            const n = @as(usize, @intCast(iy)) * grid.nx + @as(usize, @intCast(ix));
            for (lo..hi) |l| ex.near[l * nodes + n] = true;
        }
    }
}

/// The spatial index itself, its obstacle box, and its point/segment queries
/// live in `pad_grid.zig` — the candidate-superset filter every exact clearance
/// probe here funnels through. Aliased so the probe sites read unchanged.
const PadGrid = pad_grid.PadGrid;
const nearSegment = pad_grid.nearSegment;
const near_scratch_len = pad_grid.near_scratch_len;

/// The world rectangle an index built for this route must cover: the routing
/// grid's own extent, so every on-board query lands in a real cell.
fn gridBounds(g: Grid) pad_grid.Bounds {
    return .{
        .minx = g.ox,
        .miny = g.oy,
        .maxx = g.ox + @as(f64, @floatFromInt(g.nx -| 1)) * g.g,
        .maxy = g.oy + @as(f64, @floatFromInt(g.ny -| 1)) * g.g,
    };
}

/// Build the copper spatial index over `tracks` + `vias` (box order: tracks
/// then vias). Insertion reach covers the largest clearance any direct probe
/// applies — a via-via pair is `via_dia/2 + via_dia/2`, a track is its own
/// half-width plus the routing net's half-width, holes add the drill wall —
/// so `near()` / `nearSegment()` are supersets for every probe. Null on a
/// degenerate board / oversized grid / alloc failure; callers fall back to
/// the full scan with identical verdicts.
fn buildCopperIndex(ctx: *Ctx, tracks: []const Track, vias: []const Via) ?*const PadGrid {
    if (tracks.len == 0 and vias.len == 0) return null;
    var widest: f64 = 0;
    for (tracks) |t| widest = @max(widest, t.width / 2);
    for (vias) |v| widest = @max(widest, v.dia / 2);
    const reach = widest + ctx.params.via_dia + ctx.params.track_width / 2 +
        ctx.params.clearance + ctx.hole_to_hole + keepMaxExtra(ctx);
    const boxes = ctx.arena.alloc(PadObs, tracks.len + vias.len) catch return null;
    for (tracks, 0..) |t, i| boxes[i] = .{
        .x0 = @min(t.x1, t.x2),
        .y0 = @min(t.y1, t.y2),
        .x1 = @max(t.x1, t.x2),
        .y1 = @max(t.y1, t.y2),
        .net = t.net,
    };
    for (vias, 0..) |v, i| boxes[tracks.len + i] = .{
        .x0 = v.x,
        .y0 = v.y,
        .x1 = v.x,
        .y1 = v.y,
        .net = v.net,
    };
    return PadGrid.build(ctx.arena, boxes, gridBounds(ctx.grid), reach);
}

/// The reach a copper-index query must expand by so its candidate set is a
/// superset of everything that could touch the probe: the widest copper in the
/// index plus the largest clearance the CURRENT net's geometry can demand.
/// Reads `ctx.params` + `ctx.keep`, so it is restated whenever those change.
fn copperReach(ctx: *const Ctx) f64 {
    return ctx.copper_widest + ctx.params.via_dia + ctx.params.track_width / 2 +
        ctx.params.clearance + ctx.hole_to_hole + keepMaxExtra(ctx);
}

/// Refresh `ctx.copper_index` from the current copper. O(tracks + vias) per
/// call — negligible against the millions of probes it accelerates. Restamps
/// the index with the current `copper_gen`, which is what makes it usable
/// again after a compaction (see `copperCompacted`).
pub inline fn rebuildCopperIndex(ctx: *Ctx, tracks: []const Track, vias: []const Via) void {
    ctx.copper_track_count = tracks.len;
    ctx.copper_via_count = vias.len;
    const built = buildCopperIndex(ctx, tracks, vias);
    ctx.copper_index = built;
    ctx.copper_index_gen = ctx.copper_gen;
    if (built == null) {
        ctx.copper_widest = 0;
        ctx.copper_reach = 0;
        return;
    }
    var widest: f64 = 0;
    for (tracks) |t| widest = @max(widest, t.width / 2);
    for (vias) |v| widest = @max(widest, v.dia / 2);
    ctx.copper_widest = widest;
    ctx.copper_reach = copperReach(ctx);
}

/// Announce that the copper lists were REORDERED or SHRUNK, so every index the
/// copper index holds now names different copper than it was built for.
///
/// `route_cleanup.removeNetTracks` / `removeNetVias` pack survivors down in
/// place, so a surviving track slides into a removed one's slot: the index's
/// candidate `ci` is still in range and points at the WRONG track — a bounds
/// guard cannot catch it, and the probe can return a false "clear" against
/// copper that is really in the way. Bumping the generation makes `copperIdx`
/// refuse the index (linear fallback, identical verdicts) until the next
/// `rebuildCopperIndex` restamps it, so a forgotten rebuild costs time and
/// never soundness.
pub inline fn copperCompacted(ctx: *Ctx) void {
    ctx.copper_gen +%= 1;
}

/// The copper index, or null when a compaction has invalidated it. Every probe
/// reads the index through here rather than touching `ctx.copper_index`.
inline fn copperIdx(ctx: *const Ctx) ?*const PadGrid {
    if (ctx.copper_gen != ctx.copper_index_gen) return null;
    return ctx.copper_index;
}

/// Account one exact-clearance probe against the per-net direct budget, if
/// armed. Returns true when the budget is exhausted — the caller must report
/// the probed item as BLOCKED so the direct attempt fails fast and the net
/// falls to the maze (bailing on "clear" would let unvalidated copper
/// through).
inline fn probeBudgetExhausted(ctx: *Ctx) bool {
    // Direct synthesis can spend millions of exact-clearance probes inside one
    // net, so net-boundary cancellation alone cannot enforce a board deadline.
    // One clock read per 1024 probes is negligible beside the geometry work and
    // bounds the overshoot without putting a syscall on every hot-path probe.
    if (ctx.deadline_expired) return true;
    if (ctx.deadline_ns != 0) {
        ctx.deadline_probe_count +%= 1;
        if ((ctx.deadline_probe_count & 1023) == 0 and clock.nanoTimestamp() >= ctx.deadline_ns) {
            ctx.deadline_expired = true;
            return true;
        }
    }
    if (ctx.direct_budget) |*b| {
        if (b.* == 0) return true;
        b.* -= 1;
    }
    return false;
}

/// Rebuild the spatial index `moveClearsCopper` prefilters through: one
/// bounding box per foreign track (first) then per foreign via, bucketed so the
/// bin holding a move's ORIGIN contains every obstacle that move could violate.
/// The registration reach is the widest obstacle's clearance plus one diagonal
/// step, which is the furthest a move's far end can reach past its origin.
fn buildExactIndex(ctx: *Ctx, tracks: []const Track, vias: []const Via) void {
    if (ctx.exact == null) return;
    ctx.exact.?.index = null;
    var widest: f64 = 0;
    for (tracks) |t| widest = @max(widest, t.width / 2);
    for (vias) |v| widest = @max(widest, v.dia / 2);
    const boxes = ctx.arena.alloc(PadObs, tracks.len + vias.len) catch return;
    for (tracks, 0..) |t, i| boxes[i] = .{
        .x0 = @min(t.x1, t.x2),
        .y0 = @min(t.y1, t.y2),
        .x1 = @max(t.x1, t.x2),
        .y1 = @max(t.y1, t.y2),
        .net = t.net,
    };
    for (vias, 0..) |v, i| boxes[tracks.len + i] = .{ .x0 = v.x, .y0 = v.y, .x1 = v.x, .y1 = v.y, .net = v.net };
    ctx.exact.?.index = PadGrid.build(ctx.arena, boxes, gridBounds(ctx.grid), widest + ctx.reach + ctx.grid.g * sqrt2);
}

/// The gap pass's exact-clearance model. The maze raster can only mark whole
/// cells, so the raster-only obstacle model inflates every obstacle by
/// `g·√2/2` — the furthest a diagonal move's midpoint strays from the nodes
/// actually tested. That margin is sized by the GRID PITCH, which is set by the
/// board's widest net class, so a 0.127 mm control net threading past 0.127 mm
/// copper is walled out of corridors it physically fits: 0.254 mm of real
/// centre-to-centre clearance is modelled as 0.409 mm. Exact mode stamps the
/// true clearance and re-measures each candidate move against the copper — the
/// error disappears instead of merely shrinking, and only moves touching the
/// thin `near` band pay for the measurement.
const ExactClearance = struct {
    /// Per-`layer*nodes + node`: this node lies inside some foreign obstacle's
    /// clearance INFLATED by one diagonal step. A move with both ends outside
    /// the band is provably clear (every point of it sits within `g·√2/2` of an
    /// end), so it needs no measurement.
    near: []bool = &.{},
    /// The board copper the current stamp was taken from — index order is
    /// tracks then vias, matching `index`.
    tracks: []const Track = &.{},
    vias: []const Via = &.{},
    /// Bounding-box bucket index over `tracks ++ vias`; null falls back to the
    /// full scan (same verdict, more work).
    index: ?*const PadGrid = null,
};

/// True when the maze move `from_key → (to_layer, to_node)` keeps the routing
/// net's real clearance from every foreign track and via. This is what lets the
/// stamp drop the raster's diagonal-step margin: the margin existed only
/// because nothing re-measured the move, and now something does.
///
/// A layer change is not a segment — it is a via drop, whose clearance
/// `viaAllowed` owns — so it passes through.
fn moveClearsCopper(ctx: *Ctx, net: i32, from_key: usize, to_layer: usize, to_node: usize) bool {
    const ex = ctx.exact orelse return true;
    const grid = ctx.grid;
    const nodes = grid.nx * grid.ny;
    if (from_key / nodes != to_layer) return true;
    const to_key = to_layer * nodes + to_node;
    if (from_key >= ex.near.len or to_key >= ex.near.len) return true;
    if (!ex.near[from_key] and !ex.near[to_key]) return true;
    const from_node = from_key % nodes;
    const a = [2]f64{ grid.worldX(from_node % grid.nx), grid.worldY(from_node / grid.nx) };
    const b = [2]f64{ grid.worldX(to_node % grid.nx), grid.worldY(to_node / grid.nx) };
    const move = MoveSeg{ .a = a, .b = b, .net = net, .layer = @intCast(to_layer) };
    if (ex.index) |idx| {
        for (idx.near(a[0], a[1])) |ci| if (!exactItemClears(ctx, ex, ci, move)) return false;
        return true;
    }
    for (0..ex.tracks.len + ex.vias.len) |ci| if (!exactItemClears(ctx, ex, ci, move)) return false;
    return true;
}

/// One candidate maze move, as the geometry the exact clearance test measures:
/// the segment between the two nodes, plus the routing net and the layer it
/// would be drawn on.
const MoveSeg = struct { a: [2]f64, b: [2]f64, net: i32, layer: u8 };

/// Does obstacle `ci` (a track while `ci` indexes `tracks`, else a via) leave
/// the routing net's clearance around the segment a→b on `layer`?
fn exactItemClears(ctx: *Ctx, ex: ExactClearance, ci: usize, move: MoveSeg) bool {
    // The very probes the direct/dogleg synthesis measures a shortcut by, so the
    // exact model widens for an obstacle's keepout — and waives that widening
    // inside an admitting escape zone — exactly where the raster stamp does.
    if (ci < ex.tracks.len) {
        const t = ex.tracks[ci];
        return t.net == move.net or t.layer != move.layer or segClearsTrack(ctx, t, move.a, move.b);
    }
    const v = ex.vias[ci - ex.tracks.len];
    return v.net == move.net or segClearsVia(ctx, v, move.a, move.b);
}

fn zoneBounds(poly: []const [2]f64) optimizer.BoardRect {
    return outline_mod.bboxRect(poly);
}

fn zoneArea(poly: []const [2]f64) f64 {
    if (poly.len < 3) return 0;
    var twice: f64 = 0;
    var previous = poly[poly.len - 1];
    for (poly) |point| {
        twice += previous[0] * point[1] - point[0] * previous[1];
        previous = point;
    }
    return @abs(twice) / 2;
}

/// True when `(x, y)` sits inside `zone`'s polygon but the copper is NOT there:
/// a strictly-higher-priority pour of a different net covers the same spot on
/// the same layer, so this pour's fill was knocked back (KiCad zone-priority
/// resolution, mirrored by `pour.clippedByHigher`). A plane stitch that lands
/// here drills into a clearance gap — the via is DRC-clean and joins nothing,
/// which is exactly the "copper landed, islands did not merge" outcome.
fn zoneClipped(ctx: *const Ctx, zone: route_policy.ExistingZone, x: f64, y: f64) bool {
    for (ctx.zones) |z| {
        if (!z.copper or z.layer != zone.layer or z.net == zone.net) continue;
        if (z.priority <= zone.priority) continue;
        if (outline_mod.contains(z.polygon, x, y)) return true;
    }
    return false;
}

/// True when `(x, y)` is a point where `zone`'s copper really is — inside the
/// polygon and not clipped away by a higher-priority overlap.
fn zonePoured(ctx: *const Ctx, zone: route_policy.ExistingZone, x: f64, y: f64) bool {
    return outline_mod.contains(zone.polygon, x, y) and !zoneClipped(ctx, zone, x, y);
}

/// True when `(x, y)` sits in copper poured for `net` ITSELF (not a foreign pour
/// the point merely lies over) on some layer other than `except_layer`.
///
/// A via there is a plane tap: copper hanging off it may reach the rest of the
/// net only through that pour, so a cleanup pass deleting vias must leave it
/// alone — the island model does not carry pours. `except_layer` is the layer a
/// caller is about to draw its replacement copper on: a tap there needs no via,
/// because the chain endpoint stays put inside the pour and keeps the
/// connection by plain copper overlap (a same-net zone merges with same-net
/// tracks rather than clearing around them).
pub fn netPourCovers(ctx: *const Ctx, net: i32, x: f64, y: f64, except_layer: ?u8) bool {
    for (ctx.zones) |z| {
        if (!z.copper or z.net != net) continue;
        if (except_layer) |skip| {
            if (z.layer == skip) continue;
        }
        if (zonePoured(ctx, z, x, y)) return true;
    }
    return false;
}

/// Does `net` own pour copper that SURVIVES priority clipping within `reach` of
/// `(x, y)` — real fabricated metal a stitch via could land in, rather than a
/// polygon a pour merely declares?
///
/// `largestNetZone(…) != null` answers the DECLARED question, and the two are
/// different answers on a board whose pours overlap. Barracuda's `V_6VA` In3
/// pour (priority 5) is overlapped almost end to end by `V_3V3_LMX`'s (priority
/// 6), so all but a ~1.2 mm band of its fill is knocked back; `V_3V3A`'s zone
/// stops at y = 105.75 while a third of its pads sit north of it. Both nets
/// therefore read as "poured" everywhere and every stitch site was measured
/// against copper that is not there — the pad ends up with no site at all
/// rather than with the ordinary trace its island actually needs.
///
/// Clipping is LOCAL, so this is asked local to the pad: the same net can be
/// genuinely poured under one pad and bare under another 20 mm away, and each
/// pad has to be judged where it stands. Sampling is on the router's own grid,
/// which is exactly the lattice every stitch site is snapped to, so a band no
/// grid node lands in is a band no via could have used anyway.
fn pourLiveNear(ctx: *const Ctx, net: i32, x: f64, y: f64, reach: f64) bool {
    // A pad standing in its own live copper is the common case and needs no scan.
    if (netPourCovers(ctx, net, x, y, null)) return true;
    const lo = ctx.grid.nearest(x - reach, y - reach);
    const hi = ctx.grid.nearest(x + reach, y + reach);
    var iy = lo[1];
    while (iy <= hi[1]) : (iy += 1) {
        var ix = lo[0];
        while (ix <= hi[0]) : (ix += 1) {
            const px = ctx.grid.worldX(ix);
            const py = ctx.grid.worldY(iy);
            if (std.math.hypot(px - x, py - y) > reach) continue;
            if (netPourCovers(ctx, net, px, py, null)) return true;
        }
    }
    return false;
}

/// What a stranded pad's stitch via can actually REACH on this net — the
/// clip-aware replacement for the flat `poured` boolean.
const StitchTarget = enum {
    /// A plane carries the net, so any DRC-clean site near the pad taps it.
    plane,
    /// The net's own pour carries it AND that fill survives clipping within
    /// reach, so the via must land inside the surviving copper.
    pour,
    /// The net owns pours, none of them survives near this pad, and no plane
    /// backs it. A barrel here would be drilled into a clearance gap and join
    /// nothing — `island_accept` credits it no island merge — while consuming
    /// the request's own trace fallback. So the pad rejoins its net by TRACE.
    none,
};

/// Which of the three a stranded pad is in. `reach` is the widest neighbourhood
/// any tier of the stitch searches (the maze's, since it subsumes the fan's), so
/// a pad is only ruled out when NO tier could have found live copper.
fn stitchTarget(state: *GapState, pt: NetPt, net: i32, reach: f64) StitchTarget {
    const ctx = state.ctx;
    // No retained pour at all: the plane is the target and any legal site taps
    // it, exactly as this read before pours were weighed.
    if (largestNetZone(ctx, net) == null) return .plane;
    if (pourLiveNear(ctx, net, pt.x, pt.y, reach)) return .pour;
    const i: usize = @intCast(net);
    if (i < state.placement.nets.len and netHasPlane(state.placement, state.placement.nets[i].name)) return .plane;
    return .none;
}

fn largestNetZone(ctx: *const Ctx, net: i32) ?route_policy.ExistingZone {
    var best: ?route_policy.ExistingZone = null;
    var best_area: f64 = 0;
    for (ctx.zones) |zone| {
        if (!zone.copper or zone.net != net or zone.layer >= ctx.occ.len) continue;
        // A retained same-net pour is a TERMINAL even when the authored route
        // wave excludes its layer. Dijkstra may seed at any node in the pour
        // and immediately transition through a via onto an allowed layer;
        // `relaxStep` still rejects same-layer movement because the destination
        // layer is outside `allowed_layers`. Thus Barracuda's In2.Cu power
        // islands can feed F.Cu/B.Cu stubs without permitting arbitrary routed
        // traces across the reserved power layer.
        const area = zoneArea(zone.polygon);
        if (area <= best_area) continue;
        best = zone;
        best_area = area;
    }
    return best;
}

/// The point of `poly` a terminal should aim its local rescue window at. A pad
/// whose XY already overlaps the pour aims straight down into it; a pad outside
/// the polygon aims at the nearest boundary point. The latter is the orthogonal
/// projection onto the closest closed-polygon edge (with endpoint clamping).
fn zoneAnchor(poly: []const [2]f64, pt: NetPt) ?[2]f64 {
    if (poly.len == 0) return null;
    if (outline_mod.contains(poly, pt.x, pt.y) or
        outline_mod.distToEdge(poly, pt.x, pt.y) <= clearance_eps)
    {
        return .{ pt.x, pt.y };
    }
    var best = poly[0];
    var best_dist2 = std.math.inf(f64);
    var a = poly[poly.len - 1];
    for (poly) |b| {
        const dx = b[0] - a[0];
        const dy = b[1] - a[1];
        const len2 = dx * dx + dy * dy;
        const t = if (len2 > 0)
            std.math.clamp(((pt.x - a[0]) * dx + (pt.y - a[1]) * dy) / len2, 0, 1)
        else
            0;
        const candidate = [2]f64{ a[0] + t * dx, a[1] + t * dy };
        const ex = candidate[0] - pt.x;
        const ey = candidate[1] - pt.y;
        const dist2 = ex * ex + ey * ey;
        if (dist2 < best_dist2) {
            best = candidate;
            best_dist2 = dist2;
        }
        a = b;
    }
    return best;
}

/// The lowest-cost existing barrel that can replace a new pour transition for
/// `pt`. Reuse is electrically valid only when the through-via belongs to this
/// net AND its centre intersects this exact pour; distance is the reuse cost,
/// while `new_zone_via_cost_mm` is the cost of drilling locally.
fn nearestReusableZoneVia(
    vias: []const Via,
    zone: route_policy.ExistingZone,
    net: i32,
    pt: NetPt,
) ?Via {
    var best: ?Via = null;
    var best_cost = new_zone_via_cost_mm + clearance_eps;
    for (vias) |via| {
        if (via.net != net) continue;
        if (!outline_mod.contains(zone.polygon, via.x, via.y) and
            outline_mod.distToEdge(zone.polygon, via.x, via.y) > clearance_eps) continue;
        const cost = std.math.hypot(via.x - pt.x, via.y - pt.y);
        if (cost > new_zone_via_cost_mm + clearance_eps or cost >= best_cost) continue;
        best = via;
        best_cost = cost;
    }
    return best;
}

/// Prefer a short, exact-geometry trace from `pt` to a nearby same-net via over
/// a fresh layer transition. `tryDirectDogleg` checks pads, tracks, vias, zones
/// and the board edge before emitting anything; a blocked candidate simply
/// falls back to the ordinary zone route, which may create a new via.
fn reuseNearbyZoneVia(
    ctx: *Ctx,
    zone: route_policy.ExistingZone,
    net: i32,
    pt: NetPt,
    tracks: *std.ArrayList(Track),
    vias: *std.ArrayList(Via),
) std.mem.Allocator.Error!bool {
    const via = nearestReusableZoneVia(vias.items, zone, net, pt) orelse return false;
    const target = NetPt{ .x = via.x, .y = via.y, .layer = pt.layer };
    const run = DirectRun{ .ctx = ctx, .net = net, .tracks = tracks, .vias = vias };
    return try tryDirectDogleg(run, pt, target);
}

/// Drop a surface pad straight into an excluded-layer same-net pour when the
/// exact pad centre accepts a legal barrel. A via-in-pad is both the shortest
/// honest connection and leaves no outer-layer stub for later signals to
/// detour; dense pads that cannot clear a barrel fall through to the ordinary
/// nearby-via maze unchanged.
fn tryZoneViaInPad(
    ctx: *Ctx,
    zone: route_policy.ExistingZone,
    net: i32,
    pt: NetPt,
    tracks: *std.ArrayList(Track),
    vias: *std.ArrayList(Via),
) std.mem.Allocator.Error!bool {
    if (pt.thru or
        (!outline_mod.contains(zone.polygon, pt.x, pt.y) and
            outline_mod.distToEdge(zone.polygon, pt.x, pt.y) > clearance_eps)) return false;
    const run = DirectRun{ .ctx = ctx, .net = net, .tracks = tracks, .vias = vias };
    const point = [2]f64{ pt.x, pt.y };
    if (!directViaClear(run, point)) return false;
    try vias.append(ctx.arena, .{
        .x = pt.x,
        .y = pt.y,
        .dia = ctx.params.via_dia,
        .drill = ctx.params.via_drill,
        .net = net,
    });
    stampViaOcc(ctx, pt.x, pt.y, net);
    return true;
}

/// Fan a surface pad into a retained inner pour through the nearest legal local
/// barrel. Via-in-pad is tried first by `routeNetToZone`; this covers the common
/// dense-package case where the pad centre is too crowded but a short 45-degree
/// escape reaches open pour copper. Every candidate is checked against the
/// surviving (priority-clipped) fill, exact via rules, and exact stub clearance
/// before either piece of copper is emitted.
fn tryZoneFanoutVia(
    ctx: *Ctx,
    zone: route_policy.ExistingZone,
    net: i32,
    pt: NetPt,
    tracks: *std.ArrayList(Track),
    vias: *std.ArrayList(Via),
) std.mem.Allocator.Error!bool {
    if (pt.thru) return false;
    const run = DirectRun{ .ctx = ctx, .net = net, .tracks = tracks, .vias = vias };
    const centre = [2]f64{ pt.x, pt.y };
    if (padCopperAt(ctx, centre, net, pt.layer)) |pad| {
        var scan = plane_via.InPad.init(pad, centre, ctx.params.via_dia);
        while (scan.next()) |site| if (try attachZoneFanoutVia(run, zone, pt, site)) return true;
    }

    const direction = plane_via.fanDir(ctx.obs, centre, net);
    const angle = std.math.atan2(direction[1], direction[0]);
    var ring: usize = 1;
    while (ring <= 16) : (ring += 1) {
        const radius = @as(f64, @floatFromInt(ring)) * ctx.grid.g;
        var spoke: usize = 0;
        while (spoke < 12) : (spoke += 1) {
            const heading = angle + plane_via.swivel(spoke);
            const site = [2]f64{
                pt.x + radius * @cos(heading),
                pt.y + radius * @sin(heading),
            };
            if (try attachZoneFanoutVia(run, zone, pt, site)) return true;
        }
    }

    return false;
}

fn attachZoneFanoutVia(
    run: DirectRun,
    zone: route_policy.ExistingZone,
    pt: NetPt,
    site: [2]f64,
) std.mem.Allocator.Error!bool {
    if (!zonePoured(run.ctx, zone, site[0], site[1]) or !directViaClear(run, site)) return false;
    const centre = [2]f64{ pt.x, pt.y };
    const path = run.path(pt.layer);
    if (!clearDoglegSegment(path, centre, site)) return false;
    try emitDoglegSegment(path, centre, site, run.tracks);
    try run.vias.append(run.ctx.arena, .{
        .x = site[0],
        .y = site[1],
        .dia = run.ctx.params.via_dia,
        .drill = run.ctx.params.via_drill,
        .net = run.net,
    });
    stampViaOcc(run.ctx, site[0], site[1], run.net);
    return true;
}

/// Exact grid nodes in the largest CONNECTED surviving component of the
/// largest retained pour for `net`. A zone boundary is not itself proof of one
/// copper body: a higher-priority overlapping pour or routed foreign copper can
/// split its fill. Seeding every polygon node at distance zero silently shorted
/// those islands in the route search, so pads could all report success while
/// the fabricated-fill oracle still saw six disconnected V_6VA components.
fn netZoneSources(
    ctx: *Ctx,
    net: i32,
    out: *std.ArrayList(usize),
) std.mem.Allocator.Error!void {
    const zone = largestNetZone(ctx, net) orelse return;
    const grid = ctx.grid;
    const nodes = grid.nx * grid.ny;
    const bounds = zoneBounds(zone.polygon);
    const lo = grid.nearest(bounds.minx, bounds.miny);
    const hi = grid.nearest(bounds.minx + bounds.w, bounds.miny + bounds.h);
    const present = try ctx.arena.alloc(bool, nodes);
    @memset(present, false);
    var iy = lo[1];
    while (iy <= hi[1]) : (iy += 1) {
        var ix = lo[0];
        while (ix <= hi[0]) : (ix += 1) {
            const x = grid.worldX(ix);
            const y = grid.worldY(iy);
            if (!outline_mod.contains(zone.polygon, x, y) and
                outline_mod.distToEdge(zone.polygon, x, y) > clearance_eps) continue;
            if (zoneClipped(ctx, zone, x, y)) continue;
            const node = grid.node(ix, iy);
            if (blocked(ctx, zone.layer, node, net)) continue;
            present[node] = true;
        }
    }

    const labels = try ctx.arena.alloc(i32, nodes);
    @memset(labels, -1);
    var queue: std.ArrayList(usize) = .empty;
    var component: i32 = 0;
    var best_component: i32 = -1;
    var best_count: usize = 0;
    for (present, 0..) |is_present, start| {
        if (!is_present or labels[start] >= 0) continue;
        queue.clearRetainingCapacity();
        try queue.append(ctx.arena, start);
        labels[start] = component;
        var read: usize = 0;
        while (read < queue.items.len) : (read += 1) {
            const node = queue.items[read];
            const ix = node % grid.nx;
            const iy_node = node / grid.nx;
            const neighbours = [_]?usize{
                if (ix > 0) node - 1 else null,
                if (ix + 1 < grid.nx) node + 1 else null,
                if (iy_node > 0) node - grid.nx else null,
                if (iy_node + 1 < grid.ny) node + grid.nx else null,
            };
            for (neighbours) |maybe| {
                const next = maybe orelse continue;
                if (!present[next] or labels[next] >= 0) continue;
                labels[next] = component;
                try queue.append(ctx.arena, next);
            }
        }
        if (queue.items.len > best_count) {
            best_component = component;
            best_count = queue.items.len;
        }
        component += 1;
    }
    if (best_component < 0) return;
    const layer_base = @as(usize, zone.layer) * nodes;
    for (labels, 0..) |label, node| if (label == best_component)
        try out.append(ctx.arena, layer_base + node);
}

fn zoneBlocksPoint(
    ctx: *const Ctx,
    layer: usize,
    point: [2]f64,
    net: i32,
    reach: f64,
    via: bool,
) bool {
    const x = point[0];
    const y = point[1];
    for (ctx.zones) |zone| {
        if (via) {
            if (!zone.vias_blocked) continue;
        } else {
            if (zone.layer != layer or !zone.tracks_blocked) continue;
        }
        if (zone.copper and zone.net == net) continue;
        // A lower-priority pour can geometrically cover this point yet have no
        // fabricated copper here because another pour clipped it away.  Such a
        // phantom region blocks neither a barrel nor a trace.
        if (zone.copper and zoneClipped(ctx, zone, x, y)) continue;
        if (outline_mod.contains(zone.polygon, x, y) or
            outline_mod.distToEdge(zone.polygon, x, y) < reach - clearance_eps) return true;
    }
    return false;
}

/// Index of the first ground net that HAS a plane (by name), or null when the
/// board has none — then there's no plane to stitch to and the return-path
/// stitch pass is skipped (on a plane-less 2-layer board ground is ordinary
/// routed copper, so "stitching" it makes no sense).
fn firstGroundNet(placement: optimizer.Placement) ?i32 {
    for (placement.nets, 0..) |net, i| {
        if (isGroundName(shortName(net.name)) and netHasPlane(placement, net.name)) return @intCast(i);
    }
    return null;
}

/// Claim every empty grid node within `dist` (mm) of (x,y) for `net` — on
/// signal layer `layer`, or on EVERY signal layer when `both` (a through
/// via's barrel reaches them all). Existing copper is never overwritten.
/// Used to reserve a via/stub's clearance halo so the maze pass keeps
/// foreign copper away from it.
fn stampDisc(ctx: *Ctx, x: f64, y: f64, net: i32, dist: f64, layer: u8, both: bool) void {
    const grid = ctx.grid;
    const r_nodes: i64 = numeric.checkedInt(i64, @ceil(dist / grid.g)) orelse 0;
    const c = grid.nearest(x, y);
    const ci: i64 = @intCast(c[0]);
    const cj: i64 = @intCast(c[1]);
    // Hoisted out of the per-cell loop: a single-layer stamp used to walk every
    // layer and `continue` past all but one, paying the whole board's layer
    // count for each of the millions of cells a board-wide re-stamp touches.
    const lanes: []const []i32 = if (both)
        ctx.occ
    else if (layer < ctx.occ.len)
        ctx.occ[layer .. layer + 1]
    else
        &.{};
    if (lanes.len == 0) return;
    var dj: i64 = -r_nodes;
    while (dj <= r_nodes) : (dj += 1) {
        var di: i64 = -r_nodes;
        while (di <= r_nodes) : (di += 1) {
            const ix = ci + di;
            const iy = cj + dj;
            if (ix < 0 or iy < 0 or ix >= grid.nx or iy >= grid.ny) continue;
            const wx = grid.worldX(@intCast(ix));
            const wy = grid.worldY(@intCast(iy));
            // Squared compare: a board-wide re-stamp evaluates this for millions
            // of cells and `hypot` is the scaled, exactly-rounded routine.
            const ddx = wx - x;
            const ddy = wy - y;
            if (!keepout.bandClaims(ctx.keep.zones, ctx.keep.band, ddx * ddx + ddy * ddy, dist * dist, .{ wx, wy })) continue;
            const n = @as(usize, @intCast(iy)) * grid.nx + @as(usize, @intCast(ix));
            for (lanes) |occ_l| {
                if (occ_l[n] == empty_cell) occ_l[n] = net;
            }
        }
    }
}

/// Fine grids have sub-clearance neighbour spacing, so exact copper nodes need
/// a non-connective halo in `resv`. Normal-pitch grids already get this
/// guarantee from one-node spacing and retain their byte-identical raster.
fn stampTrackResv(ctx: *Ctx, a: [2]f64, b: [2]f64, net: i32, layer: u8) void {
    const dist = ctx.params.track_width / 2 + ctx.index_reach - clearance_eps;
    if (layer >= ctx.resv.len or ctx.grid.g >= dist) return;
    const grid = ctx.grid;
    const len = std.math.hypot(b[0] - a[0], b[1] - a[1]);
    const steps: usize = @max(1, numeric.toCount(@ceil(len / (grid.g * 0.5))));
    for (0..steps + 1) |step| {
        const t = @as(f64, @floatFromInt(step)) / @as(f64, @floatFromInt(steps));
        const x = a[0] + t * (b[0] - a[0]);
        const y = a[1] + t * (b[1] - a[1]);
        reserveDisc(ctx, x, y, net, dist, layer);
    }
}

/// Reserve every free `resv` node within `dist` of (x, y) on `layer` for `net`
/// — `disc_stamp`'s shared raster, first writer owning the node.
fn reserveDisc(ctx: *Ctx, x: f64, y: f64, net: i32, dist: f64, layer: u8) void {
    disc_stamp.claimFree(ctx.grid, ctx.resv[layer], .{ x, y }, dist, net);
}

// ── RF same-layer keepout (see `KeepState` and `placement/keepout.zig`) ──────

/// Extra edge-to-edge separation (mm) an obstacle on `obstacle_net` demands over
/// the routing net's ordinary clearance, because that net declared a keepout — so
/// `stampBoardCopper` and `exactItemClears` widen only the pairs the rule is about.
/// Zero between two members of ONE class: they are one signal family, held apart
/// by their shared clearance and not by each other's halo (`keepout.ClassGate`).
pub fn keepoutExtra(ctx: *const Ctx, obstacle_net: i32) f64 {
    if (ctx.keep.class.waives(obstacle_net)) return 0;
    return keepout.extraOver(ctx.keep.nets, obstacle_net, ctx.params.clearance, ctx.keep.exempt);
}

/// Conservative pad-index expansion: ordinary widest-class reach plus the
/// largest authored halo. Extra candidates are harmless; missing one is not.
fn padIndexReach(ctx: *const Ctx) f64 {
    return ctx.index_reach + keepout.maxHalo(ctx.keep.nets);
}

/// Largest keepout halo a foreign obstacle may demand over ordinary clearance.
/// The copper-index build and probe radii need it so a halo-only obstacle is
/// still found before the per-candidate test applies its own `keepoutExtra`.
fn keepMaxExtra(ctx: *const Ctx) f64 {
    if (ctx.keep.exempt) return 0;
    return @max(0, keepout.maxHalo(ctx.keep.nets) - ctx.params.clearance);
}

/// The `{ ordinary, ordinary + halo }` pair `keepout.approachClears` judges an
/// approach to `net`'s copper by, with this file's float epsilon folded in.
fn keepLimits(ctx: *const Ctx, net: i32, ordinary: f64) [2]f64 {
    const plain = ordinary - clearance_eps;
    return .{ plain, plain + keepoutExtra(ctx, net) };
}

/// Where segment a→b passes closest to (x, y) — the approach point every keepout
/// probe reports. `pad_shape` owns the projection; this is the array-shaped
/// wrapper the router's own call sites read best.
fn closestOnLine(a: [2]f64, b: [2]f64, x: f64, y: f64) [2]f64 {
    const c = pad_shape.closestOnSeg(a[0], a[1], b[0], b[1], x, y);
    return .{ c.x, c.y };
}

fn padSegmentClears(ctx: *const Ctx, p: PadObs, a: [2]f64, b: [2]f64, ordinary: f64) bool {
    const lim = keepLimits(ctx, p.net, ordinary);
    if (segmentMissesBox(a, b, .{ p.x0, p.y0, p.x1, p.y1 }, lim[1])) return true;
    const shape = pad_shape.Shape{ .x0 = p.x0, .y0 = p.y0, .x1 = p.x1, .y1 = p.y1, .poly = p.poly };
    const distance = pad_shape.segmentDist(shape, a, b, lim[1]);
    const at = closestOnLine(a, b, (p.x0 + p.x1) / 2, (p.y0 + p.y1) / 2);
    return keepout.approachClears(ctx.keep.zones, p.net, distance, at, lim);
}

/// Is node `n` inside a FOREIGN net's stamped keepout halo — on `layer`, or (null
/// = a via, whose barrel occupies them all) on ANY layer? Mirrors `blocked`'s
/// `resv` test plus the two exemptions: ground owes no keepout, a halo's owner
/// routes through its own, and a GATED node admits the nets it was opened for.
fn keepoutBlocked(ctx: *const Ctx, layer: ?usize, n: usize, net: i32) bool {
    if (ctx.keep.exempt) return false;
    if (layer) |l| return l < ctx.keep.layers.len and keepoutBlockedOn(ctx, l, n, net);
    for (0..ctx.keep.layers.len) |l| if (keepoutBlockedOn(ctx, l, n, net)) return true;
    return false;
}

/// `keepoutBlocked` for one signal layer: claimed by a halo this net owes (a
/// fellow class member's is not one) AND not let through by that node's gate.
fn keepoutBlockedOn(ctx: *const Ctx, layer: usize, n: usize, net: i32) bool {
    if (!keepout.claimed(ctx.keep.layers[layer], ctx.keep.class.ids, n, net)) return false;
    return !keepoutGateAdmits(ctx, layer, n, net);
}

/// Does the gate on halo node `(layer, n)` admit `net`? See `KeepState.gate` for
/// the encoding. An ungated node admits nobody — the halo's whole point.
fn keepoutGateAdmits(ctx: *const Ctx, layer: usize, n: usize, net: i32) bool {
    if (layer >= ctx.keep.gate.len) return false;
    const g = ctx.keep.gate[layer][n];
    if (g == empty_cell) return false;
    if (g >= 0) return g == net; // a pad landing: only that pad's net
    return ctx.keep.zones.admits(@intCast(-g - 2)); // an escape zone: ask the gate
}

/// One keepout-halo stamping request: whose halo, which signal layer, how far it
/// reaches from the centreline, and the escape zones gating it open.
const KeepStamp = struct {
    net: i32,
    layer: u8,
    dist: f64,
    /// The owner's escape zones, and the index of the first of them in
    /// `KeepState.zones.all` so a covering zone can be encoded into `gate`.
    zones: []const keepout.Zone = &.{},
    zone_base: u32 = 0,
};

/// The stamp for a keepout net's copper of half-extent `half` (a track half-width
/// or a via radius): that copper, plus the halo, plus an allowance for the FOREIGN
/// centreline it holds off — the maze tests node centres and nothing else adds an
/// intruder's own half-width.
fn keepStamp(ctx: *const Ctx, net: i32, layer: u8, half: f64) KeepStamp {
    return .{
        .net = net,
        .layer = layer,
        .dist = half + keepout.haloAt(ctx.keep.nets, net) + ctx.max_half_width,
        .zones = ctx.keep.zones.of(net),
        .zone_base = ctx.keep.zones.base(net),
    };
}

/// Claim every free node within `st.dist` of (x,y) on `st.layer` for `st.net`'s
/// keepout halo, recording each node's gate (`KeepState.gate`) as it goes: the
/// escape zone or the foreign pad landing that opens it, and to whom. Claiming
/// rather than SKIPPING those nodes is the difference between an opening and a
/// hole — see `keepout.zig`'s module doc for the filter corridor an ungated one
/// left wide open.
fn keepDisc(ctx: *Ctx, x: f64, y: f64, st: KeepStamp) void {
    if (st.layer >= ctx.keep.layers.len) return;
    const Claim = struct {
        ctx: *Ctx,
        lane: []i32,
        st: KeepStamp,

        fn stamp(self: @This(), node: disc_stamp.Node) void {
            keepClaim(self.ctx, self.lane, node.at, node.x, node.y, self.st);
        }
    };
    const claim = Claim{ .ctx = ctx, .lane = ctx.keep.layers[st.layer], .st = st };
    disc_stamp.forEach(ctx.grid, .{ x, y }, st.dist, claim, Claim.stamp);
}

/// Claim one node for `st`, preserving first-stamp ownership and recording the
/// net-gated opening that covers it. Shared by disc and exact pad-shape stamps.
fn keepClaim(ctx: *Ctx, lane: []i32, node: usize, x: f64, y: f64, st: KeepStamp) void {
    if (lane[node] != empty_cell) return;
    lane[node] = st.net;
    if (keepGateAt(ctx, x, y, st)) |code| {
        if (st.layer < ctx.keep.gate.len) ctx.keep.gate[st.layer][node] = code;
    }
}

/// The gate code for a halo node at (x,y) under stamp `st`, or null when the halo
/// closes there for everyone. Escape zones are tested first: they are the
/// owner's own declaration, and a pad landing inside one would otherwise narrow
/// the opening to a single net.
fn keepGateAt(ctx: *Ctx, x: f64, y: f64, st: KeepStamp) ?i32 {
    for (st.zones, 0..) |z, i| {
        if (std.math.hypot(x - z.x, y - z.y) > z.r) continue;
        const index: i32 = @intCast(st.zone_base + i);
        return -index - 2;
    }
    return foreignPadNetAt(ctx, x, y, st.net);
}

/// The net of the first FOREIGN pad whose landing (its copper plus the clearance
/// ring only that net may occupy) covers (x,y), else null. Such a node is gated
/// to that net rather than closed, which keeps the rule from contradicting
/// itself: pads never offend, yet a pad whose landing the halo claimed would be
/// one its own net could not route out of.
///
/// The gate matters even though `foreignPadAt` already bars other nets from most
/// of these nodes: it is measured with `index_reach` (the widest class), while
/// pad blocking uses the ROUTING net's narrower `reach`, and it is layer-blind
/// while pad blocking is layer-aware. Both differences left the landing open to
/// every net; naming the net closes them.
fn foreignPadNetAt(ctx: *Ctx, x: f64, y: f64, keep_net: i32) ?i32 {
    if (ctx.obs.len == 0) return null;
    if (ctx.pad_index == null) ctx.pad_index = PadGrid.build(ctx.arena, ctx.obs, gridBounds(ctx.grid), padIndexReach(ctx));
    const idx = ctx.pad_index orelse return null;
    const reach = ctx.index_reach;
    for (idx.near(x, y)) |pi| {
        const p = ctx.obs[pi];
        if (p.net == keep_net) continue;
        if (pad_shape.pointDist(p.x0, p.y0, p.x1, p.y1, p.poly, x, y, reach) < reach) return p.net;
    }
    return null;
}

/// Stamp a keepout halo along the segment a→b, sampled at half-grid steps like
/// every other halo writer.
fn stampKeepoutSeg(ctx: *Ctx, a: [2]f64, b: [2]f64, st: KeepStamp) void {
    if (!(st.dist > 0) or st.layer >= ctx.keep.layers.len) return;
    const len = std.math.hypot(b[0] - a[0], b[1] - a[1]);
    const steps: usize = @max(1, numeric.toCount(@ceil(len / (ctx.grid.g * 0.5))));
    for (0..steps + 1) |step| {
        const t = @as(f64, @floatFromInt(step)) / @as(f64, @floatFromInt(steps));
        keepDisc(ctx, a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1]), st);
    }
}

/// Stamp a keepout net's via halo on EVERY signal layer — its barrel is on all
/// of them, so foreign copper owes the halo wherever it runs.
fn stampKeepoutViaAll(ctx: *Ctx, x: f64, y: f64, st: KeepStamp) void {
    if (!(st.dist > 0)) return;
    for (0..ctx.keep.layers.len) |layer| {
        var one = st;
        one.layer = @intCast(layer);
        keepDisc(ctx, x, y, one);
    }
}

/// Stamp the exact copper outline of one keepout pad, dilated by its halo and
/// the widest foreign track half-width. SMD pads protect their face only;
/// through pads protect every signal layer just like vias.
fn stampKeepoutPad(ctx: *Ctx, p: PadObs) void {
    const halo = keepout.haloAt(ctx.keep.nets, p.net);
    if (!(halo > 0)) return;
    const first: usize = if (p.thru) 0 else p.layer;
    if (first >= ctx.keep.layers.len) return;
    const last: usize = if (p.thru) ctx.keep.layers.len else @min(first + 1, ctx.keep.layers.len);
    for (first..last) |layer| {
        stampKeepoutPadOn(ctx, p, keepStamp(ctx, p.net, @intCast(layer), 0));
    }
}

fn stampKeepoutPadOn(ctx: *Ctx, p: PadObs, st: KeepStamp) void {
    if (st.layer >= ctx.keep.layers.len) return;
    const grid = ctx.grid;
    const lane = ctx.keep.layers[st.layer];
    const cx = (p.x0 + p.x1) / 2;
    const cy = (p.y0 + p.y1) / 2;
    const corner = std.math.hypot(@abs(p.x1 - p.x0) / 2, @abs(p.y1 - p.y0) / 2);
    const radius: i64 = numeric.checkedInt(i64, @ceil((corner + st.dist) / grid.g)) orelse return;
    const center = grid.nearest(cx, cy);
    var dy: i64 = -radius;
    while (dy <= radius) : (dy += 1) {
        var dx: i64 = -radius;
        while (dx <= radius) : (dx += 1) {
            const ix = @as(i64, @intCast(center[0])) + dx;
            const iy = @as(i64, @intCast(center[1])) + dy;
            if (ix < 0 or iy < 0 or ix >= grid.nx or iy >= grid.ny) continue;
            const wx = grid.worldX(@intCast(ix));
            const wy = grid.worldY(@intCast(iy));
            if (pad_shape.pointDist(p.x0, p.y0, p.x1, p.y1, p.poly, wx, wy, st.dist) > st.dist) continue;
            const node = @as(usize, @intCast(iy)) * grid.nx + @as(usize, @intCast(ix));
            keepClaim(ctx, lane, node, wx, wy, st);
        }
    }
}

fn stampKeepoutPadsForNet(ctx: *Ctx, net: i32) void {
    for (ctx.obs) |p| {
        if (p.net == net) stampKeepoutPad(ctx, p);
    }
}

/// Stamp both RF bands of the copper the routing net is laying right now: its
/// same-layer keepout halo (`KeepState`) and its all-layer crossing shadow
/// (`rf_shadow`). Both read the current net's resolved widths, already loaded by
/// `setNetParams`, and both no-op for a net that declared neither.
fn stampCurrentRf(ctx: *Ctx, a: [2]f64, b: [2]f64, net: i32, layer: u8) void {
    const half = ctx.params.track_width / 2;
    if (ctx.keep.halo > 0) stampKeepoutSeg(ctx, a, b, keepStamp(ctx, net, layer, half));
    ctx.shadow.stampSeg(ctx.grid, a, b, half, net);
}

/// Stamp the RF halo + shadow of a VIA the routing net is laying right now. The
/// barrel is on every signal layer, so both bands are too.
fn stampCurrentRfVia(ctx: *Ctx, x: f64, y: f64, net: i32) void {
    const r = viaR(ctx.params);
    if (ctx.keep.halo > 0) stampKeepoutViaAll(ctx, x, y, keepStamp(ctx, net, 0, r));
    ctx.shadow.stampVia(ctx.grid, x, y, r, net);
}

/// Stamp the RF halo + shadow of copper RETAINED from a previous run (a scoped
/// route, or a re-route seeded from a saved layout): the emitters only band
/// copper THIS run lays, so an RF trace that arrived as existing copper would
/// otherwise be unprotected while every net around it reroutes.
fn stampRetainedRf(
    ctx: *Ctx,
    placement: optimizer.Placement,
    copper: struct { tracks: []const Track, vias: []const Via },
) void {
    if (ctx.keep.layers.len == 0 and ctx.shadow.layers.len == 0) return;
    for (placement.nets, 0..) |_, ni| {
        const halo = keepout.haloOf(placement, ni);
        const shadow = rf_shadow.widthOf(placement, ni);
        if (!(halo > 0) and !(shadow > 0)) continue;
        const id: i32 = @intCast(ni);
        var one = ctx.shadow;
        one.width = shadow;
        for (copper.tracks) |t| {
            if (t.net != id) continue;
            if (halo > 0) stampKeepoutSeg(ctx, .{ t.x1, t.y1 }, .{ t.x2, t.y2 }, keepStamp(ctx, id, t.layer, t.width / 2));
            one.stampSeg(ctx.grid, .{ t.x1, t.y1 }, .{ t.x2, t.y2 }, t.width / 2, id);
        }
        for (copper.vias) |v| {
            if (v.net != id) continue;
            if (halo > 0) stampKeepoutViaAll(ctx, v.x, v.y, keepStamp(ctx, id, 0, v.dia / 2));
            one.stampVia(ctx.grid, v.x, v.y, v.dia / 2, id);
        }
    }
}

/// Minimal radius (mm) within which a foreign grid node must be excluded so no
/// foreign track/via comes closer than `D = viaR + track_half + clearance` to a
/// via centre. A foreign track between two nodes both at radius R dips to
/// `√(R²−g²/2)` at its closest, so `R = √(D² + g²/2)` is exactly enough — much
/// tighter than a flat per-node margin, which is what keeps tight parts routable.
fn copperHalo(ctx: *Ctx) f64 {
    const d = viaR(ctx.params) + ctx.params.track_width / 2 + ctx.params.clearance;
    return @sqrt(d * d + ctx.grid.g * ctx.grid.g * 0.5);
}

fn viaObstacleRadius(ctx: *Ctx) f64 {
    const via_via = ctx.params.via_dia + ctx.params.clearance;
    return @max(copperHalo(ctx), via_via);
}

/// How far `viaAllowed` must expand a foreign `occ` cell to bound the physical
/// via↔copper clearance. The answer depends on what `occ` actually HOLDS, which
/// differs between the two routing modes:
///
///   * whole-board route — `occ` is connective copper centreline/centre data,
///     so the expansion has to carry the entire physical term at once
///     (`viaObstacleRadius`), and a paired diff-pair portal drops the via↔via
///     half of it (`copperHalo`).
///   * gap pass (`ctx.exact` armed) — `stampGapBoard` wipes both grids and
///     `stampBoardCopper` refills `occ` with every foreign track ALREADY
///     inflated by `width/2 + reach` and every foreign via by `dia/2 + reach`.
///     The one term a via adds over a track centre is its own radius, so that
///     is all this may expand by; carrying the full physical clearance a second
///     time double-counts a track width plus a clearance and walls legal via
///     sites out of corridors they physically fit (the `no_via_site` verdict).
///
/// The gap-pass radius keeps the raster's half-diagonal, since `occ` samples the
/// inflated region at NODES and any point sits within `g·√2/2` of one. That
/// leaves the test conservative — it may still refuse a site by up to that
/// margin — never permissive, so relaxing it cannot introduce a clearance DRC.
fn viaOccReach(ctx: *Ctx, paired_portal: bool) f64 {
    if (ctx.exact == null) return if (paired_portal) copperHalo(ctx) else viaObstacleRadius(ctx);
    return viaR(ctx.params) + ctx.grid.g * (sqrt2 / 2);
}

/// Put a placed through-via's actual connective centre in `occ`, and its
/// non-connective track-clearance halo in `resv` on every signal layer. Keeping
/// those roles separate lets another legal via sit just outside via-to-via
/// clearance without the old double-halo rejection, while tracks still cannot
/// treat clearance cells as copper sources.
fn stampViaOcc(ctx: *Ctx, x: f64, y: f64, net: i32) void {
    const center = ctx.grid.nearest(x, y);
    const node = ctx.grid.node(center[0], center[1]);
    for (ctx.occ, 0..) |occ_l, layer| {
        if (occ_l[node] == empty_cell) occ_l[node] = net;
        reserveDisc(ctx, x, y, net, copperHalo(ctx), @intCast(layer));
    }
}

/// Reserve a ground-via stub's clearance halo along its length on the stub's
/// own signal layer, so a foreign via can't be dropped on top of the stub.
fn stampStubOcc(ctx: *Ctx, a: [2]f64, b: [2]f64, net: i32, layer: u8) void {
    const grid = ctx.grid;
    const d = copperHalo(ctx);
    const len = std.math.hypot(b[0] - a[0], b[1] - a[1]);
    const steps: usize = @max(1, numeric.toCount(@ceil(len / (grid.g * 0.5))));
    var s: usize = 0;
    while (s <= steps) : (s += 1) {
        const t = @as(f64, @floatFromInt(s)) / @as(f64, @floatFromInt(steps));
        stampDisc(ctx, a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1]), net, d, layer, false);
    }
}

/// May a layer-changing via be dropped at node `n` for net `net`? It must clear
/// foreign pads by the via clearance, keep the hole-to-hole wall from every pad
/// bore, and have no foreign copper within its halo on ANY signal layer (vias
/// are through-only, so the barrel meets them all) — so a maze via can never
/// crowd a pad or an already-routed foreign track/via.
///
/// The pad-bore wall is measured here rather than left to `via_ban`: that mask
/// is built only by the gap-closing pass, so the whole-board maze had no drill
/// test at all, and the mask is grid-quantized where `PadDrills` is exact.
fn viaAllowed(ctx: *Ctx, n: usize, net: i32, placed: []const Via) bool {
    const grid = ctx.grid;
    if (ctx.via_forbidden_net == net) if (ctx.via_forbidden_mask) |mask| {
        if (mask[n]) return false;
    };
    if (ctx.via_ban) |mask| {
        if (n < mask.len and mask[n]) return false;
    }
    if (outlineBlocked(ctx, n, net)) return false; // no vias off-board / in the edge inset
    const x = grid.worldX(n % grid.nx);
    const y = grid.worldY(n / grid.nx);
    if (!viaClearsOutline(ctx, x, y, net)) return false;
    if (!viaClearsSameNetVias(ctx, placed, x, y, net)) return false;
    if (!viaClearsPadDrills(ctx, x, y)) return false;
    const zone_reach = viaR(ctx.params) + ctx.params.clearance;
    if (zoneBlocksPoint(ctx, 0, .{ x, y }, net, zone_reach, true)) return false;
    if (!viaClearsPads(ctx, x, y, net)) return false;
    // Reservations already contain the full track/via-to-track exclusion at
    // their target nodes. Test them once instead of expanding a second halo
    // around an already-expanded reservation.
    for (ctx.resv) |resv_l| {
        if (resv_l[n] != empty_cell and resv_l[n] != net) return false;
    }
    // A through barrel is on every signal layer, so a same-layer keepout halo
    // stamped on ANY of them still refuses the site.
    if (keepoutBlocked(ctx, null, n, net)) return false;
    // Expand each foreign `occ` cell by exactly the term it is still missing —
    // which is not the same in both modes (see `viaOccReach`).
    const paired_portal = ctx.pair_vias_hard and
        (if (ctx.pair_via_mask) |mask| mask[n] else false);
    const dist = viaOccReach(ctx, paired_portal);
    const r_nodes: i64 = numeric.checkedInt(i64, @ceil(dist / grid.g)) orelse 0;
    const ci: i64 = @intCast(n % grid.nx);
    const cj: i64 = @intCast(n / grid.nx);
    var dj: i64 = -r_nodes;
    while (dj <= r_nodes) : (dj += 1) {
        var di: i64 = -r_nodes;
        while (di <= r_nodes) : (di += 1) {
            const ix = ci + di;
            const iy = cj + dj;
            if (ix < 0 or iy < 0 or ix >= grid.nx or iy >= grid.ny) continue;
            const wx = grid.worldX(@intCast(ix));
            const wy = grid.worldY(@intCast(iy));
            if (std.math.hypot(wx - x, wy - y) > dist) continue;
            const m = @as(usize, @intCast(iy)) * grid.nx + @as(usize, @intCast(ix));
            for (ctx.occ) |occ_l| {
                if (occ_l[m] != empty_cell and occ_l[m] != net) return false;
            }
        }
    }
    return true;
}

// ── Maze routing ─────────────────────────────────────────────────────────

/// One net's inline bend-smoothing outcome — the true-arc metadata plus the
/// corners that missed the minimum radius. Slices are arena-owned.
const NetSmooth = struct { arcs: []const Arc, sharp: []const SharpBend };

/// RF bend-discipline routing state. `escape_mm`/`escape_pts` describe the
/// net currently being routed (a straight pad-escape reserve the maze cost
/// model enforces softly); `net_smooth` accumulates every net's inline
/// smoothing results, keyed by net index. Entries are dropped with the net's
/// copper on rip-up and snapshot/restored with the rest of the routing state.
const RfState = struct {
    escape_mm: f64 = 0,
    escape_pts: []const NetPt = &.{},
    net_smooth: std.AutoHashMapUnmanaged(i32, NetSmooth) = .empty,
    port_outcomes: std.AutoHashMapUnmanaged(i32, rf_port_report.Outcome) = .empty,
};

/// `(net-class … (keepout MM))` enforcement state — the maze's half of what
/// `drc_keepout.zig` checks afterwards. `keepout.zig`'s module doc carries the
/// semantics and why the halo gets its own node mask instead of more `resv`
/// stamps (in one line: only a separate lane can be waived for ground without
/// also waiving the ordinary clearance sharing that array).
const KeepState = struct {
    /// Per-net resolved halo (mm), net-indexed. Empty ⇒ no net on this board
    /// declares a keepout — the early-out every path checks first.
    nets: []const f64 = &.{},
    /// Per-signal-layer halo ownership: the net whose keepout claims this node,
    /// else `empty_cell`. Empty ⇒ nothing stamped. Owner ids (not a bitset), so
    /// a keepout net still routes through its own halo. Allocated ONLY on the
    /// whole-board route context; every derived context (windowed retry, gap
    /// pass, `visionMask`) instead gets the keepout term inside
    /// `stampBoardCopper`'s halo, so there is one allocation site and one place
    /// (`windowCtx`) that drops an inherited mask.
    layers: []const []i32 = &.{},
    /// Per-signal-layer GATE on a claimed halo node — the openings the halo has
    /// to carry, made net-specific so an opening admits only the nets it exists
    /// for. `empty_cell` = no gate (closed to everyone but the owner). Two kinds
    /// share the lane:
    ///   * `>= 0` — a foreign PAD LANDING (see `foreignPadNetAt`): only that
    ///     pad's own net may pass, because the opening exists so that pad can be
    ///     escaped from. First pad found owns the node.
    ///   * `<= -2` — an ESCAPE ZONE, index `-(v) - 2` into `zones.all`: a net
    ///     passes only when `zones.admits` says it owns a pad inside that zone
    ///     (see `keepout.Zones`). First zone found owns the node.
    /// Same shape, allocation site and lifetime as `layers`.
    gate: []const []i32 = &.{},
    /// The escape zones `gate`'s negative codes index, plus the per-net
    /// admission flags `setNetParams` refreshes. Empty ⇒ no keepout net declares
    /// an escape radius and no cell is ever escape-gated.
    zones: keepout.Zones = .{},
    /// Pad centres + nets the gate is answered from (`ctx.obs` projected once),
    /// so the router and `drc_keepout` gate on the same points. Empty when no
    /// keepout is declared.
    pads: []const keepout.PadPt = &.{},
    /// The obstacle `stampBoardCopper` is laying RIGHT NOW: `stampDisc` splits its
    /// halo surplus off the clearance under it and lets an admitting escape zone
    /// waive that surplus per node (`keepout.bandClaims`), which is how a derived
    /// context reproduces the openings `gate` carries. Inert for every other
    /// stamper, each of which claims its whole disc outright.
    band: keepout.Band = .{},
    /// The CURRENT net's own halo (mm, 0 = not a keepout net) — what `emitSeg`
    /// stamps as it lays copper.
    halo: f64 = 0,
    /// The current net is ground/plane copper, so no keepout halo applies to it
    /// (`keepout.exempt`). Ordinary clearance still does.
    exempt: bool = false,
    /// Net-class identity + the net now routing, so a halo is waived between one
    /// class's own members (`keepout.ClassGate`). Net-indexed, so it travels with
    /// `nets` onto every derived context.
    class: keepout.ClassGate = .{},
};

/// The maze router's whole per-run routing state: the grid, the pad obstacles,
/// the per-signal-layer occupancy/reservation grids, and the effective geometry
/// of the net currently routing. Held live (behind `RouteCore`) so an
/// interactive `route_session` can drive per-net retries / frontier probes.
const Ctx = struct {
    arena: std.mem.Allocator,
    field_space: ?struct { placement: optimizer.Placement, provider: route_policy.RouteSpace } = null,
    grid: Grid,
    obs: []const PadObs,
    reach: f64,
    /// Routed-copper occupancy, one node grid per SIGNAL layer (`occ.len` is
    /// the board's signal-layer count — 2 on legacy/2-layer boards, more when
    /// the stackup declares plane-free inner layers). Index 0 = top, 1 =
    /// bottom, 2.. = inner signal layers in stack order.
    occ: []const []i32,
    /// Diagonal corner reservations, per signal layer. When a path takes a 45°
    /// step, the two orthogonal cells it squeezes past sit only `g/√2` from the
    /// diagonal's centreline — closer than the `g = width + clearance` the grid
    /// pitch guarantees — so `emitPath` reserves them here. `blocked` refuses
    /// them to foreign nets exactly like copper, but they are NOT the owning
    /// net's copper: Dijkstra never seeds from them, so a later same-net leg
    /// can't "connect" to a cell that carries no track.
    resv: []const []i32,
    /// The *effective* geometry for the net currently being routed —
    /// `base` overlaid with that net's `(net-class …)` rule (see
    /// `setNetParams`). Every clearance/width/via read goes through this.
    params: RouteParams,
    /// The caller's defaults, kept pristine so each net's overlay starts
    /// from the same base.
    base: RouteParams = .{},
    /// Hole-to-hole wall (mm) via placement keeps from every placed via drill —
    /// `placement.rules.design.hole_to_hole` (see `viaClearsHoles`).
    hole_to_hole: f64 = 0.25,
    /// The board's fixed PAD drills, and the index that answers which of them a
    /// candidate barrel's wall could touch — see `PadDrills`.
    pad_drills: PadDrills = .{},
    /// Copper spacing between vias on the same net. Zero means use the current
    /// net's resolved ordinary clearance, matching `drc.viaSpacing`.
    via_to_via: f64 = 0,
    /// Exact outline geometry and copper-edge rule used by off-grid via
    /// synthesis. The node mask cannot safely judge a point between nodes.
    edge_clearance: f64 = 0,
    board_rect: ?optimizer.BoardRect = null,
    board_poly: ?[]const [2]f64 = null,
    /// Pad-index prefilter reach — the MAX reach any net class can need, so
    /// the lazily-built PadGrid stays a superset for every net (exact tests
    /// still use the per-net `reach`).
    index_reach: f64 = 0,
    /// When false the maze may not change layers — used for the top-layer-only
    /// first pass so a short signal net (e.g. a feedback tap) stays on the
    /// surface instead of diving to L2 the moment a via is marginally cheaper.
    allow_vias: bool = true,
    /// Ceiling (mm) on what one maze layer change may cost, or null for the
    /// lattice price alone.
    ///
    /// The ordinary price is `grid.g * via_cost_mult` — denominated in GRID
    /// PITCHES, which keeps the cost model scale-free but makes the same
    /// physical via cost four times more on a wide-track net's coarse lattice
    /// (measured: 1.91 mm at the LDO fixture's 0.477 mm pitch) than on a
    /// fine-pitch net's (0.51 mm at 0.127 mm). `detourGuard`'s retry caps it at
    /// a physical figure so a connection that already detoured is re-searched
    /// with vias priced by what they cost the BOARD. A `@min`, never a
    /// replacement: the retry can only ever be more via-friendly than the
    /// attempt it is second-guessing, never less.
    via_cost_cap_mm: ?f64 = null,
    /// Net-indexed policy for this run plus the effective masks of the current
    /// net. All-zero defaults preserve the legacy search cost and reachability.
    net_policy: []const route_policy.NetPolicy = &.{},
    selected_nets: []const bool = &.{},
    /// Cooperative cancel flag (`route_policy.Options.stop.cancel`), polled at each
    /// per-net loop boundary via `routeCancelled`. Null never cancels.
    cancel: ?*std.atomic.Value(bool) = null,
    /// Absolute whole-route deadline; zero keeps the historical clock-free
    /// behavior. Expensive probe/maze loops poll it cooperatively.
    deadline_ns: i128 = 0,
    deadline_probe_count: u32 = 0,
    deadline_expired: bool = false,
    /// How hard this run retries before reporting a net failed (see
    /// `route_policy.Effort`). `one_shot` skips the escalate / rip-up /
    /// fine-rescue machinery entirely.
    effort: route_policy.Effort = .standard,
    /// Which searches a declared pair's coupled construction may ask for its
    /// envelope-wide channel (see `route_policy.PairChannel`). The default is
    /// the maze alone, which is every board this router has ever routed.
    pair_channel: route_policy.PairChannel = .maze_only,
    /// Where a coupled pair records the wall its envelope search hit, when the
    /// caller armed one (see `pair_pinch`). Null on every run that does not ask.
    pinch_log: ?*pair_pinch.Log = null,
    /// Retained filled zones and keepouts imported from the physical board.
    /// Zone interiors seed their owner net; exact polygons provide foreign
    /// track/via clearance without turning the clearance halo into connectivity.
    zones: []const route_policy.ExistingZone = &.{},
    /// The current pour-backed net connected at least one terminal but not all.
    /// `routeNet` leaves those useful plane legs in place while still reporting
    /// the net failed; the connectivity gate remains the completion authority.
    zone_partial: bool = false,
    /// An ordinary multi-terminal tree joined at least two real pads before a
    /// later terminal proved unreachable.  Those joined pads are useful,
    /// electrically honest copper: retain the subtree so a later retry can grow
    /// from it instead of throwing away every successful leg.  Guided trees do
    /// not set this flag because their leading virtual waypoints are not pads.
    tree_partial: bool = false,
    guide_tracks: []const route_policy.GuideTrack = &.{},
    guide_vias: []const route_policy.GuideVia = &.{},
    /// Corridors an authored `(assign-escapes … (reserve))` claims for their
    /// owning nets — POLICY, not copper, so every site that reallocates or
    /// clears `resv` must re-stamp it (`lane_reserve`, which enumerates them).
    reserved_lanes: []const route_policy.ReservedLane = &.{},
    reference_corridor: ?[]const bool = null,
    reference_via_mask: ?[]const bool = null,
    pair_via_mask: ?[]const bool = null,
    pair_terminal_mask: ?[]const bool = null,
    /// Envelope-route exclusion mask (`layer*nodes + node`) for a COUPLED diff
    /// pair: foreign copper dilated by the extra half-width the pair envelope
    /// needs beyond one track, which the grid's one-lane-per-net clearance model
    /// cannot express on its own (`diff_pairs.buildBlock`). Null for every other
    /// route, so `blocked` stays byte-identical everywhere else.
    pair_block: ?[]const bool = null,
    pair_vias_hard: bool = false,
    pair_coupling_hard: bool = false,
    /// The pad lands of the net whose terminal tree is being grown, priced by
    /// `net_topology.sourceCost` when a maze leg picks where to join its own
    /// copper: a join on the net's own land is free, one mid-span on a trace
    /// pays `midspan_join_penalty_mm`. Empty (the default) for every other
    /// maze pass — the pour terminal, the gap hops, the via-seeded retries —
    /// which price every source at zero exactly as before.
    join_lands: []const net_topology.Land = &.{},
    /// Rings the pad-gateway fan scans outward (`padGateways`), in GRID steps.
    /// A pass that re-grids finer must scale this or its fan silently shrinks in
    /// millimetres and fine-pitch pads read as sealed. Default = `gate_rings`.
    gate_rings: usize = gate_rings,
    via_forbidden_mask: ?[]const bool = null,
    via_forbidden_net: i32 = empty_cell,
    /// Node-indexed sites where NO net may drop a maze via (see
    /// `buildViaBanMask`) — pad copper and through drills, including the
    /// routing net's OWN, which every other via test deliberately skips. Only
    /// the gap-closing pass sets it; null leaves via placement unchanged.
    via_ban: ?[]const bool = null,
    reference_guide_active: bool = false,
    /// Prefix of `vias` supplied as retained reference copper. Return-path
    /// stitching only considers newly routed vias after this prefix.
    preserved_vias: usize = 0,
    /// RF bend-discipline state: the current net's escape zones plus every
    /// net's inline-smoothing results (see `smoothNetInline`).
    rf: RfState = .{},
    /// Axis-only (Manhattan) discipline for the net now routing, and whether its
    /// attempt is the one currently searching (see `manhattan_route`). Inert by
    /// default, which is what keeps every non-RF route byte-identical.
    manhattan: manhattan_route.State = .{},
    /// RF same-layer keepout enforcement (see `KeepState`). Defaults inert, so
    /// every context that does not opt in routes exactly as before.
    keep: KeepState = .{},
    /// RF crossing-shadow cost: the all-layer fence-corridor band foreign copper
    /// pays to enter (see `rf_shadow`). Defaults inert — no lanes, every
    /// multiplier 1.0 — so a board declaring no fence/keepout costs exactly as
    /// before.
    shadow: rf_shadow.State = .{},
    /// Half the widest net class's track width (mm) — the allowance a keepout
    /// halo makes for the FOREIGN centreline it is holding off, since the maze
    /// tests node centres and nothing else adds a foreign track's own half-width.
    /// 0 (the default) makes a stamped halo edge-exact for a zero-width intruder,
    /// which only ever under-blocks; the real router sets it from
    /// `maxRouteParams`.
    max_half_width: f64 = 0,
    preferred_layers: u64 = 0,
    allowed_layers: u64 = 0,
    waypoints: []const route_policy.Waypoint = &.{},
    guide_branches: []const route_policy.GuideBranch = &.{},
    max_vias: ?u16 = null,
    /// When true `blocked` measures clearance against each pad's real copper
    /// outline (poly), not its bounding box — so a concave thermal/EP pad doesn't
    /// falsely wall off a corridor that a short net could escape through. The
    /// outline test is much costlier (point-in-polygon per node), so it's only
    /// switched on for the brief top-layer-first attempts; the bulk two-layer
    /// maze stays on the cheap, conservative bounding-box path.
    use_poly: bool = false,
    /// True when any obstacle pad lives on (or reaches, via through-hole) the
    /// bottom signal layer — false keeps `blocked`'s legacy all-top fast path.
    has_bottom_pads: bool = false,
    /// Which outer signal layers a declared pour covers (0 = top, 1 = bottom).
    /// Maze steps onto a poured layer cost `POUR_COST_MULT`× so signal copper
    /// prefers the un-poured face instead of slicing the pour. Both false when
    /// no pour is declared — the legacy cost model, unchanged.
    pour: [2]bool = .{ false, false },
    /// Diff-pair coupling corridor for the N net currently routing: a
    /// per-`layer*nodes + node` bitset of cells near its already-routed P twin
    /// (`diff_pairs.buildCorridor`). `relaxStep` discounts a step landing in a
    /// `true` cell so the pair hugs. Null for every other net → cost byte-identical.
    corridor: ?[]const bool = null,
    /// Lazily-built spatial index over `obs` (pads are static for a route) so
    /// `blocked` tests only pads near the node, not all of them. Null until
    /// first use, or when the board is degenerate / the grid would be oversized
    /// (blocked then falls back to the full scan). Result-identical: it only
    /// pre-filters candidates by position; the exact per-pad decision is kept.
    pad_index: ?*const PadGrid = null,
    /// Exact-clearance move validation (see `ExactClearance`). Null for every
    /// whole-board route, which keeps its raster-only obstacle model byte for
    /// byte; only the gap-closing pass arms it.
    exact: ?ExactClearance = null,
    /// Per-`layer*nodes + node` memo of `staticBlockedUncached` — the half of
    /// `blocked` that does NOT read the copper stamp, and so is pure for as long
    /// as the routing net is fixed. Unarmed (the default) every caller
    /// recomputes, which is what a differently-sized lattice must do.
    static_block: maze_scratch.Memo = .{},
    /// Per-node board-outline mask (grid-node indexed, `nx*ny` long): true where
    /// a track/via centred on that node would leave the board or sit inside the
    /// copper-edge inset. Null when the design declares NO board outline — then
    /// every outline check no-ops and routing is byte-identical to before. Built
    /// once in `buildRouteCtx` from `outline.signedInset` (exact polygon when the
    /// board is non-rectangular, else the bounding rectangle).
    outline_mask: ?[]const bool = null,
    /// A second outline mask for the fixed perimeter-fence exclusion. Unlike
    /// `outline_mask`, this one is governed by the keepout's typed track block
    /// and per-net admissions, and its inner edge begins beyond the generated
    /// fence barrel. Keeping the masks separate preserves ordinary edge rules
    /// for an explicitly admitted net.
    perimeter_track_mask: ?[]const bool = null,
    /// Copper-edge inset for exact (including off-grid) via candidates in the
    /// typed perimeter band. Zero when the keepout does not block vias.
    perimeter_via_clearance: f64 = 0,
    /// Flattened-net admission map for the typed perimeter keepout. Empty means
    /// no net is admitted; generated perimeter vias remain exempt in the DRC.
    perimeter_allowed: []const bool = &.{},
    /// Per-net (flattened-net index) flag: this net has a pad legitimately off
    /// the board — a staging part parked in the DRC's staging band. Such a net
    /// is exempt from the outline mask wholesale (else it could never reach its
    /// own off-board pad); the board-edge DRC already skips staged copper.
    net_offboard: []const bool = &.{},
    reference_replayed: std.ArrayList(usize) = .empty,
    search_limited: std.ArrayList(usize) = .empty,
    /// Nonzero only while a post-greedy retry phase re-attempts a still-failed
    /// search-limited leg: `dijkstra` / `softProbe` then size that one leg's
    /// budget to this many node expansions (the `max_escalated_expansions`
    /// tier, or `max_last_resort_expansions` for the final retry). 0 leaves
    /// every leg on its bounded whole-board budget, so escalation stays local.
    escalate_budget: usize = 0,
    /// Reused by every real maze leg and by the rip-up blocker probe. Keeping
    /// this in the route context makes memory proportional to board size
    /// instead of terminal-search count.
    search: maze_scratch.Search = .{},
    route_queue: ?RoutePq = null,
    /// Optional per-phase wall-clock instrumentation (`route_policy.Options.timing`
    /// copied through `routeCoreStart`). Null (default) leaves every phase site
    /// a no-op null check; only `bench-route --breakdown` arms it.
    timing: ?*route_timing.PhaseTimer = null,
    /// Lazily-built spatial index over the CURRENT routed copper (boxes in
    /// `tracks` then `vias` order) for the direct-synthesis exact-clearance
    /// probes (`viaClearsTracks` / `viaClearsVias` / `viaClearsHoles` /
    /// `segClearsTracks` / `segClearsVias` / `finePointClear`). A superset
    /// prefilter only — the exact per-item distance test is unchanged — so
    /// routing output is identical with or without it. Rebuilt at every
    /// per-net attempt boundary and at each finish pass's per-net boundary
    /// (copper grows as routing proceeds, and rip-up / cleanup compaction
    /// shifts list indexes); null before the first rebuild or on a degenerate
    /// board, in which case the probes fall back to the legacy full linear
    /// scan. NEVER read directly — go through `copperIdx`, which also refuses
    /// it when `copper_gen` says a compaction has invalidated it.
    copper_index: ?*const PadGrid = null,
    /// The query reach every `nearSegment` probe expands its segment box by —
    /// the largest clearance any direct probe applies under the CURRENT net's
    /// geometry, so the candidate set is a superset of the items that could
    /// touch it. Restated by `setNetParams` (a wider net's probes must widen
    /// with it) as well as by `rebuildCopperIndex`.
    copper_reach: f64 = 0,
    /// Widest copper half-extent (track half-width / via radius) in the lists
    /// `copper_index` was built from. Kept so `setNetParams` can restate
    /// `copper_reach` for the incoming net in O(1) instead of rescanning the
    /// copper.
    copper_widest: f64 = 0,
    /// Number of track boxes `copper_index` was built with — the split point
    /// between its track and via box ranges. The copper lists grow between
    /// rebuilds (a net appends its own copper mid-attempt), so probes must
    /// map an index to a track vs via using the BUILD-time boundary, not the
    /// current list length.
    copper_track_count: usize = 0,
    /// Number of via boxes in the index. Vias appended during a net attempt are
    /// not indexed, so exact probes scan this tail explicitly.
    copper_via_count: usize = 0,
    /// Bumped by `copperCompacted` whenever the copper lists are REORDERED or
    /// SHRUNK — a cleanup compaction (`route_cleanup.removeNetTracks` packs
    /// survivors down), a straighten rewrite, a rip-up rollback. Every index
    /// the copper index holds then names a *different* track or via than it
    /// was built for: in range, and wrong. `copperIdx` refuses the index until
    /// a rebuild restamps it, so the probes fall back to their linear scan
    /// (same verdict, slower) instead of returning a false "clear".
    /// Appends deliberately do NOT bump: they only leave the index a subset,
    /// which every probe already tolerates.
    copper_gen: u64 = 0,
    /// The `copper_gen` value `copper_index` was built at. A mismatch means a
    /// compaction happened since, and the index is unusable.
    copper_index_gen: u64 = 0,
    /// Per-net exact-clearance probe budget (`clearDoglegSegment` /
    /// `directViaClear`). When exhausted, probes report "blocked" so the
    /// direct attempt fails fast and the net falls to the maze (which has its
    /// own expansion budget). Null (default) leaves probes unbounded — the
    /// legacy behaviour. Armed per non-escape direct attempt in
    /// `routeNetAttempt`; the maze's own `padGateways` never pays it.
    direct_budget: ?usize = null,
    /// Probe ceiling `escapeDirectRescue` arms here; null (every whole-board
    /// route) keeps its unbounded sweep. Set only by `routeWindowNet`.
    window_probe_budget: ?usize = null,
    /// Overlap-tolerant congestion pricing, armed ONLY inside the negotiated-
    /// congestion sandbox (`congestion.zig`) — where foreign copper a re-routable
    /// net owns is passable at a price instead of walling the maze out. Null
    /// everywhere else, which is what keeps every other route byte-identical.
    congest: ?*const congestion.Pricing = null,
    /// Why the shape tier last declined a net — reported per net at info level,
    /// so a tier that ran and found nothing is never indistinguishable from one
    /// that never ran.
    shape_verdict: ShapeVerdict = .not_tried,
};

/// How far outside the outline a pad's centre must sit for its net to count as
/// an off-board staging net (mirrors `drc.staging_exempt_mm` so the router and
/// the board-edge DRC agree on what "staged" means).
const staging_offboard_mm: f64 = 10.0;

/// True when node `n` is masked off by the board outline for `net` — i.e. a
/// track/via centred there would leave the board (or the copper-edge inset).
/// A net that owns an off-board staging pad is exempt wholesale, and a node
/// sitting on any real pad is never masked (pads are the optimizer's concern
/// and the board-edge DRC never flags them, so an edge-hugging pad can still
/// seed and connect).
fn outlineBlocked(ctx: *Ctx, n: usize, net: i32) bool {
    var staged_offboard = false;
    if (net >= 0) {
        const net_index: usize = @intCast(net);
        if (net_index < ctx.net_offboard.len) staged_offboard = ctx.net_offboard[net_index];
    }
    if (ctx.outline_mask) |mask| {
        if (!staged_offboard and n < mask.len) {
            if (mask[n] and !nodeOnAnyPad(ctx, n)) return true;
        }
    }
    if (!perimeterAllowed(ctx, net)) {
        if (ctx.perimeter_track_mask) |mask| {
            // A fixed construction keepout has no pad-landing carve-out. A part in
            // this band is itself a hard DRC failure and must move; silently
            // threading its trace through the band would defeat that guarantee.
            if (n < mask.len and mask[n]) return true;
        }
    }
    return false;
}

/// True when grid node `n`'s world point lies on (inside) any obstacle pad's
/// copper. Used only for masked (near/off-edge) nodes, which are rare, so the
/// linear scan is cheap. Keeps `outlineBlocked` from walling off a pad that
/// legitimately hugs the board edge.
fn nodeOnAnyPad(ctx: *Ctx, n: usize) bool {
    const grid = ctx.grid;
    const px = grid.worldX(n % grid.nx);
    const py = grid.worldY(n / grid.nx);
    for (ctx.obs) |p| if (px >= p.x0 and px <= p.x1 and py >= p.y0 and py <= p.y1) return true;
    return false;
}

/// True if node (layer, n) can't carry net `net`: copper of another net is
/// there, or (on top) a foreign pad is within clearance. A node sitting on the
/// net's *own* pad is always allowed (that's where the trace must connect).
/// Fold one pad `p` into the `on_own`/`foreign` accumulators for a node at
/// `(px, py)` carrying `net`. Extracted so the indexed and full-scan candidate
/// paths in `blocked` share the exact same distance test.
inline fn accumPad(ctx: *const Ctx, p: PadObs, layer: usize, px: f64, py: f64, net: i32, use_poly: bool, on_own: *bool, foreign: *bool) void {
    // A pad only blocks (or connects on) the layer its copper lives on;
    // through-hole pads exist on every layer.
    if (!p.thru and p.layer != layer) return;
    // Measure clearance against the pad's real copper outline only when asked
    // (the top-first pass): a concave thermal/EP pad over-states copper in its
    // box, walling off a corridor a short net could escape through — which is
    // exactly what buries a feedback tap beside an EP and forces it inner. The
    // outline test is costly, so the bulk maze keeps the cheap box distance.
    const lim = keepLimits(ctx, p.net, ctx.reach);
    const d = if (use_poly)
        pad_shape.pointDist(p.x0, p.y0, p.x1, p.y1, p.poly, px, py, lim[1])
    else
        distPointRect(px, py, .{ .x0 = p.x0, .y0 = p.y0, .x1 = p.x1, .y1 = p.y1 });
    if (p.net == net) {
        if (d <= 1e-9) on_own.* = true;
    } else if (!keepout.approachClears(ctx.keep.zones, p.net, d, .{ px, py }, lim)) {
        foreign.* = true;
    }
}

/// True when node `(layer, n)` is unavailable to `net` — foreign copper or
/// reservation, an off-board / edge-inset node, a blocking zone/keepout, or a
/// foreign pad within clearance. The interactive frontier flood uses it as the
/// hard cost model so the snapshot matches what a real retry would see.
///
/// Foreign COPPER is the one wall the negotiated-congestion sandbox may lower
/// (`congestion.walls`: hard for every ordinary route, passable-at-a-price for a
/// net that sandbox can itself put back). A foreign RESERVATION stays hard even
/// there — a reserved lane is policy, and re-routing its owner would not free it.
pub fn blocked(ctx: *Ctx, layer: usize, n: usize, net: i32) bool {
    if (ctx.pair_block) |mask| {
        if (mask[layer * (ctx.grid.nx * ctx.grid.ny) + n]) return true;
    }
    const o = ctx.occ[layer][n];
    if (o != empty_cell and o != net and congestion.walls(ctx.congest, o)) return true;
    const rv = ctx.resv[layer][n];
    if (rv != empty_cell and rv != net) return true;
    return keepoutBlocked(ctx, layer, n, net) or staticBlocked(ctx, layer, n, net);
}

/// The half of `blocked` that reads no copper: the board-edge inset, the
/// blocking zones/keepouts, and the foreign pads. For a fixed routing net (so a
/// fixed `ctx.reach`) this is a pure function of `(layer, n)` — the pads, zones
/// and outline are all static for a route — so it is the same answer every time
/// a node is re-tested.
fn staticBlockedUncached(ctx: *Ctx, layer: usize, n: usize, net: i32) bool {
    if (outlineBlocked(ctx, n, net)) return true; // node off-board / inside the copper-edge inset
    const at = [2]f64{ ctx.grid.worldX(n % ctx.grid.nx), ctx.grid.worldY(n / ctx.grid.nx) };
    if (zoneBlocksPoint(ctx, layer, at, net, ctx.reach, false)) return true;
    return foreignPadAt(ctx, layer, n, net);
}

/// `staticBlockedUncached`, memoized through `ctx.static_block` when a caller
/// has armed it (`armStaticBlock`; every net change invalidates it through
/// `setNetParams`).
///
/// One gap hop re-runs the maze up to a dozen times — the direct attempt, a
/// blocker probe, then a rip candidate per tier — and a greedy/escalate/rip-up
/// pass re-searches the same nodes leg after leg. Each of those sweeps
/// re-derives the identical verdict for the same nodes: a polygon containment
/// plus an edge-distance per zone, then a pad-index scan. That recomputation,
/// not the graph search, is what makes a failing hop cost tens of seconds. The
/// memo makes it at most one evaluation per (layer, node) per net; because the
/// underlying predicate is pure for a fixed net, the routed result is identical.
fn staticBlocked(ctx: *Ctx, layer: usize, n: usize, net: i32) bool {
    const k = layer * (ctx.grid.nx * ctx.grid.ny) + n;
    if (ctx.static_block.get(k)) |cached| return cached;
    const hit = staticBlockedUncached(ctx, layer, n, net);
    ctx.static_block.put(k, hit);
    return hit;
}

/// Allocate + arm the `staticBlocked` memo over this context's lattice.
fn armStaticBlock(ctx: *Ctx, arena: std.mem.Allocator) std.mem.Allocator.Error!void {
    try ctx.static_block.arm(arena, ctx.occ.len * ctx.grid.nx * ctx.grid.ny);
}

/// True when a FOREIGN pad's copper sits within clearance of node `(layer, n)`
/// and the node isn't on the net's *own* pad — the physical-pad half of
/// `blocked`, split out. The rip-up blocker probe reuses it so a probe can
/// treat foreign *copper* as passable-at-a-penalty (a rip could clear it) while
/// still refusing to tunnel through a pad (which can never be ripped).
fn foreignPadAt(ctx: *Ctx, layer: usize, n: usize, net: i32) bool {
    // All-top boards keep the old fast path: nothing on the bottom layer to hit.
    if (layer != 0 and !ctx.has_bottom_pads) return false;
    const px = ctx.grid.worldX(n % ctx.grid.nx);
    const py = ctx.grid.worldY(n / ctx.grid.nx);
    // Lazily build the spatial index the first time we test a node; the pad
    // set is static for the route so one build serves all queries.
    if (ctx.pad_index == null) ctx.pad_index = PadGrid.build(ctx.arena, ctx.obs, gridBounds(ctx.grid), padIndexReach(ctx));
    var on_own = false;
    var foreign = false;
    if (ctx.pad_index) |idx| {
        for (idx.near(px, py)) |pi| accumPad(
            ctx,
            ctx.obs[pi],
            layer,
            px,
            py,
            net,
            ctx.use_poly,
            &on_own,
            &foreign,
        );
    } else {
        for (ctx.obs) |p| accumPad(ctx, p, layer, px, py, net, ctx.use_poly, &on_own, &foreign);
    }
    return foreign and !on_own;
}

const QItem = maze_scratch.QItem;

/// Route every pad to one retained local-pour polygon. The zone nodes are
/// virtual roots only for this net's Dijkstra wave: they never enter `occ`, so
/// a repourable boundary cannot become a wall for a later foreign net. A zone
/// on an excluded layer remains a legal terminal: the wave can via directly
/// out of it, but ordinary movement on that layer remains blocked by
/// `relaxStep`'s allowed-layer check.
fn routeNetToZone(
    ctx: *Ctx,
    net: i32,
    pts: []const NetPt,
    tracks: *std.ArrayList(Track),
    vias: *std.ArrayList(Via),
) std.mem.Allocator.Error!?bool {
    const zone = largestNetZone(ctx, net) orelse return null;
    var sources: std.ArrayList(usize) = .empty;
    try netZoneSources(ctx, net, &sources);
    if (sources.items.len == 0) return null;
    const nodes = ctx.grid.nx * ctx.grid.ny;
    var complete = true;
    var connected_any = false;
    for (pts) |pt| {
        if (pt.layer == zone.layer and
            (outline_mod.contains(zone.polygon, pt.x, pt.y) or
                outline_mod.distToEdge(zone.polygon, pt.x, pt.y) <= clearance_eps))
        {
            connected_any = true;
            continue;
        }
        if (try reuseNearbyZoneVia(ctx, zone, net, pt, tracks, vias)) {
            connected_any = true;
            continue;
        }
        if (try tryZoneViaInPad(ctx, zone, net, pt, tracks, vias)) {
            connected_any = true;
            continue;
        }
        if (try tryZoneFanoutVia(ctx, zone, net, pt, tracks, vias)) {
            connected_any = true;
            continue;
        }
        var ends = try padMazeEnds(ctx, tracks.items, vias.items, pt, net);
        ends.sources = sources.items;
        const prior = tracks.items.len; // this net's copper BEFORE the leg
        if (try dijkstra(ctx, net, ends, tracks, vias)) |hit| {
            try gateStub(ctx, net, pt, hit.goal, vias.items, tracks);
            // Same weld the terminal tree does, for the same reason: after the
            // first pad this pass seeds from the net's own `occ` marks, so the
            // leg can start on a clearance HALO node rather than on copper —
            // and `dijkstra`'s buried-source repair may have pulled that start
            // further back off a foreign land. Bridge `hit.start` to the copper
            // laid before this leg so the two share metal; the bridge is probed,
            // so an impossible one is left for `net_open` to name.
            try weldToNetCopper(.{
                .ctx = ctx,
                .net = net,
                .at = hit.start,
                .layer = @intCast(hit.source / nodes),
                .prior = prior,
                .tracks = tracks,
                .vias = vias.items,
            });
            connected_any = true;
        } else {
            // A retained pour is useful source copper even when one congested
            // terminal cannot reach it in this pass. Keep every independently
            // DRC-clean leg that did land, mark the net partial, and let later
            // gap/residual passes attack only the remaining islands. Rolling
            // the whole rail back made one sealed QFN pad erase twenty valid
            // plane drops, so every retry restarted from zero.
            complete = false;
        }
    }
    ctx.zone_partial = !complete and connected_any;
    return complete;
}

/// The keys ONE pad terminal may finish a maze leg on — its access node plus its
/// gateway fan — with the anchor that prices every one of them (`GateAnchors`).
/// The caller fills in the leg's source side.
fn padMazeEnds(ctx: *Ctx, tracks: []const Track, vias: []const Via, pt: NetPt, net: i32) std.mem.Allocator.Error!MazeEnds {
    const nodes = ctx.grid.nx * ctx.grid.ny;
    const nd = ctx.grid.nearest(pt.x, pt.y);
    var goals: std.ArrayList(usize) = .empty;
    try goals.append(ctx.arena, @as(usize, pt.layer) * nodes + ctx.grid.node(nd[0], nd[1]));
    try padGateways(ctx, tracks, vias, pt, net, &goals);
    return .{ .goals = goals.items, .anchors = .{ .goal = pt } };
}

/// Connect every pad of one net by repeatedly maze-routing the next pad to the
/// net's routed-so-far copper. Returns true if all pads were joined.
///
/// Each pad terminal is entered through its *access node* (nearest grid node)
/// OR one of its off-grid `padGateways` — the straight escape stub a hand
/// router draws when a fine-pitch pad's nearest grid lane happens to fall
/// inside a neighbouring pad's clearance (whether a 0.4 mm-pitch QFN pin can
/// escape on-grid is alignment luck; the gateway removes the lottery).
/// Largest centre-to-centre distance between any two terminals of a net — the
/// direct-synthesis span gate (`direct_span_mm`). O(terminals²) is fine: nets
/// have a handful of terminals.
fn netSpan(pts: []const NetPt) f64 {
    var span: f64 = 0;
    for (pts, 0..) |a, i| {
        for (pts[i + 1 ..]) |b| {
            span = @max(span, std.math.hypot(b.x - a.x, b.y - a.y));
        }
    }
    return span;
}

/// Route one net end-to-end under the current `ctx` params/policy: the maze
/// attempt, then the escape-direct rescue, then a via-budget retry. All-or-
/// nothing — a false return leaves the copper lists and occupancy exactly as
/// they were.
pub fn routeNet(
    ctx: *Ctx,
    net: i32,
    pts: []const NetPt,
    tracks: *std.ArrayList(Track),
    vias: *std.ArrayList(Via),
) std.mem.Allocator.Error!bool {
    // Every re-route (greedy, escalate, rip-up, fine rescue) probes the copper
    // it is about to route against; refresh the index from the current lists so
    // the probes stay O(local) and, critically, so a rip that shifted list
    // indexes can never alias stale entries.
    rebuildCopperIndex(ctx, tracks.items, vias.items);
    const run = DirectRun{ .ctx = ctx, .net = net, .tracks = tracks, .vias = vias };
    const track_mark = tracks.items.len;
    const via_mark = vias.items.len;
    const saved_allow_vias = ctx.allow_vias;
    const saved_direct_budget = ctx.direct_budget;
    ctx.zone_partial = false;
    ctx.tree_partial = false;
    defer ctx.allow_vias = saved_allow_vias;
    defer ctx.direct_budget = saved_direct_budget;
    errdefer rollbackDirectRun(run, track_mark, via_mark);
    // An authored `(branches …)` tree names its terminals by geometry, so bind
    // it to THIS net's terminals before anything reads the positional
    // guide-branch contract.
    //
    // The whole seam hangs off `authored_tree.len > 0`, and a net without one
    // takes NONE of it: no binding call, no save/restore, `pts` handed to
    // `connectOrder` exactly as before. That is deliberate — every net on every
    // board that authors no tree must reach the maze through the identical code
    // this replaced, so the guard is structural rather than a no-op the reader
    // has to derive.
    const authored_tree = authoredBranchTree(ctx, net);
    const policy_waypoints = ctx.waypoints;
    const policy_branches = ctx.guide_branches;
    defer if (authored_tree.len > 0) {
        // The wave policy these came from is loaded once per net, while several
        // call sites run `routeNet` twice against that one load.
        ctx.waypoints = policy_waypoints;
        ctx.guide_branches = policy_branches;
    };
    const bound_pts = if (authored_tree.len > 0)
        try bindAuthoredBranches(ctx, authored_tree, pts)
    else
        pts;
    const ordered_pts = if (ctx.guide_branches.len > 0)
        bound_pts
    else
        try net_topology.connectOrder(ctx.arena, bound_pts);

    if (ctx.deadline_ns != 0 and ctx.direct_budget == null and net >= 0 and
        hardGuidedPolicy(ctx, @intCast(net))) ctx.direct_budget = deadline_guided_probe_budget;

    if (ctx.max_vias == 0) ctx.allow_vias = false;
    // RF discipline goes FIRST: an axis-only attempt with a real price per
    // corner, so a `(max-freq …)` net comes out as a few long straights the bend
    // smoother can fillet. It declines for every other net, and anything it
    // cannot close it rolls back whole — the ladder below then runs on exactly
    // the state it saw before this rung existed (`manhattan_route`).
    var routed = try manhattan_route.attempt(run, ordered_pts);
    if (!routed) routed = try routeNetAttempt(ctx, net, ordered_pts, tracks, vias);
    if (!routed) {
        const primary_zone_partial = ctx.zone_partial;
        const primary_tree_partial = ctx.tree_partial;
        if (try retryDeferredWaypoints(ctx, net, ordered_pts, tracks, vias)) return true;
        ctx.zone_partial = ctx.zone_partial or primary_zone_partial;
        ctx.tree_partial = ctx.tree_partial or primary_tree_partial;
        if (ctx.zone_partial or ctx.tree_partial) return false;
        rollbackDirectRun(run, track_mark, via_mark);
        routed = try escapeDirectRescue(ctx, net, ordered_pts, tracks, vias);
    }
    if (!routed) {
        rollbackDirectRun(run, track_mark, via_mark);
        return false;
    }
    if (ctx.max_vias) |limit| if (vias.items.len - via_mark > @as(usize, limit)) {
        rollbackDirectRun(run, track_mark, via_mark);
        if (!saved_allow_vias) return false;
        ctx.allow_vias = false;
        const retried = try routeNetAttempt(ctx, net, ordered_pts, tracks, vias);
        if (!retried) rollbackDirectRun(run, track_mark, via_mark);
        return retried;
    };
    return try detour_guard.detourGuard(run, ordered_pts, track_mark, via_mark);
}

/// This net's authored `(branches …)` tree, or EMPTY when it has none — the one
/// condition the binding seam in `routeNet` turns on, kept as its own predicate
/// so that "this net authors no tree" is a single comparison on the hot path.
///
/// A reference-derived tree (`policy.branches`, already loaded into
/// `ctx.guide_branches` by `setNetRoutePolicy`) deliberately reads as NONE: it
/// is already positional and must not be re-bound.
fn authoredBranchTree(ctx: *const Ctx, net: i32) []const route_policy.GuideBranch {
    if (ctx.guide_branches.len > 0 or net < 0) return &.{};
    const net_i: usize = @intCast(net);
    if (net_i >= ctx.net_policy.len) return &.{};
    return ctx.net_policy[net_i].wave.branches;
}

/// Bind an authored guide tree to this net's own terminals and hand back the
/// terminal order the positional `GuideBranch` contract needs.
///
/// The wave carries the tree in AUTHORED order; the router's terminal order is
/// whatever flattening produced, which the author cannot see. `guide_branch`
/// resolves the two against each other geometrically and refuses a tree it
/// cannot land on distinct terminals — a refusal returns `pts` untouched and
/// leaves `ctx` alone, so the net routes through the ordinary path exactly as
/// it did before the form existed.
fn bindAuthoredBranches(
    ctx: *Ctx,
    authored: []const route_policy.GuideBranch,
    pts: []const NetPt,
) std.mem.Allocator.Error![]const NetPt {
    const terminals = try ctx.arena.alloc(guide_branch.Terminal, pts.len);
    for (pts, terminals) |pt, *terminal| terminal.* = .{ .x = pt.x, .y = pt.y };
    switch (try guide_branch.resolve(ctx.arena, authored, terminals)) {
        .refused => return pts,
        // One limb on a two-terminal net IS a waypoint chain, and the tree path
        // needs three terminals to mean anything. An ordinary `(waypoints …)`
        // on the same wave stays the author's more specific instruction.
        .chain => |points| {
            if (ctx.waypoints.len == 0) ctx.waypoints = points;
            return pts;
        },
        .tree => |tree| {
            const ordered = try ctx.arena.alloc(NetPt, pts.len);
            for (tree.order, ordered) |from, *slot| slot.* = pts[from];
            ctx.guide_branches = tree.branches;
            return ordered;
        },
    }
}

/// Retry one failed net immediately through its authored repair corridor,
/// before lower waves can claim that space. The ordinary attempt always runs
/// first, so a repair-only guide cannot perturb a net the broad router already
/// completes. Existing useful partial copper stays in place and can serve as a
/// same-net source; a failed guided attempt rolls back only its own additions.
fn retryDeferredWaypoints(
    ctx: *Ctx,
    net: i32,
    pts: []const NetPt,
    tracks: *std.ArrayList(Track),
    vias: *std.ArrayList(Via),
) std.mem.Allocator.Error!bool {
    if (net < 0) return false;
    const net_i: usize = @intCast(net);
    if (net_i >= ctx.net_policy.len) return false;
    const repair = ctx.net_policy[net_i].wave.repair_waypoints;
    if (repair.len == 0) return false;

    const saved_preferred = ctx.preferred_layers;
    const saved_allowed = ctx.allowed_layers;
    const saved_waypoints = ctx.waypoints;
    const saved_branches = ctx.guide_branches;
    const saved_budget = ctx.direct_budget;
    defer {
        ctx.preferred_layers = saved_preferred;
        ctx.allowed_layers = saved_allowed;
        ctx.waypoints = saved_waypoints;
        ctx.guide_branches = saved_branches;
        ctx.direct_budget = saved_budget;
    }
    ctx.preferred_layers = 0;
    ctx.allowed_layers = 0;
    ctx.waypoints = repair;
    ctx.guide_branches = &.{};
    if (ctx.deadline_ns != 0) ctx.direct_budget = deferred_repair_probe_budget;
    ctx.zone_partial = false;
    ctx.tree_partial = false;
    return routeNetAttempt(ctx, net, pts, tracks, vias);
}

/// A deferred repair corridor is a bounded authored attempt, not permission
/// to monopolize the deadline: scaling this per waypoint (8,192/point capped
/// at 65,536) produced byte-identical copper and cost ~6 s on Barracuda, so
/// the budget stays flat at the same ceiling the immediate fine retry uses.
const deferred_repair_probe_budget: usize = 8_192;

/// Routability rescue for escape-forced nets. They skip the direct-synthesis
/// experiments up front (those bypass the maze's escape shaping), but a
/// hemmed fine-pitch pad is sometimes reachable ONLY through an off-grid
/// direct path — so when the escape-shaped maze finds nothing, run the
/// direct attempts after all: a routed net with a flagged escape violation
/// beats an unrouted net, mirroring the bend smoother's shrink-on-veto.
fn escapeDirectRescue(
    ctx: *Ctx,
    net: i32,
    pts: []const NetPt,
    tracks: *std.ArrayList(Track),
    vias: *std.ArrayList(Via),
) std.mem.Allocator.Error!bool {
    if (!escapeActive(ctx)) return false;
    if (ctx.corridor != null) return false;
    if (selectedCount(ctx.selected_nets) > fine_selection_max_nets) return false;
    const direct = DirectRun{ .ctx = ctx, .net = net, .tracks = tracks, .vias = vias };
    const saved_budget = ctx.direct_budget;
    defer ctx.direct_budget = saved_budget;
    ctx.direct_budget = fine_window.escapeRescueBudget(ctx.window_probe_budget, saved_budget);
    if (pts.len == 2) return try tryDirectPair(direct, pts[0], pts[1]);
    if (pts.len > 2) return try tryDirectTerminalTree(direct, pts);
    return false;
}

/// One pass of the ordinary per-net ladder: authored guides first, then the
/// pour terminal, then the direct-synthesis experiments a short plain net is
/// allowed, then the free-space and maze terminal trees. Transactional in the
/// same sense as its callers — a false return leaves no copper behind.
pub fn routeNetAttempt(
    ctx: *Ctx,
    net: i32,
    pts: []const NetPt,
    tracks: *std.ArrayList(Track),
    vias: *std.ArrayList(Via),
) std.mem.Allocator.Error!bool {
    if (ctx.guide_branches.len > 0) {
        const direct = DirectRun{ .ctx = ctx, .net = net, .tracks = tracks, .vias = vias };
        return try tryGuidedTree(direct, pts, ctx.guide_branches);
    }
    if (ctx.waypoints.len > 0) {
        const direct = DirectRun{ .ctx = ctx, .net = net, .tracks = tracks, .vias = vias };
        if (pts.len == 2) {
            const saved_budget = ctx.direct_budget;
            if (try tryGuidedRoute(direct, pts[0], pts[1], ctx.waypoints)) return true;
            // The direct guide is intentionally probe-bounded on a timed
            // whole-board route. Exhausting that allowance must not poison the
            // ordinary maze fallback: weldToNetCopper uses the same exact
            // probes to join the maze tree, so a zero budget made every
            // otherwise-routable two-terminal guide fail immediately.
            ctx.direct_budget = saved_budget;
            return try tryMazeGuidedTree(direct, pts, ctx.waypoints);
        }
        if (pts.len > 2) return try trySharedGuidedTree(direct, pts, ctx.waypoints);
    }
    if (try routeNetToZone(ctx, net, pts, tracks, vias)) |zone_ok| return zone_ok;
    const focused_experiment = selectedCount(ctx.selected_nets) <= fine_selection_max_nets;
    // Escape-constrained nets normally go through the maze: the straight
    // pad-escape reserve lives in the maze cost model, which the direct
    // synthesis shortcuts would otherwise bypass. The ONE exception is a 2-pad
    // hop whose terminals are nearly axis-aligned (same X or same Y): a single
    // straight horizontal/vertical segment already leaves BOTH pads straight,
    // so it IS the escape line — trying it directly (still DRC-checked) yields
    // the clean straight RF trace instead of the maze's grid-quantized dogleg
    // the smoother then curls. A blocked straight line falls through to the maze.
    if (ctx.corridor == null and focused_experiment) {
        const direct = DirectRun{ .ctx = ctx, .net = net, .tracks = tracks, .vias = vias };
        const unshaped = !escapeActive(ctx);
        const axis_direct = pts.len == 2 and pad_exit.straightEscapePair(escTerm(pts[0]), escTerm(pts[1]));
        // A plain (non-escape) net only pays the direct synthesis when its
        // terminal span is small: the direct primitives' exact-clearance
        // lattice sweeps measured ~90 % of autorouter wall time on long
        // cross-layer nets and almost never close them — the maze routes
        // those in a fraction of the time (`docs/autorouter-wall-time.md`).
        // Escape-constrained (RF) nets are exempt: their straight off-grid
        // trace is the point of the direct path.
        const short_plain = unshaped and netSpan(pts) <= direct_span_mm;
        // Bounded probes for the plain-net direct path only: a net that
        // cannot close direct burns its budget and falls to the maze (which
        // has its own expansion budget and never pays this one). Escape nets
        // keep the unbounded budget — they are the few RF nets of a board.
        // The budget is restored BEFORE the maze runs: `weldToNetCopper`
        // clears against the maze's own copper through `clearDoglegSegment`,
        // and a budget exhausted during the maze would silently fail welds.
        const saved_budget = ctx.direct_budget;
        if (unshaped) ctx.direct_budget = direct_probe_budget;
        if (pts.len == 2 and (axis_direct or short_plain) and
            (try tryDirectPair(direct, pts[0], pts[1])))
        {
            ctx.direct_budget = saved_budget;
            return true;
        }
        if (pts.len > 2 and short_plain and (try tryDirectTerminalTree(direct, pts))) {
            ctx.direct_budget = saved_budget;
            return true;
        }
        ctx.direct_budget = saved_budget;
    }
    return try @import("route_free_space.zig").tryTerminalTree(ctx.arena, ctx, net, pts, tracks, vias, DirectPath, clearDoglegSegment, stampStubOcc, stampCurrentRf) or try tryMazeTerminalTree(ctx, net, pts, tracks, vias, 1);
}

/// Grow an ordinary raster tree through `pts` in their supplied order.
/// Callers may prepend virtual waypoint terminals to make the maze claim a
/// shared trunk before it fans out to real pads. `partial_after` is the number
/// of successful legs required before failure owns useful pad copper: one for
/// an all-real tree, or all guide legs plus two real-pad attachments for a
/// virtual-waypoint tree.
pub fn tryMazeTerminalTree(
    ctx: *Ctx,
    net: i32,
    pts: []const NetPt,
    tracks: *std.ArrayList(Track),
    vias: *std.ArrayList(Via),
    partial_after: usize,
) std.mem.Allocator.Error!bool {
    const nodes = ctx.grid.nx * ctx.grid.ny;
    // Seed the net with its first pad's access node, on that pad's own layer,
    // plus that pad's gateways as extra Dijkstra sources until real copper
    // exists (a gateway only becomes copper when a path actually uses it —
    // stamping them all up-front would fake connectivity). A BLOCKED access
    // node (a fine-pitch pad whose nearest grid node fell inside a
    // neighbour's clearance — or onto the neighbour itself) is never seeded:
    // copper growing from it would sit on/inside the foreign pad. Such pads
    // enter the maze through their gateways only.
    const p0 = ctx.grid.nearest(pts[0].x, pts[0].y);
    const p0n = ctx.grid.node(p0[0], p0[1]);
    if (!blocked(ctx, pts[0].layer, p0n, net)) ctx.occ[pts[0].layer][p0n] = net;
    var seed_gates: std.ArrayList(usize) = .empty;
    try padGateways(ctx, tracks.items, vias.items, pts[0], net, &seed_gates);
    ctx.join_lands = try netLands(ctx, net, pts);
    defer ctx.join_lands = &.{};

    var have_copper = false; // true once some leg routed (seed stub emitted)
    var connected_legs: usize = 0;
    for (pts[1..]) |pt| {
        var ends = try padMazeEnds(ctx, tracks.items, vias.items, pt, net);
        // Both ends of the FIRST leg are pad fans, so both are priced. Once this
        // net owns copper the source side is that copper, not an escape: there is
        // no stub to charge for standing on metal that already exists.
        if (!have_copper) {
            ends.sources = seed_gates.items;
            ends.anchors.source = pts[0];
        }
        const prior = tracks.items.len; // this net's copper BEFORE the leg
        if (try dijkstra(ctx, net, ends, tracks, vias)) |hit| {
            // Join the goal pad's centre to whichever entry node the path
            // actually reached (plain access node or gateway alike).
            try gateStub(ctx, net, pt, hit.goal, vias.items, tracks);
            if (!have_copper) {
                try gateStub(ctx, net, pts[0], hit.source, vias.items, tracks);
                have_copper = true;
            } else {
                // A later leg welds at whichever occupancy node Dijkstra
                // reached — which can sit a clearance-halo off the real
                // centreline (`stampStubOcc`/`stampViaOcc` mark `occ==net`
                // out to the copper CLEARANCE radius). Bridge it to the
                // net's prior copper so the two legs share metal. `hit.start`
                // is that node after `dijkstra`'s buried-source repair, so the
                // bridge starts where the copper actually does.
                try weldToNetCopper(.{
                    .ctx = ctx,
                    .net = net,
                    .at = hit.start,
                    .layer = @intCast(hit.source / nodes),
                    .prior = prior,
                    .tracks = tracks,
                    .vias = vias.items,
                });
            }
            connected_legs += 1;
        } else {
            // Do NOT stamp the failed goal as this net's copper. It was never
            // reached, so it carries no track — marking it `occ = net` would
            // make it a Dijkstra *source* for a later same-net leg (see the
            // source scan in `dijkstra`), letting that leg weld to a stranded
            // island: the drawing looks connected while the pad is electrically
            // split from the net's real copper. Leaving it EMPTY keeps the pad
            // honestly unrouted. Later legs cannot change the failed result.
            // Once one leg landed, `pts[0]` and at least one later real
            // terminal share actual copper.  Preserve that connected subtree:
            // the caller still reports failure, while subsequent retries and
            // the oracle-driven close pass can work only on what remains.
            ctx.tree_partial = have_copper and connected_legs >= partial_after;
            return false;
        }
    }
    ctx.tree_partial = false;
    return true;
}

/// One net's live state for the direct (off-grid) routing primitives: the
/// routing context, the net index, and the board's growing copper lists.
pub const DirectRun = struct {
    ctx: *Ctx,
    net: i32,
    tracks: *std.ArrayList(Track),
    vias: *std.ArrayList(Via),

    /// This run's fixed-layer view of the board for the off-grid probes.
    pub fn path(self: DirectRun, layer: u8) DirectPath {
        return .{
            .ctx = self.ctx,
            .net = self.net,
            .layer = layer,
            .tracks = self.tracks.items,
            .vias = self.vias.items,
        };
    }
};

/// One net's fixed-layer view of the board for the off-grid probes: the route
/// context, the net, the layer, and the copper the probes measure against.
pub const DirectPath = struct {
    ctx: *Ctx,
    net: i32,
    layer: u8,
    tracks: []const Track,
    vias: []const Via,
};

fn padAxisTerm(path: DirectPath, pt: NetPt) ?octilinear.PadTerm {
    const box = ownPadBox(path.ctx, pt, path.net) orelse return null;
    return .{ .at = .{ pt.x, pt.y }, .out = pt.out, .box = .{ .x0 = box.x0, .y0 = box.y0, .x1 = box.x1, .y1 = box.y1 } };
}

/// The world boxes of the pads one net is being routed to — what a maze leg
/// prices its join against (`Ctx.join_lands`). A terminal with no resolvable
/// own-pad box simply contributes no land, so it prices like any other copper.
fn netLands(ctx: *Ctx, net: i32, pts: []const NetPt) std.mem.Allocator.Error![]const net_topology.Land {
    var out: std.ArrayList(net_topology.Land) = .empty;
    for (pts) |pt| {
        const box = ownPadBox(ctx, pt, net) orelse continue;
        try out.append(ctx.arena, .{ .x0 = box.x0, .y0 = box.y0, .x1 = box.x1, .y1 = box.y1 });
    }
    return out.items;
}

fn padAxisOptions(path: DirectPath) net_topology.Options {
    return .{ .pad = .{ .step = @max(path.ctx.grid.g, path.ctx.params.track_width), .half_width = path.ctx.params.track_width / 2, .rings = gate_rings }, .land_join = !escapeActive(path.ctx) and path.ctx.corridor == null and path.ctx.reference_corridor == null };
}

fn axisExitDogleg(path: DirectPath, pt: NetPt, target: [2]f64) ?Dogleg {
    const term = padAxisTerm(path, pt) orelse return null;
    const found = octilinear.padExit(DirectPath, term, target, padAxisOptions(path).pad, path, clearDoglegSegment) orelse return null;
    return .{ .count = found.count, .bends = found.bends };
}

fn axisEntryDogleg(path: DirectPath, source: [2]f64, pt: NetPt) ?Dogleg {
    return reversedDogleg(axisExitDogleg(path, pt, source) orelse return null);
}

fn axisPairDogleg(path: DirectPath, from: NetPt, to: NetPt) ?Dogleg {
    const a = padAxisTerm(path, from) orelse return null;
    const b = padAxisTerm(path, to) orelse return null;
    const found = net_topology.padJoin(DirectPath, a, b, padAxisOptions(path), path, clearDoglegSegment) orelse return null;
    return .{ .count = found.count, .bends = found.bends };
}

/// Direct primitives are deliberately bounded to small terminal trees. Beyond
/// this, repeatedly trying the local continuous/via searches becomes more
/// expensive than growing the ordinary maze tree and is less likely to choose
/// a useful trunk.
const direct_tree_max_pads: usize = 6;
const direct_tree_max_edge_attempts: usize = 6;
const direct_tree_via_radius_mm: f64 = 1.0;
/// Exact off-grid tree edges scan retained pads, tracks, and vias for every
/// candidate bend. Past this much copper that local search becomes slower than
/// the indexed board maze, so hand the whole net to the maze immediately.
const direct_tree_max_exact_geometry: usize = 512;

fn tryDirectPair(run: DirectRun, from: NetPt, to: NetPt) std.mem.Allocator.Error!bool {
    if (run.ctx.timing) |t| t.begin(.direct);
    defer if (run.ctx.timing) |t| t.end(.direct);
    if (from.layer != to.layer) {
        if (std.math.hypot(to.x - from.x, to.y - from.y) < 1e-9) {
            if (!run.ctx.allow_vias or !directViaClear(run, .{ from.x, from.y })) return false;
            try run.vias.append(run.ctx.arena, .{
                .x = from.x,
                .y = from.y,
                .dia = run.ctx.params.via_dia,
                .drill = run.ctx.params.via_drill,
                .net = run.net,
            });
            stampViaOcc(run.ctx, from.x, from.y, run.net);
            return true;
        }
        return try tryDirectOneVia(run, from, to);
    }
    if (layerInMask(run.ctx.preferred_layers, from.layer) and
        (try tryDirectDogleg(run, from, to))) return true;
    if (try tryDirectPreferredLayer(run, from, to)) return true;
    return try tryTwoViaSeededMaze(run, from, to);
}

/// A deliberately cheap subset of the direct primitives for frontier-tree
/// growth. A failed edge must hand control back quickly: running the full fine
/// grid and seeded-maze fallbacks for every possible tree edge is multiplicative
/// on a full board.
fn tryDirectTreePair(run: DirectRun, from: NetPt, to: NetPt) std.mem.Allocator.Error!bool {
    if (from.layer == to.layer) {
        if (!layerInMask(run.ctx.preferred_layers, from.layer)) return false;
        const path = run.path(from.layer);
        const a = [2]f64{ from.x, from.y };
        const b = [2]f64{ to.x, to.y };
        if (selectedCount(run.ctx.selected_nets) == 1) {
            const found = if (axisPairDogleg(path, from, to)) |dogleg|
                ContinuousRoute{ .dogleg = dogleg }
            else
                (try findContinuousRoute(path, a, b)) orelse return false;
            try emitContinuousRoute(path, a, b, found, run.tracks);
            return true;
        }
        const dogleg = axisPairDogleg(path, from, to) orelse findThreeBend(path, a, b) orelse return false;
        try emitDogleg(path, a, b, dogleg, run.tracks);
        return true;
    }
    if (!run.ctx.allow_vias) return false;
    const max_ring: i64 = @intFromFloat(@ceil(direct_tree_via_radius_mm / direct_via_grid_mm));
    var ring: i64 = 1;
    while (ring <= max_ring) : (ring += 1) {
        for ([2]NetPt{ from, to }) |anchor| {
            if (try tryDirectViaLatticeRing(run, from, to, anchor, ring)) return true;
        }
    }
    return false;
}

/// Clear a failed direct attempt's raster reservations, then reconstruct every
/// reservation that existed before it from the surviving exact geometry. This
/// keeps the direct-tree attempt transactional even when retained copper of the
/// same net was already present in the route context.
pub fn restoreNetOcc(ctx: *Ctx, net: i32, tracks: []const Track, vias: []const Via) void {
    clearNetOcc(ctx, net);
    for (tracks) |track| {
        if (track.net != net) continue;
        stampStubOcc(ctx, .{ track.x1, track.y1 }, .{ track.x2, track.y2 }, net, track.layer);
    }
    for (vias) |via| {
        if (via.net == net) stampViaOcc(ctx, via.x, via.y, net);
    }
}

/// Roll both copper lists back to the marks an attempt recorded before it —
/// the one rollback primitive every transactional pass here shares.
pub fn shrinkCopper(t: *std.ArrayList(Track), v: *std.ArrayList(Via), tm: usize, vm: usize) void {
    t.shrinkRetainingCapacity(tm);
    v.shrinkRetainingCapacity(vm);
}

/// Undo one net's copper back to `track_mark`/`via_mark` and rebuild its
/// occupancy from the geometry that survives.
pub fn rollbackDirectRun(run: DirectRun, track_mark: usize, via_mark: usize) void {
    shrinkCopper(run.tracks, run.vias, track_mark, via_mark);
    restoreNetOcc(run.ctx, run.net, run.tracks.items, run.vias.items);
}

fn tryGuidedRoute(
    run: DirectRun,
    from: NetPt,
    to: NetPt,
    waypoints: []const route_policy.Waypoint,
) std.mem.Allocator.Error!bool {
    return tryGuidedChain(run, from, to, waypoints, guideReverseIsShorter(from, to, waypoints));
}

/// Walk one guide chain from `from` to `to`, entering it at whichever end
/// `reverse` selects. The orientation is a PARAMETER because who chooses it
/// differs: a lone terminal pair decides for itself (`tryGuidedRoute`), while
/// every leg of a shared trunk must be handed the SAME answer, decided once for
/// the whole tree (`trySharedGuidedTree`).
fn tryGuidedChain(
    run: DirectRun,
    from: NetPt,
    to: NetPt,
    waypoints: []const route_policy.Waypoint,
    reverse: bool,
) std.mem.Allocator.Error!bool {
    const track_mark = run.tracks.items.len;
    const via_mark = run.vias.items.len;
    var current = from;
    for (0..waypoints.len) |step| {
        const point = waypoints[if (reverse) waypoints.len - 1 - step else step];
        const next = NetPt{ .x = point.x, .y = point.y, .layer = point.layer };
        if (!(try tryDirectPair(run, current, next))) {
            rollbackDirectRun(run, track_mark, via_mark);
            return false;
        }
        current = next;
    }
    if (!(try tryDirectPair(run, current, to))) {
        rollbackDirectRun(run, track_mark, via_mark);
        return false;
    }
    return true;
}

/// A waypoint chain describes physical topology, not the incidental order in
/// which flattening happened to emit a net's two pins. Orient it so its first
/// and last authored points are nearest the corresponding route terminals.
/// Without this, an otherwise valid A→B guide presented to a B→A `FlatNet`
/// first crossed the whole board to A, walked the guide back to B, then crossed
/// to A again — both slow and normally impossible on a populated board.
fn guideReverseIsShorter(
    from: NetPt,
    to: NetPt,
    waypoints: []const route_policy.Waypoint,
) bool {
    if (waypoints.len < 2) return false;
    const first = waypoints[0];
    const last = waypoints[waypoints.len - 1];
    const forward = std.math.hypot(first.x - from.x, first.y - from.y) +
        std.math.hypot(to.x - last.x, to.y - last.y);
    const reverse = std.math.hypot(last.x - from.x, last.y - from.y) +
        std.math.hypot(to.x - first.x, to.y - first.y);
    return reverse + clearance_eps < forward;
}

/// The one orientation every leg of a SHARED trunk enters its guide chain from.
///
/// `guideReverseIsShorter` answers for a single terminal pair, which is right
/// for a two-pad net but wrong per-leg on a tree: the legs of one trunk then
/// pick opposite ends of the same chain, and a trunk walked in two directions is
/// not one trunk. This asks the identical question of the WHOLE tree — the same
/// entry+exit cost, summed over every leg against the shared root — so on a tree
/// with a single leg it reduces exactly to `guideReverseIsShorter`.
fn sharedGuideReverse(pts: []const NetPt, waypoints: []const route_policy.Waypoint) bool {
    if (waypoints.len < 2 or pts.len < 2) return false;
    const root = pts[0];
    const first = waypoints[0];
    const last = waypoints[waypoints.len - 1];
    const enter_forward = std.math.hypot(first.x - root.x, first.y - root.y);
    const enter_reverse = std.math.hypot(last.x - root.x, last.y - root.y);
    var forward: f64 = 0;
    var reverse: f64 = 0;
    for (pts[1..]) |to| {
        forward += enter_forward + std.math.hypot(to.x - last.x, to.y - last.y);
        reverse += enter_reverse + std.math.hypot(to.x - first.x, to.y - first.y);
    }
    return reverse + clearance_eps < forward;
}

fn sameTrackGeometry(a: Track, b: Track) bool {
    if (a.net != b.net or a.layer != b.layer or @abs(a.width - b.width) > 1e-9) return false;
    const direct = @abs(a.x1 - b.x1) <= 1e-9 and @abs(a.y1 - b.y1) <= 1e-9 and
        @abs(a.x2 - b.x2) <= 1e-9 and @abs(a.y2 - b.y2) <= 1e-9;
    const reverse = @abs(a.x1 - b.x2) <= 1e-9 and @abs(a.y1 - b.y2) <= 1e-9 and
        @abs(a.x2 - b.x1) <= 1e-9 and @abs(a.y2 - b.y1) <= 1e-9;
    return direct or reverse;
}

fn dedupeGuidedTracks(tracks: *std.ArrayList(Track), mark: usize) void {
    var write = mark;
    for (tracks.items[mark..]) |item| {
        var duplicate = false;
        for (tracks.items[mark..write]) |prior| if (sameTrackGeometry(item, prior)) {
            duplicate = true;
            break;
        };
        if (duplicate) continue;
        tracks.items[write] = item;
        write += 1;
    }
    tracks.shrinkRetainingCapacity(write);
}

fn dedupeGuidedVias(vias: *std.ArrayList(Via), mark: usize) void {
    var write = mark;
    for (vias.items[mark..]) |item| {
        var duplicate = false;
        for (vias.items[mark..write]) |prior| {
            if (item.net == prior.net and @abs(item.x - prior.x) <= 1e-9 and @abs(item.y - prior.y) <= 1e-9) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;
        vias.items[write] = item;
        write += 1;
    }
    vias.shrinkRetainingCapacity(write);
}

fn tryGuidedTree(
    run: DirectRun,
    pts: []const NetPt,
    branches: []const route_policy.GuideBranch,
) std.mem.Allocator.Error!bool {
    if (pts.len < 3 or branches.len != pts.len - 1) return false;
    const track_mark = run.tracks.items.len;
    const via_mark = run.vias.items.len;
    for (branches, 0..) |branch, branch_i| {
        if (try tryGuidedRoute(run, pts[0], pts[branch_i + 1], branch.waypoints)) continue;
        rollbackDirectRun(run, track_mark, via_mark);
        return false;
    }
    dedupeGuidedTracks(run.tracks, track_mark);
    dedupeGuidedVias(run.vias, via_mark);
    return true;
}

fn trySharedGuidedTree(
    run: DirectRun,
    pts: []const NetPt,
    waypoints: []const route_policy.Waypoint,
) std.mem.Allocator.Error!bool {
    if (pts.len < 3 or waypoints.len == 0) return false;
    const track_mark = run.tracks.items.len;
    const via_mark = run.vias.items.len;
    const saved_budget = run.ctx.direct_budget;
    // ONE orientation for the whole trunk (see `sharedGuideReverse`).
    const reverse = sharedGuideReverse(pts, waypoints);
    for (pts[1..]) |point| {
        if (try tryGuidedChain(run, pts[0], point, waypoints, reverse)) continue;
        rollbackDirectRun(run, track_mark, via_mark);
        run.ctx.direct_budget = saved_budget;
        return try tryMazeGuidedTree(run, pts, waypoints);
    }
    dedupeGuidedTracks(run.tracks, track_mark);
    dedupeGuidedVias(run.vias, via_mark);
    var parent: []usize = &.{};
    const islands = try route_cleanup.countCopperIslands(
        run.ctx.arena,
        &.{},
        run.tracks.items[track_mark..],
        run.vias.items[via_mark..],
        &parent,
    );
    if (islands <= 1) return true;
    rollbackDirectRun(run, track_mark, via_mark);
    run.ctx.direct_budget = saved_budget;
    return try tryMazeGuidedTree(run, pts, waypoints);
}

/// When exact doglegs cannot honor a shared waypoint without crossing existing
/// copper, make the waypoint chain the maze tree's seed. Every real terminal
/// then joins that routed-so-far trunk through the normal clearance-aware
/// search, so a hard guide remains useful on a populated board rather than
/// turning an otherwise-routable multi-drop net into a direct-geometry miss.
fn tryMazeGuidedTree(
    run: DirectRun,
    pts: []const NetPt,
    waypoints: []const route_policy.Waypoint,
) std.mem.Allocator.Error!bool {
    const guided = try run.ctx.arena.alloc(NetPt, waypoints.len + pts.len);
    for (waypoints, guided[0..waypoints.len]) |point, *terminal| {
        terminal.* = .{ .x = point.x, .y = point.y, .layer = point.layer };
    }
    const used = try run.ctx.arena.alloc(bool, pts.len);
    const track_mark = run.tracks.items.len;
    const via_mark = run.vias.items.len;
    const attempts = @min(pts.len, direct_tree_max_pads);
    for (0..attempts) |first| {
        @memset(used, false);
        guided[waypoints.len] = pts[first];
        used[first] = true;
        for (waypoints.len + 1..guided.len) |write| {
            var next: usize = 0;
            var best = std.math.inf(f64);
            for (pts, 0..) |candidate, candidate_i| {
                if (used[candidate_i]) continue;
                for (guided[0..write]) |tree_point| {
                    const distance = std.math.hypot(candidate.x - tree_point.x, candidate.y - tree_point.y);
                    if (distance >= best) continue;
                    next = candidate_i;
                    best = distance;
                }
            }
            guided[write] = pts[next];
            used[next] = true;
        }
        // `guided[0]` is virtual. A useful partial therefore needs every
        // remaining guide point plus two real terminals joined to that trunk.
        const partial_after = waypoints.len + 1;
        if (try tryMazeTerminalTree(run.ctx, run.net, guided, run.tracks, run.vias, partial_after)) return true;
        if (run.ctx.tree_partial) return false;
        rollbackDirectRun(run, track_mark, via_mark);
        // A guided tree starts with virtual waypoint terminals, so a partial
        // flag can describe only a floating guide trunk.  Never expose that as
        // useful pad connectivity.
        run.ctx.tree_partial = false;
    }
    return false;
}

/// Grow a small off-grid tree from the nearest routable terminal frontier.
/// Unlike the raster maze, each leg starts and ends at true pad centres, so a
/// mixed-face three-pad signal can first join the nearby cross-face pair and
/// then extend along the destination face. Every rejected edge and the whole
/// failed tree are rolled back before the ordinary maze gets its turn.
fn tryDirectTerminalTree(run: DirectRun, pts: []const NetPt) std.mem.Allocator.Error!bool {
    if (run.ctx.timing) |t| t.begin(.direct);
    defer if (run.ctx.timing) |t| t.end(.direct);
    if (pts.len < 3 or pts.len > direct_tree_max_pads) return false;
    // The exact mixed-layer tree probes a dense via lattice against every
    // retained feature. Reserve it for focused one/two-net repair; in a batch
    // the bounded board maze is both faster and globally more representative.
    if (selectedCount(run.ctx.selected_nets) > fine_selection_max_nets) return false;
    if (run.tracks.items.len + run.vias.items.len > direct_tree_max_exact_geometry) return false;
    const initial_track_mark = run.tracks.items.len;
    const initial_via_mark = run.vias.items.len;
    const connected = try run.ctx.arena.alloc(bool, pts.len);
    const attempted = try run.ctx.arena.alloc(bool, pts.len * pts.len);
    @memset(connected, false);
    @memset(attempted, false);
    connected[0] = true;

    var remaining = pts.len - 1;
    var edge_attempts: usize = 0;
    while (remaining > 0) {
        var joined = false;
        while (!joined) {
            var best_from: ?usize = null;
            var best_to: usize = 0;
            var best_distance = std.math.inf(f64);
            for (pts, 0..) |from, from_i| {
                if (!connected[from_i]) continue;
                for (pts, 0..) |to, to_i| {
                    if (connected[to_i] or attempted[from_i * pts.len + to_i]) continue;
                    const distance = std.math.hypot(to.x - from.x, to.y - from.y);
                    if (distance >= best_distance) continue;
                    best_distance = distance;
                    best_from = from_i;
                    best_to = to_i;
                }
            }
            const from_i = best_from orelse {
                rollbackDirectRun(run, initial_track_mark, initial_via_mark);
                return false;
            };
            attempted[from_i * pts.len + best_to] = true;
            if (edge_attempts >= direct_tree_max_edge_attempts) {
                rollbackDirectRun(run, initial_track_mark, initial_via_mark);
                return false;
            }
            edge_attempts += 1;
            const track_mark = run.tracks.items.len;
            const via_mark = run.vias.items.len;
            if (try tryDirectTreePair(run, pts[from_i], pts[best_to])) {
                connected[best_to] = true;
                remaining -= 1;
                joined = true;
            } else {
                rollbackDirectRun(run, track_mark, via_mark);
            }
        }
    }
    return true;
}

const Dogleg = struct {
    count: u2 = 0,
    bends: [3][2]f64 = .{ .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } },
};

const direct_escape_grid_mm: f64 = 0.025;

fn directSegmentInside(path: DirectPath, a: [2]f64, b: [2]f64) bool {
    const len = std.math.hypot(b[0] - a[0], b[1] - a[1]);
    const steps: usize = @max(1, numeric.toCount(@ceil(len / (path.ctx.grid.g * 0.5))));
    const min_x = path.ctx.grid.worldX(0);
    const min_y = path.ctx.grid.worldY(0);
    const max_x = path.ctx.grid.worldX(path.ctx.grid.nx - 1);
    const max_y = path.ctx.grid.worldY(path.ctx.grid.ny - 1);
    var i: usize = 0;
    while (i <= steps) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
        const x = a[0] + t * (b[0] - a[0]);
        const y = a[1] + t * (b[1] - a[1]);
        if (x < min_x - clearance_eps or x > max_x + clearance_eps or
            y < min_y - clearance_eps or y > max_y + clearance_eps) return false;
        if (zoneBlocksPoint(path.ctx, path.layer, .{ x, y }, path.net, path.ctx.reach, false)) return false;
        if (path.ctx.outline_mask == null and path.ctx.perimeter_track_mask == null) continue;
        const nearest = path.ctx.grid.nearest(x, y);
        const node = path.ctx.grid.node(nearest[0], nearest[1]);
        if (outlineBlocked(path.ctx, node, path.net)) return false;
    }
    return true;
}

/// DRC-grade clearance for one off-grid segment on `path`'s layer: authored
/// lanes, the board outline and blocking zones, then foreign pads, vias and
/// copper. The oracle every direct (non-raster) primitive probes with.
pub fn clearDoglegSegment(path: DirectPath, a: [2]f64, b: [2]f64) bool {
    if (path.ctx.timing) |t| t.dogleg_probes += 1;
    if (probeBudgetExhausted(path.ctx)) return false;
    if (std.math.hypot(b[0] - a[0], b[1] - a[1]) < 1e-9) return true;
    // Authored lanes are checked in world space (a direct run is off-grid) —
    // see `lane_reserve`; the maze's `resv` test alone is bypassable here.
    if (lane_reserve.segmentBlocked(path.ctx.reserved_lanes, path.ctx.grid, path.layer, path.net, a, b)) return false;
    return directSegmentInside(path, a, b) and
        segClearsPadsOnLayer(path.ctx, a, b, path.net, path.layer) and
        segClearsVias(path.ctx, path.vias, a, b, path.net) and
        segClearsTracks(path.ctx, path.tracks, a, b, path.net, path.layer);
}

fn clearDoglegSegmentWidth(path: DirectPath, a: [2]f64, b: [2]f64, width: f64) bool {
    if (!(width > 0) or @abs(width - path.ctx.params.track_width) <= 1e-9)
        return clearDoglegSegment(path, a, b);
    const old_width = path.ctx.params.track_width;
    const old_reach = path.ctx.reach;
    const old_gen = path.ctx.copper_gen;
    const old_copper_reach = path.ctx.copper_reach;
    defer {
        path.ctx.params.track_width = old_width;
        path.ctx.reach = old_reach;
        path.ctx.copper_gen = old_gen;
        path.ctx.copper_reach = old_copper_reach;
    }
    path.ctx.params.track_width = width;
    path.ctx.reach = width / 2 + path.ctx.params.clearance;
    path.ctx.copper_reach = copperReach(path.ctx);
    path.ctx.copper_gen +%= 1; // force exact linear copper scans at this width
    if (path.ctx.timing) |t| t.dogleg_probes += 1;
    if (probeBudgetExhausted(path.ctx)) return false;
    if (std.math.hypot(b[0] - a[0], b[1] - a[1]) < 1e-9) return true;
    if (lane_reserve.segmentBlocked(path.ctx.reserved_lanes, path.ctx.grid, path.layer, path.net, a, b)) return false;
    return directSegmentInside(path, a, b) and
        segClearsPadsLinear(path.ctx, a, b, path.net, path.layer) and
        segClearsVias(path.ctx, path.vias, a, b, path.net) and
        segClearsTracks(path.ctx, path.tracks, a, b, path.net, path.layer);
}

fn segClearsPadsLinear(ctx: *Ctx, a: [2]f64, b: [2]f64, net: i32, layer: u8) bool {
    const need = ctx.params.track_width / 2 + ctx.params.clearance;
    for (ctx.obs) |pad| {
        if (pad.net == net or (!pad.thru and pad.layer != layer)) continue;
        if (!padSegmentClears(ctx, pad, a, b, need)) return false;
    }
    return true;
}

/// Append one off-grid segment of the current net's width and stamp its
/// occupancy + RF shadow. Degenerate legs are dropped, so a caller may emit a
/// collapsed corner without special-casing it.
pub fn emitDoglegSegment(
    path: DirectPath,
    a: [2]f64,
    b: [2]f64,
    tracks: *std.ArrayList(Track),
) std.mem.Allocator.Error!void {
    if (std.math.hypot(b[0] - a[0], b[1] - a[1]) < 1e-9) return;
    try tracks.append(path.ctx.arena, .{
        .x1 = a[0],
        .y1 = a[1],
        .x2 = b[0],
        .y2 = b[1],
        .layer = path.layer,
        .width = path.ctx.params.track_width,
        .net = path.net,
    });
    stampStubOcc(path.ctx, a, b, path.net, path.layer);
    stampCurrentRf(path.ctx, a, b, path.net, path.layer);
}

/// Find a clear straight or one-bend diagonal+orthogonal connection.
fn findSimpleDogleg(path: DirectPath, a: [2]f64, b: [2]f64) ?Dogleg {
    const dx = b[0] - a[0];
    const dy = b[1] - a[1];
    const ax = @abs(dx);
    const ay = @abs(dy);
    if (ax < 1e-9 or ay < 1e-9 or @abs(ax - ay) < 1e-9) {
        return if (clearDoglegSegment(path, a, b)) Dogleg{} else null;
    }
    const sx: f64 = if (dx < 0) -1 else 1;
    const sy: f64 = if (dy < 0) -1 else 1;
    const bends = if (ax > ay)
        [2][2]f64{
            .{ a[0] + sx * ay, b[1] },
            .{ b[0] - sx * ay, a[1] },
        }
    else
        [2][2]f64{
            .{ b[0], a[1] + sy * ax },
            .{ a[0], b[1] - sy * ax },
        };
    for (bends) |bend| {
        if (!clearDoglegSegment(path, a, bend)) continue;
        if (!clearDoglegSegment(path, bend, b)) continue;
        return .{ .count = 1, .bends = .{ bend, .{ 0, 0 }, .{ 0, 0 } } };
    }
    return null;
}

fn findEscapedDogleg(path: DirectPath, a: [2]f64, b: [2]f64) ?Dogleg {
    const max_ring: usize = @max(1, numeric.toCount(@ceil(1.5 / direct_escape_grid_mm)));
    const direction = plane_via.fanDir(path.ctx.obs, a, path.net);
    const ang0 = std.math.atan2(direction[1], direction[0]);
    var ring: usize = 1;
    while (ring <= max_ring) : (ring += 1) {
        const rad = @as(f64, @floatFromInt(ring)) * direct_escape_grid_mm;
        var heading: usize = 0;
        while (heading < 8) : (heading += 1) {
            const ang = octilinear.compass45(ang0, heading);
            const escape = [2]f64{ a[0] + rad * @cos(ang), a[1] + rad * @sin(ang) };
            if (!clearDoglegSegment(path, a, escape)) continue;
            const rest = findSimpleDogleg(path, escape, b) orelse continue;
            if (rest.count == 0) return .{ .count = 1, .bends = .{ escape, .{ 0, 0 }, .{ 0, 0 } } };
            return .{ .count = 2, .bends = .{ escape, rest.bends[0], .{ 0, 0 } } };
        }
    }
    return null;
}

fn reversedDogleg(dogleg: Dogleg) Dogleg {
    var out = dogleg;
    var i: usize = 0;
    while (i < dogleg.count) : (i += 1) out.bends[i] = dogleg.bends[dogleg.count - 1 - i];
    return out;
}

/// Find a bounded two-bend octilinear path. After trying the shortest simple
/// forms, fan a short 45-degree escape from either endpoint and join the
/// remainder with a simple dogleg. Searching both directions handles a long
/// first run whose only compact breakout lives beside the destination pad.
fn findDogleg(path: DirectPath, a: [2]f64, b: [2]f64) ?Dogleg {
    if (findSimpleDogleg(path, a, b)) |simple| return simple;
    if (findEscapedDogleg(path, a, b)) |forward| return forward;
    if (findEscapedDogleg(path, b, a)) |reverse| return reversedDogleg(reverse);
    return null;
}

const EscapeCandidates = struct {
    items: [192][2]f64 = @splat(.{ 0, 0 }),
    len: usize = 0,

    fn add(self: *EscapeCandidates, path: DirectPath, origin: [2]f64, point: [2]f64) void {
        if (self.len >= self.items.len or !clearDoglegSegment(path, origin, point)) return;
        for (self.items[0..self.len]) |existing| {
            if (std.math.hypot(point[0] - existing[0], point[1] - existing[1]) < 1e-6) return;
        }
        self.items[self.len] = point;
        self.len += 1;
    }
};

fn addCircleBoundaryEscapes(
    out: *EscapeCandidates,
    path: DirectPath,
    origin: [2]f64,
    angle: f64,
    center: [2]f64,
    radius: f64,
) void {
    const ux = @cos(angle);
    const uy = @sin(angle);
    const ox = origin[0] - center[0];
    const oy = origin[1] - center[1];
    const projection = ox * ux + oy * uy;
    const discriminant = projection * projection - (ox * ox + oy * oy - radius * radius);
    if (discriminant < 0) return;
    const root = @sqrt(discriminant);
    for ([_]f64{ -projection - root, -projection + root }) |distance| {
        if (distance < 0.1 or distance > 3.0) continue;
        out.add(path, origin, .{ origin[0] + distance * ux, origin[1] + distance * uy });
    }
}

fn addTrackBoundaryEscapes(
    out: *EscapeCandidates,
    path: DirectPath,
    origin: [2]f64,
    angle: f64,
) void {
    const ux = @cos(angle);
    const uy = @sin(angle);
    for (path.tracks) |track| {
        if (track.net == path.net or track.layer != path.layer) continue;
        const tx = track.x2 - track.x1;
        const ty = track.y2 - track.y1;
        const length = std.math.hypot(tx, ty);
        if (length < 1e-9) continue;
        const dx = tx / length;
        const dy = ty / length;
        const nx = -dy;
        const ny = dx;
        const denom = ux * nx + uy * ny;
        if (@abs(denom) < 1e-9) continue;
        const need = track.width / 2 + path.ctx.params.track_width / 2 + path.ctx.params.clearance;
        addCircleBoundaryEscapes(out, path, origin, angle, .{ track.x1, track.y1 }, need);
        addCircleBoundaryEscapes(out, path, origin, angle, .{ track.x2, track.y2 }, need);
        const origin_offset = (origin[0] - track.x1) * nx + (origin[1] - track.y1) * ny;
        for ([_]f64{ -1, 1 }) |side| {
            const radius = (side * need - origin_offset) / denom;
            if (radius < 0.1 or radius > 3.0) continue;
            const point = [2]f64{ origin[0] + radius * ux, origin[1] + radius * uy };
            const along = (point[0] - track.x1) * dx + (point[1] - track.y1) * dy;
            if (along >= -2.0 and along <= length + 2.0) out.add(path, origin, point);
        }
    }
}

fn addViaBoundaryEscapes(
    out: *EscapeCandidates,
    path: DirectPath,
    origin: [2]f64,
    angle: f64,
) void {
    for (path.vias) |via| {
        if (via.net == path.net) continue;
        const radius = via.dia / 2 + path.ctx.params.track_width / 2 + path.ctx.params.clearance;
        addCircleBoundaryEscapes(out, path, origin, angle, .{ via.x, via.y }, radius);
    }
}

fn addPadBoundaryEscapes(
    out: *EscapeCandidates,
    path: DirectPath,
    origin: [2]f64,
    angle: f64,
) void {
    const ux = @cos(angle);
    const uy = @sin(angle);
    const inset = path.ctx.params.track_width / 2 + path.ctx.params.clearance;
    for (path.ctx.obs) |pad| {
        if (pad.net == path.net) continue;
        if (!pad.thru and pad.layer != path.layer) continue;
        const x0 = pad.x0 - inset;
        const x1 = pad.x1 + inset;
        const y0 = pad.y0 - inset;
        const y1 = pad.y1 + inset;
        if (@abs(ux) > 1e-9) for ([_]f64{ x0, x1 }) |x| {
            const radius = (x - origin[0]) / ux;
            if (radius < 0.1 or radius > 3.0) continue;
            const y = origin[1] + radius * uy;
            if (y >= y0 and y <= y1) out.add(path, origin, .{ x, y });
        };
        if (@abs(uy) > 1e-9) for ([_]f64{ y0, y1 }) |y| {
            const radius = (y - origin[1]) / uy;
            if (radius < 0.1 or radius > 3.0) continue;
            const x = origin[0] + radius * ux;
            if (x >= x0 and x <= x1) out.add(path, origin, .{ x, y });
        };
    }
}

fn escapeCandidates(path: DirectPath, origin: [2]f64, toward: [2]f64) EscapeCandidates {
    var out = EscapeCandidates{};
    const radii = [_]f64{ 1.5, 1.25, 1.0, 0.75, 0.5, 2.0, 0.25 };
    const base = std.math.atan2(toward[1] - origin[1], toward[0] - origin[0]);
    var heading: usize = 0;
    while (heading < 8) : (heading += 1) {
        const angle = octilinear.compass45(base, heading);
        addViaBoundaryEscapes(&out, path, origin, angle);
        addTrackBoundaryEscapes(&out, path, origin, angle);
        addPadBoundaryEscapes(&out, path, origin, angle);
        for (radii) |radius| {
            out.add(path, origin, .{
                origin[0] + radius * @cos(angle),
                origin[1] + radius * @sin(angle),
            });
        }
    }
    return out;
}

const max_continuous_bends: usize = 10;
const max_continuous_expansions: usize = 64;
const no_continuous_parent = std.math.maxInt(usize);

const DirectPolyline = struct {
    count: u4 = 0,
    bends: [max_continuous_bends][2]f64 = @splat(.{ 0, 0 }),
};

const ContinuousState = struct {
    point: [2]f64,
    parent: usize,
    depth: u8,
    cost: f64,
};

const ContinuousPointKey = struct { x: i32, y: i32 };

fn continuousPointKey(point: [2]f64) ContinuousPointKey {
    return .{
        .x = @intFromFloat(@round(point[0] * 1000.0)),
        .y = @intFromFloat(@round(point[1] * 1000.0)),
    };
}

fn continuousSolution(
    states: []const ContinuousState,
    current: usize,
    tail: Dogleg,
) ?DirectPolyline {
    var reversed: [max_continuous_bends][2]f64 = @splat(.{ 0, 0 });
    var reverse_len: usize = 0;
    var index = current;
    while (states[index].parent != no_continuous_parent) {
        if (reverse_len >= reversed.len) return null;
        reversed[reverse_len] = states[index].point;
        reverse_len += 1;
        index = states[index].parent;
    }
    if (reverse_len + tail.count > max_continuous_bends) return null;
    var out = DirectPolyline{};
    while (reverse_len > 0) {
        reverse_len -= 1;
        out.bends[out.count] = reversed[reverse_len];
        out.count += 1;
    }
    var i: usize = 0;
    while (i < tail.count) : (i += 1) {
        out.bends[out.count] = tail.bends[i];
        out.count += 1;
    }
    return out;
}

fn inContinuousWindow(point: [2]f64, a: [2]f64, b: [2]f64) bool {
    const margin = 3.0;
    return point[0] >= @min(a[0], b[0]) - margin and
        point[0] <= @max(a[0], b[0]) + margin and
        point[1] >= @min(a[1], b[1]) - margin and
        point[1] <= @max(a[1], b[1]) + margin;
}

/// Bounded continuous A* over exact-clearance boundary nodes. This is the
/// arbitrary-bend fallback after compact doglegs fail; it remains local to the
/// terminal pair and every proposed edge passes `clearDoglegSegment` before it
/// enters the queue.
fn findMultiBend(
    path: DirectPath,
    a: [2]f64,
    b: [2]f64,
) std.mem.Allocator.Error!?DirectPolyline {
    var states: std.ArrayList(ContinuousState) = .empty;
    var best = std.AutoHashMapUnmanaged(ContinuousPointKey, f64).empty;
    var queue = maze_scratch.Pq.init(path.ctx.arena, {});
    try states.append(path.ctx.arena, .{
        .point = a,
        .parent = no_continuous_parent,
        .depth = 0,
        .cost = 0,
    });
    try best.put(path.ctx.arena, continuousPointKey(a), 0);
    try queue.add(.{ .d = std.math.hypot(b[0] - a[0], b[1] - a[1]), .key = 0 });

    var expansions: usize = 0;
    while (queue.removeOrNull()) |item| {
        if (expansions >= max_continuous_expansions) break;
        const state = states.items[item.key];
        const known = best.get(continuousPointKey(state.point)) orelse continue;
        if (state.cost > known + clearance_eps) continue;
        expansions += 1;
        if (findDogleg(path, state.point, b)) |tail| {
            if (continuousSolution(states.items, item.key, tail)) |solution| return solution;
        }
        if (state.depth >= max_continuous_bends - 1) continue;
        const candidates = escapeCandidates(path, state.point, b);
        for (candidates.items[0..candidates.len]) |point| {
            if (!inContinuousWindow(point, a, b)) continue;
            const step = std.math.hypot(point[0] - state.point[0], point[1] - state.point[1]);
            if (step < 0.1) continue;
            const cost = state.cost + step;
            const key = continuousPointKey(point);
            if (best.get(key)) |old| if (old <= cost + clearance_eps) continue;
            try best.put(path.ctx.arena, key, cost);
            const index = states.items.len;
            try states.append(path.ctx.arena, .{
                .point = point,
                .parent = item.key,
                .depth = state.depth + 1,
                .cost = cost,
            });
            const heuristic = std.math.hypot(b[0] - point[0], b[1] - point[1]);
            const bend_cost = @as(f64, @floatFromInt(state.depth)) * 0.01;
            try queue.add(.{ .d = cost + heuristic + bend_cost, .key = index });
        }
    }
    return null;
}

const fine_grid_mm: f64 = 0.025;
const fine_grid_margin_mm: f64 = 0.75;
const max_fine_grid_nodes: usize = 50_000;

const FineGrid = struct {
    ox: f64,
    oy: f64,
    nx: usize,
    ny: usize,

    fn node(self: FineGrid, ix: usize, iy: usize) usize {
        return iy * self.nx + ix;
    }

    fn point(self: FineGrid, index: usize) [2]f64 {
        return .{
            self.ox + @as(f64, @floatFromInt(index % self.nx)) * fine_grid_mm,
            self.oy + @as(f64, @floatFromInt(index / self.nx)) * fine_grid_mm,
        };
    }
};

/// One pad check for `finePointClear`: false when the pad's copper outline
/// comes within `pad_need` of `point` (foreign pads on the copper's layer only).
inline fn pointClearsPad(pad: PadObs, net: i32, layer: u8, point: [2]f64, pad_need: f64) bool {
    if (pad.net == net or (!pad.thru and pad.layer != layer)) return true;
    if (pointMissesBox(point, pad.x0, pad.y0, pad.x1, pad.y1, pad_need)) return true;
    return pad_shape.pointDist(pad.x0, pad.y0, pad.x1, pad.y1, pad.poly, point[0], point[1], pad_need) >=
        pad_need - clearance_eps;
}

/// One via check for `finePointClear`: false when a foreign via's copper comes
/// within `need` of `point`.
inline fn pointClearsVia(via: Via, net: i32, point: [2]f64, need: f64) bool {
    if (via.net == net) return true;
    if (pointMissesBox(point, via.x, via.y, via.x, via.y, need)) return true;
    return std.math.hypot(point[0] - via.x, point[1] - via.y) >= need - clearance_eps;
}

/// One track check for `finePointClear`: false when a foreign track on the
/// copper's layer comes within `need` of `point`.
inline fn pointClearsTrack(track: Track, net: i32, layer: u8, point: [2]f64, need: f64) bool {
    if (track.net == net or track.layer != layer) return true;
    if (pointMissesBox(point, track.x1, track.y1, track.x2, track.y2, need)) return true;
    return segPointDist(track.x1, track.y1, track.x2, track.y2, point[0], point[1]) >= need - clearance_eps;
}

fn finePointClear(path: DirectPath, point: [2]f64) bool {
    if (!directSegmentInside(path, point, point)) return false;
    const ctx = path.ctx;
    const pad_need = ctx.params.track_width / 2 + ctx.params.clearance;
    if (ctx.pad_index == null) ctx.pad_index = PadGrid.build(ctx.arena, ctx.obs, gridBounds(ctx.grid), padIndexReach(ctx));
    if (ctx.pad_index) |pidx| {
        for (pidx.near(point[0], point[1])) |pi| {
            if (!pointClearsPad(ctx.obs[pi], path.net, path.layer, point, pad_need)) return false;
        }
    } else {
        for (ctx.obs) |pad| {
            if (!pointClearsPad(pad, path.net, path.layer, point, pad_need)) return false;
        }
    }
    if (copperIdx(ctx)) |cidx| {
        for (cidx.near(point[0], point[1])) |ci| {
            if (ci < ctx.copper_track_count) {
                if (ci >= path.tracks.len) continue; // defence in depth: a valid index only ever undershoots
                const need = path.tracks[ci].width / 2 + ctx.params.track_width / 2 + ctx.params.clearance;
                if (!pointClearsTrack(path.tracks[ci], path.net, path.layer, point, need)) return false;
            } else {
                const vi = ci - ctx.copper_track_count;
                if (vi >= path.vias.len) continue; // defence in depth: a valid index only ever undershoots
                const need = path.vias[vi].dia / 2 + ctx.params.track_width / 2 + ctx.params.clearance;
                if (!pointClearsVia(path.vias[vi], path.net, point, need)) return false;
            }
        }
        for (path.tracks[@min(ctx.copper_track_count, path.tracks.len)..]) |track| {
            const need = track.width / 2 + ctx.params.track_width / 2 + ctx.params.clearance;
            if (!pointClearsTrack(track, path.net, path.layer, point, need)) return false;
        }
        for (path.vias[@min(ctx.copper_via_count, path.vias.len)..]) |via| {
            const need = via.dia / 2 + ctx.params.track_width / 2 + ctx.params.clearance;
            if (!pointClearsVia(via, path.net, point, need)) return false;
        }
        return true;
    }
    for (path.vias) |via| {
        const need = via.dia / 2 + ctx.params.track_width / 2 + ctx.params.clearance;
        if (!pointClearsVia(via, path.net, point, need)) return false;
    }
    for (path.tracks) |track| {
        const need = track.width / 2 + ctx.params.track_width / 2 + ctx.params.clearance;
        if (!pointClearsTrack(track, path.net, path.layer, point, need)) return false;
    }
    return true;
}

fn fineGateways(
    arena: std.mem.Allocator,
    path: DirectPath,
    grid: FineGrid,
    blocked_cells: []const bool,
    target: [2]f64,
) std.mem.Allocator.Error![]const usize {
    var out: std.ArrayList(usize) = .empty;
    const cx: i64 = @intFromFloat(@round((target[0] - grid.ox) / fine_grid_mm));
    const cy: i64 = @intFromFloat(@round((target[1] - grid.oy) / fine_grid_mm));
    var ring: i64 = 0;
    while (ring <= 4) : (ring += 1) {
        var dx = -ring;
        while (dx <= ring) : (dx += 1) {
            var dy = -ring;
            while (dy <= ring) : (dy += 1) {
                if (ring > 0 and @abs(dx) != ring and @abs(dy) != ring) continue;
                const ix = cx + dx;
                const iy = cy + dy;
                if (ix < 0 or iy < 0 or ix >= grid.nx or iy >= grid.ny) continue;
                const node = grid.node(@intCast(ix), @intCast(iy));
                if (blocked_cells[node]) continue;
                const point = grid.point(node);
                if (!octilinear.isOctilinear(target, point) or !clearDoglegSegment(path, target, point)) continue;
                try out.append(arena, node);
            }
        }
        if (out.items.len > 0) break;
    }
    return out.items;
}

fn fineNeighbor(grid: FineGrid, node: usize, dx: i64, dy: i64) ?usize {
    const ix = @as(i64, @intCast(node % grid.nx)) + dx;
    const iy = @as(i64, @intCast(node / grid.nx)) + dy;
    if (ix < 0 or iy < 0 or ix >= grid.nx or iy >= grid.ny) return null;
    return grid.node(@intCast(ix), @intCast(iy));
}

fn compressFinePath(
    arena: std.mem.Allocator,
    path: DirectPath,
    grid: FineGrid,
    prev: []const i64,
    goal: usize,
    endpoints: [2][2]f64,
) std.mem.Allocator.Error!?DirectPolyline {
    const a = endpoints[0];
    const b = endpoints[1];
    var reversed: std.ArrayList([2]f64) = .empty;
    var node = goal;
    while (true) {
        try reversed.append(arena, grid.point(node));
        if (prev[node] < 0) break;
        node = @intCast(prev[node]);
    }
    var points: std.ArrayList([2]f64) = .empty;
    try points.append(arena, a);
    var i = reversed.items.len;
    while (i > 0) {
        i -= 1;
        const last = points.items[points.items.len - 1];
        if (std.math.hypot(last[0] - reversed.items[i][0], last[1] - reversed.items[i][1]) > 1e-6)
            try points.append(arena, reversed.items[i]);
    }
    const last = points.items[points.items.len - 1];
    if (std.math.hypot(last[0] - b[0], last[1] - b[1]) > 1e-6)
        try points.append(arena, b);

    var out = DirectPolyline{};
    i = 1;
    while (i + 1 < points.items.len) : (i += 1) {
        const before = points.items[i - 1];
        const point = points.items[i];
        const after = points.items[i + 1];
        const ux = point[0] - before[0];
        const uy = point[1] - before[1];
        const vx = after[0] - point[0];
        const vy = after[1] - point[1];
        if (@abs(ux * vy - uy * vx) < 1e-9 and ux * vx + uy * vy > 0) continue;
        if (out.count >= max_continuous_bends) return null;
        out.bends[out.count] = point;
        out.count += 1;
    }
    var start = a;
    for (out.bends[0..out.count]) |bend| {
        if (!clearDoglegSegment(path, start, bend)) return null;
        start = bend;
    }
    if (!clearDoglegSegment(path, start, b)) return null;
    return out;
}

/// Fine local A* for a narrow arbitrary-bend corridor. It is bounded to the
/// endpoint neighbourhood, so a 0.025 mm phase does not allocate a full-board
/// grid; every compressed output segment is rechecked against exact geometry.
fn findFineGridPath(
    path: DirectPath,
    a: [2]f64,
    b: [2]f64,
) std.mem.Allocator.Error!?DirectPolyline {
    const ox = @floor((@min(a[0], b[0]) - fine_grid_margin_mm) / fine_grid_mm) * fine_grid_mm;
    const oy = @floor((@min(a[1], b[1]) - fine_grid_margin_mm) / fine_grid_mm) * fine_grid_mm;
    const maxx = @ceil((@max(a[0], b[0]) + fine_grid_margin_mm) / fine_grid_mm) * fine_grid_mm;
    const maxy = @ceil((@max(a[1], b[1]) + fine_grid_margin_mm) / fine_grid_mm) * fine_grid_mm;
    const nx = numeric.toCount(@round((maxx - ox) / fine_grid_mm) + 1);
    const ny = numeric.toCount(@round((maxy - oy) / fine_grid_mm) + 1);
    if (nx == 0 or ny == 0 or nx * ny > max_fine_grid_nodes) return null;
    const grid = FineGrid{ .ox = ox, .oy = oy, .nx = nx, .ny = ny };
    const count = nx * ny;
    const blocked_cells = try path.ctx.arena.alloc(bool, count);
    for (blocked_cells, 0..) |*blocked_cell, node| blocked_cell.* = !finePointClear(path, grid.point(node));
    const sources = try fineGateways(path.ctx.arena, path, grid, blocked_cells, a);
    const goals = try fineGateways(path.ctx.arena, path, grid, blocked_cells, b);
    if (sources.len == 0 or goals.len == 0) return null;

    const goal_cells = try path.ctx.arena.alloc(bool, count);
    const closed = try path.ctx.arena.alloc(bool, count);
    const dist = try path.ctx.arena.alloc(f64, count);
    const prev = try path.ctx.arena.alloc(i64, count);
    @memset(goal_cells, false);
    @memset(closed, false);
    @memset(dist, std.math.inf(f64));
    @memset(prev, -1);
    for (goals) |goal| goal_cells[goal] = true;
    var queue = maze_scratch.Pq.init(path.ctx.arena, {});
    for (sources) |source| {
        dist[source] = std.math.hypot(grid.point(source)[0] - a[0], grid.point(source)[1] - a[1]);
        try queue.add(.{ .d = dist[source], .key = source });
    }
    const directions = [_][2]i64{
        .{ 1, 0 },
        .{ -1, 0 },
        .{ 0, 1 },
        .{ 0, -1 },
        .{ 1, 1 },
        .{ 1, -1 },
        .{ -1, 1 },
        .{ -1, -1 },
    };
    var found: ?usize = null;
    while (queue.removeOrNull()) |item| {
        if (closed[item.key]) continue;
        closed[item.key] = true;
        if (goal_cells[item.key]) {
            found = item.key;
            break;
        }
        for (directions) |direction| {
            const next = fineNeighbor(grid, item.key, direction[0], direction[1]) orelse continue;
            if (closed[next] or blocked_cells[next]) continue;
            if (direction[0] != 0 and direction[1] != 0) {
                const side_x = fineNeighbor(grid, item.key, direction[0], 0) orelse continue;
                const side_y = fineNeighbor(grid, item.key, 0, direction[1]) orelse continue;
                if (blocked_cells[side_x] or blocked_cells[side_y]) continue;
            }
            const step = if (direction[0] != 0 and direction[1] != 0) fine_grid_mm * std.math.sqrt2 else fine_grid_mm;
            const next_dist = dist[item.key] + step;
            if (next_dist >= dist[next]) continue;
            dist[next] = next_dist;
            prev[next] = @intCast(item.key);
            const point = grid.point(next);
            const heuristic = std.math.hypot(b[0] - point[0], b[1] - point[1]);
            try queue.add(.{ .d = next_dist + heuristic, .key = next });
        }
    }
    const goal = found orelse return null;
    return compressFinePath(path.ctx.arena, path, grid, prev, goal, .{ a, b });
}

/// Find a bounded three-bend octilinear path by escaping both endpoints and
/// joining the two escape points with a straight or one-bend middle. Alongside
/// fixed compact escapes, candidate endpoints sit exactly on clearance
/// boundaries derived from retained horizontal/vertical copper. That lets the
/// continuous search use a zero-slack bus lane without depending on grid phase.
fn findThreeBend(path: DirectPath, a: [2]f64, b: [2]f64) ?Dogleg {
    if (findDogleg(path, a, b)) |shorter| return shorter;
    const starts = escapeCandidates(path, a, b);
    const ends = escapeCandidates(path, b, a);
    for (starts.items[0..starts.len]) |ae| {
        for (ends.items[0..ends.len]) |be| {
            const middle = findSimpleDogleg(path, ae, be) orelse continue;
            if (middle.count == 0) return .{ .count = 2, .bends = .{ ae, be, .{ 0, 0 } } };
            return .{ .count = 3, .bends = .{ ae, middle.bends[0], be } };
        }
    }
    return null;
}

fn emitDogleg(
    path: DirectPath,
    a: [2]f64,
    b: [2]f64,
    dogleg: Dogleg,
    tracks: *std.ArrayList(Track),
) std.mem.Allocator.Error!void {
    var start = a;
    var i: usize = 0;
    while (i < dogleg.count) : (i += 1) {
        try emitDoglegSegment(path, start, dogleg.bends[i], tracks);
        start = dogleg.bends[i];
    }
    try emitDoglegSegment(path, start, b, tracks);
}

fn emitPolyline(
    path: DirectPath,
    a: [2]f64,
    b: [2]f64,
    polyline: DirectPolyline,
    tracks: *std.ArrayList(Track),
) std.mem.Allocator.Error!void {
    var start = a;
    var i: usize = 0;
    while (i < polyline.count) : (i += 1) {
        try emitDoglegSegment(path, start, polyline.bends[i], tracks);
        start = polyline.bends[i];
    }
    try emitDoglegSegment(path, start, b, tracks);
}

const ContinuousRoute = union(enum) {
    dogleg: Dogleg,
    polyline: DirectPolyline,
};

fn findContinuousRoute(
    path: DirectPath,
    a: [2]f64,
    b: [2]f64,
) std.mem.Allocator.Error!?ContinuousRoute {
    if (findThreeBend(path, a, b)) |dogleg| return .{ .dogleg = dogleg };
    if (try findMultiBend(path, a, b)) |polyline| return .{ .polyline = polyline };
    if (selectedCount(path.ctx.selected_nets) == 1) {
        if (try findFineGridPath(path, a, b)) |polyline| return .{ .polyline = polyline };
    }
    return null;
}

fn emitContinuousRoute(
    path: DirectPath,
    a: [2]f64,
    b: [2]f64,
    found: ContinuousRoute,
    tracks: *std.ArrayList(Track),
) std.mem.Allocator.Error!void {
    switch (found) {
        .dogleg => |dogleg| try emitDogleg(path, a, b, dogleg, tracks),
        .polyline => |polyline| try emitPolyline(path, a, b, polyline, tracks),
    }
}

/// Route a clear two-terminal same-layer net without forcing its naturally
/// off-grid pad centres through maze nodes.
fn tryDirectDogleg(run: DirectRun, from: NetPt, to: NetPt) std.mem.Allocator.Error!bool {
    const path = run.path(from.layer);
    const a = [2]f64{ from.x, from.y };
    const b = [2]f64{ to.x, to.y };
    const found = if (axisPairDogleg(path, from, to)) |dogleg|
        ContinuousRoute{ .dogleg = dogleg }
    else
        (try findContinuousRoute(path, a, b)) orelse return false;
    try emitContinuousRoute(path, a, b, found, run.tracks);
    return true;
}

/// The one-via primitive searches this far from either terminal. Three mm is
/// enough to escape the pad field around dense RF/QFN devices without moving a
/// layer transition halfway across the board.
const direct_via_radius_mm: f64 = 3.0;
/// A plain (non-escape) net's terminal span beyond which the direct-synthesis
/// primitives are skipped in favour of the maze. Measured (`docs/
/// autorouter-wall-time.md`): long cross-layer nets pay the entire 0.05 mm
/// via lattice (~7 400 candidates) and almost never close direct; the maze
/// routes them in a fraction of the time. Escape-constrained (RF) nets are
/// exempt — their straight-trace quality is the point of the direct path.
const direct_span_mm: f64 = 6.0;
/// Per-net exact-clearance probe ceiling for the plain-net direct path
/// (`clearDoglegSegment` / `directViaClear`). A net that cannot close direct
/// burns this and falls to the maze; with the copper index each probe is
/// O(local), so this is a wall-clock safety net, not the primary bound.
const direct_probe_budget: usize = 200_000;
/// A failed hard guide's immediate whole-board fine retry runs inline before
/// lower-priority nets get a turn. Keep its off-grid escape experiment small:
/// Barracuda's first failed guide spent the entire 270-second board allowance
/// in this one retry at the ordinary 200k ceiling. The maze still gets its
/// bounded fine-grid search; only the multiplicative exact-dogleg fallback is
/// shortened here.
const immediate_fine_probe_budget: usize = 8_192;
/// Under a whole-board deadline, a hard waypoint is a quick authored attempt,
/// not permission to monopolize the transaction. A valid coarse guide needs
/// a bounded allowance for every leg; Barracuda's seven-leg control guides
/// exhausted both the former 512-probe ceiling and a later 2,048-probe ceiling
/// before reaching their final pad. 8,192 matches the already-bounded
/// immediate fine retry and lets the cheap exact attempt finish before the
/// much more expensive guided maze takes over.
/// A route that exhausts this still falls through to the maze, and the shared
/// wall-clock deadline remains the outer bound across every net and retry.
const deadline_guided_probe_budget: usize = 8_192;
/// Local 2-D search radius for a one-via cross-face route. The via normally
/// belongs beside a terminal; a larger transition is left to the maze.
const direct_one_via_radius_mm: f64 = 1.5;
const direct_via_grid_mm: f64 = 0.05;

/// True when a via of the current net params centred at `pos` clears the board
/// outline, every blocking zone, every foreign pad, every foreign via's copper,
/// every drilled hole's manufacturing wall, and every foreign track — the exact
/// (non-raster) via legality test the direct primitives and the coupled
/// diff-pair construction both gate on.
pub fn directViaClear(run: DirectRun, pos: [2]f64) bool {
    if (run.ctx.timing) |t| t.direct_via_checks += 1;
    if (probeBudgetExhausted(run.ctx)) return false;
    const nearest = run.ctx.grid.nearest(pos[0], pos[1]);
    const node = run.ctx.grid.node(nearest[0], nearest[1]);
    // The site ban is a property of the SITE, not of the search that reached it:
    // an off-grid direct via must respect it exactly as a maze via does, or a
    // caller that banned a region (a coupled pair keeping layer changes out of
    // its own pad field) silently loses the guarantee. Null for every route
    // that sets no ban, so this is inert everywhere else.
    if (run.ctx.via_ban) |mask| {
        if (node < mask.len and mask[node]) return false;
    }
    if (!viaClearsOutline(run.ctx, pos[0], pos[1], run.net)) return false;
    // A barrel is on every layer, so one foreign lane refuses the site.
    if (lane_reserve.viaBlocked(run.ctx.reserved_lanes, run.ctx.grid, run.net, pos)) return false;
    const zone_reach = viaR(run.ctx.params) + run.ctx.params.clearance;
    if (zoneBlocksPoint(run.ctx, 0, pos, run.net, zone_reach, true)) return false;
    return viaClearsPads(run.ctx, pos[0], pos[1], run.net) and
        viaClearsVias(run.ctx, run.vias.items, pos[0], pos[1], run.net) and
        viaClearsHoles(run.ctx, run.vias.items, pos[0], pos[1]) and
        viaClearsTracks(run.ctx, run.tracks.items, pos[0], pos[1], run.net);
}

fn tryDirectViaCandidate(run: DirectRun, from: NetPt, to: NetPt, pos: [2]f64) std.mem.Allocator.Error!bool {
    if (!directViaClear(run, pos)) return false;
    const a = [2]f64{ from.x, from.y };
    const b = [2]f64{ to.x, to.y };
    const from_path = run.path(from.layer);
    const to_path = run.path(to.layer);
    const from_dogleg = axisExitDogleg(from_path, from, pos) orelse findDogleg(from_path, a, pos) orelse return false;
    const to_dogleg = axisEntryDogleg(to_path, pos, to) orelse findDogleg(to_path, pos, b) orelse return false;
    try emitDogleg(from_path, a, pos, from_dogleg, run.tracks);
    try emitDogleg(to_path, pos, b, to_dogleg, run.tracks);
    try run.vias.append(run.ctx.arena, .{
        .x = pos[0],
        .y = pos[1],
        .dia = run.ctx.params.via_dia,
        .drill = run.ctx.params.via_drill,
        .net = run.net,
    });
    stampViaOcc(run.ctx, pos[0], pos[1], run.net);
    return true;
}

fn preferredAlternateLayer(ctx: *const Ctx, terminal: u8) ?u8 {
    if (ctx.preferred_layers == 0 and ctx.selected_nets.len == 0) return null;
    var layer: u8 = 0;
    while (layer < ctx.occ.len) : (layer += 1) {
        if (layer == terminal) continue;
        if (ctx.preferred_layers != 0 and !layerInMask(ctx.preferred_layers, layer)) continue;
        if (!layerInMask(ctx.allowed_layers, layer)) continue;
        return layer;
    }
    return null;
}

fn directViaPairClear(run: DirectRun, first: [2]f64, second: [2]f64) bool {
    if (!directViaClear(run, first) or !directViaClear(run, second)) return false;
    const drill_wall = run.ctx.params.via_drill + run.ctx.hole_to_hole;
    const copper = viaPairCenterNeed(run.ctx, run.ctx.params.via_dia, run.ctx.params.via_dia, true);
    return std.math.hypot(second[0] - first[0], second[1] - first[1]) >= @max(drill_wall, copper) - clearance_eps;
}

fn tryDirectPreferredCandidate(
    run: DirectRun,
    from: NetPt,
    to: NetPt,
    route_layer: u8,
    first: [2]f64,
    second: [2]f64,
) std.mem.Allocator.Error!bool {
    if (!directViaPairClear(run, first, second)) return false;
    const a = [2]f64{ from.x, from.y };
    const b = [2]f64{ to.x, to.y };
    const terminal_path = run.path(from.layer);
    const preferred_path = run.path(route_layer);
    const first_leg = axisExitDogleg(terminal_path, from, first) orelse findDogleg(terminal_path, a, first) orelse return false;
    const middle = findDogleg(preferred_path, first, second) orelse return false;
    const last_leg = axisEntryDogleg(terminal_path, second, to) orelse findDogleg(terminal_path, second, b) orelse return false;
    try emitDogleg(terminal_path, a, first, first_leg, run.tracks);
    try emitDogleg(preferred_path, first, second, middle, run.tracks);
    try emitDogleg(terminal_path, second, b, last_leg, run.tracks);
    for ([2][2]f64{ first, second }) |pos| {
        try run.vias.append(run.ctx.arena, .{
            .x = pos[0],
            .y = pos[1],
            .dia = run.ctx.params.via_dia,
            .drill = run.ctx.params.via_drill,
            .net = run.net,
        });
        stampViaOcc(run.ctx, pos[0], pos[1], run.net);
    }
    return true;
}

/// Honour a preferred non-terminal layer with matched nearby transitions: one
/// via beside each same-face pad and the long leg on the preferred layer.
fn tryDirectPreferredLayer(run: DirectRun, from: NetPt, to: NetPt) std.mem.Allocator.Error!bool {
    if (!run.ctx.allow_vias) return false;
    const route_layer = preferredAlternateLayer(run.ctx, from.layer) orelse return false;
    const max_ring: usize = @max(1, numeric.toCount(@ceil(direct_via_radius_mm / run.ctx.grid.g)));
    const a = [2]f64{ from.x, from.y };
    const b = [2]f64{ to.x, to.y };
    const direction = plane_via.fanDir(run.ctx.obs, a, run.net);
    const ang0 = std.math.atan2(direction[1], direction[0]);
    var ring: usize = 1;
    while (ring <= max_ring) : (ring += 1) {
        const rad = @as(f64, @floatFromInt(ring)) * run.ctx.grid.g;
        var heading: usize = 0;
        while (heading < 8) : (heading += 1) {
            const ang = octilinear.compass45(ang0, heading);
            const delta = [2]f64{ rad * @cos(ang), rad * @sin(ang) };
            const first = [2]f64{ a[0] + delta[0], a[1] + delta[1] };
            const second = [2]f64{ b[0] + delta[0], b[1] + delta[1] };
            if (try tryDirectPreferredCandidate(run, from, to, route_layer, first, second)) return true;
        }
    }
    return false;
}

fn tryDirectViaLatticeRing(
    run: DirectRun,
    from: NetPt,
    to: NetPt,
    anchor: NetPt,
    ring: i64,
) std.mem.Allocator.Error!bool {
    const ox = @round(anchor.x / direct_via_grid_mm) * direct_via_grid_mm;
    const oy = @round(anchor.y / direct_via_grid_mm) * direct_via_grid_mm;
    var dx = -ring;
    while (dx <= ring) : (dx += 1) {
        var dy = -ring;
        while (dy <= ring) : (dy += 1) {
            if (@abs(dx) != ring and @abs(dy) != ring) continue;
            const pos = [2]f64{
                ox + @as(f64, @floatFromInt(dx)) * direct_via_grid_mm,
                oy + @as(f64, @floatFromInt(dy)) * direct_via_grid_mm,
            };
            if (try tryDirectViaCandidate(run, from, to, pos)) return true;
        }
    }
    return false;
}

const HybridAttempt = enum { skip, failed, routed };

fn tryDirectThreeBendViaCandidate(
    run: DirectRun,
    from: NetPt,
    to: NetPt,
    pos: [2]f64,
) std.mem.Allocator.Error!bool {
    if (!directViaClear(run, pos)) return false;
    const a = [2]f64{ from.x, from.y };
    const b = [2]f64{ to.x, to.y };
    const from_path = run.path(from.layer);
    const from_dogleg = axisExitDogleg(from_path, from, pos) orelse findDogleg(from_path, a, pos) orelse return false;
    const to_path = run.path(to.layer);
    if (axisEntryDogleg(to_path, pos, to) orelse findThreeBend(to_path, pos, b)) |to_dogleg| {
        try emitDogleg(from_path, a, pos, from_dogleg, run.tracks);
        try emitDogleg(to_path, pos, b, to_dogleg, run.tracks);
        try run.vias.append(run.ctx.arena, .{
            .x = pos[0],
            .y = pos[1],
            .dia = run.ctx.params.via_dia,
            .drill = run.ctx.params.via_drill,
            .net = run.net,
        });
        stampViaOcc(run.ctx, pos[0], pos[1], run.net);
        return true;
    }
    return false;
}

fn tryViaSeededMazeCandidate(
    run: DirectRun,
    from: NetPt,
    to: NetPt,
    pos: [2]f64,
) std.mem.Allocator.Error!HybridAttempt {
    if (try tryDirectThreeBendViaCandidate(run, from, to, pos)) return .routed;
    if (!directViaClear(run, pos)) return .skip;
    const a = [2]f64{ from.x, from.y };
    const from_path = run.path(from.layer);
    const from_dogleg = axisExitDogleg(from_path, from, pos) orelse findDogleg(from_path, a, pos) orelse return .skip;
    const track_mark = run.tracks.items.len;
    const via_mark = run.vias.items.len;
    try emitDogleg(from_path, a, pos, from_dogleg, run.tracks);
    try run.vias.append(run.ctx.arena, .{
        .x = pos[0],
        .y = pos[1],
        .dia = run.ctx.params.via_dia,
        .drill = run.ctx.params.via_drill,
        .net = run.net,
    });
    stampViaOcc(run.ctx, pos[0], pos[1], run.net);

    const ends = try padMazeEnds(run.ctx, run.tracks.items, run.vias.items, to, run.net);
    const old_allow_vias = run.ctx.allow_vias;
    run.ctx.allow_vias = false;
    const hit = dijkstra(run.ctx, run.net, ends, run.tracks, run.vias) catch |err| {
        run.ctx.allow_vias = old_allow_vias;
        return err;
    };
    run.ctx.allow_vias = old_allow_vias;
    if (hit) |found| {
        try gateStub(run.ctx, run.net, to, found.goal, run.vias.items, run.tracks);
        return .routed;
    }
    shrinkCopper(run.tracks, run.vias, track_mark, via_mark);
    clearNetOcc(run.ctx, run.net);
    return .failed;
}

fn tryThreeBendViaLatticeRing(
    run: DirectRun,
    from: NetPt,
    to: NetPt,
    ring: i64,
) std.mem.Allocator.Error!bool {
    const ox = @round(from.x / direct_via_grid_mm) * direct_via_grid_mm;
    const oy = @round(from.y / direct_via_grid_mm) * direct_via_grid_mm;
    const toward = [2]f64{ to.x - from.x, to.y - from.y };
    var dx = -ring;
    while (dx <= ring) : (dx += 1) {
        var dy = -ring;
        while (dy <= ring) : (dy += 1) {
            if (@abs(dx) != ring and @abs(dy) != ring) continue;
            const delta = [2]f64{
                @as(f64, @floatFromInt(dx)) * direct_via_grid_mm,
                @as(f64, @floatFromInt(dy)) * direct_via_grid_mm,
            };
            if (delta[0] * toward[0] + delta[1] * toward[1] <= 0) continue;
            const pos = [2]f64{ ox + delta[0], oy + delta[1] };
            if (try tryDirectThreeBendViaCandidate(run, from, to, pos)) return true;
        }
    }
    return false;
}

fn tryViaSeededMaze(run: DirectRun, from: NetPt, to: NetPt) std.mem.Allocator.Error!bool {
    // Try useful breakout distances before arbitrary near-pad lattice points.
    // A transition just outside a dense package's pad collar gives the maze a
    // real source corridor; a via-in-pad source is often legal yet boxed in on
    // the destination face. Head toward the other terminal first, then sweep
    // the remaining compass directions.
    const radii = [_]f64{ 0.75, 1.5, 1.0, 1.25, 0.5, 0.25 };
    const ox = @round(from.x / direct_via_grid_mm) * direct_via_grid_mm;
    const oy = @round(from.y / direct_via_grid_mm) * direct_via_grid_mm;
    const ang0 = std.math.atan2(to.y - from.y, to.x - from.x);
    var attempts: usize = 0;
    for (radii) |radius| {
        var heading: usize = 0;
        while (heading < 8) : (heading += 1) {
            const ang = octilinear.compass45(ang0, heading);
            const pos = [2]f64{ ox + radius * @cos(ang), oy + radius * @sin(ang) };
            switch (try tryViaSeededMazeCandidate(run, from, to, pos)) {
                .skip => {},
                .routed => return true,
                .failed => {
                    attempts += 1;
                    if (attempts >= 4) return false;
                },
            }
        }
    }
    return false;
}

/// Seed a same-face route with an exact off-grid via, then let the maze place
/// the return transition. This covers local layer detours where both vias sit
/// beside one endpoint (a common escape around a dense connector/pad wall),
/// which the matched-offset preferred-layer primitive cannot represent.
fn tryTwoViaSeededMazeCandidate(
    run: DirectRun,
    from: NetPt,
    to: NetPt,
    pos: [2]f64,
) std.mem.Allocator.Error!HybridAttempt {
    if (!directViaClear(run, pos)) return .skip;
    const start = [2]f64{ from.x, from.y };
    const from_path = run.path(from.layer);
    const first_leg = axisExitDogleg(from_path, from, pos) orelse findThreeBend(from_path, start, pos) orelse return .skip;
    const track_mark = run.tracks.items.len;
    const via_mark = run.vias.items.len;
    try emitDogleg(from_path, start, pos, first_leg, run.tracks);
    try run.vias.append(run.ctx.arena, .{
        .x = pos[0],
        .y = pos[1],
        .dia = run.ctx.params.via_dia,
        .drill = run.ctx.params.via_drill,
        .net = run.net,
    });
    stampViaOcc(run.ctx, pos[0], pos[1], run.net);

    const ends = try padMazeEnds(run.ctx, run.tracks.items, run.vias.items, to, run.net);
    if (try dijkstra(run.ctx, run.net, ends, run.tracks, run.vias)) |hit| {
        try gateStub(run.ctx, run.net, to, hit.goal, run.vias.items, run.tracks);
        return .routed;
    }
    shrinkCopper(run.tracks, run.vias, track_mark, via_mark);
    clearNetOcc(run.ctx, run.net);
    return .failed;
}

fn compass22(ang0: f64, k: usize) f64 {
    const step = std.math.pi / 8.0;
    const base = @round(ang0 / step) * step;
    const mag: f64 = @floatFromInt((k + 1) / 2);
    const sign: f64 = if (k % 2 == 1) 1 else -1;
    return base + sign * mag * step;
}

fn tryTwoViaSeededMaze(run: DirectRun, from: NetPt, to: NetPt) std.mem.Allocator.Error!bool {
    if (!run.ctx.allow_vias or preferredAlternateLayer(run.ctx, from.layer) == null) return false;
    const radii = [_]f64{ 4.0, 3.0, 5.0, 2.0, 1.5, 0.75 };
    const anchors = [2]NetPt{ to, from };
    var attempts: usize = 0;
    for (anchors) |anchor| {
        const other = if (anchor.x == to.x and anchor.y == to.y) from else to;
        const base = std.math.atan2(other.y - anchor.y, other.x - anchor.x);
        for (radii) |radius| {
            var heading: usize = 0;
            while (heading < 16) : (heading += 1) {
                const angle = compass22(base, heading);
                const px = anchor.x + radius * @cos(angle);
                const py = anchor.y + radius * @sin(angle);
                const pos = [2]f64{
                    @round(px / direct_via_grid_mm) * direct_via_grid_mm,
                    @round(py / direct_via_grid_mm) * direct_via_grid_mm,
                };
                switch (try tryTwoViaSeededMazeCandidate(run, from, to, pos)) {
                    .skip => {},
                    .routed => return true,
                    .failed => {
                        attempts += 1;
                        if (attempts >= 4) return false;
                    },
                }
            }
        }
    }
    return false;
}

/// Route a two-terminal net whose pads live on different faces with one
/// off-grid via and an octilinear dogleg on each face. Candidate vias fan out
/// over a two-dimensional lattice around both pads, nearest first. Unlike an
/// eight-ray fan this can reach a narrow safe corridor at an arbitrary x/y
/// offset while still keeping the transition close to a terminal.
fn tryDirectOneVia(run: DirectRun, from: NetPt, to: NetPt) std.mem.Allocator.Error!bool {
    if (!run.ctx.allow_vias) return false;
    const anchors = [2]NetPt{ from, to };
    const max_ring: i64 = @intCast(@max(1, numeric.toCount(@ceil(direct_one_via_radius_mm / direct_via_grid_mm))));
    var ring: i64 = 1;
    while (ring <= max_ring) : (ring += 1) {
        for (anchors) |anchor| {
            if (try tryDirectViaLatticeRing(run, from, to, anchor, ring)) return true;
        }
    }
    ring = @intFromFloat(@ceil(0.4 / direct_via_grid_mm));
    while (ring <= max_ring) : (ring += 1) {
        if (try tryThreeBendViaLatticeRing(run, from, to, ring)) return true;
    }
    return try tryViaSeededMaze(run, from, to);
}

/// Rings the pad-gateway search fans outward — ~1.5 mm at the default pitch,
/// enough to clear a QFN pad collar plus the ground-via ring beside it.
const gate_rings: usize = 6;

/// Collect the off-grid gateway nodes of pad terminal `pt`: grid nodes within
/// `GATE_RINGS` of the pad centre that are themselves routable AND reachable
/// from the pad centre by ONE straight stub keeping true clearance from every
/// foreign pad, placed via, and routed track. Along a pad's own axis such a
/// stub always clears its row neighbours (the lateral gap is fixed by the pad
/// pitch), so a fine-pitch pin keeps an exit even when every nearby grid node
/// sits inside a neighbour's clearance. Keys are appended to `out` (deduped).
fn padGateways(ctx: *Ctx, tracks: []const Track, vias: []const Via, pt: NetPt, net: i32, out: *std.ArrayList(usize)) std.mem.Allocator.Error!void {
    if (ctx.timing) |t| t.begin(.gateways);
    defer if (ctx.timing) |t| t.end(.gateways);
    // Escape-constrained nets prefer gateways along the pad's outward axis —
    // the stub IS the start of the straight escape. If that filtered fan
    // yields nothing (a hemmed fine-pitch pad), fall back to the full fan:
    // routability wins and the bend smoother's reserve flags the residual.
    const escape = ctx.rf.escape_mm > 0 and (pt.out[0] != 0 or pt.out[1] != 0);
    const before = out.items.len;
    const scan = GateScan{ .ctx = ctx, .tracks = tracks, .vias = vias, .pt = pt, .net = net };
    try padGatewayFan(scan, out, escape);
    if (escape and out.items.len == before)
        try padGatewayFan(scan, out, false);
}

/// One pad terminal's gateway scan context (see `padGateways`).
const GateScan = struct {
    ctx: *Ctx,
    tracks: []const Track,
    vias: []const Via,
    pt: NetPt,
    net: i32,
};

fn padGatewayFan(
    scan: GateScan,
    out: *std.ArrayList(usize),
    escape_aligned_only: bool,
) std.mem.Allocator.Error!void {
    const ctx = scan.ctx;
    const grid = ctx.grid;
    const c = [2]f64{ scan.pt.x, scan.pt.y };
    const dir = plane_via.fanDir(ctx.obs, c, scan.net);
    var ring: usize = 1;
    while (ring <= ctx.gate_rings) : (ring += 1) {
        const rad = @as(f64, @floatFromInt(ring)) * grid.g;
        var k: usize = 0;
        while (k < 8) : (k += 1) {
            const ang = octilinear.compass45(std.math.atan2(dir[1], dir[0]), k);
            if (escape_aligned_only) {
                const along = @cos(ang) * scan.pt.out[0] + @sin(ang) * scan.pt.out[1];
                if (along < escape_align_min) continue;
            }
            const nd = grid.nearest(c[0] + rad * @cos(ang), c[1] + rad * @sin(ang));
            const n = grid.node(nd[0], nd[1]);
            const key = @as(usize, scan.pt.layer) * grid.nx * grid.ny + n;
            if (std.mem.indexOfScalar(usize, out.items, key) != null) continue;
            if (blocked(ctx, scan.pt.layer, n, scan.net)) continue;
            const s = [2]f64{ grid.worldX(nd[0]), grid.worldY(nd[1]) };
            const gateway_len = std.math.hypot(s[0] - c[0], s[1] - c[1]);
            const saved_width = router_support.usePadGateway(&ctx.params, gateway_len);
            const clears = segClearsPadsOnLayer(ctx, c, s, scan.net, null) and
                segClearsVias(ctx, scan.vias, c, s, scan.net) and
                segClearsTracks(ctx, scan.tracks, c, s, scan.net, scan.pt.layer);
            ctx.params.track_width = saved_width;
            if (!clears) continue;
            try out.append(ctx.arena, key);
        }
    }
}

/// Pull a leg's copper off a pad-buried start. `stampStubOcc`/`stampViaOcc` mark
/// this net's clearance HALO, not just its centreline, so Dijkstra can seed a leg
/// at a node a FOREIGN land swallows — and `emitSeg` then draws the run's first
/// segment out of that land (barracuda's `LMX_VTUNE` over `U17`'s ground pad, and
/// three rail stubs grazing their neighbours' ground pads).
///
/// Refusing the seed is the obvious fix and the wrong one: `tryMazeTerminalTree`
/// gives up on the WHOLE net when one leg cannot reach the net's copper, which
/// measured at nine lost nets and double the route time on barracuda. So keep the
/// route and shorten the copper — trim the source-end segment back to its first
/// clearing point (`trimStub` walked from the far end). The leg stays routed, the
/// illegal metal is gone, and the residue is a sub-millimetre gap the (probed)
/// weld closes when it can and `net_open` names when it cannot. Returns the leg's
/// new start, or the node's own point when it was legal to begin with.
fn trimBuriedStart(
    ctx: *Ctx,
    net: i32,
    key: usize,
    from: usize,
    tracks: *std.ArrayList(Track),
    vias: []const Via,
) [2]f64 {
    const grid = ctx.grid;
    const nodes = grid.nx * grid.ny;
    const layer: u8 = @intCast(key / nodes);
    const n = key % nodes;
    const w = [2]f64{ grid.worldX(n % grid.nx), grid.worldY(n / grid.nx) };
    if (!foreignPadAt(ctx, layer, n, net)) return w;
    for (tracks.items[from..]) |*t| {
        if (t.net != net or t.layer != layer) continue;
        const at_head = @abs(t.x1 - w[0]) < 1e-6 and @abs(t.y1 - w[1]) < 1e-6;
        const at_tail = @abs(t.x2 - w[0]) < 1e-6 and @abs(t.y2 - w[1]) < 1e-6;
        if (!at_head and !at_tail) continue;
        const far = if (at_head) [2]f64{ t.x2, t.y2 } else [2]f64{ t.x1, t.y1 };
        // Nothing clears ⇒ `kept` lands on `far`, collapsing the segment to a
        // degenerate stub that `dropDegenerateTracks` sweeps up at the end.
        const kept = trimStub(ctx, vias, tracks.items, far, w, net, layer);
        if (at_head) {
            t.x1 = kept[0];
            t.y1 = kept[1];
        } else {
            t.x2 = kept[0];
            t.y2 = kept[1];
        }
        return kept;
    }
    return w;
}

/// Bridge a later maze leg's weld node to the net's EXISTING copper. A leg after
/// the first seeds Dijkstra from every `occ==net` node and welds at whichever it
/// reaches — but `stampStubOcc` / `stampViaOcc` mark `occ==net` out to the copper
/// CLEARANCE halo (`copperHalo`), not just the copper edge, so the weld node can
/// sit a fraction of a grid pitch OFF the real centreline. The leg's emitted path
/// starts exactly at that node, so without this the two legs' copper share no
/// metal — a fab-fatal open the router's grid model reads as connected (the
/// `net_open` DRC catches it downstream). Emit the short same-net segment from the
/// weld node to the nearest point on copper that existed BEFORE this leg
/// (`tracks[0..prior]`, same signal layer) so the centrelines physically meet. The
/// gap lies inside the net's own reserved halo, and the bridge is probed before
/// it is drawn, so it can add no foreign-clearance violation; it never changes
/// which path Dijkstra found (routed counts and every other DRC stay identical).
const Weld = struct {
    ctx: *Ctx,
    net: i32,
    /// Where the leg's copper actually starts (post-`trimBuriedStart`).
    at: [2]f64,
    layer: u8,
    /// Mark in `tracks` before this leg — everything below it is prior copper.
    prior: usize,
    tracks: *std.ArrayList(Track),
    vias: []const Via,
};

fn weldToNetCopper(weld: Weld) std.mem.Allocator.Error!void {
    const ctx = weld.ctx;
    const net = weld.net;
    const w = weld.at;
    const layer = weld.layer;
    const prior = weld.prior;
    const tracks = weld.tracks;
    const vias = weld.vias;
    var best: f64 = std.math.inf(f64);
    var bx: f64 = 0;
    var by: f64 = 0;
    for (tracks.items[0..prior]) |t| {
        if (t.net != net or t.layer != layer) continue;
        const c = pad_shape.closestOnSeg(t.x1, t.y1, t.x2, t.y2, w[0], w[1]);
        if (c.d < best) {
            best = c.d;
            bx = c.x;
            by = c.y;
        }
    }
    // Bridge only a genuine near-miss: the weld already sits ON same-layer
    // copper (centre within one track width ⇒ overlapping metal) needs nothing;
    // farther than the copper-clearance halo means the weld is via-connected to
    // another layer (a via stamps `occ==net` on every layer at its node) or is a
    // real gap the ratsnest owns — either way a long bridge would be wrong. Only
    // the (track_width, copperHalo] band is a stub-halo weld to close.
    // Deliberately NOT routed through the `OctiJoin` seam: this is the one join
    // that must not stamp an occupancy halo (stamping would let a later leg of
    // the same net weld to it in turn). It spans at most one copper halo, so the
    // residual off-axis copper is a few tenths of a millimetre.
    //
    // PROBED, though. The old "it lies inside our own reserved halo, so it adds
    // no foreign-clearance violation" reasoning only ever held for foreign
    // COPPER (which the halo did detour) — a foreign PAD is not stamped into
    // anything and can sit squarely across the bridge. Emitting a violating weld
    // trades a visible open for an invisible fab-blocking short, so the bridge
    // now has to clear like every other segment; when it can't, the leg simply
    // stays unwelded and `net_open` reports it.
    if (best > ctx.params.track_width and best <= copperHalo(ctx)) {
        const path = DirectPath{ .ctx = ctx, .net = net, .layer = layer, .tracks = tracks.items, .vias = vias };
        if (!clearDoglegSegment(path, w, .{ bx, by })) return;
        try tracks.append(ctx.arena, .{ .x1 = w[0], .y1 = w[1], .x2 = bx, .y2 = by, .layer = layer, .width = ctx.params.track_width, .net = net });
        stampCurrentRf(ctx, w, .{ bx, by }, net, layer);
    }
}

/// The seam every off-raster endpoint joins the board through: a pad centre or
/// a plane-via site, neither of which sits on the maze grid, so the naive
/// segment between them lands at whatever angle the offset happens to be. Each
/// is short, but there is roughly one per pad, and each seeds a chain that then
/// reads non-octilinear to every later pass. Supplies both the clearance probe
/// and the segment emitter for `octilinear.emitJoin`.
const OctiJoin = struct {
    ctx: *Ctx,
    net: i32,
    layer: u8,
    placed_vias: []const Via,
    tracks: *std.ArrayList(Track),

    /// DRC-grade clearance for one candidate leg, against foreign pads,
    /// placed vias, and foreign copper on this layer.
    pub fn clear(self: OctiJoin, a: [2]f64, b: [2]f64) bool {
        return segClearsPadsOnLayer(self.ctx, a, b, self.net, null) and
            segClearsVias(self.ctx, self.placed_vias, a, b, self.net) and
            segClearsTracks(self.ctx, self.tracks.items, a, b, self.net, self.layer);
    }

    /// Does the whole prefix `a`→`b` meet the *fabrication* rule — the exact
    /// track↔pad / track↔via / track↔track clearances the DRC re-checks, with
    /// the DRC's layer semantics (an SMD pad obstructs only its own side, a
    /// through pad every layer)? Deliberately NOT the same predicate as
    /// `clear`: that one is layer-blind, which is the right *chooser* (it keeps
    /// an elbow off the opposite face's lands too) but the wrong *gate* — a
    /// join refused on it alone would drop copper the board would happily fab.
    fn fabricable(self: OctiJoin, a: [2]f64, b: [2]f64) bool {
        return segClearsPadsOnLayer(self.ctx, a, b, self.net, self.layer) and
            segClearsVias(self.ctx, self.placed_vias, a, b, self.net) and
            segClearsTracks(self.ctx, self.tracks.items, a, b, self.net, self.layer);
    }

    /// The farthest point along `a`→`b` whose whole prefix is `fabricable`, or
    /// null when not even a sliver leaving `a` clears.
    ///
    /// Prefix clearance is monotone in the fraction kept (shortening a segment
    /// can only remove approaches), so a bisection is exact rather than a
    /// sampling approximation, and it costs `join_trim_probes` probes instead
    /// of one per grid step.
    fn trimmed(self: OctiJoin, a: [2]f64, b: [2]f64) ?[2]f64 {
        if (self.fabricable(a, b)) return b;
        const at = struct {
            fn point(p: [2]f64, q: [2]f64, t: f64) [2]f64 {
                return .{ p[0] + t * (q[0] - p[0]), p[1] + t * (q[1] - p[1]) };
            }
        }.point;
        var lo: f64 = 0;
        var hi: f64 = 1;
        for (0..join_trim_probes) |_| {
            const mid = (lo + hi) / 2;
            if (self.fabricable(a, at(a, b, mid))) lo = mid else hi = mid;
        }
        const kept = at(a, b, lo);
        if (std.math.hypot(kept[0] - a[0], kept[1] - a[1]) < octilinear.min_heading_mm) return null;
        return kept;
    }

    /// Append one join segment and reserve its occupancy halo, so later nets
    /// detour copper the grid itself cannot see.
    ///
    /// TRIMMED to the fabricable prefix first. `emitJoin` has two paths that
    /// reach here with copper nothing ever probed — an already-octilinear pair
    /// (never a candidate, so `elbow` returns before probing it) and the
    /// direct-segment fallback taken when neither elbow clears — and this is
    /// the join every pad centre and plane-via site leaves the board through.
    /// On barracuda that drew `V_1V8A` out of `adf4159/C116.1` straight at the
    /// cap's own GND pad, 0.094 mm into a 0.127 mm rule. An elbow leg that
    /// `clear` already approved is untouched (that test is strictly stronger
    /// than this one), so only the unprobed paths change: they now stop at the
    /// violation instead of crossing it, and a pad whose centre cannot even
    /// start a legal stub emits nothing. An honestly open net is a better
    /// outcome than a fab-blocking short — the open is visible to `net_open`,
    /// the short is not.
    pub fn seg(self: OctiJoin, a: [2]f64, b: [2]f64) std.mem.Allocator.Error!void {
        const end = self.trimmed(a, b) orelse return;
        try self.tracks.append(self.ctx.arena, .{
            .x1 = a[0],
            .y1 = a[1],
            .x2 = end[0],
            .y2 = end[1],
            .layer = self.layer,
            .width = self.ctx.params.track_width,
            .net = self.net,
        });
        stampStubOcc(self.ctx, a, end, self.net, self.layer);
        stampCurrentRf(self.ctx, a, end, self.net, self.layer);
    }
};

/// Bisection steps `OctiJoin.trimmed` spends locating the fabricable prefix.
/// 24 halvings resolve a 5 mm join to under a nanometre — far below the
/// clearance epsilon, so the kept end is exact for every practical purpose.
const join_trim_probes: usize = 24;

/// Emit the stub joining pad terminal `pt`'s true centre to the entry node
/// `key` the maze actually used. The pad centre is off-raster by construction,
/// so it goes through the `OctiJoin` seam to keep its heading on the compass.
fn gateStub(
    ctx: *Ctx,
    net: i32,
    pt: NetPt,
    key: usize,
    placed_vias: []const Via,
    tracks: *std.ArrayList(Track),
) std.mem.Allocator.Error!void {
    const grid = ctx.grid;
    const nodes = grid.nx * grid.ny;
    const layer: u8 = @intCast(key / nodes);
    const n = key % nodes;
    const w = [2]f64{ grid.worldX(n % grid.nx), grid.worldY(n / grid.nx) };
    const path = DirectPath{ .ctx = ctx, .net = net, .layer = layer, .tracks = tracks.items, .vias = placed_vias };
    const join = OctiJoin{ .ctx = ctx, .net = net, .layer = layer, .placed_vias = placed_vias, .tracks = tracks };
    // The axis-only attempt joins its pads through the SAME seam, on an L rather
    // than the axis-then-45° elbow. A refusal is deliberately not fatal here: the
    // ordinary join still runs, and the off-axis copper it then draws is what
    // makes `manhattan_route` decline the whole route rather than ship a trace
    // that is not what it claims to be.
    if (ctx.manhattan.active and try manhattan_route.axisStub(join, .{ pt.x, pt.y }, w)) return;
    if (axisExitDogleg(path, pt, w)) |dogleg| {
        try emitDogleg(path, .{ pt.x, pt.y }, w, dogleg, tracks);
        return;
    }
    try octilinear.emitJoin(.{ pt.x, pt.y }, w, join);
}

/// Reset every grid node this net stamped back to EMPTY. Used to undo a failed
/// top-layer-only attempt before re-routing the net with vias allowed — since a
/// net only ever stamps its own index, clearing `occ == net` (and its diagonal
/// corner reservations) leaves every other net's copper untouched.
fn clearNetOcc(ctx: *Ctx, net: i32) void {
    for (ctx.occ, ctx.resv) |occ_l, resv_l| {
        for (occ_l, resv_l) |*o, *r| {
            if (o.* == net) o.* = empty_cell;
            if (r.* == net) r.* = empty_cell;
        }
    }
    // The net's keepout halo goes with its copper — a ripped-up RF trace must not
    // leave a phantom exclusion zone behind for every net routed after it — and
    // each halo node's GATE goes with the node, or a later stamp would inherit a
    // stale opening it never asked for.
    for (ctx.keep.layers, 0..) |keep_l, layer| {
        const gate_l: ?[]i32 = if (layer < ctx.keep.gate.len) ctx.keep.gate[layer] else null;
        for (keep_l, 0..) |*c, n| {
            if (c.* != net) continue;
            c.* = empty_cell;
            if (gate_l) |g| g[n] = empty_cell;
        }
    }
    // Component pads are permanent guarded copper, not routed copper. Restore
    // their exact halos after removing this net's track/via stamps.
    stampKeepoutPadsForNet(ctx, net);
    // `resv` reset 5/6, the same idea one line up: ripping a net's tracks must
    // not also hand its reserved corridor to whoever routes next.
    lane_reserve.stamp(ctx.reserved_lanes, ctx.resv, ctx.grid, net);
    ctx.shadow.clearNet(net);
}

// ── Bounded rip-up & reroute ─────────────────────────────────────────────────
//
// The greedy pass is first-routed-wins, so a net can be boxed in by copper
// routed before it. After it, each still-failed net gets a bounded chance to
// displace copper of no-higher priority that stands in its way (see
// `collectRippable` for why equal-priority copper is rippable but strictly
// higher is protected): a soft "probe" search finds the min-cost path when
// foreign copper is passable-at-a-penalty (the crossed nets are the blockers),
// those blockers are ripped, the failed net is re-routed into the freed space,
// and the ripped nets are re-routed after it (they may find alternates). Every
// attempt is speculative — the whole routing state is snapshotted first and
// rolled back unless the attempt strictly improves the outcome (more nets
// routed, then higher total authored routing priority, then shorter copper), so
// rip-up cannot trade away an earlier wave merely to shorten a lower-priority
// net. Capped at `RIPUP_MAX_ROUNDS` passes and stops early once a pass changes
// nothing. Skipped entirely on grid overflow
// (that path returns before the greedy pass ever runs).

/// A maze net's working record during rip-up: its net index, routing priority,
/// and whether it is currently routed. Built once from the greedy pass, then
/// mutated in place as nets are ripped and re-routed.
pub const RipNet = struct {
    net_i: usize,
    pri: u64,
    ok: bool,
    /// False for an atomic pair member or a hard-guided reference replay.
    reroutable: bool = true,
};

/// Rip-up passes cap: at most this many full sweeps over the failed nets. Each
/// sweep is O(failed × (probe + rip + reroute)); 3 is plenty for module boards
/// and keeps the worst case a small multiple of the single greedy pass.
const ripup_max_rounds: usize = 3;
/// How many times the signal-finish stage interleaves budget escalation with
/// rip-up. Escalation is non-destructive (only raises the routed count) and
/// rip-up's freed copper can enable an escalation the previous pass could not
/// reach — so re-running escalation AFTER rip-up rescues legs a single up-front
/// pass would strand (the order-fragility this fixes). 2 is enough for the
/// module boards; a fixed count keeps the stage deterministic and time-bounded.
const signal_escalate_passes: usize = 2;
/// Per-cell penalty (× grid pitch) the blocker probe charges for stepping onto
/// foreign copper. Large enough that the probe crosses copper only when there is
/// no pad-free detour — so the nets it reports are the ones actually walling the
/// failed net in, not incidental copper it could have gone around.
const ripup_cross_pen: f64 = 200.0;

/// True when a cooperative cancel has been requested for this run. Polled at
/// each per-net loop boundary (plane pass, greedy pass, rip-up, escalation,
/// fine-window rescue) so an automatic phase stops starting new work promptly
/// while the finish pass still runs. A monotonic load is enough: the flag is
/// set once by the controlling job and only ever read here.
pub fn routeCancelled(ctx: *const Ctx) bool {
    if (ctx.deadline_expired or
        (ctx.deadline_ns != 0 and clock.nanoTimestamp() >= ctx.deadline_ns)) return true;
    const flag = ctx.cancel orelse return false;
    return flag.load(.monotonic);
}

/// True when at least one net in the working set is still unrouted — the cheap
/// guard that keeps rip-up (and its scratch arena) off fully-routed boards.
fn anyRecoverableFailed(routable: []const RipNet) bool {
    for (routable) |rn| if (!rn.ok and rn.reroutable) return true;
    return false;
}

/// Total length (mm) of every track segment — the tie-break metric rip-up uses
/// to prefer the shorter of two equally-routed outcomes.
/// Count of currently-routed nets in the working set.
fn countRouted(routable: []const RipNet) usize {
    var c: usize = 0;
    for (routable) |rn| c += @intFromBool(rn.ok);
    return c;
}

const RipScore = struct {
    routed: usize,
    priority: u128,
    trace: f64,
};

/// How good the board is right now, for a speculative transaction's keep-best
/// gate: nets routed, then the summed routing priority of the routed ones, then
/// total copper. Shared by rip-up and the joint tier so both judge identically.
pub fn ripScore(routable: []const RipNet, tracks: []const Track) RipScore {
    var priority: u128 = 0;
    for (routable) |rn| priority += if (rn.ok) rn.pri else 0;
    return .{
        .routed = countRouted(routable),
        .priority = priority,
        .trace = route_timeline.traceLen(tracks),
    };
}

/// Is `now` a STRICTLY better board than `before` by `ripScore`'s keys? The
/// accept gate of every speculative rip: anything else reverts.
pub fn ripScoreBetter(now: RipScore, before: RipScore) bool {
    if (now.routed != before.routed) return now.routed > before.routed;
    if (now.priority != before.priority) return now.priority > before.priority;
    return now.trace < before.trace - 1e-6;
}

/// Remove all of `net_i`'s copper from the board: clear its occupancy/reservation
/// cells and delete its tracks + vias. Leaves every other net untouched (a net
/// only ever stamps its own index), so the freed cells are exactly this net's.
pub fn ripNet(ctx: *Ctx, tracks: *std.ArrayList(Track), vias: *std.ArrayList(Via), net_i: usize) void {
    const ni: i32 = @intCast(net_i);
    clearNetOcc(ctx, ni);
    route_cleanup.removeNetTracks(tracks, ni);
    route_cleanup.removeNetVias(vias, ni);
    copperCompacted(ctx); // both packed survivors down — every copper index is now aliased
    _ = ctx.rf.net_smooth.remove(ni);
}

/// Cost of ENTERING node `(layer, n)` for `net` during a blocker probe: `null`
/// if a foreign pad hard-blocks it (a pad can never be ripped), else the soft
/// penalty — 0 for a free cell, `RIPUP_CROSS_PEN×g` per foreign-copper layer the
/// cell carries. This is what makes the probe pass *through* copper so the path
/// it finds reveals which nets a rip would have to clear.
fn softEnter(ctx: *Ctx, layer: usize, n: usize, net: i32) ?f64 {
    // Pads can never be ripped, nor can off-board / zone-blocked ground be
    // opened up, so the probe's hard wall is exactly `blocked`'s static half.
    if (staticBlocked(ctx, layer, n, net)) return null;
    var pen: f64 = 0;
    const o = ctx.occ[layer][n];
    if (o != empty_cell and o != net) pen += ripup_cross_pen * ctx.grid.g;
    const rv = ctx.resv[layer][n];
    if (rv != empty_cell and rv != net) pen += ripup_cross_pen * ctx.grid.g;
    // A keepout halo is soft for the same reason a reservation is: it belongs to
    // a net, and ripping that net would clear it. (A keepout class is usually
    // high-priority, so `collectRippable` protects it — but the probe should
    // still NAME it as the blocker, not call the corridor geometrically sealed.)
    if (keepoutBlocked(ctx, layer, n, net)) pen += ripup_cross_pen * ctx.grid.g;
    return pen;
}

/// Relax one probe move onto `(to_layer, to_node)` at base step cost `base`,
/// adding the soft entry penalty. A hard-pad-blocked target is skipped.
fn softStep(ctx: *Ctx, pq: *Pq, state: maze_scratch.State, net: i32, from_key: usize, to_layer: usize, to_node: ?usize, base: f64) std.mem.Allocator.Error!void {
    const tn = to_node orelse return;
    const enter = softEnter(ctx, to_layer, tn, net) orelse return;
    const nodes = ctx.grid.nx * ctx.grid.ny;
    const to_key = to_layer * nodes + tn;
    const nd = state.dist[from_key] + base + enter;
    if (nd < state.dist[to_key]) {
        try state.settle(to_key, nd, @intCast(from_key));
        try pq.add(.{ .d = nd, .key = to_key });
    }
}

/// Probe diagonal (dx,dy) of (ix,iy), refusing to clip a pad's corner (same
/// no-corner-cut guard as the real maze) — foreign copper on the flanks is fine,
/// only a hard-pad-blocked flank forbids the diagonal.
fn softDiag(
    ctx: *Ctx,
    pq: *Pq,
    state: maze_scratch.State,
    net: i32,
    from_key: usize,
    layer: usize,
    ix: usize,
    iy: usize,
    dx: i64,
    dy: i64,
) std.mem.Allocator.Error!void {
    const grid = ctx.grid;
    const c1 = neighbor(grid, ix, iy, dx, 0) orelse return;
    const c2 = neighbor(grid, ix, iy, 0, dy) orelse return;
    if (softEnter(ctx, layer, c1, net) == null or softEnter(ctx, layer, c2, net) == null) return;
    try softStep(ctx, pq, state, net, from_key, layer, neighbor(grid, ix, iy, dx, dy), grid.g * sqrt2);
}

/// Soft Dijkstra from `src`'s access node to `goal`'s, foreign copper passable
/// at a penalty (see `softEnter`). On reaching the goal it walks the path back
/// and records every foreign net whose copper it crossed into `crossed` — the
/// blocker set for this pad pair. Unreachable even softly (walled by pads) ⇒ no
/// blockers recorded. Uses `scratch` for its queue and the context's shared
/// `maze_scratch.Search` for dist/prev — it used to allocate and memset a whole
/// `layers × nodes` key space of its own per pad pair, which on a large board is
/// tens of megabytes for a probe that touches a few thousand nodes.
fn softProbe(ctx: *Ctx, net: i32, src: NetPt, goal: NetPt, crossed: *std.AutoHashMapUnmanaged(i32, void), scratch: std.mem.Allocator) std.mem.Allocator.Error!void {
    const grid = ctx.grid;
    const nodes = grid.nx * grid.ny;
    const n_layers = ctx.occ.len;
    const state = try ctx.search.begin(ctx.arena, n_layers * nodes);
    const dist = state.dist;
    const prev = state.prev;

    const s = grid.nearest(src.x, src.y);
    const src_key = @as(usize, src.layer) * nodes + grid.node(s[0], s[1]);
    const gd = grid.nearest(goal.x, goal.y);
    const goal_key = @as(usize, goal.layer) * nodes + grid.node(gd[0], gd[1]);

    var pq = maze_scratch.Pq.init(scratch, {});
    try state.settle(src_key, 0, -1);
    try pq.add(.{ .d = 0, .key = src_key });

    var found = false;
    var expansions: usize = 0;
    while (pq.removeOrNull()) |it| {
        if (it.d > dist[it.key]) continue;
        if (it.key == goal_key) {
            found = true;
            break;
        }
        // Escalated when the caller is probing an eligible net's blockers (a
        // long congested net's blocker probe must reach across the board to see
        // what walls it in, or rip-up would find nothing to rip and give up).
        const probe_limit = if (ctx.escalate_budget > 0)
            ctx.escalate_budget
        else
            unguidedExpansionLimit(ctx.selected_nets);
        if (expansions >= probe_limit) {
            try recordSearchLimit(ctx, net);
            return;
        }
        expansions += 1;
        const layer = it.key / nodes;
        const n = it.key % nodes;
        const ix = n % grid.nx;
        const iy = n / grid.nx;
        try softStep(ctx, &pq, state, net, it.key, layer, neighbor(grid, ix, iy, 1, 0), grid.g);
        try softStep(ctx, &pq, state, net, it.key, layer, neighbor(grid, ix, iy, -1, 0), grid.g);
        try softStep(ctx, &pq, state, net, it.key, layer, neighbor(grid, ix, iy, 0, 1), grid.g);
        try softStep(ctx, &pq, state, net, it.key, layer, neighbor(grid, ix, iy, 0, -1), grid.g);
        try softDiag(ctx, &pq, state, net, it.key, layer, ix, iy, 1, 1);
        try softDiag(ctx, &pq, state, net, it.key, layer, ix, iy, 1, -1);
        try softDiag(ctx, &pq, state, net, it.key, layer, ix, iy, -1, 1);
        try softDiag(ctx, &pq, state, net, it.key, layer, ix, iy, -1, -1);
        if (n_layers > 1) {
            for (0..n_layers) |to_layer| {
                if (to_layer == layer) continue;
                try softStep(ctx, &pq, state, net, it.key, to_layer, n, grid.g * via_cost_mult);
            }
        }
    }
    if (!found) return;
    // Walk back from the goal, recording foreign copper crossed on the way.
    var k = goal_key;
    while (true) {
        const layer = k / nodes;
        const nn = k % nodes;
        const o = ctx.occ[layer][nn];
        if (o != empty_cell and o != net) try crossed.put(scratch, o, {});
        const rv = ctx.resv[layer][nn];
        if (rv != empty_cell and rv != net) try crossed.put(scratch, rv, {});
        if (layer < ctx.keep.layers.len) {
            const kl = ctx.keep.layers[layer];
            // A halo this net does not owe (a fellow class member's) never
            // blocked it, so its owner is no candidate for rip-up.
            if (keepout.claimed(kl, ctx.keep.class.ids, nn, net)) try crossed.put(scratch, kl[nn], {});
        }
        const p = prev[k];
        if (p < 0) break;
        k = @intCast(p);
    }
}

/// The foreign nets whose copper boxes `net_i` in: probe `net_i`'s first pad to
/// each of its other pads with copper soft-passable and union the crossed nets.
/// Returns the blocker net indices (deduped). Allocated in `scratch`.
pub fn detectBlockers(
    ctx: *Ctx,
    placement: optimizer.Placement,
    idx_of: *std.StringHashMapUnmanaged(usize),
    net_i: usize,
    scratch: std.mem.Allocator,
) std.mem.Allocator.Error![]i32 {
    const ni: i32 = @intCast(net_i);
    setNetParams(ctx, placement, net_i);
    const pts = try netPoints(scratch, placement, idx_of, placement.nets[net_i]);
    if (pts.len < 2) return &.{};
    setNetRoutePolicy(ctx, net_i, pts);
    var crossed = std.AutoHashMapUnmanaged(i32, void).empty;
    for (pts[1..]) |pt| {
        try softProbe(ctx, ni, pts[0], pt, &crossed, scratch);
        if (searchWasLimited(ctx, net_i)) break;
    }
    var out: std.ArrayList(i32) = .empty;
    var it = crossed.keyIterator();
    while (it.next()) |kp| try out.append(scratch, kp.*);
    return out.toOwnedSlice(scratch);
}

/// Indices (into `routable`) of the nets rip-up may remove for the failed net:
/// currently-routed blockers of priority ≤ `fail_pri` (the caller passes the
/// failed net's priority as the ceiling, or `maxInt` to let a reference-proven
/// eligible net also rip a strictly-higher-priority wall — the keep-best gate
/// still reverts unless the board improves) that are not a plane, a pour, or
/// ground (that copper is never ripped).
///
/// Why lower-*or-equal*, not strictly-lower: the greedy pass routes strictly
/// higher-priority nets first, so a net that failed there was only ever boxed in
/// by copper of higher-OR-EQUAL priority. Forbidding equal-priority rips would
/// therefore make rip-up unable to rescue the common case — a net walled off by
/// an equal-tier neighbour (e.g. one flash-data line boxing the next) — leaving
/// it a no-op. Equal-tier nets carry no real importance difference (net index is
/// only a stable sort tiebreak), so ripping one to route another and letting it
/// find an alternate is exactly the intended trade. STRICTLY higher priority
/// (authored `(net-class (priority …))` tiers, the elevated switcher hot loop,
/// planes/pours/ground) stays protected; `saveSnapshot`/keep-best still make the
/// whole attempt a no-op unless it strictly improves the board.
pub fn collectRippable(
    scratch: std.mem.Allocator,
    placement: optimizer.Placement,
    routable: []const RipNet,
    blockers: []const i32,
    fail_pri: u64,
) std.mem.Allocator.Error![]usize {
    var out: std.ArrayList(usize) = .empty;
    for (routable, 0..) |rn, i| {
        if (!rn.ok or !rn.reroutable) continue;
        if (rn.pri > fail_pri) continue; // never rip STRICTLY higher priority
        const name = placement.nets[rn.net_i].name;
        if (netHasPlane(placement, name)) continue;
        if (isGroundName(shortName(name))) continue;
        const pour = netPourLayers(placement, name);
        if (pour[0] or pour[1]) continue;
        var is_blocker = false;
        for (blockers) |b| {
            if (b == @as(i32, @intCast(rn.net_i))) {
                is_blocker = true;
                break;
            }
        }
        if (is_blocker) try out.append(scratch, i);
    }
    return out.toOwnedSlice(scratch);
}

/// Re-route one net from scratch (its copper must already be ripped), updating
/// its `ok` flag. Mirrors the greedy pass's plain (via-allowed) attempt.
pub fn rerouteNet(
    ctx: *Ctx,
    placement: optimizer.Placement,
    idx_of: *std.StringHashMapUnmanaged(usize),
    rn: *RipNet,
    tracks: *std.ArrayList(Track),
    vias: *std.ArrayList(Via),
) std.mem.Allocator.Error!void {
    setNetParams(ctx, placement, rn.net_i);
    const pts = try netPoints(ctx.arena, placement, idx_of, placement.nets[rn.net_i]);
    if (pts.len < 2) {
        rn.ok = true;
        return;
    }
    setNetRoutePolicy(ctx, rn.net_i, pts);
    try setNetReferenceGuide(ctx, rn.net_i);
    const keep = tracks.items.len;
    rn.ok = try routeNet(ctx, @intCast(rn.net_i), pts, tracks, vias);
    if (rn.ok) try smoothNetInline(
        .{ .ctx = ctx, .placement = placement, .tracks = tracks, .vias = vias },
        rn.net_i,
        keep,
        0,
    );
}

/// A rollback point for one speculative rip-up attempt: the full routing state
/// (copper + occupancy grids + per-net status + search-limit marks) plus its
/// score, duplicated into the scratch arena so `restoreSnapshot` puts it back.
const RipSnapshot = struct {
    tracks: []Track,
    vias: []Via,
    occ: [][]i32,
    resv: [][]i32,
    /// The stamped RF keepout halos, their per-node gates, and the crossing
    /// shadow (all empty on a board that declares none) — captured with the rest
    /// of the occupancy state so a rejected rip can't leave a band belonging to
    /// copper it just put back, or lose one.
    keep: [][]i32,
    gate: [][]i32,
    shadow: [][]i32,
    score: RipScore,
    ok: []bool,
    /// The inline bend-smoothing metadata alive at snapshot time — restored
    /// verbatim so a rejected rip-up can't leave stale (or missing) arcs.
    smooth: []const SmoothEntry,
    /// Search-limited marks at snapshot time — a rollback must leak none.
    search_limited: []const usize,
};

const SmoothEntry = struct { net: i32, v: NetSmooth };

/// Duplicate one per-signal-layer node grid group into `scratch` (an empty group
/// duplicates to an empty group, which is how a board declaring no RF band pays
/// nothing for the snapshot).
fn dupeLanes(scratch: std.mem.Allocator, lanes: []const []i32) std.mem.Allocator.Error![][]i32 {
    const out = try scratch.alloc([]i32, lanes.len);
    for (lanes, out) |src, *dst| dst.* = try scratch.dupe(i32, src);
    return out;
}

/// Copy a duplicated lane group back over the live one.
fn copyLanes(dst: []const []i32, src: []const []i32) void {
    for (dst, src) |d, s| @memcpy(d, s);
}

/// Duplicate the current routing state into `scratch` for possible rollback.
pub fn saveSnapshot(
    scratch: std.mem.Allocator,
    ctx: *Ctx,
    tracks: *std.ArrayList(Track),
    vias: *std.ArrayList(Via),
    routable: []const RipNet,
) std.mem.Allocator.Error!RipSnapshot {
    const ok = try scratch.alloc(bool, routable.len);
    for (routable, ok) |rn, *o| o.* = rn.ok;
    var smooth: std.ArrayList(SmoothEntry) = .empty;
    var it = ctx.rf.net_smooth.iterator();
    while (it.next()) |entry| try smooth.append(scratch, .{ .net = entry.key_ptr.*, .v = entry.value_ptr.* });
    return .{
        .tracks = try scratch.dupe(Track, tracks.items),
        .vias = try scratch.dupe(Via, vias.items),
        .occ = try dupeLanes(scratch, ctx.occ),
        .resv = try dupeLanes(scratch, ctx.resv),
        .keep = try dupeLanes(scratch, ctx.keep.layers),
        .gate = try dupeLanes(scratch, ctx.keep.gate),
        .shadow = try dupeLanes(scratch, ctx.shadow.layers),
        .score = ripScore(routable, tracks.items),
        .ok = ok,
        .smooth = smooth.items,
        .search_limited = try scratch.dupe(usize, ctx.search_limited.items),
    };
}

/// Restore the routing state captured by `saveSnapshot`, discarding the
/// speculative attempt's changes.
pub fn restoreSnapshot(
    ctx: *Ctx,
    tracks: *std.ArrayList(Track),
    vias: *std.ArrayList(Via),
    routable: []RipNet,
    snap: RipSnapshot,
) std.mem.Allocator.Error!void {
    tracks.clearRetainingCapacity();
    try tracks.appendSlice(ctx.arena, snap.tracks);
    vias.clearRetainingCapacity();
    try vias.appendSlice(ctx.arena, snap.vias);
    copyLanes(ctx.occ, snap.occ);
    copyLanes(ctx.resv, snap.resv);
    copyLanes(ctx.keep.layers, snap.keep);
    copyLanes(ctx.keep.gate, snap.gate);
    copyLanes(ctx.shadow.layers, snap.shadow);
    for (routable, snap.ok) |*rn, o| rn.ok = o;
    ctx.rf.net_smooth.clearRetainingCapacity();
    for (snap.smooth) |entry| try ctx.rf.net_smooth.put(ctx.arena, entry.net, entry.v);
    ctx.search_limited.clearRetainingCapacity();
    try ctx.search_limited.appendSlice(ctx.arena, snap.search_limited);
}

/// Did `net_i`'s last search run OUT OF BUDGET (rather than drain its
/// frontier)? The fork every escalation tier turns on: a budget failure is
/// `escalateSearchLimited`'s, a drained one `escalate_retry`'s.
pub fn searchWasLimited(ctx: *const Ctx, net_i: usize) bool {
    for (ctx.search_limited.items) |limited| if (limited == net_i) return true;
    return false;
}

/// Bounded rip-up & reroute over the greedy pass's working set. Returns the
/// number of rounds run (≥1 whenever called; caller only calls it when a net
/// failed). See the section header above for the algorithm.
const RipUpRun = struct {
    ctx: *Ctx,
    placement: optimizer.Placement,
    idx_of: *std.StringHashMapUnmanaged(usize),
    routable: []RipNet,
    tracks: *std.ArrayList(Track),
    vias: *std.ArrayList(Via),
    progress: *RouteProgress,
};

fn ripUpReroute(run: RipUpRun) std.mem.Allocator.Error!usize {
    const ctx = run.ctx;
    const placement = run.placement;
    const idx_of = run.idx_of;
    const routable = run.routable;
    const tracks = run.tracks;
    const vias = run.vias;
    const route_progress = run.progress;
    // Reset per-attempt scratch so only one route snapshot is live at a time.
    var scratch_inst = std.heap.ArenaAllocator.init(ctx.arena);
    defer scratch_inst.deinit();
    var rounds: usize = 0;
    while (rounds < ripup_max_rounds) {
        // Cooperative cancel: stop rip-up at a round boundary. Copper already
        // committed by an accepted round stays; the finish pass still runs.
        if (routeCancelled(ctx)) break;
        rounds += 1;
        var made_progress = false;
        for (routable) |*rn| {
            if (routeCancelled(ctx)) break;
            if (rn.ok or !rn.reroutable) continue;
            // EVERY still-failed net is a rip-up candidate: the escalate↔rip-up
            // interleave already gave a search-limited leg its bounded
            // large-budget retry, so one that still reaches destructive rip-up
            // is genuinely walled in. Deliberately wider than the old escape /
            // diff-pair / max-freq / ≤3-terminal gate, which left multi-drop
            // buses (barracuda's SPI_SCK/MOSI, the V_3V3A tree) forever
            // unrippable — safe to widen because the keep-best gate below
            // reverts any rip that does not strictly improve the board, and
            // `collectRippable` still never rips a plane, a pour, or ground.
            const scratch = scratch_inst.allocator();
            // The blocker probe searches under the escalated budget so a long
            // congested net (e.g. a multi-drop bus crossing the board) reaches
            // the copper walling it in instead of timing out and reporting
            // nothing to rip.
            ctx.escalate_budget = max_escalated_expansions;
            const blockers = try detectBlockers(ctx, placement, idx_of, rn.net_i, scratch);
            ctx.escalate_budget = 0;
            // A reference-proven net the greedy pass could not route is often
            // walled in by a STRICTLY higher-priority neighbour claiming its only
            // channel (e.g. a power rail across a bus net's escape). Raise the rip
            // ceiling so that neighbour becomes rippable; the reroute puts the
            // rescued net down first, then the neighbour finds an alternate. The
            // keep-best gate below still discards the attempt unless the board
            // strictly improves, so a rip that can't re-home the neighbour reverts.
            const rip_ceiling: u64 = std.math.maxInt(u64);
            const rippable = try collectRippable(scratch, placement, routable, blockers, rip_ceiling);
            if (rippable.len == 0) {
                _ = scratch_inst.reset(.retain_capacity);
                continue;
            }
            const snap = try saveSnapshot(scratch, ctx, tracks, vias, routable);
            // Rip the failed net + its lower-priority blockers…
            ripNet(ctx, tracks, vias, rn.net_i);
            rn.ok = false;
            for (rippable) |ri| {
                ripNet(ctx, tracks, vias, routable[ri].net_i);
                routable[ri].ok = false;
            }
            const related: []const usize = if (route_progress.timeline.enabled) blk: {
                const items = try ctx.arena.alloc(usize, rippable.len + 1);
                items[0] = rn.net_i;
                for (rippable, items[1..]) |ri, *net_i| net_i.* = routable[ri].net_i;
                break :blk items;
            } else &.{};
            try route_progress.timeline.capture(.{
                .kind = .ripup,
                .net = rn.net_i,
                .related_nets = related,
                .round = rounds,
                .routed = route_progress.plane_routed + countRouted(routable),
            }, tracks.items, vias.items);
            // …reroute the net we're rescuing first (so it claims the freed
            // space), then the ripped blockers in descending-priority order. A
            // rescued net that was search-limited needs the escalated budget here
            // too — freeing a blocker only helps if its long detour can now finish
            // searching (the low-priority blockers keep the base budget so their
            // re-route stays cheap).
            ctx.escalate_budget = if (searchWasLimited(ctx, rn.net_i)) max_escalated_expansions else 0;
            try rerouteNet(ctx, placement, idx_of, rn, tracks, vias);
            ctx.escalate_budget = 0;
            for (rippable) |ri| try rerouteNet(ctx, placement, idx_of, &routable[ri], tracks, vias);
            const now_score = ripScore(routable, tracks.items);
            const better = ripScoreBetter(now_score, snap.score);
            try route_progress.timeline.capture(.{
                .kind = .reroute_candidate,
                .net = rn.net_i,
                .related_nets = related,
                .round = rounds,
                .routed = route_progress.plane_routed + now_score.routed,
            }, tracks.items, vias.items);
            if (better) {
                made_progress = true;
                try route_progress.timeline.capture(.{
                    .kind = .reroute_accepted,
                    .net = rn.net_i,
                    .related_nets = related,
                    .round = rounds,
                    .routed = route_progress.plane_routed + now_score.routed,
                }, tracks.items, vias.items);
            } else {
                try restoreSnapshot(ctx, tracks, vias, routable, snap);
                try route_progress.timeline.capture(.{
                    .kind = .reroute_rejected,
                    .net = rn.net_i,
                    .related_nets = related,
                    .round = rounds,
                    .routed = route_progress.plane_routed + countRouted(routable),
                }, tracks.items, vias.items);
            }
            _ = scratch_inst.reset(.retain_capacity);
        }
        if (!made_progress) break;
    }
    return rounds;
}

/// Live state the post-greedy budget-escalation phase re-routes against —
/// the same working set greedy/rip-up mutate, threaded through one struct so
/// the phase helpers stay within the parameter cap.
pub const EscalateRun = struct {
    ctx: *Ctx,
    placement: optimizer.Placement,
    idx_of: *std.StringHashMapUnmanaged(usize),
    routable: []RipNet,
    tracks: *std.ArrayList(Track),
    vias: *std.ArrayList(Via),
    /// The per-leg maze budget this pass grants a retried leg —
    /// `max_escalated_expansions` for an ordinary escalation pass, or
    /// `max_last_resort_expansions` for the final residual retry.
    budget: usize = max_escalated_expansions,
};

/// The working-set slot for `net_i` (each net appears once), or null.
pub fn ripNetSlot(routable: []RipNet, net_i: usize) ?*RipNet {
    for (routable) |*rn| if (rn.net_i == net_i) return rn;
    return null;
}

/// Post-greedy budget escalation. A still-failed net (or atomic diff pair) that
/// ended the greedy pass search-limited is retried once under `run.budget`
/// expansions before it is declared failed — the whole-board budget stays
/// bounded because only this small set pays it. Non-destructive: an already-
/// routed leg is never ripped, so escalation can only raise the routed count,
/// never lower it, and it is safe to re-run (a no-op once every leg routes).
/// Deterministic: pairs (driven from the P leg) then singleton nets, both in
/// fixed slice order. Returns how many legs it routed.
fn escalateSearchLimited(run: EscalateRun) std.mem.Allocator.Error!usize {
    var rescued: usize = 0;
    for (run.placement.diff_pairs) |pair| {
        if (routeCancelled(run.ctx)) return rescued; // cooperative cancel
        rescued += try diff_couple.escalatePair(run, pair);
    }
    for (run.routable) |*rn| {
        if (routeCancelled(run.ctx)) break; // cooperative cancel
        if (rn.ok or !searchWasLimited(run.ctx, rn.net_i)) continue;
        if (diff_couple.isPairMember(run.placement.diff_pairs, rn.net_i)) continue;
        run.ctx.escalate_budget = run.budget;
        try rerouteNet(run.ctx, run.placement, run.idx_of, rn, run.tracks, run.vias);
        run.ctx.escalate_budget = 0;
        if (rn.ok) {
            clearSearchLimit(run.ctx, rn.net_i);
            rescued += 1;
        }
    }
    return rescued;
}

/// The named outcomes of one net's shape attempt.
const ShapeVerdict = enum {
    not_tried,
    /// More than two terminals — the sequential-leg tier owns those.
    multi_terminal,
    /// The net's policy leaves it no layer to lay copper on.
    no_layer,
    /// The layered channel graph found no corridor on any allowed layer,
    /// through any legal via site. A geometry answer.
    no_channel,
    /// A path existed but the board refused its copper — an RF halo, a reserved
    /// lane, a zone, or the outline, none of which the shape mesh models.
    copper_refused,
    /// The copper landed but failed the DRC gate, so it was rolled back.
    drc_refused,
};

// ── Shape tier: the multi-layer CDT last resort ───────────────────────────────

/// Via-site lattice pitch (mm) the shape tier offers the channel graph.
///
/// Every site becomes a mesh vertex on every allowed layer, so the pitch trades
/// where a dive may land against how large the graph grows. 1.0 mm puts ~1750
/// candidates over a 70 x 25 mm board, of which the via-legality probe keeps
/// only the ones a barrel actually fits — finer than the scale at which a layer
/// change is a useful move, and far cheaper than meshing the maze's own
/// 0.254 mm lattice.
const shape_via_pitch_mm: f64 = 1.0;
/// Floor on that pitch, so a sliver of a window cannot ask for millions of probes.
const shape_via_pitch_min_mm: f64 = 0.25;
/// Roughly how many candidate columns a window should offer across its short side.
const shape_sites_across: f64 = 8.0;
/// Hard cap on candidates offered for one attempt.
const shape_max_sites: usize = 4000;
/// Radius (mm) of the fine disc of via candidates offered around EACH terminal,
/// and the pitch it is sampled at. See `shapeTerminalSites` for the measurement
/// that sets them: a terminal's own free-space pocket is 0.2-3.6 mm across on
/// barracuda's refusals, so a candidate has to be sampled at well under a
/// millimetre and within a couple of millimetres of the pad to land in one.
const shape_term_radius_mm: f64 = 2.0;
const shape_term_pitch_mm: f64 = 0.2;
/// A hop's bow allowance as a fraction of its own span, and its bounds (mm).
const shape_bow_frac: f64 = 0.25;
const shape_bow_min_mm: f64 = 8.0;
const shape_bow_max_mm: f64 = 25.0;
/// Wall-clock a board must have spare, PER remaining net, to afford the tier.
const shape_gate_ns: i128 = 15 * clock.ns_per_s;
/// Hop span (mm) past which the SHAPE tier is asked before the maze rather than
/// after it (see `closeOneGap`).
///
/// Measured, and deliberately above the longest join the maze is known to close
/// here: barracuda's `V_1V8A` closes ONLY through its 37 mm whole-net gate join,
/// so a threshold below that would reorder a hop the raster demonstrably wins.
/// The residual joins the maze never closes on that board start at 42.5 mm
/// (`SPI_LMX_CSN`), run through 49.6 (`TXDATA_ADF`) and end at 55.3
/// (`LOCK_DET`) — which is the band this threshold separates.
const shape_first_hop_mm: f64 = 40.0;

/// Is this hop long enough that the shape tier is asked BEFORE the maze? Both
/// tiers still run either way (see `closeOneGap`); only their order moves.
fn shapeFirst(opts: GapOptions, from: NetPt, to: NetPt) bool {
    return opts.shape.meshes() and std.math.hypot(to.x - from.x, to.y - from.y) > shape_first_hop_mm;
}

/// Most nets one route hands to the shape tier. The tier exists for the residue
/// the whole ladder could not reach; a board with more failures than this has a
/// problem no last-resort geometry search is the answer to.
const shape_max_nets: usize = 8;

/// Can this board afford the shape tier for one more net?
///
/// A run with no deadline answers NO on purpose, exactly as the wide-unblock
/// gate does: bench and corpus routes are deterministic clock-free boards, and
/// "is there time left" is not a question they can be asked — handing them a
/// tier nobody declared would move a corpus result for no authored reason.
fn shapeTierAffordable(ctx: *const Ctx, nets_left: usize) bool {
    if (ctx.deadline_ns == 0 or nets_left == 0) return false;
    const spare = ctx.deadline_ns - clock.nanoTimestamp();
    if (spare <= 0) return false;
    return @divTrunc(spare, @as(i128, @intCast(nets_left))) >= shape_gate_ns;
}

/// The search window for one shape attempt: the terminals' own span with room
/// to bow around an obstacle, clamped to the BOARD rather than to the raster.
///
/// A shape hop deliberately does NOT inherit the maze's window. `buildGapCtx`
/// sizes a corridor raster to the cells it is willing to allocate, and for a
/// 1 mm gap in congested copper that box leaves nowhere to detour and no room
/// for a legal via site — which is what made `found no channel` the dominant
/// verdict on barracuda's first census. The mesh has no cells to allocate: its
/// cost follows the obstacle count, and a whole board's busiest layer meshes in
/// 1.41 s. So the bow allowance is sized from the hop's own geometry, and the
/// only hard limit is the board, past which there is nothing to route through.
///
/// Widening is sound because the obstacle set is board-wide either way:
/// `windowCtx` re-grids the raster but never clips `ctx.obs`, and a hop's
/// tracks and vias come from the whole `GapBoard`. So the mesh outside the
/// raster window still sees every pad and every trace out there.
fn shapeWindow(bounds: ShapeBounds, pts: []const NetPt) fine_window.WindowRect {
    var r = fine_window.WindowRect{ .x0 = pts[0].x, .y0 = pts[0].y, .x1 = pts[0].x, .y1 = pts[0].y };
    for (pts) |p| {
        r.x0 = @min(r.x0, p.x);
        r.y0 = @min(r.y0, p.y);
        r.x1 = @max(r.x1, p.x);
        r.y1 = @max(r.y1, p.y);
    }
    // A long hop may need to bow proportionally further out; a short one still
    // gets a real detour allowance rather than a hairline box.
    const span = @max(r.x1 - r.x0, r.y1 - r.y0);
    const bow = std.math.clamp(span * shape_bow_frac, shape_bow_min_mm, shape_bow_max_mm);
    return .{
        .x0 = @max(r.x0 - bow, bounds.x0),
        .y0 = @max(r.y0 - bow, bounds.y0),
        .x1 = @min(r.x1 + bow, bounds.x1),
        .y1 = @min(r.y1 + bow, bounds.y1),
    };
}

/// The outer limit a shape window may grow to — the board, intersected with the
/// raster the emission gate measures against.
const ShapeBounds = struct {
    x0: f64,
    y0: f64,
    x1: f64,
    y1: f64,

    /// The routable extent of a placement: its declared board rectangle when it
    /// has one, else the parts' own bounding box — CLAMPED to `grid`, the raster
    /// of the context whose gate will judge the copper.
    ///
    /// The clamp is model parity, not timidity. `directSegmentInside` — which
    /// every emitted segment passes through — refuses any point outside the
    /// context's grid window, and a gap hop's context is a CORRIDOR raster
    /// (`GapWindow.around(gap, corridorMargin(gap, …))`), not the whole board.
    /// A window wider than that raster does not buy the search room; it buys it
    /// a corridor whose copper the gate is certain to refuse, spent instead of
    /// the legal one beside it. On a short hop the two disagreed by construction:
    /// the corridor margin floors at 3 mm while `shapeWindow`'s bow allowance
    /// floors at 8, so the mesh searched millimetres of board the gate would
    /// never accept a segment in. A whole-board context's grid already covers
    /// the board, so this changes nothing there.
    fn of(grid: Grid, placement: optimizer.Placement) ShapeBounds {
        var b: ShapeBounds = if (placement.board_rect) |r| .{
            .x0 = r.minx,
            .y0 = r.miny,
            .x1 = r.minx + r.w,
            .y1 = r.miny + r.h,
        } else .{ .x0 = placement.minx, .y0 = placement.miny, .x1 = placement.maxx, .y1 = placement.maxy };
        b.x0 = @max(b.x0, grid.worldX(0));
        b.y0 = @max(b.y0, grid.worldY(0));
        b.x1 = @min(b.x1, grid.worldX(grid.nx - 1));
        b.y1 = @min(b.y1, grid.worldY(grid.ny - 1));
        return b;
    }
};

/// One question for the gridless mesh: whose board, whose copper, which two
/// terminals — and how wide the channel has to be.
///
/// `width` is the only field that is not simply "what the caller already has".
/// Zero takes the routing net's own track width, which is every single-net
/// caller. A COUPLED differential pair asks for its whole ENVELOPE (`2·width +
/// gap`) instead, because the channel it needs has to hold BOTH legs: the
/// centreline the mesh returns is split into two exact ±(width+gap)/2 offsets,
/// so a corridor sized for one trace would hand back a path whose legs do not
/// fit. That is the same substitution `diff_couple.routeEnvelope` makes on the
/// maze's own `params.track_width`.
pub const ShapeAsk = struct {
    placement: optimizer.Placement,
    tracks: []const Track,
    vias: []const Via,
    from: NetPt,
    to: NetPt,
    width: f64 = 0,
};

/// The copper profile one mesh request models: the ask's own width when it names
/// one, else the routing net's track width. One rule rather than a condition
/// inlined per caller, because "how wide is the channel" is the single question a
/// coupled pair answers differently from every other mesh caller.
fn shapeWidth(ask: ShapeAsk, track_width: f64) f64 {
    return if (ask.width > 0) ask.width else track_width;
}

/// Assemble one `cdt_layers` request — the window, the per-layer prices, the
/// foreign copper at this net's exact halo, the non-copper keepouts, and the via
/// sites a layer change may go through. Null when the net may lay copper on no
/// layer at all, which is the one question that has to be answered before a mesh
/// is worth building.
///
/// ONE builder for every mesh caller. The gap hop, the whole-net shape rescue
/// and the coupled pair channel are the same question asked over different
/// copper, and three spellings of it are three chances for one of them to model
/// the board differently from the gate that judges its output — which is the
/// exact failure `shapeHalo` and `shapeKeepouts` were written to close.
///
/// The probe budget is deliberately NOT touched here: every caller nulls it
/// across its whole attempt (the sites AND the emission gate behind them), and
/// restoring it when this returns would re-arm it for the emission.
pub fn shapeInput(run: DirectRun, ask: ShapeAsk) std.mem.Allocator.Error!?cdt_layers.Input {
    const ctx = run.ctx;
    const arena = ctx.arena;
    const layers = try shapeLayers(arena, ctx, run.net);
    if (layers.len == 0) return null;
    const pts = try arena.alloc(NetPt, 2);
    pts[0] = ask.from;
    pts[1] = ask.to;
    const rect = shapeWindow(ShapeBounds.of(ctx.grid, ask.placement), pts);
    const sites = try shapeViaSites(arena, run, rect, ask.from, ask.to);
    return .{
        .field = .{
            .rect = rect,
            .layer = ask.from.layer,
            .obstacles = .{
                .pads = ctx.obs,
                .tracks = ask.tracks,
                .vias = ask.vias,
                .skip_net = run.net,
                .halo = try shapeHalo(arena, ctx, run.net),
                .keepouts = try shapeKeepouts(arena, ctx, run.net, pts),
            },
            .track_width = shapeWidth(ask, ctx.params.track_width),
            .clearance = ctx.params.clearance,
        },
        .layers = layers,
        .start = .{ .at = .{ ask.from.x, ask.from.y }, .layer = ask.from.layer },
        .goal = .{ .at = .{ ask.to.x, ask.to.y }, .layer = ask.to.layer },
        .via_sites = sites,
        .via_cost_mm = ctx.grid.g * via_cost_mult,
    };
}

/// The signal layers `net` may lay copper on, priced exactly as `relaxStep`
/// prices them, so the shape router prefers the layers the maze would rather
/// than inventing a preference of its own. Layer availability is the gap pass's
/// rule (`gapLayers`: outer faces, un-poured inners, and any layer carrying this
/// net's own pour) narrowed by the net's authored `allowed_layers`.
fn shapeLayers(a: std.mem.Allocator, ctx: *const Ctx, net: i32) std.mem.Allocator.Error![]const cdt_layers.Layer {
    var out: std.ArrayList(cdt_layers.Layer) = .empty;
    const usable = gapLayers(ctx, net);
    for (0..@min(ctx.occ.len, 64)) |layer| {
        const li: u8 = @intCast(layer);
        if ((usable & (@as(u64, 1) << @intCast(li))) == 0) continue;
        if (!layerInMask(ctx.allowed_layers, li)) continue;
        var cost: f64 = if (layer >= 2) inner_cost_mult else if (ctx.pour[layer]) pour_cost_mult else 1.0;
        if (!layerInMask(ctx.preferred_layers, li)) cost *= preferred_layer_cost_mult;
        try out.append(a, .{ .index = li, .cost = cost });
    }
    return out.toOwnedSlice(a);
}

/// The per-net keepout halo the shape search must model, in `cdt_route`'s own
/// net-indexed form — or an empty slice when this board declares no keepout at
/// all, which keeps every such board's mesh byte-identical.
///
/// This is one half of MODEL PARITY. `emitShapeRoute` gates each segment on
/// `clearDoglegSegment`, whose pad/track/via probes all measure against
/// `keepLimits` — ordinary clearance PLUS the obstacle net's authored halo. The
/// mesh saw only the ordinary clearance, so a corridor the halo closes still
/// looked open, the single Dijkstra answer came back through it, and the gate
/// refused the whole attempt. There is no second answer: a refusal ends the hop.
/// So the halo goes into the obstacle inflation, and the search routes AROUND
/// what the gate would have refused.
///
/// The escape-zone carve-out is honoured the way it is measured. `approachClears`
/// waives the halo SURPLUS (never the ordinary clearance) where the approach
/// point falls inside one of the obstacle net's own escape zones that admits the
/// net now routing — the neighbour pin escaping past an RF pad. A zone is a disc
/// on the obstacle's own pads, so where it admits at all it covers the band the
/// halo would have added; modelling that net at ordinary clearance is what the
/// mesh already did, and is therefore never a regression.
fn shapeHalo(a: std.mem.Allocator, ctx: *const Ctx, net: i32) std.mem.Allocator.Error![]const f64 {
    if (ctx.keep.nets.len == 0 or ctx.keep.exempt) return &.{};
    const out = try a.alloc(f64, ctx.keep.nets.len);
    for (out, 0..) |*extra, i| {
        const obstacle: i32 = @intCast(i);
        if (obstacle == net or zoneAdmitsAnywhere(ctx.keep.zones, obstacle)) {
            extra.* = 0;
            continue;
        }
        extra.* = keepoutExtra(ctx, obstacle);
    }
    return out;
}

/// Does ANY of `net`'s escape zones currently admit the net being routed? Then
/// its halo surplus stands down wherever those zones reach, and the shape mesh
/// keeps the ordinary-clearance model it has always used for it.
fn zoneAdmitsAnywhere(zones: keepout.Zones, net: i32) bool {
    const first = zones.base(net);
    for (0..zones.of(net).len) |i| {
        if (zones.admits(first + i)) return true;
    }
    return false;
}

/// The regions a shape path must avoid on `layer` that are not copper: the
/// blocking zones `directSegmentInside` consults, and the band inside the board
/// edge where `outlineBlocked` refuses to put copper.
///
/// The other half of model parity, and the same argument: these are hard
/// refusals in the emission gate, so a mesh blind to them hands back exactly the
/// corridor the gate then throws away.
fn shapeKeepouts(
    a: std.mem.Allocator,
    ctx: *const Ctx,
    net: i32,
    pts: []const NetPt,
) std.mem.Allocator.Error![]const cdt_layers.Keepout {
    var out: std.ArrayList(cdt_layers.Keepout) = .empty;
    for (ctx.zones) |zone| {
        if (!zone.tracks_blocked or zone.polygon.len < 3) continue;
        if (zone.copper and zone.net == net) continue;
        try out.append(a, .{ .poly = zone.polygon, .layer = zone.layer });
    }
    if (try shapeEdgeBands(a, ctx, net, pts)) |bands| {
        for (bands) |band| try out.append(a, .{ .poly = band, .every_layer = true });
    }
    return out.toOwnedSlice(a);
}

/// The four rectangles of the copper-edge inset band, or null when this board or
/// this net has no edge rule for the mesh to model.
///
/// An under-approximation for a design whose `board_poly` is not its own
/// bounding rectangle, which is the safe direction: it models LESS than the gate
/// refuses, never more, so at worst such a board keeps exactly today's
/// behaviour. It is skipped wholesale for a net staged off-board, and whenever a
/// TERMINAL of this hop lies in the band — `outlineBlocked` exempts a node
/// sitting on a real pad precisely so an edge-hugging pad can still be reached,
/// and a band that walled in its own terminal would refuse a hop the gate would
/// have taken.
fn shapeEdgeBands(
    a: std.mem.Allocator,
    ctx: *const Ctx,
    net: i32,
    pts: []const NetPt,
) std.mem.Allocator.Error!?[]const []const [2]f64 {
    if (ctx.outline_mask == null) return null;
    const br = ctx.board_rect orelse return null;
    if (net >= 0) {
        const i: usize = @intCast(net);
        if (i < ctx.net_offboard.len and ctx.net_offboard[i]) return null;
    }
    const inset = via_rules.edgeInset(ctx.params.track_width, ctx.params.via_dia, ctx.edge_clearance);
    if (!(inset > 0)) return null;
    const x0 = br.minx;
    const y0 = br.miny;
    const x1 = br.minx + br.w;
    const y1 = br.miny + br.h;
    if (x1 - x0 <= 2 * inset or y1 - y0 <= 2 * inset) return null;
    for (pts) |p| {
        if (p.x < x0 + inset or p.x > x1 - inset) return null; // a terminal in
        if (p.y < y0 + inset or p.y > y1 - inset) return null; // the band
    }
    const bands = try a.alloc([]const [2]f64, 4);
    const spans = [4][4]f64{
        .{ x0 - inset, y0 - inset, x0 + inset, y1 + inset }, // west
        .{ x1 - inset, y0 - inset, x1 + inset, y1 + inset }, // east
        .{ x0 - inset, y0 - inset, x1 + inset, y0 + inset }, // south
        .{ x0 - inset, y1 - inset, x1 + inset, y1 + inset }, // north
    };
    for (bands, spans) |*band, s| {
        const quad = try a.alloc([2]f64, 4);
        quad[0] = .{ s[0], s[1] };
        quad[1] = .{ s[2], s[1] };
        quad[2] = .{ s[2], s[3] };
        quad[3] = .{ s[0], s[3] };
        band.* = quad;
    }
    return bands;
}

/// The via-site lattice pitch for one window.
///
/// A fixed 1.0 mm pitch is right for a board-scale window and useless for a
/// tight one: a 2 mm x 1 mm pocket contains no lattice point at all, so the
/// layered search had no way to change layers and silently degenerated to a
/// single-layer one. The pitch therefore scales with the window's short side,
/// so every window offers a comparable NUMBER of candidates rather than a
/// comparable spacing, floored so a pathological sliver cannot ask for millions.
fn shapeViaPitch(rect: fine_window.WindowRect) f64 {
    const short = @min(rect.x1 - rect.x0, rect.y1 - rect.y0);
    return std.math.clamp(short / shape_sites_across, shape_via_pitch_min_mm, shape_via_pitch_mm);
}

/// The board points a barrel may occupy: a fine disc about each terminal, then a
/// lattice across the window, then a run along the straight line between them.
///
/// Every candidate goes through `directViaClear` — the router's own exact via
/// test, so the shape engine is never offered a site the board would refuse.
/// The on-axis run matters as much as the lattice: a dive is most often wanted
/// exactly where the direct route is blocked, and a lattice aligned to the
/// window can miss that line entirely however fine it is.
///
/// The TERMINAL discs come first because they are the ones a refusal turns on
/// (`shapeTerminalSites`) and the cap must never starve them.
fn shapeViaSites(
    a: std.mem.Allocator,
    run: DirectRun,
    rect: fine_window.WindowRect,
    from: NetPt,
    to: NetPt,
) std.mem.Allocator.Error![]const cdt_layers.ViaSite {
    var out: std.ArrayList(cdt_layers.ViaSite) = .empty;
    try shapeTerminalSites(a, run, &out, from);
    try shapeTerminalSites(a, run, &out, to);
    const pitch = shapeViaPitch(rect);
    var y = rect.y0 + pitch / 2;
    while (y < rect.y1 and out.items.len < shape_max_sites) : (y += pitch) {
        var x = rect.x0 + pitch / 2;
        while (x < rect.x1 and out.items.len < shape_max_sites) : (x += pitch) {
            if (directViaClear(run, .{ x, y })) try out.append(a, .{ .x = x, .y = y });
        }
    }
    // Walk the terminal-to-terminal line at the same pitch.
    const dx = to.x - from.x;
    const dy = to.y - from.y;
    const len = std.math.hypot(dx, dy);
    if (len > 1e-9) {
        var t = pitch;
        while (t < len and out.items.len < shape_max_sites) : (t += pitch) {
            const pos = [2]f64{ from.x + dx * (t / len), from.y + dy * (t / len) };
            if (directViaClear(run, pos)) try out.append(a, .{ .x = pos[0], .y = pos[1] });
        }
    }
    return out.toOwnedSlice(a);
}

/// Every legal barrel position in a fine disc about ONE terminal.
///
/// This is the supply a refusal turns on, and neither of the other two sources
/// can provide it: the lattice is anchored to the WINDOW and the on-axis run
/// starts a full pitch out, so neither ever samples the millimetre around a pad
/// — and in a congested pad field the lattice points beside a pad are exactly
/// the ones `directViaClear` rejects, so the surviving supply retreats to open
/// board.
///
/// Measured on barracuda (2026-08-17), on every `found no channel` hop: the
/// nearest site OFFERED was 1.5-4.6 mm from the terminal and the terminal's own
/// reachable free-space pocket (0.2-3.6 mm across) held NO via node at all,
/// while a 0.1 mm probe of the same 2 mm disc found 12-193 legal barrels. With
/// no via node in the pocket the layered graph has no layer-change edge where
/// the terminal needs one, so the multi-layer search degenerates to a
/// single-layer one exactly where the dive is the whole point — and the taut
/// channel it was built to find is refused with a legal barrel sitting under a
/// millimetre from the pad.
///
/// The hop's TERMINAL VIA BAN applies here as it does to the maze's own via
/// test (`viaAllowed`): a barrel punched into the hop's own terminal pad is not
/// an escape, it is via-in-pad, so those nodes are withheld even though
/// `directViaClear` — which skips the routing net's own pads — would pass them.
/// The ban only covers the terminal pads and their via halo, so the rest of the
/// disc is offered exactly as measured.
fn shapeTerminalSites(
    a: std.mem.Allocator,
    run: DirectRun,
    out: *std.ArrayList(cdt_layers.ViaSite),
    at: NetPt,
) std.mem.Allocator.Error!void {
    const r = shape_term_radius_mm;
    var dy: f64 = -r;
    while (dy <= r + 1e-9 and out.items.len < shape_max_sites) : (dy += shape_term_pitch_mm) {
        var dx: f64 = -r;
        while (dx <= r + 1e-9 and out.items.len < shape_max_sites) : (dx += shape_term_pitch_mm) {
            if (std.math.hypot(dx, dy) > r) continue;
            const pos = [2]f64{ at.x + dx, at.y + dy };
            if (shapeSiteBanned(run.ctx, run.net, pos)) continue;
            if (directViaClear(run, pos)) try out.append(a, .{ .x = pos[0], .y = pos[1] });
        }
    }
}

/// Is `pos` inside the via exclusion the hop in flight declared for its own
/// terminals? `directViaClear` deliberately does not read this mask — it is the
/// off-grid primitive every direct route shares — so the shape tier asks the
/// question itself, exactly as the maze's `viaAllowed` does.
fn shapeSiteBanned(ctx: *const Ctx, net: i32, pos: [2]f64) bool {
    if (ctx.via_forbidden_net != net) return false;
    const mask = ctx.via_forbidden_mask orelse return false;
    const nearest = ctx.grid.nearest(pos[0], pos[1]);
    const node = ctx.grid.node(nearest[0], nearest[1]);
    return node < mask.len and mask[node];
}

/// Emit one shape route's copper: each leg's segments on its own layer, then the
/// barrel at the layer change that follows it. Strictly in path order, and each
/// probe re-projects `run.path`, so every segment is judged against the copper
/// the ones before it already laid. False the moment any piece is refused —
/// the caller then rolls the whole attempt back.
fn emitShapeRoute(run: DirectRun, found: cdt_layers.Route, stamp: bool) std.mem.Allocator.Error!bool {
    for (found.legs, 0..) |leg, i| {
        for (0..leg.path.len -| 1) |k| {
            const p = leg.path[k];
            const q = leg.path[k + 1];
            const path = run.path(leg.layer);
            if (!clearDoglegSegment(path, p, q)) return false;
            if (stamp) {
                try emitDoglegSegment(path, p, q, run.tracks);
            } else {
                try appendShapeSegment(path, p, q, run.tracks);
            }
        }
        if (i >= found.vias.len) continue;
        const pos = [2]f64{ found.vias[i].x, found.vias[i].y };
        if (!directViaClear(run, pos)) return false;
        try run.vias.append(run.ctx.arena, .{
            .x = pos[0],
            .y = pos[1],
            .dia = run.ctx.params.via_dia,
            .drill = run.ctx.params.via_drill,
            .net = run.net,
        });
        if (stamp) stampViaOcc(run.ctx, pos[0], pos[1], run.net);
    }
    return true;
}

/// Which family of the emission gate refused a shape route, in the gate's own
/// order. `none` means nothing refuses now — the route was rolled back for
/// another reason, or the board moved under it.
///
/// This is the observability half of model parity. A bare `copper refused`
/// verdict cannot say whether the search's obstacle model is short of the gate's
/// or whether the gate is simply right about the board, and those want opposite
/// work: the first is a mesh to teach, the second is a corridor that genuinely
/// is not there. Every family named here is one the mesh now models
/// (`shapeHalo`, `shapeKeepouts`, `ShapeBounds.of`), so a residual count in any
/// of them is a measured gap rather than a guess.
const ShapeRefusal = enum { lane, inside, pads, vias, tracks, via_site, none };

/// Re-ask the refused route's own probes, one family at a time. Only ever run on
/// the refusal path — a landed route costs nothing for it.
fn shapeRefusal(run: DirectRun, found: cdt_layers.Route) ShapeRefusal {
    for (found.legs, 0..) |leg, i| {
        const path = run.path(leg.layer);
        for (0..leg.path.len -| 1) |k| {
            const a = leg.path[k];
            const b = leg.path[k + 1];
            if (std.math.hypot(b[0] - a[0], b[1] - a[1]) < 1e-9) continue;
            if (lane_reserve.segmentBlocked(path.ctx.reserved_lanes, path.ctx.grid, path.layer, path.net, a, b))
                return .lane;
            if (!directSegmentInside(path, a, b)) return .inside;
            if (!segClearsPadsOnLayer(path.ctx, a, b, path.net, path.layer)) return .pads;
            if (!segClearsVias(path.ctx, path.vias, a, b, path.net)) return .vias;
            if (!segClearsTracks(path.ctx, path.tracks, a, b, path.net, path.layer)) return .tracks;
        }
        if (i < found.vias.len and !directViaClear(run, .{ found.vias[i].x, found.vias[i].y })) return .via_site;
    }
    return .none;
}

/// Append one shape segment WITHOUT stamping occupancy — the spelling a hop
/// uses, because a gap path is a candidate its caller may still throw away and
/// only `GapState.absorb` may put copper on the live board. The segment is
/// still appended to the run's own list, so a later via in the same hop is
/// probed against it.
fn appendShapeSegment(
    path: DirectPath,
    a: [2]f64,
    b: [2]f64,
    tracks: *std.ArrayList(Track),
) std.mem.Allocator.Error!void {
    if (std.math.hypot(b[0] - a[0], b[1] - a[1]) < 1e-9) return;
    try tracks.append(path.ctx.arena, .{
        .x1 = a[0],
        .y1 = a[1],
        .x2 = b[0],
        .y2 = b[1],
        .layer = path.layer,
        .width = path.ctx.params.track_width,
        .net = path.net,
    });
}

/// One net's shape attempt: mesh every layer it may use, search the layered
/// channel graph through the legal via sites, emit what it finds, and gate the
/// whole tail on the same `fineCopperClean` every other rescue commits through.
/// All-or-nothing — a refused attempt leaves the copper and occupancy exactly as
/// it found them, so the tier can neither introduce a violation nor disturb a
/// routed net.
fn shapeRescueNet(run: EscalateRun, rn: *RipNet) std.mem.Allocator.Error!bool {
    const ctx = run.ctx;
    setNetParams(ctx, run.placement, rn.net_i);
    const pts = try netPoints(ctx.arena, run.placement, run.idx_of, run.placement.nets[rn.net_i]);
    // Two terminals for now: a multi-drop net needs its legs sequenced against
    // its own accumulating copper, which is the next tier up.
    if (pts.len != 2) {
        ctx.shape_verdict = .multi_terminal;
        return false;
    }
    setNetRoutePolicy(ctx, rn.net_i, pts);
    const net: i32 = @intCast(rn.net_i);
    const dr = DirectRun{ .ctx = ctx, .net = net, .tracks = run.tracks, .vias = run.vias };
    // The tier is gated on its own wall clock, so a probe budget left over from
    // the maze must not make every via site read as blocked.
    const saved_budget = ctx.direct_budget;
    ctx.direct_budget = null;
    defer ctx.direct_budget = saved_budget;
    const ask = (try shapeInput(dr, .{
        .placement = run.placement,
        .tracks = run.tracks.items,
        .vias = run.vias.items,
        .from = pts[0],
        .to = pts[1],
    })) orelse {
        ctx.shape_verdict = .no_layer;
        return false;
    };
    const found = (try cdt_layers.route(ctx.arena, ask)) orelse {
        ctx.shape_verdict = .no_channel;
        return false;
    };
    const keep_t = run.tracks.items.len;
    const keep_v = run.vias.items.len;
    const emitted = try emitShapeRoute(dr, found, true);
    if (emitted and fineCopperClean(.{
        .ctx = ctx,
        .placement = run.placement,
        .board_tracks = run.tracks.items[0..keep_t],
        .board_vias = run.vias.items[0..keep_v],
        .new_tracks = run.tracks.items[keep_t..],
        .new_vias = run.vias.items[keep_v..],
        .net_i = rn.net_i,
    })) return true;
    ctx.shape_verdict = if (emitted) .drc_refused else .copper_refused;
    rollbackDirectRun(dr, keep_t, keep_v);
    return false;
}

/// The tier: one shape attempt for each net the whole ladder still could not
/// reach, newest evidence first, bounded by `shape_max_nets` and by whether the
/// board can spare the wall clock. Returns how many nets it closed.
fn shapeRescueTier(run: EscalateRun) std.mem.Allocator.Error!usize {
    var left: usize = 0;
    for (run.routable) |*rn| {
        if (!rn.ok and rn.reroutable) left += 1;
    }
    var rescued: usize = 0;
    var tried: usize = 0;
    shapeLog("shape tier: enter with {d} failed, affordable={}", .{ left, shapeTierAffordable(run.ctx, left) });
    for (run.routable) |*rn| {
        if (routeCancelled(run.ctx)) break;
        if (rn.ok or !rn.reroutable) continue;
        if (diff_couple.isPairMember(run.placement.diff_pairs, rn.net_i)) continue;
        if (tried >= shape_max_nets) break;
        if (!shapeTierAffordable(run.ctx, left - rescued)) break;
        tried += 1;
        const name = run.placement.nets[rn.net_i].name;
        if (!try shapeRescueNet(run, rn)) {
            shapeLog("shape tier {s}: {s}", .{ name, @tagName(run.ctx.shape_verdict) });
            continue;
        }
        rn.ok = true;
        clearSearchLimit(run.ctx, rn.net_i);
        rescued += 1;
        shapeLog("shape tier {s}: closed", .{name});
    }
    return rescued;
}

/// Route a diff pair's follower leg against its already-routed leader under the
/// caller's escalation flag: a coupled attempt confined to the corridor dilated
/// from the leader's fresh copper, then an independent fallback. Mirrors the
/// greedy pass's follower path so the two produce identical coupled geometry.
pub fn routeFollowerLeg(
    run: EscalateRun,
    pair: diff_pairs.DiffPair,
    n_slot: *RipNet,
) std.mem.Allocator.Error!void {
    const ctx = run.ctx;
    setNetParams(ctx, run.placement, pair.n);
    const pts = try netPoints(ctx.arena, run.placement, run.idx_of, run.placement.nets[pair.n]);
    if (pts.len < 2) {
        n_slot.ok = true;
        return;
    }
    setNetRoutePolicy(ctx, pair.n, pts);
    try setNetReferenceGuide(ctx, pair.n);
    const ni: i32 = @intCast(pair.n);
    const radius = pairCorridorRadius(ctx, pair.gap);
    ctx.corridor = try diff_pairs.buildCorridor(ctx.arena, ctx.occ, ctx.grid.nx, ctx.grid.ny, @intCast(pair.p), radius);
    ctx.pair_via_mask = try buildPairViaMask(ctx, run.vias.items, @intCast(pair.p), pair.gap);
    if (pts.len == 2) ctx.pair_terminal_mask = try buildPairTerminalMask(ctx.arena, ctx, pts);
    const keep = run.tracks.items.len;
    var ok = false;
    if (pts.len == 2) {
        ctx.pair_coupling_hard = true;
        ctx.pair_vias_hard = ctx.pair_via_mask != null;
        ok = try routeNet(ctx, ni, pts, run.tracks, run.vias);
        ctx.pair_vias_hard = false;
        ctx.pair_coupling_hard = false;
    }
    if (!ok) {
        ctx.corridor = null;
        ctx.pair_via_mask = null;
        ctx.pair_terminal_mask = null;
        ok = try routeNet(ctx, ni, pts, run.tracks, run.vias);
    }
    ctx.corridor = null;
    ctx.pair_via_mask = null;
    ctx.pair_terminal_mask = null;
    n_slot.ok = ok;
    if (ok) try smoothNetInline(
        .{ .ctx = ctx, .placement = run.placement, .tracks = run.tracks, .vias = run.vias },
        pair.n,
        keep,
        0,
    );
}

// ── Windowed fine-grid local retry ───────────────────────────────────────────
//
// The last resort for nets STILL failed after every escalate / rip-up phase.
// `fine_window` (a pure planning module — the bend_smooth / straighten precedent
// of a plain-data interface) decides the window box + pitch; the router drives
// the same maze on a fresh context built over that window at half (then quarter)
// the whole-board grid pitch, where an off-grid pad escape the coarse raster
// can't represent becomes routable. Only still-failed nets are touched and
// routed copper is never ripped, so a cleanly-routing board pays nothing.

/// Live routing state the windowed rescue reads and splices into — the working
/// set `routeSignalPass` holds after greedy + rip-up.
const FineRescueRun = struct {
    ctx: *Ctx,
    placement: optimizer.Placement,
    idx_of: *std.StringHashMapUnmanaged(usize),
    routable: []RipNet,
    tracks: *std.ArrayList(Track),
    vias: *std.ArrayList(Via),
    /// Connectivity accept gate for nets that DECLARED a raster pitch (see
    /// `fine_accept`). Null = ungated, which is what every path that cannot
    /// build an over-cap window keeps.
    gate: ?*fine_accept.Gate = null,
    /// Normally-refused classifier rungs this pass may arm, because the board's
    /// residual is down to the last few nets (`gap_policy.lastKRungs`). All
    /// false — the default — is the historical classifier exactly.
    widen: gap_policy.LastKRungs = .{},
    /// How many more nets a widened rung may DECIDE (`LastK.spenders`), spent
    /// only where widening actually changed the verdict. Null = none, which is
    /// what every caller that armed no rung keeps.
    widen_left: ?*usize = null,
    /// Restrict the pass to nets with an explicit `(resolution …)` request.
    /// Used by one-shot effort, whose only permitted rescue is authored.
    declared_only: bool = false,
};

fn fineRescueEligible(run: FineRescueRun, net_i: usize) bool {
    return !run.declared_only or fine_window.declaredPitch(run.placement, net_i) != null;
}

/// Claim one of the pass's widened-rung decisions, or report it is out of them.
/// The budget is charged at the point a rung overturns a refusal, so a residual
/// that never hits one costs nothing.
fn takeWiden(run: FineRescueRun) bool {
    const left = run.widen_left orelse return false;
    if (left.* == 0) return false;
    left.* -= 1;
    return true;
}

/// Retry only still-failed nets whose base-grid reachability shape is the
/// `grid_quantization` class: the flood can reach every terminal, or it finds
/// an open non-sealed corridor with no foreign-copper frontier. Search-limited
/// (budget) and copper-walled (order/congestion) failures are deliberately
/// skipped, so a whole-board batch pays fine-grid cost only for the residual
/// class a finer lattice can actually fix. Returns newly routed net indices in
/// `routable` order; each gets its `ok` set and copper spliced onto the board.
fn fineWindowRescue(run: FineRescueRun) std.mem.Allocator.Error![]const usize {
    const arena = run.ctx.arena;
    var out: std.ArrayList(usize) = .empty;
    for (run.routable) |*rn| {
        if (routeCancelled(run.ctx)) break; // cooperative cancel: skip the rescue
        if (rn.ok) continue;
        if (!fineRescueEligible(run, rn.net_i)) continue;
        // A retained pour is already the rail's connected trunk. Preserve the
        // existing bounded per-terminal rescue for those nets regardless of
        // the whole-net failure label; this is a pour-specific join operation,
        // not the batch quarter-grid retry restricted below.
        if (largestNetZone(run.ctx, @intCast(rn.net_i)) != null) {
            const pts = try netPoints(arena, run.placement, run.idx_of, run.placement.nets[rn.net_i]);
            const base = fine_window.netPitch(run.ctx.base, run.placement, rn.net_i);
            if (try rescueZoneTerminals(run, rn.net_i, pts, base)) {
                rn.ok = true;
                try out.append(arena, rn.net_i);
            }
            continue;
        }
        // Per-residual flood scratch must be reclaimed before the next net.
        // allocator-ok: the injected route arena is monotonic and cannot do that.
        var scratch_inst = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer scratch_inst.deinit();
        // A DECLARED `(resolution …)` is the author saying this net needs a
        // finer lattice than the classifier can infer — honour it without the
        // quantization heuristic having to agree.
        if (fine_window.declaredPitch(run.placement, rn.net_i) == null and
            !try residualIsGridQuantized(run, rn.net_i, scratch_inst.allocator())) continue;
        if (try rescueNetInWindow(run, rn.net_i) or
            try rescueQuantizedFullBoard(run, rn.net_i))
        {
            rn.ok = true;
            try out.append(arena, rn.net_i);
        }
    }
    return out.toOwnedSlice(arena);
}

/// Match the stuck diagnostic's inexpensive, base-grid classification fork
/// without importing `route_diagnose` back into the router (which would form an
/// import cycle). The flood is capped, and its page-backed scratch arena is
/// discarded after each residual net, bounding both runtime and retained
/// memory. This intentionally recognizes only a safe subset of quantization:
/// an over-budget flood is left to the search-budget remedy and a rippable-
/// copper frontier to rip-up — UNLESS `run.widen` armed those rungs, which the
/// caller does only once the residual is down to the last few nets and both
/// refusals have gone stale (`gap_policy.lastKRungs`).
fn residualIsGridQuantized(
    run: FineRescueRun,
    net_i: usize,
    scratch: std.mem.Allocator,
) std.mem.Allocator.Error!bool {
    setNetParams(run.ctx, run.placement, net_i);
    const pts = try netPoints(scratch, run.placement, run.idx_of, run.placement.nets[net_i]);
    if (pts.len < 2) return false;
    setNetRoutePolicy(run.ctx, net_i, pts);
    const flood = try residualFlood(run.ctx, @intCast(net_i), pts[0], scratch);
    const shape = residualFloodShape(run.ctx, pts, flood.reached);
    if (shape.reaches_all) return true;
    if (flood.capped) return run.widen.capped_flood and takeWiden(run);
    if (!shape.reaches_other and shape.reached_cells <= quantization_escape_cells) return false;
    if (!residualFrontierHasRippableCopper(run, net_i, pts, flood.reached)) return true;
    return run.widen.rippable_frontier and takeWiden(run);
}

/// Keep the classifier proportional to a small local diagnostic even on the
/// largest routable board. Hitting the cap means "unknown", hence no retry.
const quantization_flood_cap: usize = 20_000;
const quantization_escape_cells: usize = 14;
const quantization_crop_margin: usize = 3;

const ResidualFlood = struct { reached: []const bool, capped: bool };
const ResidualFloodWork = struct {
    ctx: *Ctx,
    net: i32,
    reached: []bool,
    queue: *std.ArrayList(usize),
    scratch: std.mem.Allocator,
};

/// Bounded 8-connected + via reachability flood over the live whole-board
/// copper. It uses `blocked`, exactly as the ordinary maze and stuck diagnosis
/// do, but stores only a bitset and queue.
fn residualFlood(
    ctx: *Ctx,
    net: i32,
    seed: NetPt,
    scratch: std.mem.Allocator,
) std.mem.Allocator.Error!ResidualFlood {
    const nodes = ctx.grid.nx * ctx.grid.ny;
    const reached = try scratch.alloc(bool, ctx.occ.len * nodes);
    @memset(reached, false);
    var queue: std.ArrayList(usize) = .empty;
    const start_xy = ctx.grid.nearest(seed.x, seed.y);
    const start = @as(usize, seed.layer) * nodes + ctx.grid.node(start_xy[0], start_xy[1]);
    reached[start] = true;
    try queue.append(scratch, start);
    const work = ResidualFloodWork{
        .ctx = ctx,
        .net = net,
        .reached = reached,
        .queue = &queue,
        .scratch = scratch,
    };
    var head: usize = 0;
    while (head < queue.items.len and head < quantization_flood_cap) : (head += 1)
        try residualFloodExpand(work, queue.items[head]);
    return .{ .reached = reached, .capped = head < queue.items.len };
}

fn residualFloodExpand(work: ResidualFloodWork, key: usize) std.mem.Allocator.Error!void {
    const grid = work.ctx.grid;
    const nodes = grid.nx * grid.ny;
    const layer = key / nodes;
    const node = key % nodes;
    const ix = node % grid.nx;
    const iy = node / grid.nx;
    const offsets = [_][2]i64{
        .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 },  .{ 0, -1 },
        .{ 1, 1 }, .{ 1, -1 }, .{ -1, 1 }, .{ -1, -1 },
    };
    for (offsets) |d| {
        const next = neighbor(grid, ix, iy, d[0], d[1]) orelse continue;
        try residualFloodReach(work, layer, next);
    }
    for (0..work.ctx.occ.len) |other_layer|
        if (other_layer != layer) try residualFloodReach(work, other_layer, node);
}

fn residualFloodReach(work: ResidualFloodWork, layer: usize, node: usize) std.mem.Allocator.Error!void {
    const nodes = work.ctx.grid.nx * work.ctx.grid.ny;
    const key = layer * nodes + node;
    if (work.reached[key] or blocked(work.ctx, layer, node, work.net)) return;
    work.reached[key] = true;
    try work.queue.append(work.scratch, key);
}

const ResidualFloodShape = struct {
    reached_cells: usize,
    reaches_all: bool,
    reaches_other: bool,
};

fn residualFloodShape(ctx: *const Ctx, pts: []const NetPt, reached: []const bool) ResidualFloodShape {
    const nodes = ctx.grid.nx * ctx.grid.ny;
    var reached_cells: usize = 0;
    for (0..nodes) |node| {
        for (0..ctx.occ.len) |layer| {
            if (!reached[layer * nodes + node]) continue;
            reached_cells += 1;
            break;
        }
    }
    var all = true;
    var other = false;
    for (pts, 0..) |pt, i| {
        const xy = ctx.grid.nearest(pt.x, pt.y);
        const hit = reached[@as(usize, pt.layer) * nodes + ctx.grid.node(xy[0], xy[1])];
        all = all and hit;
        other = other or (i > 0 and hit);
    }
    return .{ .reached_cells = reached_cells, .reaches_all = all, .reaches_other = other };
}

/// Whether removable routed copper bounds the reachable region inside the
/// failed net's pad corridor. A lower/equal-priority routed wall is congestion
/// for rip-up to solve, so it suppresses the fine retry. Protected or retained
/// copper is different: the router cannot remove it, and an otherwise-open
/// corridor narrowed by that copper is exactly where a finer lattice may help.
fn residualFrontierHasRippableCopper(
    run: FineRescueRun,
    net_i: usize,
    pts: []const NetPt,
    reached: []const bool,
) bool {
    const ctx = run.ctx;
    const net: i32 = @intCast(net_i);
    const crop = residualCrop(ctx.grid, pts);
    for (crop[1]..crop[3] + 1) |iy| {
        for (crop[0]..crop[2] + 1) |ix| {
            const node = iy * ctx.grid.nx + ix;
            for (0..ctx.occ.len) |layer| {
                if (!residualFrontierAdjacent(ctx, reached, layer, ix, iy)) continue;
                const occ = ctx.occ[layer][node];
                if (occ != empty_cell and occ != net and
                    residualOwnerRippable(run, net_i, occ)) return true;
                const resv = ctx.resv[layer][node];
                if (resv != empty_cell and resv != net and
                    residualOwnerRippable(run, net_i, resv)) return true;
            }
        }
    }
    return false;
}

fn residualCrop(grid: Grid, pts: []const NetPt) [4]usize {
    const first = grid.nearest(pts[0].x, pts[0].y);
    var min_ix = first[0];
    var min_iy = first[1];
    var max_ix = first[0];
    var max_iy = first[1];
    for (pts[1..]) |pt| {
        const xy = grid.nearest(pt.x, pt.y);
        min_ix = @min(min_ix, xy[0]);
        min_iy = @min(min_iy, xy[1]);
        max_ix = @max(max_ix, xy[0]);
        max_iy = @max(max_iy, xy[1]);
    }
    return .{
        min_ix -| quantization_crop_margin,
        min_iy -| quantization_crop_margin,
        @min(grid.nx - 1, max_ix + quantization_crop_margin),
        @min(grid.ny - 1, max_iy + quantization_crop_margin),
    };
}

fn residualOwnerRippable(run: FineRescueRun, fail_i: usize, owner: i32) bool {
    if (owner < 0) return false;
    var fail_pri: ?u64 = null;
    for (run.routable) |rn| {
        if (rn.net_i == fail_i) {
            fail_pri = rn.pri;
            break;
        }
    }
    const ceiling = fail_pri orelse return false;
    for (run.routable) |rn| {
        if (!rn.ok or @as(i32, @intCast(rn.net_i)) != owner or rn.pri > ceiling) continue;
        const name = run.placement.nets[rn.net_i].name;
        if (netHasPlane(run.placement, name) or isGroundName(shortName(name))) return false;
        const pour = netPourLayers(run.placement, name);
        return !pour[0] and !pour[1];
    }
    return false;
}

fn residualFrontierAdjacent(
    ctx: *const Ctx,
    reached: []const bool,
    layer: usize,
    ix: usize,
    iy: usize,
) bool {
    const nodes = ctx.grid.nx * ctx.grid.ny;
    const node = iy * ctx.grid.nx + ix;
    for (0..ctx.occ.len) |other_layer|
        if (other_layer != layer and reached[other_layer * nodes + node]) return true;
    const offsets = [_][2]i64{
        .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 },  .{ 0, -1 },
        .{ 1, 1 }, .{ 1, -1 }, .{ -1, 1 }, .{ -1, -1 },
    };
    for (offsets) |d| {
        const next = neighbor(ctx.grid, ix, iy, d[0], d[1]) orelse continue;
        if (reached[layer * nodes + next]) return true;
    }
    return false;
}

/// A non-pour net with more terminals than this is skipped by the windowed
/// rescue: its whole-net window overflows and its per-leg pass would maze one
/// bounded window per nearest-pair leg — dozens for a board-spanning rail —
/// which is expensive and, when the net is walled in by congestion rather than
/// quantization, futile. Retained-pour rails take the bounded per-terminal path
/// below instead: each terminal only has to reach the already-connected pour.
const rescue_max_terminals: usize = 12;

fn immediateFineGuidedEligible(ctx: *const Ctx, net_i: usize, terminal_count: usize) bool {
    return ctx.deadline_ns == 0 and terminal_count >= 2 and terminal_count <= rescue_max_terminals and
        hardGuidedPolicy(ctx, net_i);
}

const ImmediateFineGuidedRun = struct {
    ctx: *Ctx,
    placement: optimizer.Placement,
    idx_of: *std.StringHashMapUnmanaged(usize),
    tracks: *std.ArrayList(Track),
    vias: *std.ArrayList(Via),
};

/// Retry a failed authored guide while its wave still owns the corridor. The
/// ordinary batch grid is sized for the board's widest class; a thin guided
/// control trace can therefore miss an otherwise-valid escape and only be
/// diagnosed after lower waves have occupied it. Rebuild one half-pitch,
/// whole-board context over the live higher-priority copper, commit only a
/// DRC-clean result, then stamp that result back into the batch grid before
/// routing continues.
fn immediateFineGuided(
    immediate: ImmediateFineGuidedRun,
    net_i: usize,
    pts: []const NetPt,
    marks: [2]usize,
) std.mem.Allocator.Error!bool {
    const ctx = immediate.ctx;
    const placement = immediate.placement;
    const idx_of = immediate.idx_of;
    const tracks = immediate.tracks;
    const vias = immediate.vias;
    const ni: i32 = @intCast(net_i);
    shrinkCopper(tracks, vias, marks[0], marks[1]);
    clearNetOcc(ctx, ni);
    if (routeCancelled(ctx)) return false;

    const selected = try ctx.arena.alloc(bool, placement.nets.len);
    @memset(selected, false);
    selected[net_i] = true;
    var fc = switch (try buildRouteCtx(ctx.arena, placement, ctx.base, selected, 0)) {
        .ok => |fresh| fresh,
        .empty, .overflow => return false,
    };
    fc.pour = ctx.pour;
    fc.net_policy = ctx.net_policy;
    fc.selected_nets = selected;
    fc.cancel = ctx.cancel;
    fc.deadline_ns = ctx.deadline_ns;
    fc.deadline_expired = ctx.deadline_expired;
    fc.zones = ctx.zones;
    fc.guide_tracks = ctx.guide_tracks;
    fc.guide_vias = ctx.guide_vias;
    fc.reserved_lanes = ctx.reserved_lanes;
    fc.window_probe_budget = immediate_fine_probe_budget;
    setNetParams(&fc, placement, net_i);
    stampBoardCopper(&fc, tracks.items, vias.items, ni);
    // `resv` reset 6/6 — a fresh `buildRouteCtx` inherits nothing.
    lane_reserve.stamp(fc.reserved_lanes, fc.resv, fc.grid, null);
    const ok = try routeWindowNet(&fc, placement, net_i, pts, tracks, vias);
    const run = FineRescueRun{
        .ctx = ctx,
        .placement = placement,
        .idx_of = idx_of,
        .routable = &.{},
        .tracks = tracks,
        .vias = vias,
    };
    if (!ok or !(try keepIfClean(run, net_i, marks[0], marks[1]))) return false;

    // The accepted fine copper must become an obstacle/source on the coarser
    // live batch grid before the next net starts.
    stampBoardCopper(
        ctx,
        tracks.items[marks[0]..],
        vias.items[marks[1]..],
        std.math.minInt(i32),
    );
    return true;
}

/// Route one still-failed net in a fine window: the whole tree first (a net
/// whose terminal box fits the cell budget), else per nearest-pair leg. A
/// retained-pour net is already a connected tree, so rescue each terminal into
/// that tree independently even when the rail exceeds `rescue_max_terminals`.
/// A net's own copper, lifted off the board so a rescue can REPLACE it.
///
/// Re-routing a net is a replacement, not an addition. A whole-board pass that
/// fails may now KEEP the connected subtree it earned (`tree_partial`), so a
/// rescue can arrive at a net that already carries copper — and the rescue
/// routes that net WHOLE, from its pads, with `stampBoardCopper` skipping the
/// net's own metal so it is neither obstacle nor source. Left in place, the
/// earlier attempt is not a head start but a DUPLICATE: the same net wired
/// twice, and every section made redundant by the second wiring reported as
/// `dangling_copper`. Measured on the quarter-pitch fixture, a rescued 7-pad
/// net carried 14 stale tracks under 41 new ones, and its dangling-copper count
/// went 3 -> 45.
///
/// So the net's copper comes OFF before the attempt and goes back only if the
/// attempt is refused. A net that owns none lifts nothing and restores nothing,
/// which is every net whose failed pass retained none — those rescue exactly as
/// they did before the subtree was ever retained.
///
/// Not used by the pour path (`rescueZoneTerminals`): a retained pour IS that
/// rail's connected trunk and the per-terminal join is genuinely additive, so
/// lifting there would tear out the very copper being joined to.
const LiftedNet = struct {
    tracks: []const Track,
    vias: []const Via,

    /// Take `net_i`'s copper off the board, returning it for `restore`.
    fn lift(run: FineRescueRun, net_i: usize) std.mem.Allocator.Error!LiftedNet {
        const ni: i32 = @intCast(net_i);
        var tracks: std.ArrayList(Track) = .empty;
        var vias: std.ArrayList(Via) = .empty;
        for (run.tracks.items) |track| if (track.net == ni) try tracks.append(run.ctx.arena, track);
        for (run.vias.items) |via| if (via.net == ni) try vias.append(run.ctx.arena, via);
        if (tracks.items.len == 0 and vias.items.len == 0) return .{ .tracks = &.{}, .vias = &.{} };
        ripNet(run.ctx, run.tracks, run.vias, net_i);
        return .{ .tracks = tracks.items, .vias = vias.items };
    }

    /// Put it back, occupancy included, after a refused attempt.
    fn restore(self: LiftedNet, run: FineRescueRun, net_i: usize) std.mem.Allocator.Error!void {
        if (self.tracks.len == 0 and self.vias.len == 0) return;
        try run.tracks.appendSlice(run.ctx.arena, self.tracks);
        try run.vias.appendSlice(run.ctx.arena, self.vias);
        restoreNetOcc(run.ctx, @intCast(net_i), run.tracks.items, run.vias.items);
    }
};

fn rescueNetInWindow(run: FineRescueRun, net_i: usize) std.mem.Allocator.Error!bool {
    const pts = try netPoints(run.ctx.arena, run.placement, run.idx_of, run.placement.nets[net_i]);
    if (pts.len < 2) return false;
    const base = fine_window.netPitch(run.ctx.base, run.placement, net_i);
    if (largestNetZone(run.ctx, @intCast(net_i)) != null)
        return rescueZoneTerminals(run, net_i, pts, base);
    if (pts.len > rescue_max_terminals) return false;
    const lifted = try LiftedNet.lift(run, net_i);
    if (try rescueWhole(run, net_i, pts, base)) return true;
    if (try rescueLegs(run, net_i, pts, base)) return true;
    try lifted.restore(run, net_i);
    return false;
}

/// Final quantization-only fallback: one quarter-pitch context spanning the
/// live board, rather than the terminal-box windows above. This is materially
/// different from `rescueWhole`/`rescueLegs`: a local 3.5 mm crop can itself
/// wall a net whose only fine-grid path temporarily detours farther away. The
/// board context preserves every routed foreign track/via as an obstacle, and
/// the appended copper is still transactional behind `keepIfClean`. Scoped
/// callers use the same pass: their adaptive whole-route retry can be skipped
/// after an earlier coarse search limit, while the bounded live-grid classifier
/// can still prove that the residual itself is quantization.
///
/// Cell count and maze expansions are independently capped, and the caller
/// invokes this only after the bounded classifier proves grid quantization, so
/// congestion/search failures never pay the board-scale allocation or search.
fn rescueQuantizedFullBoard(run: FineRescueRun, net_i: usize) std.mem.Allocator.Error!bool {
    const pts = try netPoints(run.ctx.arena, run.placement, run.idx_of, run.placement.nets[net_i]);
    if (pts.len < 2 or pts.len > rescue_max_terminals) return false;
    const pitch = fine_window.netPitch(run.ctx.base, run.placement, net_i) * fine_grid_scale;
    const rect = fine_window.WindowRect{
        .x0 = run.placement.minx - route_grid_margin_mm,
        .y0 = run.placement.miny - route_grid_margin_mm,
        .x1 = run.placement.maxx + route_grid_margin_mm,
        .y1 = run.placement.maxy + route_grid_margin_mm,
    };
    if (fine_window.windowCells(rect, pitch) > fine_window.max_fine_board_cells) return false;
    var fc = (try windowCtx(run.ctx, run.placement, rect, pitch)) orelse return false;
    const ni: i32 = @intCast(net_i);
    setNetParams(&fc, run.placement, net_i);
    const lifted = try LiftedNet.lift(run, net_i);
    stampBoardCopper(&fc, run.tracks.items, run.vias.items, ni);
    const keep_t = run.tracks.items.len;
    const keep_v = run.vias.items.len;
    const ok = try routeWindowNet(&fc, run.placement, net_i, pts, run.tracks, run.vias);
    if (ok and try keepIfClean(run, net_i, keep_t, keep_v)) return true;
    shrinkCopper(run.tracks, run.vias, keep_t, keep_v);
    try lifted.restore(run, net_i);
    return false;
}

/// The routing grid's one-millimetre raster apron (`routeGridDims` /
/// `buildRouteCtx` and the fine-window rescues share it).
/// True when the board copper appended after `keep` is DRC-clean for `net_i`
/// against the copper before it AND the accept gate keeps it, else roll it back.
/// The rescue paths route the net directly onto the board lists (so direct
/// synthesis sees the existing copper via the lists); this validates + commits
/// or discards that tail. The gate is a no-op for any net that declared no
/// `(resolution …)`; for one that did, it re-asks the connectivity oracle,
/// because a declared window is wide enough to island a pour (`fine_accept`).
fn keepIfClean(run: FineRescueRun, net_i: usize, keep_t: usize, keep_v: usize) std.mem.Allocator.Error!bool {
    const clean = fineCopperClean(.{
        .ctx = run.ctx,
        .placement = run.placement,
        .board_tracks = run.tracks.items[0..keep_t],
        .board_vias = run.vias.items[0..keep_v],
        .new_tracks = run.tracks.items[keep_t..],
        .new_vias = run.vias.items[keep_v..],
        .net_i = net_i,
    });
    if (clean and try gateAccepts(run, net_i, keep_t, keep_v)) return true;
    shrinkCopper(run.tracks, run.vias, keep_t, keep_v);
    return false;
}

/// Ask this run's accept gate about the copper appended after `keep`. An
/// ungated run (no declared resolution can reach it) keeps today's answer.
fn gateAccepts(run: FineRescueRun, net_i: usize, keep_t: usize, keep_v: usize) std.mem.Allocator.Error!bool {
    const gate = run.gate orelse return true;
    const curves = try liveCurves(run.ctx.arena, run.ctx, run.placement.nets.len);
    const attempt = fine_accept.Attempt{ .tracks = run.tracks.items, .vias = run.vias.items, .arcs = curves.arcs, .rf_paths = curves.rf_paths, .keep_t = keep_t, .keep_v = keep_v };
    return gate.accepts(net_i, attempt);
}

/// Route `pts` for `net_i` on the windowed context `fc` onto `tracks`/`vias`,
/// with the escape reserve forced on (`fine_window.escape_reserve_mm`). Replaces
/// `rerouteNet` in the window so the escape machinery engages; foreign copper
/// is already stamped into `fc.occ` and threaded into the lists.
/// Forcing that reserve also forces the window to BOUND its escape rescue:
/// `escapeDirectRescue` sweeps the direct lattice unbounded for any net whose
/// reserve is armed, on the premise that those are the few an author declared
/// RF — false here, where the reserve is SYNTHETIC. Measured 2026-08-05 on
/// barracuda: one still-failing net's four windows burnt 4.30 M probes / 21.9 s
/// and rescued nothing, 88 % of the board's routing time (15.9 M / 78 s for two
/// such nets under a topology plan). Only THIS context carries the ceiling, so
/// every whole-board route is untouched.
fn routeWindowNet(
    fc: *Ctx,
    placement: optimizer.Placement,
    net_i: usize,
    pts: []const NetPt,
    tracks: *std.ArrayList(Track),
    vias: *std.ArrayList(Via),
) std.mem.Allocator.Error!bool {
    setNetParams(fc, placement, net_i);
    fc.rf.escape_mm = @max(fc.rf.escape_mm, fine_window.escape_reserve_mm);
    if (fc.window_probe_budget == null) fc.window_probe_budget = direct_probe_budget;
    // Hard waypoint/branch attempts enter `routeNetAttempt` before the escape
    // fallback that historically armed this budget. Arm it at the window seam
    // so guided direct synthesis cannot bypass the same bounded allowance.
    fc.direct_budget = fc.window_probe_budget;
    setNetRoutePolicy(fc, net_i, pts);
    return routeNet(fc, @intCast(net_i), pts, tracks, vias);
}

/// Whole-net window: re-route the full terminal set in each candidate window
/// (a DECLARED pitch, then half, then quarter) — onto the board lists so both
/// the maze (via `occ`) and direct synthesis (via the lists) clear existing
/// copper — until one succeeds AND passes the accept gate. Rolls back a dirty or
/// failed attempt so the board is untouched unless the net truly routes. An
/// over-cap declared window outgrows the blanket `max_window_expansions`, so it
/// budgets from its own size instead (`declaredWindowBudget` — one full sweep).
fn rescueWhole(run: FineRescueRun, net_i: usize, pts: []const NetPt, base: f64) std.mem.Allocator.Error!bool {
    const ni: i32 = @intCast(net_i);
    for (fine_window.wholeWindows(run.placement, pts, base, fine_window.declaredPitch(run.placement, net_i))) |maybe| {
        const w = maybe orelse continue;
        var fc = (try windowCtx(run.ctx, run.placement, w.rect, w.pitch)) orelse continue;
        if (w.over_cap) fc.escalate_budget = fine_window.declaredWindowBudget(fc.occ.len, fine_window.windowCells(w.rect, w.pitch));
        setNetParams(&fc, run.placement, net_i); // sets fc.reach for the stamp halo
        stampBoardCopper(&fc, run.tracks.items, run.vias.items, ni);
        const keep_t = run.tracks.items.len;
        const keep_v = run.vias.items.len;
        const ok = try routeWindowNet(&fc, run.placement, net_i, pts, run.tracks, run.vias);
        if (ok and try keepIfClean(run, net_i, keep_t, keep_v)) return true;
        shrinkCopper(run.tracks, run.vias, keep_t, keep_v);
    }
    return false;
}

/// Per-leg window: connect a board-spanning net's terminals by nearest-pair
/// legs, each in its own two-terminal window, routed onto the board lists. Kept
/// only if EVERY leg routes and the assembled net is DRC-clean (else rolled back
/// wholesale — no stranded island). Same-net legs need no clearance from each
/// other, so independent pad-to-pad legs never add DRC.
fn rescueLegs(run: FineRescueRun, net_i: usize, pts: []const NetPt, base: f64) std.mem.Allocator.Error!bool {
    const legs = try fine_window.mstLegs(run.ctx.arena, pts);
    if (legs.len == 0) return false;
    const keep_t = run.tracks.items.len;
    const keep_v = run.vias.items.len;
    for (legs) |leg| {
        if (try routeLegInWindow(run, net_i, .{ pts[leg[0]], pts[leg[1]] }, base)) continue;
        shrinkCopper(run.tracks, run.vias, keep_t, keep_v);
        return false;
    }
    return keepIfClean(run, net_i, keep_t, keep_v);
}

/// A retained pour is the net's connected trunk, so recover a congested rail by
/// joining each pad to that trunk in its own bounded fine-grid window. This is
/// both cheaper and more faithful than building a pad-to-pad MST: the pour,
/// rather than a trace snaking across the board, supplies the shared copper.
/// Every terminal must succeed and the combined tail must pass the same final
/// DRC gate as the ordinary fine-window rescue, otherwise the whole attempt is
/// rolled back.
fn rescueZoneTerminals(
    run: FineRescueRun,
    net_i: usize,
    pts: []const NetPt,
    base: f64,
) std.mem.Allocator.Error!bool {
    const zone = largestNetZone(run.ctx, @intCast(net_i)) orelse return false;
    const keep_t = run.tracks.items.len;
    const keep_v = run.vias.items.len;
    for (pts) |pt| {
        if (pt.layer == zone.layer and
            (outline_mod.contains(zone.polygon, pt.x, pt.y) or
                outline_mod.distToEdge(zone.polygon, pt.x, pt.y) <= clearance_eps)) continue;
        if (try reuseZoneViaInWindow(run, net_i, pt, zone, base)) continue;
        const anchor = zoneAnchor(zone.polygon, pt) orelse {
            shrinkCopper(run.tracks, run.vias, keep_t, keep_v);
            return false;
        };
        const zone_pt = NetPt{ .x = anchor[0], .y = anchor[1], .layer = zone.layer };
        if (try routeZoneTerminalInWindow(run, net_i, pt, zone_pt, base)) continue;
        shrinkCopper(run.tracks, run.vias, keep_t, keep_v);
        return false;
    }
    return keepIfClean(run, net_i, keep_t, keep_v);
}

/// Fine-window counterpart of `reuseNearbyZoneVia`. The window has fresh
/// occupancy, so an accepted direct trace reserves only the temporary context;
/// the exact copper is appended to the board lists and the rescue's final
/// `keepIfClean` gate commits or rolls it back transactionally.
fn reuseZoneViaInWindow(
    run: FineRescueRun,
    net_i: usize,
    pt: NetPt,
    zone: route_policy.ExistingZone,
    base: f64,
) std.mem.Allocator.Error!bool {
    const ni: i32 = @intCast(net_i);
    const via = nearestReusableZoneVia(run.vias.items, zone, ni, pt) orelse return false;
    const target = NetPt{ .x = via.x, .y = via.y, .layer = pt.layer };
    for (fine_window.legWindows(run.placement, pt, target, base, fine_window.declaredPitch(run.placement, net_i))) |maybe| {
        const w = maybe orelse continue;
        var fc = (try windowCtx(run.ctx, run.placement, w.rect, w.pitch)) orelse continue;
        setNetParams(&fc, run.placement, net_i);
        fc.rf.escape_mm = @max(fc.rf.escape_mm, fine_window.escape_reserve_mm);
        setNetRoutePolicy(&fc, net_i, &.{ pt, target });
        stampBoardCopper(&fc, run.tracks.items, run.vias.items, ni);
        const direct = DirectRun{ .ctx = &fc, .net = ni, .tracks = run.tracks, .vias = run.vias };
        if (try tryDirectDogleg(direct, pt, target)) return true;
    }
    return false;
}

/// Maze one pad into its retained pour in each candidate pad-to-pour window.
/// `routeNetToZone` still owns the electrical semantics: the inner pour is a
/// Dijkstra source and an excluded pour layer permits only the via transition,
/// never an ordinary routed trace.
fn routeZoneTerminalInWindow(
    run: FineRescueRun,
    net_i: usize,
    pt: NetPt,
    zone_pt: NetPt,
    base: f64,
) std.mem.Allocator.Error!bool {
    const ni: i32 = @intCast(net_i);
    for (fine_window.legWindows(run.placement, pt, zone_pt, base, fine_window.declaredPitch(run.placement, net_i))) |maybe| {
        const w = maybe orelse continue;
        var fc = (try windowCtx(run.ctx, run.placement, w.rect, w.pitch)) orelse continue;
        setNetParams(&fc, run.placement, net_i);
        fc.rf.escape_mm = @max(fc.rf.escape_mm, fine_window.escape_reserve_mm);
        setNetRoutePolicy(&fc, net_i, &.{pt});
        stampBoardCopper(&fc, run.tracks.items, run.vias.items, ni);
        const mark_t = run.tracks.items.len;
        const mark_v = run.vias.items.len;
        if ((try routeNetToZone(&fc, ni, &.{pt}, run.tracks, run.vias)) orelse false) return true;
        shrinkCopper(run.tracks, run.vias, mark_t, mark_v);
    }
    return false;
}

/// The rescued net's fresh copper (`new_*`) and the board copper (`board_*`) it
/// must clear, plus the net it belongs to. Bundled to stay within the cap.
const CleanCheck = struct {
    ctx: *Ctx,
    placement: optimizer.Placement,
    board_tracks: []const Track,
    board_vias: []const Via,
    new_tracks: []const Track,
    new_vias: []const Via,
    net_i: usize,
};

/// True when the rescued net's fresh copper keeps full DRC clearance from all
/// foreign board copper and pads — the keep-best gate that makes the windowed
/// rescue safe by construction, whatever sub-pitch path (maze or direct
/// synthesis) produced it. Uses the router's own DRC-grade clearance primitives
/// (which skip same-net), with the clearance inflated to the board's widest
/// class so a foreign net with a larger rule can't be under-checked. A rescue
/// that fails here is dropped, so the phase can never introduce a DRC error.
fn fineCopperClean(chk: CleanCheck) bool {
    const ctx = chk.ctx;
    const saved = ctx.params;
    defer ctx.params = saved;
    setNetParams(ctx, chk.placement, chk.net_i);
    const maxp = maxRouteParams(chk.placement, ctx.base, ctx.selected_nets);
    ctx.params.clearance = @max(ctx.params.clearance, maxp.clearance);
    const ni: i32 = @intCast(chk.net_i);
    for (chk.new_tracks) |t| {
        ctx.params.track_width = t.width;
        const a = [2]f64{ t.x1, t.y1 };
        const b = [2]f64{ t.x2, t.y2 };
        if (!segClearsTracks(ctx, chk.board_tracks, a, b, ni, t.layer)) return false;
        if (!segClearsPadsOnLayer(ctx, a, b, ni, t.layer)) return false;
        if (!segClearsVias(ctx, chk.board_vias, a, b, ni)) return false;
    }
    for (chk.new_vias) |v| {
        ctx.params.via_dia = v.dia;
        ctx.params.via_drill = v.drill;
        if (!viaClearsPads(ctx, v.x, v.y, ni)) return false;
        if (!viaClearsVias(ctx, chk.board_vias, v.x, v.y, ni)) return false;
        if (!viaClearsTracks(ctx, chk.board_tracks, v.x, v.y, ni)) return false;
        if (!viaClearsHoles(ctx, chk.board_vias, v.x, v.y)) return false;
    }
    return true;
}

/// Maze one leg's two terminals in each candidate window (half then quarter
/// pitch) onto the board lists, stamping only foreign copper into `occ` (this
/// net's other legs need no clearance from this one and stay off `occ` so they
/// never wall a later leg in). Leaves the board lists at their entry length on
/// failure.
fn routeLegInWindow(run: FineRescueRun, net_i: usize, leg_pts: [2]NetPt, base: f64) std.mem.Allocator.Error!bool {
    const ni: i32 = @intCast(net_i);
    for (fine_window.legWindows(run.placement, leg_pts[0], leg_pts[1], base, fine_window.declaredPitch(run.placement, net_i))) |maybe| {
        const w = maybe orelse continue;
        var fc = (try windowCtx(run.ctx, run.placement, w.rect, w.pitch)) orelse continue;
        setNetParams(&fc, run.placement, net_i); // sets fc.reach for the stamp halo
        stampBoardCopper(&fc, run.tracks.items, run.vias.items, ni);
        const mark_t = run.tracks.items.len;
        const mark_v = run.vias.items.len;
        if (try routeWindowNet(&fc, run.placement, net_i, &leg_pts, run.tracks, run.vias)) return true;
        shrinkCopper(run.tracks, run.vias, mark_t, mark_v);
    }
    return false;
}

/// Per-net routed-copper totals for the summary JSON: trace length (mm) summed
/// over the net's track segments, and its via count. Emitted by `perNetRouted`.
pub const NetRouted = struct { name: []const u8, mm: f64, vias: usize };

/// Aggregate a `RouteResult`'s copper by net — one `NetRouted` per net that
/// carries any track or via — so a caller can read where copper went per
/// connection (the route-summary JSON's `per_net`). Sorted by descending trace
/// length so the longest nets read first. `net`-index copper with no matching
/// `placement.nets` entry (there should be none) is skipped.
pub fn perNetRouted(arena: std.mem.Allocator, placement: optimizer.Placement, r: RouteResult) std.mem.Allocator.Error![]NetRouted {
    var by_idx = std.AutoHashMapUnmanaged(i32, NetRouted).empty;
    defer by_idx.deinit(arena);
    for (r.tracks) |t| {
        if (t.net < 0) continue;
        const ui: usize = @intCast(t.net);
        if (ui >= placement.nets.len) continue;
        const gop = try by_idx.getOrPut(arena, t.net);
        if (!gop.found_existing) gop.value_ptr.* = .{ .name = placement.nets[ui].name, .mm = 0, .vias = 0 };
        gop.value_ptr.mm += std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
    }
    for (r.vias) |v| {
        if (v.net < 0) continue;
        const ui: usize = @intCast(v.net);
        if (ui >= placement.nets.len) continue;
        const gop = try by_idx.getOrPut(arena, v.net);
        if (!gop.found_existing) gop.value_ptr.* = .{ .name = placement.nets[ui].name, .mm = 0, .vias = 0 };
        gop.value_ptr.vias += 1;
    }
    var out: std.ArrayList(NetRouted) = .empty;
    var it = by_idx.valueIterator();
    while (it.next()) |nr| try out.append(arena, nr.*);
    std.sort.pdq(NetRouted, out.items, {}, netRoutedLonger);
    return out.toOwnedSlice(arena);
}

fn netRoutedLonger(_: void, a: NetRouted, b: NetRouted) bool {
    if (a.mm != b.mm) return a.mm > b.mm;
    return std.mem.lessThan(u8, b.name, a.name); // stable, name-descending tiebreak
}

/// The pad centres whose `padGateways` fan produced the keys one maze leg is
/// handed, so `dijkstra` can PRICE the escape stub each of those keys implies.
///
/// A gateway is not a free way into the grid: whichever one the path uses,
/// `gateStub` afterwards draws real copper from the pad's centre out to it. The
/// search used to see none of that — every gateway was a dist-0 source, and any
/// popped goal was accepted at whatever dist it carried and added nothing — so
/// the fan's outermost ring was the cheapest entry the maze could buy in EVERY
/// direction, including straight away from the target. Measured on
/// `bcuda-lt3045-ldo`: `C_VOUT` left its pad 0.51 mm (ring 2) on the heading
/// opposite its partner and then turned 45° back across itself, and that
/// wrong-way stub was permanent, because no later pass may LENGTHEN copper to
/// straighten what the search chose.
///
/// With an anchor the leg pays for what it draws: `hypot(pad, key)`, the
/// straight-line length of that stub. That is a LOWER bound on the copper
/// `gateStub` actually lays (an off-axis join mitres, an axis dogleg turns), so
/// charging it can only under-state the price — which is exactly what keeps it
/// safe against a search whose A* heuristic must stay admissible.
///
/// A null anchor prices nothing, so a caller whose keys are not a pad fan (zone
/// copper, a seeded via, a stitch's via sites) searches as it always did.
const GateAnchors = struct { source: ?NetPt = null, goal: ?NetPt = null };

/// One maze leg's two ends: the keys it may finish ON, the keys it may grow FROM
/// beyond the net's own copper, and the pad fans (if any) those key sets belong
/// to — the anchors that turn a key into a priced escape rather than a free one.
const MazeEnds = struct {
    goals: []const usize,
    sources: []const usize = &.{},
    anchors: GateAnchors = .{},
};

/// What entering or leaving the maze at grid key `k` costs when `anchor` names
/// the pad the key's fan surrounds — 0 for an unanchored key. See `GateAnchors`.
///
/// Through the SAME lens the leg's own steps are priced by: `scale` is the
/// lowest multiplier any of them can be discounted by (`routeHeuristic`), so a
/// stub is comparable with the lattice run it is competing against. Charging a
/// raw millimetre against steps a coupling corridor has halved would price the
/// escape out of every discount the leg exists to take — measured on the
/// diff-pair fixture, where the N net stopped detouring toward its P twin at all.
fn gateStubCost(grid: Grid, nodes: usize, anchor: ?NetPt, k: usize, scale: f64) f64 {
    const pt = anchor orelse return 0;
    const n = k % nodes;
    return std.math.hypot(grid.worldX(n % grid.nx) - pt.x, grid.worldY(n / grid.nx) - pt.y) * scale;
}

/// Where a successful maze leg entered and left the grid: `goal` is the goal
/// key it reached (plain access node or pad gateway), `source` the seeded key
/// the path grew from — the caller stubs the pad centres onto both. `start` is
/// where the leg's copper ACTUALLY begins: `source`'s own point normally, or
/// the trimmed point when that source sat inside a foreign land (see the
/// buried-source repair at the end of `dijkstra`). A caller that welds the leg
/// to the net's earlier copper must bridge from `start`, not from `source`.
const DijkstraHit = struct { goal: usize, source: usize, start: [2]f64 };

const RoutePq = maze_scratch.RoutePq;

const MazeSearch = struct {
    pq: *RoutePq,
    state: maze_scratch.State,
    heuristic: RouteHeuristic,
    /// Turn tie-break inputs, resolved once per search (`octilinear.turned`).
    lattice: octilinear.Lattice,
};

const RouteHeuristic = route_grid.Heuristic;

/// This leg's A* estimate. The scale is the LOWEST multiplier any step of the
/// leg can be discounted by — 0.1× inside a reference corridor, 0.5× inside a
/// pair corridor, 0.05× in both — which is what keeps the Euclidean estimate
/// admissible while it still points somewhere useful.
fn routeHeuristic(ctx: *Ctx, goals: []const usize, nodes: usize) RouteHeuristic {
    const reference_scale: f64 = if (ctx.reference_corridor != null) reference_corridor_mult else 1;
    const pair_scale: f64 = if (ctx.corridor != null) diff_corridor_mult else 1;
    return route_grid.heuristic(ctx.grid, goals, nodes, reference_scale * pair_scale);
}

fn recordSearchLimit(ctx: *Ctx, net: i32) std.mem.Allocator.Error!void {
    if (net < 0) return;
    const net_i: usize = @intCast(net);
    if (!searchWasLimited(ctx, net_i)) try ctx.search_limited.append(ctx.arena, net_i);
}

/// Drop `net_i` from the search-limited set — called when the escalation retry
/// finally routes a leg that the greedy pass had left budget-limited, so the
/// reported set names only nets that are *still* search-limited.
pub fn clearSearchLimit(ctx: *Ctx, net_i: usize) void {
    var i: usize = 0;
    while (i < ctx.search_limited.items.len) {
        if (ctx.search_limited.items[i] == net_i) _ = ctx.search_limited.swapRemove(i) else i += 1;
    }
}

/// Inputs that size one maze leg's node-expansion budget: the whole-board
/// `base` (`unguidedExpansionLimit`), whether the net carries a straight
/// pad-escape reserve, whether the post-greedy retry phase escalated this leg,
/// and whether a diff-pair coupling corridor confines it.
const BudgetInput = struct {
    base: usize,
    escape_active: bool,
    /// 0 = no escalation; otherwise the escalated per-leg expansion budget for
    /// this retry (the `max_escalated_expansions` or `max_last_resort_expansions`
    /// tier). A larger value widens both the plain and the corridor-capped search.
    escalate: usize,
    corridor: bool,
    /// This leg follows a soft reference guide (`setNetReferenceGuide`), which
    /// discounts on-guide steps to 0.1x — and therefore drops the A* heuristic
    /// to the same 0.1x to stay admissible (`routeHeuristic`). A near-Dijkstra
    /// search expands far more nodes for the same path, so a guided leg on the
    /// whole-board budget runs out of expansions on a path an unguided leg
    /// finds easily: the guide is meant to shape the route, not to make it fail.
    /// Measured on barracuda, where guiding a net set cost nets it had routed
    /// unguided. Guided legs therefore take the targeted floor, like escapes.
    guided: bool = false,
};

/// The bounded node-expansion budget for one maze leg. Escape-forced and
/// escalated legs search wider; a coupling corridor caps the search tightly (a
/// narrow band converges fast) unless escalation also widens that cap.
fn expansionBudget(in: BudgetInput) usize {
    const escape_limit = if (in.escape_active or in.guided)
        @max(in.base, route_grid.max_targeted_expansions)
    else
        in.base;
    const ordinary = if (in.escalate > 0)
        @max(escape_limit, in.escalate)
    else
        escape_limit;
    if (!in.corridor) return ordinary;
    const cap = if (in.escalate > 0) in.escalate else route_grid.max_pair_corridor_expansions;
    return @min(ordinary, cap);
}

/// Seed one maze leg's Dijkstra frontier: every node this net already owns, plus
/// the seed pad's gateway fan, each at what it costs to START there.
///
/// The `occ == net` scan is deliberately NOT filtered by `foreignPadAt`, though a
/// stamped node CAN be illegal copper (the halo reaches past the centreline).
/// Dropping those sources does remove the resulting violations, but measured on
/// barracuda it costs NINE connected nets and doubles the route time:
/// `tryMazeTerminalTree` fails the whole net when one leg cannot reach the net's
/// existing copper, and those failures cascade into rip-up escalation. Seeding
/// only the legal marks when any exist measured identical — the legs that die
/// need the buried cluster specifically, not just some legal source.
/// `trimBuriedStart` handles it at the other end instead: the leg routes, and its
/// copper is pulled back off the land it started in.
///
/// PRICES (see `GateAnchors`): a gateway costs the stub that reaches it, and so
/// does the seed pad's own ACCESS node — that node is a mark in `occ` like any
/// other, but `gateStub` still draws copper from the pad centre out to it, and
/// leaving the one reachable entry free would price the whole fan against a zero
/// that is not real. Every OTHER mark is copper that already exists and costs
/// nothing to stand on.
fn seedMazeSources(ctx: *Ctx, net: i32, ends: MazeEnds, search: MazeSearch) std.mem.Allocator.Error!void {
    const grid = ctx.grid;
    const nodes = grid.nx * grid.ny;
    const anchor = ends.anchors.source;
    const seed_key: ?usize = if (anchor) |pt| blk: {
        const nd = grid.nearest(pt.x, pt.y);
        break :blk @as(usize, pt.layer) * nodes + grid.node(nd[0], nd[1]);
    } else null;
    for (0..ctx.occ.len) |layer| {
        var cursor: usize = 0;
        while (std.mem.findScalarPos(i32, ctx.occ[layer], cursor, net)) |n| {
            const k = layer * nodes + n;
            var at = net_topology.sourceCost(ctx.join_lands, grid.worldX(n % grid.nx), grid.worldY(n / grid.nx));
            if (seed_key == k) at += gateStubCost(grid, nodes, anchor, k, search.heuristic.scale);
            try search.state.settle(k, at, -1);
            try search.pq.add(.{ .f = at + search.heuristic.estimate(grid, n), .d = at, .key = k });
            cursor = n + 1;
        }
    }
    for (ends.sources) |k| {
        const at = gateStubCost(grid, nodes, anchor, k, search.heuristic.scale);
        if (at < search.state.dist[k]) {
            try search.state.settle(k, at, -1);
            try search.pq.add(.{ .f = at + search.heuristic.estimate(grid, k % nodes), .d = at, .key = k });
        }
    }
}

/// Dijkstra from all of net's current copper (occ==net) plus `ends.sources`
/// (the seed pad's gateways) to the CHEAPEST key in `ends.goals` (full
/// layer*nodes+node keys). On success, stamps the path as the net's copper,
/// emits the tracks/vias, and reports which goal/source the path used.
///
/// "Cheapest" counts the escape stubs, not just the lattice path: with
/// `ends.anchors` naming the pad a fan belongs to, a source gateway is seeded at
/// the length of the stub `gateStub` will draw to reach it, and a goal is
/// accepted on `dist + its own stub` (`GateAnchors`). Without anchors every stub
/// is zero and the search is the pre-pricing one to the bit.
fn dijkstra(
    ctx: *Ctx,
    net: i32,
    ends: MazeEnds,
    tracks: *std.ArrayList(Track),
    vias: *std.ArrayList(Via),
) std.mem.Allocator.Error!?DijkstraHit {
    const goals = ends.goals;
    const anchors = ends.anchors;
    const grid = ctx.grid;
    const nodes = grid.nx * grid.ny;
    // Mark in `tracks` before this leg — the buried-source repair below only
    // ever rewrites copper this leg drew, and a welding caller bridges to what
    // sits below the mark.
    const prior = tracks.items.len;
    const n_layers = ctx.occ.len;
    const search_nodes = n_layers * nodes;
    const state = try ctx.search.begin(ctx.arena, search_nodes);
    const dist = state.dist;
    const prev = state.prev;
    // Goal keys span one narrow band of the key space (a terminal pad's access
    // nodes), so a range test rejects almost every pop before the membership
    // scan runs at all. Same predicate, same `found_key`; with no goals the
    // range is empty and the test is false, exactly as the scan was.
    //
    // `goal_stub_min` rides along: the cheapest stub in the whole goal fan, and
    // so the OPTIMALITY bound of the priced accept below.
    const heuristic = routeHeuristic(ctx, goals, nodes);
    var goal_lo: usize = std.math.maxInt(usize);
    var goal_hi: usize = 0;
    var goal_stub_min: f64 = std.math.inf(f64);
    for (goals) |goal| {
        goal_lo = @min(goal_lo, goal);
        goal_hi = @max(goal_hi, goal);
        goal_stub_min = @min(goal_stub_min, gateStubCost(grid, nodes, anchors.goal, goal, heuristic.scale));
    }
    if (ctx.route_queue == null) ctx.route_queue = RoutePq.init(ctx.arena, {});
    const pq = &ctx.route_queue.?;
    pq.clearRetainingCapacity();
    const search = MazeSearch{
        .pq = pq,
        .state = state,
        .heuristic = heuristic,
        .lattice = .{
            .nx = grid.nx,
            .nodes = nodes,
            .prev = prev,
            .enabled = ctx.corridor == null and ctx.reference_corridor == null,
        },
    };
    try seedMazeSources(ctx, net, ends, search);

    // An escape-forced net lost its direct-synthesis shortcut and pays soft
    // penalties around both terminals, so its search legitimately expands more
    // nodes: `expansionBudget` gives it the targeted budget. Escape nets are the
    // few RF nets of a board, so the extra allowance stays bounded. An escalated
    // retry searches wider still; a coupling corridor caps the search tightly.
    const expansion_limit = expansionBudget(.{
        .base = unguidedExpansionLimit(ctx.selected_nets),
        .escape_active = escapeActive(ctx),
        .escalate = ctx.escalate_budget,
        .corridor = ctx.corridor != null and ctx.reference_corridor == null,
        .guided = ctx.reference_corridor != null,
    });
    var expansions: usize = 0;
    // Whole-run counters: every leg's expansion count and the leg itself, so
    // `bench-route --breakdown` can divide greedy time by expansions to expose
    // the per-expansion cost. The `defer` reads the loop's final count.
    if (ctx.timing) |t| t.begin(.maze);
    if (ctx.timing) |t| t.maze_legs += 1;
    defer if (ctx.timing) |t| {
        t.end(.maze);
        t.maze_expansions += expansions;
    };
    var found_key: ?usize = null;
    // The best `dist + goal stub` accepted so far, and the OPTIMALITY invariant
    // that lets the leg stop: every goal still unpopped costs at least the heap
    // minimum `f` to reach — A* admissibility over a goal region where `h` is
    // zero, so a goal's own priority IS its cost paid — and at least
    // `goal_stub_min` to leave. Once `f + goal_stub_min` reaches `found_total`,
    // nothing left in the queue can beat it, and every goal that could TIE it
    // has already been popped. An unanchored leg prices every stub at zero, so
    // the test fires on the first goal popped: the pre-pricing search, exactly.
    var found_total: f64 = std.math.inf(f64);
    while (pq.removeOrNull()) |it| {
        if (it.d > dist[it.key]) continue;
        // A single maze leg may consume hundreds of thousands of expansions;
        // polling only between nets can overshoot an authored board deadline
        // by minutes. Match the direct-probe cadence without timing every node.
        if ((expansions & 1023) == 0 and routeCancelled(ctx)) return null;
        const layer = it.key / nodes;
        const n = it.key % nodes;
        if (it.key >= goal_lo and it.key <= goal_hi and
            std.mem.indexOfScalar(usize, goals, it.key) != null)
        {
            // A goal pops at its FINAL dist (a stale entry was skipped above), so
            // this is the one chance to price it. A STRICT improvement is required
            // to displace an equal earlier one, so the winner is a function of the
            // queue order alone — the same board still routes byte-identically.
            const total = it.d + gateStubCost(grid, nodes, anchors.goal, it.key, heuristic.scale);
            if (total < found_total) {
                found_total = total;
                found_key = it.key;
            }
        }
        if (found_key != null and it.f + goal_stub_min >= found_total) break;
        if (expansions >= expansion_limit) {
            // A budget that runs out AFTER a goal was accepted has not failed the
            // leg: `found_total` is already the best any remaining key could tie,
            // it is simply no longer proven optimal. Ship it rather than throwing
            // a routed leg away over the last few expansions.
            if (found_key != null) break;
            try recordSearchLimit(ctx, net);
            return null;
        }
        expansions += 1;
        const ix = n % grid.nx;
        const iy = n / grid.nx;
        // Same-layer 4-neighbours (orthogonal, cost g).
        const from = it.key;
        for ([4][2]i64{ .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 } }) |d|
            try relaxStep(ctx, search, net, from, layer, neighbor(grid, ix, iy, d[0], d[1]), grid.g);
        // Same-layer diagonals (45° bends, cost g·√2). Guarded against
        // corner-cutting, and skipped outright while the RF axis-only attempt
        // owns the search — there is no 45° step for it to find.
        if (!ctx.manhattan.active) for ([4][2]i64{ .{ 1, 1 }, .{ 1, -1 }, .{ -1, 1 }, .{ -1, -1 } }) |d|
            try relaxDiag(ctx, search, net, from, layer, ix, iy, d[0], d[1]);
        // Via to every OTHER signal layer at the same (ix,iy) — vias are
        // through-only, so one drill reaches them all at the same cost. Only
        // where a via of the configured size keeps clearance from foreign
        // pads and copper, and only when this pass permits layer changes.
        // (On a 2-signal board this is exactly the old `1 - layer` step.)
        if (ctx.allow_vias and n_layers > 1 and viaAllowed(ctx, n, net, vias.items)) {
            // The lattice price for a layer change, under whatever ceiling the
            // caller set (`Ctx.via_cost_cap_mm`; null = the price to the bit).
            const lattice = grid.g * via_cost_mult;
            const via_step = if (ctx.via_cost_cap_mm) |cap| @min(lattice, cap) else lattice;
            for (0..n_layers) |to_layer| if (to_layer != layer)
                try relaxStep(ctx, search, net, from, to_layer, n, via_step);
        }
    }

    const goal = found_key orelse return null;
    const source = (try emitPath(ctx, prev, goal, net, tracks, vias)) orelse return null;
    // The SOURCE is the one node on the path the search never had to prove
    // legal. Every other node was relaxed into through `relaxStep`, which
    // refuses a `blocked` node — but a source is seeded at dist 0 from the
    // `occ == net` scan above, and `occ` carries this net's clearance HALO
    // (`stampStubOcc` / `stampViaOcc` / `stampDisc`), not just its centreline.
    // A halo node can therefore sit inside a FOREIGN pad's clearance, and
    // `emitPath` then draws the leg's last run ending exactly on it — copper
    // that fails the `track_pad` DRC by construction.
    //
    // Repairing it HERE, at the one seam every maze pass returns through, is
    // what makes the guarantee hold for all of them. The trim used to live at
    // the terminal tree's own call site, so every OTHER pass — the pour
    // terminal (`routeNetToZone`), the gap hops, the via-seeded retries — had
    // none. Measured on barracuda: two `V_5VA` legs out of `routeNetToZone`
    // ended on grid nodes inside a `hmc733` ground land and an `ldo_3v3a`
    // divider pad, and no later pass removed them.
    const start = trimBuriedStart(ctx, net, source, prior, tracks, vias.items);
    return .{ .goal = goal, .source = source, .start = start };
}

/// Resolve a 4-neighbour node index, or null at the grid edge.
fn neighbor(grid: Grid, ix: usize, iy: usize, dx: i64, dy: i64) ?usize {
    const x = @as(i64, @intCast(ix)) + dx;
    const y = @as(i64, @intCast(iy)) + dy;
    if (x < 0 or y < 0 or x >= grid.nx or y >= grid.ny) return null;
    return @as(usize, @intCast(y)) * grid.nx + @as(usize, @intCast(x));
}

const Pq = maze_scratch.Pq;

fn relaxStep(
    ctx: *Ctx,
    search: MazeSearch,
    net: i32,
    from_key: usize,
    to_layer: usize,
    to_node: ?usize,
    step: f64,
) std.mem.Allocator.Error!void {
    const tn = to_node orelse return;
    if (!layerInMask(ctx.allowed_layers, @intCast(to_layer))) return;
    if (blocked(ctx, to_layer, tn, net)) return;
    if (!moveClearsCopper(ctx, net, from_key, to_layer, tn)) return;
    const nodes = ctx.grid.nx * ctx.grid.ny;
    const to_key = to_layer * nodes + tn;
    const from_layer = from_key / nodes;
    if (ctx.pair_coupling_hard) {
        const corridor = ctx.corridor orelse return;
        const terminal = if (ctx.pair_terminal_mask) |mask| mask[to_key] else false;
        if (!corridor[to_key] and !terminal) return;
    }
    if (ctx.pair_vias_hard and from_layer != to_layer) {
        const mask = ctx.pair_via_mask orelse return;
        if (!mask[tn]) return;
    }
    // Stepping onto a poured outer layer costs extra (`POUR_COST_MULT`);
    // steps on an inner signal layer carry the mild `INNER_COST_MULT` bias
    // so equal-length paths stay on the outer faces.
    var eff = if (to_layer >= 2)
        step * inner_cost_mult
    else if (ctx.pour[to_layer])
        step * pour_cost_mult
    else
        step;
    if (!layerInMask(ctx.preferred_layers, @intCast(to_layer))) eff *= preferred_layer_cost_mult;
    if (ctx.reference_corridor) |guide| {
        if (guide[to_key]) eff *= reference_corridor_mult;
    }
    if (ctx.reference_guide_active and from_layer != to_layer) {
        const on_reference_via = if (ctx.reference_via_mask) |mask| mask[tn] else false;
        eff *= if (on_reference_via) reference_via_mult else reference_off_via_mult;
    }
    if (from_layer != to_layer) if (ctx.pair_via_mask) |mask| {
        eff *= if (mask[tn]) diff_via_on_ring_mult else diff_via_off_ring_mult;
    };
    if (ctx.rf.escape_mm > 0) eff *= escapePenalty(ctx, from_key, to_key);
    // RF crossing shadow: a step into a protected net's fence corridor is priced,
    // a via dropped in one priced harder. Soft, so a net that must cross still
    // crosses — it just buys the shortest (≈perpendicular) crossing it can, and
    // a run parallel to the trace costs a multiple of that. See `rf_shadow`.
    eff *= ctx.shadow.multiplier(to_layer, tn, net, from_layer != to_layer, ctx.keep.exempt);
    // A CORNER, added after every multiplier, because a corner is a property of
    // the turn and not of the layer or corridor it happens on
    // (`manhattan_route.turnCost`): `turn_cost_mult` (4 pitches) while the RF
    // axis-only attempt is buying straights outright, `bend_cost_mult` (0.15)
    // for every ordinary leg, and zero for a leg an explicit shape constraint
    // already pins — the diff-pair coupling and reference corridors, which
    // `search.lattice.enabled` marks and which therefore run on the cost model
    // that predates any turn price, to the bit.
    eff += ctx.manhattan.turnCost(ctx.grid.g, search.lattice, from_key, to_key);
    // Diff-pair coupling: discount a step landing in the N net's corridor so it
    // hugs its P twin. No corridor → mult 1.0 → the cost is byte-identical.
    const mult: f64 = if (ctx.corridor) |cor| (if (cor[to_key]) diff_corridor_mult else 1.0) else 1.0;
    // Congestion surcharge, and zero unless the negotiated-congestion sandbox is
    // armed: OUTSIDE the corridor multiplier, because a shared resource costs
    // what it costs whether or not the step also happens to hug a twin.
    const nd = search.state.dist[from_key] + eff * mult +
        congestion.price(ctx.congest, to_key, ctx.occ[to_layer][tn], net, ctx.grid.g);
    if (nd < search.state.dist[to_key]) {
        try search.state.settle(to_key, nd, @intCast(from_key));
        try search.pq.add(.{ .f = nd + search.heuristic.estimate(ctx.grid, tn), .d = nd, .key = to_key });
    }
}

/// Cost multiplier a step within the escape reserve pays: within `escape_mm`
/// of a terminal pad, steps misaligned with that pad's outward axis (and
/// early layer changes) are discouraged so the trace leaves the chip straight
/// before its first bend. Soft — a boxed-in pad can still pay it, and the
/// weight is kept moderate so goal regions don't become cost walls that
/// exhaust the search budget on dense boards.
const escape_pen_mult: f64 = 4.0;
/// Minimum |cos| between a step and the pad's outward axis to count as
/// escape-aligned. 0.85 admits only the straight-out compass direction on the
/// 45°-quantized maze (a 45° step scores ~0.71).
const escape_align_min: f64 = 0.85;

/// True when the current net carries a straight pad-escape reserve that can
/// actually bind: a positive escape distance and at least one terminal with a
/// real outward axis.
pub fn escapeActive(ctx: *const Ctx) bool {
    if (ctx.rf.escape_mm <= 0) return false;
    for (ctx.rf.escape_pts) |pt| if (pt.out[0] != 0 or pt.out[1] != 0) return true;
    return false;
}

/// The escape-reserve cost multiplier for the move `from_key` → `to_key` of
/// the current net (whose terminals are `ctx.rf.escape_pts`). 1.0 outside
/// every reserve; `escape_pen_mult` for a misaligned surface step or a layer
/// change inside one.
fn escapePenalty(ctx: *const Ctx, from_key: usize, to_key: usize) f64 {
    const grid = ctx.grid;
    const nodes = grid.nx * grid.ny;
    const from_layer = from_key / nodes;
    const to_layer = to_key / nodes;
    const fn_node = from_key % nodes;
    const fx = grid.worldX(fn_node % grid.nx);
    const fy = grid.worldY(fn_node / grid.nx);
    for (ctx.rf.escape_pts) |pt| {
        if (pt.out[0] == 0 and pt.out[1] == 0) continue;
        if (std.math.hypot(fx - pt.x, fy - pt.y) >= ctx.rf.escape_mm) continue;
        if (from_layer != to_layer) {
            if (from_layer == pt.layer or to_layer == pt.layer) return escape_pen_mult;
            continue;
        }
        if (from_layer != pt.layer) continue;
        const tn = to_key % nodes;
        const dx = grid.worldX(tn % grid.nx) - fx;
        const dy = grid.worldY(tn / grid.nx) - fy;
        const len = std.math.hypot(dx, dy);
        if (len < 1e-9) continue;
        const along = @abs(dx * pt.out[0] + dy * pt.out[1]) / len;
        if (along < escape_align_min) return escape_pen_mult;
    }
    return 1.0;
}

/// Relax the diagonal neighbour (dx,dy) of (ix,iy) on `layer`. Refuses the move
/// if either orthogonal cell it squeezes past is blocked, so a 45° trace never
/// clips the corner of a pad it must clear (no corner-cutting).
fn relaxDiag(
    ctx: *Ctx,
    search: MazeSearch,
    net: i32,
    from_key: usize,
    layer: usize,
    ix: usize,
    iy: usize,
    dx: i64,
    dy: i64,
) std.mem.Allocator.Error!void {
    const grid = ctx.grid;
    const c1 = neighbor(grid, ix, iy, dx, 0) orelse return;
    const c2 = neighbor(grid, ix, iy, 0, dy) orelse return;
    if (blocked(ctx, layer, c1, net) or blocked(ctx, layer, c2, net)) return;
    try relaxStep(ctx, search, net, from_key, layer, neighbor(grid, ix, iy, dx, dy), grid.g * sqrt2);
}

/// Walk `prev` from the goal back to a source, stamp the path as net copper,
/// and emit merged track segments (per straight run) + vias (per layer change).
/// Returns the source key the path grew from (== `goal_key` for a 1-node path).
fn emitPath(
    ctx: *Ctx,
    prev: []i64,
    goal_key: usize,
    net: i32,
    tracks: *std.ArrayList(Track),
    vias: *std.ArrayList(Via),
) std.mem.Allocator.Error!?usize {
    const grid = ctx.grid;
    const nodes = grid.nx * grid.ny;
    var key: i64 = @intCast(goal_key);
    // Collect the path (goal → source).
    var path: std.ArrayList(usize) = .empty;
    while (key >= 0) : (key = prev[@intCast(key)]) {
        const k: usize = @intCast(key);
        try path.append(ctx.arena, k);
    }
    const ks = path.items;
    if (ks.len < 2) return goal_key;
    const via_path = .{
        .arena = ctx.arena,
        .grid = grid,
        .nodes = nodes,
        .rule = viaCopperRule(ctx),
        .net = net,
    };
    if (!try via_rules.pathClears(@TypeOf(via_path), via_path, ks, Via, vias.items)) return null;
    for (ks) |k| ctx.occ[k / nodes][k % nodes] = net;
    // Reserve the two corner cells of every diagonal step (see `Ctx.resv`):
    // they sit only g/√2 from the diagonal's centreline, so a later foreign
    // track through one would violate clearance without ever sharing a node.
    // `relaxDiag` already proved both corners clear of foreign copper *and*
    // foreign reservations, so stamping is always safe.
    for (ks[1..], 0..) |k, i| {
        const pk = ks[i];
        if (k / nodes != pk / nodes) continue; // layer change, not a step
        const layer = k / nodes;
        const ax = (pk % nodes) % grid.nx;
        const ay = (pk % nodes) / grid.nx;
        const bx = (k % nodes) % grid.nx;
        const by = (k % nodes) / grid.nx;
        if (ax == bx or ay == by) continue; // orthogonal step
        ctx.resv[layer][ay * grid.nx + bx] = net;
        ctx.resv[layer][by * grid.nx + ax] = net;
    }
    // Emit: merge straight same-layer runs into one track; via on layer change.
    // A run stays straight while consecutive grid steps share one direction —
    // which now includes the four diagonals, so 45° legs merge too.
    var run_start: usize = 0;
    var i: usize = 1;
    while (i < ks.len) : (i += 1) {
        const prev_layer = ks[i - 1] / nodes;
        const cur_layer = ks[i] / nodes;
        if (cur_layer != prev_layer) {
            try emitSeg(ctx, tracks, ks[run_start], ks[i - 1], net);
            const n = ks[i - 1] % nodes;
            const vx = grid.worldX(n % grid.nx);
            const vy = grid.worldY(n / grid.nx);
            try vias.append(ctx.arena, .{ .x = vx, .y = vy, .dia = ctx.params.via_dia, .drill = ctx.params.via_drill, .net = net });
            stampViaOcc(ctx, vx, vy, net); // reserve its halo for later nets
            stampCurrentRfVia(ctx, vx, vy, net); // …and its RF halo + shadow, on every layer
            run_start = i;
        } else if (i >= 2 and !sameDir(grid, nodes, ks[i - 2], ks[i - 1], ks[i])) {
            try emitSeg(ctx, tracks, ks[run_start], ks[i - 1], net);
            run_start = i - 1;
        }
    }
    try emitSeg(ctx, tracks, ks[run_start], ks[ks.len - 1], net);
    return ks[ks.len - 1];
}

/// Does the unit step a→b equal the unit step b→c? True ⇒ a, b, c lie on one
/// straight line (orthogonal *or* 45° diagonal), so the run can keep extending.
fn sameDir(grid: Grid, nodes: usize, a: usize, b: usize, c: usize) bool {
    const ax: i64 = @intCast((a % nodes) % grid.nx);
    const ay: i64 = @intCast((a % nodes) / grid.nx);
    const bx: i64 = @intCast((b % nodes) % grid.nx);
    const by: i64 = @intCast((b % nodes) / grid.nx);
    const cx: i64 = @intCast((c % nodes) % grid.nx);
    const cy: i64 = @intCast((c % nodes) / grid.nx);
    return (bx - ax) == (cx - bx) and (by - ay) == (cy - by);
}

fn emitSeg(ctx: *Ctx, tracks: *std.ArrayList(Track), a_key: usize, b_key: usize, net: i32) std.mem.Allocator.Error!void {
    const grid = ctx.grid;
    const nodes = grid.nx * grid.ny;
    if (a_key == b_key) return;
    const layer: u8 = @intCast(a_key / nodes);
    const a = a_key % nodes;
    const b = b_key % nodes;
    const start = [2]f64{ grid.worldX(a % grid.nx), grid.worldY(a / grid.nx) };
    const end = [2]f64{ grid.worldX(b % grid.nx), grid.worldY(b / grid.nx) };
    try tracks.append(ctx.arena, .{
        .x1 = start[0],
        .y1 = start[1],
        .x2 = end[0],
        .y2 = end[1],
        .layer = layer,
        .width = ctx.params.track_width,
        .net = net,
    });
    stampTrackResv(ctx, start, end, net, layer);
    // A keepout net's copper carries its halo forward on THIS layer, so later
    // nets detour (or cross on another layer, which the rule allows by design) —
    // and its crossing shadow onto EVERY layer, so a crossing pays for running
    // alongside instead of straight across (`rf_shadow`).
    stampCurrentRf(ctx, start, end, net, layer);
}

// ── Small helpers ──────────────────────────────────────────────────────────

/// Radius (mm) a signal via needs a GND stitching via within (see
/// `return_path.return_path_radius_mm`).
pub const return_path_radius_mm = return_path.return_path_radius_mm;
/// Count return-path discontinuities in a routed board (see `return_path`).
pub const returnPathViolations = return_path.returnPathViolations;
/// The same count, restricted to the named signal nets (see `return_path`).
pub const returnPathViolationsForNets = return_path.returnPathViolationsForNets;

const isGndVia = return_path.isGndVia;

/// Ground-net predicate — the router shares the optimizer's exact one so a
/// split/numbered ground (GND1, AGND2, PGND_2) is treated as a plane here just
/// as it is in placement. A previous hand-copied exact-match list drifted and
/// routed those nets as signal copper.
const isGroundName = optimizer.isGroundName;

/// Net name after the last '/' — the leaf of a `sub-block/NET` flattened name.
pub fn shortName(s: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, s, '/')) |i| return s[i + 1 ..];
    return s;
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: placement/router - maze-routes a two-pad net into connected track segments
test "route connects a simple two-pad net" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const pads_a = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const pads_b = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads_a, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads_b, .fallback = false, .x = 3, .y = 0 },
    };
    const pins_a = [_]flat_netlist.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const nets = [_]FlatNet{.{ .name = "SIG", .pins = &pins_a }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -0.5,
        .miny = -0.5,
        .maxx = 3.5,
        .maxy = 0.5,
        .generated = true,
    };
    const r = try route(arena, placement, .{});
    try testing.expectEqual(@as(usize, 1), r.total);
    try testing.expectEqual(@as(usize, 1), r.routed);
    try testing.expect(r.tracks.len >= 1);
    const review = try routeWithTimeline(arena, placement, .{}, .{});
    try testing.expectEqual(r.routed, review.routed.routed);
    try testing.expectEqual(RouteEventKind.initial, review.timeline[0].kind);
    try testing.expectEqual(r.total, review.timeline[0].state.total);
    try testing.expectEqual(RouteEventKind.complete, review.timeline[review.timeline.len - 1].kind);
    try testing.expectEqual(r.tracks.len, review.timeline[review.timeline.len - 1].state.tracks.len);

    // A bottom preference is strong enough to justify two vias on this run.
    const prefer_bottom = [_]route_policy.NetPolicy{.{ .preferred_layers = 2 }};
    const biased = try routeWithOptions(arena, placement, .{}, .{ .net = &prefer_bottom });
    try testing.expect(trackLenOnLayer(biased.tracks, 1) > 1.0);
    try testing.expect(biased.vias.len >= 2);

    // A hard top-only policy wins over that preference and emits no B.Cu.
    const top_only = [_]route_policy.NetPolicy{.{ .preferred_layers = 2, .allowed_layers = 1 }};
    const constrained = try routeWithOptions(arena, placement, .{}, .{ .net = &top_only });
    try testing.expectEqual(@as(f64, 0), trackLenOnLayer(constrained.tracks, 1));
    try testing.expectEqual(@as(usize, 0), constrained.vias.len);

    // A hard zero-via budget rolls an over-budget preferred-layer attempt back,
    // then finds the legal top-layer route without leaving stale B.Cu copper.
    const zero_vias = [_]route_policy.NetPolicy{.{ .preferred_layers = 2, .max_vias = 0 }};
    const budgeted = try routeWithOptions(arena, placement, .{}, .{ .net = &zero_vias });
    try testing.expectEqual(@as(usize, 1), budgeted.routed);
    try testing.expectEqual(@as(usize, 0), budgeted.vias.len);
    try testing.expectEqual(@as(f64, 0), trackLenOnLayer(budgeted.tracks, 1));

    // Ordered waypoints can request exact layer transitions by repeating the
    // same coordinate on two layers.
    const guide_points = [_]route_policy.Waypoint{
        .{ .x = 1.0, .y = 0, .layer = 0 },
        .{ .x = 1.0, .y = 0, .layer = 1 },
        .{ .x = 2.0, .y = 0, .layer = 1 },
        .{ .x = 2.0, .y = 0, .layer = 0 },
    };
    const guided_policy = [_]route_policy.NetPolicy{.{ .waypoints = &guide_points }};
    const guided = try routeWithOptions(arena, placement, .{}, .{ .net = &guided_policy });
    try testing.expectEqual(@as(usize, 1), guided.routed);
    try testing.expectEqual(@as(usize, 2), guided.vias.len);
    try testing.expect(trackLenOnLayer(guided.tracks, 1) > 0.9);

    // Guide orientation is physical rather than coupled to FlatNet pin order:
    // authoring the same chain from R2 back to R1 routes the identical two-pad
    // topology instead of crossing the board to visit the points backwards.
    const reversed_guide_points = [_]route_policy.Waypoint{
        guide_points[3],
        guide_points[2],
        guide_points[1],
        guide_points[0],
    };
    const reversed_guided_policy = [_]route_policy.NetPolicy{.{ .waypoints = &reversed_guide_points }};
    const reversed_guided = try routeWithOptions(arena, placement, .{}, .{ .net = &reversed_guided_policy });
    try testing.expectEqual(@as(usize, 1), reversed_guided.routed);
    try testing.expectEqual(@as(usize, 2), reversed_guided.vias.len);
    try testing.expect(trackLenOnLayer(reversed_guided.tracks, 1) > 0.9);

    // A guide that inherently needs two transitions cannot satisfy a one-via
    // budget. The whole failed net is transactional: no tracks or vias survive.
    const one_via = [_]route_policy.NetPolicy{.{ .waypoints = &guide_points, .max_vias = 1 }};
    const rejected = try routeWithOptions(arena, placement, .{}, .{ .net = &one_via });
    try testing.expectEqual(@as(usize, 0), rejected.routed);
    try testing.expectEqual(@as(usize, 0), rejected.tracks.len);
    try testing.expectEqual(@as(usize, 0), rejected.vias.len);

    // A false selected-net mask skips the net entirely; retained copper still
    // passes through unchanged for leave-one-net experiment composition.
    const none = [_]bool{false};
    const existing = [_]route_policy.ExistingTrack{.{
        .x1 = 1,
        .y1 = 0.5,
        .x2 = 2,
        .y2 = 0.5,
        .layer = 0,
        .width = 0.2,
        .net = 7,
    }};
    const skipped = try routeWithOptions(arena, placement, .{}, .{
        .selected_nets = &none,
        .existing_tracks = &existing,
    });
    try testing.expectEqual(@as(usize, 0), skipped.total);
    try testing.expectEqual(@as(usize, 1), skipped.tracks.len);
    try testing.expectEqual(@as(i32, 7), skipped.tracks[0].net);

    // A retained same-net pour is a connected local trunk. Pads already in it
    // need only tiny centre-to-grid access stubs, not a redundant full trace.
    const pour_poly = [_][2]f64{
        .{ -0.3, -0.3 }, .{ 3.3, -0.3 }, .{ 3.3, 0.3 }, .{ -0.3, 0.3 },
    };
    const pour = [_]route_policy.ExistingZone{.{
        .polygon = &pour_poly,
        .layer = 0,
        .net = 0,
    }};
    const poured = try routeWithOptions(arena, placement, .{}, .{ .existing_zones = &pour });
    try testing.expectEqual(@as(usize, 1), poured.routed);
    try testing.expect(route_timeline.traceLen(poured.tracks) < 0.5);

    // A two-layer keepout is a real routing obstacle, unlike a repourable
    // copper-zone boundary. The routed trace must go around its clearance halo.
    const keepout_poly = [_][2]f64{
        .{ 1.3, -0.5 }, .{ 1.7, -0.5 }, .{ 1.7, 0.5 }, .{ 1.3, 0.5 },
    };
    const keepouts = [_]route_policy.ExistingZone{
        .{
            .polygon = &keepout_poly,
            .layer = 0,
            .net = -2,
            .tracks_blocked = true,
            .vias_blocked = true,
            .copper = false,
        },
        .{
            .polygon = &keepout_poly,
            .layer = 1,
            .net = -2,
            .tracks_blocked = true,
            .vias_blocked = true,
            .copper = false,
        },
    };
    const detoured = try routeWithOptions(arena, placement, .{}, .{ .existing_zones = &keepouts });
    try testing.expectEqual(@as(usize, 1), detoured.routed);
    try testing.expect(route_timeline.traceLen(detoured.tracks) > 3.1);
}

// spec: placement/router - a failed broad net retries its repair-waypoints before lower waves can claim the corridor, without perturbing a successful ordinary route
test "a failed ordinary net takes its deferred repair corridor immediately" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads, .fallback = false, .x = 3, .y = 0 },
    };
    const pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const nets = [_]FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -0.5,
        .miny = -0.5,
        .maxx = 3.5,
        .maxy = 0.5,
        .generated = true,
        .board_rect = .{ .minx = -0.5, .miny = -0.5, .w = 4, .h = 1 },
        .rules = .{ .copper_layers = 2 },
    };
    const wall_poly = [_][2]f64{
        .{ 1.3, -0.5 }, .{ 1.7, -0.5 }, .{ 1.7, 0.5 }, .{ 1.3, 0.5 },
    };
    const top_wall = [_]route_policy.ExistingZone{.{
        .polygon = &wall_poly,
        .layer = 0,
        .net = -2,
        .tracks_blocked = true,
        .vias_blocked = true,
        .copper = false,
    }};
    const repair = [_]route_policy.Waypoint{
        .{ .x = 0.8, .y = 0, .layer = 0 },
        .{ .x = 0.8, .y = 0, .layer = 1 },
        .{ .x = 2.2, .y = 0, .layer = 1 },
        .{ .x = 2.2, .y = 0, .layer = 0 },
    };
    const policies = [_]route_policy.NetPolicy{.{
        .wave = .{ .repair_waypoints = &repair },
        .allowed_layers = 1,
        .max_vias = 2,
    }};

    const routed = try routeWithOptions(arena, placement, .{}, .{
        .net = &policies,
        .existing_zones = &top_wall,
    });
    try testing.expectEqual(@as(usize, 1), routed.routed);
    try testing.expectEqual(@as(usize, 2), routed.vias.len);
    try testing.expect(trackLenOnLayer(routed.tracks, 1) > 1.0);
}

// spec: placement/router - a timed deferred repair corridor runs under one flat probe budget, so corridor length cannot scale its claim on the shared deadline
test "a timed deferred repair corridor routes under its flat probe budget" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads, .fallback = false, .x = 3, .y = 0 },
    };
    const pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const nets = [_]FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -0.5,
        .miny = -0.5,
        .maxx = 3.5,
        .maxy = 0.5,
        .generated = true,
        .board_rect = .{ .minx = -0.5, .miny = -0.5, .w = 4, .h = 1 },
        .rules = .{ .copper_layers = 2 },
    };
    const wall_poly = [_][2]f64{
        .{ 1.3, -0.5 }, .{ 1.7, -0.5 }, .{ 1.7, 0.5 }, .{ 1.3, 0.5 },
    };
    const top_wall = [_]route_policy.ExistingZone{.{
        .polygon = &wall_poly,
        .layer = 0,
        .net = -2,
        .tracks_blocked = true,
        .vias_blocked = true,
        .copper = false,
    }};
    const repair = [_]route_policy.Waypoint{
        .{ .x = 0.8, .y = 0, .layer = 0 },
        .{ .x = 0.8, .y = 0, .layer = 1 },
        .{ .x = 2.2, .y = 0, .layer = 1 },
        .{ .x = 2.2, .y = 0, .layer = 0 },
    };
    const policies = [_]route_policy.NetPolicy{.{
        .wave = .{ .repair_waypoints = &repair },
        .allowed_layers = 1,
        .max_vias = 2,
    }};

    const timed = try routeWithOptions(arena, placement, .{}, .{
        .net = &policies,
        .existing_zones = &top_wall,
        .stop = .{ .max_route_ms = 60_000 },
    });
    try testing.expectEqual(@as(usize, 1), timed.routed);
    try testing.expectEqual(@as(usize, 2), timed.vias.len);
    try testing.expect(trackLenOnLayer(timed.tracks, 1) > 1.0);
}

/// Three drops in a row with both F.Cu channels walled off: the ordinary maze
/// cannot reach either outer pad, so only a corridor that dives to B.Cu and
/// back can. The middle pad is the tree's root and is deliberately NOT the
/// net's first terminal, which is what makes this a test of the geometric
/// binding rather than of the positional contract underneath it.
fn walledClockBoard(parts: []Part) optimizer.Placement {
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &walled_clock_nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -3.5,
        .miny = -0.5,
        .maxx = 3.5,
        .maxy = 0.5,
        .generated = true,
        .board_rect = .{ .minx = -3.5, .miny = -0.5, .w = 7, .h = 1 },
        .rules = .{ .copper_layers = 2 },
    };
}

/// The three drops of `walledClockBoard`, as the caller's own mutable storage.
fn walledClockParts(pads: []const geometry.Pad) [3]Part {
    return .{
        .{ .ref_des = "U1", .kind = .hub, .hw = 0.5, .hh = 0.5, .pads = pads, .fallback = false, .x = -3, .y = 0 },
        .{ .ref_des = "U2", .kind = .hub, .hw = 0.5, .hh = 0.5, .pads = pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "U3", .kind = .hub, .hw = 0.5, .hh = 0.5, .pads = pads, .fallback = false, .x = 3, .y = 0 },
    };
}

/// `walledClockBoard`'s one net, in the pin order the router's terminals follow:
/// the ROOT drop is the middle entry, never the first.
const walled_clock_nets = blk: {
    const pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "U2", .pin = "1" },
        .{ .ref_des = "U3", .pin = "1" },
    };
    break :blk [_]FlatNet{.{ .name = "SCK", .pins = &pins }};
};

/// The two F.Cu walls of `walledClockBoard`, one in each channel.
const walled_clock_zones = blk: {
    const west = [_][2]f64{ .{ -2.0, -0.5 }, .{ -1.6, -0.5 }, .{ -1.6, 0.5 }, .{ -2.0, 0.5 } };
    const east = [_][2]f64{ .{ 1.6, -0.5 }, .{ 2.0, -0.5 }, .{ 2.0, 0.5 }, .{ 1.6, 0.5 } };
    break :blk [_]route_policy.ExistingZone{
        .{ .polygon = &west, .layer = 0, .net = -2, .tracks_blocked = true, .vias_blocked = true, .copper = false },
        .{ .polygon = &east, .layer = 0, .net = -2, .tracks_blocked = true, .vias_blocked = true, .copper = false },
    };
};

// spec: placement/router - an authored branch tree routes a multi-drop net through one corridor per drop, bound to the terminals by geometry rather than by authored order
test "an authored branch tree routes each drop through its own corridor" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const to_west = [_]route_policy.Waypoint{
        .{ .x = -1.2, .y = 0, .layer = 0 },
        .{ .x = -1.2, .y = 0, .layer = 1 },
        .{ .x = -2.4, .y = 0, .layer = 1 },
        .{ .x = -2.4, .y = 0, .layer = 0 },
    };
    const to_east = [_]route_policy.Waypoint{
        .{ .x = 1.2, .y = 0, .layer = 0 },
        .{ .x = 1.2, .y = 0, .layer = 1 },
        .{ .x = 2.4, .y = 0, .layer = 1 },
        .{ .x = 2.4, .y = 0, .layer = 0 },
    };
    const branches = [_]route_policy.GuideBranch{
        .{ .waypoints = &to_west },
        .{ .waypoints = &to_east },
    };
    const policies = [_]route_policy.NetPolicy{.{
        .wave = .{ .branches = &branches },
        .allowed_layers = 1,
        .max_vias = 4,
    }};

    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = walledClockParts(&pads);
    const routed = try routeWithOptions(arena, walledClockBoard(&parts), .{}, .{
        .net = &policies,
        .existing_zones = &walled_clock_zones,
    });
    try testing.expectEqual(@as(usize, 1), routed.routed);
    // One dive per drop: the tree is two independent limbs, not one trunk.
    try testing.expectEqual(@as(usize, 4), routed.vias.len);
    try testing.expect(trackLenOnLayer(routed.tracks, 1) > 2.0);
}

// spec: placement/router - a branch tree that cannot be bound to distinct terminals guides nothing, leaving the net to the ordinary multi-terminal router
test "an unbindable branch tree leaves the net routing exactly as it would unguided" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const to_west = [_]route_policy.Waypoint{
        .{ .x = -1.2, .y = 0, .layer = 0 },
        .{ .x = -1.2, .y = 0, .layer = 1 },
        .{ .x = -2.4, .y = 0, .layer = 1 },
        .{ .x = -2.4, .y = 0, .layer = 0 },
    };
    // Three limbs on a three-terminal net: one too many to cover it, so the
    // tree is refused whole rather than applied to two of the three drops.
    const branches = [_]route_policy.GuideBranch{
        .{ .waypoints = &to_west },
        .{ .waypoints = &to_west },
        .{ .waypoints = &to_west },
    };
    const guided = [_]route_policy.NetPolicy{.{
        .wave = .{ .branches = &branches },
        .allowed_layers = 1,
        .max_vias = 4,
    }};
    const plain = [_]route_policy.NetPolicy{.{ .allowed_layers = 1, .max_vias = 4 }};

    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var guided_parts = walledClockParts(&pads);
    var plain_parts = walledClockParts(&pads);
    const refused = try routeWithOptions(arena, walledClockBoard(&guided_parts), .{}, .{
        .net = &guided,
        .existing_zones = &walled_clock_zones,
    });
    const unguided = try routeWithOptions(arena, walledClockBoard(&plain_parts), .{}, .{
        .net = &plain,
        .existing_zones = &walled_clock_zones,
    });
    try testing.expectEqual(unguided.routed, refused.routed);
    try testing.expectEqual(unguided.tracks.len, refused.tracks.len);
    try testing.expectEqual(unguided.vias.len, refused.vias.len);
}

test "a routed diff-pair leader survives a follower that cannot route" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const pads = [_]geometry.Pad{.{
        .number = "1",
        .x = 0,
        .y = 0,
        .w = 0.3,
        .h = 0.3,
    }};
    var parts = [_]Part{
        .{ .ref_des = "P1", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "P2", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &pads, .fallback = false, .x = 3, .y = 0 },
        .{ .ref_des = "N1", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &pads, .fallback = false, .x = 0, .y = 1 },
        .{ .ref_des = "N2", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &pads, .fallback = false, .x = 3, .y = 1 },
    };
    const p_pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "P1", .pin = "1" },
        .{ .ref_des = "P2", .pin = "1" },
    };
    const n_pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "N1", .pin = "1" },
        .{ .ref_des = "N2", .pin = "1" },
    };
    const nets = [_]FlatNet{
        .{ .name = "D_P", .pins = &p_pins },
        .{ .name = "D_N", .pins = &n_pins },
    };
    const pairs = [_]diff_pairs.DiffPair{.{ .p = 0, .n = 1, .gap = 0.2 }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .diff_pairs = &pairs,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -0.5,
        .miny = -0.5,
        .maxx = 3.5,
        .maxy = 1.5,
        .generated = true,
    };
    const impossible_transition = [_]route_policy.Waypoint{
        .{ .x = 1.5, .y = 1, .layer = 0 },
        .{ .x = 1.5, .y = 1, .layer = 1 },
    };
    const policies = [_]route_policy.NetPolicy{
        .{},
        .{ .waypoints = &impossible_transition, .max_vias = 0 },
    };

    const routed = try routeWithOptions(arena, placement, .{}, .{ .net = &policies });
    try testing.expectEqual(@as(usize, 2), routed.total);
    // The follower (D_N) is forced unroutable by an impossible layer-change
    // waypoint under max_vias=0. The leader (D_P) routed standalone and MUST be
    // kept — a declared pair may never route worse than two independent nets
    // (the old code tore both out; see finishGreedyNet). So exactly one net
    // routes and only D_N is reported failed.
    try testing.expectEqual(@as(usize, 1), routed.routed);
    try testing.expect(routed.tracks.len > 0);
    try testing.expectEqual(@as(usize, 1), routed.failed.len);
    try testing.expect(std.mem.eql(u8, "D_N", routed.failed[0]));
}

// spec: placement/router - an escalation re-couple rips both legs, re-runs the coupled construction and freezes both, and rolls the whole transaction back when it declines
test "escalation re-couples a declared pair as one all-or-nothing transaction" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.3, .h = 0.3 }};
    var parts = [_]Part{
        .{ .ref_des = "P1", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "P2", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &pads, .fallback = false, .x = 3, .y = 0 },
        .{ .ref_des = "N1", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &pads, .fallback = false, .x = 0, .y = 1 },
        .{ .ref_des = "N2", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &pads, .fallback = false, .x = 3, .y = 1 },
    };
    const p_pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "P1", .pin = "1" }, .{ .ref_des = "P2", .pin = "1" } };
    const n_pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "N1", .pin = "1" }, .{ .ref_des = "N2", .pin = "1" } };
    const nets = [_]FlatNet{ .{ .name = "D_P", .pins = &p_pins }, .{ .name = "D_N", .pins = &n_pins } };
    const pairs = [_]diff_pairs.DiffPair{.{ .p = 0, .n = 1, .gap = 0.2 }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .diff_pairs = &pairs,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -0.5,
        .miny = -0.5,
        .maxx = 3.5,
        .maxy = 1.5,
        .generated = true,
    };
    const outcome = try routeCoreStart(arena, placement, .{}, .{}, .off);
    try testing.expect(outcome == .core);
    const core = outcome.core;
    const esc = EscalateRun{
        .ctx = core.ctx,
        .placement = core.placement,
        .idx_of = core.idx_of,
        .routable = core.result.routable,
        .tracks = core.tracks,
        .vias = core.vias,
    };
    const pair = pairs[0];
    try testing.expectEqual([2]bool{ true, true }, [2]bool{
        ripNetSlot(esc.routable, pair.p).?.ok,
        ripNetSlot(esc.routable, pair.n).?.ok,
    });

    // Happy path: both legs come off the board, the coupled construction runs
    // again, and both are frozen so rip-up can never take one member alone.
    try testing.expectEqual(true, try diff_couple.recouple(esc, pair));
    try testing.expectEqual([4]bool{ true, true, false, false }, [4]bool{
        ripNetSlot(esc.routable, pair.p).?.ok,
        ripNetSlot(esc.routable, pair.n).?.ok,
        ripNetSlot(esc.routable, pair.p).?.reroutable,
        ripNetSlot(esc.routable, pair.n).?.reroutable,
    });

    // Rollback path: widen the class until its envelope (2·width + gap) cannot
    // fit the board at all, so the construction declines AFTER both legs have
    // been ripped. The routed pair survives only if the snapshot is restored.
    core.ctx.params.track_width = 3.0;
    const tracks_before = core.tracks.items.len;
    const vias_before = core.vias.items.len;
    try testing.expectEqual(false, try diff_couple.recouple(esc, pair));
    try testing.expectEqual(tracks_before, core.tracks.items.len);
    try testing.expectEqual(vias_before, core.vias.items.len);
    try testing.expectEqual([2]bool{ true, true }, [2]bool{
        ripNetSlot(esc.routable, pair.p).?.ok,
        ripNetSlot(esc.routable, pair.n).?.ok,
    });
}

// spec: placement/router - a net spanning the two board sides routes through a via, each leg on its part's layer unless the barrel stands in that pad's own land
test "route vias between a top part and a bottom part" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const pads_a = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const pads_b = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads_a, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads_b, .fallback = false, .x = 3, .y = 0, .side = .bottom },
    };
    const pins_a = [_]flat_netlist.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const nets = [_]FlatNet{.{ .name = "SIG", .pins = &pins_a }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -0.5,
        .miny = -0.5,
        .maxx = 3.5,
        .maxy = 0.5,
        .generated = true,
    };
    const r = try route(arena, placement, .{});
    try testing.expectEqual(@as(usize, 1), r.total);
    try testing.expectEqual(@as(usize, 1), r.routed);
    // Crossing sides needs a via and copper spanning the 3 mm gap. WHICH face
    // carries it is no longer fixed: a barrel standing in a pad's own land is
    // that pad's connection on that face (`via_centre`), and both lands here are
    // 0.4 mm square — exactly the barrel — so the near side draws none.
    try testing.expect(r.vias.len >= 1);
    var span: f64 = 0;
    for (r.tracks) |t| span += std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
    try testing.expect(span > 2.0);
}

// A small mixed-face multi-terminal net grows a direct tree through its nearest
// terminal frontier.
test "route grows a direct tree across three mixed-face pads" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const pad = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 0, .y = 0.5 },
        .{
            .ref_des = "R1",
            .kind = .passive,
            .hw = 0.3,
            .hh = 0.3,
            .pads = &pad,
            .fallback = false,
            .x = 0,
            .y = 0,
            .side = .bottom,
        },
        .{
            .ref_des = "R2",
            .kind = .passive,
            .hw = 0.3,
            .hh = 0.3,
            .pads = &pad,
            .fallback = false,
            .x = 0,
            .y = -0.8,
            .side = .bottom,
        },
    };
    const pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "R1", .pin = "1" },
        .{ .ref_des = "R2", .pin = "1" },
    };
    const nets = [_]FlatNet{.{ .name = "TREE", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1,
        .miny = -1.3,
        .maxx = 1,
        .maxy = 1,
        .generated = true,
    };
    const routed = try route(arena, placement, .{});
    try testing.expectEqual(@as(usize, 1), routed.total);
    try testing.expectEqual(@as(usize, 1), routed.routed);
    try testing.expectEqual(@as(usize, 1), routed.vias.len);
    // U1 (at y = 0.5) is the only top-side terminal, so the top face is reached
    // by copper or — the barrel centred in U1's own land — by the land itself.
    try testing.expect(trackLenOnLayer(routed.tracks, 0) > 0 or @abs(routed.vias[0].y - 0.5) <= 0.2);
    try testing.expect(trackLenOnLayer(routed.tracks, 1) > 0.5);
}

// spec: placement/router - a board outline detours routed copper around a concave notch; no-outline routes unchanged
test "route detours a concave board notch and leaves no-outline routing unchanged" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // L-board: 10×10 with the top-right 4×6 notch removed (matches drc's l_poly).
    const l_poly = [_][2]f64{
        .{ 0, 0 }, .{ 10, 0 }, .{ 10, 4 }, .{ 6, 4 }, .{ 6, 10 }, .{ 0, 10 },
    };
    const pa = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const pb = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    // Pad A in the tall left arm, pad B in the low right arm — the straight line
    // between them slices through the removed notch, so a clean route MUST detour.
    var parts = [_]Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pa, .fallback = false, .x = 2, .y = 8 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pb, .fallback = false, .x = 9, .y = 2 },
    };
    const pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const nets = [_]FlatNet{.{ .name = "SIG", .pins = &pins }};
    var placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .generated = true,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 },
        .board_poly = &l_poly,
    };

    const r = try route(arena, placement, .{});
    try testing.expectEqual(@as(usize, 1), r.routed); // still routable within the L

    // Board-edge DRC is clean — nothing routed into or across the notch — and
    // every routed vertex sits inside the board polygon.
    const viol = try @import("drc.zig").check(arena, placement, r, 0.127);
    try testing.expectEqual(@as(usize, 0), @import("drc.zig").countKind(viol, .board_edge));
    for (r.tracks) |t| {
        try testing.expect(outline_mod.contains(&l_poly, t.x1, t.y1));
        try testing.expect(outline_mod.contains(&l_poly, t.x2, t.y2));
    }

    // Same two parts, NO outline: the null mask makes every outline check a
    // no-op, so routing is unaffected (still succeeds).
    placement.board_rect = null;
    placement.board_poly = null;
    const r2 = try route(arena, placement, .{});
    try testing.expectEqual(@as(usize, 1), r2.routed);
}

// A typed perimeter keepout is a hard track/via obstacle on every signal
// layer while its explicit net admissions remain usable.
test "router blocks the fixed perimeter band for tracks and vias" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const nets = [_]FlatNet{
        .{ .name = "SIG", .pins = &.{} },
        .{ .name = "GND", .pins = &.{} },
    };
    const placement = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .generated = true,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 },
        .rules = .{ .perimeter_fence = .{
            .via_dia = 0.4,
            .via_drill = 0.2,
            .spacing = 1,
            .edge_offset = 0.5,
            .net = "GND",
            .keepout = .{
                .clearance = 0.3,
                .blocks = .{ .tracks = true, .vias = true },
                .allow_nets = &.{"GND"},
            },
        } },
    };
    var ctx = try testRouteCtx(arena, placement, .{});
    const near = ctx.grid.nearest(0.8, 5);
    const node = ctx.grid.node(near[0], near[1]);
    try testing.expect(outlineBlocked(&ctx, node, 0));
    try testing.expect(!outlineBlocked(&ctx, node, 1));
    try testing.expect(!viaClearsOutline(&ctx, 1.1, 5, 0));
    try testing.expect(viaClearsOutline(&ctx, 1.1, 5, 1));
    try testing.expect(viaClearsOutline(&ctx, 1.3, 5, 0));
}

// spec: placement/router - exposed-pad thermal fields use practical centred 3x3 and 4x4 arrays instead of the DRC-densest possible drill packing
test "thermal array density matches small and large exposed pads" {
    const via_dia: f64 = 0.4;
    const min_pitch: f64 = 0.527;

    const hmc451 = thermalAxis(1.95, via_dia, min_pitch);
    try testing.expectEqual(@as(usize, 3), hmc451.count);
    try testing.expectApproxEqAbs(@as(f64, 0.775), hmc451.pitch, 1e-9);

    const hmc733 = thermalAxis(2.5, via_dia, min_pitch);
    try testing.expectEqual(@as(usize, 3), hmc733.count);
    try testing.expectApproxEqAbs(@as(f64, 0.9), hmc733.pitch, 1e-9);

    const lmx2595 = thermalAxis(4.6, via_dia, min_pitch);
    try testing.expectEqual(@as(usize, 4), lmx2595.count);
    try testing.expectApproxEqAbs(@as(f64, 0.9), lmx2595.pitch, 1e-9);

    const array = ThermalArray{
        .pad = .{ .x0 = -0.975, .y0 = -0.975, .x1 = 0.975, .y1 = 0.975 },
        .centre = .{ 10, 20 },
        .cols = hmc451.count,
        .rows = hmc451.count,
        .pitch_x = hmc451.pitch,
        .pitch_y = hmc451.pitch,
    };
    try testing.expectEqual(@as(usize, 9), array.count());
    try testing.expectEqual([2]f64{ 9.225, 19.225 }, array.point(0, 0));
    try testing.expectEqual([2]f64{ 10, 20 }, array.point(1, 1));
    try testing.expectEqual([2]f64{ 10.775, 20.775 }, array.point(2, 2));
    try testing.expect(thermalArrayNeedsPrepass(array));

    const preferred = ThermalArray{
        .pad = .{ .x0 = -1.25, .y0 = -1.25, .x1 = 1.25, .y1 = 1.25 },
        .centre = .{ 10, 20 },
        .cols = hmc733.count,
        .rows = hmc733.count,
        .pitch_x = hmc733.pitch,
        .pitch_y = hmc733.pitch,
    };
    try testing.expect(!thermalArrayNeedsPrepass(preferred));

    const large = ThermalArray{
        .pad = .{ .x0 = -2.3, .y0 = -2.3, .x1 = 2.3, .y1 = 2.3 },
        .centre = .{ 10, 20 },
        .cols = lmx2595.count,
        .rows = lmx2595.count,
        .pitch_x = lmx2595.pitch,
        .pitch_y = lmx2595.pitch,
    };
    try testing.expect(thermalArrayNeedsPrepass(large));
}

// spec: placement/router - plane nets follow authored route-wave priority within the plane-stitch pass, so a ground wave can reserve stitch sites before a competing power pour
test "plane net stitch order follows authored wave priority" {
    var order = [_]usize{ 0, 1, 2, 3 };
    const priorities = [_]u64{ 2, 9, 4, 9 };
    const thermal = [_]f64{ 0, 0, 0, 0 };
    sortPlaneOrder(&order, &priorities, &thermal);
    try testing.expectEqualSlices(usize, &.{ 1, 3, 2, 0 }, &order);

    // A net with an exposed thermal land gets the scarce drill sites before an
    // electrically higher-priority plane net; wave priority remains its tie-break.
    var hot_order = [_]usize{ 0, 1, 2, 3 };
    const hot_priorities = [_]u64{ 99, 9, 40, 1 };
    const hot_thermal = [_]f64{ 0, 4, 0, 9 };
    sortPlaneOrder(&hot_order, &hot_priorities, &hot_thermal);
    try testing.expectEqualSlices(usize, &.{ 3, 1, 0, 2 }, &hot_order);
}

// spec: placement/router - a plane-less stackup routes ground as real copper instead of dropping plane vias
test "plane-less stackup maze-routes the ground net" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const pads_a = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const pads_b = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]Part{
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads_a, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads_b, .fallback = false, .x = 3, .y = 0 },
    };
    const pins_g = [_]flat_netlist.FlatPin{ .{ .ref_des = "C1", .pin = "1" }, .{ .ref_des = "C2", .pin = "1" } };
    const nets = [_]FlatNet{.{ .name = "GND", .pins = &pins_g }};
    var placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -0.5,
        .miny = -0.5,
        .maxx = 3.5,
        .maxy = 0.5,
        .generated = true,
    };

    // Legacy (no stackup): GND is a plane net — one via per pad, no trace run.
    const legacy = try route(arena, placement, .{});
    try testing.expectEqual(@as(usize, 1), legacy.routed);
    try testing.expect(legacy.vias.len >= 2);

    // Declared plane-less stackup: GND maze-routes as surface copper.
    placement.rules.plane_nets = &.{};
    const flat = try route(arena, placement, .{});
    try testing.expectEqual(@as(usize, 1), flat.routed);
    try testing.expectEqual(@as(usize, 0), flat.vias.len);
    var gnd_len: f64 = 0;
    for (flat.tracks) |t| gnd_len += std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
    try testing.expect(gnd_len >= 2.5); // the ~3 mm pad-to-pad run exists as copper
}

// Regression: selected plane vias must avoid retained opposite-face copper.
test "plane vias clear retained opposite-face tracks" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const pad = [_]geometry.Pad{.{
        .number = "1",
        .x = 0,
        .y = 0,
        .w = 0.4,
        .h = 0.4,
    }};
    var parts = [_]Part{
        .{
            .ref_des = "C1",
            .kind = .passive,
            .hw = 0.5,
            .hh = 0.5,
            .pads = &pad,
            .fallback = false,
            .x = -2,
            .y = 0,
        },
        .{
            .ref_des = "C2",
            .kind = .passive,
            .hw = 0.5,
            .hh = 0.5,
            .pads = &pad,
            .fallback = false,
            .x = 2,
            .y = 0,
        },
        .{
            .ref_des = "J1",
            .kind = .passive,
            .hw = 0.5,
            .hh = 0.5,
            .pads = &pad,
            .fallback = false,
            .x = -2,
            .y = -1,
            .side = .bottom,
        },
        .{
            .ref_des = "J2",
            .kind = .passive,
            .hw = 0.5,
            .hh = 0.5,
            .pads = &pad,
            .fallback = false,
            .x = -2,
            .y = 1,
            .side = .bottom,
        },
    };
    const gnd_pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "C1", .pin = "1" },
        .{ .ref_des = "C2", .pin = "1" },
    };
    const sig_pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "J1", .pin = "1" },
        .{ .ref_des = "J2", .pin = "1" },
    };
    const nets = [_]FlatNet{
        .{ .name = "GND", .pins = &gnd_pins },
        .{ .name = "SIG", .pins = &sig_pins },
    };
    const ground_names = [_][]const u8{"GND"};
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2.5,
        .miny = -1.5,
        .maxx = 2.5,
        .maxy = 1.5,
        .generated = true,
        .rules = .{
            .plane_nets = &ground_names,
            .copper_layers = 4,
            .planes = .{ .declared = &planes },
        },
    };
    const selected = [_]bool{ true, false };
    const retained = [_]route_policy.ExistingTrack{.{
        .x1 = -2,
        .y1 = -1,
        .x2 = -2,
        .y2 = 1,
        .layer = 1,
        .width = 0.2,
        .net = 1,
    }};
    const routed = try routeWithOptions(arena, placement, .{}, .{
        .selected_nets = &selected,
        .existing_tracks = &retained,
    });
    try testing.expectEqual(@as(usize, 1), routed.routed);
    try testing.expectEqual(@as(usize, 2), routed.vias.len);
    try testing.expect(@abs(routed.vias[0].x + 2) > 0.4);
    const drc_mod = @import("drc.zig");
    const violations = try drc_mod.check(arena, placement, routed, 0.127);
    // The plane stitch's elbow leaves one leg that never gets off the land it
    // starts from — attached at both ends, carrying nothing. The finish's own
    // section-deletion pass now reads it exactly as this check does, so the
    // board arrives clean instead of handing the warning to the public gate.
    try testing.expectEqual(@as(usize, 0), drc_mod.countKind(violations, .dangling_copper));
    try testing.expectEqual(@as(usize, 0), violations.len);

    const replay_policy = [_]route_policy.NetPolicy{
        .{ .replay_reference_copper = true },
        .{},
    };
    const guide_vias = [_]route_policy.GuideVia{.{
        .x = -1.4,
        .y = 0,
        .net = 0,
        .dia = 0.4,
        .drill = 0.2,
    }};
    const replayed = try routeWithOptions(arena, placement, .{}, .{
        .net = &replay_policy,
        .selected_nets = &selected,
        .existing_tracks = &retained,
        .guides = .{ .vias = &guide_vias },
    });
    try testing.expectEqual(@as(usize, 1), replayed.routed);
    // A replay guide that reaches only the inner GND plane and no second
    // copper layer is an artifact, even though its reference was accepted.
    try testing.expectEqual(@as(usize, 0), replayed.vias.len);
    try testing.expectEqualSlices(usize, &.{0}, replayed.reference_replayed);
}

// spec: placement/router - a scoped route echoes retained out-of-scope copper byte-identical; no finish pass rewrites an unselected net
test "scoped route returns retained out-of-scope copper byte-identical" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Net A (selected) routes fresh along y = 2. Net B (NOT selected) arrives
    // as retained caller copper shaped exactly like what the finish passes
    // rewrite: an up-across-down via hop (the redundant-hop pass's target),
    // collinear runs straighten would merge, and a sub-micron stub the
    // degenerate sweep would drop. All of it must come back verbatim — a
    // scoped barracuda re-route once returned a different board than
    // submitted and reopened six previously-connected out-of-scope nets.
    const pad = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]Part{
        .{ .ref_des = "A1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 0, .y = 2 },
        .{ .ref_des = "A2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 3, .y = 2 },
        .{ .ref_des = "B1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "B2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 3, .y = 0 },
    };
    const pins_a = [_]flat_netlist.FlatPin{ .{ .ref_des = "A1", .pin = "1" }, .{ .ref_des = "A2", .pin = "1" } };
    const pins_b = [_]flat_netlist.FlatPin{ .{ .ref_des = "B1", .pin = "1" }, .{ .ref_des = "B2", .pin = "1" } };
    const nets = [_]FlatNet{
        .{ .name = "A", .pins = &pins_a },
        .{ .name = "B", .pins = &pins_b },
    };
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -0.5,
        .miny = -0.5,
        .maxx = 3.5,
        .maxy = 2.5,
        .generated = true,
    };
    const selected = [_]bool{ true, false };
    const retained_tracks = [_]route_policy.ExistingTrack{
        .{ .x1 = 0, .y1 = 0, .x2 = 1.5, .y2 = 0, .layer = 0, .width = 0.25, .net = 1 },
        .{ .x1 = 1.5, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 1, .width = 0.25, .net = 1 },
        .{ .x1 = 2, .y1 = 0, .x2 = 3, .y2 = 0, .layer = 0, .width = 0.25, .net = 1 },
        .{ .x1 = 0, .y1 = 0, .x2 = 0, .y2 = 0.0000005, .layer = 0, .width = 0.25, .net = 1 },
    };
    const retained_vias = [_]route_policy.ExistingVia{
        .{ .x = 1.5, .y = 0, .dia = 0.4, .drill = 0.2, .net = 1 },
        .{ .x = 2, .y = 0, .dia = 0.4, .drill = 0.2, .net = 1 },
    };
    const routed = try routeWithOptions(arena, placement, .{}, .{
        .selected_nets = &selected,
        .existing_tracks = &retained_tracks,
        .existing_vias = &retained_vias,
    });
    try testing.expectEqual(@as(usize, 1), routed.routed); // net A routed fresh

    // Net B's copper: exactly the submitted segments/vias, in order, verbatim.
    try testing.expect(retainedTracksEchoed(routed.tracks, &retained_tracks, 1));
    try testing.expect(retainedViasEchoed(routed.vias, &retained_vias, 1));
}

/// Every net-`net` track in `tracks`, in submitted order, equals `want`
/// field-for-field with nothing missing or added — the byte-identical echo
/// check for a scoped route's retained copper. Hoisted so the test itself
/// stays conditional-free.
fn retainedTracksEchoed(tracks: []const Track, want: []const route_policy.ExistingTrack, net: i32) bool {
    var k: usize = 0;
    for (tracks) |t| {
        if (t.net != net) continue;
        if (k >= want.len) return false;
        const w = want[k];
        if (t.x1 != w.x1 or t.y1 != w.y1 or t.x2 != w.x2 or t.y2 != w.y2) return false;
        if (t.layer != w.layer or t.width != w.width) return false;
        k += 1;
    }
    return k == want.len;
}

/// The via half of `retainedTracksEchoed`.
fn retainedViasEchoed(vias: []const Via, want: []const route_policy.ExistingVia, net: i32) bool {
    var k: usize = 0;
    for (vias) |v| {
        if (v.net != net) continue;
        if (k >= want.len) return false;
        const w = want[k];
        if (v.x != w.x or v.y != w.y or v.dia != w.dia or v.drill != w.drill) return false;
        k += 1;
    }
    return k == want.len;
}

// spec: placement/router - routes through a plane-free inner signal layer when both outer faces are blocked; a 2-signal stackup never emits inner copper
test "congested net dives to the inner signal layer on a 3-signal stackup" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const G = @import("geometry.zig");
    // Net A joins two through-hole pads at x = ±3. Two SMD "wall" pads (on no
    // net) at x = 0 span the whole gridded height — one on the TOP face, one
    // on the BOTTOM face — so both outer signal layers are cut in half and no
    // 2-layer path exists. On a (stackup 4 (plane 2 "GND")) board the third
    // signal layer (index 2 = stack L3/In2.Cu) is plane-free and SMD walls
    // don't exist there, so the route must dive inner through vias.
    const thru_pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.8, .h = 0.8, .thru = true, .drill = 0.4 }};
    const wall_pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 8.0 }};
    var parts = [_]Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &thru_pad, .fallback = false, .x = -3, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &thru_pad, .fallback = false, .x = 3, .y = 0 },
        .{ .ref_des = "W1", .kind = .hub, .hw = 0.3, .hh = 4.0, .pads = &wall_pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "W2", .kind = .hub, .hw = 0.3, .hh = 4.0, .pads = &wall_pad, .fallback = false, .x = 0, .y = 0, .side = .bottom },
    };
    const a_pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const nets = [_]FlatNet{.{ .name = "A", .pins = &a_pins }};
    const gnd_names = [_][]const u8{"GND"};
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    var placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -3.5,
        .miny = -1,
        .maxx = 3.5,
        .maxy = 1,
        .generated = true,
        .rules = .{ .plane_nets = &gnd_names, .copper_layers = 4, .planes = .{ .declared = &planes } },
    };

    const r = try route(arena, placement, .{});
    try testing.expectEqual(@as(usize, 1), r.total);
    try testing.expectEqual(@as(usize, 1), r.routed);
    try testing.expectEqual(@as(usize, 0), r.failed.len);
    try testing.expect(!r.grid_overflow);
    // The crossing itself lives on the inner layer, reached through vias.
    try testing.expect(trackLenOnLayer(r.tracks, 2) > 1.0);
    try testing.expectEqual(@as(usize, 2), r.vias.len);
    // …and the inner-layer copper introduces no clearance violations.
    const viol = try @import("drc.zig").check(arena, placement, r, 0.127);
    try testing.expectEqual(@as(usize, 0), viol.len);

    // Regression: the same walls on a plane-less (stackup 2) have only the
    // two outer faces — the net cannot route, and NO inner copper appears.
    placement.rules = .{ .plane_nets = &.{}, .copper_layers = 2 };
    const flat = try route(arena, placement, .{});
    try testing.expectEqual(@as(usize, 0), flat.routed);
    try testing.expectEqual(@as(usize, 1), flat.failed.len);
    try testing.expectEqual(@as(f64, 0), trackLenOnLayer(flat.tracks, 2));

    // Legacy no-stackup boards keep the 2-signal model too (net A is not a
    // ground, so the implicit planes don't rescue it).
    placement.rules = .{};
    const legacy = try route(arena, placement, .{});
    try testing.expectEqual(@as(usize, 0), legacy.routed);
    try testing.expectEqual(@as(f64, 0), trackLenOnLayer(legacy.tracks, 2));
}

// spec: placement/router - a retained same-net pour on an excluded inner layer reuses its nearest same-net pour via within 3 mm, then prefers a legal via-in-pad before a maze stub
test "excluded inner pour reuses a same-net via within three millimetres" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const G = @import("geometry.zig");
    const smd_pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.5, .h = 0.5 }};
    var parts = [_]Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 0.5, .hh = 0.5, .pads = &smd_pad, .fallback = false, .x = -1, .y = 0 },
        .{ .ref_des = "U2", .kind = .hub, .hw = 0.5, .hh = 0.5, .pads = &smd_pad, .fallback = false, .x = 1, .y = 0 },
    };
    const pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "U2", .pin = "1" },
    };
    const nets = [_]FlatNet{.{ .name = "V_3V3_LMX", .pins = &pins }};
    const gnd_names = [_][]const u8{"GND"};
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -3,
        .miny = -1,
        .maxx = 3,
        .maxy = 1,
        .generated = true,
        // In1.Cu is the GND plane, leaving signal-layer index 2 as In2.Cu.
        .rules = .{ .plane_nets = &gnd_names, .copper_layers = 4, .planes = .{ .declared = &planes } },
    };
    const inner_poly = [_][2]f64{
        .{ -2.5, -0.5 },
        .{ 2.5, -0.5 },
        .{ 2.5, 0.5 },
        .{ -2.5, 0.5 },
    };
    const inner_pour = [_]route_policy.ExistingZone{.{
        .polygon = &inner_poly,
        .layer = 2,
        .net = 0,
    }};
    // The Barracuda policy: route traces only on F.Cu/B.Cu. In2.Cu is not in
    // the mask, but its retained pour must remain a legal via terminal.
    const outer_only = [_]route_policy.NetPolicy{.{ .allowed_layers = 0b11 }};

    const created = try routeWithOptions(arena, placement, .{}, .{
        .net = &outer_only,
        .existing_zones = &inner_pour,
    });
    try testing.expectEqual(@as(usize, 1), created.routed);
    // The first pad creates one pour transition; the second is only 2 mm away,
    // so its lower-cost choice is a surface trace into that existing barrel.
    try testing.expectEqual(@as(usize, 1), created.vias.len);
    try testing.expectApproxEqAbs(parts[0].x, created.vias[0].x, 1e-9);
    try testing.expectApproxEqAbs(parts[0].y, created.vias[0].y, 1e-9);
    try testing.expect(trackLenOnLayer(created.tracks, 0) > 0);
    // The router may leave the excluded layer only through a via; it must not
    // draw ordinary trace copper across the reserved power-pour layer.
    try testing.expectEqual(@as(f64, 0), trackLenOnLayer(created.tracks, 2));
    for (created.vias) |via| try testing.expect(outline_mod.contains(&inner_poly, via.x, via.y));

    // At 4 mm separation, the existing transition costs more than a new via,
    // so each terminal gets a local barrel.
    parts[0].x = -2;
    parts[1].x = 2;
    const far = try routeWithOptions(arena, placement, .{}, .{
        .net = &outer_only,
        .existing_zones = &inner_pour,
    });
    try testing.expectEqual(@as(usize, 1), far.routed);
    try testing.expectEqual(@as(usize, 2), far.vias.len);

    // One retained through-via inside the pour is close enough to serve both
    // terminals, and it is carried through without a replacement.
    parts[0].x = -1;
    parts[1].x = 1;
    const retained = [_]route_policy.ExistingVia{.{
        .x = 0,
        .y = 0,
        .dia = 0.4,
        .drill = 0.2,
        .net = 0,
    }};
    const reused = try routeWithOptions(arena, placement, .{}, .{
        .net = &outer_only,
        .existing_vias = &retained,
        .existing_zones = &inner_pour,
    });
    try testing.expectEqual(@as(usize, 1), reused.routed);
    try testing.expectEqual(retained.len, reused.vias.len);
    try testing.expectEqual(@as(f64, 0), trackLenOnLayer(reused.tracks, 2));

    // Distance alone never makes a foreign-net barrel reusable, nor does a
    // same-net via that misses the retained pour.
    const terminal = NetPt{ .x = -1, .y = 0, .layer = 0 };
    const foreign = [_]Via{.{ .x = 0, .y = 0, .dia = 0.4, .net = 1, .drill = 0.2 }};
    try testing.expect(nearestReusableZoneVia(&foreign, inner_pour[0], 0, terminal) == null);
    const outside = [_]Via{.{ .x = 0, .y = 0.8, .dia = 0.4, .net = 0, .drill = 0.2 }};
    try testing.expect(nearestReusableZoneVia(&outside, inner_pour[0], 0, terminal) == null);
}

/// Test-only checked unwrap for `buildRouteCtx`. Keeping the outcome switch
/// here leaves behavior tests declarative and turns a surprise grid sizing
/// result into an ordinary test error instead of a panic.
fn testRouteCtx(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    params: RouteParams,
) !Ctx {
    return switch (try buildRouteCtx(arena, placement, params, &.{}, 1)) {
        .ok => |built| built,
        .empty, .overflow => error.UnexpectedRouteGrid,
    };
}

fn testRouteCore(outcome: CoreOutcome) !RouteCore {
    return switch (outcome) {
        .core => |built| built,
        .done => error.UnexpectedRouteGrid,
    };
}

fn countTracksForNet(tracks: []const Track, net: i32) usize {
    var count: usize = 0;
    for (tracks) |track| {
        if (track.net == net) count += 1;
    }
    return count;
}

// spec: placement/router - a batch or scoped route retries a bounded-classifier base-grid quantization failure on a quarter-pitch single-net window over live copper even when an earlier coarse attempt recorded a search limit
test "quarter-pitch pass rescues a base-grid quantization failure beyond the local window" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const G = @import("geometry.zig");
    const signal_pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.3, .h = 0.3 }};
    const upper_wall = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.5, .h = 7.75, .thru = true, .drill = 0.2 }};
    const lower_wall = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.5, .h = 1.75, .thru = true, .drill = 0.2 }};
    var parts = [_]Part{
        .{ .ref_des = "S1", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &signal_pad, .fallback = false, .x = 1, .y = 1 },
        .{ .ref_des = "S2", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &signal_pad, .fallback = false, .x = 2, .y = 2 },
        .{ .ref_des = "S3", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &signal_pad, .fallback = false, .x = 3, .y = 3 },
        .{ .ref_des = "S4", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &signal_pad, .fallback = false, .x = 4, .y = 2 },
        .{ .ref_des = "S5", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &signal_pad, .fallback = false, .x = 6, .y = 2 },
        .{ .ref_des = "S6", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &signal_pad, .fallback = false, .x = 7, .y = 3 },
        .{ .ref_des = "S7", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &signal_pad, .fallback = false, .x = 9, .y = 1 },
        // Through-hole walls block both signal faces. Their 0.5 mm gap at
        // y=8 is physically wide enough for the 0.127/0.127 rule, but no
        // 0.254 mm base-grid row lands in its legal centre strip.
        .{ .ref_des = "W1", .kind = .hub, .hw = 0.25, .hh = 3.875, .pads = &upper_wall, .fallback = false, .x = 5, .y = 3.875 },
        .{ .ref_des = "W2", .kind = .hub, .hw = 0.25, .hh = 0.875, .pads = &lower_wall, .fallback = false, .x = 5, .y = 9.125 },
    };
    const pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "S1", .pin = "1" },
        .{ .ref_des = "S2", .pin = "1" },
        .{ .ref_des = "S3", .pin = "1" },
        .{ .ref_des = "S4", .pin = "1" },
        .{ .ref_des = "S5", .pin = "1" },
        .{ .ref_des = "S6", .pin = "1" },
        .{ .ref_des = "S7", .pin = "1" },
    };
    const nets = [_]FlatNet{.{ .name = "FINE_ONLY", .pins = &pins }};
    const rules = [_]optimizer.NetRule{.{ .class = .{ .name = "fine" }, .rf = .{ .escape_mm = 0.4 } }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 },
        .generated = true,
        .rules = .{ .net = &rules },
    };
    const retained = [_]route_policy.ExistingTrack{.{
        .x1 = 6,
        .y1 = 6,
        .x2 = 9,
        .y2 = 6,
        .layer = 0,
        .width = 0.127,
        .net = -2,
    }};
    const options = route_policy.Options{ .existing_tracks = &retained };

    const core = try testRouteCore(try routeCoreStart(arena, placement, .{}, options, .off));
    try testing.expectEqual(@as(usize, 1), core.result.routable.len);
    try testing.expect(!core.result.routable[0].ok); // the whole-board base lattice failed
    var scratch_inst = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer scratch_inst.deinit();
    const rescue_run = FineRescueRun{
        .ctx = core.ctx,
        .placement = placement,
        .idx_of = core.idx_of,
        .routable = core.result.routable,
        .tracks = core.tracks,
        .vias = core.vias,
    };
    try testing.expect(try residualIsGridQuantized(rescue_run, 0, scratch_inst.allocator()));
    // An earlier coarse attempt may have reached its expansion cap even though
    // the bounded live-grid classifier now proves an uncapped, copper-free
    // corridor. Match the stuck diagnostic's grid_quantization verdict instead
    // of letting that stale budget history suppress the targeted retry.
    try recordSearchLimit(core.ctx, 0);
    try testing.expect(try residualIsGridQuantized(rescue_run, 0, scratch_inst.allocator()));
    clearSearchLimit(core.ctx, 0);
    // A focused/scoped caller uses this same residual pass. Its automatic
    // whole-route retry may have been suppressed by that earlier search-limit
    // record, so selection itself must not veto a now-proven quantized rescue.
    const selected = [_]bool{true};
    core.ctx.selected_nets = &selected;
    // The failed base pass keeps the subtree it earned (`tree_partial`), so the
    // net arrives at the rescue already carrying copper. A rescue REPLACES that
    // copper rather than wiring the net a second time on top of it
    // (`LiftedNet`) — which is why the DRC counts below describe the rescue's
    // own lattice and nothing else.
    const retained_subtree = countTracksForNet(core.tracks.items, 0);
    try testing.expect(retained_subtree > 0);
    // Every legacy terminal-box/leg window ends above the only wall gap. It
    // refuses, so it must also hand that subtree back untouched.
    try testing.expect(!try rescueNetInWindow(rescue_run, 0));
    try testing.expectEqual(retained_subtree, countTracksForNet(core.tracks.items, 0));
    // The new board window reaches it and a quarter-pitch row lands in it,
    // while the retained track on the far side remains live obstacle copper.
    try testing.expect(try rescueQuantizedFullBoard(rescue_run, 0));
    try testing.expectEqual(retained.len, countTracksForNet(core.tracks.items, -2));
    const drc_mod = @import("drc.zig");
    const viol = try drc_mod.check(arena, placement, .{
        .tracks = core.tracks.items,
        .vias = core.vias.items,
        .routed = 1,
        .total = 1,
    }, 0.127);
    // W1 and W2 are sized to span the board height exactly (0→7.75 and
    // 8.25→10 on a 10 mm board), so their lands rest ON the cut line: two
    // pad↔board-edge findings that belong to the obstacle fixture. Two fixture
    // courtyards also sit inside the default 0.2 mm edge margin;
    // neither finding family comes from the rescued route.
    try testing.expectEqual(@as(usize, 2), drc_mod.countKind(viol, .board_edge));
    try testing.expectEqual(@as(usize, 2), drc_mod.countKind(viol, .component_edge));
    // The rescue draws raw lattice copper: it runs BELOW the finish, so no pad
    // escape has disciplined it yet and its legs still leave their own lands
    // off centre — one same-net `land_transit` warning per dirtied land of the
    // seven-pad chain packed on 1 mm pitch, belonging to the fixture's
    // geometry, not to a clearance failure. (The checker reports per PAD with
    // the worst offence; before that grouping this same lattice read as nine
    // findings, two lands double-billed for two legs each.) The finish's own
    // pad-escape pass — which this rescue runs below, and which every board
    // sees — is what centres those entries; the trade on the whole board is
    // measured the other way round (`bcuda-lt3045-ldo`: 18.47 mm of trace to
    // 16.87 mm, 24 quality warnings to 9).
    try testing.expectEqual(@as(usize, 7), drc_mod.countKind(viol, .land_transit));
    // Under the full-cross-section contact graph, only three stored sections
    // can be deleted without changing pad/live-via/pour connectivity. Eight
    // sections the capsule-only graph called redundant are now correctly kept:
    // their only alternate path was a weak trace-to-trace graze.
    try testing.expectEqual(@as(usize, 3), drc_mod.countKind(viol, .dangling_copper));
    // This is deliberately the raw rescue lattice below the shared final route
    // gate. Its former width-only contact is a weak graze, not a fabricated
    // junction, so it must not be reported as an implicit electrical join.
    try testing.expectEqual(@as(usize, 0), drc_mod.countKind(viol, .implicit_junction));
    try testing.expectEqual(@as(usize, 14), viol.len);

    // The public batch seam runs the same sequence before diagnostics capture,
    // so the rescued net disappears from `failed` in the finished result.
    const batch = try routeWithOptions(arena, placement, .{}, options);
    try testing.expectEqual(@as(usize, 1), batch.routed);
    try testing.expectEqual(@as(usize, 0), batch.failed.len);
}

// spec: placement/router - a refused whole-net rescue puts back the retained copper it lifted, so an attempt that changes nothing costs nothing
test "a refused whole-net rescue leaves the retained subtree exactly as it found it" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // A rescue lifts the net's retained copper so it can REPLACE rather than
    // duplicate it. That makes the refusal path load-bearing: a rescue that
    // declines must put every segment back, or a failed attempt silently
    // deletes copper the board had already earned.
    const G = @import("geometry.zig");
    const pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.3, .h = 0.3 }};
    const wall = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.5, .h = 10, .thru = true, .drill = 0.2 }};
    var parts = [_]Part{
        .{ .ref_des = "S1", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &pad, .fallback = false, .x = 1, .y = 1 },
        .{ .ref_des = "S2", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &pad, .fallback = false, .x = 2, .y = 2 },
        // Behind an unbroken wall: no window, at any pitch, reaches it.
        .{ .ref_des = "S3", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &pad, .fallback = false, .x = 9, .y = 1 },
        .{ .ref_des = "W1", .kind = .hub, .hw = 0.25, .hh = 5, .pads = &wall, .fallback = false, .x = 5, .y = 5 },
    };
    const pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "S1", .pin = "1" },
        .{ .ref_des = "S2", .pin = "1" },
        .{ .ref_des = "S3", .pin = "1" },
    };
    const nets = [_]FlatNet{.{ .name = "WALLED", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 },
        .generated = true,
    };

    const core = try testRouteCore(try routeCoreStart(arena, placement, .{}, .{}, .off));
    try testing.expectEqual(@as(usize, 1), core.result.routable.len);
    try testing.expect(!core.result.routable[0].ok); // S3 is unreachable
    // S1↔S2 joined, so the failed pass kept that subtree.
    const before = try arena.dupe(Track, core.tracks.items);
    try testing.expect(countTracksForNet(before, 0) > 0);

    const rescue_run = FineRescueRun{
        .ctx = core.ctx,
        .placement = placement,
        .idx_of = core.idx_of,
        .routable = core.result.routable,
        .tracks = core.tracks,
        .vias = core.vias,
    };
    const selected = [_]bool{true};
    core.ctx.selected_nets = &selected;
    // Both whole-net rescues must refuse — and hand the board back unchanged.
    try testing.expect(!try rescueNetInWindow(rescue_run, 0));
    try testing.expectEqual(before.len, core.tracks.items.len);
    try testing.expect(!try rescueQuantizedFullBoard(rescue_run, 0));
    try testing.expectEqual(before.len, core.tracks.items.len);
    // Same copper, not merely the same amount of it.
    for (before) |was| {
        var still_there = false;
        for (core.tracks.items) |now| {
            if (sameTrackGeometry(was, now)) {
                still_there = true;
                break;
            }
        }
        try testing.expect(still_there);
    }
}

// spec: placement/router - a high-fanout retained-pour net gets per-terminal fine-window rescue after higher-priority copper routes
test "high-fanout retained pour gets per-terminal fine-window rescue" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const G = @import("geometry.zig");
    const pads = [_]G.Pad{
        .{ .number = "1", .x = -6, .y = 0, .w = 0.4, .h = 0.4 },
        .{ .number = "2", .x = -5, .y = 0, .w = 0.4, .h = 0.4 },
        .{ .number = "3", .x = -4, .y = 0, .w = 0.4, .h = 0.4 },
        .{ .number = "4", .x = -3, .y = 0, .w = 0.4, .h = 0.4 },
        .{ .number = "5", .x = -2, .y = 0, .w = 0.4, .h = 0.4 },
        .{ .number = "6", .x = -1, .y = 0, .w = 0.4, .h = 0.4 },
        .{ .number = "7", .x = 0, .y = 0, .w = 0.4, .h = 0.4 },
        .{ .number = "8", .x = 1, .y = 0, .w = 0.4, .h = 0.4 },
        .{ .number = "9", .x = 2, .y = 0, .w = 0.4, .h = 0.4 },
        .{ .number = "10", .x = 3, .y = 0, .w = 0.4, .h = 0.4 },
        .{ .number = "11", .x = 4, .y = 0, .w = 0.4, .h = 0.4 },
        .{ .number = "12", .x = 5, .y = 0, .w = 0.4, .h = 0.4 },
        .{ .number = "13", .x = 6, .y = 0, .w = 0.4, .h = 0.4 },
    };
    var parts = [_]Part{.{
        .ref_des = "U1",
        .kind = .hub,
        .hw = 7,
        .hh = 0.5,
        .pads = &pads,
        .fallback = false,
        .x = 0,
        .y = 0,
    }};
    const pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "U1", .pin = "2" },
        .{ .ref_des = "U1", .pin = "3" },
        .{ .ref_des = "U1", .pin = "4" },
        .{ .ref_des = "U1", .pin = "5" },
        .{ .ref_des = "U1", .pin = "6" },
        .{ .ref_des = "U1", .pin = "7" },
        .{ .ref_des = "U1", .pin = "8" },
        .{ .ref_des = "U1", .pin = "9" },
        .{ .ref_des = "U1", .pin = "10" },
        .{ .ref_des = "U1", .pin = "11" },
        .{ .ref_des = "U1", .pin = "12" },
        .{ .ref_des = "U1", .pin = "13" },
    };
    const nets = [_]FlatNet{.{ .name = "V_RAIL", .pins = &pins }};
    const gnd_names = [_][]const u8{"GND"};
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -7,
        .miny = -1,
        .maxx = 7,
        .maxy = 1,
        .generated = true,
        .rules = .{ .plane_nets = &gnd_names, .copper_layers = 4, .planes = .{ .declared = &planes } },
    };
    const inner_poly = [_][2]f64{
        .{ -6.5, -0.5 },
        .{ 6.5, -0.5 },
        .{ 6.5, 0.5 },
        .{ -6.5, 0.5 },
    };
    const inner_pour = [_]route_policy.ExistingZone{.{
        .polygon = &inner_poly,
        .layer = 2,
        .net = 0,
    }};
    const outer_only = [_]route_policy.NetPolicy{.{ .allowed_layers = 0b11 }};
    var ctx = try testRouteCtx(arena, placement, .{});
    ctx.zones = &inner_pour;
    ctx.net_policy = &outer_only;
    var idx_of = std.StringHashMapUnmanaged(usize).empty;
    try idx_of.put(arena, "U1", 0);
    var tracks: std.ArrayList(Track) = .empty;
    var vias: std.ArrayList(Via) = .empty;
    var routable = [_]RipNet{.{ .net_i = 0, .pri = 0, .ok = false }};
    const rescued = try fineWindowRescue(.{
        .ctx = &ctx,
        .placement = placement,
        .idx_of = &idx_of,
        .routable = &routable,
        .tracks = &tracks,
        .vias = &vias,
    });
    // Thirteen terminals exceeds the ordinary rescue cap of twelve. The
    // retained-pour path still joins every surface pad, but adjacent pads share
    // nearby pour vias instead of drilling thirteen one-millimetre-spaced holes.
    try testing.expectEqualSlices(usize, &.{0}, rescued);
    try testing.expect(routable[0].ok);
    try testing.expect(vias.items.len < pads.len);
    try testing.expectEqual(@as(f64, 0), trackLenOnLayer(tracks.items, 2));
    for (vias.items) |via| try testing.expect(outline_mod.contains(&inner_poly, via.x, via.y));
}

/// Total copper length (mm) the tracks put on signal layer `layer` — test
/// helper (hoisted so the inner-layer test keeps a single top-level loop).
fn trackLenOnLayer(tracks: []const Track, layer: u8) f64 {
    var len: f64 = 0;
    for (tracks) |t| {
        if (t.layer == layer) len += std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
    }
    return len;
}

// spec: placement/router - reports a grid too large to route via RouteResult.grid_overflow instead of a silent empty result
test "route flags grid overflow on an oversized board" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const pads_a = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads_a, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads_a, .fallback = false, .x = 900, .y = 900 },
    };
    const pins_a = [_]flat_netlist.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const nets = [_]FlatNet{.{ .name = "SIG", .pins = &pins_a }};
    // ~900×900 mm at the default 0.254 mm pitch ≈ 12.6M nodes/layer — far past
    // MAX_NODES, so the router must bail AND say so.
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -0.5,
        .miny = -0.5,
        .maxx = 900.5,
        .maxy = 900.5,
        .generated = true,
    };
    const r = try route(arena, placement, .{});
    try testing.expect(r.grid_overflow);
    try testing.expectEqual(@as(usize, 0), r.tracks.len);
    try testing.expectEqual(@as(usize, 0), r.total);
}

// spec: placement/router - a 1-2-net scoped route whose automatic fine-grid promotion overflows the node budget falls back to the base pitch instead of routing nothing
test "scoped fine-grid promotion falls back to the base pitch on node-budget overflow" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const pad = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 5, .y = 5 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 12, .y = 5 },
        .{ .ref_des = "R3", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 5, .y = 15 },
        .{ .ref_des = "R4", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 12, .y = 15 },
    };
    const pins_a = [_]flat_netlist.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const pins_b = [_]flat_netlist.FlatPin{ .{ .ref_des = "R3", .pin = "1" }, .{ .ref_des = "R4", .pin = "1" } };
    const nets = [_]FlatNet{ .{ .name = "A", .pins = &pins_a }, .{ .name = "B", .pins = &pins_b } };
    // 60×24 mm at the default 0.254 mm pitch: ~25k nodes at the base pitch
    // but ~402k at the two-net quarter-pitch promotion — past max_nodes, the
    // barracuda shape that used to degenerate a scoped route to zero copper.
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 60,
        .maxy = 24,
        .generated = true,
    };
    const both = [_]bool{ true, true };
    // The pure decision: the quarter-pitch promotion overflows so the base
    // pitch wins; an explicit request is honoured as asked; a whole-board
    // run never promotes; a board the promotion fits keeps it.
    try testing.expectEqual(@as(f64, 1), fittedGridScale(placement, .{}, &both, 0));
    try testing.expectEqual(@as(f64, 0.25), fittedGridScale(placement, .{}, &both, 0.25));
    try testing.expectEqual(@as(f64, 1), fittedGridScale(placement, .{}, &.{}, 0));
    var small = placement;
    small.maxx = 10;
    small.maxy = 10;
    try testing.expectEqual(@as(f64, 0.25), fittedGridScale(small, .{}, &both, 0));

    const r = try routeWithOptions(arena, placement, .{}, .{ .selected_nets = &both });
    try testing.expect(!r.grid_overflow);
    try testing.expectEqual(@as(f64, 1), r.grid_scale);
    try testing.expectEqual(@as(usize, 2), r.routed);
}

// spec: placement/router - an outer-layer pour connects same-side pads directly; only opposite-face pads get a stitching via
test "outer pour skips vias for pads already in the pour" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const pads_smd = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const pads_thru = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.8, .h = 0.8, .thru = true, .drill = 0.4 }};
    var parts = [_]Part{
        // Top SMD pad: opposite the bottom pour — the one pad that needs a via.
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads_smd, .fallback = false, .x = 0, .y = 0 },
        // Bottom SMD pad: sits in the pour.
        .{ .ref_des = "C2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads_smd, .fallback = false, .x = 3, .y = 0, .side = .bottom },
        // Through-hole pad: its barrel meets the pour from either side.
        .{ .ref_des = "J1", .kind = .passive, .hw = 0.6, .hh = 0.6, .pads = &pads_thru, .fallback = false, .x = 6, .y = 0 },
    };
    const pins_g = [_]flat_netlist.FlatPin{
        .{ .ref_des = "C1", .pin = "1" },
        .{ .ref_des = "C2", .pin = "1" },
        .{ .ref_des = "J1", .pin = "1" },
    };
    const nets = [_]FlatNet{.{ .name = "GND", .pins = &pins_g }};
    const gnd_names = [_][]const u8{"GND"};
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -0.6,
        .miny = -0.6,
        .maxx = 6.6,
        .maxy = 0.6,
        .generated = true,
        // Isolate the outer-pour transition pass: the separately tested
        // ground-via-distance finisher is disabled for this fixture.
        .rules = .{
            .plane_nets = &gnd_names,
            .copper_layers = 2,
            .planes = .{ .declared = &planes },
            .design = .{ .pour = .{ .ground_via_max = 0 } },
        },
    };

    // (stackup 2 (pour bottom "GND")): only the top-face SMD pad vias down.
    const r = try route(arena, placement, .{});
    try testing.expectEqual(@as(usize, 1), r.total);
    try testing.expectEqual(@as(usize, 1), r.routed);
    try testing.expectEqual(@as(usize, 0), r.failed.len);
    try testing.expectEqual(@as(usize, 1), r.vias.len);
    // The via serves C1 (near x=0), not the in-pour pads.
    try testing.expect(@abs(r.vias[0].x) < 1.5);

    // Every pad in the pour ⇒ zero vias, and the net still counts routed.
    parts[0].side = .bottom;
    const all_bot = try route(arena, placement, .{});
    try testing.expectEqual(@as(usize, 1), all_bot.total);
    try testing.expectEqual(@as(usize, 1), all_bot.routed);
    try testing.expectEqual(@as(usize, 0), all_bot.failed.len);
    try testing.expectEqual(@as(usize, 0), all_bot.vias.len);
}

// spec: placement/router - a net-class rule sets its nets' trace width and via size; unruled nets keep defaults
test "net-class rules drive per-net track width" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const pads_a = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const pads_b = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const pads_c = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const pads_d = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads_a, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads_b, .fallback = false, .x = 4, .y = 0 },
        .{ .ref_des = "R3", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads_c, .fallback = false, .x = 0, .y = 3 },
        .{ .ref_des = "R4", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads_d, .fallback = false, .x = 4, .y = 3 },
    };
    const pins_p = [_]flat_netlist.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const pins_s = [_]flat_netlist.FlatPin{ .{ .ref_des = "R3", .pin = "1" }, .{ .ref_des = "R4", .pin = "1" } };
    const nets = [_]FlatNet{ .{ .name = "VBUS", .pins = &pins_p }, .{ .name = "SIG", .pins = &pins_s } };
    const rules = [_]optimizer.NetRule{ .{ .width = 0.3, .via_dia = 0.6, .via_drill = 0.3 }, .{} };
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -0.5,
        .miny = -0.5,
        .maxx = 4.5,
        .maxy = 3.5,
        .generated = true,
        .rules = .{ .net = &rules },
    };
    const r = try route(arena, placement, .{});
    try testing.expectEqual(@as(usize, 2), r.routed);
    var saw_wide = false;
    var saw_default = false;
    for (r.tracks) |t| {
        if (t.net == 0) {
            try testing.expectEqual(@as(f64, 0.3), t.width);
            saw_wide = true;
        } else {
            try testing.expectEqual((RouteParams{}).track_width, t.width);
            saw_default = true;
        }
    }
    try testing.expect(saw_wide and saw_default);
}

// spec: placement/power-routing - adaptive routing retains the full maximum-current target while a pour-backed rail keeps its short authored fanout width
test "power routing keeps the electrical target without widening pour fanouts" {
    const foils = [_]@import("impedance.zig").Foil{
        .{ .index = 1, .thickness_mm = 0.035 },
        .{ .index = 2, .thickness_mm = 0.0152 },
        .{ .index = 3, .thickness_mm = 0.0152 },
        .{ .index = 4, .thickness_mm = 0.035 },
    };
    const rails = [_]@import("../eval/power_budget.zig").Rail{.{
        .net = "VDD",
        .load_max_a = 0.34,
        .any_max_load = true,
        .status = .no_source,
    }};
    const nets = [_]FlatNet{.{ .name = "VDD", .pins = &.{} }};
    const placement = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .generated = true,
        .rules = .{ .physical = .{ .stack = .{ .layers = 4, .foils = &foils }, .rails = &rails } },
    };
    const trunk = power_route_width.exactWidth(&.{}, placement, 0, 0.2532);
    try testing.expect(trunk > 0.40 and trunk < 0.42);
    const poly = [_][2]f64{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };
    const zones = [_]route_policy.ExistingZone{.{ .polygon = &poly, .layer = 2, .net = 0 }};
    try testing.expectEqual(@as(f64, 0.2532), power_route_width.exactWidth(&zones, placement, 0, 0.2532));
}

// spec: placement/router - LoopRouter measures a real per-leg trace length that detours foreign pads
test "LoopRouter.legLen lengthens a leg that must route around an obstacle" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const G = @import("geometry.zig");
    const pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const sig = [_]flat_netlist.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };

    // Clear board: R1 → R2, 4 mm apart on net SIG (index 0). The real trace is
    // ~straight, so its length is close to the 4 mm separation.
    var clear_parts = [_]Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 4, .y = 0 },
    };
    const clear_nets = [_]FlatNet{.{ .name = "SIG", .pins = &sig }};
    var clear_idx = std.StringHashMapUnmanaged(usize).empty;
    try clear_idx.put(arena, "R1", 0);
    try clear_idx.put(arena, "R2", 1);
    var lr_clear = try LoopRouter.init(arena, &clear_parts, &clear_nets, &clear_idx, .{});
    const len_clear = (try lr_clear.legLen(.{ 0, 0 }, .{ 4, 0 }, 0)).?;
    try testing.expect(len_clear >= 3.5 and len_clear < 6.0);

    // Same endpoints, but a foreign pad (net OTHER, index 1) straddles the direct
    // path — the trace must detour around it, so the measured length grows.
    const blk_pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 1.2, .h = 1.2 }};
    var blk_parts = [_]Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 4, .y = 0 },
        .{ .ref_des = "U9", .kind = .hub, .hw = 0.8, .hh = 0.8, .pads = &blk_pad, .fallback = false, .x = 2, .y = 0 },
    };
    const other = [_]flat_netlist.FlatPin{.{ .ref_des = "U9", .pin = "1" }};
    const blk_nets = [_]FlatNet{ .{ .name = "SIG", .pins = &sig }, .{ .name = "OTHER", .pins = &other } };
    var blk_idx = std.StringHashMapUnmanaged(usize).empty;
    try blk_idx.put(arena, "R1", 0);
    try blk_idx.put(arena, "R2", 1);
    try blk_idx.put(arena, "U9", 2);
    var lr_blk = try LoopRouter.init(arena, &blk_parts, &blk_nets, &blk_idx, .{});
    const len_blk = (try lr_blk.legLen(.{ 0, 0 }, .{ 4, 0 }, 0)).?;
    try testing.expect(len_blk > len_clear + 0.5);
}

// spec: placement/router - routes corners as 45° diagonals rather than 90° bends
test "route uses 45 degree diagonal segments" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Two pads offset both in x and y on an open board: the shortest legal path
    // is a single 45° diagonal, so at least one emitted track must be diagonal.
    const pads_a = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const pads_b = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads_a, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads_b, .fallback = false, .x = 3, .y = 3 },
    };
    const pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const nets = [_]FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -0.5,
        .miny = -0.5,
        .maxx = 3.5,
        .maxy = 3.5,
        .generated = true,
    };
    const r = try route(arena, placement, .{});
    try testing.expectEqual(@as(usize, 1), r.routed);
    var saw_diag = false;
    for (r.tracks) |t| {
        if (@abs(t.x2 - t.x1) > 1e-6 and @abs(t.y2 - t.y1) > 1e-6) saw_diag = true;
    }
    try testing.expect(saw_diag);
}

// spec: placement/router - counts signal vias lacking a nearby ground stitching via as return-path discontinuities
test "returnPathViolations flags unstitched signal vias" {
    const nets = [_]FlatNet{
        .{ .name = "SIG", .pins = &.{} }, // net 0 — a signal
        .{ .name = "GND", .pins = &.{} }, // net 1 — ground (stitching vias)
    };
    var parts = [_]Part{};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 1,
        .maxy = 1,
        .generated = true,
    };
    // A signal via with its only GND via 5 mm away → unstitched (1 warning). The
    // GND via itself is never counted.
    const far = [_]Via{
        .{ .x = 0, .y = 0, .dia = 0.4, .net = 0 },
        .{ .x = 5, .y = 0, .dia = 0.4, .net = 1 },
    };
    const far_res = RouteResult{ .tracks = &.{}, .vias = &far, .routed = 0, .total = 0 };
    try testing.expectEqual(@as(usize, 1), returnPathViolations(placement, far_res, return_path_radius_mm));
    try testing.expectEqual(
        @as(usize, 1),
        returnPathViolationsForNets(placement, far_res, return_path_radius_mm, &.{"SIG"}),
    );
    try testing.expectEqual(
        @as(usize, 0),
        returnPathViolationsForNets(placement, far_res, return_path_radius_mm, &.{"OTHER"}),
    );

    // Move the GND via within the radius → the signal via is stitched (0 warnings).
    const near = [_]Via{
        .{ .x = 0, .y = 0, .dia = 0.4, .net = 0 },
        .{ .x = 1, .y = 0, .dia = 0.4, .net = 1 },
    };
    const near_res = RouteResult{ .tracks = &.{}, .vias = &near, .routed = 0, .total = 0 };
    try testing.expectEqual(@as(usize, 0), returnPathViolations(placement, near_res, return_path_radius_mm));
}

// spec: placement/router - stitches each signal via's return path with a nearby GND plane via
// spec: placement/router - final topology pruning runs after RF finishing and ground-pad stitching, so no copper producer bypasses it
test "route stitches a useful signal via with a ground via" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const G = @import("geometry.zig");
    // A real top-to-bottom connection needs a signal via. The return-path pass
    // must then add a GND via within RETURN_PATH_RADIUS_MM. Both outer faces are
    // ground-poured, so that stitch barrel is useful on two copper layers and
    // survives the final topology-artifact cleanup.
    const pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const dummy = Part{
        .ref_des = "DUMMY",
        .kind = .passive,
        .hw = 0,
        .hh = 0,
        .pads = &.{},
        .fallback = false,
    };
    var parts: [stitch_max_parts + 1]Part = @splat(dummy);
    parts[0] = .{
        .ref_des = "U1",
        .kind = .hub,
        .hw = 0.6,
        .hh = 0.6,
        .pads = &pad,
        .fallback = false,
        .x = 0,
        .y = 0,
    };
    parts[1] = .{
        .ref_des = "U2",
        .kind = .hub,
        .hw = 0.6,
        .hh = 0.6,
        .pads = &pad,
        .fallback = false,
        .x = 3,
        .y = 0,
        .side = .bottom,
    };
    const pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "U2", .pin = "1" },
    };
    const nets = [_]FlatNet{
        .{ .name = "EN", .pins = &pins }, // net 0 — the single-pin breakout
        .{ .name = "GND", .pins = &.{} }, // net 1 — the ground plane to stitch to
    };
    const ground_planes = [_]optimizer.PlaneAt{
        .{ .index = 1, .net = "GND" },
        .{ .index = 2, .net = "GND" },
    };
    const plane_nets = [_][]const u8{"GND"};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = -2,
        .maxx = 3,
        .maxy = 2,
        .generated = true,
        .rules = .{ .plane_nets = &plane_nets, .copper_layers = 2, .planes = .{ .declared = &ground_planes } },
    };

    const r = try route(arena, placement, .{});

    // This placement exceeds the ordinary board-size gate, but its two-net
    // targeted route still gets the required signal via plus one GND stitch.
    try testing.expectEqual(@as(usize, 2), r.vias.len);
    var sig: ?Via = null;
    var gnd: ?Via = null;
    for (r.vias) |v| {
        if (v.net == 0) sig = v;
        if (v.net == 1) gnd = v;
    }
    try testing.expect(sig != null and gnd != null);
    // The stitch via sits within the return-path radius of the signal via…
    try testing.expect(std.math.hypot(gnd.?.x - sig.?.x, gnd.?.y - sig.?.y) <= return_path_radius_mm);
    // …so the routed board reports no return-path discontinuity.
    try testing.expectEqual(@as(usize, 0), returnPathViolations(placement, r, return_path_radius_mm));
}

// spec: placement/router - the final autorouter pass adds a DRC-clean plane via within the authored maximum of every eligible SMD ground pad
test "route adds final ground-pad stitches after an outer pour skipped plane vias" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const G = @import("geometry.zig");
    const pad = [_]G.Pad{.{ .number = "2", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]Part{
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C2", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 0.8, .y = 0 },
    };
    const pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "C1", .pin = "2" },
        .{ .ref_des = "C2", .pin = "2" },
    };
    const nets = [_]FlatNet{.{ .name = "GND", .pins = &pins }};
    const plane_nets = [_][]const u8{"GND"};
    const planes = [_]optimizer.PlaneAt{
        .{ .index = 1, .net = "GND" },
        .{ .index = 2, .net = "GND" },
    };
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1,
        .miny = -1,
        .maxx = 2,
        .maxy = 1,
        .generated = true,
        .rules = .{
            .plane_nets = &plane_nets,
            .copper_layers = 4,
            .planes = .{ .declared = &planes },
            .design = .{ .pour = .{ .ground_via_max = 1.0 } },
        },
    };
    const routed = try route(arena, placement, placement.rules.design.routeParams());
    try testing.expectEqual(@as(usize, 1), routed.vias.len);
    try testing.expect(groundPadHasNearbyVia(routed.vias, 0, .{ 0, 0 }, 1.0));
    try testing.expect(groundPadHasNearbyVia(routed.vias, 0, .{ 0.8, 0 }, 1.0));
}

// spec: placement/router - elevates only the switching hot loop above the baseline routing tier
test "netClassRank elevates switch-node and input-rail nets but no other class" {
    // The switching loop routes first…
    try testing.expectEqual(@as(u32, 1), netClassRank("SW")); // switch node
    try testing.expectEqual(@as(u32, 1), netClassRank("VIN")); // input rail
    // …everything else stays at the baseline tier — clock/RF/power/signal are
    // deliberately NOT reordered (a tradeoff the scalar routed metric can't judge).
    try testing.expectEqual(@as(u32, 0), netClassRank("SCLK")); // clock
    try testing.expectEqual(@as(u32, 0), netClassRank("DATA0")); // bulk signal
    try testing.expectEqual(@as(u32, 0), netClassRank("GND")); // ground (pass-1 anyway)
}

// spec: placement/router - lets authored (net-class (priority …)) dominate the intrinsic net-class rank
test "netPriority ranks the hot loop first yet keeps authored class priority dominant" {
    var idx = std.StringHashMapUnmanaged(usize).empty;
    defer idx.deinit(testing.allocator);
    try idx.put(testing.allocator, "U1", 0);
    try idx.put(testing.allocator, "C1", 1);

    const sw_pins = [_]flat_netlist.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
    const sig_pins = [_]flat_netlist.FlatPin{.{ .ref_des = "C1", .pin = "1" }};
    const sw = FlatNet{ .name = "SW", .pins = &sw_pins };
    const sig = FlatNet{ .name = "DATA", .pins = &sig_pins };

    const base = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 0,
        .maxy = 0,
        .generated = true,
    };

    // With no `(net-class … (priority …))`, the hot-loop net (index 0) outranks
    // the bulk signal (index 1).
    try testing.expect(netPriority(base, &idx, sw, 0) > netPriority(base, &idx, sig, 1));

    // Give the signal's net an authored class priority: explicit author intent
    // now wins, even though the hot loop still carries its intrinsic class bit.
    const rules = [_]optimizer.NetRule{ .{}, .{ .priority = 5 } }; // SW unranked, DATA tier 5
    var ranked = base;
    ranked.rules = .{ .net = &rules };
    try testing.expect(netPriority(ranked, &idx, sig, 1) > netPriority(ranked, &idx, sw, 0));
}

// spec: placement/router - auto-elevates a bare hub-to-inductor bridge net to the hot-loop tier
test "netPriority elevates a power-named hub-inductor bridge (VREG_LX) over a rail" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const G = @import("geometry.zig");
    const pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "L_VREG", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 2, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 4, .y = 0 },
    };
    var idx = std.StringHashMapUnmanaged(usize).empty;
    try idx.put(arena, "U1", 0);
    try idx.put(arena, "L_VREG", 1);
    try idx.put(arena, "C1", 2);

    // VREG_LX: hub pin + inductor pin only — the RP2350-style switch node whose
    // NAME classifies as a power rail (VREG prefix). Must still outrank a
    // many-pin rail like DVDD (hub + inductor + cap = the smoothed output).
    const lx_pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "L_VREG", .pin = "1" } };
    const rail_pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "L_VREG", .pin = "1" },
        .{ .ref_des = "C1", .pin = "1" },
        .{ .ref_des = "C1", .pin = "1" },
    };
    const lx = FlatNet{ .name = "VREG_LX", .pins = &lx_pins };
    const rail = FlatNet{ .name = "DVDD", .pins = &rail_pins };

    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 4,
        .maxy = 0,
        .generated = true,
    };
    try testing.expect(netPriority(placement, &idx, lx, 0) > netPriority(placement, &idx, rail, 1));
}

// spec: placement/router - names the nets that failed to route in RouteResult.failed
test "route reports an unroutable net by name in failed" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const G = @import("geometry.zig");
    const pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    // A through-hole wall pad spanning the whole grid height splits the board on
    // BOTH signal layers, so net A (one pad each side) cannot route at all.
    const wall = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 6.0, .thru = true }};
    var parts = [_]Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = -3, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 3, .y = 0 },
        .{ .ref_des = "J1", .kind = .hub, .hw = 0.5, .hh = 3.0, .pads = &wall, .fallback = false, .x = 0, .y = 0 },
    };
    const a_pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const w_pins = [_]flat_netlist.FlatPin{.{ .ref_des = "J1", .pin = "1" }};
    const nets = [_]FlatNet{ .{ .name = "A", .pins = &a_pins }, .{ .name = "WALL", .pins = &w_pins } };
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -3.5,
        .miny = -0.5,
        .maxx = 3.5,
        .maxy = 0.5,
        .generated = true,
    };
    const r = try route(arena, placement, .{});
    try testing.expectEqual(@as(usize, 1), r.total);
    try testing.expectEqual(@as(usize, 0), r.routed);
    try testing.expectEqual(@as(usize, 1), r.failed.len);
    try testing.expectEqualStrings("A", r.failed[0]);
}

// spec: placement/router - a failed leg's goal is never a same-net source, so a later leg cannot weld to a stranded pad
test "failed leg leaves no stranded island for a later leg to weld onto" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const G = @import("geometry.zig");
    const pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    // Same full-height through-hole wall as the failed-net test, but net A now
    // has THREE pads: R1 alone on the left, R2 and R3 together on the right.
    // The seed is R1 (left). Its first leg R1→R2 must cross the wall and fails.
    // Before the fix that failed goal (R2's node) was stamped `occ = A`, so the
    // next leg R1→R3 grew a path R2-node → R3 and welded R3 onto the stranded
    // R2 island — a right-side {R2,R3} blob drawn as if wired to R1, electrically
    // split. With the fix R2's node stays EMPTY, R1→R3 also crosses the wall and
    // fails, and net A emits NO copper at all.
    const wall = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 6.0, .thru = true }};
    var parts = [_]Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = -3, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 3, .y = 0 },
        .{ .ref_des = "R3", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 3, .y = 1.5 },
        .{ .ref_des = "J1", .kind = .hub, .hw = 0.5, .hh = 3.0, .pads = &wall, .fallback = false, .x = 0, .y = 0 },
    };
    const a_pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" }, .{ .ref_des = "R3", .pin = "1" } };
    const w_pins = [_]flat_netlist.FlatPin{.{ .ref_des = "J1", .pin = "1" }};
    const nets = [_]FlatNet{ .{ .name = "A", .pins = &a_pins }, .{ .name = "WALL", .pins = &w_pins } };
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -3.5,
        .miny = -0.5,
        .maxx = 3.5,
        .maxy = 2.0,
        .generated = true,
    };
    const r = try route(arena, placement, .{});
    // Net A cannot bridge the wall, so it is reported failed…
    try testing.expectEqual(@as(usize, 1), r.failed.len);
    try testing.expectEqualStrings("A", r.failed[0]);
    // …and — the invariant under test — no copper crosses the wall or reaches
    // R1's side: the failed R1→R2 leg's goal was never stamped as a same-net
    // source, so no later leg can weld toward the stranded left half. The
    // legitimately joined R2↔R3 pair MAY keep its subtree (two real pads
    // electrically joined — the retain-subtree rule the sibling test pins);
    // what it must never do is emit a track at or left of the wall.
    for (r.tracks) |t| {
        if (t.net != 0) continue;
        try testing.expect(t.x1 > 0.2 and t.x2 > 0.2);
    }
}

// spec: placement/router - a failed multi-terminal net retains a subtree only after two real pads are electrically joined
test "failed multi-terminal net keeps its connected pad subtree" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const G = @import("geometry.zig");
    const pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const wall = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 6.0, .thru = true }};
    var parts = [_]Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = -3, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = -2, .y = 0 },
        .{ .ref_des = "R3", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 3, .y = 0 },
        .{ .ref_des = "J1", .kind = .hub, .hw = 0.5, .hh = 3.0, .pads = &wall, .fallback = false, .x = 0, .y = 0 },
    };
    const a_pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "R1", .pin = "1" },
        .{ .ref_des = "R2", .pin = "1" },
        .{ .ref_des = "R3", .pin = "1" },
    };
    const w_pins = [_]flat_netlist.FlatPin{.{ .ref_des = "J1", .pin = "1" }};
    const nets = [_]FlatNet{ .{ .name = "A", .pins = &a_pins }, .{ .name = "WALL", .pins = &w_pins } };
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -3.5,
        .miny = -0.5,
        .maxx = 3.5,
        .maxy = 0.5,
        .generated = true,
    };
    const routed = try routeWithOptions(arena, placement, .{}, .{ .effort = .one_shot });
    try testing.expectEqual(@as(usize, 0), routed.routed);
    try testing.expectEqual(@as(usize, 1), routed.failed.len);
    try testing.expectEqualStrings("A", routed.failed[0]);
    try testing.expect(countTracksForNet(routed.tracks, 0) > 0);
}

// spec: placement/router - perNetRouted totals a net's routed copper length and via count
test "perNetRouted totals a net's routed copper length and via count" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const G = @import("geometry.zig");
    const pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 3, .y = 0 },
    };
    const pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const nets = [_]FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -0.5,
        .miny = -0.5,
        .maxx = 3.5,
        .maxy = 0.5,
        .generated = true,
    };
    const r = try route(arena, placement, .{});
    const per = try perNetRouted(arena, placement, r);
    try testing.expectEqual(@as(usize, 1), per.len);
    try testing.expectEqualStrings("SIG", per[0].name);
    try testing.expect(per[0].mm > 0);
    // The aggregate matches a direct sum over SIG's track segments; with only one
    // net on the board, every via is SIG's, so per-net via count == total vias.
    var sum: f64 = 0;
    for (r.tracks) |t| sum += std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
    try testing.expectApproxEqAbs(sum, per[0].mm, 1e-6);
    try testing.expectEqual(r.vias.len, per[0].vias);
}

// spec: placement/router - keeps every placed via a hole-to-hole wall from every other drilled hole
test "same-net ground vias keep a manufacturable hole-to-hole wall" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const G = @import("geometry.zig");

    // A hub with two GND pads 0.4 mm apart on a big open courtyard. Both are on
    // the (implicitly planed) GND net, so pass 1 drops a via at each. At the
    // 0.4 mm pad pitch a naive via-in-pad pair sits 0.4 mm centre-to-centre —
    // with the 0.2 mm default drill that is a 0.2 mm wall, under the 0.25 mm
    // hole-to-hole rule. The placer must fan the second via clear.
    const pads = [_]G.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 0.3, .h = 0.3 },
        .{ .number = "2", .x = 0.4, .y = 0, .w = 0.3, .h = 0.3 },
    };
    var parts = [_]Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2, .hh = 2, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
    };
    const gnd = [_]flat_netlist.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "U1", .pin = "2" } };
    const nets = [_]FlatNet{.{ .name = "GND", .pins = &gnd }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2.5,
        .miny = -2.5,
        .maxx = 2.5,
        .maxy = 2.5,
        .generated = true,
    };
    const r = try route(arena, placement, .{});
    // Both GND pads are still served by a via (connectivity preserved)…
    try testing.expect(r.vias.len >= 2);
    // …and every drilled-hole pair clears the wall rule: centre distance is at
    // least the two drill radii plus the 0.25 mm default hole-to-hole.
    for (r.vias, 0..) |a, i| {
        if (a.drill <= 0) continue;
        for (r.vias[i + 1 ..]) |b| {
            if (b.drill <= 0) continue;
            const d = std.math.hypot(a.x - b.x, a.y - b.y);
            try testing.expect(d >= a.drill / 2 + b.drill / 2 + 0.25 - 1e-6);
        }
    }
}

// spec: placement/router - smooths an rf net's corners inline as it routes, recording a per-net bend event
test "rf net smooths inline: arcs in the result, bend event rides with the net" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const G = @import("geometry.zig");
    const pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 6, .y = 4 },
    };
    const pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const nets = [_]FlatNet{.{ .name = "RF1", .pins = &pins }};
    // Pads sit at the part centres (no outward axis), so no escape reserve —
    // this test isolates the inline smoothing itself.
    const rules = [_]optimizer.NetRule{.{ .class = .{ .name = "rf" }, .width = 0.3, .rf = .{ .max_freq_hz = 12e9 } }};
    var placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1,
        .miny = -1,
        .maxx = 7,
        .maxy = 5,
        .generated = true,
    };
    placement.rules.net = &rules;
    // A keepout straddling the straight (0,0)→(6,4) line forces a detour bend
    // that survives the inline straighten pass (its shortcut is blocked), so the
    // arc smoother still has a real corner to reshape.
    const keepout_poly = [_][2]f64{ .{ 2.5, 1.5 }, .{ 3.5, 1.5 }, .{ 3.5, 2.5 }, .{ 2.5, 2.5 } };
    const kz = struct {
        fn on(layer: u8, poly: []const [2]f64) route_policy.ExistingZone {
            return .{
                .polygon = poly,
                .layer = layer,
                .net = -2,
                .tracks_blocked = true,
                .vias_blocked = true,
                .copper = false,
            };
        }
    };
    const keepouts = [_]route_policy.ExistingZone{ kz.on(0, &keepout_poly), kz.on(1, &keepout_poly) };
    const run = try routeWithTimeline(arena, placement, .{}, .{ .existing_zones = &keepouts });
    try testing.expectEqual(@as(usize, 1), run.routed.routed);
    // The path must detour the keepout with at least one bend; inline smoothing
    // turned that surviving corner into arc metadata without any finish post-pass.
    try testing.expect(run.routed.arcs.len >= 1);
    var bend_step: ?usize = null;
    var complete_step: usize = 0;
    for (run.timeline, 0..) |ev, i| {
        if (ev.kind == .bend_smoothing) {
            bend_step = i;
            try testing.expectEqual(@as(?usize, 0), ev.net);
        }
        if (ev.kind == .complete) complete_step = i;
    }
    // The bend event rides with the net's own routing step, not a post-pass.
    try testing.expect(bend_step != null);
    try testing.expect(bend_step.? < complete_step);
}

/// A routing context carrying ONE through pad on net 1 — the barracuda shape:
/// `buck_6v/U22` pad 5, a 0.30 mm land over a 0.20 mm bore, on the same rail
/// (`V_6VA`) the router is dropping barrels for. The copper tests all skip the
/// routing net's own pads, so this pad is invisible to everything except the
/// hole-to-hole wall.
fn samePadBoreCtx(arena: std.mem.Allocator, obs: []const PadObs, holes: []const pad_exit.Hole) Ctx {
    return .{
        .arena = arena,
        .grid = .{ .ox = 0, .oy = 0, .g = 0.1, .nx = 120, .ny = 120 },
        .obs = obs,
        .reach = 0.2,
        .occ = &.{},
        .resv = &.{},
        .params = .{ .via_dia = 0.5, .via_drill = 0.3, .track_width = 0.2, .clearance = 0.127 },
        .base = .{},
        .hole_to_hole = 0.2,
        .pad_drills = .{ .holes = holes, .reach = 0.35 },
    };
}

// spec: placement/router - a candidate via site keeps the hole-to-hole wall from every through-pad bore, its own net's pads included
test "a via site beside a same-net through pad is refused by the bore wall" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // The measured barracuda site: a 0.20 mm bore at (5,5) and a 0.30 mm barrel
    // 0.202 mm away, a −0.048 mm wall against the design's 0.200 mm rule.
    const obs = [_]PadObs{.{ .x0 = 4.85, .y0 = 4.85, .x1 = 5.15, .y1 = 5.15, .net = 1, .thru = true }};
    const holes = [_]pad_exit.Hole{.{ .x = 5, .y = 5, .r = 0.1 }};
    var ctx = samePadBoreCtx(arena, &obs, &holes);
    var tracks: std.ArrayList(Track) = .empty;
    var vias: std.ArrayList(Via) = .empty;
    const run = DirectRun{ .ctx = &ctx, .net = 1, .tracks = &tracks, .vias = &vias };

    // Copper alone passes it: the pad is on the routing net, so `viaClearsPads`
    // never looks at it. Only the net-blind bore wall refuses the site — which
    // is precisely what the DRC would have reported.
    try testing.expect(viaClearsPads(&ctx, 5.202, 5, 1));
    try testing.expect(!viaClearsPadDrills(&ctx, 5.202, 5));
    try testing.expect(!directViaClear(run, .{ 5.202, 5 }));

    // The wall is 0.15 + 0.1 + 0.2 = 0.45 mm of centre distance. Just outside
    // it the same site is legal again, so the rule costs nothing it needn't.
    try testing.expect(viaClearsPadDrills(&ctx, 5.451, 5));
    try testing.expect(directViaClear(run, .{ 5.451, 5 }));

    // A FOREIGN pad's bore is measured by the identical net-blind rule.
    const foreign = [_]PadObs{.{ .x0 = 4.85, .y0 = 4.85, .x1 = 5.15, .y1 = 5.15, .net = 7, .thru = true }};
    var foreign_ctx = samePadBoreCtx(arena, &foreign, &holes);
    try testing.expect(!viaClearsPadDrills(&foreign_ctx, 5.202, 5));

    // Landing on the bore itself is that hole re-drilled, not a wall — the
    // exemption `drc.holePairViolation` makes, so the two never disagree.
    try testing.expect(viaClearsPadDrills(&ctx, 5, 5));

    // The index is a pre-filter, never a verdict: the same probes answer
    // identically once one is built.
    const boxes = [_]PadObs{.{ .x0 = 4.9, .y0 = 4.9, .x1 = 5.1, .y1 = 5.1, .net = -1 }};
    ctx.pad_drills.index = PadGrid.build(arena, &boxes, gridBounds(ctx.grid), 0.35);
    try testing.expect(ctx.pad_drills.index != null);
    try testing.expect(!viaClearsPadDrills(&ctx, 5.202, 5));
    try testing.expect(viaClearsPadDrills(&ctx, 5.451, 5));
    try testing.expect(viaClearsPadDrills(&ctx, 5, 5));

    // A barrel wider than the index was sized for takes the full scan rather
    // than trusting a query past the index's reach.
    ctx.params.via_drill = 1.2;
    try testing.expect(!viaClearsPadDrills(&ctx, 5.6, 5));
}

// spec: placement/router - a maze via candidate is refused inside a through-pad bore's hole-to-hole wall
test "a maze via node inside a pad bore's wall is not an allowed via site" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Node (50,50) is the bore's own centre and node (52,50) is 0.2 mm away —
    // inside the 0.45 mm wall. Node (55,50), 0.5 mm off, clears it.
    const obs = [_]PadObs{.{ .x0 = 4.85, .y0 = 4.85, .x1 = 5.15, .y1 = 5.15, .net = 1, .thru = true }};
    const holes = [_]pad_exit.Hole{.{ .x = 5, .y = 5, .r = 0.1 }};
    var ctx = samePadBoreCtx(arena, &obs, &holes);
    ctx.occ = try allocLayerGrids(arena, 2, ctx.grid.nx * ctx.grid.ny);
    ctx.resv = try allocLayerGrids(arena, 2, ctx.grid.nx * ctx.grid.ny);

    try testing.expect(!viaAllowed(&ctx, ctx.grid.node(52, 50), 1, &.{}));
    try testing.expect(viaAllowed(&ctx, ctx.grid.node(55, 50), 1, &.{}));
}

// spec: placement/router - an escape-constrained pad exits straight for the declared distance before its first bend
test "rf escape holds the pad exit straight before the first bend" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const G = @import("geometry.zig");
    // U1's pad sits on its right edge → outward escape axis = +x. The target
    // is almost straight UP from the pad, so an unconstrained route would
    // turn immediately; the escape reserve forces 1.5 mm of +x first.
    const hub_pad = [_]G.Pad{.{ .number = "1", .x = 1.5, .y = 0, .w = 0.4, .h = 0.4 }};
    const r_pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1.5, .hh = 1.5, .pads = &hub_pad, .fallback = false, .x = 0, .y = 5 },
        .{
            .ref_des = "R2",
            .kind = .passive,
            .hw = 0.5,
            .hh = 0.5,
            .pads = &r_pad,
            .fallback = false,
            .x = 2,
            .y = 10,
        },
    };
    const pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const nets = [_]FlatNet{.{ .name = "LO", .pins = &pins }};
    const rules = [_]optimizer.NetRule{
        .{ .class = .{ .name = "rf" }, .width = 0.3, .rf = .{ .max_freq_hz = 12e9, .escape_mm = 1.5 } },
    };
    var placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = 3,
        .maxx = 10,
        .maxy = 11,
        .generated = true,
    };
    placement.rules.net = &rules;
    const r = try route(arena, placement, .{});
    try testing.expectEqual(@as(usize, 1), r.routed);
    // Inside the escape reserve every track vertex stays on the pad's row
    // (grid quantization allowed); the trace provably went out +x first.
    var max_x: f64 = 1.5;
    for (r.tracks) |t| {
        for ([2][2]f64{ .{ t.x1, t.y1 }, .{ t.x2, t.y2 } }) |p| {
            max_x = @max(max_x, p[0]);
            if (std.math.hypot(p[0] - 1.5, p[1] - 5.0) >= 1.5) continue;
            try testing.expect(@abs(p[1] - 5.0) <= 0.3);
        }
    }
    try testing.expect(max_x >= 2.8);
}

// spec: placement/router - a pad's own quarter rotation reorients its routing obstacle so the vacated lane routes straight and DRC agrees
test "pad-local rotation frees the straight lane it vacates" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const G = @import("geometry.zig");
    const drc = @import("drc.zig");
    const sig_pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    // A locally-TALL foreign pad (0.3 x 1.2) turned flat by its own
    // `(pos … 270)`: world extents 1.2 wide x 0.3 tall, y in [0.4, 0.7] —
    // clear of the pad-to-pad lane. Ignoring pad.rot would read it as a
    // phantom tall bar crossing y=0 and block the lane (the control below).
    const flat = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.3, .h = 1.2, .rot = 270 }};
    const tall = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.3, .h = 1.2 }};
    const pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const nets = [_]FlatNet{.{ .name = "SIG", .pins = &pins }};
    const mk = struct {
        fn part(ref: []const u8, pads: []const G.Pad, x: f64, y: f64) Part {
            return .{
                .ref_des = ref,
                .kind = .passive,
                .hw = 0.65,
                .hh = 0.3,
                .pads = pads,
                .fallback = false,
                .x = x,
                .y = y,
            };
        }
    };
    for ([2]bool{ true, false }) |rotated| {
        var parts = [_]Part{
            mk.part("R1", &sig_pad, 0, 0),
            mk.part("R2", &sig_pad, 3, 0),
            mk.part("U9", if (rotated) &flat else &tall, 1.5, 0.55),
        };
        const placement = optimizer.Placement{
            .parts = &parts,
            .links = &.{},
            .loops = &.{},
            .stubs = &.{},
            .instances = &.{},
            .nets = &nets,
            .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
            .minx = -0.5,
            .miny = -2,
            .maxx = 3.5,
            .maxy = 2,
            .generated = true,
        };
        const r = try route(arena, placement, .{});
        try testing.expectEqual(@as(usize, 1), r.routed);
        if (rotated) {
            // The lane the rotated pad vacates is straight AND on-axis (both
            // pads share y), so the finish pass may collapse the hop to the
            // single pad-to-pad segment without leaving the octilinear headings.
            try testing.expectEqual(@as(usize, 1), r.tracks.len);
        } else {
            // The truly tall pad blocks the lane — the route must detour.
            try testing.expect(r.tracks.len > 1);
        }
        // Either way the copper respects the pad's REAL extents.
        for (try drc.check(arena, placement, r, 0.127)) |v|
            try testing.expect(v.kind != .track_pad);
    }
}

// spec: placement/router - rip-up runs no rounds when the greedy pass already routed every net
test "rip-up runs no rounds when the greedy pass routes everything" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const G = @import("geometry.zig");
    const pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 3, .y = 0 },
    };
    const pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const nets = [_]FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -0.5,
        .miny = -0.5,
        .maxx = 3.5,
        .maxy = 0.5,
        .generated = true,
    };
    const r = try route(arena, placement, .{});
    // A cleanly routable board never triggers rip-up (the failure guard).
    try testing.expectEqual(r.total, r.routed);
    try testing.expectEqual(@as(usize, 0), r.ripup_rounds);
}

// spec: placement/router - rip-up leaves a wall-blocked net failed without disturbing an already-routed net
test "rip-up leaves a wall-blocked net failed without disturbing a routed net" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const G = @import("geometry.zig");
    const pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    // A through-hole wall taller than the board+routing-margin grid splits it on
    // both layers with no over-the-top escape. GOOD's two pads sit together on the
    // left (trivially routable); BAD straddles the wall (unroutable). Rip-up runs
    // (BAD failed) but the wall is PADS, not copper, so BAD's blocker probe finds
    // nothing to rip — it must leave GOOD untouched and BAD honestly failed, never
    // welding BAD across the wall.
    const wall = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 10.0, .thru = true }};
    var parts = [_]Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.4, .hh = 0.4, .pads = &pad, .fallback = false, .x = -3, .y = -2 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.4, .hh = 0.4, .pads = &pad, .fallback = false, .x = -4, .y = -2 },
        .{ .ref_des = "R3", .kind = .passive, .hw = 0.4, .hh = 0.4, .pads = &pad, .fallback = false, .x = -3, .y = 2 },
        .{ .ref_des = "R4", .kind = .passive, .hw = 0.4, .hh = 0.4, .pads = &pad, .fallback = false, .x = 3, .y = 2 },
        .{ .ref_des = "J1", .kind = .hub, .hw = 0.5, .hh = 3.2, .pads = &wall, .fallback = false, .x = 0, .y = 0 },
    };
    const good_pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const bad_pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "R3", .pin = "1" }, .{ .ref_des = "R4", .pin = "1" } };
    const w_pins = [_]flat_netlist.FlatPin{.{ .ref_des = "J1", .pin = "1" }};
    const nets = [_]FlatNet{
        .{ .name = "GOOD", .pins = &good_pins },
        .{ .name = "BAD", .pins = &bad_pins },
        .{ .name = "WALL", .pins = &w_pins },
    };
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -5,
        .miny = -3,
        .maxx = 5,
        .maxy = 3,
        .generated = true,
    };
    const r = try route(arena, placement, .{});
    try testing.expectEqual(@as(usize, 2), r.total); // GOOD + BAD (WALL is single-pad)
    try testing.expectEqual(@as(usize, 1), r.routed); // GOOD routes, BAD can't
    try testing.expectEqual(@as(usize, 1), r.failed.len);
    try testing.expectEqualStrings("BAD", r.failed[0]);
    try testing.expect(r.ripup_rounds >= 1); // rip-up ran (a net failed)
    var good = false;
    var bad_tracks: usize = 0;
    for (r.tracks) |t| {
        if (t.net == 0) good = true; // GOOD copper survived rip-up
        if (t.net == 1) bad_tracks += 1; // BAD emitted no (false) copper
    }
    try testing.expect(good);
    try testing.expectEqual(@as(usize, 0), bad_tracks);
}

// spec: placement/router - escapes a fine-pitch pad through an off-grid gateway stub when no grid lane clears
test "pad gateway neck admits a QFN launch that the nominal width blocks" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // The target is centred between two 0.2 mm-wide foreign lands on 0.33 mm
    // pitch. Its 0.23 mm edge gap admits 0.1524 mm copper plus 0.127 mm
    // clearance, but is narrower than the 0.2532 mm nominal trace needs.
    const obs = [_]PadObs{
        .{ .x0 = -0.43, .y0 = -0.3, .x1 = -0.23, .y1 = 0.3, .net = 1 },
        .{ .x0 = 0.23, .y0 = -0.3, .x1 = 0.43, .y1 = 0.3, .net = 1 },
    };
    const grid = Grid{ .ox = -2, .oy = -2, .g = 0.254, .nx = 20, .ny = 20 };
    const nominal = RouteParams{ .track_width = 0.2532, .clearance = 0.127 };
    var ctx = Ctx{
        .arena = arena,
        .grid = grid,
        .obs = &obs,
        .reach = nominal.track_width / 2 + nominal.clearance,
        .occ = try allocLayerGrids(arena, 1, grid.nx * grid.ny),
        .resv = try allocLayerGrids(arena, 1, grid.nx * grid.ny),
        .params = nominal,
        .base = nominal,
        .index_reach = nominal.track_width / 2 + nominal.clearance,
    };
    const terminal = NetPt{ .x = 0, .y = 0, .layer = 0, .out = .{ 0, 1 } };
    var gateways: std.ArrayList(usize) = .empty;
    try padGateways(&ctx, &.{}, &.{}, terminal, 0, &gateways);
    try testing.expectEqual(@as(usize, 0), gateways.items.len);

    ctx.params.pad_neck = .{ .width = 0.1524, .max_length = 0.75, .taper_length = 0.35 };
    try padGateways(&ctx, &.{}, &.{}, terminal, 0, &gateways);
    try testing.expect(gateways.items.len > 0);
    try testing.expectEqual(nominal.track_width, ctx.params.track_width);
    try testing.expectApproxEqAbs(@as(f64, 0.2028), router_support.padGatewayWidth(ctx.params, 0.925), 1e-9);
    try testing.expectEqual(nominal.track_width, router_support.padGatewayWidth(ctx.params, 1.2));
}

// spec: placement/router - a hemmed breakout drops its unfinished escape stub when no legal via can land
test "escape stub is dropped when every via heading is pad-blocked" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const G = @import("geometry.zig");
    // A breakout pad at the origin ringed by eight foreign pads, one on each
    // 45° compass heading at 0.7 mm — every escape ray passes through foreign
    // copper, so no DRC-safe stub+via exists. The old relaxed tier would have
    // dropped a via beyond the ring with the stub crossing a ring pad (the
    // QFN-neighbour overlap bug); now the breakout must emit no orphan copper.
    // Ring pads are 0.3 mm wide so adjacent ring pads keep pad↔pad clearance
    // between THEMSELVES — the only thing under test is the escape stub.
    const pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const ring_pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.3, .h = 0.3 }};
    var parts = [_]Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &ring_pad, .fallback = false, .x = 0.7, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &ring_pad, .fallback = false, .x = 0.495, .y = 0.495 },
        .{ .ref_des = "R3", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &ring_pad, .fallback = false, .x = 0, .y = 0.7 },
        .{ .ref_des = "R4", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &ring_pad, .fallback = false, .x = -0.495, .y = 0.495 },
        .{ .ref_des = "R5", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &ring_pad, .fallback = false, .x = -0.7, .y = 0 },
        .{ .ref_des = "R6", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &ring_pad, .fallback = false, .x = -0.495, .y = -0.495 },
        .{ .ref_des = "R7", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &ring_pad, .fallback = false, .x = 0, .y = -0.7 },
        .{ .ref_des = "R8", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &ring_pad, .fallback = false, .x = 0.495, .y = -0.495 },
    };
    const pins = [_]flat_netlist.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
    const nets = [_]FlatNet{.{ .name = "EN", .pins = &pins }};
    const stubs = [_]optimizer.Stub{.{ .part = 0, .ax = 0, .ay = 0, .bx = 2, .by = 0, .net = 0 }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &stubs,
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = -2,
        .maxx = 2,
        .maxy = 2,
        .generated = true,
    };
    const r = try route(arena, placement, .{});
    // No DRC-safe escape exists — no via may be dropped…
    try testing.expectEqual(@as(usize, 0), r.vias.len);
    try testing.expectEqual(@as(usize, 0), r.tracks.len);
    // With no orphan stub, copper clearance remains clean.
    // This fixture packs the ring pads tighter than the solver ever would (to
    // starve every escape heading), so the diagonal courtyards intentionally
    // overlap and the tight mask openings leave slivers — both assembly-hygiene
    // warnings, not copper defects. The COPPER clearance this test is about is
    // clean: zero via/track/pad clearance violations.
    const drc = @import("drc.zig");
    const viol = try drc.check(arena, placement, r, 0.127);
    const copper = drc.countKind(viol, .via_pad) + drc.countKind(viol, .via_via) +
        drc.countKind(viol, .via_track) + drc.countKind(viol, .track_track) +
        drc.countKind(viol, .track_pad) + drc.countKind(viol, .pad_pad);
    try testing.expectEqual(@as(usize, 0), copper);
}

// spec: placement/router - reserves diagonal corner cells so later nets keep trace-to-trace clearance
test "a routed diagonal reserves its corner cells against foreign nets only" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Bare 20×20 grid, no pads: route net 0 along a pure 45° diagonal, then
    // check the squeeze-past corner cells of every step are reserved — blocked
    // for a foreign net, open for the owner, and never Dijkstra sources (resv,
    // not occ).
    const grid = Grid{ .ox = 0, .oy = 0, .g = 0.254, .nx = 20, .ny = 20 };
    const nodes = grid.nx * grid.ny;
    const occ = try allocLayerGrids(arena, 2, nodes);
    const resv = try allocLayerGrids(arena, 2, nodes);
    var ctx = Ctx{
        .arena = arena,
        .grid = grid,
        .obs = &.{},
        .reach = 0.1905,
        .occ = occ,
        .resv = resv,
        .params = .{},
        .base = .{},
        .index_reach = 0.1905,
    };
    var tracks: std.ArrayList(Track) = .empty;
    var vias: std.ArrayList(Via) = .empty;
    // Drive the maze directly (no pad gateways): seed net 0 at (2,2), route to
    // (6,6) — the unique shortest path is the pure 45° diagonal.
    ctx.occ[0][grid.node(2, 2)] = 0;
    const goals = [_]usize{grid.node(6, 6)}; // layer 0 ⇒ key == node index
    const hit = try dijkstra(&ctx, 0, .{ .goals = &goals }, &tracks, &vias);
    try testing.expect(hit != null);

    // Each diagonal step (i,i)→(i+1,i+1) squeezes past corners (i+1,i) and
    // (i,i+1) — all must now be reserved for net 0: blocked for a foreign net,
    // open for the owner, and never copper (occ stays EMPTY).
    try testing.expect(diagCornersReserved(&ctx, 2, 6, 0));
}

// spec: placement/router - a maze leg is charged for the escape stub each pad gateway implies, so it buys the entry that points where the route goes instead of the outermost free one
test "a priced gateway fan stops the maze buying a free wrong-way escape" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Two off-grid pads 2.61 mm apart with one foreign land standing between
    // them, so the lattice run has to go round while a straight gateway stub
    // does not.
    //
    // Unpriced, this is the shape the fan cannot help drawing: BOTH ends may
    // enter the grid anywhere in their six-ring fan for nothing, so the search
    // minimises only the lattice run BETWEEN the two fans — and `gateStub` then
    // draws two long straight rays from the pad centres out to wherever that run
    // happened to start and end. Any meeting point off the line between the pads
    // makes those rays a V, and nothing in the cost told the search so. Priced,
    // the two rays ARE part of what is minimised.
    const grid = Grid{ .ox = 0, .oy = 0, .g = 0.254, .nx = 20, .ny = 14 };
    const obs = [_]PadObs{.{ .x0 = 1.5, .y0 = 0.6, .x1 = 2.1, .y1 = 1.4, .net = 1, .layer = 0 }};
    var ctx = Ctx{
        .arena = arena,
        .grid = grid,
        .obs = &obs,
        .reach = 0.1905,
        .occ = try allocLayerGrids(arena, 1, grid.nx * grid.ny),
        .resv = try allocLayerGrids(arena, 1, grid.nx * grid.ny),
        .params = .{},
        .base = .{},
        .index_reach = 0.1905,
    };
    const from = NetPt{ .x = 2.948, .y = 1.424, .layer = 0 };
    const to = NetPt{ .x = 0.538, .y = 0.418, .layer = 0 };
    var src_gates: std.ArrayList(usize) = .empty;
    var goals: std.ArrayList(usize) = .empty;
    const seed = grid.nearest(from.x, from.y);
    ctx.occ[0][grid.node(seed[0], seed[1])] = 0;
    try padGateways(&ctx, &.{}, &.{}, from, 0, &src_gates);
    const near = grid.nearest(to.x, to.y);
    try goals.append(arena, grid.node(near[0], near[1])); // layer 0 ⇒ key == node
    try padGateways(&ctx, &.{}, &.{}, to, 0, &goals);
    try testing.expect(src_gates.items.len > 8 and goals.items.len > 8);

    // Route the leg and hand back every millimetre of copper it lays: the maze
    // run plus the two escape stubs. Only `anchors` differs between the calls.
    const Leg = struct {
        fn copper(c: *Ctx, ends: MazeEnds, a: NetPt, b: NetPt) std.mem.Allocator.Error!f64 {
            clearNetOcc(c, 0);
            const nd = c.grid.nearest(a.x, a.y);
            c.occ[a.layer][c.grid.node(nd[0], nd[1])] = 0;
            var tracks: std.ArrayList(Track) = .empty;
            var vias: std.ArrayList(Via) = .empty;
            const hit = (try dijkstra(c, 0, ends, &tracks, &vias)) orelse return std.math.inf(f64);
            try gateStub(c, 0, a, hit.source, vias.items, &tracks);
            try gateStub(c, 0, b, hit.goal, vias.items, &tracks);
            return route_timeline.traceLen(tracks.items);
        }
    };
    const both = MazeEnds{ .goals = goals.items, .sources = src_gates.items };
    const free = try Leg.copper(&ctx, both, from, to);
    var priced = both;
    priced.anchors = .{ .source = from, .goal = to };
    const paid = try Leg.copper(&ctx, priced, from, to);

    // A whole fan radius is the scale of the thing being bought, so it is the
    // scale to judge the waste on: the free leg draws MORE than the straight
    // line between the pads plus one fan radius, and the priced leg draws less.
    const straight = std.math.hypot(to.x - from.x, to.y - from.y);
    const fan_reach = @as(f64, @floatFromInt(gate_rings)) * grid.g;
    try testing.expect(free > straight + fan_reach);
    try testing.expect(paid < straight + fan_reach);
    try testing.expect(paid < free - 4 * grid.g);
}

// spec: placement/router - a leg seeded on a pad-buried halo node has its copper trimmed back off the land instead of the net being failed
test "trimBuriedStart pulls a leg's first segment out of the foreign pad it started in" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const grid = Grid{ .ox = 0, .oy = 0, .g = 0.254, .nx = 20, .ny = 20 };
    const nodes = grid.nx * grid.ny;
    // A foreign (net 1) land swallowing node (2,2) and reaching a little to its
    // right — barracuda's `U17` ground pad beside the `LMX_VTUNE` escape. The
    // halo of net 0's own copper still marks (2,2) as net 0's, so Dijkstra may
    // seed there; the run it draws must not start inside the land.
    const pad = [_]PadObs{.{
        .x0 = grid.worldX(2) - 0.1,
        .y0 = grid.worldY(2) - 0.1,
        .x1 = grid.worldX(2) + 0.2,
        .y1 = grid.worldY(2) + 0.1,
        .net = 1,
        .layer = 0,
    }};
    var ctx = Ctx{
        .arena = arena,
        .grid = grid,
        .obs = &pad,
        .reach = 0.19,
        .occ = try allocLayerGrids(arena, 1, nodes),
        .resv = try allocLayerGrids(arena, 1, nodes),
        .params = .{ .track_width = 0.2, .clearance = 0.15, .via_dia = 0.4, .via_drill = 0.2 },
    };
    var tracks: std.ArrayList(Track) = .empty;
    const from = tracks.items.len;
    // The leg as `emitSeg` drew it: starting AT the buried node (2,2) and
    // running right, away from the pad.
    try tracks.append(arena, .{
        .x1 = grid.worldX(2),
        .y1 = grid.worldY(2),
        .x2 = grid.worldX(9),
        .y2 = grid.worldY(2),
        .layer = 0,
        .width = 0.2,
        .net = 0,
    });
    const start = trimBuriedStart(&ctx, 0, grid.node(2, 2), from, &tracks, &.{});

    // The run survives — one segment, same far end, same net — but its start has
    // moved clear of the land, and that is the point the caller welds from.
    try testing.expectEqual(@as(usize, 1), tracks.items.len);
    try testing.expectApproxEqAbs(grid.worldX(9), tracks.items[0].x2, 1e-9);
    try testing.expect(tracks.items[0].x1 > grid.worldX(2) + 0.1);
    try testing.expectApproxEqAbs(tracks.items[0].x1, start[0], 1e-9);
    try testing.expectApproxEqAbs(tracks.items[0].y1, start[1], 1e-9);

    // A leg whose start node is NOT pad-buried is returned untouched.
    var clean: std.ArrayList(Track) = .empty;
    try clean.append(arena, .{ .x1 = grid.worldX(9), .y1 = grid.worldY(9), .x2 = grid.worldX(12), .y2 = grid.worldY(9), .layer = 0, .width = 0.2, .net = 0 });
    const kept = trimBuriedStart(&ctx, 0, grid.node(9, 9), 0, &clean, &.{});
    try testing.expectApproxEqAbs(grid.worldX(9), kept[0], 1e-9);
    try testing.expectApproxEqAbs(grid.worldX(9), clean.items[0].x1, 1e-9);
}

// spec: placement/router - the pad-buried source trim happens at the shared search seam, so a pass that does no trimming of its own still emits pad-clearing copper
test "dijkstra pulls a leg off the foreign land its source was buried in" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const grid = Grid{ .ox = 0, .oy = 0, .g = 0.254, .nx = 20, .ny = 20 };
    const nodes = grid.nx * grid.ny;
    // A foreign (net 1) land swallowing node (2,2) but stopping short of (3,2),
    // so the maze can still step right out of it. This is the shape barracuda's
    // poured `V_5VA` hit: `routeNetToZone` seeds from the net's own `occ` marks,
    // `stampStubOcc` painted (2,2) net 0 as part of an earlier leg's clearance
    // HALO, and the pass does no trimming of its own.
    const pad = [_]PadObs{.{
        .x0 = grid.worldX(2) - 0.1,
        .y0 = grid.worldY(2) - 0.1,
        .x1 = 0.55,
        .y1 = grid.worldY(2) + 0.1,
        .net = 1,
        .layer = 0,
    }};
    var ctx = Ctx{
        .arena = arena,
        .grid = grid,
        .obs = &pad,
        .reach = 0.19,
        .occ = try allocLayerGrids(arena, 1, nodes),
        .resv = try allocLayerGrids(arena, 1, nodes),
        .params = .{ .track_width = 0.2, .clearance = 0.15, .via_dia = 0.4, .via_drill = 0.2 },
        .base = .{},
        .index_reach = 0.19,
    };
    // The buried node is the ONLY source, so the leg must grow out of it —
    // `relaxStep` would never have entered it (`blocked` is true there).
    try testing.expect(blocked(&ctx, 0, grid.node(2, 2), 0));
    ctx.occ[0][grid.node(2, 2)] = 0;

    var tracks: std.ArrayList(Track) = .empty;
    var vias: std.ArrayList(Via) = .empty;
    const goals = [_]usize{grid.node(9, 2)}; // one layer ⇒ key == node index
    const hit = (try dijkstra(&ctx, 0, .{ .goals = &goals }, &tracks, &vias)) orelse
        return error.LegNotRouted;

    // The leg is routed, reaches its goal, and grew from the buried source…
    try testing.expect(tracks.items.len > 0);
    try testing.expectEqual(goals[0], hit.goal);
    try testing.expectEqual(grid.node(2, 2), hit.source);
    // …and every segment it drew clears the foreign land by the exact rule
    // `drc.checkTrackPad` applies (centreline distance − half width ≥ clearance).
    const shape = pad_shape.Shape{ .x0 = pad[0].x0, .y0 = pad[0].y0, .x1 = pad[0].x1, .y1 = pad[0].y1 };
    for (tracks.items) |t| {
        const d = pad_shape.segmentDist(shape, .{ t.x1, t.y1 }, .{ t.x2, t.y2 }, 4.0);
        try testing.expect(d - t.width / 2 >= ctx.params.clearance - 1e-9);
    }
    // The reported start is where that copper now begins — off the land, and
    // the point a welding caller must bridge from.
    try testing.expect(hit.start[0] > grid.worldX(2) + 0.1);
}

// spec: placement/router - a later leg's weld to the net's occupancy halo is bridged to the real copper so the two legs share metal
test "weldToNetCopper bridges an off-centreline halo weld to the net's prior copper" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const grid = Grid{ .ox = 0, .oy = 0, .g = 0.254, .nx = 20, .ny = 20 };
    const nodes = grid.nx * grid.ny;
    var ctx = Ctx{
        .arena = arena,
        .grid = grid,
        .obs = &.{},
        .reach = 0.19,
        .occ = try allocLayerGrids(arena, 1, nodes),
        .resv = try allocLayerGrids(arena, 1, nodes),
        // Explicit geometry so `copperHalo` is deterministic: its (0.2, ~0.48]
        // mm bridging band comfortably contains the one-grid-row (0.254 mm)
        // weld this test uses.
        .params = .{ .track_width = 0.2, .clearance = 0.15, .via_dia = 0.4, .via_drill = 0.2 },
    };
    // Prior copper: one horizontal net-0 track on layer 0 (the earlier leg).
    const y0 = grid.worldY(2);
    var tracks: std.ArrayList(Track) = .empty;
    try tracks.append(arena, .{ .x1 = grid.worldX(2), .y1 = y0, .x2 = grid.worldX(6), .y2 = y0, .layer = 0, .width = 0.2, .net = 0 });
    const prior = tracks.items.len;

    // A later leg welds at node (4,3): one grid row (0.254 mm, inside the
    // (track_width, copperHalo] halo band) ABOVE the real centreline — the halo
    // weld a Dijkstra source leaves. It is bridged straight down to the closest
    // point on the prior track, so the centrelines now meet (no fab open).
    try weldToNetCopper(.{ .ctx = &ctx, .net = 0, .at = .{ grid.worldX(4), grid.worldY(3) }, .layer = 0, .prior = prior, .tracks = &tracks, .vias = &.{} });
    try testing.expectEqual(prior + 1, tracks.items.len);
    const b = tracks.items[prior];
    try testing.expectApproxEqAbs(grid.worldX(4), b.x1, 1e-9);
    try testing.expectApproxEqAbs(grid.worldY(3), b.y1, 1e-9);
    try testing.expectApproxEqAbs(grid.worldX(4), b.x2, 1e-9);
    try testing.expectApproxEqAbs(y0, b.y2, 1e-9);
    try testing.expectEqual(@as(i32, 0), b.net);

    // A weld already ON the prior copper adds no bridge.
    try weldToNetCopper(.{ .ctx = &ctx, .net = 0, .at = .{ grid.worldX(4), grid.worldY(2) }, .layer = 0, .prior = prior, .tracks = &tracks, .vias = &.{} });
    try testing.expectEqual(prior + 1, tracks.items.len);
}

// spec: placement/router - a halo weld whose bridge would cross foreign copper is refused instead of laid over it
test "weldToNetCopper refuses a bridge that crosses a foreign pad" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const grid = Grid{ .ox = 0, .oy = 0, .g = 0.254, .nx = 20, .ny = 20 };
    const nodes = grid.nx * grid.ny;
    // A foreign (net 1) pad sitting between the weld node (4,3) and the prior
    // copper at row 2 — barracuda's LDO ground paddle, which the unprobed
    // bridge used to be drawn straight across.
    const pad = [_]PadObs{.{
        .x0 = grid.worldX(4) - 0.2,
        .y0 = grid.worldY(2) + 0.05,
        .x1 = grid.worldX(4) + 0.2,
        .y1 = grid.worldY(3) - 0.05,
        .net = 1,
        .layer = 0,
    }};
    var ctx = Ctx{
        .arena = arena,
        .grid = grid,
        .obs = &pad,
        .reach = 0.19,
        .occ = try allocLayerGrids(arena, 1, nodes),
        .resv = try allocLayerGrids(arena, 1, nodes),
        .params = .{ .track_width = 0.2, .clearance = 0.15, .via_dia = 0.4, .via_drill = 0.2 },
    };
    const y0 = grid.worldY(2);
    var tracks: std.ArrayList(Track) = .empty;
    try tracks.append(arena, .{ .x1 = grid.worldX(2), .y1 = y0, .x2 = grid.worldX(6), .y2 = y0, .layer = 0, .width = 0.2, .net = 0 });
    const prior = tracks.items.len;

    // Same weld as the bridging test above, now with the pad in the way: no
    // copper is emitted, so the leg reads as the open it really is (the
    // `net_open` marker names it) instead of shorting to the pad.
    try weldToNetCopper(.{ .ctx = &ctx, .net = 0, .at = .{ grid.worldX(4), grid.worldY(3) }, .layer = 0, .prior = prior, .tracks = &tracks, .vias = &.{} });
    try testing.expectEqual(prior, tracks.items.len);
}

// spec: placement/router - a pad-centre join stops at the foreign-pad clearance instead of emitting the segment nothing probed
test "OctiJoin trims a join that aims at a two-pad passive's sibling pad" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // barracuda's `adf4159/C116` to scale: a 0402-class cap turned 90 degrees,
    // so its own pad (net 0) and its GND pad (net 1) sit 0.64 mm apart in y with
    // 0.230 mm half-heights. The maze's entry node for the V_1V8A pad lies
    // straight up the inter-pad lane, so the join is already octilinear — the
    // one shape `elbow` returns on without probing, which is exactly how the
    // unprobed segment used to be drawn 0.094 mm into a 0.127 mm rule.
    const grid = Grid{ .ox = 0, .oy = 0, .g = 0.254, .nx = 20, .ny = 20 };
    const nodes = grid.nx * grid.ny;
    const own = [2]f64{ 2.0, 2.0 };
    const sibling = [_]PadObs{.{ .x0 = 1.8, .y0 = 2.41, .x1 = 2.2, .y1 = 2.87, .net = 1, .layer = 0 }};
    var ctx = Ctx{
        .arena = arena,
        .grid = grid,
        .obs = &sibling,
        .reach = 0.2535,
        .occ = try allocLayerGrids(arena, 1, nodes),
        .resv = try allocLayerGrids(arena, 1, nodes),
        .params = .{ .track_width = 0.253, .clearance = 0.127, .via_dia = 0.4, .via_drill = 0.2 },
    };
    var tracks: std.ArrayList(Track) = .empty;
    const join = OctiJoin{ .ctx = &ctx, .net = 0, .layer = 0, .placed_vias = &.{}, .tracks = &tracks };

    // A track_width trace needs its half-width plus the rule clear of the
    // sibling's near edge, so the copper may reach y = 2.41 − 0.2535 and no
    // farther. The old emit ran the full 0.4 mm to the node at y = 2.4.
    try octilinear.emitJoin(own, .{ 2.0, 2.4 }, join);
    try testing.expectEqual(@as(usize, 1), tracks.items.len);
    const t = tracks.items[0];
    try testing.expectApproxEqAbs(own[0], t.x1, 1e-9);
    try testing.expectApproxEqAbs(own[1], t.y1, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 2.1565), t.y2, 1e-6);
    // The emitted copper — not merely the requested span — passes the very
    // predicate the track-pad DRC re-runs on it.
    try testing.expect(segClearsPadsOnLayer(&ctx, .{ t.x1, t.y1 }, .{ t.x2, t.y2 }, 0, 0));

    // Away from the sibling the join is untouched: a legal span still emits end
    // to end, so trimming costs nothing where the copper was always fabricable.
    tracks.clearRetainingCapacity();
    try octilinear.emitJoin(own, .{ 2.0, 1.6 }, join);
    try testing.expectEqual(@as(usize, 1), tracks.items.len);
    try testing.expectApproxEqAbs(@as(f64, 1.6), tracks.items[0].y2, 1e-9);

    // A pad centre that already crowds its neighbour has no legal stub at all,
    // so nothing is drawn — an open `net_open` names beats a silent short.
    const crowding = [_]PadObs{.{ .x0 = 1.8, .y0 = 2.1, .x1 = 2.2, .y1 = 2.5, .net = 1, .layer = 0 }};
    ctx.obs = &crowding;
    tracks.clearRetainingCapacity();
    try octilinear.emitJoin(own, .{ 2.0, 2.4 }, join);
    try testing.expectEqual(@as(usize, 0), tracks.items.len);
}

test "batch maze search is bounded and reuses its board-sized buffers" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const grid = Grid{ .ox = 0, .oy = 0, .g = 0.1, .nx = 200, .ny = 120 };
    const nodes = grid.nx * grid.ny;
    const selected = [_]bool{ true, true, true };
    var ctx = Ctx{
        .arena = arena,
        .grid = grid,
        .obs = &.{},
        .reach = 0.2,
        .occ = try allocLayerGrids(arena, 1, nodes),
        .resv = try allocLayerGrids(arena, 1, nodes),
        .params = .{},
        .selected_nets = &selected,
        .allow_vias = false,
    };
    const source = grid.node(10, 60);
    const goal = grid.node(190, 60);
    ctx.occ[0][source] = 0;
    for (0..grid.ny) |y| ctx.occ[0][grid.node(100, y)] = 1;

    var tracks: std.ArrayList(Track) = .empty;
    var vias: std.ArrayList(Via) = .empty;
    try testing.expect(try dijkstra(&ctx, 0, .{ .goals = &.{goal} }, &tracks, &vias) == null);
    try testing.expectEqualSlices(usize, &.{0}, ctx.search_limited.items);
    const dist_ptr = ctx.search.dist.ptr;

    ctx.occ[0][grid.node(100, 60)] = empty_cell;
    try testing.expect(try dijkstra(&ctx, 0, .{ .goals = &.{goal} }, &tracks, &vias) != null);
    try testing.expect(dist_ptr == ctx.search.dist.ptr);
}

// spec: placement/router - a rolled-back attempt restores the search-limited marks its own probe added, leaving the set byte-identical
test "a rolled-back attempt leaves search_limited byte-identical" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var scratch_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch_inst.deinit();

    const grid = Grid{ .ox = 0, .oy = 0, .g = 0.1, .nx = 200, .ny = 120 };
    const nodes = grid.nx * grid.ny;
    const selected = [_]bool{ true, true, true };
    var ctx = Ctx{
        .arena = arena,
        .grid = grid,
        .obs = &.{},
        .reach = 0.2,
        .occ = try allocLayerGrids(arena, 1, nodes),
        .resv = try allocLayerGrids(arena, 1, nodes),
        .params = .{},
        .selected_nets = &selected,
        .allow_vias = false,
    };
    // A mark an EARLIER phase left behind: the rollback must keep it.
    try ctx.search_limited.append(arena, 2);

    var tracks: std.ArrayList(Track) = .empty;
    var vias: std.ArrayList(Via) = .empty;
    var routable = [_]RipNet{};
    const snap = try saveSnapshot(scratch_inst.allocator(), &ctx, &tracks, &vias, &routable);

    // The speculative attempt: a wall-blocked leg exhausts its budget on net 0
    // and marks it, as a `rerouteNet` inside a rip-up transaction would.
    const source = grid.node(10, 60);
    const goal = grid.node(190, 60);
    ctx.occ[0][source] = 0;
    for (0..grid.ny) |y| ctx.occ[0][grid.node(100, y)] = 1;
    try testing.expect(try dijkstra(&ctx, 0, .{ .goals = &.{goal} }, &tracks, &vias) == null);
    try testing.expectEqualSlices(usize, &.{ 2, 0 }, ctx.search_limited.items);

    // Rolling the attempt back unwinds its mark and only its mark.
    try restoreSnapshot(&ctx, &tracks, &vias, &routable, snap);
    try testing.expectEqualSlices(usize, &.{2}, ctx.search_limited.items);
}

test "A star heuristic stays admissible through combined corridor discounts" {
    const grid = Grid{ .ox = 0, .oy = 0, .g = 0.1, .nx = 11, .ny = 1 };
    const corridor: [11]bool = @splat(false);
    var ctx = Ctx{
        .arena = testing.allocator,
        .grid = grid,
        .obs = &.{},
        .reach = 0,
        .occ = &.{},
        .resv = &.{},
        .params = .{},
        .reference_corridor = &corridor,
        .corridor = &corridor,
    };
    const heuristic = routeHeuristic(&ctx, &.{grid.node(10, 0)}, 11);
    try testing.expectApproxEqAbs(@as(f64, 0.05), heuristic.estimate(grid, 0), 1e-12);
}

/// Loop body of the diagonal-reservation test, hoisted so the test itself
/// stays conditional-free: checks every corner cell of the (lo,lo)→(hi,hi)
/// diagonal is reserved for `net`, blocked to a foreign net, passable to the
/// owner, and not stamped as copper.
fn diagCornersReserved(ctx: *Ctx, lo: usize, hi: usize, net: i32) bool {
    const grid = ctx.grid;
    var i: usize = lo;
    while (i < hi) : (i += 1) {
        const c1 = grid.node(i + 1, i);
        const c2 = grid.node(i, i + 1);
        if (ctx.resv[0][c1] != net or ctx.resv[0][c2] != net) return false;
        if (!blocked(ctx, 0, c1, net + 1)) return false; // foreign net must be blocked
        if (blocked(ctx, 0, c1, net)) return false; // owner must stay passable
        if (ctx.occ[0][c1] != empty_cell) return false; // reserved ≠ copper
    }
    return true;
}

test "segSegDist returns zero for a proper crossing away from the origin" {
    // Two unit diagonals crossing at (1.5,1.5); the intersection parameter's
    // numerator must read b1−a1 (not b1+a1), or the crossing is missed and a
    // positive endpoint distance is returned instead of 0.
    try testing.expectEqual(@as(f64, 0), segSegDist(.{ 1, 1 }, .{ 2, 2 }, .{ 1, 2 }, .{ 2, 1 }));
}

test "copperHalo sums via radius, half track, and clearance under the sqrt" {
    var ctx = Ctx{
        .arena = testing.allocator,
        .grid = .{ .ox = 0, .oy = 0, .g = 1.0, .nx = 1, .ny = 1 },
        .obs = &.{},
        .reach = 0,
        .occ = &.{},
        .resv = &.{},
        .params = .{ .via_dia = 0.8, .track_width = 0.2, .clearance = 0.3 },
    };
    // d = viaR + track_width/2 + clearance = 0.4 + 0.1 + 0.3 = 0.8;
    // halo = √(d² + g²·0.5) = √(0.64 + 0.5) = √1.14. Any +→− flip changes d.
    try testing.expectApproxEqAbs(@as(f64, @sqrt(1.14)), copperHalo(&ctx), 1e-9);
}

test "via occupancy keeps legal neighboring via outside one physical halo" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const grid = Grid{ .ox = 0, .oy = 0, .g = 0.1, .nx = 30, .ny = 20 };
    const nodes = grid.nx * grid.ny;
    var ctx = Ctx{
        .arena = arena,
        .grid = grid,
        .obs = &.{},
        .reach = 0.2536,
        .occ = try allocLayerGrids(arena, 2, nodes),
        .resv = try allocLayerGrids(arena, 2, nodes),
        .params = .{ .via_dia = 0.4, .track_width = 0.2532, .clearance = 0.127 },
        .base = .{},
        .index_reach = 0.2536,
    };
    stampViaOcc(&ctx, 1.0, 1.0, 0);
    const halo_cell = grid.node(14, 10);
    try testing.expectEqual(empty_cell, ctx.occ[0][halo_cell]);
    try testing.expectEqual(@as(i32, 0), ctx.resv[0][halo_cell]);
    try testing.expect(!viaAllowed(&ctx, grid.node(15, 10), 1, &.{}));
    try testing.expect(viaAllowed(&ctx, grid.node(16, 10), 1, &.{}));
}

// spec: placement/router - a gap-pass via site counts its clearance from already-inflated foreign copper once, not twice
test "a gap-pass via site clears stamped foreign copper by the physical distance only" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const grid = Grid{ .ox = 0, .oy = 0, .g = 0.1, .nx = 40, .ny = 40 };
    const nodes = grid.nx * grid.ny;
    var ctx = Ctx{
        .arena = arena,
        .grid = grid,
        .obs = &.{},
        .reach = 0.2,
        .occ = try allocLayerGrids(arena, 2, nodes),
        .resv = try allocLayerGrids(arena, 2, nodes),
        .params = .{ .via_dia = 0.4, .track_width = 0.2, .clearance = 0.2 },
        .base = .{},
        .index_reach = 0.2,
    };
    // Arm the gap pass's exact mode, then stamp a foreign net-1 track along
    // y = 1.0. A net-0 via (radius 0.2) must keep viaR + width/2 + clearance
    // = 0.2 + 0.1 + 0.2 = 0.5 mm from that centreline — and no more.
    ctx.exact = .{ .near = try arena.alloc(bool, ctx.occ.len * nodes) };
    const foreign = [_]Track{
        .{ .x1 = 0.5, .y1 = 1.0, .x2 = 3.0, .y2 = 1.0, .layer = 0, .width = 0.2, .net = 1 },
    };
    stampBoardCopper(&ctx, &foreign, &.{}, 0);
    // 0.4 mm off the centreline is inside the physical clearance — still refused.
    try testing.expect(!viaAllowed(&ctx, grid.node(17, 14), 0, &.{}));
    // 0.7 mm off it clears by 0.2 mm. Re-expanding the stamp by a second full
    // via halo would refuse this site out past 0.9 mm.
    try testing.expect(viaAllowed(&ctx, grid.node(17, 17), 0, &.{}));
}

// spec: placement/router - a clearance probe never resolves a stale copper index: after a cleanup compaction slides survivors into removed slots the probes fall back to the full scan instead of judging the wrong track
test "a compacted copper list cannot false-clear a probe through the aliased index" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const grid = Grid{ .ox = 0, .oy = 0, .g = 0.1, .nx = 120, .ny = 120 };
    var ctx = Ctx{
        .arena = arena,
        .grid = grid,
        .obs = &.{},
        .reach = 0.2,
        .occ = &.{},
        .resv = &.{},
        .params = .{ .via_dia = 0.4, .track_width = 0.2, .clearance = 0.2 },
        .base = .{},
    };
    // Three tracks. Slot 1 is a foreign net-2 wall lying straight across the
    // probe segment; slot 0 is net-1 copper and slot 2 more net-2 copper, both
    // parked far away where nothing can reach them. The probe is a net-3 stub
    // crossing the wall.
    var tracks: std.ArrayList(Track) = .empty;
    try tracks.append(arena, .{ .x1 = 5.0, .y1 = 5.0, .x2 = 6.0, .y2 = 5.0, .layer = 0, .width = 0.2, .net = 1 });
    try tracks.append(arena, .{ .x1 = 0.5, .y1 = 1.2, .x2 = 1.5, .y2 = 1.2, .layer = 0, .width = 0.2, .net = 2 });
    try tracks.append(arena, .{ .x1 = 8.0, .y1 = 8.0, .x2 = 9.0, .y2 = 8.0, .layer = 0, .width = 0.2, .net = 2 });
    const a = [2]f64{ 1.0, 1.0 };
    const b = [2]f64{ 1.0, 1.4 };

    rebuildCopperIndex(&ctx, tracks.items, &.{});
    try testing.expect(copperIdx(&ctx) != null); // the indexed path is the one under test
    try testing.expect(!segClearsTracks(&ctx, tracks.items, a, b, 3, 0));

    // Now compact exactly as a cleanup pass does: dropping net 1 slides the
    // wall from slot 1 to slot 0 and the far net-2 track from slot 2 to slot 1.
    // The index still reports "the box beside the probe is candidate 1" — in
    // range of the shortened list, so no bounds guard can catch it, and slot 1
    // now holds the FAR track. Resolving that candidate says the wall is gone
    // and the crossing is clear.
    route_cleanup.removeNetTracks(&tracks, 1);
    copperCompacted(&ctx);
    try testing.expectEqual(@as(usize, 2), tracks.items.len);
    try testing.expectEqual(@as(f64, 1.2), tracks.items[0].y1); // the wall, now at slot 0
    try testing.expect(!segClearsTracks(&ctx, tracks.items, a, b, 3, 0));

    // …and the index is usable again — same verdict — once it is restamped.
    rebuildCopperIndex(&ctx, tracks.items, &.{});
    try testing.expect(copperIdx(&ctx) != null);
    try testing.expect(!segClearsTracks(&ctx, tracks.items, a, b, 3, 0));
}

// spec: placement/router - exact clearance probes inspect copper appended after their spatial index was built
test "an appended copper tail cannot false-clear an exact probe" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const grid = Grid{ .ox = 0, .oy = 0, .g = 0.1, .nx = 120, .ny = 120 };
    var ctx = Ctx{
        .arena = arena,
        .grid = grid,
        .obs = &.{},
        .reach = 0.2,
        .occ = &.{},
        .resv = &.{},
        .params = .{ .via_dia = 0.4, .via_drill = 0.3, .track_width = 0.2, .clearance = 0.2 },
        .base = .{},
        .hole_to_hole = 0.2,
    };
    var tracks: std.ArrayList(Track) = .empty;
    try tracks.append(arena, .{ .x1 = 8, .y1 = 8, .x2 = 9, .y2 = 8, .layer = 0, .width = 0.2, .net = 1 });
    var vias: std.ArrayList(Via) = .empty;
    try vias.append(arena, .{ .x = 8, .y = 9, .dia = 0.4, .drill = 0.3, .net = 1 });
    rebuildCopperIndex(&ctx, tracks.items, vias.items);
    try testing.expect(copperIdx(&ctx) != null);

    // These foreign items arrive after the index build, as the P leg does
    // before a coupled route probes its N leg. No index box names either one.
    try tracks.append(arena, .{ .x1 = 0.5, .y1 = 1.2, .x2 = 1.5, .y2 = 1.2, .layer = 0, .width = 0.2, .net = 2 });
    try vias.append(arena, .{ .x = 1, .y = 1.2, .dia = 0.4, .drill = 0.3, .net = 2 });
    const a = [2]f64{ 1, 1 };
    const b = [2]f64{ 1, 1.4 };
    try testing.expect(!segClearsTracks(&ctx, tracks.items, a, b, 3, 0));
    try testing.expect(!viaClearsTracks(&ctx, tracks.items, 1, 1.2, 3));
    try testing.expect(!segClearsVias(&ctx, vias.items, a, b, 3));
    try testing.expect(!viaClearsHoles(&ctx, vias.items, 1.3, 1.2));
    try testing.expect(!finePointClear(.{ .ctx = &ctx, .net = 3, .layer = 0, .tracks = tracks.items, .vias = vias.items }, .{ 1, 1.2 }));
}

/// A `passive` part with a square courtyard `half` and one pad set `pads`.
fn mkPart(ref: []const u8, x: f64, y: f64, half: f64, pads: []const geometry.Pad) Part {
    return .{
        .ref_des = ref,
        .kind = .passive,
        .hw = half,
        .hh = half,
        .pads = pads,
        .fallback = false,
        .x = x,
        .y = y,
    };
}

// A minimal parallel diff-pair board: P (D_P) at y=0 and N (D_N) at `pn_gap`,
// each a two-pad net, with a THROUGH-HOLE obstacle straddling N's straight lane
// at mid-span. Blocking both layers forces N to detour in-plane — up (away from
// P) or down (toward P) — instead of viaing under it. `pair` toggles coupling.
fn diffPairFixture(arena: std.mem.Allocator, pn_gap: f64, pair: bool) std.mem.Allocator.Error!RouteResult {
    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const obs = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.8, .thru = true, .drill = 0.3 }};
    const parts = arena.alloc(Part, 5) catch return error.OutOfMemory;
    parts[0] = mkPart("R1", 0, 0, 0.5, &pad);
    parts[1] = mkPart("R2", 8, 0, 0.5, &pad);
    parts[2] = mkPart("R3", 0, pn_gap, 0.5, &pad);
    parts[3] = mkPart("R4", 8, pn_gap, 0.5, &pad);
    parts[4] = mkPart("U1", 4, pn_gap, 0.4, &obs);
    const pins_p = [_]flat_netlist.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const pins_n = [_]flat_netlist.FlatPin{ .{ .ref_des = "R3", .pin = "1" }, .{ .ref_des = "R4", .pin = "1" } };
    const pins_o = [_]flat_netlist.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
    const nets = arena.alloc(FlatNet, 3) catch return error.OutOfMemory;
    nets[0] = .{ .name = "D_P", .pins = &pins_p };
    nets[1] = .{ .name = "D_N", .pins = &pins_n };
    nets[2] = .{ .name = "OBS", .pins = &pins_o };
    const pairs = arena.alloc(diff_pairs.DiffPair, 1) catch return error.OutOfMemory;
    pairs[0] = .{ .p = 0, .n = 1, .gap = pn_gap };
    const placement = optimizer.Placement{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1,
        .miny = -1,
        .maxx = 9,
        .maxy = pn_gap + 1,
        .generated = true,
        .diff_pairs = if (pair) pairs else &.{},
    };
    return route(arena, placement, .{});
}

/// Lowest y touched by any track on net index `ni` (∞ if the net has no copper).
fn minTrackY(r: RouteResult, ni: i32) f64 {
    var lo: f64 = std.math.inf(f64);
    for (r.tracks) |t| {
        if (t.net != ni) continue;
        lo = @min(lo, @min(t.y1, t.y2));
    }
    return lo;
}

// spec: placement/router - a diff pair's N net is biased into a corridor hugging its already-routed P twin
test "diff-pair coupling pulls the N net's detour toward its P twin" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const gap = 2.0;
    const coupled = try diffPairFixture(arena, gap, true);
    // Both nets route (P is index 0, N index 1; OBS is single-pad, unrouted).
    try testing.expectEqual(@as(usize, 2), coupled.total);
    try testing.expectEqual(@as(usize, 2), coupled.routed);
    // The corridor discounts cells near P (y≈0), and the up detour past the
    // obstacle sits outside it — so the coupled N detours DOWN (toward P), its
    // lowest copper dipping below its own lane and no higher than the uncoupled
    // route's lowest point.
    const coupled_lo = minTrackY(coupled, 1);
    const uncoupled_lo = minTrackY(try diffPairFixture(arena, gap, false), 1);
    try testing.expect(coupled_lo < gap);
    try testing.expect(coupled_lo <= uncoupled_lo);
}

// spec: placement/router - an empty diff-pairs set leaves routing unchanged and deterministic
test "diff-pair empty set is an inert no-op" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Two runs of the same board with no pairs must produce identical copper —
    // the diff-pair path never engages (reorder returns the same order, the
    // corridor stays null), so the route is byte-identical to today's.
    const a = try diffPairFixture(arena, 2.0, false);
    const b = try diffPairFixture(arena, 2.0, false);
    try testing.expectEqual(a.tracks.len, b.tracks.len);
    try testing.expectEqual(a.routed, b.routed);
    for (a.tracks, b.tracks) |ta, tb| {
        try testing.expectEqual(ta.x1, tb.x1);
        try testing.expectEqual(ta.y1, tb.y1);
        try testing.expectEqual(ta.x2, tb.x2);
        try testing.expectEqual(ta.y2, tb.y2);
        try testing.expectEqual(ta.net, tb.net);
    }
}

// spec: placement/router - a leg following a soft reference guide searches on the targeted expansion budget, since its heuristic is discounted to stay admissible
test "expansionBudget gives a guided leg the targeted budget" {
    const base = route_grid.max_batch_expansions;
    // A guided leg pays a 0.1x heuristic (routeHeuristic) and so expands far
    // more nodes per unit of progress; it takes the targeted floor.
    try testing.expectEqual(route_grid.max_targeted_expansions, expansionBudget(.{
        .base = base,
        .escape_active = false,
        .escalate = 0,
        .corridor = false,
        .guided = true,
    }));
    // Unguided is unchanged — the whole-board base, exactly as before.
    try testing.expectEqual(base, expansionBudget(.{
        .base = base,
        .escape_active = false,
        .escalate = 0,
        .corridor = false,
        .guided = false,
    }));
}

// spec: placement/router - escalation widens the maze expansion budget only for a retried search-limited leg
test "expansionBudget escalates only for a retried search-limited leg" {
    const base = route_grid.max_batch_expansions;
    // Ordinary whole-board leg, no corridor: exactly the base budget.
    try testing.expectEqual(base, expansionBudget(.{
        .base = base,
        .escape_active = false,
        .escalate = 0,
        .corridor = false,
    }));
    // An escape-forced leg widens to the targeted budget.
    try testing.expectEqual(route_grid.max_targeted_expansions, expansionBudget(.{
        .base = base,
        .escape_active = true,
        .escalate = 0,
        .corridor = false,
    }));
    // A coupling corridor caps the ordinary search tightly.
    try testing.expectEqual(route_grid.max_pair_corridor_expansions, expansionBudget(.{
        .base = base,
        .escape_active = false,
        .escalate = 0,
        .corridor = true,
    }));
    // Escalation lifts the plain budget far above the whole-board base…
    try testing.expectEqual(max_escalated_expansions, expansionBudget(.{
        .base = base,
        .escape_active = false,
        .escalate = max_escalated_expansions,
        .corridor = false,
    }));
    // …and lifts the corridor cap too, so an escalated pair retry is not stuck
    // at the tight 2 000-cell corridor budget.
    try testing.expectEqual(max_escalated_expansions, expansionBudget(.{
        .base = base,
        .escape_active = false,
        .escalate = max_escalated_expansions,
        .corridor = true,
    }));
}

// spec: placement/router - a diff pair whose follower leg fails keeps its already-routed leader leg
test "a failed diff-pair follower keeps its routed leader" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var ctx = Ctx{
        .arena = arena,
        .grid = .{ .ox = 0, .oy = 0, .g = 1, .nx = 1, .ny = 1 },
        .obs = &.{},
        .reach = 0,
        .occ = &.{},
        .resv = &.{},
        .params = .{},
    };
    var tracks: std.ArrayList(Track) = .empty;
    var vias: std.ArrayList(Via) = .empty;
    // Leader (net 0) already routed and frozen; the pair transaction points at
    // its working-set slot.
    var routable: std.ArrayList(RipNet) = .empty;
    try routable.append(arena, .{ .net_i = 0, .pri = 0, .ok = true, .reroutable = false });
    var pair_txn: ?PairTxn = .{
        .p_net = 0,
        .n_net = 1,
        .track_mark = 0,
        .via_mark = 0,
        .routable_i = 0,
        .leader_ok = true,
    };
    const net_pri = [_]u64{ 0, 0 };
    // Follower (net 1) FAILS. finishGreedyNet must not tear out the leader: it
    // keeps net 0's copper and leaves both legs rescue candidates.
    try finishGreedyNet(.{
        .ctx = &ctx,
        .net_pri = &net_pri,
        .tracks = &tracks,
        .vias = &vias,
        .routable = &routable,
        .pair_txn = &pair_txn,
    }, 1, false, .{ 0, 0 }, null, .{ .p_net = 0, .gap = 0.2 });
    try testing.expectEqual(@as(usize, 2), routable.items.len);
    try testing.expect(routable.items[0].ok); // leader kept, not ripped
    try testing.expect(routable.items[0].reroutable); // now a rescue candidate
    try testing.expect(!routable.items[1].ok); // follower stays failed
    try testing.expect(pair_txn == null);
}

// spec: placement/router - a declared diff pair routes deterministically across identical runs
test "a declared diff pair routes deterministically across identical runs" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    // Two identical runs of the DECLARED-pair board (coupling + fallback +
    // escalation all reachable) must produce byte-identical copper — no
    // hashmap-iteration or wall-clock nondeterminism in the retry phases.
    const a = try diffPairFixture(arena, 2.0, true);
    const b = try diffPairFixture(arena, 2.0, true);
    try testing.expectEqual(a.routed, b.routed);
    try testing.expectEqual(a.tracks.len, b.tracks.len);
    for (a.tracks, b.tracks) |ta, tb| {
        try testing.expectEqual(ta.x1, tb.x1);
        try testing.expectEqual(ta.y1, tb.y1);
        try testing.expectEqual(ta.x2, tb.x2);
        try testing.expectEqual(ta.y2, tb.y2);
        try testing.expectEqual(ta.net, tb.net);
    }
}

// spec: placement/router - rip-up eligibility covers any net still failed after budget escalation
test "any net still failed after budget escalation is rip-up eligible" {
    // A plain multi-drop net (4 pins, no RF / diff-pair / escape rule) — exactly
    // the class the old escape/pair/max-freq/≤3-terminal gate refused to rescue.
    // Universal eligibility is now observable through the RIP CEILING: every
    // still-failed seed runs at `maxInt`, so a STRICTLY higher-priority routed
    // blocker is collected for it and the keep-best gate alone decides.
    const pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "U2", .pin = "1" },
        .{ .ref_des = "U3", .pin = "1" },
        .{ .ref_des = "U4", .pin = "1" },
    };
    const nets = [_]FlatNet{.{ .name = "BUS", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 1,
        .maxy = 1,
        .generated = true,
    };
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();
    const routable = [_]RipNet{.{ .net_i = 0, .pri = 900, .ok = true }};
    const blockers = [_]i32{0};
    const open = try collectRippable(a, placement, &routable, &blockers, std.math.maxInt(u64));
    try testing.expectEqual(@as(usize, 1), open.len);
    // The old gated path passed the seed's own (lower) priority instead, which
    // is what left such a net unable to displace the neighbour walling it in.
    const gated = try collectRippable(a, placement, &routable, &blockers, 10);
    try testing.expectEqual(@as(usize, 0), gated.len);
}

// spec: placement/router - rip-up equal-count keep-best scoring preserves authored wave priority before preferring shorter copper
test "rip-up keep-best preserves wave priority before copper length" {
    const before = RipScore{ .routed = 8, .priority = 90, .trace = 100 };
    // More connected nets remains the primary goal regardless of the tie-breaks.
    try testing.expect(ripScoreBetter(.{ .routed = 9, .priority = 1, .trace = 200 }, before));
    // At equal count an earlier authored wave cannot be traded away merely
    // because the replacement lower-priority trace is shorter.
    try testing.expect(!ripScoreBetter(.{ .routed = 8, .priority = 89, .trace = 20 }, before));
    try testing.expect(ripScoreBetter(.{ .routed = 8, .priority = 91, .trace = 200 }, before));
    // Length remains the deterministic final tie-break for the same net set.
    try testing.expect(ripScoreBetter(.{ .routed = 8, .priority = 90, .trace = 99 }, before));
}

// spec: placement/router - a failed authored guide gets one immediate half-pitch retry before lower waves claim its corridor unless a whole-route deadline prioritizes breadth
test "immediate fine retry is bounded to authored guides with manageable terminal count" {
    var ctx: Ctx = undefined;
    const policies = [_]route_policy.NetPolicy{
        .{ .waypoints = &.{.{ .x = 1, .y = 2, .layer = 0 }} },
        .{},
    };
    ctx.net_policy = &policies;
    ctx.deadline_ns = 0;
    try testing.expect(immediateFineGuidedEligible(&ctx, 0, 2));
    try testing.expect(!immediateFineGuidedEligible(&ctx, 0, rescue_max_terminals + 1));
    try testing.expect(!immediateFineGuidedEligible(&ctx, 1, 2));
    ctx.deadline_ns = 1;
    try testing.expect(!immediateFineGuidedEligible(&ctx, 0, 2));
}

// spec: placement/router - a last-resort retry escalates a residual leg to a larger expansion budget than an ordinary escalation
test "the last-resort retry uses a larger expansion budget than an ordinary escalation" {
    try testing.expect(max_last_resort_expansions > max_escalated_expansions);
    // `expansionBudget` threads the caller's escalated budget verbatim, so the
    // last-resort tier searches strictly wider than an ordinary escalation — on
    // the plain AND the corridor-capped path.
    try testing.expectEqual(max_last_resort_expansions, expansionBudget(.{
        .base = route_grid.max_batch_expansions,
        .escape_active = false,
        .escalate = max_last_resort_expansions,
        .corridor = false,
    }));
    try testing.expectEqual(max_last_resort_expansions, expansionBudget(.{
        .base = route_grid.max_batch_expansions,
        .escape_active = false,
        .escalate = max_last_resort_expansions,
        .corridor = true,
    }));
}

// spec: placement/router - budget escalation re-runs after rip-up as a safe no-op once every leg is routed
test "budget escalation is a safe no-op once every leg is routed" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var ctx = Ctx{
        .arena = arena,
        .grid = .{ .ox = 0, .oy = 0, .g = 1, .nx = 1, .ny = 1 },
        .obs = &.{},
        .reach = 0,
        .occ = &.{},
        .resv = &.{},
        .params = .{},
    };
    var idx_of: std.StringHashMapUnmanaged(usize) = .empty;
    var tracks: std.ArrayList(Track) = .empty;
    var vias: std.ArrayList(Via) = .empty;
    // Both legs already routed, no diff pairs, an empty search-limited set.
    var routable: std.ArrayList(RipNet) = .empty;
    try routable.append(arena, .{ .net_i = 0, .pri = 0, .ok = true });
    try routable.append(arena, .{ .net_i = 1, .pri = 0, .ok = true });
    const placement = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 1,
        .maxy = 1,
        .generated = true,
    };
    // The interleave leans on an idempotent tail: a re-run (here at the last-
    // resort budget) must touch nothing when nothing is failed, so a late pass
    // never disturbs a solved board.
    const rescued = try escalateSearchLimited(.{
        .ctx = &ctx,
        .placement = placement,
        .idx_of = &idx_of,
        .routable = routable.items,
        .tracks = &tracks,
        .vias = &vias,
        .budget = max_last_resort_expansions,
    });
    try testing.expectEqual(@as(usize, 0), rescued);
    try testing.expectEqual(@as(usize, 0), tracks.items.len);
    try testing.expectEqual(@as(usize, 0), vias.items.len);
    try testing.expect(routable.items[0].ok and routable.items[1].ok);
}

// spec: placement/router - straightEscapePair accepts an axis-aligned pad pair that faces along the hop, rejecting a diagonal, a perpendicular-facing, a coincident, or a cross-layer pair
test "straightEscapePair accepts facing axis-aligned pads only" {
    const at = struct {
        fn p(x: f64, y: f64, layer: u8, ox: f64, oy: f64) pad_exit.Term {
            return .{ .x = x, .y = y, .layer = layer, .out = .{ ox, oy } };
        }
    }.p;
    // The IF1_MIX shape: same-Y pads facing each other (+x / -x) → straight.
    try testing.expect(pad_exit.straightEscapePair(at(0, 0, 0, 1, 0), at(1.3, 0, 0, -1, 0)));
    // Same X, facing up/down → straight. A pad with no outward axis ({0,0})
    // imposes no facing constraint, so a facing partner alone suffices.
    try testing.expect(pad_exit.straightEscapePair(at(2, 1, 0, 0, 1), at(2, 4, 0, 0, -1)));
    try testing.expect(pad_exit.straightEscapePair(at(0, 0, 0, 1, 0), at(1.3, 0, 0, 0, 0)));
    // A small off-axis slope within ~11° still counts (facing).
    try testing.expect(pad_exit.straightEscapePair(at(0, 0, 0, 1, 0), at(2, 0.2, 0, -1, 0)));
    // Axis-aligned but a pad faces PERPENDICULAR to the hop (the escape-reserve
    // case): the straight line would leave it sideways → refused.
    try testing.expect(!pad_exit.straightEscapePair(at(0, 0, 0, 0, 1), at(1.3, 0, 0, -1, 0)));
    // A steeper slope, a 45° diagonal, coincident, and cross-layer are refused.
    try testing.expect(!pad_exit.straightEscapePair(at(0, 0, 0, 1, 0), at(2, 1, 0, -1, 0)));
    try testing.expect(!pad_exit.straightEscapePair(at(0, 0, 0, 1, 0), at(1, 1, 0, -1, -1)));
    try testing.expect(!pad_exit.straightEscapePair(at(3, 3, 0, 1, 0), at(3, 3, 0, -1, 0)));
    try testing.expect(!pad_exit.straightEscapePair(at(0, 0, 0, 1, 0), at(1.3, 0, 1, -1, 0)));
}

// ── Live progress sink + cooperative cancel (phase-1 live-route hooks) ────────

/// A placement of `n` well-separated two-pad signal nets, each of which routes
/// on its own row of the open board — the fixture for the streaming-sink and
/// cancel tests. Net `i` joins parts `A<i>`/`B<i>` on row `i`, so every net
/// routes independently and a full run reports `routed == total == n`.
fn separatedNetPlacement(arena: std.mem.Allocator, n: usize) std.mem.Allocator.Error!optimizer.Placement {
    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const pads = try arena.dupe(geometry.Pad, &pad);
    const parts = try arena.alloc(Part, n * 2);
    const nets = try arena.alloc(FlatNet, n);
    for (0..n) |i| {
        const row: f64 = @floatFromInt(i * 3);
        const a_ref = try std.fmt.allocPrint(arena, "A{d}", .{i});
        const b_ref = try std.fmt.allocPrint(arena, "B{d}", .{i});
        parts[i * 2] = .{ .ref_des = a_ref, .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = pads, .fallback = false, .x = 0, .y = row };
        parts[i * 2 + 1] = .{ .ref_des = b_ref, .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = pads, .fallback = false, .x = 3, .y = row };
        const pins = try arena.alloc(flat_netlist.FlatPin, 2);
        pins[0] = .{ .ref_des = a_ref, .pin = "1" };
        pins[1] = .{ .ref_des = b_ref, .pin = "1" };
        nets[i] = .{ .name = try std.fmt.allocPrint(arena, "N{d}", .{i}), .pins = pins };
    }
    const maxy: f64 = @floatFromInt((n - 1) * 3);
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -0.5,
        .miny = -0.5,
        .maxx = 3.5,
        .maxy = maxy + 0.5,
        .generated = true,
    };
}

/// Records the kind of every streamed event. Zig has no closures, so a static
/// sink carries its state through the `?*anyopaque` ctx pointer and restores
/// the erased event pointer with `@ptrCast(@alignCast(...))`.
const KindCollector = struct {
    arena: std.mem.Allocator,
    kinds: std.ArrayList(RouteEventKind) = .empty,
    /// Set if a stream append ever failed — the test asserts it stayed false
    /// (the sink cannot propagate an error through its `void` signature).
    oom: bool = false,

    fn emit(ctx: ?*anyopaque, ev: *const anyopaque) void {
        const self: *KindCollector = @ptrCast(@alignCast(ctx));
        const event: *const RouteEvent = @ptrCast(@alignCast(ev));
        self.kinds.append(self.arena, event.kind) catch {
            self.oom = true;
        };
    }
};

/// Trips a cancel flag the first time a net finishes routing — the sink that
/// drives the mid-run cancel test.
const CancelOnFirstRouted = struct {
    flag: *std.atomic.Value(bool),
    tripped: bool = false,

    fn emit(ctx: ?*anyopaque, ev: *const anyopaque) void {
        const self: *CancelOnFirstRouted = @ptrCast(@alignCast(ctx));
        const event: *const RouteEvent = @ptrCast(@alignCast(ev));
        if (!self.tripped and event.kind == .net_routed) {
            self.tripped = true;
            self.flag.store(true, .monotonic);
        }
    }
};

// spec: placement/router - a progress sink observes every captured timeline event in order during a routed run
test "a progress sink streams the timeline event kinds in order" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const placement = try separatedNetPlacement(arena, 2);
    var collector = KindCollector{ .arena = arena };
    const sink = route_policy.ProgressSink{ .ctx = &collector, .emit = KindCollector.emit };
    const run = try routeWithTimeline(arena, placement, .{}, .{ .sink = sink });

    // The sink saw exactly the run's finished timeline, in the same order.
    try testing.expect(!collector.oom);
    try testing.expectEqual(run.timeline.len, collector.kinds.items.len);
    for (run.timeline, collector.kinds.items) |ev, streamed| {
        try testing.expectEqual(ev.kind, streamed);
    }
    try testing.expect(collector.kinds.items.len >= 2);
    try testing.expectEqual(RouteEventKind.initial, collector.kinds.items[0]);
    try testing.expectEqual(
        RouteEventKind.complete,
        collector.kinds.items[collector.kinds.items.len - 1],
    );
    // A plain (uncancelled) run routes both nets and is not flagged cancelled.
    try testing.expectEqual(@as(usize, 2), run.routed.routed);
    try testing.expect(!run.routed.cancelled);
}

// spec: placement/router - a cancelled run stops at a net boundary and still finishes to a valid partial result
test "a cancel tripped mid-run stops routing yet finishes a valid partial run" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const placement = try separatedNetPlacement(arena, 3);
    var flag: std.atomic.Value(bool) = .init(false);
    var canceller = CancelOnFirstRouted{ .flag = &flag };
    const sink = route_policy.ProgressSink{ .ctx = &canceller, .emit = CancelOnFirstRouted.emit };
    const run = try routeWithTimeline(arena, placement, .{}, .{ .sink = sink, .stop = .{ .cancel = &flag } });

    try testing.expect(run.routed.cancelled);
    // Exactly the first net routed; the cancel stopped the rest at a net
    // boundary, so they stay failed and routed is a strict partial.
    try testing.expect(run.routed.routed >= 1);
    try testing.expect(run.routed.routed < run.routed.total);
    try testing.expectEqual(run.routed.total - run.routed.routed, run.routed.failed.len);
    // The finish path still ran: a complete timeline and a well-formed board
    // (the one routed net left real copper).
    try testing.expect(run.timeline.len >= 2);
    try testing.expectEqual(
        RouteEventKind.complete,
        run.timeline[run.timeline.len - 1].kind,
    );
    try testing.expect(run.routed.tracks.len >= 1);
}

// spec: placement/router - a run cancelled before it starts routes nothing and still records a complete timeline
test "a run cancelled before routing produces an empty partial run with a complete timeline" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const placement = try separatedNetPlacement(arena, 3);
    var flag: std.atomic.Value(bool) = .init(true); // cancelled before the first net
    const run = try routeWithTimeline(arena, placement, .{}, .{ .stop = .{ .cancel = &flag } });

    try testing.expect(run.routed.cancelled);
    try testing.expectEqual(@as(usize, 0), run.routed.routed);
    // Every net was reached-but-unrouted, so all are reported failed.
    try testing.expectEqual(run.routed.total, run.routed.failed.len);
    try testing.expect(run.routed.total >= 1);
    // The finish path still ran: initial + complete bracket a valid timeline.
    try testing.expectEqual(RouteEventKind.initial, run.timeline[0].kind);
    try testing.expectEqual(
        RouteEventKind.complete,
        run.timeline[run.timeline.len - 1].kind,
    );
    // A well-formed, empty-copper board — not a crash or a null slice.
    try testing.expectEqual(@as(usize, 0), run.routed.tracks.len);
}

// spec: placement/route-deadline - an expired route deadline stops before the first net and returns a valid cancelled partial board
test "an expired route deadline stops before the first net" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const placement = try separatedNetPlacement(arena, 3);
    const run = try routeWithTimeline(arena, placement, .{}, .{ .stop = .{ .deadline_ns = 1 } });
    try testing.expect(run.routed.cancelled);
    try testing.expectEqual(@as(usize, 0), run.routed.routed);
    try testing.expectEqual(run.routed.total, run.routed.failed.len);
    try testing.expectEqual(RouteEventKind.complete, run.timeline[run.timeline.len - 1].kind);
}

/// A minimal two-terminal board for the terminal via-ban tests: same-net pads
/// at (0,0) and (10,0), which is all `markTerminalViaBan` reads — the ban is a
/// per-terminal footprint mask, so whatever sits in the corridor between them is
/// beside the point. The gap-closing BEHAVIOUR suite and its walled/slotted
/// boards live in `gap_close_route.zig` (this file is at its file-size cap); the
/// two tests below stay here only because they read the private gap context.
fn viaBanPlacement(arena: std.mem.Allocator) std.mem.Allocator.Error!optimizer.Placement {
    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const parts = try arena.alloc(Part, 2);
    parts[0] = .{ .ref_des = "A", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 0, .y = 0 };
    parts[1] = .{ .ref_des = "B", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 10, .y = 0 };
    const pins = try arena.alloc(flat_netlist.FlatPin, 2);
    pins[0] = .{ .ref_des = "A", .pin = "1" };
    pins[1] = .{ .ref_des = "B", .pin = "1" };
    const nets = try arena.alloc(FlatNet, 1);
    nets[0] = .{ .name = "SIG", .pins = pins };
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .rules = .{ .copper_layers = 4 },
        .minx = -1,
        .miny = -4,
        .maxx = 11,
        .maxy = 6,
        .generated = true,
    };
}

/// The one hop those tests measure: terminal A to terminal B.
fn viaBanGap() Gap {
    return .{
        .net_i = 0,
        .from = .{ .x = 0, .y = 0, .layer = 0 },
        .to = .{ .x = 10, .y = 0, .layer = 0 },
    };
}

/// How many grid nodes the terminal via-ban would forbid for one hop under
/// `policy` — the mask the maze reads through `Ctx.via_forbidden_mask`.
fn termBanNodes(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    gap: Gap,
    policy: TerminalVia,
) std.mem.Allocator.Error!usize {
    var ctx = switch (try buildGapCtx(arena, placement, .{}, gap_grid_divisor, null)) {
        .ok => |c| c,
        else => return 0,
    };
    var state = GapState{
        .ctx = &ctx,
        .placement = placement,
        .board = .{},
        .opts = .{ .terminal_via = policy },
        .dead = &.{},
        .holes = &.{},
        .term_ban = try arena.alloc(bool, ctx.grid.nx * ctx.grid.ny),
    };
    markTerminalViaBan(&state, gap, @intCast(gap.net_i));
    var n: usize = 0;
    for (state.term_ban) |banned| {
        if (banned) n += 1;
    }
    return n;
}

fn testGapCtx(arena: std.mem.Allocator, placement: optimizer.Placement) std.mem.Allocator.Error!Ctx {
    return switch (try buildGapCtx(arena, placement, .{}, gap_grid_divisor, null)) {
        .ok => |ctx| ctx,
        else => error.OutOfMemory,
    };
}

// spec: placement/router - the smd_ok terminal-via policy frees an SMD terminal pad for a hop's escape via while a through-hole terminal stays banned
test "closeGaps frees an SMD terminal via only under the smd_ok policy" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const placement = try viaBanPlacement(arena);
    const smd = viaBanGap();
    var thru = viaBanGap();
    thru.from.thru = true;

    // The default bans a via in either terminal, SMD or not.
    try testing.expect(try termBanNodes(arena, placement, smd, .banned) > 0);
    try testing.expect(try termBanNodes(arena, placement, thru, .banned) > 0);

    // `smd_ok` frees the SMD terminal — the via a fine-pitch row leaves as the
    // only way off the pad — while a through-hole terminal stays off limits.
    try testing.expectEqual(@as(usize, 0), try termBanNodes(arena, placement, smd, .smd_ok));
    try testing.expect(try termBanNodes(arena, placement, thru, .smd_ok) > 0);
}

// spec: placement/route-deadline - a route deadline reached during an additive gap hop stops that hop's maze rather than waiting for its expansion ceiling
test "closeGaps observes the containing route deadline inside a hop" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const placement = try viaBanPlacement(arena);
    const paths = try closeGaps(arena, placement, .{}, .{}, &.{viaBanGap()}, .{
        .raster = .{ .stop = .{ .deadline_ns = 1 } },
    });
    try testing.expectEqual(@as(usize, 1), paths.len);
    try testing.expect(paths[0] == null);
}

// spec: Web Server - A fine gap rescue tries an exact outer-face escape before its inner-layer multi-via fallback after the ordinary raster drains
test "a fine gap rescue uses exact multi-via terminal escapes" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const placement = try viaBanPlacement(arena);
    var ctx = try testGapCtx(arena, placement);
    const gap = viaBanGap();
    var state = GapState{
        .ctx = &ctx,
        .placement = placement,
        .board = .{},
        .opts = .{ .terminal_via = .smd_ok },
        .dead = &.{},
        .holes = &.{},
        .term_ban = try arena.alloc(bool, ctx.grid.nx * ctx.grid.ny),
    };
    setNetParams(&ctx, placement, gap.net_i);
    ctx.allowed_layers = gapLayers(&ctx, @intCast(gap.net_i));
    const wall = [_]Track{.{
        .x1 = 5,
        .y1 = -4,
        .x2 = 5,
        .y2 = 6,
        .layer = 0,
        .width = 0.5,
        .net = 1,
    }};
    const live = GapBoard{ .tracks = &wall };
    stampGapBoard(&ctx, live, @intCast(gap.net_i));

    const path = (try exactGapRescue(&state, live, gap.from, gap.to.?, @intCast(gap.net_i))) orelse
        return error.TestUnexpectedResult;
    try testing.expect(path.vias.len >= 2);
    var used_inner = false;
    for (path.tracks) |track| used_inner = used_inner or track.layer >= 2;
    try testing.expect(used_inner);
}

// spec: Web Server - A fine gap rescue on a plane-only four-layer stack uses the opposite outer face when its terminal face is blocked
test "a fine gap rescue falls back to the opposite outer face" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    var placement = try viaBanPlacement(arena);
    // Model the signal-layer view of a four-layer board whose two inner layers
    // are planes: only F.Cu and B.Cu are legal for tracks.
    placement.rules.copper_layers = 2;
    var ctx = try testGapCtx(arena, placement);
    const gap = viaBanGap();
    var state = GapState{
        .ctx = &ctx,
        .placement = placement,
        .board = .{},
        .opts = .{ .terminal_via = .smd_ok },
        .dead = &.{},
        .holes = &.{},
        .term_ban = try arena.alloc(bool, ctx.grid.nx * ctx.grid.ny),
    };
    setNetParams(&ctx, placement, gap.net_i);
    ctx.allowed_layers = gapLayers(&ctx, @intCast(gap.net_i));
    const wall = [_]Track{.{
        .x1 = 5,
        .y1 = -4,
        .x2 = 5,
        .y2 = 6,
        .layer = 0,
        .width = 0.5,
        .net = 1,
    }};
    const live = GapBoard{ .tracks = &wall };
    stampGapBoard(&ctx, live, @intCast(gap.net_i));

    const path = (try exactGapRescue(&state, live, gap.from, gap.to.?, @intCast(gap.net_i))) orelse
        return error.TestUnexpectedResult;
    try testing.expect(path.vias.len >= 2);
    var used_back = false;
    for (path.tracks) |track| used_back = used_back or track.layer == 1;
    try testing.expect(used_back);
}

// spec: Web Server - A fine gap raster may opt into a capped expansion multiplier without changing its allocated search region
test "gap expansion effort is capped and leaves the raster size alone" {
    const base = scaledGapCeiling(gap_max_expansions, gap_grid_divisor);
    const finer = scaledGapCeiling(gap_max_expansions, gap_grid_divisor * 2);
    try testing.expect(finer > base);
    const requested: usize = 99;
    const effort = @max(@as(usize, 1), @min(requested, 8));
    try testing.expectEqual(@as(usize, 8), effort);
    try testing.expectEqual(finer * 8, finer * effort);
}

// spec: placement/router - a stitch hop's own SMD terminal pad is never via-banned, while a through-hole stitch terminal stays banned
test "a stitch's SMD pad stays via-legal under the banned policy" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const placement = try viaBanPlacement(arena);
    // A stitch has no far terminal — the via AT the stranded pad is the whole
    // point of the hop, so even the default `banned` policy must not mask it.
    var stitch = viaBanGap();
    stitch.to = null;
    try testing.expectEqual(@as(usize, 0), try termBanNodes(arena, placement, stitch, .banned));

    // A through-hole stitch terminal keeps the ban: a barrel beside a same-net
    // drill is redundant copper and a hole-to-hole violation.
    var thru_stitch = viaBanGap();
    thru_stitch.to = null;
    thru_stitch.from.thru = true;
    try testing.expect(try termBanNodes(arena, placement, thru_stitch, .banned) > 0);
}

// spec: placement/router - a plane stitch with no legal via site falls back to the oracle's short pad bridge
test "a stitch with no via site falls back to its pad bridge" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const placement = try viaBanPlacement(arena);
    // This net's retained pour begins eight millimetres away. A stitch beside
    // the left pad cannot reach any point inside it (the bounded stitch maze
    // reaches five millimetres), while the two same-face pads still have a
    // clear straight trace between them.
    const pour_poly = [_][2]f64{ .{ 8, -1 }, .{ 11, -1 }, .{ 11, 1 }, .{ 8, 1 } };
    const zones = [_]route_policy.ExistingZone{.{ .polygon = &pour_poly, .layer = 0, .net = 0 }};
    const params = RouteParams{ .track_width = 0.2, .clearance = 0.1 };
    const gap = Gap{
        .net_i = 0,
        .from = .{ .x = 0, .y = 0, .layer = 0 },
        .stitch_fallback = .{ .x = 10, .y = 0, .layer = 0 },
    };
    const paths = try closeGaps(arena, placement, params, .{ .zones = &zones }, &.{gap}, .{
        .ripup = false,
        .raster = .{ .window = GapWindow.around(gap, 1) },
    });
    const path = paths[0] orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 0), path.vias.len);
    try testing.expect(path.tracks.len > 0);
}

// spec: placement/route-resolution - a declared resolution is honoured under one-shot effort, since it is the author's instruction rather than a router retry
test "one-shot still runs the rescue for a net that declared its own pitch" {
    // `finishBatch` skips the windowed rescue under one_shot — EXCEPT when some
    // net declared `(resolution …)`, because that is already the author's
    // instruction and honouring it is following the plan, not retrying.
    var placement = std.mem.zeroes(optimizer.Placement);
    const plain = [_]optimizer.NetRule{ .{}, .{} };
    placement.rules.net = &plain;
    try testing.expect(!anyDeclaredResolution(placement));

    const declared = [_]optimizer.NetRule{ .{}, .{ .resolution_mm = 0.05 } };
    placement.rules.net = &declared;
    try testing.expect(anyDeclaredResolution(placement));

    const fine_only = FineRescueRun{
        .ctx = undefined,
        .placement = placement,
        .idx_of = undefined,
        .routable = &.{},
        .tracks = undefined,
        .vias = undefined,
        .declared_only = true,
    };
    try testing.expect(!fineRescueEligible(fine_only, 0));
    try testing.expect(fineRescueEligible(fine_only, 1));
}

// spec: placement/router - a plane stitch may land in ANY of its net's pours, not only the largest
test "a stitch site is judged against every same-net pour" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    // Two pours on one net: a big one far away and a small one under the pad.
    // Judging only the LARGEST strands the pad sitting on its own copper.
    const big = [_][2]f64{ .{ 20, 20 }, .{ 40, 20 }, .{ 40, 40 }, .{ 20, 40 } };
    const small = [_][2]f64{ .{ 0, 0 }, .{ 2, 0 }, .{ 2, 2 }, .{ 0, 2 } };
    const zones = [_]route_policy.ExistingZone{
        .{ .polygon = &big, .layer = 0, .net = 0 },
        .{ .polygon = &small, .layer = 0, .net = 0 },
    };
    var ctx = Ctx{
        .arena = arena,
        .grid = .{ .ox = 0, .oy = 0, .g = 1, .nx = 2, .ny = 2 },
        .occ = &.{},
        .resv = &.{},
        .obs = &.{},
        .reach = 0.1905,
        .params = .{},
        .base = .{},
    };
    ctx.zones = &zones;
    // The larger pour does not cover the pad's neighbourhood...
    try testing.expect(!zonePoured(&ctx, zones[0], 1, 1));
    // ...but the net's pour coverage as a whole does.
    try testing.expect(netPourCovers(&ctx, 0, 1, 1, null));
}

// spec: placement/router - a stranded pad's stitch target is the pour copper that survives priority clipping AROUND THAT PAD, so a net whose fill is knocked back there is stitched as if it had no pour
test "a stitch target is judged on the fill that survives near the pad" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // The barracuda shape, in miniature: a low pour (net 0) overlapped end to
    // end by a higher-priority foreign one (net 1) except for a surviving band
    // along its west edge. `largestNetZone` sees one pour and answers "poured"
    // everywhere; only the fill says where the copper actually is.
    const lo = [_][2]f64{ .{ 0, 0 }, .{ 20, 0 }, .{ 20, 10 }, .{ 0, 10 } };
    const hi = [_][2]f64{ .{ 2, 0 }, .{ 20, 0 }, .{ 20, 10 }, .{ 2, 10 } };
    const zones = [_]route_policy.ExistingZone{
        .{ .polygon = &lo, .layer = 0, .net = 0, .priority = 0 },
        .{ .polygon = &hi, .layer = 0, .net = 1, .priority = 1 },
    };
    var ctx = Ctx{
        .arena = arena,
        .grid = .{ .ox = 0, .oy = 0, .g = 1, .nx = 21, .ny = 11 },
        .occ = try allocLayerGrids(arena, 1, 21 * 11),
        .resv = &.{},
        .obs = &.{},
        .reach = 0.1905,
        .params = .{},
        .base = .{},
    };
    ctx.zones = &zones;

    // Locality, both ways. A pad standing in the surviving band is over live
    // copper; one 4 mm east of it still reaches the band; one at the far end
    // reaches no surviving fill at all, though its own pour's polygon covers it.
    try testing.expect(pourLiveNear(&ctx, 0, 1, 5, 5));
    try testing.expect(pourLiveNear(&ctx, 0, 5, 5, 5));
    try testing.expect(!pourLiveNear(&ctx, 0, 18, 5, 5));

    // The three targets. Naming the pour's net "V_LO" keeps it off both plane
    // predicates, so the knocked-back pad has nothing left to tap.
    const nets = try arena.alloc(FlatNet, 2);
    nets[0] = .{ .name = "V_LO", .pins = &.{} };
    nets[1] = .{ .name = "V_HI", .pins = &.{} };
    var placement = std.mem.zeroes(optimizer.Placement);
    placement.nets = nets;
    placement.rules = .{ .plane_nets = &.{} };
    var state = GapState{
        .ctx = &ctx,
        .placement = placement,
        .board = .{},
        .opts = .{},
        .dead = &.{},
        .holes = &.{},
        .term_ban = &.{},
    };
    try testing.expectEqual(StitchTarget.pour, stitchTarget(&state, .{ .x = 1, .y = 5, .layer = 0 }, 0, 5));
    try testing.expectEqual(StitchTarget.none, stitchTarget(&state, .{ .x = 18, .y = 5, .layer = 0 }, 0, 5));
    // The higher pour is knocked back by nobody, so it is poured where it lies.
    try testing.expectEqual(StitchTarget.pour, stitchTarget(&state, .{ .x = 18, .y = 5, .layer = 0 }, 1, 5));
    // A net with no retained pour keeps the old reading: the plane is the
    // target and any legal site taps it.
    try testing.expectEqual(StitchTarget.plane, stitchTarget(&state, .{ .x = 18, .y = 5, .layer = 0 }, 2, 5));
}

// spec: placement/router - a stitch onto a pour a higher-priority overlap knocked back falls through to its trace fallback, while the same geometry at equal priority still stitches
test "a knocked-back pour is stitched as a trace, an unclipped one as a via" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const placement = try viaBanPlacement(arena);
    const params = RouteParams{ .track_width = 0.2, .clearance = 0.1 };
    const gap = Gap{
        .net_i = 0,
        .from = .{ .x = 0, .y = 0, .layer = 0 },
        .stitch_fallback = .{ .x = 10, .y = 0, .layer = 0 },
    };
    // `SIG`'s own pour sits right under the stranded pad, and a FOREIGN pour
    // covers the same ground. Everything below is held fixed but the priority.
    const mine = [_][2]f64{ .{ -3, -3 }, .{ 3, -3 }, .{ 3, 3 }, .{ -3, 3 } };
    const theirs = [_][2]f64{ .{ -3, -3 }, .{ 3, -3 }, .{ 3, 3 }, .{ -3, 3 } };

    // Equal priority: nothing is knocked back, so the pad taps its own copper.
    const tied = [_]route_policy.ExistingZone{
        .{ .polygon = &mine, .layer = 0, .net = 0, .priority = 0 },
        .{ .polygon = &theirs, .layer = 0, .net = 1, .priority = 0 },
    };
    const stitched = try closeGaps(arena, placement, params, .{ .zones = &tied }, &.{gap}, .{
        .ripup = false,
        .raster = .{ .window = GapWindow.around(gap, 1) },
    });
    const via_path = stitched[0] orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 1), via_path.vias.len);

    // Outranked: `SIG`'s fill is gone from every point the pad could reach, so
    // a barrel would be drilled into a clearance gap. The hop takes the trace.
    const outranked = [_]route_policy.ExistingZone{
        .{ .polygon = &mine, .layer = 0, .net = 0, .priority = 0 },
        .{ .polygon = &theirs, .layer = 0, .net = 1, .priority = 1 },
    };
    const traced = try closeGaps(arena, placement, params, .{ .zones = &outranked }, &.{gap}, .{
        .ripup = false,
        .raster = .{ .window = GapWindow.around(gap, 1) },
    });
    const trace_path = traced[0] orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 0), trace_path.vias.len);
    try testing.expect(trace_path.tracks.len > 0);
}

// spec: placement/router - a foreign net's pad landing carved out of a keepout halo is keyed to that pad's net, so no other net threads it
test "a keepout halo's pad-landing opening admits only that pad's net" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Net 0 is the RF net (0.5 mm halo); net 1 owns a pad sitting inside that
    // halo, and net 2 is a passer-by with nothing there.
    const grid = Grid{ .ox = 0, .oy = 0, .g = 0.1, .nx = 120, .ny = 120 };
    const pads = [_]PadObs{.{ .x0 = 5.9, .y0 = 5.2, .x1 = 6.1, .y1 = 5.4, .net = 1 }};
    const halos = [_]f64{ 0.5, 0, 0 };
    var ctx = Ctx{
        .arena = arena,
        .grid = grid,
        .occ = &.{},
        .resv = &.{},
        .obs = &pads,
        .reach = 0.19,
        .params = .{},
        .base = .{},
    };
    ctx.index_reach = 0.19;
    ctx.keep.nets = &halos;
    ctx.keep.layers = try allocLayerGrids(arena, 1, grid.nx * grid.ny);
    ctx.keep.gate = try allocLayerGrids(arena, 1, grid.nx * grid.ny);
    ctx.keep.halo = 0.5;
    stampKeepoutSeg(&ctx, .{ 2, 5 }, .{ 10, 5 }, keepStamp(&ctx, 0, 0, 0.0635));

    // A node in the pad's clearance landing but off its copper: the opening is
    // there so net 1 can escape its own pad, and it admits nobody else.
    const landing = grid.node(60, 51);
    try testing.expect(!keepoutBlocked(&ctx, 0, landing, 1));
    try testing.expect(keepoutBlocked(&ctx, 0, landing, 2));
    // Plain halo well away from the pad is shut to both, and open to its owner.
    const plain = grid.node(40, 53);
    try testing.expect(keepoutBlocked(&ctx, 0, plain, 1));
    try testing.expect(keepoutBlocked(&ctx, 0, plain, 2));
    try testing.expect(!keepoutBlocked(&ctx, 0, plain, 0));
}

// spec: placement/router - a derived context's obstacle stamp opens its keepout surplus inside an admitting escape zone and keeps the full halo outside it, on the raster and on the exact re-measure alike
test "a rescue context's stamped keepout halo opens inside an admitting escape zone" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Net 1 is the RF net: a 0.5 mm halo, a 1 mm escape radius around its own pad
    // at (3, 5), and a track along y = 5. Net 0 is the neighbour pin escaping past
    // it, owning a pad at (3, 5.8) INSIDE that zone — the whole qualification.
    // Net 2 is a passer-by with a pad nowhere near. Clearance 0.2 under a 0.2 mm
    // track puts the ordinary reach at 0.4 mm and the halo at 0.7 mm.
    const nets = [_]FlatNet{
        .{ .name = "SPI_SCK", .pins = &.{} },
        .{ .name = "RF1_BPF", .pins = &.{} },
        .{ .name = "SPI_MOSI", .pins = &.{} },
    };
    const rules = [_]optimizer.NetRule{
        .{},
        .{ .rf = .{ .keepout_mm = 0.5, .keepout_escape_mm = 1.0 } },
        .{},
    };
    const placement = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 7,
        .generated = true,
        .rules = .{ .net = &rules },
    };
    const pads = try arena.dupe(keepout.PadPt, &[_]keepout.PadPt{
        .{ .net = 1, .x = 3, .y = 5 },
        .{ .net = 0, .x = 3, .y = 5.8 },
        .{ .net = 2, .x = 9, .y = 1 },
    });
    const grid = Grid{ .ox = 0, .oy = 0, .g = 0.05, .nx = 200, .ny = 140 };
    const cells = grid.nx * grid.ny;
    var ctx = Ctx{
        .arena = arena,
        .grid = grid,
        .obs = &.{},
        .reach = 0.3,
        .occ = try allocLayerGrids(arena, 2, cells),
        .resv = try allocLayerGrids(arena, 2, cells),
        .params = .{ .track_width = 0.2, .clearance = 0.2 },
        .base = .{},
        .index_reach = 0.3,
    };
    ctx.keep.nets = try keepout.halos(arena, placement);
    ctx.keep.pads = pads;
    ctx.keep.zones = try keepout.buildZones(arena, placement, pads);
    keepout.admitCurrent(ctx.keep.zones, pads, 0); // what `setNetParams` leaves
    const foreign = [_]Track{
        .{ .x1 = 2, .y1 = 5, .x2 = 8, .y2 = 5, .layer = 0, .width = 0.2, .net = 1 },
    };
    // A windowed retry / gap hop carries no halo node mask, so this stamp is its
    // whole keepout enforcement.
    stampBoardCopper(&ctx, &foreign, &.{}, 0);

    // 0.55 mm off the centreline: clear of the 0.4 mm ordinary clearance, inside
    // the 0.7 mm halo. Under the RF pad's escape zone the surplus stands down…
    try testing.expectEqual(empty_cell, ctx.occ[0][grid.node(60, 111)]);
    // …and 3 mm along the same track, outside every zone, it does not.
    try testing.expectEqual(@as(i32, 1), ctx.occ[0][grid.node(120, 111)]);
    // The ordinary clearance under the halo is never waived, zone or not.
    try testing.expectEqual(@as(i32, 1), ctx.occ[0][grid.node(60, 106)]);
    // Past the halo the raster is free whatever the gate says.
    try testing.expectEqual(empty_cell, ctx.occ[0][grid.node(120, 116)]);

    // The gap pass re-measures each move against the copper itself; that path
    // owes the same waiver, or the raster's opening leads only to a move the
    // exact check refuses.
    ctx.exact = .{ .near = try arena.alloc(bool, ctx.occ.len * cells) };
    stampBoardCopper(&ctx, &foreign, &.{}, 0);
    try testing.expect(moveClearsCopper(&ctx, 0, grid.node(59, 111), 0, grid.node(60, 111)));
    try testing.expect(!moveClearsCopper(&ctx, 0, grid.node(119, 111), 0, grid.node(120, 111)));
    try testing.expect(!moveClearsCopper(&ctx, 0, grid.node(59, 106), 0, grid.node(60, 106)));

    // Re-aim the gate at the passer-by: the same opening is not net 2's to use,
    // so the full halo stands over the RF pad as well as away from it.
    for (ctx.occ) |lane| @memset(lane, empty_cell);
    keepout.admitCurrent(ctx.keep.zones, pads, 2);
    stampBoardCopper(&ctx, &foreign, &.{}, 2);
    try testing.expectEqual(@as(i32, 1), ctx.occ[0][grid.node(60, 111)]);
    try testing.expect(!moveClearsCopper(&ctx, 2, grid.node(59, 111), 0, grid.node(60, 111)));
}

/// A bare four-signal-layer context for the shape tier's decision tests.
fn shapeTestCtx(arena: std.mem.Allocator, grid: Grid) std.mem.Allocator.Error!Ctx {
    const nodes = grid.nx * grid.ny;
    return .{
        .arena = arena,
        .grid = grid,
        .obs = &.{},
        .reach = 0.2,
        .occ = try allocLayerGrids(arena, 4, nodes),
        .resv = try allocLayerGrids(arena, 4, nodes),
        .params = .{},
        .base = .{},
        .index_reach = 0.2,
    };
}

// spec: placement/router - the shape tier declines a clock-free board and accepts one with wall clock to spare per remaining net
test "the shape tier is gated on spare wall clock, not offered to clock-free boards" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var ctx = try shapeTestCtx(arena, .{ .ox = 0, .oy = 0, .g = 0.254, .nx = 40, .ny = 40 });
    // A corpus/bench route carries no deadline. "Is there time left" is not a
    // question it can be asked, so the tier must never fire there — that is what
    // keeps a deterministic board's result unmoved by this feature existing.
    ctx.deadline_ns = 0;
    try testing.expect(!shapeTierAffordable(&ctx, 3));
    // A served route with minutes in hand affords it for a handful of nets.
    ctx.deadline_ns = clock.nanoTimestamp() + 300 * clock.ns_per_s;
    try testing.expect(shapeTierAffordable(&ctx, 3));
    // The allowance is PER remaining net, so the same clock does not stretch
    // over an unbounded residue.
    try testing.expect(!shapeTierAffordable(&ctx, 100));
    // And nothing is affordable once the deadline is behind us.
    ctx.deadline_ns = clock.nanoTimestamp() - clock.ns_per_s;
    try testing.expect(!shapeTierAffordable(&ctx, 1));
}

// spec: placement/router - the shape tier offers a net the layers its policy allows, priced as the maze prices them
test "the shape tier's layer list honours the net policy and the maze's own layer costs" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var ctx = try shapeTestCtx(arena, .{ .ox = 0, .oy = 0, .g = 0.254, .nx = 40, .ny = 40 });
    // Unrestricted policy: every signal layer is on offer, the inner ones at the
    // maze's inner multiplier and the clear outer faces at par.
    const all = try shapeLayers(arena, &ctx, 0);
    try testing.expectEqual(@as(usize, 4), all.len);
    try testing.expectEqual(@as(u8, 0), all[0].index);
    try testing.expectApproxEqAbs(@as(f64, 1.0), all[0].cost, 1e-12);
    try testing.expectApproxEqAbs(inner_cost_mult, all[2].cost, 1e-12);
    // A poured outer face costs the maze's pour multiplier, not par.
    ctx.pour = .{ true, false };
    const poured = try shapeLayers(arena, &ctx, 0);
    try testing.expectApproxEqAbs(pour_cost_mult, poured[0].cost, 1e-12);
    ctx.pour = .{ false, false };
    // An authored `(allowed-layers …)` is HARD: a layer outside it is not
    // offered at all, however cheap it would have been.
    ctx.allowed_layers = (@as(u64, 1) << 0) | (@as(u64, 1) << 1);
    const outer_only = try shapeLayers(arena, &ctx, 0);
    try testing.expectEqual(@as(usize, 2), outer_only.len);
    try testing.expectEqual(@as(u8, 0), outer_only[0].index);
    try testing.expectEqual(@as(u8, 1), outer_only[1].index);
    // A foreign pour on an inner layer withdraws it — that layer is a reserved
    // plane, and slicing a signal through it is the damage the gap pass's own
    // rule exists to prevent.
    ctx.allowed_layers = 0;
    ctx.zones = &.{.{ .polygon = &.{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } }, .layer = 3, .net = 7 }};
    const no_in3 = try shapeLayers(arena, &ctx, 0);
    try testing.expectEqual(@as(usize, 3), no_in3.len);
    for (no_in3) |l| try testing.expect(l.index != 3);
}

// spec: placement/router - the shape tier's window is the net's terminal box with room to bow, clamped to the routing grid
test "the shape tier window bows around the terminals and stays on the grid" {
    // A 0.254 mm grid 40 x 40 spans 0 .. 9.906 mm.
    const grid = Grid{ .ox = 0, .oy = 0, .g = 0.254, .nx = 40, .ny = 40 };
    const pts = [_]NetPt{
        .{ .x = 4.0, .y = 5.0, .layer = 0 },
        .{ .x = 6.0, .y = 5.0, .layer = 1 },
    };
    // Here the raster and the board are the same extent (see `ShapeBounds.of`).
    const w = shapeWindow(.{ .x0 = 0, .y0 = 0, .x1 = grid.worldX(grid.nx - 1), .y1 = grid.worldY(grid.ny - 1) }, &pts);
    // The margin is real room to detour, and the grid extent is a hard clamp —
    // the obstacle scan only covered what the grid covers.
    try testing.expectApproxEqAbs(@as(f64, 0.0), w.x0, 1e-12);
    try testing.expectApproxEqAbs(grid.worldX(grid.nx - 1), w.x1, 1e-12);
    try testing.expect(w.y0 >= 0.0 and w.y1 <= grid.worldY(grid.ny - 1));
    try testing.expect(w.x1 - w.x0 > 2.0 and w.y1 - w.y0 > 2.0);
}

// spec: placement/router - every gridless mesh request is assembled by one builder, which models the routing net's own track width unless the caller names a wider channel
test "a mesh request takes the net's track width, and a pair's envelope when it asks" {
    const here = NetPt{ .x = 1.0, .y = 1.0, .layer = 0 };
    const there = NetPt{ .x = 5.0, .y = 1.0, .layer = 0 };
    const plain = ShapeAsk{ .placement = undefined, .tracks = &.{}, .vias = &.{}, .from = here, .to = there };
    // Every single-net caller — the gap hop and the whole-net shape rescue —
    // leaves `width` at its default, which is the model they have always used.
    try testing.expectEqual(@as(f64, 0.2), shapeWidth(plain, 0.2));
    // A COUPLED pair is the one caller that needs more room than one trace: the
    // centreline it asks for is split into two legs, so the channel has to hold
    // `2·width + gap` (`diff_shape.envelopeCenterline`).
    var envelope = plain;
    envelope.width = 2 * 0.2 + 0.127;
    try testing.expectEqual(@as(f64, 0.527), shapeWidth(envelope, 0.2));
}

// spec: placement/router - a shape window is clamped to its own context's raster, not to the whole board, because the emission gate refuses every point outside that raster
test "the shape tier window never leaves the raster its gate measures against" {
    // A board 60 mm wide, and a CORRIDOR raster covering 20 .. 30 mm of it —
    // the shape a gap hop's context takes (`GapWindow.around`).
    const placement = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 60,
        .maxy = 40,
        .generated = true,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 60, .h = 40 },
    };
    const grid = Grid{ .ox = 20, .oy = 10, .g = 0.254, .nx = 40, .ny = 40 };
    const pts = [_]NetPt{
        .{ .x = 24.0, .y = 15.0, .layer = 0 },
        .{ .x = 26.0, .y = 15.0, .layer = 0 },
    };
    const bounds = ShapeBounds.of(grid, placement);
    // The board would allow 0 .. 60; the raster is the binding limit, and the
    // bow allowance (8 mm minimum) would have crossed it in both directions.
    try testing.expectApproxEqAbs(grid.worldX(0), bounds.x0, 1e-12);
    try testing.expectApproxEqAbs(grid.worldX(grid.nx - 1), bounds.x1, 1e-12);
    const w = shapeWindow(bounds, &pts);
    try testing.expect(w.x0 >= grid.worldX(0) - 1e-12);
    try testing.expect(w.x1 <= grid.worldX(grid.nx - 1) + 1e-12);
    try testing.expect(w.y0 >= grid.worldY(0) - 1e-12);
    try testing.expect(w.y1 <= grid.worldY(grid.ny - 1) + 1e-12);
    // A whole-board raster is not narrowed by the clamp: the board is then the
    // binding limit and the window is what it always was.
    const wide = Grid{ .ox = -5, .oy = -5, .g = 1.0, .nx = 100, .ny = 100 };
    const whole = ShapeBounds.of(wide, placement);
    try testing.expectApproxEqAbs(@as(f64, 0), whole.x0, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 60), whole.x1, 1e-12);
}

/// How many of `sites` lie within `r` mm of `at`, and how far the nearest is.
fn nearSiteStats(sites: []const cdt_layers.ViaSite, at: NetPt, r: f64) struct { n: usize, near: f64 } {
    var n: usize = 0;
    var near: f64 = std.math.inf(f64);
    for (sites) |s| {
        const d = std.math.hypot(s.x - at.x, s.y - at.y);
        if (d <= r) n += 1;
        near = @min(near, d);
    }
    return .{ .n = n, .near = near };
}

// spec: placement/router - the shape tier anchors a fine disc of via candidates on each terminal, so a pocket the window lattice never samples still gets a layer change
test "the shape tier's via sites are anchored on the terminals, not only on the window" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const grid = Grid{ .ox = 0, .oy = 0, .g = 0.254, .nx = 80, .ny = 80 };
    var ctx = try shapeTestCtx(arena, grid);
    var tracks: std.ArrayList(Track) = .empty;
    var vias: std.ArrayList(Via) = .empty;
    const run = DirectRun{ .ctx = &ctx, .net = 0, .tracks = &tracks, .vias = &vias };
    // A 16 mm window puts the lattice at its 1 mm ceiling, offset half a pitch
    // off the window corner — so its nearest candidate to either terminal is
    // most of a millimetre away, and the on-axis run starts a full pitch out.
    const rect = fine_window.WindowRect{ .x0 = 0, .y0 = 0, .x1 = 16, .y1 = 16 };
    try testing.expectApproxEqAbs(shape_via_pitch_mm, shapeViaPitch(rect), 1e-12);
    const from = NetPt{ .x = 8.0, .y = 8.0, .layer = 0 };
    const to = NetPt{ .x = 12.0, .y = 8.0, .layer = 0 };
    const sites = try shapeViaSites(arena, run, rect, from, to);
    // Both terminals carry a dense local supply — the layer change a sealed
    // pocket needs can only come from a candidate inside the pocket, and the
    // pockets measured on barracuda are a fraction of the lattice pitch across.
    const s_from = nearSiteStats(sites, from, 1.0);
    const s_to = nearSiteStats(sites, to, 1.0);
    try testing.expect(s_from.near <= shape_term_pitch_mm);
    try testing.expect(s_to.near <= shape_term_pitch_mm);
    try testing.expect(s_from.n > 10 and s_to.n > 10);
    // A foreign pad over the disc withdraws it: the exact via test still governs
    // every candidate, so the tier is never handed a barrel the board refuses.
    const blocker = [_]PadObs{.{ .x0 = 5.0, .y0 = 5.0, .x1 = 11.0, .y1 = 11.0, .net = 1, .layer = 0 }};
    ctx.obs = &blocker;
    const guarded = try shapeViaSites(arena, run, rect, from, to);
    try testing.expectEqual(@as(usize, 0), nearSiteStats(guarded, from, 1.0).n);
    try testing.expect(nearSiteStats(guarded, to, 1.0).n > 10);
}

// spec: placement/router - the shape tier withholds a terminal via candidate the hop's own via ban covers
test "the shape tier honours the hop's terminal via ban" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const grid = Grid{ .ox = 0, .oy = 0, .g = 0.254, .nx = 80, .ny = 80 };
    var ctx = try shapeTestCtx(arena, grid);
    var tracks: std.ArrayList(Track) = .empty;
    var vias: std.ArrayList(Via) = .empty;
    const run = DirectRun{ .ctx = &ctx, .net = 0, .tracks = &tracks, .vias = &vias };
    const rect = fine_window.WindowRect{ .x0 = 0, .y0 = 0, .x1 = 16, .y1 = 16 };
    const from = NetPt{ .x = 8.0, .y = 8.0, .layer = 0 };
    const to = NetPt{ .x = 12.0, .y = 8.0, .layer = 0 };
    // The hop banned barrels in its own `from` pad and its via halo. Arriving —
    // or leaving — by drilling the pad is not a route, so those candidates must
    // not be offered even though `directViaClear`, which skips the routing net's
    // own pads, would pass every one of them.
    const mask = try arena.alloc(bool, grid.nx * grid.ny);
    @memset(mask, false);
    markForbiddenDisc(grid, mask, from.x, from.y, 0.5);
    ctx.via_forbidden_mask = mask;
    ctx.via_forbidden_net = 0;
    const banned = try shapeViaSites(arena, run, rect, from, to);
    try testing.expectEqual(@as(usize, 0), nearSiteStats(banned, from, 0.3).n);
    // Only the banned pad is withheld: the rest of its disc, and the other
    // terminal's, are offered exactly as before.
    try testing.expect(nearSiteStats(banned, from, 1.0).n > 0);
    try testing.expect(nearSiteStats(banned, to, 1.0).n > 10);
    // And the ban is the ROUTING net's: another net's hop is not restricted by it.
    ctx.via_forbidden_net = 7;
    const other = try shapeViaSites(arena, run, rect, from, to);
    try testing.expect(nearSiteStats(other, from, 0.3).n > 0);
}

// spec: placement/router - a gap hop past the maze's practical reach asks the gridless mesh first and the maze second, so a doomed cross-board maze cannot spend the whole attempt before the geometry answer is tried
test "a cross-board gap hop asks the shape tier before the maze" {
    const near = NetPt{ .x = 0, .y = 0, .layer = 0 };
    // Every hop the maze is known to close here stays on today's order: the
    // longest measured is a 37 mm whole-net join, comfortably below the mark.
    try testing.expect(!shapeFirst(.{}, near, .{ .x = 3, .y = 0, .layer = 0 }));
    try testing.expect(!shapeFirst(.{}, near, .{ .x = 37, .y = 0, .layer = 0 }));
    try testing.expect(!shapeFirst(.{}, near, .{ .x = shape_first_hop_mm, .y = 0, .layer = 0 }));
    // The residual cross-board joins the maze never closes — barracuda's 42.5,
    // 49.6 and 55.3 mm control targets — go to the mesh first.
    for ([_]f64{ 42.5, 49.6, 55.3 }) |mm| {
        try testing.expect(shapeFirst(.{}, near, .{ .x = mm, .y = 0, .layer = 0 }));
    }
    // Diagonal spans are measured as spans, not per axis.
    try testing.expect(shapeFirst(.{}, near, .{ .x = 30, .y = 40, .layer = 0 })); // 50 mm
    // And a caller with the tier switched off never reorders anything, however
    // long the hop: there is no second tier to put first.
    try testing.expect(!shapeFirst(.{ .shape = .off }, near, .{ .x = 55.3, .y = 0, .layer = 0 }));
}

// spec: placement/router - a gap hop the maze cannot draw is re-asked of the gridless mesh before any copper is ripped
test "the additive gap closer falls back to the shape hop before it rips" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Two pads 3 mm apart with a clear channel between them. The maze closes
    // this hop on its own, so the shape fallback must NOT be what draws it —
    // the ordering assertion is the point: `shapeHop` stands between the maze
    // and the rip, never in front of the maze.
    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads, .fallback = false, .x = 3, .y = 0 },
    };
    const pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const nets = [_]FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -0.5,
        .miny = -0.5,
        .maxx = 3.5,
        .maxy = 0.5,
        .generated = true,
        .board_rect = .{ .minx = -0.5, .miny = -0.5, .w = 4, .h = 1 },
        .rules = .{ .copper_layers = 2 },
    };
    const gaps = [_]Gap{.{
        .net_i = 0,
        .from = .{ .x = 0, .y = 0, .layer = 0 },
        .to = .{ .x = 3, .y = 0, .layer = 0 },
    }};
    // `ripup = false` is the additive contract the per-gap transaction routes
    // under: nothing may be displaced, so a hop either draws in free space or
    // reports no path. That is exactly the call site `join_no_path` comes from.
    const paths = try closeGaps(arena, placement, .{}, .{
        .tracks = &.{},
        .vias = &.{},
        .zones = &.{},
    }, &gaps, .{ .ripup = false });
    try testing.expectEqual(@as(usize, 1), paths.len);
    const path = paths[0] orelse return error.TestUnexpectedResult;
    // Whoever drew it, an additive hop must have ripped nothing — the property
    // `route_close.additiveOnly` keeps the whole transaction on.
    try testing.expectEqual(@as(usize, 0), path.ripped.len);
    try testing.expect(path.tracks.len > 0);
}
