//! The rescue ladder — the last two tiers a still-failed net is offered after
//! the greedy pass, budget escalation and rip-up have all been spent.
//!
//! Both tiers change the SEARCH, not the board: they re-ask a failed net's
//! question in a representation the whole-board raster cannot express, and
//! either come back with copper that passes the same gate as any other leg, or
//! leave the board exactly as they found it.
//!
//!   * the SHAPE tier — a layered constrained-Delaunay channel graph over the
//!     net's own window (`cdt_layers`), meshed with a via-site lattice, for a
//!     two-terminal net the maze walled in. `ShapeVerdict` records why it
//!     declined, so a tier that ran and found nothing is never mistaken for
//!     one that never ran.
//!   * the WINDOWED FINE-GRID tier — the same maze at half then quarter the
//!     board pitch over a small window around the net's terminals
//!     (`fine_window` plans where and how fine), where an off-grid escape from
//!     an interior fine-pitch pad becomes representable at all. It includes
//!     the residual-flood classifier that decides whether a failure is grid
//!     quantization worth re-rastering or a genuine wall.
//!
//! Split out of `router.zig` verbatim (2026-09-05).

const std = @import("std");
const optimizer = @import("optimizer.zig");
const cdt_layers = @import("cdt_layers.zig");
const diff_pairs = @import("diff_pairs.zig");
const diff_couple = @import("diff_couple.zig");
const route_policy = @import("route_policy.zig");
const fine_window = @import("fine_window.zig");
const fine_accept = @import("fine_accept.zig");
const gap_policy = @import("gap_policy.zig");
const keepout = @import("keepout.zig");
const lane_reserve = @import("lane_reserve.zig");
const outline_mod = @import("outline.zig");
const pad_grid = @import("pad_grid.zig");
const route_grid = @import("route_grid.zig");
const route_result = @import("route_result.zig");
const router_support = @import("router_support.zig");
const via_rules = @import("router_via_rules.zig");
const clock = @import("../infra/clock.zig");
const net_name = @import("../net_name.zig");
const router = @import("router.zig");
const router_ctx = @import("router_ctx.zig");
const router_direct = @import("router_direct.zig");
const router_maze = @import("router_maze.zig");
const router_gap_close = @import("router_gap_close.zig");

const shapeLog = std.log.info;
const shortName = net_name.leaf;
const isGroundName = optimizer.isGroundName;
const maxRouteParams = route_grid.maxRouteParams;
const RouteParams = router_support.RouteParams;
const PadObs = pad_grid.PadObs;
const Track = route_result.Track;
const Via = route_result.Via;

// The routing context and its board model (see `router_ctx.zig`).
const Ctx = router_ctx.Ctx;
const Grid = router_ctx.Grid;
const NetPt = router_ctx.NetPt;
const clearance_eps = router_ctx.clearance_eps;
const empty_cell = router_ctx.empty_cell;
const allocLayerGrids = router_ctx.allocLayerGrids;
const blocked = router_ctx.blocked;
const keepoutExtra = router_ctx.keepoutExtra;
const layerInMask = router_ctx.layerInMask;
const netHasPlane = router_ctx.netHasPlane;
const netPoints = router_ctx.netPoints;
const netPourLayers = router_ctx.netPourLayers;
const segClearsPadsOnLayer = router_ctx.segClearsPadsOnLayer;
const segClearsTracks = router_ctx.segClearsTracks;
const segClearsVias = router_ctx.segClearsVias;
const setNetParams = router_ctx.setNetParams;
const setNetReferenceGuide = router_ctx.setNetReferenceGuide;
const setNetRoutePolicy = router_ctx.setNetRoutePolicy;
const stampBoardCopper = router_ctx.stampBoardCopper;
const stampViaOcc = router_ctx.stampViaOcc;
const viaClearsHoles = router_ctx.viaClearsHoles;
const viaClearsPads = router_ctx.viaClearsPads;
const viaClearsTracks = router_ctx.viaClearsTracks;
const viaClearsVias = router_ctx.viaClearsVias;

// The maze search these tiers re-ask their question through.
const clearNetOcc = router_maze.clearNetOcc;
const clearSearchLimit = router_maze.clearSearchLimit;
const neighbor = router_maze.neighbor;

// The gap pass's layer mask, shared with the shape tier.
const GapOptions = gap_policy.GapOptions;
const gapLayers = router_gap_close.gapLayers;

// The passes and geometry still owned by `router.zig`.
const DirectPath = router_direct.DirectPath;
const DirectRun = router_direct.DirectRun;
const EscalateRun = router.EscalateRun;
const RipNet = router.RipNet;
const buildPairTerminalMask = router.buildPairTerminalMask;
const buildPairViaMask = router.buildPairViaMask;
const buildRouteCtx = router.buildRouteCtx;
const clearDoglegSegment = router_direct.clearDoglegSegment;
const directSegmentInside = router_direct.directSegmentInside;
const directViaClear = router_direct.directViaClear;
const direct_probe_budget = router_direct.direct_probe_budget;
const emitDoglegSegment = router_direct.emitDoglegSegment;
const fine_grid_scale = router.fine_grid_scale;
const hardGuidedPolicy = router.hardGuidedPolicy;
const immediate_fine_probe_budget = router_direct.immediate_fine_probe_budget;
const inner_cost_mult = router.inner_cost_mult;
const liveCurves = router.liveCurves;
const markForbiddenDisc = router.markForbiddenDisc;
const pairCorridorRadius = router.pairCorridorRadius;
const pour_cost_mult = router.pour_cost_mult;
const preferred_layer_cost_mult = router.preferred_layer_cost_mult;
const restoreNetOcc = router_direct.restoreNetOcc;
const ripNet = router.ripNet;
const rollbackDirectRun = router_direct.rollbackDirectRun;
const route = router.route;
const routeCancelled = router.routeCancelled;
const largestNetZone = router.largestNetZone;
const nearestReusableZoneVia = router.nearestReusableZoneVia;
const zoneAnchor = router.zoneAnchor;
const routeNet = router.routeNet;
const routeNetToZone = router.routeNetToZone;
const route_grid_margin_mm = router.route_grid_margin_mm;
const shrinkCopper = router_direct.shrinkCopper;
const smoothNetInline = router.smoothNetInline;
const tryDirectDogleg = router_direct.tryDirectDogleg;
const via_cost_mult = router.via_cost_mult;
const windowCtx = router.windowCtx;

// ── Shape tier: the multi-layer CDT last resort ───────────────────────────────

/// Via-site lattice pitch (mm) the shape tier offers the channel graph.
///
/// Every site becomes a mesh vertex on every allowed layer, so the pitch trades
/// where a dive may land against how large the graph grows. 1.0 mm puts ~1750
/// candidates over a 70 x 25 mm board, of which the via-legality probe keeps
/// only the ones a barrel actually fits — finer than the scale at which a layer
/// change is a useful move, and far cheaper than meshing the maze's own
/// 0.254 mm lattice.
pub const shape_via_pitch_mm: f64 = 1.0;
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
pub const shape_term_pitch_mm: f64 = 0.2;
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
pub const shape_first_hop_mm: f64 = 40.0;

/// Is this hop long enough that the shape tier is asked BEFORE the maze? Both
/// tiers still run either way (see `closeOneGap`); only their order moves.
pub fn shapeFirst(opts: GapOptions, from: NetPt, to: NetPt) bool {
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
pub fn shapeTierAffordable(ctx: *const Ctx, nets_left: usize) bool {
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
pub fn shapeWindow(bounds: ShapeBounds, pts: []const NetPt) fine_window.WindowRect {
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
pub const ShapeBounds = struct {
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
pub fn shapeWidth(ask: ShapeAsk, track_width: f64) f64 {
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
pub fn shapeLayers(a: std.mem.Allocator, ctx: *const Ctx, net: i32) std.mem.Allocator.Error![]const cdt_layers.Layer {
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
pub fn shapeViaPitch(rect: fine_window.WindowRect) f64 {
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
pub fn shapeViaSites(
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
pub fn emitShapeRoute(run: DirectRun, found: cdt_layers.Route, stamp: bool) std.mem.Allocator.Error!bool {
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
pub const ShapeRefusal = enum { lane, inside, pads, vias, tracks, via_site, none };

/// Re-ask the refused route's own probes, one family at a time. Only ever run on
/// the refusal path — a landed route costs nothing for it.
pub fn shapeRefusal(run: DirectRun, found: cdt_layers.Route) ShapeRefusal {
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
pub fn shapeRescueTier(run: EscalateRun) std.mem.Allocator.Error!usize {
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
pub const FineRescueRun = struct {
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

pub fn fineRescueEligible(run: FineRescueRun, net_i: usize) bool {
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
pub fn fineWindowRescue(run: FineRescueRun) std.mem.Allocator.Error![]const usize {
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
pub fn residualIsGridQuantized(
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
pub const rescue_max_terminals: usize = 12;

pub fn immediateFineGuidedEligible(ctx: *const Ctx, net_i: usize, terminal_count: usize) bool {
    return ctx.deadline_ns == 0 and terminal_count >= 2 and terminal_count <= rescue_max_terminals and
        hardGuidedPolicy(ctx, net_i);
}

pub const ImmediateFineGuidedRun = struct {
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
pub fn immediateFineGuided(
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

pub fn rescueNetInWindow(run: FineRescueRun, net_i: usize) std.mem.Allocator.Error!bool {
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
pub fn rescueQuantizedFullBoard(run: FineRescueRun, net_i: usize) std.mem.Allocator.Error!bool {
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
pub fn routeWindowNet(
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

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
const geometry = @import("geometry.zig");

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
