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
const net_name = @import("../net_name.zig");
const Part = optimizer.Part;
const FlatNet = flat_netlist.FlatNet;

const router_direct = @import("router_direct.zig");

// Direct (geometry-first) synthesis lives in `router_direct.zig`; the names
// below are its, aliased so this file's call sites keep their spelling.
pub const DirectRun = router_direct.DirectRun;
pub const DirectPath = router_direct.DirectPath;
const deadline_guided_probe_budget = router_direct.deadline_guided_probe_budget;
const direct_probe_budget = router_direct.direct_probe_budget;
const direct_span_mm = router_direct.direct_span_mm;
pub const clearDoglegSegment = router_direct.clearDoglegSegment;
const clearDoglegSegmentWidth = router_direct.clearDoglegSegmentWidth;
pub const directViaClear = router_direct.directViaClear;
pub const emitDoglegSegment = router_direct.emitDoglegSegment;
const finePointClear = router_direct.finePointClear;
const netLands = router_direct.netLands;
pub const restoreNetOcc = router_direct.restoreNetOcc;
pub const rollbackDirectRun = router_direct.rollbackDirectRun;
const sameTrackGeometry = router_direct.sameTrackGeometry;
pub const shrinkCopper = router_direct.shrinkCopper;
const tryDirectDogleg = router_direct.tryDirectDogleg;
const tryDirectPair = router_direct.tryDirectPair;
const tryDirectTerminalTree = router_direct.tryDirectTerminalTree;
const tryGuidedRoute = router_direct.tryGuidedRoute;
const tryGuidedTree = router_direct.tryGuidedTree;
const tryMazeGuidedTree = router_direct.tryMazeGuidedTree;
const trySharedGuidedTree = router_direct.trySharedGuidedTree;

const router_rescue = @import("router_rescue.zig");

// The rescue ladder (the shape tier and the windowed fine-grid retry) lives
// in `router_rescue.zig`; the names below are its, aliased so this file's
// call sites keep their spelling.
const FineRescueRun = router_rescue.FineRescueRun;
const ShapeAsk = router_rescue.ShapeAsk;
const ShapeBounds = router_rescue.ShapeBounds;
const rescue_max_terminals = router_rescue.rescue_max_terminals;
const shape_term_pitch_mm = router_rescue.shape_term_pitch_mm;
const shape_via_pitch_mm = router_rescue.shape_via_pitch_mm;
const fineWindowRescue = router_rescue.fineWindowRescue;
const immediateFineGuided = router_rescue.immediateFineGuided;
const immediateFineGuidedEligible = router_rescue.immediateFineGuidedEligible;
const rescueNetInWindow = router_rescue.rescueNetInWindow;
const rescueQuantizedFullBoard = router_rescue.rescueQuantizedFullBoard;
const residualIsGridQuantized = router_rescue.residualIsGridQuantized;
const shapeLayers = router_rescue.shapeLayers;
const shapeRescueTier = router_rescue.shapeRescueTier;
const shapeTierAffordable = router_rescue.shapeTierAffordable;
const shapeViaPitch = router_rescue.shapeViaPitch;
const shapeViaSites = router_rescue.shapeViaSites;
const shapeWidth = router_rescue.shapeWidth;
const shapeWindow = router_rescue.shapeWindow;
/// Build one shape-tier mesh request for `run`'s net (see `router_rescue`).
pub const shapeInput = router_rescue.shapeInput;
/// Route one declared diff-pair follower leg against its leader (see
/// `router_rescue`).
pub const routeFollowerLeg = router_rescue.routeFollowerLeg;

const router_maze = @import("router_maze.zig");

// The maze search (Dijkstra, the cost model, the pad gateways) lives in
// `router_maze.zig`; the names below are its, aliased so this file's call
// sites keep their spelling.
pub const MazeEnds = router_maze.MazeEnds;
const OctiJoin = router_maze.OctiJoin;
const Pq = router_maze.Pq;
const clearNetOcc = router_maze.clearNetOcc;
pub const clearSearchLimit = router_maze.clearSearchLimit;
const dijkstra = router_maze.dijkstra;
pub const escapeActive = router_maze.escapeActive;
const expansionBudget = router_maze.expansionBudget;
const gateStub = router_maze.gateStub;
const neighbor = router_maze.neighbor;
const padGateways = router_maze.padGateways;
const recordSearchLimit = router_maze.recordSearchLimit;
const routeHeuristic = router_maze.routeHeuristic;
const trimBuriedStart = router_maze.trimBuriedStart;
const weldToNetCopper = router_maze.weldToNetCopper;

const router_gap_close = @import("router_gap_close.zig");

// The gap-closing pass lives in `router_gap_close.zig`; the names below are
// its, aliased so this file's call sites keep their spelling.
const GapState = router_gap_close.GapState;
const gap_max_expansions = router_gap_close.gap_max_expansions;
pub const closeGaps = router_gap_close.closeGaps;
const buildGapCtx = router_gap_close.buildGapCtx;
const exactGapRescue = router_gap_close.exactGapRescue;
const gapLayers = router_gap_close.gapLayers;
const markTerminalViaBan = router_gap_close.markTerminalViaBan;
pub const ownPadBox = router_gap_close.ownPadBox;
const scaledGapCeiling = router_gap_close.scaledGapCeiling;
const stampGapBoard = router_gap_close.stampGapBoard;

const router_ctx = @import("router_ctx.zig");

// The routing context and its board model live in `router_ctx.zig`; every name
// below is that module's, aliased so the passes here keep their spelling.
const Ctx = router_ctx.Ctx;
pub const Grid = router_ctx.Grid;
const Rect = router_ctx.Rect;
const KeepState = router_ctx.KeepState;
const NetSmooth = router_ctx.NetSmooth;
const PadDrills = router_ctx.PadDrills;
const PadGrid = router_ctx.PadGrid;
const ShapeVerdict = router_ctx.ShapeVerdict;
pub const NetPt = router_ctx.NetPt;
pub const netPoints = router_ctx.netPoints;
pub const localSupplyBonds = router_ctx.localSupplyBonds;
pub const netHasPlane = router_ctx.netHasPlane;
pub const netPourLayers = router_ctx.netPourLayers;
const escTerm = router_ctx.escTerm;
const padInPour = router_ctx.padInPour;
/// Occupancy/reservation sentinel for a grid cell no net has claimed.
pub const empty_cell = router_ctx.empty_cell;
/// Geometry comparisons use the same one-nanometre tolerance as `drc.zig`,
/// so a route on an exact decimal clearance boundary is accepted consistently.
pub const clearance_eps = router_ctx.clearance_eps;
const sqrt2 = router_ctx.sqrt2;
const gate_rings = router_ctx.gate_rings;
const staging_offboard_mm = router_ctx.staging_offboard_mm;
const allocLayerGrids = router_ctx.allocLayerGrids;
const armStaticBlock = router_ctx.armStaticBlock;
pub const blocked = router_ctx.blocked;
pub const buildObstacles = router_ctx.buildObstacles;
pub const copperCompacted = router_ctx.copperCompacted;
const copperHalo = router_ctx.copperHalo;
const copperIdx = router_ctx.copperIdx;
const copperReach = router_ctx.copperReach;
const distPointRect = router_ctx.distPointRect;
const findEscapeVia = router_ctx.findEscapeVia;
const findGroundVia = router_ctx.findGroundVia;
const findStitchVia = router_ctx.findStitchVia;
const firstGroundNet = router_ctx.firstGroundNet;
const foreignPadAt = router_ctx.foreignPadAt;
const gridBounds = router_ctx.gridBounds;
const groundViaPointClear = router_ctx.groundViaPointClear;
const keepStamp = router_ctx.keepStamp;
const keepoutBlocked = router_ctx.keepoutBlocked;
pub const keepoutExtra = router_ctx.keepoutExtra;
pub const layerInMask = router_ctx.layerInMask;
const moveClearsCopper = router_ctx.moveClearsCopper;
const netClassRank = router_ctx.netClassRank;
pub const netEnabled = router_ctx.netEnabled;
pub const netLayerAuthored = router_ctx.netLayerAuthored;
pub const netPourCovers = router_ctx.netPourCovers;
const netPriority = router_ctx.netPriority;
const outlineBlocked = router_ctx.outlineBlocked;
const padCopperAt = router_ctx.padCopperAt;
const padIndexReach = router_ctx.padIndexReach;
const padSegmentClears = router_ctx.padSegmentClears;
const perimeterAllowed = router_ctx.perimeterAllowed;
const pointMissesBox = router_ctx.pointMissesBox;
const pourLiveNear = router_ctx.pourLiveNear;
const probeBudgetExhausted = router_ctx.probeBudgetExhausted;
pub const rebuildCopperIndex = router_ctx.rebuildCopperIndex;
const segClearsPadsOnLayer = router_ctx.segClearsPadsOnLayer;
const segClearsTracks = router_ctx.segClearsTracks;
const segClearsVias = router_ctx.segClearsVias;
pub const setNetParams = router_ctx.setNetParams;
const setNetReferenceGuide = router_ctx.setNetReferenceGuide;
pub const setNetRoutePolicy = router_ctx.setNetRoutePolicy;
const stampBoardCopper = router_ctx.stampBoardCopper;
const stampCurrentRf = router_ctx.stampCurrentRf;
const stampCurrentRfVia = router_ctx.stampCurrentRfVia;
const stampDisc = router_ctx.stampDisc;
const stampExistingCopper = router_ctx.stampExistingCopper;
const stampKeepoutPad = router_ctx.stampKeepoutPad;
const stampKeepoutPadsForNet = router_ctx.stampKeepoutPadsForNet;
const stampKeepoutSeg = router_ctx.stampKeepoutSeg;
const stampRetainedRf = router_ctx.stampRetainedRf;
const stampStubOcc = router_ctx.stampStubOcc;
const stampTrackResv = router_ctx.stampTrackResv;
const stampViaOcc = router_ctx.stampViaOcc;
const staticBlocked = router_ctx.staticBlocked;
const trimStub = router_ctx.trimStub;
const viaAllowed = router_ctx.viaAllowed;
const viaClearsHoles = router_ctx.viaClearsHoles;
const viaClearsOutline = router_ctx.viaClearsOutline;
const viaClearsPadDrills = router_ctx.viaClearsPadDrills;
const viaClearsPads = router_ctx.viaClearsPads;
const viaClearsTracks = router_ctx.viaClearsTracks;
const viaClearsVias = router_ctx.viaClearsVias;
const viaCopperRule = router_ctx.viaCopperRule;
const viaPairCenterNeed = router_ctx.viaPairCenterNeed;
const viaR = router_ctx.viaR;
const zoneArea = router_ctx.zoneArea;
pub const zoneBlocksPoint = router_ctx.zoneBlocksPoint;
const zoneBounds = router_ctx.zoneBounds;
const zoneClipped = router_ctx.zoneClipped;
const zonePoured = router_ctx.zonePoured;

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
const nodeCount = route_grid.nodeCount;
const fine_selection_max_nets = route_grid.fine_selection_max_nets;
const selectedCount = route_grid.selectedCount;
const maxRouteParams = route_grid.maxRouteParams;
const selectedDiffPairGap = route_grid.selectedDiffPairGap;
const GridDims = route_grid.GridDims;
const effectiveGridScale = route_grid.effectiveGridScale;
const routeGridDims = route_grid.routeGridDims;
const fittedGridScale = route_grid.fittedGridScale;
pub const route_grid_margin_mm = route_grid.apron_mm;
/// Escalated per-leg expansion budget for the post-greedy retry of a net (or
/// atomic diff pair) that ended the greedy pass search-limited. Far above the
/// whole-board `max_batch_expansions`, but applied to only the handful of
/// still-failed nets, so the full replay stays bounded (a few extra seconds).
pub const max_escalated_expansions: usize = 400_000;
/// The last-resort per-leg expansion budget: a single bounded retry, far above
/// `max_escalated_expansions`, for the few nets still search-limited after the
/// escalate↔rip-up interleave has run. Applied to only that residual set, so
/// the full replay stays well under its time ceiling (comfortably below the
/// ~3 M-expansion practical maze-search cap).
pub const max_last_resort_expansions: usize = 1_500_000;
/// Quarter-pitch scale shared by the selected-net reroute and the batch's
/// residual single-net pass. Keeping one spelling prevents the two fine-grid
/// entry points from silently drifting.
pub const fine_grid_scale: f64 = 0.25;
pub const via_cost_mult: f64 = 4.0; // a layer change costs ~4 grid steps
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

/// Step-cost multiplier for maze moves onto an outer layer a declared pour
/// covers: every signal trace there slices the pour into islands, so signals
/// prefer the un-poured face — but the layer stays usable when the other side
/// is walled off (the Gerber emission carves clearance around whatever lands
/// there, so the result is legal either way).
pub const pour_cost_mult: f64 = 1.5;
/// Step-cost multiplier for maze moves on an INNER signal layer (index ≥ 2,
/// from a `(stackup …)` with more than two plane-free copper layers). Kept
/// mild: an inner dive already pays two via costs, so this only breaks the
/// tie against equal-length inner paths — a trivially routable board keeps
/// all its copper on the outer faces (identical to the 2-layer result), while
/// a congested crossing still dives inner the moment the surface detour
/// exceeds ~25% of the path. No-op on ≤2-signal boards (no such layer exists).
pub const inner_cost_mult: f64 = 1.25;
/// Step-cost multiplier for a diff-pair N-net maze move landing in its P twin's
/// coupling corridor (`Ctx.corridor`): a discount so the pair runs parallel and
/// tight. Only ever applied when a corridor is active — null keeps 1.0, byte-identical.
pub const diff_corridor_mult: f64 = 0.5;
pub const diff_via_on_ring_mult: f64 = 0.005;
pub const diff_via_off_ring_mult: f64 = 8.0;
/// A completed reference corridor is a soft topology hint, not copper. Staying
/// on it is strongly preferred; a legal detour remains possible.
pub const reference_corridor_mult: f64 = 0.1;
pub const reference_via_mult: f64 = 0.1;
pub const reference_off_via_mult: f64 = 8.0;
/// Cost multiplier for trace steps outside the current route wave's preferred
/// layers. Large enough to justify a layer change on a useful run, but finite
/// so the router can escape a blocked preferred layer.
pub const preferred_layer_cost_mult: f64 = 3.0;
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
/// note this constant replaces recorded a 0.6-pitch price taking board-a from
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

/// Plane and finishing passes run outside routeNet's transactional via gate.
/// Consult the authored total against the copper currently present, so retained
/// barrels and earlier passes spend the same allowance.
fn canAddNetVia(ctx: *const Ctx, vias: []const Via, net: i32) bool {
    const ni = std.math.cast(usize, net) orelse return false;
    if (ni >= ctx.net_policy.len) return true;
    const limit = ctx.net_policy[ni].max_vias orelse return true;
    var count: usize = 0;
    for (vias) |via| {
        if (via.net == net) count += 1;
    }
    return count < limit;
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
            if (!canAddNetVia(ctx, vias.items, ni)) continue;
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
        if (!canAddNetVia(ctx, vias.items, ni)) continue;
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
    if (policy.max_vias) |limit| {
        var remaining: usize = limit;
        for (vias.items) |via| {
            if (via.net == net) remaining -|= 1;
        }
        for (ctx.guide_vias) |via| {
            if (via.net != net) continue;
            if (remaining == 0) return false;
            remaining -= 1;
        }
    }
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

pub fn hardGuidedPolicy(ctx: *const Ctx, net_i: usize) bool {
    if (net_i >= ctx.net_policy.len) return false;
    const policy = ctx.net_policy[net_i];
    return policy.waypoints.len > 0 or route_policy.hasBranchTree(policy);
}

pub fn pairCorridorRadius(ctx: *const Ctx, gap: f64) usize {
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

pub fn buildPairTerminalMask(
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

pub fn markForbiddenDisc(grid: Grid, mask: []bool, x: f64, y: f64, radius: f64) void {
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
pub const InlineSmooth = struct {
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
pub fn smoothNetInline(run: InlineSmooth, net_i: usize, keep: usize, routed: usize) std.mem.Allocator.Error!void {
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
pub const CtxResult = union(enum) { ok: Ctx, empty, overflow };

pub fn unguidedExpansionLimit(selected_nets: []const bool) usize {
    const count = selectedCount(selected_nets);
    return if (count > 0 and count <= fine_selection_max_nets)
        route_grid.max_targeted_expansions
    else
        route_grid.max_batch_expansions;
}

pub fn buildPairViaMask(
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

pub fn buildPerimeterTrackMask(
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

/// Build the routing grid + base `Ctx` that `route` and `groundVias` share
/// verbatim (they MUST stay in lockstep): grid pitch sized to the WIDEST net
/// class, obstacles = every pad (mirroring `drc.zig`); `.pour` filled by `route`.
pub fn buildRouteCtx(
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
    const grid_nodes = nodeCount(nx, ny);
    if (grid_nodes == 0) return .empty;
    if (grid_nodes > max_nodes) return .overflow;
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
    const nodes = nodeCount(grid.nx, grid.ny);
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
pub fn windowCtx(
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
pub fn anyDeclaredResolution(placement: optimizer.Placement) bool {
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
        return assembleRouteRun(run, &.{});
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
    // board-a board-d` (2026-08-04) rather than argued:
    //
    //   * `straighten` runs BEFORE the hop drop because the hop drop's detector
    //     reads copper: `HopScan` follows a bounded run of segments between two
    //     vias and `clearingElbow` judges the replacement against what leaves
    //     each end. On raw maze copper those runs are staircases, and two of
    //     board-d's redundant hops go unrecognised — +4 vias, +10 tracks — when
    //     the pass is handed un-tautened metal.
    //   * the hop drop runs BEFORE `stitchReturnPaths`, so the stitcher never
    //     spends a ground via guarding a signal via that is about to be deleted.
    //   * the merged single-layer runs the hop drop leaves are re-glossed HERE,
    //     not left to the cleanup phase's closing sweep, because stitching in
    //     between pins vias into the corridors those runs would tauten through
    //     (deferring it costs board-d +6 tracks). It is conditional because with
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
    // board-a: V_6VA's two surviving square corners on B.Cu are both
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
    // Capture fallback RF profiles while every pad-neck slice still exists.
    // The final gloss below is allowed to collapse those slices against pad
    // copper, which destroys the width stations needed to reconstruct a full
    // two-sided taper after the fact.
    const rf_trials_before_gloss = try rf_port_report.collectOrdered(arena, &run.ctx.rf.port_outcomes, run.placement.nets.len);
    const rf_fallbacks = try @import("rf_taper_paths.zig").exactFallbacks(arena, run.placement, run.tracks.items, rf_trials_before_gloss);
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
    try @import("rf_taper_paths.zig").compactFallbackHandles(arena, run.tracks, rf_fallbacks);
    var outcome_it = run.ctx.rf.port_outcomes.valueIterator();
    while (outcome_it.next()) |outcome| {
        for (run.tracks.items) |track| outcome.physical.retained_tracks += @intFromBool(track.net == outcome.net);
    }
    copperCompacted(run.ctx);
    if (timing) |t| t.end(.cleanup);
    return assembleRouteRun(run, rf_fallbacks);
}

/// Assemble the compact result shared by a normally cleaned board and a
/// cooperatively stopped partial board. RF bend discipline ran inline, so its
/// metadata remains valid even when a deadline skips the cosmetic finish tail.
fn assembleRouteRun(run: RouteFinish, rf_fallbacks: []const rf_port_report.Outcome) std.mem.Allocator.Error!RouteRun {
    const arena = run.ctx.arena;
    const timing = run.ctx.timing;
    var arcs: std.ArrayList(Arc) = .empty;
    var sharp: std.ArrayList(SharpBend) = .empty;
    for (0..run.placement.nets.len) |ni| {
        const s = run.ctx.rf.net_smooth.get(@intCast(ni)) orelse continue;
        try arcs.appendSlice(arena, s.arcs);
        try sharp.appendSlice(arena, s.sharp);
    }
    const rf_trials = try rf_port_report.collectOrdered(arena, &run.ctx.rf.port_outcomes, run.placement.nets.len);
    var rf_outcomes: std.ArrayList(rf_port_report.Outcome) = .empty;
    try rf_outcomes.appendSlice(arena, rf_trials);
    try rf_outcomes.appendSlice(arena, rf_fallbacks);
    try recordPostPass(.complete, run.progress, run.tracks.items, run.vias.items);
    if (timing) |t| t.end(.finish_total);

    return .{ .routed = .{
        .tracks = try run.tracks.toOwnedSlice(arena),
        .vias = try run.vias.toOwnedSlice(arena),
        .arcs = try arcs.toOwnedSlice(arena),
        .sharp_bends = try sharp.toOwnedSlice(arena),
        .rf_port_outcomes = try rf_outcomes.toOwnedSlice(arena),
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
        if (!canAddNetVia(ctx, vias.items, stub.net)) continue;
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
        if (!canAddNetVia(ctx, vias.items, ground_net)) break;
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
            if (!canAddNetVia(ctx, vias.items, ni)) break;
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

    /// Every allocation below lands in `arena` and NOTHING here is freed
    /// individually: both callers (`optimizer.routedLoops` /
    /// `routedSubsetWeighted`) hand over a scratch arena they reset per
    /// candidate, and the tests use one they `deinit`. That is why a failure
    /// after `allocLayerGrids` leaks nothing and carries no `errdefer` — an
    /// `arena.free` here would be a no-op standing in for a release the arena
    /// already performs wholesale.
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
        // Saturating: a design can place parts far enough apart that `nx * ny`
        // leaves `usize` outright, and the bail must refuse that rather than
        // trap on (or wrap past) the multiply. See `route_grid.nodeCount`.
        const nodes = nodeCount(nx, ny);
        if (nodes == 0 or nodes > max_nodes) return .{ .ctx = undefined, .ready = false };
        const grid = Grid{ .ox = ox, .oy = oy, .g = g, .nx = nx, .ny = ny };

        // The loop surrogate always measures on the two OUTER faces — it
        // scores a decoupling leg, not a full route, so inner layers would
        // only slow the placement loop without changing the ordering.
        const occ = try allocLayerGrids(arena, 2, nodes);
        const resv = try allocLayerGrids(arena, 2, nodes);

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

/// What a stranded pad's stitch via can actually REACH on this net — the
/// clip-aware replacement for the flat `poured` boolean.
pub const StitchTarget = enum {
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
pub fn stitchTarget(state: *GapState, pt: NetPt, net: i32, reach: f64) StitchTarget {
    const ctx = state.ctx;
    // No retained pour at all: the plane is the target and any legal site taps
    // it, exactly as this read before pours were weighed.
    if (largestNetZone(ctx, net) == null) return .plane;
    if (pourLiveNear(ctx, net, pt.x, pt.y, reach)) return .pour;
    const i: usize = @intCast(net);
    if (i < state.placement.nets.len and netHasPlane(state.placement, state.placement.nets[i].name)) return .plane;
    return .none;
}

pub fn largestNetZone(ctx: *const Ctx, net: i32) ?route_policy.ExistingZone {
    var best: ?route_policy.ExistingZone = null;
    var best_area: f64 = 0;
    for (ctx.zones) |zone| {
        if (!zone.copper or zone.net != net or zone.layer >= ctx.occ.len) continue;
        // A retained same-net pour is a TERMINAL even when the authored route
        // wave excludes its layer. Dijkstra may seed at any node in the pour
        // and immediately transition through a via onto an allowed layer;
        // `relaxStep` still rejects same-layer movement because the destination
        // layer is outside `allowed_layers`. Thus Board A's In2.Cu power
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
pub fn zoneAnchor(poly: []const [2]f64, pt: NetPt) ?[2]f64 {
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
pub fn nearestReusableZoneVia(
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

/// Route every pad to one retained local-pour polygon. The zone nodes are
/// virtual roots only for this net's Dijkstra wave: they never enter `occ`, so
/// a repourable boundary cannot become a wall for a later foreign net. A zone
/// on an excluded layer remains a legal terminal: the wave can via directly
/// out of it, but ordinary movement on that layer remains blocked by
/// `relaxStep`'s allowed-layer check.
pub fn routeNetToZone(
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
pub fn padMazeEnds(ctx: *Ctx, tracks: []const Track, vias: []const Via, pt: NetPt, net: i32) std.mem.Allocator.Error!MazeEnds {
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
    const saved_via_limit = ctx.max_vias;
    defer ctx.max_vias = saved_via_limit;
    if (saved_via_limit) |limit| {
        var present: u16 = 0;
        for (vias.items) |via| if (via.net == net) {
            present +|= 1;
        };
        ctx.max_vias = limit -| present;
    }
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
        routed = try retryDeferredWaypoints(ctx, net, ordered_pts, tracks, vias);
        if (!routed) {
            ctx.zone_partial = ctx.zone_partial or primary_zone_partial;
            ctx.tree_partial = ctx.tree_partial or primary_tree_partial;
            if (ctx.zone_partial or ctx.tree_partial) {
                if (ctx.max_vias) |limit| if (vias.items.len - via_mark > limit) {
                    rollbackDirectRun(run, track_mark, via_mark);
                    ctx.zone_partial = false;
                    ctx.tree_partial = false;
                };
                return false;
            }
            rollbackDirectRun(run, track_mark, via_mark);
            routed = try escapeDirectRescue(ctx, net, ordered_pts, tracks, vias);
        }
    }
    if (!routed) {
        rollbackDirectRun(run, track_mark, via_mark);
        return false;
    }
    if (ctx.max_vias) |limit| if (vias.items.len - via_mark > @as(usize, limit)) {
        rollbackDirectRun(run, track_mark, via_mark);
        if (!saved_allow_vias) return false;
        return try retryViaBudget(run, ordered_pts, track_mark, via_mark, limit);
    };
    return try detour_guard.detourGuard(run, ordered_pts, track_mark, via_mark);
}

/// Try the remaining nonzero via allowance before falling back to no new
/// layer changes. Copper and partial flags roll back together on every refusal.
fn retryViaBudget(
    run: DirectRun,
    pts: []const NetPt,
    track_mark: usize,
    via_mark: usize,
    limit: u16,
) std.mem.Allocator.Error!bool {
    const ctx = run.ctx;
    const saved_bias = ctx.via_cost.bias_mm;
    defer ctx.via_cost.bias_mm = saved_bias;
    const span = ctx.grid.g * @as(f64, @floatFromInt(ctx.grid.nx + ctx.grid.ny));
    for ([_]f64{ 1, 4, 0 }) |scale| {
        if (routeCancelled(ctx)) return false;
        ctx.allow_vias = limit > 0 and scale > 0;
        ctx.via_cost.bias_mm = @max(saved_bias, span * scale);
        const routed = try routeNetAttempt(ctx, run.net, pts, run.tracks, run.vias);
        if (routed and run.vias.items.len - via_mark <= limit) return true;
        rollbackDirectRun(run, track_mark, via_mark);
        ctx.zone_partial = false;
        ctx.tree_partial = false;
        if (limit == 0) break;
    }
    return false;
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
    const saved_waypoints = ctx.waypoints;
    const saved_branches = ctx.guide_branches;
    const saved_budget = ctx.direct_budget;
    defer {
        ctx.preferred_layers = saved_preferred;
        ctx.waypoints = saved_waypoints;
        ctx.guide_branches = saved_branches;
        ctx.direct_budget = saved_budget;
    }
    ctx.preferred_layers = 0;
    ctx.waypoints = repair;
    ctx.guide_branches = &.{};
    if (ctx.deadline_ns != 0) ctx.direct_budget = deferred_repair_probe_budget;
    ctx.zone_partial = false;
    ctx.tree_partial = false;
    return routeNetAttempt(ctx, net, pts, tracks, vias);
}

/// A deferred repair corridor is a bounded authored attempt, not permission
/// to monopolize the deadline: scaling this per waypoint (8,192/point capped
/// at 65,536) produced byte-identical copper and cost ~6 s on Board A, so
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
    // Virtual guide terminals cannot authorize copper on a forbidden layer.
    // Direct guide segments otherwise bypass the maze's allowed-layer filter.
    if (!route_policy.guideLayersAllowed(ctx.allowed_layers, ctx.waypoints)) return false;
    for (ctx.guide_branches) |branch| if (!route_policy.guideLayersAllowed(ctx.allowed_layers, branch.waypoints)) return false;
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
        // A cross-face RF hop can keep the same straight escape, with its
        // single via ON that line. Probe this before the escape-shaped maze;
        // the general via lattice may accept a needless off-axis detour.
        const straight_via = pts.len == 2 and (!unshaped or netSpan(pts) <= direct_span_mm);
        if (straight_via and (try router_direct.tryStraightOneVia(direct, pts[0], pts[1]))) return true;
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

pub const RipScore = struct {
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
    return now.trace < before.trace - clearance_eps;
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
pub fn softProbe(ctx: *Ctx, net: i32, src: NetPt, goal: NetPt, crossed: *std.AutoHashMapUnmanaged(i32, void), scratch: std.mem.Allocator) std.mem.Allocator.Error!void {
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
            // buses (board-a's SPI_SCK/MOSI, the V_3V3A tree) forever
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
pub const shortName = net_name.leaf;

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: placement/router - maze-routes a two-pad net into connected track segments
// spec: placement/router - retained same-net vias spend a whole-board route budget while foreign vias do not
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

    // A retained via is part of the authored total. The two-transition guide
    // cannot add two more to an existing one under a cap of two.
    var retained_placement = placement;
    retained_placement.maxy = 3;
    const total_two = [_]route_policy.NetPolicy{.{ .waypoints = &guide_points, .max_vias = 2 }};
    var retained_via = [_]route_policy.ExistingVia{.{ .x = 1.5, .y = 2, .dia = 0.4, .drill = 0.2, .net = 0 }};
    const budget_pts = [_]NetPt{ .{ .x = 0, .y = 0, .layer = 0 }, .{ .x = 3, .y = 0, .layer = 0 } };
    for ([_]i32{ 0, 7 }) |retained_net| {
        retained_via[0].net = retained_net;
        const core = try testRouteCore(try routeCoreStart(arena, retained_placement, .{}, .{
            .net = &total_two,
            .existing_vias = &retained_via,
            .selected_nets = &.{false},
        }, .off));
        setNetParams(core.ctx, retained_placement, 0);
        setNetRoutePolicy(core.ctx, 0, &budget_pts);
        const connected = try routeNet(core.ctx, 0, &budget_pts, core.tracks, core.vias);
        try testing.expect(retainedViasEchoed(core.vias.items, &retained_via, retained_net));
        if (retained_net == 0) {
            try testing.expect(core.vias.items.len <= 2);
        } else {
            try testing.expect(connected);
            try testing.expectEqual(@as(usize, 3), core.vias.items.len);
        }
    }

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
        .allowed_layers = 3,
        .max_vias = 2,
    }};

    const core = try testRouteCore(try routeCoreStart(arena, placement, .{}, .{
        .net = &policies,
        .selected_nets = &.{false},
        .existing_zones = &top_wall,
        .stop = .{ .max_route_ms = 60_000 },
    }, .off));
    const pts = [_]NetPt{ .{ .x = 0, .y = 0, .layer = 0 }, .{ .x = 3, .y = 0, .layer = 0 } };
    setNetParams(core.ctx, placement, 0);
    setNetRoutePolicy(core.ctx, 0, &pts);
    var tracks: std.ArrayList(Track) = .empty;
    var vias: std.ArrayList(Via) = .empty;
    try testing.expect(try retryDeferredWaypoints(core.ctx, 0, &pts, &tracks, &vias));
    try testing.expectEqual(@as(usize, 2), vias.items.len);
    try testing.expect(trackLenOnLayer(tracks.items, 1) > 1.0);
    try testing.expectEqual(@as(u64, 3), core.ctx.allowed_layers);
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
        .allowed_layers = 3,
        .max_vias = 4,
    }};

    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = walledClockParts(&pads);
    const placement = walledClockBoard(&parts);
    const core = try testRouteCore(try routeCoreStart(arena, placement, .{}, .{
        .net = &policies,
        .selected_nets = &.{false},
        .existing_zones = &walled_clock_zones,
    }, .off));
    const pts = [_]NetPt{
        .{ .x = -3, .y = 0, .layer = 0 },
        .{ .x = 0, .y = 0, .layer = 0 },
        .{ .x = 3, .y = 0, .layer = 0 },
    };
    setNetParams(core.ctx, placement, 0);
    setNetRoutePolicy(core.ctx, 0, &pts);
    var tracks: std.ArrayList(Track) = .empty;
    var vias: std.ArrayList(Via) = .empty;
    try testing.expect(try routeNet(core.ctx, 0, &pts, &tracks, &vias));
    // One dive per drop: the tree is two independent limbs, not one trunk.
    try testing.expectEqual(@as(usize, 4), vias.items.len);
    try testing.expect(trackLenOnLayer(tracks.items, 1) > 2.0);
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

// spec: placement/router - plane and finishing vias share the authored total with retained copper
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

    const limited = try routeWithOptions(arena, placement, .{}, .{
        .net = &.{.{ .max_vias = 1 }},
    });
    try testing.expect(limited.vias.len <= 1);
    const forbidden = try routeWithOptions(arena, placement, .{}, .{
        .net = &.{.{ .max_vias = 0 }},
    });
    try testing.expectEqual(@as(usize, 0), forbidden.vias.len);

    // Thermal arrays reuse occupied sites and spend only the remaining total.
    var ctx = try testRouteCtx(arena, placement, .{});
    ctx.net_policy = &.{.{ .max_vias = 2 }};
    const array = ThermalArray{
        .pad = .{ .x0 = -0.45, .y0 = -0.45, .x1 = 0.45, .y1 = 0.45 },
        .centre = .{ 0, 0 },
        .cols = 2,
        .rows = 2,
        .pitch_x = 0.6,
        .pitch_y = 0.6,
    };
    // A roomy standalone land allows all four sites without the via cap.
    ctx.params.via_dia = 0.2;
    ctx.params.via_drill = 0.1;
    var array_vias: std.ArrayList(Via) = .empty;
    const covered = try placeThermalViaArray(&ctx, &array_vias, &.{}, 0, array);
    try testing.expectEqual(@as(usize, 2), covered);
    try testing.expectEqual(@as(usize, 2), try placeThermalViaArray(&ctx, &array_vias, &.{}, 0, array));
    try testing.expectEqual(@as(usize, 2), array_vias.items.len);
    ctx.net_policy = &.{};
    try testing.expectEqual(@as(usize, 4), try placeThermalViaArray(&ctx, &array_vias, &.{}, 0, array));

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
    const capped_replay = try routeWithOptions(arena, placement, .{}, .{
        .net = &.{ .{ .replay_reference_copper = true, .max_vias = 0 }, .{} },
        .selected_nets = &selected,
        .existing_tracks = &retained,
        .guides = .{ .vias = &guide_vias },
    });
    try testing.expectEqual(@as(usize, 0), capped_replay.vias.len);
    try testing.expectEqual(@as(usize, 0), capped_replay.reference_replayed.len);
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
    // scoped board-a re-route once returned a different board than
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
    // The Board A policy: route traces only on F.Cu/B.Cu. In2.Cu is not in
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
    // measured the other way round (`board-a-lt3045-ldo`: 18.47 mm of trace to
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
    // board-a shape that used to degenerate a scoped route to zero copper.
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

// spec: placement/router - a lattice whose node count overflows a usize is refused by the node-budget bail instead of trapping on the multiply
test "LoopRouter.init refuses a span whose node count overflows usize" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // The axis counts are `ceil(span / pitch) + 1` over a span the DESIGN
    // supplies, so two parts this far apart give each axis ~1e11/pitch nodes
    // and `nx * ny` leaves `usize`. Before `route_grid.nodeCount` saturated it,
    // the bare multiply panicked with `integer overflow` in a safe build (and
    // wrapped to a small count in an optimized one, sailing past the
    // `> max_nodes` bail and then sizing the grid allocation from the wrapped
    // value while `Grid.nx`/`Grid.ny` stayed astronomical). The router must
    // refuse this the way it refuses any other unaffordable board: not ready.
    const G = @import("geometry.zig");
    const pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const sig = [_]flat_netlist.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    var parts = [_]Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 1e11, .y = 1e11 },
    };
    const nets = [_]FlatNet{.{ .name = "SIG", .pins = &sig }};
    var idx = std.StringHashMapUnmanaged(usize).empty;
    try idx.put(arena, "R1", 0);
    try idx.put(arena, "R2", 1);

    const lr = try LoopRouter.init(arena, &parts, &nets, &idx, .{});
    try testing.expect(!lr.ready);

    // The saturating count is what makes that bail reachable: the product of
    // two axis counts this size must land at the ceiling, never wrap.
    try testing.expectEqual(
        @as(usize, std.math.maxInt(usize)),
        route_grid.nodeCount(std.math.maxInt(usize) / 2, 4),
    );
    try testing.expectEqual(@as(usize, 12), route_grid.nodeCount(3, 4));
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
        if (@abs(t.x2 - t.x1) > clearance_eps and @abs(t.y2 - t.y1) > clearance_eps) saw_diag = true;
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
    const capped = try routeWithOptions(arena, placement, .{}, .{
        .net = &.{ .{}, .{ .max_vias = 0 } },
    });
    try testing.expectEqual(@as(usize, 1), capped.vias.len);
    try testing.expectEqual(@as(i32, 0), capped.vias[0].net);
    try testing.expectEqual(@as(usize, 1), returnPathViolations(placement, capped, return_path_radius_mm));
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
    const capped = try routeWithOptions(arena, placement, placement.rules.design.routeParams(), .{
        .net = &.{.{ .max_vias = 0 }},
    });
    try testing.expectEqual(@as(usize, 0), capped.vias.len);
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

// spec: placement/router - a deferred repair corridor cannot escape authored layer and via limits
test "a deferred repair corridor cannot escape authored layer and via limits" {
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
    try testing.expectEqual(@as(usize, 0), routed.routed);
    try testing.expectEqual(@as(usize, 0), routed.vias.len);
    try testing.expectEqual(@as(f64, 0), trackLenOnLayer(routed.tracks, 1));

    // Force the ordinary guide into the wall. The repair can cross on B.Cu,
    // but its two transitions exceed the one-via cap and must roll back.
    const budgeted = [_]route_policy.NetPolicy{.{
        .wave = .{ .repair_waypoints = &repair },
        .waypoints = &.{.{ .x = 1.5, .y = 0, .layer = 0 }},
        .allowed_layers = 3,
        .max_vias = 1,
    }};
    const core = try testRouteCore(try routeCoreStart(arena, placement, .{}, .{
        .net = &budgeted,
        .selected_nets = &.{false},
        .existing_zones = &top_wall,
    }, .off));
    const pts = [_]NetPt{ .{ .x = 0, .y = 0, .layer = 0 }, .{ .x = 3, .y = 0, .layer = 0 } };
    setNetParams(core.ctx, placement, 0);
    setNetRoutePolicy(core.ctx, 0, &pts);
    var tracks: std.ArrayList(Track) = .empty;
    var vias: std.ArrayList(Via) = .empty;
    _ = try routeNet(core.ctx, 0, &pts, &tracks, &vias);
    try testing.expect(vias.items.len <= budgeted[0].max_vias.?);
}

// spec: placement/router - an incomplete subtree exceeding the remaining via allowance is rolled back rather than retained
test "via budget rolls back an over-budget partial tree" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();
    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = walledClockParts(&pads);
    const placement = walledClockBoard(&parts);
    var sealed_east = walled_clock_zones[1];
    sealed_east.layer = 1;
    const walls = [_]route_policy.ExistingZone{ walled_clock_zones[0], walled_clock_zones[1], sealed_east };
    const pts = [_]NetPt{ .{ .x = -3, .y = 0, .layer = 0 }, .{ .x = 0, .y = 0, .layer = 0 }, .{ .x = 3, .y = 0, .layer = 0 } };
    for ([_]u16{ 3, 1 }) |limit| {
        const policies = [_]route_policy.NetPolicy{.{ .allowed_layers = 3, .max_vias = limit }};
        const core = try testRouteCore(try routeCoreStart(arena, placement, .{}, .{
            .net = &policies,
            .selected_nets = &.{false},
            .existing_zones = &walls,
        }, .off));
        setNetParams(core.ctx, placement, 0);
        setNetRoutePolicy(core.ctx, 0, &pts);
        var tracks: std.ArrayList(Track) = .empty;
        var vias: std.ArrayList(Via) = .empty;
        try testing.expect(!try routeNet(core.ctx, 0, &pts, &tracks, &vias));
        if (limit == 3) {
            try testing.expect(core.ctx.tree_partial);
            try testing.expectEqual(@as(usize, 2), vias.items.len);
        } else {
            try testing.expect(!core.ctx.tree_partial);
            try testing.expectEqual(@as(usize, 0), vias.items.len);
            try testing.expectEqual(@as(usize, 0), tracks.items.len);
        }
    }
}
