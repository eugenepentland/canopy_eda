//! Gap closing — the finishing pass that joins a partly-routed board's islands.
//!
//! `router.zig` routes nets; this file services one `closeGaps` request over
//! the copper that pass left behind. The caller-facing contract (the request /
//! response types and the rip-up ladder policy) lives in `gap_policy.zig` and
//! is re-exported from `router.zig`, so `router.Gap` and friends stay the
//! spelling every caller uses. What lives here is the machinery that answers
//! one:
//!
//!   * `GapState` — the per-pass state: a refined raster over the gap's own
//!     window, the live copper board, the via-ban mask, and the ladder's
//!     bookkeeping.
//!   * the hop ladder — `shapeHop`, `mazeHop`, `stitchHop`, `exactGapRescue`
//!     and `ripupHop`, tried in the order `gap_policy` prescribes.
//!   * the stitch searches — where a stranded terminal may drop a barrel into
//!     a plane, a surviving pour, or a bridge trace.
//!   * the bounded rip-and-repair transaction: nominate blockers, rip them,
//!     re-route, and roll the whole thing back if the board did not improve.
//!
//! Split out of `router.zig` verbatim (2026-09-05): it was one self-contained
//! pass reachable through a single entry point.

const std = @import("std");
const optimizer = @import("optimizer.zig");
const gap_policy = @import("gap_policy.zig");
const cdt_layers = @import("cdt_layers.zig");
const pad_exit = @import("pad_exit.zig");
const plane_via = @import("plane_via.zig");
const lane_reserve = @import("lane_reserve.zig");
const straighten = @import("straighten.zig");
const pad_shape = @import("pad_shape.zig");
const route_grid = @import("route_grid.zig");
const route_result = @import("route_result.zig");
const router_support = @import("router_support.zig");
const via_rules = @import("router_via_rules.zig");
const numeric = @import("../numeric.zig");
const flat_netlist = @import("../flat_netlist.zig");
const router = @import("router.zig");
const router_ctx = @import("router_ctx.zig");
const router_maze = @import("router_maze.zig");

const shapeLog = std.log.info;
const segPointDist = pad_shape.segPointDist;
const maxRouteParams = route_grid.maxRouteParams;
const Part = optimizer.Part;
const FlatNet = flat_netlist.FlatNet;
const RouteParams = router_support.RouteParams;
const Track = route_result.Track;
const Via = route_result.Via;

// The routing context and its board model (see `router_ctx.zig`).
const Ctx = router_ctx.Ctx;
const Grid = router_ctx.Grid;
const Rect = router_ctx.Rect;
const NetPt = router_ctx.NetPt;
const clearance_eps = router_ctx.clearance_eps;
const empty_cell = router_ctx.empty_cell;
const gate_rings = router_ctx.gate_rings;
const allocLayerGrids = router_ctx.allocLayerGrids;
const armStaticBlock = router_ctx.armStaticBlock;
const blocked = router_ctx.blocked;
const distPointRect = router_ctx.distPointRect;
const groundViaPointClear = router_ctx.groundViaPointClear;
const netPourCovers = router_ctx.netPourCovers;
const pourLiveNear = router_ctx.pourLiveNear;
const zonePoured = router_ctx.zonePoured;
const padCopperAt = router_ctx.padCopperAt;
const segClearsPadsOnLayer = router_ctx.segClearsPadsOnLayer;
const segClearsTracks = router_ctx.segClearsTracks;
const segClearsVias = router_ctx.segClearsVias;
const setNetParams = router_ctx.setNetParams;
const stampBoardCopper = router_ctx.stampBoardCopper;
const viaAllowed = router_ctx.viaAllowed;
const viaR = router_ctx.viaR;

// The passes and searches this one calls back into (see `router.zig`).
const CtxResult = router.CtxResult;
const FineRescueRun = router.FineRescueRun;
const DirectRun = router.DirectRun;
const Gap = gap_policy.Gap;
const GapBoard = gap_policy.GapBoard;
const GapPath = gap_policy.GapPath;
const GapReason = gap_policy.GapReason;
const GapOptions = gap_policy.GapOptions;
const GapWindow = gap_policy.GapWindow;
const TerminalVia = gap_policy.TerminalVia;
const gap_grid_divisor = gap_policy.gap_grid_divisor;
const buildPerimeterTrackMask = router.buildPerimeterTrackMask;
const buildRouteCtx = router.buildRouteCtx;
const clearSearchLimit = router_maze.clearSearchLimit;
const dijkstra = router_maze.dijkstra;
const emitShapeRoute = router.emitShapeRoute;
const gateStub = router_maze.gateStub;
const markForbiddenDisc = router.markForbiddenDisc;
const padGateways = router_maze.padGateways;
const rollbackDirectRun = router.rollbackDirectRun;
const route = router.route;
const routeCancelled = router.routeCancelled;
const searchWasLimited = router.searchWasLimited;
const anyDeclaredResolution = router.anyDeclaredResolution;
const shapeFirst = router.shapeFirst;
const shape_first_hop_mm = router.shape_first_hop_mm;
const shapeInput = router.shapeInput;
const shapeRefusal = router.shapeRefusal;
const softProbe = router.softProbe;
const StitchTarget = router.StitchTarget;
const fineRescueEligible = router.fineRescueEligible;
const stitchTarget = router.stitchTarget;
const tryDirectPair = router.tryDirectPair;
const tryTwoViaSeededMaze = router.tryTwoViaSeededMaze;
const windowCtx = router.windowCtx;

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
pub const GapState = struct {
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
pub fn gapLayers(ctx: *const Ctx, net: i32) u64 {
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
pub fn stampGapBoard(ctx: *Ctx, live: GapBoard, net: i32) void {
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
pub fn exactGapRescue(
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
    if (@abs(at[0] - c[0]) > clearance_eps or @abs(at[1] - c[1]) > clearance_eps) {
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
pub fn buildGapCtx(
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
pub const gap_max_expansions: usize = 120_000;

/// A gap ceiling (`gap_max_nodes` / `gap_max_expansions`) scaled to a caller's
/// grid divisor: node count grows with the divisor squared, so the budgets do
/// too. At the default divisor this is the identity, and because both sides of
/// `refineGapGrid`'s fit check scale by the same factor, a board whose
/// divisor-2 raster fits its budget fits every finer raster's scaled budget.
pub fn scaledGapCeiling(base: usize, divisor: f64) usize {
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
pub fn markTerminalViaBan(state: *GapState, gap: Gap, net: i32) void {
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
pub fn ownPadBox(ctx: *Ctx, pt: NetPt, net: i32) ?Rect {
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

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
const geometry = @import("geometry.zig");
const route_policy = @import("route_policy.zig");
const keepout = @import("keepout.zig");

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
