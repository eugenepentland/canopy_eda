//! Post-route connectivity reconciliation — the ORACLE GATE every fresh route
//! passes through before its numbers reach a caller.
//!
//! A batch route counts a net routed when its own maze reached each terminal.
//! That is not the same question as "does the copper on the board join this
//! net's pads", and on a dense board the two answers diverge badly: board-a's
//! whole-board route claimed 85/90 while `fab_readiness.routableTally` — the
//! one connectivity oracle every reporting surface shares — found 77/90. The
//! difference was never hard routing. It was short joins the router never
//! emitted while counting the net complete: a 0.98 mm divider tie between two
//! adjacent resistor pads, a 1.34 mm hop from a diode to its inductor, and a
//! `GND` net shipped as 34 separate islands because nothing stitched it.
//!
//! So this module asks the oracle, and then it FIXES what the oracle found:
//!
//!  1. tally the routed copper (plus the layout's pours — a poured rail is
//!     joined by its zone and by nothing else),
//!  2. plan one island-joining hop per gap the oracle names, for the nets the
//!     router itself *claimed* were routed,
//!  3. route them through `router.closeGaps`,
//!  4. re-tally, and report the oracle's answer as `routed`/`total`/`failed`.
//!
//! Step 2's scope is the point. Nets the router listed as FAILED are the
//! genuinely hard ones — they need rip-up, finer rasters, or a different global
//! solution, and retrying them inline would double a route's wall clock for
//! nets a finishing pass owns anyway (`close_open_nets`). Nets it claimed to
//! have routed are a different animal: the router already believes it solved
//! them, so the remaining gap is a bookkeeping failure, and the space it has to
//! cross is free by construction. `include_failed` opts into the expensive half.
//!
//! The gate is also strictly ADDITIVE: its judge refuses any hop that had to
//! rip foreign copper. Nothing a route already earned can be taken away here,
//! which is what makes it safe to run unconditionally on every fresh route.
//!
//! "Did it rip anything?" is the whole verdict for a two-pad BRIDGE, because a
//! maze that reached both pads produced a join and one that did not produced
//! nothing. It is not the verdict for a hop on a PLANE- or POUR-carried net: a
//! stitch barrel is "landed" whether or not the fill it drops into is the fill
//! its island needed, so such a hop is committed one island at a time through
//! `island_accept.Ledger` — its copper built as a separate candidate, weighed by
//! the connectivity oracle plus the geometry DRC, and adopted only on a strict
//! gain. That is what lets a rail like board-a's `V_3V3A`, carried by a
//! retained In3.Cu zone and arriving in eight islands, be closed by the gate at
//! all; committing those same stitches unweighed measured 102 -> 98 nets.

const std = @import("std");
const clock = @import("../infra/clock.zig");

// Per-hop no-path trace (debug level: dev servers only).
const closeLog = std.log.debug;
const island_accept = @import("island_accept.zig");
const optimizer = @import("optimizer.zig");
const router = @import("router.zig");
const pour = @import("pour.zig");
const route_policy = @import("route_policy.zig");
const fab_readiness = @import("../fab_readiness.zig");
const routed_copper = @import("routed_copper.zig");

/// Knobs on one reconciliation pass.
pub const Options = struct {
    /// Also plan hops for nets the ROUTER reported as failed. Off by default:
    /// those need the rip-up/finer-raster machinery a dedicated finishing pass
    /// brings, and asking for them inline costs a whole second route's time for
    /// hops that mostly come back `blocked`.
    include_failed: bool = false,
    /// Longest island-joining hop this gate will attempt (mm), measured
    /// pad-to-pad by the oracle. A phantom join is short by nature; a long one
    /// is a real routing problem and belongs to the finishing pass.
    max_hop_mm: f64 = default_max_hop_mm,
    /// Most hops one gate pass will attempt. The gate runs on EVERY fresh
    /// route, so its cost has to be bounded by construction: a board whose
    /// ground net arrives in thirty islands would otherwise turn a two-minute
    /// route into a twenty-minute one. Hops are ordered cheapest-net-first
    /// (`cheapestNetFirst`), so the cap buys as many CLOSED nets as it can
    /// rather than spending itself on one net's islands; whatever is left
    /// simply stays open and is reported as such.
    max_hops: usize = default_max_hops,
    /// Restrict hop planning to these net indices (the caller's routing scope).
    /// Empty means the whole board. A SCOPED re-route must not lay copper on a
    /// net it was told to leave alone — its counters still come from the whole
    /// board's oracle tally, but the fixing half stays inside the scope.
    only_nets: []const bool = &.{},
    /// What THIS pass runs under: its own slice, the board transaction's stop
    /// conditions, and the refusals its earlier passes collected.
    pass: Pass = .{},
    /// Whether the endgame may put an escape via inside an SMD terminal. The
    /// ordinary interactive gate keeps the conservative ban; unattended
    /// completion can opt in for fine-pitch connector lands whose pitch leaves
    /// no DRC-legal sideways trace exit. Through-hole terminals remain banned.
    terminal_via: router.TerminalVia = .banned,
};

/// The clock and the memory ONE gate pass runs under.
pub const Pass = struct {
    /// Absolute wall-clock bound for THIS reconcile pass alone; zero means
    /// unbounded. Expiry stops new hops — and halts an in-flight hop's maze —
    /// but never marks the result cancelled: the gate runs several times per
    /// route, so one pass giving its slice back is normal progress, not a
    /// board abort. Only the shared `stop` below cancels.
    slice_deadline_ns: i128 = 0,
    /// Share the outer route transaction's stop conditions so a large batch of
    /// additive island joins cannot overrun an authored board deadline.
    stop: route_policy.Stop = .{},
    /// Hops this route's EARLIER gate passes already tried and had refused.
    /// Null (the default) re-plans every hop the oracle names on every pass.
    memo: ?*HopMemo = null,
    /// Let a long hop search a corridor proportional to its own span. The
    /// ladder's LAST pass only — see `corridor_span_share`.
    wide_corridors: bool = false,
};

/// The hops a route's gate passes have already tried and been refused, shared
/// across the passes of ONE route.
///
/// The gate re-plans from the oracle's island report every pass, and that
/// report barely moves for a net whose hops all fail: board-a's `V_3V3A`
/// asked for the same fifteen hops in every pass and had every one of them
/// refused — a corridor maze each, plus two whole-board oracle passes for each
/// stitch — which is where two of three timed gate passes went while the rails
/// behind them were never reached. A refusal is geometric, not incidental: the
/// maze that found no path is looking at strictly MORE copper next pass, and a
/// stitch the oracle credited with no island merge lands in the same metal it
/// landed in before. So a refused hop is remembered and not planned again.
///
/// It is deliberately a per-ROUTE memory. A fresh route re-plans everything.
pub const HopMemo = struct {
    alloc: std.mem.Allocator,
    refused: std.ArrayList(Key) = .empty,
    /// Refusals so far per flattened-net index, for the whole-net cutoff below.
    per_net: std.AutoHashMapUnmanaged(usize, usize) = .empty,
    /// Hops whose GRIDLESS SHAPE attempt was refused, keyed WITHOUT the corridor
    /// width (see `refuseShape`).
    shape_refused: std.ArrayList(Key) = .empty,
    /// Shape refusals so far per flattened-net index, for `sealed` below.
    ///
    /// A SECOND tally rather than a contribution to `per_net`, deliberately:
    /// `per_net` drives `exhausted`, which decides which hops the gate ladder
    /// plans, so folding a second event class into it would change what a
    /// clock-free board attempts. Nothing in the routing path reads this one.
    shape_per_net: std.AutoHashMapUnmanaged(usize, usize) = .empty,

    /// A hop's identity: its net plus its endpoints in millimetres. The
    /// endpoints compare exactly — every pass recomputes them from the same pad
    /// table, so the same hop keys identically without a tolerance to tune.
    pub const Key = struct { net_i: usize, from: [2]f64, to: [2]f64, wide: bool = false };

    /// An empty memory, allocating from `alloc` as refusals arrive.
    pub fn init(alloc: std.mem.Allocator) HopMemo {
        return .{ .alloc = alloc };
    }

    /// Release the refusal lists. The memo is per-route, so this runs when the
    /// route's gate ladder ends.
    pub fn deinit(self: *HopMemo) void {
        self.refused.deinit(self.alloc);
        self.per_net.deinit(self.alloc);
        self.shape_refused.deinit(self.alloc);
        self.shape_per_net.deinit(self.alloc);
    }

    /// Remember that this hop's SHAPE attempt found nothing, so no later pass of
    /// this route builds that mesh again.
    ///
    /// Keyed WITHOUT `wide`, which is the whole reason this is a second list
    /// rather than a second entry in the first. The width in a key is the maze's
    /// search corridor, and the ladder's last pass re-plans every refused hop at
    /// the wider width precisely because a corridor with room to detour is a
    /// question the narrow maze was never asked. The shape tier has no such
    /// parameter: it sizes its own window from the hop's terminals and clamps it
    /// to the board (`router.shapeWindow`), so the mesh it builds and the
    /// channel it searches are identical at either width. Re-asking it is a
    /// rebuild of the same mesh over the same copper for the same answer —
    /// measured on board-a, six of the wide pass's shape attempts were verbatim
    /// repeats of hops the ordinary passes had already refused.
    ///
    /// The refusal is durable for the same reason a maze refusal is: this gate is
    /// additive, so every later pass looks at strictly MORE copper, and a channel
    /// that did not exist in the free space does not open when copper is added to
    /// it.
    pub fn refuseShape(self: *HopMemo, gap: router.Gap) std.mem.Allocator.Error!void {
        const tally = try self.shape_per_net.getOrPutValue(self.alloc, gap.net_i, 0);
        tally.value_ptr.* += 1;
        const key = keyOf(gap, false);
        if (self.shapeSeenKey(key)) return;
        try self.shape_refused.append(self.alloc, key);
    }

    /// Was this hop's shape attempt already made, and refused, by an earlier pass?
    pub fn shapeSeen(self: *const HopMemo, gap: router.Gap) bool {
        return self.shapeSeenKey(keyOf(gap, false));
    }

    fn shapeSeenKey(self: *const HopMemo, key: Key) bool {
        for (self.shape_refused.items) |k| if (samePoint(k, key)) return true;
        return false;
    }

    /// Remember that this hop was tried and refused, so no later pass of this
    /// route plans it again.
    pub fn refuse(self: *HopMemo, gap: router.Gap, wide: bool) std.mem.Allocator.Error!void {
        const tally = try self.per_net.getOrPutValue(self.alloc, gap.net_i, 0);
        tally.value_ptr.* += 1;
        const key = keyOf(gap, wide);
        if (self.seenKey(key)) return;
        try self.refused.append(self.alloc, key);
    }

    /// Has this net spent enough of the ladder's slices being refused that the
    /// gate should stop planning it at all?
    ///
    /// A hop-level memory alone does not stop a MANY-ISLANDED net: each accepted
    /// or refused hop reshapes the oracle's island tree, so the next pass names
    /// fresh endpoints and the same net asks for another dozen mazes. Board A's
    /// `V_3V3A` did exactly that — 20-plus refusals across a route, never one net
    /// gained — while `GND`, sorted behind it with eight sub-1.5 mm hops that
    /// land when they are reached, got two attempts in three passes.
    pub fn exhausted(self: *const HopMemo, net_i: usize) bool {
        return self.refusals(net_i) >= net_refusal_cutoff;
    }

    /// How many of this net's hops this route's gate has tried and refused.
    pub fn refusals(self: *const HopMemo, net_i: usize) usize {
        return self.per_net.get(net_i) orelse 0;
    }

    /// How many of this net's hops the GRIDLESS SHAPE tier searched and found no
    /// channel for.
    pub fn shapeRefusals(self: *const HopMemo, net_i: usize) usize {
        return self.shape_per_net.get(net_i) orelse 0;
    }

    /// Has this route already given the net a TERMINAL GEOMETRY answer — one no
    /// later retry of the same board can be expected to overturn?
    ///
    /// The two records mean it in the two ways the gate can say it:
    ///
    ///   * `exhausted` — the ladder refused this net's hops so many times that
    ///     it stopped planning the net at all. That is the gate's own decision
    ///     that the net's answers have stopped being informative.
    ///   * a shape refusal — the gridless tier BUILT this hop's mesh over the
    ///     free space and found no channel (`rememberShapeRefusal` records it
    ///     only when the search actually ran and both tiers declined). A net
    ///     closes only when every one of its hops lands, so one hop with no
    ///     channel in the free space is a sealed net for this board's copper.
    ///
    /// A net with NEITHER has not been answered — a long-hop signal the gate
    /// never plans at all (`planHops`' `all_short` rule) lands here — and a
    /// caller must treat it as open, not as sealed.
    ///
    /// Read by the residual's guided-corridor retry to skip the nets its slices
    /// cannot help, never by the gate itself: no hop this route plans, and no
    /// copper it lays, depends on this answer.
    pub fn sealed(self: *const HopMemo, net_i: usize) bool {
        return self.exhausted(net_i) or self.shapeRefusals(net_i) > 0;
    }

    /// Was this exact hop already tried and refused by an earlier pass?
    pub fn seen(self: *const HopMemo, gap: router.Gap, wide: bool) bool {
        return self.seenKey(keyOf(gap, wide));
    }

    /// A linear scan, deliberately: one route's gate ladder refuses tens of
    /// hops, not thousands, and a list keys on the planner's own f64
    /// millimetres without the bit-pattern detour a float hash would need.
    fn seenKey(self: *const HopMemo, key: Key) bool {
        for (self.refused.items) |k| if (samePoint(k, key)) return true;
        return false;
    }

    fn samePoint(a: Key, b: Key) bool {
        if (a.net_i != b.net_i or a.wide != b.wide) return false;
        if (a.from[0] != b.from[0] or a.from[1] != b.from[1]) return false;
        return a.to[0] == b.to[0] and a.to[1] == b.to[1];
    }

    fn keyOf(gap: router.Gap, wide: bool) Key {
        const target = gap.to orelse gap.stitch_fallback;
        return .{
            .net_i = gap.net_i,
            .from = .{ gap.from.x, gap.from.y },
            .to = if (target) |t| .{ t.x, t.y } else .{ 0, 0 },
            .wide = wide,
        };
    }
};

/// How many refusals on ONE net end its gate planning for the rest of a route.
/// Sized above the handful a net can spend while genuinely converging (a poured
/// rail closing island by island refuses the odd redundant stitch) and below
/// the count a treadmill reaches inside a single pass.
pub const net_refusal_cutoff: usize = 8;

/// `gaps` minus every hop an earlier pass of this route already had refused.
fn withoutRefused(
    arena: std.mem.Allocator,
    gaps: []const router.Gap,
    memo: ?*HopMemo,
    wide: bool,
) std.mem.Allocator.Error![]const router.Gap {
    const seen = memo orelse return gaps;
    var out: std.ArrayList(router.Gap) = .empty;
    for (gaps) |g| {
        if (seen.seen(g, wide)) continue;
        try out.append(arena, g);
    }
    if (out.items.len != gaps.len)
        closeLog("plan: {d} of {d} hops already refused this route", .{ gaps.len - out.items.len, gaps.len });
    return out.toOwnedSlice(arena);
}

/// Default ceiling on how many hops one gate pass attempts. Sized so the gate
/// stays a small fraction of a route's wall clock on a dense board.
pub const default_max_hops: usize = 48;

/// Default ceiling on one reconciliation hop (mm). Sized from the measured
/// phantom joins on board-a — the longest was 1.34 mm (a boost converter's
/// diode-to-inductor switch node) — with headroom for a pad pair that has to
/// detour around one neighbouring part rather than run straight.
pub const default_max_hop_mm: f64 = 4.0;

/// A route whose counters are the oracle's, plus what the gate had to do to get
/// there. `claimed_routed` is what the ROUTER reported before reconciliation:
/// when it exceeds `result.routed` the router over-counted, which is a defect
/// worth surfacing rather than silently correcting.
pub const Reconciled = struct {
    result: router.RouteResult,
    hops_tried: usize = 0,
    hops_kept: usize = 0,
    claimed_routed: usize = 0,
};

/// Reconcile `routed`'s counters with the connectivity oracle, closing the
/// island-joining hops the oracle names on nets the router claimed it finished.
/// Returns copper that is a superset of `routed`'s (the gate never removes
/// copper) carrying honest `routed`/`total`/`failed` counters.
pub fn reconcile(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    params: router.RouteParams,
    routed: router.RouteResult,
    zones: []const route_policy.ExistingZone,
    opts: Options,
) std.mem.Allocator.Error!Reconciled {
    var out = Reconciled{ .result = routed, .claimed_routed = routed.routed };
    const pours = try userZones(arena, placement, zones);
    const before = try fab_readiness.routableTally(arena, placement, copperOf(routed, pours));
    if (before.open.len == 0 or stopRequested(opts)) {
        out.result.routed = before.routed;
        out.result.total = before.total;
        out.result.failed = before.open;
        out.result.cancelled = out.result.cancelled or stopRequested(opts);
        return out;
    }

    const gaps = try planHops(arena, placement, routed, pours, opts);
    if (gaps.len > 0) {
        out.hops_tried = wholeNetPrefixLen(gaps, opts.max_hops);
        if (out.hops_tried < gaps.len) closeLog("plan: prefix keeps {d} of {d} hops", .{ out.hops_tried, gaps.len });
        out.result = try closeEach(arena, .{
            .placement = placement,
            .params = params,
            .routed = routed,
            .zones = zones,
            .pours = pours,
            .stop = opts,
        }, gaps[0..out.hops_tried], &out.hops_kept);
    }

    const after = try tallyAfterHops(arena, placement, out.result, pours, before, out.hops_kept);
    out.result.routed = after.routed;
    out.result.total = after.total;
    out.result.failed = after.open;
    out.result.cancelled = out.result.cancelled or stopRequested(opts);
    return out;
}

fn stopRequested(opts: Options) bool {
    if (opts.pass.stop.cancel) |flag| if (flag.load(.monotonic)) return true;
    return opts.pass.stop.deadline_ns != 0 and clock.nanoTimestamp() >= opts.pass.stop.deadline_ns;
}

fn sliceExpired(opts: Options) bool {
    return opts.pass.slice_deadline_ns != 0 and clock.nanoTimestamp() >= opts.pass.slice_deadline_ns;
}

/// The stop handed to an individual hop's maze: the outer transaction stop
/// with its deadline pulled in to the pass slice, so an in-flight corridor
/// search halts when the slice does. A halted maze yields no complete path and
/// the hop is simply skipped — the board is never marked cancelled by a slice.
fn slicedRasterStop(opts: Options) route_policy.Stop {
    if (opts.pass.slice_deadline_ns == 0) return opts.pass.stop;
    var stop = opts.pass.stop;
    stop.deadline_ns = if (stop.deadline_ns == 0)
        opts.pass.slice_deadline_ns
    else
        @min(stop.deadline_ns, opts.pass.slice_deadline_ns);
    return stop;
}

/// Reconciliation is additive, and `hops_kept == 0` proves `result` contains
/// the same copper the first tally inspected. Reuse that graph-derived answer
/// instead of rebuilding every net's connectivity graph for unchanged copper.
fn tallyAfterHops(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    result: router.RouteResult,
    pours: []const pour.UserZone,
    before: fab_readiness.Tally,
    hops_kept: usize,
) std.mem.Allocator.Error!fab_readiness.Tally {
    if (hops_kept == 0) return before;
    return fab_readiness.routableTally(arena, placement, copperOf(result, pours));
}

/// The board one gate pass works against: the placement, its routing params,
/// the copper routed so far, and the retained pours.
const Board = struct {
    placement: optimizer.Placement,
    params: router.RouteParams,
    routed: router.RouteResult,
    zones: []const route_policy.ExistingZone,
    /// The same retained pours, named for the connectivity oracle — which hops
    /// belong to a poured rail is what decides whether a hop is committed
    /// transactionally (see `transactional`).
    pours: []const pour.UserZone = &.{},
    stop: Options,
};

/// How far outside a hop's pads its search corridor reaches (mm). A gate hop is
/// a short join by construction (`max_hop_mm`), so a corridor this size holds
/// every legal way round its endpoints while keeping the maze bounded.
const corridor_margin_mm: f64 = 3.0;

/// A LAST-CHANCE pass gives a hop long enough to need room to detour a corridor
/// proportional to its own span instead. Three millimetres round a 16 mm hop is
/// a nearly straight slot: board-a's `EN_BUCK6V` is one 16.5 mm bridge, its
/// router diagnosis is "a free-space path the maze could not thread", and every
/// ordinary gate pass reported "no committable path" for it — with the wider
/// corridor it closes.
///
/// It is deliberately not the ORDINARY corridor. A hop given room to detour
/// takes it, and that copper is in the way of everything planned behind it:
/// widening every pass measured 103 -> 102 twice on board-a, closing
/// `EN_BUCK6V` and losing `V_1V8A` and `SPI_DSA_CSN` to the snaking bridge it
/// drew. Spent only once the ladder has otherwise converged, the detour has
/// nothing left to block. The proportion still stops at
/// `corridor_span_max_mm`: past that are the 40-55 mm long shots whose mazes
/// have to stay cheap enough to fail fast inside a pass slice.
const corridor_span_share: f64 = 0.5;
const corridor_span_max_mm: f64 = 20.0;

/// The search corridor half-width for one planned hop.
fn corridorMargin(gap: router.Gap, wide: bool) f64 {
    if (!wide) return corridor_margin_mm;
    const to = gap.to orelse gap.stitch_fallback orelse return corridor_margin_mm;
    const span = std.math.hypot(to.x - gap.from.x, to.y - gap.from.y);
    if (span > corridor_span_max_mm) return corridor_margin_mm;
    return @max(corridor_margin_mm, corridor_span_share * span);
}

/// Route each planned hop inside ITS OWN corridor, folding in the ones that
/// land without ripping.
///
/// One `closeGaps` call per hop rather than one call for the batch, because the
/// window is per-call: an unbounded batch rasters the whole board and lets a
/// hopeless hop drain a board-scale search budget, which measured at over
/// sixteen minutes on board-a against a two-minute route. Bounded to the few
/// millimetres around its own pads, a hop that cannot land fails fast.
fn closeEach(
    arena: std.mem.Allocator,
    board_in: Board,
    gaps: []const router.Gap,
    kept: *usize,
) std.mem.Allocator.Error!router.RouteResult {
    const placement = board_in.placement;
    const params = board_in.params;
    const zones = board_in.zones;
    var board = board_in.routed;
    var ledger = island_accept.Ledger.init(placement, params, zones);
    defer ledger.deinit();
    for (gaps) |gap| {
        if (stopRequested(board_in.stop) or sliceExpired(board_in.stop)) break;
        // The cutoff has to bite INSIDE a pass as well as between passes: a
        // many-islanded net's whole run is planned before its first refusal, so
        // waiting for the next plan hands it the entire slice one more time.
        if (board_in.stop.pass.memo) |memo| if (memo.exhausted(gap.net_i)) continue;
        // A hop the maze may re-ask at a wider corridor, but whose gridless mesh
        // an earlier pass already searched and found sealed, is asked of the maze
        // alone (see `HopMemo.refuseShape`).
        const shape = !shapeRefused(board_in.stop, gap);
        const paths = try router.closeGaps(arena, placement, params, .{
            .tracks = board.tracks,
            .vias = board.vias,
            .zones = zones,
        }, &.{gap}, .{
            .ripup = false,
            .shape = if (shape) .fallback else .off,
            .judge = .{ .ctx = null, .keep = keepAdditiveOnly },
            .terminal_via = board_in.stop.terminal_via,
            .raster = .{
                .window = router.GapWindow.around(gap, corridorMargin(gap, board_in.stop.pass.wide_corridors)),
                .stop = slicedRasterStop(board_in.stop),
            },
        });
        const path = committable(firstPath(paths), stopRequested(board_in.stop)) orelse {
            closeLog("close hop net_i={d} ({d:.2},{d:.2}): no committable path", .{
                gap.net_i, gap.from.x, gap.from.y,
            });
            // Only a maze that RAN and found nothing is a verdict. A slice that
            // expired mid-search says nothing about the hop, so it is left for
            // a later pass rather than remembered as refused.
            if (!sliceExpired(board_in.stop)) {
                try rememberRefusal(board_in.stop, gap);
                // No copper at all means BOTH tiers declined, so the shape tier's
                // own answer is recorded too — but only when it was allowed to
                // run, or the memo would remember a search that never happened.
                if (shape) try rememberShapeRefusal(board_in.stop, gap);
            }
            continue;
        };
        // Each hop sees the copper the previous ones laid, so a batch never
        // draws two joins through the same channel.
        if (!transactional(placement, board_in.pours, gap)) {
            board = try absorb(arena, board, path, kept);
            continue;
        }
        const merged = try ledger.commit(arena, board, .{ .net_i = gap.net_i, .path = path });
        board = merged orelse {
            try rememberRefusal(board_in.stop, gap);
            continue;
        };
        kept.* += 1;
    }
    return board;
}

/// Record a hop the gate tried and refused, when the caller is keeping a memo.
fn rememberRefusal(opts: Options, gap: router.Gap) std.mem.Allocator.Error!void {
    if (opts.pass.memo) |memo| try memo.refuse(gap, opts.pass.wide_corridors);
}

/// Record a hop whose shape attempt found nothing, when the caller keeps a memo.
fn rememberShapeRefusal(opts: Options, gap: router.Gap) std.mem.Allocator.Error!void {
    if (opts.pass.memo) |memo| try memo.refuseShape(gap);
}

/// Has this route's gate already built and searched this hop's mesh in vain?
fn shapeRefused(opts: Options, gap: router.Gap) bool {
    const memo = opts.pass.memo orelse return false;
    return memo.shapeSeen(gap);
}

/// A hop's copper, or null when the route transaction's deadline expired while
/// that hop was routing. Weighing a hop is two whole-board oracle passes, so a
/// timed route DROPS a hop it can no longer afford to judge rather than
/// committing a mutation it never measured. The loop's own pre-hop check stops
/// it from starting more work; this is the half that keeps the work already
/// done from landing unjudged.
fn committable(path: ?router.GapPath, expired: bool) ?router.GapPath {
    if (expired) return null;
    return path;
}

/// Does this hop belong to a net a PLANE or one of the layout's own pours
/// carries? Such a hop is the one whose copper can land without joining
/// anything — a stitch barrel is "landed" whether or not the metal it drops
/// into is the metal its island needed, and a poured rail's islands are closed
/// a few at a time rather than all at once — so it is weighed against the
/// connectivity oracle rather than merely checked for rips (`island_accept`).
fn transactional(placement: optimizer.Placement, pours: []const pour.UserZone, gap: router.Gap) bool {
    if (gap.net_i >= placement.nets.len) return false;
    return planeCarried(placement, pours, placement.nets[gap.net_i].name);
}

/// The single hop's copper out of a one-gap `closeGaps` batch.
fn firstPath(paths: []const ?router.GapPath) ?router.GapPath {
    if (paths.len == 0) return null;
    return paths[0];
}

/// The oracle's view of a route's copper: its tracks and vias plus the layout's
/// pours, which are connecting copper for any rail poured rather than traced.
fn copperOf(routed: router.RouteResult, zones: []const pour.UserZone) routed_copper.Copper {
    return .{
        .tracks = routed.tracks,
        .arcs = routed.arcs,
        .rf_paths = routed.rf_port_outcomes,
        .vias = routed.vias,
        .zones = zones,
    };
}

/// Keep only hops that laid copper WITHOUT ripping any. The gate runs on every
/// fresh route, so it must never be able to make a board worse: a hop that
/// needs foreign copper out of its way is a rip-and-repair transaction, which
/// is the finishing pass's job and not something a reporting fix should do.
fn keepAdditiveOnly(ctx: ?*anyopaque, index: usize, path: router.GapPath) bool {
    _ = ctx;
    _ = index;
    return path.ripped.len == 0;
}

/// Plan one hop per gap the oracle names on an eligible net: a maze bridge
/// between two islands' nearest pads, or — for a net a plane or one of its own
/// pours carries — a stitch via beside each stranded island, which is how such
/// a pad rejoins its net (a surface trace between two QFN ground pads usually
/// cannot exist at all).
fn planHops(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    zones: []const pour.UserZone,
    opts: Options,
) std.mem.Allocator.Error![]const router.Gap {
    const opens = try fab_readiness.openNets(arena, placement, copperOf(routed, zones));
    var index = try refIndex(arena, placement);
    var gaps: std.ArrayList(router.Gap) = .empty;
    for (opens) |o| {
        if (!opts.include_failed and namedIn(routed.failed, o.net)) continue;
        const net_i = netIndex(placement, o.net) orelse continue;
        if (opts.only_nets.len > net_i and !opts.only_nets[net_i]) continue;
        if (opts.pass.memo) |memo| if (memo.exhausted(net_i)) {
            closeLog("plan {s} (net_i={d}): skipped, {d} refusals this route", .{
                o.net, net_i, net_refusal_cutoff,
            });
            continue;
        };
        if (planeCarried(placement, zones, o.net)) {
            const before_plan = gaps.items.len;
            const stitch_opts = StitchOptions{
                .net_i = net_i,
                .max_fallback_mm = opts.max_hop_mm,
            };
            try appendStitches(arena, &gaps, &index, placement, o, stitch_opts);
            closeLog("plan {s} (net_i={d}): {d} islands, {d} stitches planned", .{
                o.net, net_i, o.islands, gaps.items.len - before_plan,
            });
            // A pour is no rescue for an island its fill never reaches. Of
            // board-a's `V_3V3A` islands only two sit over the In3 zone that
            // carries the rail; the rest are 1.0-10.2 mm surface hops between
            // ordinary pads, so a pass that plans stitches alone leaves every
            // one of them open. Each island-joining hop the oracle named is
            // therefore requested as well, as its own transaction — and
            // INDEPENDENTLY, unlike the non-poured branch below: a poured rail's
            // islands close a few at a time, so one leg too long for the gate
            // must not withdraw the trivial local joins beside it.
            // The bridge ceiling stays at the DEFAULT short-hop bound even when
            // the gate's own ceiling is the 50 mm standard tier: a long bridge
            // is a corridor maze — a full net route in cost — and one poured
            // rail's 10 mm legs ran the broad gate to 108 s on board-a,
            // starving every later phase. The pour is the long-haul carrier;
            // an island past the short bound belongs to the residual passes.
            const before_bridges = gaps.items.len;
            const bridge_opts = StitchOptions{
                .net_i = net_i,
                .max_fallback_mm = @min(opts.max_hop_mm, default_max_hop_mm),
            };
            try appendBridges(arena, &gaps, &index, placement, o, bridge_opts);
            closeLog("plan {s} (net_i={d}): {d} bridges planned", .{
                o.net, net_i, gaps.items.len - before_bridges,
            });
            continue;
        }
        // This gate buys completed nets, not partial copper. If even one
        // required island join is a genuine long-route problem, spending the
        // bounded hop budget on this net's shorter joins cannot change its
        // routed tally. Leave the whole net to the residual/finishing pass so
        // those no-win hops cannot starve a fully closable net behind it.
        var all_short = true;
        for (o.gaps) |g| if (g.mm > opts.max_hop_mm) {
            all_short = false;
            break;
        };
        if (!all_short) continue;
        for (o.gaps) |g| {
            const from = padPoint(placement, &index, g.from) orelse continue;
            const to = padPoint(placement, &index, g.to) orelse continue;
            try gaps.append(arena, .{ .net_i = net_i, .from = from, .to = to });
        }
    }
    return cheapestNetFirst(arena, try withoutRefused(arena, gaps.items, opts.pass.memo, opts.pass.wide_corridors));
}

/// Order the planned hops CHEAPEST NET FIRST — every hop of the net that needs
/// fewest, then the next, keeping each net's hops together.
///
/// `reconcile` attempts only whole-net runs inside its `max_hops` prefix, and a
/// net only closes when EVERY one of its hops lands, so the budget buys closed
/// nets and nothing else. Net order — what this replaces — spends it badly: one
/// net with many islands eats the whole budget and every net behind it is dropped
/// untried, and a plane-carried ground net is exactly that shape, stranding thirty
/// islands where a signal net strands one. Cheapest-net-first is the greedy answer
/// to the actual question: it maximises nets closed per hop spent.
///
/// Measured on the corpus, on top of the in-pad stitch search: board-e
/// 47 -> 52 routed nets and board-d 80 -> 83, with board-a's sixteen ground
/// stitches still fitting because its whole board asks for fewer hops than the
/// budget. Dealing round-robin instead — every net's first hop, then every net's
/// second — measured identically on every board, so the win is in not letting one
/// net take the lot rather than in the exact discipline; this order is the one
/// that also keeps a multi-hop net whole.
///
/// The reorder is a pure permutation — no hop is dropped here — and its key is a
/// total order (run length, then the run's first position), so it neither loses
/// work nor depends on sort stability.
fn cheapestNetFirst(arena: std.mem.Allocator, gaps: []const router.Gap) std.mem.Allocator.Error![]const router.Gap {
    // `planHops` appends one contiguous run per open net, so a run boundary is
    // exactly a change of `net_i`. A run's cost key is its HOP COUNT, because a
    // net closes only when every one of its hops lands: the count is exactly
    // how many hops the slice must buy to gain a net, which is what the budget
    // is being spent on. Keying total millimetres instead was measured and
    // reverted — it promoted board-a's two many-islanded rails (GND's sixteen
    // sub-2 mm hops, V_3V3A's fifteen) ahead of the three-hop rails behind them
    // and cost three closed nets (v46 102 -> v48 100), because a long run's
    // early hops buy nothing when its later ones cannot land.
    var runs: std.ArrayList(RunCost) = .empty; // {start, len}
    for (gaps, 0..) |g, i| {
        if (i > 0 and gaps[i - 1].net_i == g.net_i) {
            runs.items[runs.items.len - 1].len += 1;
            continue;
        }
        try runs.append(arena, .{ .start = i, .len = 1 });
    }
    std.mem.sort(RunCost, runs.items, {}, cheaperRun);
    var out: std.ArrayList(router.Gap) = .empty;
    for (runs.items) |run| try out.appendSlice(arena, gaps[run.start .. run.start + run.len]);
    return out.toOwnedSlice(arena);
}

const RunCost = struct { start: usize, len: usize };

fn cheaperRun(_: void, a: RunCost, b: RunCost) bool {
    if (a.len != b.len) return a.len < b.len;
    return a.start < b.start;
}

/// Longest prefix no greater than `budget` which ends at a net-run boundary.
/// `cheapestNetFirst` keeps each net contiguous and orders shorter runs first,
/// so once the next run does not fit no later run can fit either.
fn wholeNetPrefixLen(gaps: []const router.Gap, budget: usize) usize {
    var accepted: usize = 0;
    var run_start: usize = 0;
    while (run_start < gaps.len) {
        var run_end = run_start + 1;
        while (run_end < gaps.len and gaps[run_end].net_i == gaps[run_start].net_i) : (run_end += 1) {}
        if (run_end > budget) break;
        accepted = run_end;
        run_start = run_end;
    }
    return accepted;
}

/// Shorter run first, earlier run breaking every tie.
/// One request per stranded copper island of a plane/pour-carried net. Prefer
/// a stitch via, retaining the oracle's nearest cross-island pad as a bridge
/// fallback. An island already sitting on a disconnected component of its own
/// pour cannot benefit from another via; use its parent edge in the oracle's
/// island tree as a bridge directly instead.
fn appendStitches(
    arena: std.mem.Allocator,
    gaps: *std.ArrayList(router.Gap),
    index: *std.StringHashMapUnmanaged(usize),
    placement: optimizer.Placement,
    o: fab_readiness.OpenNet,
    opts: StitchOptions,
) std.mem.Allocator.Error!void {
    var done: std.AutoHashMapUnmanaged(usize, void) = .empty;
    const main = mainIsland(o);
    for (o.pads) |p| {
        const seen = try done.getOrPut(arena, p.island);
        if (seen.found_existing) continue;
        if (skipStitch(placement, o, p.island, main)) {
            // `closingGaps` emits a rooted tree: every non-root island appears
            // exactly once as `to`. Bridging that parent edge joins a pour
            // component that another via would merely land back inside.
            for (o.gaps) |g| {
                if (g.to.island != p.island or g.mm > opts.max_fallback_mm) continue;
                const from = padPoint(placement, index, g.to) orelse break;
                const to = padPoint(placement, index, g.from) orelse break;
                try gaps.append(arena, .{ .net_i = opts.net_i, .from = from, .to = to });
                break;
            }
            continue;
        }
        const choice = stitchFallback(placement, index, o, p, opts.max_fallback_mm);
        try gaps.append(arena, .{
            .net_i = opts.net_i,
            .from = choice.from,
            .stitch_fallback = choice.to,
        });
    }
}

const StitchOptions = struct {
    net_i: usize,
    max_fallback_mm: f64,
};

/// One BRIDGE request per island-joining hop the oracle named, within the
/// ceiling — the short surface join (with a via where the two pads are on
/// different sides) that a stitch cannot stand in for when neither island sits
/// over the rail's pour.
fn appendBridges(
    arena: std.mem.Allocator,
    gaps: *std.ArrayList(router.Gap),
    index: *std.StringHashMapUnmanaged(usize),
    placement: optimizer.Placement,
    o: fab_readiness.OpenNet,
    opts: StitchOptions,
) std.mem.Allocator.Error!void {
    for (o.gaps) |g| {
        if (g.mm > opts.max_fallback_mm) continue;
        const from = padPoint(placement, index, g.from) orelse continue;
        const to = padPoint(placement, index, g.to) orelse continue;
        try gaps.append(arena, .{ .net_i = opts.net_i, .from = from, .to = to });
    }
}

/// Nearest endpoint outside `island` from the oracle's island-spanning tree.
/// `appendStitches` prefers a via because that is the cleanest connection to a
/// plane, but a crowded surface pad may have no legal via site. The oracle has
/// already identified the shortest real pad-to-pad join; retain its far end so
/// the router can try that bridge instead of declaring the rail impossible.
const StitchFallback = struct {
    from: router.NetPt,
    to: ?router.NetPt,
};

fn stitchFallback(
    placement: optimizer.Placement,
    index: *std.StringHashMapUnmanaged(usize),
    o: fab_readiness.OpenNet,
    default_pad: fab_readiness.OpenPad,
    max_mm: f64,
) StitchFallback {
    var from = padPoint(placement, index, default_pad) orelse router.NetPt{
        .x = default_pad.x,
        .y = default_pad.y,
        .layer = @as(u8, if (default_pad.side == .top) 0 else 1),
        .thru = default_pad.thru,
    };
    var to: ?router.NetPt = null;
    var best_mm = std.math.inf(f64);
    for (o.gaps) |g| {
        const pair = if (g.from.island == default_pad.island)
            .{ g.from, g.to }
        else if (g.to.island == default_pad.island)
            .{ g.to, g.from }
        else
            continue;
        if (g.mm <= max_mm and g.mm < best_mm) {
            const candidate_from = padPoint(placement, index, pair[0]) orelse continue;
            const candidate_to = padPoint(placement, index, pair[1]) orelse continue;
            from = candidate_from;
            to = candidate_to;
            best_mm = g.mm;
        }
    }
    return .{ .from = from, .to = to };
}

/// The island holding most of the net's pads — its main body. Ties go to the
/// lowest island id, so the answer is a pure function of the oracle's report.
fn mainIsland(o: fab_readiness.OpenNet) usize {
    var best: usize = 0;
    var best_n: usize = 0;
    for (o.pads) |p| {
        var n: usize = 0;
        for (o.pads) |q| {
            if (q.island == p.island) n += 1;
        }
        if (n > best_n or (n == best_n and p.island < best)) {
            best = p.island;
            best_n = n;
        }
    }
    return best;
}

/// Does this island need no stitch via?
///
/// Only when the copper a via there would reach is copper the island is
/// ALREADY part of. `plane_joined` alone does not say that: there is one plane
/// node per pour COMPONENT, and two pads sharing a component are united into
/// one island — so several islands being plane-joined means they sit on
/// several DISJOINT pieces of the net's pour, each still needing a way down.
///
/// A net with a declared PLANE has copper on a layer the island is not on, so a
/// via there always reaches new metal; the one island for which that merges
/// nothing is the net's own main body. A pour-only net has no such layer — the
/// pour its island touches is the whole of what a via could reach — so its
/// pour-joined islands keep the original skip.
fn skipStitch(placement: optimizer.Placement, o: fab_readiness.OpenNet, island: usize, main: usize) bool {
    if (island >= o.plane_joined.len or !o.plane_joined[island]) return false;
    if (!router.netHasPlane(placement, o.net)) return true;
    return island == main;
}

/// Fold a kept hop's copper into `routed`, counting the keep. A hop the judge
/// rejected (see `keepAdditiveOnly`) contributes nothing, and no existing copper
/// is ever dropped — `ripped` is empty on every path that survives it.
fn absorb(
    arena: std.mem.Allocator,
    routed: router.RouteResult,
    path: router.GapPath,
    kept: *usize,
) std.mem.Allocator.Error!router.RouteResult {
    if (path.ripped.len > 0) return routed;
    var tracks: std.ArrayList(router.Track) = .empty;
    var vias: std.ArrayList(router.Via) = .empty;
    try tracks.appendSlice(arena, routed.tracks);
    try tracks.appendSlice(arena, path.tracks);
    try vias.appendSlice(arena, routed.vias);
    try vias.appendSlice(arena, path.vias);
    kept.* += 1;
    var out = routed;
    out.tracks = try tracks.toOwnedSlice(arena);
    out.vias = try vias.toOwnedSlice(arena);
    return out;
}

/// Name the router's index-keyed retained pours so the connectivity oracle can
/// credit them. The router carries `ExistingZone` (net INDEX) while the oracle
/// speaks `UserZone` (net NAME); without this translation every pad on a rail
/// that is poured rather than traced reads as its own isolated island, which is
/// the exact false positive the gate exists to remove. Keepout zones carry no
/// copper and so join nothing — they are dropped.
///
/// `pub` for the second caller that has to ask the same oracle the same
/// question: `fine_accept.Gate`, the accept gate on declared-resolution rescue
/// windows. One spelling of the translation keeps mid-route and post-route
/// connectivity answering about the same board.
pub fn userZones(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    zones: []const route_policy.ExistingZone,
) std.mem.Allocator.Error![]const pour.UserZone {
    var out: std.ArrayList(pour.UserZone) = .empty;
    for (zones) |z| {
        if (!z.copper) continue;
        // A keepout or an unassigned zone carries a negative net index; naming
        // it would index the net table out of range (and `@intCast` on a
        // negative is a checked panic in ReleaseSafe, which is how prod runs).
        if (z.net < 0) continue;
        const ni: usize = @intCast(z.net);
        if (ni >= placement.nets.len) continue;
        try out.append(arena, .{
            .net = placement.nets[ni].name,
            .layer = z.layer,
            .poly = z.polygon,
            .priority = z.priority,
        });
    }
    return out.toOwnedSlice(arena);
}

/// True when a plane or one of the layout's own pours already carries `name`,
/// so its stranded pads rejoin by dropping a via rather than by a surface hop.
fn planeCarried(placement: optimizer.Placement, zones: []const pour.UserZone, name: []const u8) bool {
    if (router.netHasPlane(placement, name)) return true;
    for (zones) |z| {
        if (std.mem.eql(u8, z.net, name)) return true;
    }
    return false;
}

/// Ref-des → part index, for lifting an oracle pad back onto its part.
/// One island-joining hop between two pads the connectivity oracle named, as a
/// `router.closeGaps` request — the same request `planHops` builds for the
/// gate, exposed because the per-gap unblock transaction draws exactly one of
/// these after freeing its channel, and it must ask for it the same way (same
/// pad-to-terminal mapping, same layer rule) or the two passes would be aiming
/// at different geometry.
pub fn hopRequest(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    net_i: usize,
    from: fab_readiness.OpenPad,
    to: fab_readiness.OpenPad,
) std.mem.Allocator.Error!?router.Gap {
    var index = try refIndex(arena, placement);
    const a = padPoint(placement, &index, from) orelse return null;
    const b = padPoint(placement, &index, to) orelse return null;
    return .{ .net_i = net_i, .from = a, .to = b };
}

/// The search corridor one such hop is drawn inside — the gate's own margin, so
/// a hop the gate refused for want of room is not silently re-asked with more.
pub fn hopWindow(gap: router.Gap) router.GapWindow {
    return router.GapWindow.around(gap, corridorMargin(gap, false));
}

/// Keep only a hop that laid copper without ripping any: the per-gap
/// transaction rips through the vacate policy BEFORE it draws, so anything the
/// draw itself would have to move is copper nobody nominated.
pub fn additiveOnly(ctx: ?*anyopaque, index: usize, path: router.GapPath) bool {
    return keepAdditiveOnly(ctx, index, path);
}

fn refIndex(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
) std.mem.Allocator.Error!std.StringHashMapUnmanaged(usize) {
    var index: std.StringHashMapUnmanaged(usize) = .empty;
    for (placement.parts, 0..) |p, i| try index.put(arena, p.ref_des, i);
    return index;
}

/// The flattened-net index of `name`, or null when unknown.
fn netIndex(placement: optimizer.Placement, name: []const u8) ?usize {
    for (placement.nets, 0..) |net, i| {
        if (std.mem.eql(u8, net.name, name)) return i;
    }
    return null;
}

/// Is `name` one of `names`?
fn namedIn(names: []const []const u8, name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// Lift an oracle pad into the router's terminal form: its world centre, the
/// signal layer its side puts it on, and the outward escape axis (part centre →
/// pad centre) the gateway fan prefers.
fn padPoint(
    placement: optimizer.Placement,
    index: *std.StringHashMapUnmanaged(usize),
    p: fab_readiness.OpenPad,
) ?router.NetPt {
    const pi = index.get(p.ref) orelse return null;
    const part = placement.parts[pi];
    const len = std.math.hypot(p.x - part.x, p.y - part.y);
    return .{
        .x = p.x,
        .y = p.y,
        .layer = if (p.side == .bottom) 1 else 0,
        .thru = p.thru,
        .ref_des = p.ref,
        .pin = p.pad,
        .out = if (len > 1e-9) .{ (p.x - part.x) / len, (p.y - part.y) / len } else .{ 0, 0 },
    };
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;
const geometry = @import("geometry.zig");
const flat_netlist = @import("../flat_netlist.zig");

/// Three 0.4 mm pads in a row on one net: R1 and R2 one millimetre apart, R3
/// three millimetres further on. Enough board for a phantom join (R1↔R2) and a
/// hop the ceiling refuses (R2↔R3).
const three_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};

fn threePadParts() [3]optimizer.Part {
    return .{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &three_pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &three_pad, .fallback = false, .x = 1, .y = 0 },
        .{ .ref_des = "R3", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &three_pad, .fallback = false, .x = 6, .y = 0 },
    };
}

fn fixturePlacement(parts: []optimizer.Part, nets: []const optimizer.FlatNet) optimizer.Placement {
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1,
        .miny = -1,
        .maxx = 7,
        .maxy = 1,
        .generated = true,
    };
}

const three_pins = [_]flat_netlist.FlatPin{
    .{ .ref_des = "R1", .pin = "1" },
    .{ .ref_des = "R2", .pin = "1" },
    .{ .ref_des = "R3", .pin = "1" },
};

const two_pins = [_]flat_netlist.FlatPin{
    .{ .ref_des = "R1", .pin = "1" },
    .{ .ref_des = "R2", .pin = "1" },
};

// spec: placement/route-close - a fresh route's routed/total counters are the connectivity oracle's answer, not the router's own claim
test "reconcile replaces an over-counted claim with the oracle's tally" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = threePadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &three_pins }};
    const placement = fixturePlacement(&parts, &nets);
    // The router's claim: one net routed, with copper joining R2 and R3 only —
    // R1 is left stranded, exactly the phantom-join shape.
    const tracks = [_]router.Track{.{ .x1 = 1, .y1 = 0, .x2 = 6, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 }};
    const claim = router.RouteResult{ .tracks = &tracks, .vias = &.{}, .routed = 1, .total = 1 };

    // With hops disallowed by a zero ceiling the gate cannot fix anything, so
    // it reports the honest number instead of the claim.
    const honest = try reconcile(arena, placement, .{}, claim, &.{}, .{ .max_hop_mm = 0 });
    try testing.expectEqual(@as(usize, 1), honest.claimed_routed);
    try testing.expectEqual(@as(usize, 0), honest.result.routed);
    try testing.expectEqual(@as(usize, 1), honest.result.total);
    try testing.expectEqual(@as(usize, 1), honest.result.failed.len);
    try testing.expectEqualStrings("SIG", honest.result.failed[0]);
}

// spec: placement/route-close - a reconciliation pass that keeps no copper reuses its first connectivity tally
test "unchanged reconciliation reuses its first connectivity tally" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = threePadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &two_pins }};
    const placement = fixturePlacement(&parts, &nets);
    const open = [_][]const u8{"SIG"};
    const before = fab_readiness.Tally{ .routed = 0, .total = 1, .open = &open };

    const unchanged = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 1 };
    const after = try tallyAfterHops(arena, placement, unchanged, &.{}, before, 0);
    try testing.expectEqual(before.routed, after.routed);
    try testing.expectEqual(before.total, after.total);
    try testing.expect(after.open.ptr == before.open.ptr);
}

// spec: placement/route-close - the post-route oracle gate closes the short island-joining hops a batch route left open and reports the net routed
test "reconcile bridges a phantom join and reports the net routed" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = threePadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &two_pins }};
    const placement = fixturePlacement(&parts, &nets);
    // No copper at all: R1 and R2 are 1 mm apart, well inside the ceiling.
    const claim = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 1, .total = 1 };
    const fixed = try reconcile(arena, placement, .{}, claim, &.{}, .{});
    try testing.expect(fixed.hops_tried >= 1);
    try testing.expectEqual(@as(usize, 1), fixed.hops_kept);
    try testing.expectEqual(@as(usize, 1), fixed.result.routed);
    try testing.expectEqual(@as(usize, 0), fixed.result.failed.len);
    try testing.expect(fixed.result.tracks.len > 0);
}

// spec: placement/route-close - a poured rail's redundant island hops are refused once the one that merged its islands is kept
test "reconcile keeps one hop of a poured rail and refuses the redundant rest" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = threePadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "PWR", .pins = &two_pins }};
    const placement = fixturePlacement(&parts, &nets);
    // A pour naming the rail, well away from either pad: it makes `PWR`
    // pour-carried (so its hops go through the transactional gate) without
    // joining anything, which is board-a's `V_3V3A` in miniature — a zone
    // that covers one strip of the board and none of the stranded islands.
    const poly = [_][2]f64{ .{ 4, -0.9 }, .{ 5, -0.9 }, .{ 5, -0.3 }, .{ 4, -0.3 } };
    const zones = [_]route_policy.ExistingZone{.{ .polygon = &poly, .layer = 0, .net = 0, .copper = true }};
    const claim = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 1, .total = 1 };
    const out = try reconcile(arena, placement, .{}, claim, &zones, .{});
    // One hop per stranded island plus one per oracle gap — all requested, so a
    // stitch that cannot land never withdraws the surface join beside it.
    try testing.expect(out.hops_tried >= 2);
    // …but only the hop that actually merged the islands is committed. The old
    // "did it rip anything?" rule kept every one of them.
    try testing.expectEqual(@as(usize, 1), out.hops_kept);
    try testing.expectEqual(@as(usize, 1), out.result.routed);
    try testing.expectEqual(@as(usize, 0), out.result.failed.len);
}

// spec: placement/route-close - a pour-carried bridge keeps the short default ceiling even at the wide standard gate tier, so a long leg is left to the residual passes instead of a gate-time corridor maze
test "a poured net's bridge ceiling stays short at the wide gate tier" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = threePadParts();
    // R2↔R3 are 5 mm apart: over the 4 mm default, under the 50 mm standard
    // tier. The pour makes the net pour-carried without joining anything.
    const pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "R2", .pin = "1" },
        .{ .ref_des = "R3", .pin = "1" },
    };
    const nets = [_]optimizer.FlatNet{.{ .name = "PWR", .pins = &pins }};
    const placement = fixturePlacement(&parts, &nets);
    const poly = [_][2]f64{ .{ 4, -0.9 }, .{ 5, -0.9 }, .{ 5, -0.3 }, .{ 4, -0.3 } };
    const existing = [_]route_policy.ExistingZone{.{ .polygon = &poly, .layer = 0, .net = 0, .copper = true }};
    const zones = try userZones(arena, placement, &existing);
    const claim = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 1, .total = 1 };
    const gaps = try planHops(arena, placement, claim, zones, .{ .max_hop_mm = 50 });
    for (gaps) |g| {
        const to = g.to orelse continue;
        const dx = to.x - g.from.x;
        const dy = to.y - g.from.y;
        try testing.expect(@sqrt(dx * dx + dy * dy) <= default_max_hop_mm + 1e-9);
    }
}

// spec: placement/route-close - the post-route oracle gate never plans a hop longer than its ceiling, leaving genuine routing problems to the finishing pass
test "reconcile refuses a hop past the ceiling" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = threePadParts();
    // R2↔R3 are 5 mm apart — past the default ceiling.
    const pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "R2", .pin = "1" },
        .{ .ref_des = "R3", .pin = "1" },
    };
    const nets = [_]optimizer.FlatNet{.{ .name = "LONG", .pins = &pins }};
    const placement = fixturePlacement(&parts, &nets);
    const claim = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 1, .total = 1 };
    const out = try reconcile(arena, placement, .{}, claim, &.{}, .{});
    try testing.expectEqual(@as(usize, 0), out.hops_tried);
    try testing.expectEqual(@as(usize, 0), out.result.routed);
}

// spec: placement/route-deadline - an expired route deadline keeps the additive connectivity gate from starting new hops
test "an expired route deadline stops the additive gate" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = threePadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &two_pins }};
    const placement = fixturePlacement(&parts, &nets);
    const claim = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 1, .total = 1 };
    const out = try reconcile(arena, placement, .{}, claim, &.{}, .{ .pass = .{ .stop = .{ .deadline_ns = 1 } } });
    try testing.expect(out.result.cancelled);
    try testing.expectEqual(@as(usize, 0), out.hops_tried);
    try testing.expectEqual(@as(usize, 0), out.result.routed);
}

// spec: placement/route-close - a net with any over-ceiling gap consumes no bounded gate hops because its shorter joins cannot make the net complete
test "reconcile skips every partial hop on a net with a long gap" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = threePadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "MIXED", .pins = &three_pins }};
    const placement = fixturePlacement(&parts, &nets);
    // R1↔R2 is only 1 mm, but R2↔R3 is 5 mm. Closing the first join can
    // never change this net's tally while the second remains beyond the gate.
    const claim = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 1, .total = 1 };
    const out = try reconcile(arena, placement, .{}, claim, &.{}, .{ .max_hop_mm = 4 });
    try testing.expectEqual(@as(usize, 0), out.hops_tried);
    try testing.expectEqual(@as(usize, 0), out.result.tracks.len);
    try testing.expectEqual(@as(usize, 0), out.result.routed);
}

// spec: placement/route-close - the post-route oracle gate skips nets the router itself reported failed unless the caller opts in
test "reconcile leaves a router-failed net to the finishing pass by default" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = threePadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &two_pins }};
    const placement = fixturePlacement(&parts, &nets);
    const failed = [_][]const u8{"SIG"};
    const claim = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 1, .failed = &failed };

    const skipped = try reconcile(arena, placement, .{}, claim, &.{}, .{});
    try testing.expectEqual(@as(usize, 0), skipped.hops_tried);

    const opted_in = try reconcile(arena, placement, .{}, claim, &.{}, .{ .include_failed = true });
    try testing.expect(opted_in.hops_tried >= 1);
    try testing.expectEqual(@as(usize, 1), opted_in.result.routed);
}

// spec: placement/route-effort - a one-shot route lets the post-route oracle gate finish the nets the router gave up on, since no rescue ladder runs behind it
test "include_failed recovers a short join the router gave up on" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = threePadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &two_pins }};
    const placement = fixturePlacement(&parts, &nets);
    // The shape a one-shot route produces: a trivially closable 1 mm join that
    // the router nonetheless listed as failed, because it did not retry.
    const failed = [_][]const u8{"SIG"};
    const claim = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 1, .failed = &failed };

    // Behind a retrying route the gate defers — the rescue ladder owns it.
    try testing.expectEqual(@as(usize, 0), (try reconcile(arena, placement, .{}, claim, &.{}, .{})).hops_tried);
    // With nothing behind it, the gate finishes the board itself.
    const finished = try reconcile(arena, placement, .{}, claim, &.{}, .{ .include_failed = true });
    try testing.expectEqual(@as(usize, 1), finished.result.routed);
}

// spec: placement/route-close - a scoped re-route's gate confines its hops to the scope while still reporting the whole board's tally
test "reconcile leaves out-of-scope nets alone" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Four parts so the two nets share NO pad — a pad on two nets is not a
    // board, and the oracle's island count for one would depend on the other.
    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 1, .y = 0 },
        .{ .ref_des = "R3", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 0, .y = 3 },
        .{ .ref_des = "R4", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 1, .y = 3 },
    };
    const in_scope = [_]flat_netlist.FlatPin{
        .{ .ref_des = "R1", .pin = "1" },
        .{ .ref_des = "R2", .pin = "1" },
    };
    const out_of_scope = [_]flat_netlist.FlatPin{
        .{ .ref_des = "R3", .pin = "1" },
        .{ .ref_des = "R4", .pin = "1" },
    };
    const nets = [_]optimizer.FlatNet{
        .{ .name = "INSCOPE", .pins = &in_scope },
        .{ .name = "OTHER", .pins = &out_of_scope },
    };
    const placement = fixturePlacement(&parts, &nets);
    const claim = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 2, .total = 2 };
    const selected = [_]bool{ true, false };
    const out = try reconcile(arena, placement, .{}, claim, &.{}, .{
        .only_nets = &selected,
        .max_hop_mm = 10, // both hops are within reach; only the scope may stop one
    });
    // Only the in-scope net was worth a hop...
    try testing.expectEqual(@as(usize, 1), out.hops_tried);
    // ...but the tally still describes the WHOLE board, so OTHER reads open.
    try testing.expectEqual(@as(usize, 2), out.result.total);
    try testing.expectEqual(@as(usize, 1), out.result.failed.len);
    try testing.expectEqualStrings("OTHER", out.result.failed[0]);
}

// spec: placement/route-close - a keepout or unassigned zone is skipped rather than named as a net's pour
test "reconcile survives a zone with no net" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = threePadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &two_pins }};
    const placement = fixturePlacement(&parts, &nets);
    const poly = [_][2]f64{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };
    const zones = [_]route_policy.ExistingZone{
        .{ .polygon = &poly, .layer = 0, .net = -1 }, // keepout: no net
        .{ .polygon = &poly, .layer = 0, .net = 99, .copper = true }, // past the table
    };
    const claim = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 1, .total = 1 };
    const out = try reconcile(arena, placement, .{}, claim, &zones, .{});
    try testing.expectEqual(@as(usize, 1), out.result.total);
}

// spec: placement/route-close - the post-route oracle gate is additive: it never drops copper the route already earned
test "reconcile keeps every existing track" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = threePadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "SIG", .pins = &two_pins }};
    const placement = fixturePlacement(&parts, &nets);
    const tracks = [_]router.Track{.{ .x1 = 0, .y1 = 0.9, .x2 = 6, .y2 = 0.9, .layer = 1, .width = 0.2, .net = 0 }};
    const claim = router.RouteResult{ .tracks = &tracks, .vias = &.{}, .routed = 1, .total = 1 };
    const out = try reconcile(arena, placement, .{}, claim, &.{}, .{});
    var kept = false;
    for (out.result.tracks) |t| {
        if (t.layer == 1 and t.y1 == 0.9) kept = true;
    }
    try testing.expect(kept);
}

// spec: placement/route-close - the post-route oracle gate stitches only the islands its plane or pour does not already carry
test "appendStitches skips the pour-joined island" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = threePadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "PWR", .pins = &two_pins }};
    const placement = fixturePlacement(&parts, &nets);
    var index = std.StringHashMapUnmanaged(usize).empty;
    try index.put(arena, "R1", 0);
    try index.put(arena, "R2", 1);
    const pads = [_]fab_readiness.OpenPad{
        .{ .ref = "R1", .pad = "1", .x = 0, .y = 0, .side = .top, .thru = false, .island = 0 },
        .{ .ref = "R2", .pad = "1", .x = 1, .y = 0, .side = .top, .thru = false, .island = 1 },
    };
    // R1's island already rides the pour — only R2's island needs a via.
    const joined = [_]bool{ true, false };
    const open_gaps = [_]fab_readiness.OpenGap{.{ .from = pads[0], .to = pads[1], .mm = 1 }};
    const o = fab_readiness.OpenNet{ .net = "PWR", .islands = 2, .pads = &pads, .gaps = &open_gaps, .plane_joined = &joined };
    var gaps: std.ArrayList(router.Gap) = .empty;
    try appendStitches(arena, &gaps, &index, placement, o, .{ .net_i = 0, .max_fallback_mm = 4 });
    try testing.expectEqual(@as(usize, 1), gaps.items.len);
    try testing.expectApproxEqAbs(@as(f64, 1), gaps.items[0].from.x, 1e-9);
    try testing.expect(gaps.items[0].to == null);
    try testing.expectApproxEqAbs(@as(f64, 0), gaps.items[0].stitch_fallback.?.x, 1e-9);
}

// spec: placement/route-close - the post-route oracle gate stitches every stranded island of a plane-carried net but its main body
test "appendStitches stitches every plane-joined island but the main body" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = threePadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "GND", .pins = &three_pins }};
    var placement = fixturePlacement(&parts, &nets);
    // A declared inner GND plane: a via at ANY island reaches metal the island
    // is not already on, so `plane_joined` cannot mean "already connected".
    const planes = [_]optimizer.PlaneAt{.{ .index = 2, .net = "GND" }};
    placement.rules.copper_layers = 4;
    placement.rules.planes = .{ .declared = &planes };
    const plane_names = [_][]const u8{"GND"};
    placement.rules.plane_nets = &plane_names;
    var index = std.StringHashMapUnmanaged(usize).empty;
    try index.put(arena, "R1", 0);
    try index.put(arena, "R2", 1);
    try index.put(arena, "R3", 2);
    const pads = [_]fab_readiness.OpenPad{
        .{ .ref = "R1", .pad = "1", .x = 0, .y = 0, .side = .top, .thru = false, .island = 0 },
        .{ .ref = "R2", .pad = "1", .x = 1, .y = 0, .side = .top, .thru = false, .island = 0 },
        .{ .ref = "R3", .pad = "1", .x = 6, .y = 0, .side = .top, .thru = false, .island = 1 },
    };
    // BOTH islands ride a pour — on two DISJOINT pieces of it, which is what
    // separate islands means. The two-pad body is the net's main one.
    const joined = [_]bool{ true, true };
    const open_gaps = [_]fab_readiness.OpenGap{.{ .from = pads[0], .to = pads[2], .mm = 6 }};
    const o = fab_readiness.OpenNet{ .net = "GND", .islands = 2, .pads = &pads, .gaps = &open_gaps, .plane_joined = &joined };
    var gaps: std.ArrayList(router.Gap) = .empty;
    try appendStitches(arena, &gaps, &index, placement, o, .{ .net_i = 0, .max_fallback_mm = 10 });
    try testing.expectEqual(@as(usize, 1), gaps.items.len);
    try testing.expectApproxEqAbs(@as(f64, 6), gaps.items[0].from.x, 1e-9);
    try testing.expect(gaps.items[0].to == null);
    try testing.expectApproxEqAbs(@as(f64, 0), gaps.items[0].stitch_fallback.?.x, 1e-9);
}

// spec: placement/route-close - disconnected components of the same pour are joined by a surface bridge because another stitch would land back in the same component
test "appendStitches bridges between already pour-joined islands" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = threePadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "PWR", .pins = &two_pins }};
    const placement = fixturePlacement(&parts, &nets);
    var index = std.StringHashMapUnmanaged(usize).empty;
    try index.put(arena, "R1", 0);
    try index.put(arena, "R2", 1);
    const pads = [_]fab_readiness.OpenPad{
        .{ .ref = "R1", .pad = "1", .x = 0, .y = 0, .side = .top, .thru = false, .island = 0 },
        .{ .ref = "R2", .pad = "1", .x = 1, .y = 0, .side = .top, .thru = false, .island = 1 },
    };
    const joined = [_]bool{ true, true };
    const open_gaps = [_]fab_readiness.OpenGap{.{ .from = pads[0], .to = pads[1], .mm = 1 }};
    const o = fab_readiness.OpenNet{ .net = "PWR", .islands = 2, .pads = &pads, .gaps = &open_gaps, .plane_joined = &joined };
    var gaps: std.ArrayList(router.Gap) = .empty;
    try appendStitches(arena, &gaps, &index, placement, o, .{ .net_i = 0, .max_fallback_mm = 4 });
    try testing.expectEqual(@as(usize, 1), gaps.items.len);
    try testing.expectApproxEqAbs(@as(f64, 1), gaps.items[0].from.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), gaps.items[0].to.?.x, 1e-9);
    try testing.expect(gaps.items[0].stitch_fallback == null);
}

// spec: placement/route-close - the post-route oracle gate spends its hop budget cheapest-net-first, so one net's islands cannot starve the rest
test "planned hops are ordered cheapest net first" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Net 0 asks for three hops, nets 1 and 2 for one each — the shape a
    // stranded ground plane makes against ordinary two-pad bridges.
    const planned = [_]router.Gap{
        .{ .net_i = 0, .from = .{ .x = 0, .y = 0, .layer = 0 } },
        .{ .net_i = 0, .from = .{ .x = 1, .y = 0, .layer = 0 } },
        .{ .net_i = 0, .from = .{ .x = 2, .y = 0, .layer = 0 } },
        .{ .net_i = 1, .from = .{ .x = 3, .y = 0, .layer = 0 } },
        .{ .net_i = 2, .from = .{ .x = 4, .y = 0, .layer = 0 } },
    };
    const ordered = try cheapestNetFirst(arena, &planned);
    try testing.expectEqual(planned.len, ordered.len);
    // The two one-hop nets go first — a two-hop budget then closes BOTH of them
    // instead of laying two thirds of net 0 — and net 0 keeps its run intact.
    const nets = [_]usize{ ordered[0].net_i, ordered[1].net_i, ordered[2].net_i, ordered[3].net_i, ordered[4].net_i };
    try testing.expectEqualSlices(usize, &.{ 1, 2, 0, 0, 0 }, &nets);
    try testing.expectApproxEqAbs(@as(f64, 0), ordered[2].from.x, 1e-9);

    // The key is the hop COUNT, not the run's millimetres: a net closes only
    // when every one of its hops lands, so the one-hop long shot outranks the
    // three-hop run of tiny joins. Keying millimetres was measured and reverted
    // — it promoted board-a's two many-islanded rails ahead of the short runs
    // behind them and cost three closed nets.
    const mixed = [_]router.Gap{
        .{ .net_i = 5, .from = .{ .x = 0, .y = 0, .layer = 0 }, .to = .{ .x = 40, .y = 0, .layer = 0 } },
        .{ .net_i = 6, .from = .{ .x = 0, .y = 0, .layer = 0 }, .to = .{ .x = 1.5, .y = 0, .layer = 0 } },
        .{ .net_i = 6, .from = .{ .x = 2, .y = 0, .layer = 0 }, .to = .{ .x = 3.5, .y = 0, .layer = 0 } },
        .{ .net_i = 6, .from = .{ .x = 4, .y = 0, .layer = 0 } },
    };
    const by_count = try cheapestNetFirst(arena, &mixed);
    const count_nets = [_]usize{ by_count[0].net_i, by_count[1].net_i, by_count[2].net_i, by_count[3].net_i };
    try testing.expectEqualSlices(usize, &.{ 5, 6, 6, 6 }, &count_nets);
}

/// Refuse `count` distinct hops of one net, the shape a many-islanded rail
/// makes across the passes of a route.
fn refuseDistinctHops(memo: *HopMemo, net_i: usize, count: usize) std.mem.Allocator.Error!void {
    var spent: usize = 0;
    while (spent < count) : (spent += 1) {
        try memo.refuse(.{ .net_i = net_i, .from = .{ .x = @floatFromInt(spent), .y = 0, .layer = 0 } }, false);
    }
}

// spec: placement/route-close - a net whose hops the gate has refused enough times in one route stops being planned, so a many-islanded treadmill cannot starve the nets behind it
test "a net refused enough times stops being planned by this route's gate" {
    var memo = HopMemo.init(testing.allocator);
    defer memo.deinit();
    const hop = router.Gap{ .net_i = 7, .from = .{ .x = 0, .y = 0, .layer = 0 } };
    try testing.expect(!memo.exhausted(7));
    // Each pass names fresh endpoints on a many-islanded net, so the count has
    // to rise on distinct hops, not only on repeats of one.
    try refuseDistinctHops(&memo, 7, net_refusal_cutoff);
    try testing.expect(memo.exhausted(7));
    // Its neighbours are untouched: the cutoff is per net, which is the whole
    // point — the slice goes to the nets that were being starved.
    try testing.expect(!memo.exhausted(8));
    try testing.expect(memo.seen(hop, false));
}

// spec: placement/route-close - a net the route's gate has answered terminally reads as sealed — the per-net refusal cutoff, or a hop whose gridless mesh found no channel — while a net it never planned reads as unanswered, and the shape tally is kept apart from the one that ends planning
test "a net the gate answered terminally reads as sealed" {
    var memo = HopMemo.init(testing.allocator);
    defer memo.deinit();
    // A net the gate never planned has no answer, so it is not sealed. This is
    // the case the residual's guided retry must still spend a slice on: a
    // long-hop signal `planHops` never plans has been refused nothing.
    try testing.expect(!memo.sealed(7));
    try testing.expectEqual(@as(usize, 0), memo.refusals(7));
    try testing.expectEqual(@as(usize, 0), memo.shapeRefusals(7));

    // ONE shape refusal seals a net: the gridless tier built that hop's mesh
    // over the free space and found no channel, and a net closes only when every
    // one of its hops lands.
    const hop = router.Gap{ .net_i = 7, .from = .{ .x = 0, .y = 0, .layer = 0 } };
    try memo.refuseShape(hop);
    try testing.expect(memo.sealed(7));
    try testing.expectEqual(@as(usize, 1), memo.shapeRefusals(7));
    // …and it does NOT feed the cutoff that ends the gate's own planning, so no
    // hop this route attempts moves because of it.
    try testing.expectEqual(@as(usize, 0), memo.refusals(7));
    try testing.expect(!memo.exhausted(7));

    // The other terminal answer is the ladder's per-net cutoff, on a net whose
    // shape tier was never even asked.
    try testing.expect(!memo.sealed(8));
    try refuseDistinctHops(&memo, 8, net_refusal_cutoff);
    try testing.expect(memo.sealed(8));
    try testing.expectEqual(@as(usize, 0), memo.shapeRefusals(8));
    // A net refused once is answered but not exhausted, and one refusal of one
    // hop is not a verdict about the net.
    try refuseDistinctHops(&memo, 9, 1);
    try testing.expect(!memo.sealed(9));
}

// spec: placement/route-close - a hop whose gridless shape attempt one gate pass already refused is asked of the maze alone on every later pass, at either corridor width, so the same mesh is never rebuilt for the same answer
test "a shape attempt refused once is not rebuilt at either corridor width" {
    var memo = HopMemo.init(testing.allocator);
    defer memo.deinit();
    const hop = router.Gap{
        .net_i = 3,
        .from = .{ .x = 186.58, .y = 107.30, .layer = 0 },
        .to = .{ .x = 144.05, .y = 106.15, .layer = 0 },
    };
    try testing.expect(!memo.shapeSeen(hop));
    try memo.refuseShape(hop);
    try testing.expect(memo.shapeSeen(hop));
    // The width is deliberately NOT part of the key: the ladder's last pass
    // re-plans this hop so its MAZE can search a wider corridor, and the shape
    // tier — which sizes its own window from the terminals — would otherwise
    // rebuild the identical mesh for the identical answer.
    try testing.expect(!memo.seen(hop, true));
    try testing.expect(!memo.seen(hop, false));
    // A maze refusal is not a shape refusal: only a pass that let the shape tier
    // run and got nothing may speak for it.
    const other = router.Gap{
        .net_i = 3,
        .from = .{ .x = 0, .y = 0, .layer = 0 },
        .to = .{ .x = 1, .y = 0, .layer = 0 },
    };
    try memo.refuse(other, false);
    try testing.expect(!memo.shapeSeen(other));
    // Distinct hops of one net keep distinct answers, and a repeat refusal of
    // the same hop is idempotent rather than a second entry.
    try memo.refuseShape(hop);
    try testing.expectEqual(@as(usize, 1), memo.shape_refused.items.len);
}

// spec: placement/route-close - the gate ladder's last pass lets a long island-joining hop search a corridor proportional to its own span, so a stuck bridge gets room to detour only once no other plan can be blocked by it
test "a hop's search corridor grows with the hop" {
    const stitch = router.Gap{ .net_i = 0, .from = .{ .x = 0, .y = 0, .layer = 0 } };
    // A stitch has no span at all, and a short bridge keeps the flat margin.
    try testing.expectApproxEqAbs(corridor_margin_mm, corridorMargin(stitch, true), 1e-9);
    const short = router.Gap{
        .net_i = 0,
        .from = .{ .x = 0, .y = 0, .layer = 0 },
        .to = .{ .x = 2, .y = 0, .layer = 0 },
    };
    try testing.expectApproxEqAbs(corridor_margin_mm, corridorMargin(short, true), 1e-9);
    // A 16 mm bridge gets room to go round something.
    const long = router.Gap{
        .net_i = 0,
        .from = .{ .x = 0, .y = 0, .layer = 0 },
        .to = .{ .x = 16, .y = 0, .layer = 0 },
    };
    try testing.expectApproxEqAbs(corridor_span_share * 16, corridorMargin(long, true), 1e-9);
    try testing.expect(corridorMargin(long, true) > corridor_margin_mm);
    // An ORDINARY pass keeps the cheap slot for the same hop: the detour that
    // buys a stuck bridge is copper every plan behind it would have to dodge.
    try testing.expectApproxEqAbs(corridor_margin_mm, corridorMargin(long, false), 1e-9);
    // Past the cap the long shots keep the cheap slot: their mazes have to fail
    // fast inside a pass slice rather than raster half the board.
    const far = router.Gap{
        .net_i = 0,
        .from = .{ .x = 0, .y = 0, .layer = 0 },
        .to = .{ .x = 45, .y = 0, .layer = 0 },
    };
    try testing.expectApproxEqAbs(corridor_margin_mm, corridorMargin(far, true), 1e-9);
}

// spec: placement/route-close - a hop an earlier gate pass of the same route already had refused is not planned again
test "a refused hop is not re-planned by a later gate pass of the same route" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var memo = HopMemo.init(testing.allocator);
    defer memo.deinit();
    const planned = [_]router.Gap{
        .{ .net_i = 0, .from = .{ .x = 0, .y = 0, .layer = 0 }, .to = .{ .x = 1, .y = 0, .layer = 0 } },
        .{ .net_i = 0, .from = .{ .x = 2, .y = 0, .layer = 0 }, .to = .{ .x = 3, .y = 0, .layer = 0 } },
        // A stitch keys on its fallback terminal, so two stitches beside the
        // same island stay distinguishable.
        .{ .net_i = 1, .from = .{ .x = 4, .y = 0, .layer = 0 }, .stitch_fallback = .{ .x = 5, .y = 0, .layer = 0 } },
    };
    // Nothing refused yet: the plan is handed back whole, and the same slice.
    const untouched = try withoutRefused(arena, &planned, &memo, false);
    try testing.expectEqual(planned.len, untouched.len);

    try memo.refuse(planned[1], false);
    try memo.refuse(planned[2], false);
    const kept = try withoutRefused(arena, &planned, &memo, false);
    try testing.expectEqual(@as(usize, 1), kept.len);
    try testing.expectApproxEqAbs(@as(f64, 0), kept[0].from.x, 1e-9);

    // A caller keeping no memo re-plans everything, exactly as before.
    const unmemoized = try withoutRefused(arena, &planned, null, false);
    try testing.expectEqual(planned.len, unmemoized.len);
    // A refusal in the narrow slot is not a refusal of the same hop given room:
    // the last pass re-asks it.
    const widened = try withoutRefused(arena, &planned, &memo, true);
    try testing.expectEqual(planned.len, widened.len);
}

// spec: placement/route-close - a hop on a plane- or pour-carried net is committed transactionally, while an ordinary bridge keeps the cheap additive rule
test "only a poured or planed net's hops are weighed by the oracle" {
    var parts = threePadParts();
    const nets = [_]optimizer.FlatNet{
        .{ .name = "SIG", .pins = &two_pins },
        .{ .name = "PWR", .pins = &two_pins },
    };
    const placement = fixturePlacement(&parts, &nets);
    const pours = [_]pour.UserZone{.{ .net = "PWR", .layer = 0, .poly = &.{} }};
    // An ordinary two-pad net: a maze that reached both pads produced a join or
    // it produced nothing, so "did it rip anything?" is the whole verdict.
    try testing.expect(!transactional(placement, &pours, .{ .net_i = 0, .from = .{ .x = 0, .y = 0, .layer = 0 } }));
    // The rail one of the layout's own pours carries is the one whose copper
    // can land without joining anything.
    try testing.expect(transactional(placement, &pours, .{ .net_i = 1, .from = .{ .x = 0, .y = 0, .layer = 0 } }));
    // A hop naming a net this placement does not have judges nothing.
    try testing.expect(!transactional(placement, &pours, .{ .net_i = 9, .from = .{ .x = 0, .y = 0, .layer = 0 } }));
}

// spec: placement/route-deadline - a route deadline that expires while a gate hop is routing drops that hop's copper instead of committing it
test "a hop that finished past the deadline is dropped" {
    const tracks = [_]router.Track{.{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 }};
    const landed = router.GapPath{ .tracks = &tracks };
    try testing.expect(committable(landed, false) != null);
    try testing.expect(committable(landed, true) == null);
    try testing.expect(committable(null, false) == null);
}

// spec: placement/route-close - a pour-carried net's islands are each requested as their own hop, so one leg too long for the gate never withdraws the short joins beside it
test "a poured net plans every short island hop even beside an over-ceiling one" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var parts = threePadParts();
    const nets = [_]optimizer.FlatNet{.{ .name = "PWR", .pins = &three_pins }};
    const placement = fixturePlacement(&parts, &nets);
    var index = std.StringHashMapUnmanaged(usize).empty;
    try index.put(arena, "R1", 0);
    try index.put(arena, "R2", 1);
    try index.put(arena, "R3", 2);
    const pads = [_]fab_readiness.OpenPad{
        .{ .ref = "R1", .pad = "1", .x = 0, .y = 0, .side = .top, .thru = false, .island = 0 },
        .{ .ref = "R2", .pad = "1", .x = 1, .y = 0, .side = .top, .thru = false, .island = 1 },
        .{ .ref = "R3", .pad = "1", .x = 6, .y = 0, .side = .top, .thru = false, .island = 2 },
    };
    // R1↔R2 is 1 mm; R2↔R3 is 5 mm, past a 4 mm ceiling. The non-poured branch
    // withdraws such a net entirely; a poured rail keeps the join it can make.
    const open_gaps = [_]fab_readiness.OpenGap{
        .{ .from = pads[0], .to = pads[1], .mm = 1 },
        .{ .from = pads[1], .to = pads[2], .mm = 5 },
    };
    const joined = [_]bool{ false, false, false };
    const o = fab_readiness.OpenNet{ .net = "PWR", .islands = 3, .pads = &pads, .gaps = &open_gaps, .plane_joined = &joined };
    var gaps: std.ArrayList(router.Gap) = .empty;
    try appendBridges(arena, &gaps, &index, placement, o, .{ .net_i = 0, .max_fallback_mm = 4 });
    try testing.expectEqual(@as(usize, 1), gaps.items.len);
    try testing.expect(gaps.items[0].to != null);
    try testing.expectApproxEqAbs(@as(f64, 0), gaps.items[0].from.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1), gaps.items[0].to.?.x, 1e-9);
}

// spec: placement/route-close - a bounded gate attempts only whole net runs so its last budget slots never buy copper that cannot change a routed tally
test "hop budget ends before a partial net run" {
    const planned = [_]router.Gap{
        .{ .net_i = 1, .from = .{ .x = 0, .y = 0, .layer = 0 } },
        .{ .net_i = 2, .from = .{ .x = 1, .y = 0, .layer = 0 } },
        .{ .net_i = 2, .from = .{ .x = 2, .y = 0, .layer = 0 } },
        .{ .net_i = 2, .from = .{ .x = 3, .y = 0, .layer = 0 } },
    };
    try testing.expectEqual(@as(usize, 1), wholeNetPrefixLen(&planned, 3));
    try testing.expectEqual(@as(usize, 4), wholeNetPrefixLen(&planned, 4));
}
