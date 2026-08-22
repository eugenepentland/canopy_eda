//! Interactive routing sessions — a pausable driver around the maze router.
//!
//! `RouteSession` runs the WHOLE standard pipeline first (plane vias, the greedy
//! maze pass, and every bounded rip-up round — the router exhausts its own
//! tricks via `router.routeCoreStart`). The nets still failed after that become
//! an interactive queue, presented ONE AT A TIME as `StuckReport` stuck-points.
//! A human applies a `Hint` (a corridor of waypoints, a forced rip of blocking
//! nets, a queue reorder, an allowed-layer override, or an outright abandon),
//! which is recorded and then consumed by the next `runUntilEvent`: the stuck
//! net is retried immediately (with any hinted rips/reorders), and either pops
//! (routed) so the next failure is presented, or is presented again with a
//! fresh frontier and a bumped attempt count. When the queue empties (or every
//! remaining net is abandoned) the finish passes run ONCE via
//! `RouteCore.finish` and the session is `done`.
//!
//! The session OWNS its own arena, so its state survives across HTTP requests —
//! it must not be built in a request arena. The `placement` and the non-`net`
//! slices of `options` are BORROWED (`start` dupes only `selected_nets` and the
//! per-net policy it must patch for hints); the caller must keep that backing
//! memory — and the `placement` — alive for the session's lifetime (allocate
//! them in a session-scoped arena, not the request arena).
//!
//! Hints lower onto the router's existing machinery, never new routing code:
//! a corridor becomes the waypoint policy `(pcb-plan (route (wave …)))` lowers
//! to, a layer override becomes the allowed-layers mask, a rip drives the
//! rip-up `ripNet` path, and a reorder is a queue move. The retry itself is the
//! same per-net maze call the greedy pass and rip-up use (`router.rerouteNet`,
//! with escape / direct-synthesis rescue intact). The frontier snapshot re-runs
//! a bounded reachability flood from the stuck net's first pad over the router's
//! own hard cost model (`router.blocked`), so it shows exactly what the search
//! pressed against; blocked cells are attributed to the owning net via the
//! occupancy grid the rip-up cost machinery already maintains.

const std = @import("std");
const router = @import("router.zig");
const optimizer = @import("optimizer.zig");
const route_policy = @import("route_policy.zig");
const geometry = @import("geometry.zig");
const flat_netlist = @import("../flat_netlist.zig");

const Allocator = std.mem.Allocator;
const RouteRun = router.RouteRun;

/// Empty-cell sentinel in the router's occupancy/reservation grids (mirrors the
/// router's private `empty_cell`).
const empty_cell: i32 = -1;
/// Reachability-flood expansion budget for one frontier snapshot — bounds the
/// picture on a huge board (a tiny module stays far under it).
const frontier_flood_cap: usize = 20_000;
/// Cells of slack added around the reached region so the frontier shows the
/// copper/clearance the search pressed against, not just the reached interior.
const frontier_margin_cells: usize = 3;
/// Cap on the frontier grid's larger dimension; a bigger crop downsamples (and
/// records the effective `cell_mm`) so the snapshot stays a bounded payload.
const frontier_max_cells: usize = 200;
/// Cap on how many ranked blockers a stuck report carries.
const frontier_max_blockers: usize = 16;

const empty_result = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 };
const empty_run = RouteRun{ .routed = empty_result, .timeline = &.{} };

/// A signal-layer bitset (bit L = layer L), the allowed-layers spelling shared
/// with `route_policy.NetPolicy.allowed_layers`.
pub const LayerMask = u64;

/// A world-space guide point a corridor hint asks the retry to pass near.
pub const Waypoint = struct { x: f64, y: f64 };

/// One net whose copper the stuck net's search pressed against. `share` is the
/// fraction of the frontier's blocked-copper cells this net owns; `rip_cost` is
/// how much routed copper (mm) a rip would discard.
pub const Blocker = struct { net_i: usize, share: f32, rip_cost: f32 };

/// A cropped, downsampled snapshot of the stuck net's search frontier. `cells`
/// is row-major `rows × cols` at `cell_mm` pitch anchored at `origin`; a value
/// is 0 unvisited, 1 reached-by-search, 2 blocked-by-copper, 3 blocked-by-clearance.
pub const Frontier = struct {
    origin: [2]f64,
    cell_mm: f64,
    cols: u32,
    rows: u32,
    cells: []const u2,
};

/// The evidence bundle for one presented stuck-point. `occupancy` holds one
/// grid per signal layer over the SAME crop window as `frontier` (same origin,
/// cell_mm, cols, rows): a cell is 0 free, 1 this-net copper, 2 foreign copper,
/// 3 blocked-otherwise (clearance halo / keepout / board edge) — the router's
/// raw grid truth, so a human can see exactly why a region reads as blocked.
pub const StuckReport = struct {
    net_i: usize,
    attempts: u32,
    pads: []const [2]f64,
    frontier: Frontier,
    occupancy: []const []const u2,
    blockers: []const Blocker,
    layer_occupancy: []const f32,
};

/// Terminal outcome once the interactive queue empties (or every remaining net
/// is abandoned) and the finish passes have run.
pub const Summary = struct {
    routed: usize,
    total: usize,
    failed: []const usize,
    abandoned: []const usize,
    trace_mm: f64,
};

/// What `runUntilEvent` returns: a stuck net awaiting a hint, the finished
/// summary, or an aborted run (the grid was empty or overflowed, so no
/// interactive routing was possible).
pub const Status = union(enum) { stuck: StuckReport, done: Summary, aborted };

/// A human's steer on the current stuck net (or a queued one).
pub const Hint = union(enum) {
    /// Waypoints the retry must pass near (lowered via the waypoint policy).
    corridor: struct { net_i: usize, points: []const Waypoint },
    /// Force-rip these nets before retrying the stuck net; ripped nets rejoin
    /// the retry queue after it.
    rip: struct { nets: []const usize },
    /// Pull this queued net to the front so it is retried next.
    route_now: struct { net_i: usize },
    /// Allowed-layers override for the retry.
    layers: struct { net_i: usize, allowed: LayerMask },
    /// Give up on this net and move on.
    abandon: struct { net_i: usize },
};

/// Borrowed inputs plus the mutable per-net policy the session patches for
/// corridor / layer hints (kept in sync with `ctx.net_policy`).
const Input = struct {
    placement: *const optimizer.Placement,
    params: router.RouteParams,
    options: route_policy.Options,
    net_policy: []route_policy.NetPolicy = &.{},
};

/// The interactive queue and its per-net bookkeeping. `items[0]` is the current
/// stuck net; `staged_rips` holds forced rips awaiting the next retry.
const Queue = struct {
    items: std.ArrayList(usize) = .empty,
    attempts: std.AutoHashMapUnmanaged(usize, u32) = .empty,
    abandoned: std.ArrayList(usize) = .empty,
    staged_rips: std.ArrayList(usize) = .empty,
    retry_pending: bool = false,
};

const Phase = enum { unstarted, presenting, done, aborted };

/// Phase plus the last-built view of the run (copper + timeline) for streaming.
const View = struct {
    phase: Phase = .unstarted,
    run: RouteRun = empty_run,
};

/// A pausable interactive routing session. Owns its arena; state survives
/// across requests. See the module header for the pause/retry contract.
pub const RouteSession = struct {
    gpa: Allocator,
    arena_state: std.heap.ArenaAllocator,
    input: Input,
    core: ?router.RouteCore = null,
    queue: Queue = .{},
    hints: std.ArrayList(Hint) = .empty,
    view: View = .{},

    fn arena(self: *RouteSession) Allocator {
        return self.arena_state.allocator();
    }

    /// Begin a session over `placement` with the given routing params/options.
    /// Nothing routes yet — the first `runUntilEvent` runs the standard
    /// pipeline. The caller owns `placement` and `options`' non-`net` backing
    /// (see the module header) and must free the session with `deinit`.
    pub fn start(
        gpa: Allocator,
        placement: *const optimizer.Placement,
        params: router.RouteParams,
        options: route_policy.Options,
    ) Allocator.Error!*RouteSession {
        const self = try gpa.create(RouteSession);
        errdefer gpa.destroy(self);
        self.* = .{
            .gpa = gpa,
            .arena_state = std.heap.ArenaAllocator.init(gpa),
            .input = .{ .placement = placement, .params = params, .options = options },
        };
        errdefer self.arena_state.deinit();
        try self.adoptOptions();
        return self;
    }

    /// Copy the hint-mutable inputs into the session arena: a per-net policy
    /// padded to `nets.len` (the patch target for corridor/layer hints, which
    /// `ctx.net_policy` then aliases) and `selected_nets`. Padding with default
    /// `NetPolicy{}` for absent entries is behaviour-neutral versus a shorter
    /// slice, so the standard pipeline routes identically.
    fn adoptOptions(self: *RouteSession) Allocator.Error!void {
        const a = self.arena();
        const n = self.input.placement.nets.len;
        const np = try a.alloc(route_policy.NetPolicy, n);
        for (np, 0..) |*p, i| p.* = if (i < self.input.options.net.len) self.input.options.net[i] else .{};
        self.input.net_policy = np;
        self.input.options.net = np;
        if (self.input.options.selected_nets.len > 0)
            self.input.options.selected_nets = try a.dupe(bool, self.input.options.selected_nets);
    }

    /// Free the session and everything it allocated.
    pub fn deinit(self: *RouteSession) void {
        self.arena_state.deinit();
        self.gpa.destroy(self);
    }

    /// Advance the session by one event. The first call runs the full standard
    /// pipeline and presents the first still-failed net (or finishes when none
    /// failed); later calls consume any applied hint to retry the current stuck
    /// net, then present the next failure or the final summary.
    pub fn runUntilEvent(self: *RouteSession) Allocator.Error!Status {
        return switch (self.view.phase) {
            .unstarted => self.startPipeline(),
            .presenting => self.advance(),
            .done => .{ .done = try self.summary() },
            .aborted => .aborted,
        };
    }

    /// Record `hint` (into the accepted-hints log and the timeline) and stage
    /// its effect. The retry itself happens on the next `runUntilEvent`.
    pub fn applyHint(self: *RouteSession, hint: Hint) Allocator.Error!void {
        const stored = try self.dupeHint(hint);
        try self.hints.append(self.arena(), stored);
        if (self.core) |core| {
            try core.recordSessionEvent(.hint_applied, hintNet(stored), try self.describe(stored));
        }
        try self.dispatchHint(stored);
        if (self.core != null) try self.refreshRunView();
    }

    /// The live run so far (copper + timeline) for streaming to the page, or the
    /// final run once the session is done/aborted.
    pub fn currentRun(self: *const RouteSession) *const RouteRun {
        return &self.view.run;
    }

    /// The hints applied so far, in order — for `(pcb-plan)` distillation.
    pub fn acceptedHints(self: *const RouteSession) []const Hint {
        return self.hints.items;
    }

    // ── Pipeline & queue ─────────────────────────────────────────────────────

    fn startPipeline(self: *RouteSession) Allocator.Error!Status {
        const outcome = try router.routeCoreStart(
            self.arena(),
            self.input.placement.*,
            self.input.params,
            self.input.options,
            .on,
        );
        // An empty/overflowed grid yields no resumable state: report aborted.
        // (Tag-checked rather than switched so the `CoreOutcome` prong-switch
        // lives only in the router, keeping the pair out of a second file.)
        if (std.meta.activeTag(outcome) == .done) {
            self.view = .{ .phase = .aborted, .run = outcome.done };
            return .aborted;
        }
        self.core = outcome.core;
        try self.buildQueue();
        self.view.phase = .presenting;
        return self.presentOrFinish();
    }

    fn buildQueue(self: *RouteSession) Allocator.Error!void {
        const core = &self.core.?;
        for (core.result.routable) |rn| {
            if (!rn.ok) try self.queue.items.append(self.arena(), rn.net_i);
        }
    }

    fn presentOrFinish(self: *RouteSession) Allocator.Error!Status {
        if (self.currentNet()) |net_i| {
            const report = try self.presentNet(net_i);
            try self.refreshRunView();
            return .{ .stuck = report };
        }
        return self.finishSession();
    }

    /// Record a `stuck` timeline decision for `net_i` and build its report.
    /// The first presentation seeds the attempt count at 1 (the pipeline's own
    /// automatic attempt); a re-presentation after a failed retry reflects the
    /// already-bumped count.
    fn presentNet(self: *RouteSession, net_i: usize) Allocator.Error!StuckReport {
        if (self.attemptsOf(net_i) == 0) try self.setAttempts(net_i, 1);
        try self.core.?.recordSessionEvent(.stuck, net_i, "");
        return self.captureFrontier(net_i, self.attemptsOf(net_i));
    }

    /// One interactive step after the first present: consume the pending hint,
    /// retry the current stuck net first, then reroute forced-rip nets and
    /// present the next failure. With no hint pending the current net is simply
    /// re-presented (an abandon-only step advances the queue instead).
    fn advance(self: *RouteSession) Allocator.Error!Status {
        if (self.currentNet() == null) return self.finishSession();
        if (!self.queue.retry_pending) return self.presentOrFinish();
        self.queue.retry_pending = false;
        const ripped = try self.takeStagedRips();
        if (self.currentNet() == null) return self.finishSession();
        const target = self.currentNet().?;
        const target_ok = try self.retry(target);
        if (target_ok) try self.popRouted(target);
        for (ripped) |net_i| {
            if (!try self.retry(net_i)) try self.enqueue(net_i);
        }
        if (target_ok) return self.presentOrFinish();
        const report = try self.presentNet(target);
        try self.refreshRunView();
        return .{ .stuck = report };
    }

    fn finishSession(self: *RouteSession) Allocator.Error!Status {
        const run = try self.core.?.finish();
        self.view = .{ .phase = .done, .run = run };
        return .{ .done = try self.summary() };
    }

    /// Retry one net with the current (possibly hint-patched) policy — the same
    /// per-net maze call the greedy pass and rip-up use. Rips any stale copper
    /// first (a no-op for a failed net), reroutes into `core.routable`, bumps
    /// its attempt count, and reports whether it routed.
    fn retry(self: *RouteSession, net_i: usize) Allocator.Error!bool {
        const core = &self.core.?;
        router.ripNet(core.ctx, core.tracks, core.vias, net_i);
        const rn = self.findRoutable(net_i) orelse return false;
        rn.ok = false;
        try router.rerouteNet(core.ctx, self.input.placement.*, core.idx_of, rn, core.tracks, core.vias);
        try self.setAttempts(net_i, self.attemptsOf(net_i) + 1);
        return rn.ok;
    }

    /// Rip the staged forced-rip nets off the board, mark them unrouted, and
    /// return their indices; `advance` reroutes them after the rescued net.
    fn takeStagedRips(self: *RouteSession) Allocator.Error![]const usize {
        const core = &self.core.?;
        for (self.queue.staged_rips.items) |net_i| {
            router.ripNet(core.ctx, core.tracks, core.vias, net_i);
            if (self.findRoutable(net_i)) |rn| rn.ok = false;
            self.removeFromQueue(net_i);
        }
        const ripped = try self.arena().dupe(usize, self.queue.staged_rips.items);
        self.queue.staged_rips.clearRetainingCapacity();
        return ripped;
    }

    // ── Hint handling ────────────────────────────────────────────────────────

    fn dispatchHint(self: *RouteSession, hint: Hint) Allocator.Error!void {
        switch (hint) {
            .corridor => |c| {
                try self.setWaypoints(c.net_i, c.points);
                self.queue.retry_pending = true;
            },
            .layers => |l| {
                if (l.net_i < self.input.net_policy.len)
                    self.input.net_policy[l.net_i].allowed_layers = l.allowed;
                self.queue.retry_pending = true;
            },
            .rip => |r| {
                try self.queue.staged_rips.appendSlice(self.arena(), r.nets);
                self.queue.retry_pending = true;
            },
            .route_now => |r| {
                try self.moveToFront(r.net_i);
                self.queue.retry_pending = true;
            },
            .abandon => |a| try self.abandon(a.net_i),
        }
    }

    fn setWaypoints(self: *RouteSession, net_i: usize, points: []const Waypoint) Allocator.Error!void {
        if (net_i >= self.input.net_policy.len) return;
        const layer = self.netFirstLayer(net_i);
        const wp = try self.arena().alloc(route_policy.Waypoint, points.len);
        for (wp, points) |*w, p| w.* = .{ .x = p.x, .y = p.y, .layer = layer };
        self.input.net_policy[net_i].waypoints = wp;
    }

    fn netFirstLayer(self: *RouteSession, net_i: usize) u8 {
        const core = self.core orelse return 0;
        if (net_i >= self.input.placement.nets.len) return 0;
        const net = self.input.placement.nets[net_i];
        const pts = router.netPoints(self.arena(), self.input.placement.*, core.idx_of, net) catch return 0;
        return if (pts.len > 0) pts[0].layer else 0;
    }

    fn abandon(self: *RouteSession, net_i: usize) Allocator.Error!void {
        self.removeFromQueue(net_i);
        for (self.queue.abandoned.items) |a| if (a == net_i) return;
        try self.queue.abandoned.append(self.arena(), net_i);
    }

    fn dupeHint(self: *RouteSession, hint: Hint) Allocator.Error!Hint {
        const a = self.arena();
        return switch (hint) {
            .corridor => |c| .{ .corridor = .{ .net_i = c.net_i, .points = try a.dupe(Waypoint, c.points) } },
            .rip => |r| .{ .rip = .{ .nets = try a.dupe(usize, r.nets) } },
            else => hint,
        };
    }

    fn describe(self: *RouteSession, hint: Hint) Allocator.Error![]const u8 {
        const a = self.arena();
        return switch (hint) {
            .corridor => |c| std.fmt.allocPrint(a, "corridor net {d} ({d} pts)", .{ c.net_i, c.points.len }),
            .rip => |r| std.fmt.allocPrint(a, "rip {d} net(s)", .{r.nets.len}),
            .route_now => |r| std.fmt.allocPrint(a, "route-now net {d}", .{r.net_i}),
            .layers => |l| std.fmt.allocPrint(a, "layers net {d} mask 0x{x}", .{ l.net_i, l.allowed }),
            .abandon => |ab| std.fmt.allocPrint(a, "abandon net {d}", .{ab.net_i}),
        };
    }

    // ── Small queue / bookkeeping helpers ────────────────────────────────────

    fn currentNet(self: *RouteSession) ?usize {
        return if (self.queue.items.items.len > 0) self.queue.items.items[0] else null;
    }

    fn attemptsOf(self: *RouteSession, net_i: usize) u32 {
        return self.queue.attempts.get(net_i) orelse 0;
    }

    fn setAttempts(self: *RouteSession, net_i: usize, v: u32) Allocator.Error!void {
        try self.queue.attempts.put(self.arena(), net_i, v);
    }

    fn findRoutable(self: *RouteSession, net_i: usize) ?*router.RipNet {
        for (self.core.?.result.routable) |*rn| {
            if (rn.net_i == net_i) return rn;
        }
        return null;
    }

    fn queueIndex(self: *RouteSession, net_i: usize) ?usize {
        for (self.queue.items.items, 0..) |v, i| {
            if (v == net_i) return i;
        }
        return null;
    }

    fn removeFromQueue(self: *RouteSession, net_i: usize) void {
        if (self.queueIndex(net_i)) |i| _ = self.queue.items.orderedRemove(i);
    }

    fn popRouted(self: *RouteSession, net_i: usize) Allocator.Error!void {
        self.removeFromQueue(net_i);
    }

    fn enqueue(self: *RouteSession, net_i: usize) Allocator.Error!void {
        if (self.queueIndex(net_i) != null) return;
        for (self.queue.abandoned.items) |a| if (a == net_i) return;
        try self.queue.items.append(self.arena(), net_i);
    }

    fn moveToFront(self: *RouteSession, net_i: usize) Allocator.Error!void {
        const i = self.queueIndex(net_i) orelse return;
        const v = self.queue.items.orderedRemove(i);
        try self.queue.items.insert(self.arena(), 0, v);
    }

    fn summary(self: *RouteSession) Allocator.Error!Summary {
        const a = self.arena();
        var failed: std.ArrayList(usize) = .empty;
        if (self.core) |core| {
            for (core.result.routable) |rn| {
                if (!rn.ok and !self.isAbandoned(rn.net_i)) try failed.append(a, rn.net_i);
            }
        }
        return .{
            .routed = self.view.run.routed.routed,
            .total = self.view.run.routed.total,
            .failed = failed.items,
            .abandoned = try a.dupe(usize, self.queue.abandoned.items),
            .trace_mm = traceMm(self.view.run.routed.tracks),
        };
    }

    fn isAbandoned(self: *RouteSession, net_i: usize) bool {
        for (self.queue.abandoned.items) |a| if (a == net_i) return true;
        return false;
    }

    /// Rebuild `view.run` as an arena-stable snapshot of the live copper +
    /// timeline, so `currentRun` (const) can hand back a valid pointer.
    fn refreshRunView(self: *RouteSession) Allocator.Error!void {
        const core = &self.core.?;
        const a = self.arena();
        var routed: usize = core.progress.plane_routed;
        for (core.result.routable) |rn| {
            if (rn.ok) routed += 1;
        }
        self.view.run = .{
            .routed = .{
                .tracks = try a.dupe(router.Track, core.tracks.items),
                .vias = try a.dupe(router.Via, core.vias.items),
                .routed = routed,
                .total = core.progress.total,
                .grid_scale = core.result.grid_scale,
                .ripup_rounds = core.result.ripup_rounds,
            },
            .timeline = try a.dupe(router.RouteEvent, core.progress.timeline.events.items),
        };
    }

    // ── Frontier capture ─────────────────────────────────────────────────────

    /// Build the stuck report for `net_i`: its pads, a cropped/downsampled
    /// search-frontier snapshot, the ranked blockers, and per-layer occupancy.
    fn captureFrontier(self: *RouteSession, net_i: usize, attempts: u32) Allocator.Error!StuckReport {
        const a = self.arena();
        const core = &self.core.?;
        const ctx = core.ctx;
        router.setNetParams(ctx, self.input.placement.*, net_i);
        const ni: i32 = @intCast(net_i);
        const pts = try router.netPoints(a, self.input.placement.*, core.idx_of, self.input.placement.nets[net_i]);
        const pads = try a.alloc([2]f64, pts.len);
        for (pads, pts) |*pad, p| pad.* = .{ p.x, p.y };
        if (pts.len < 2) return .{
            .net_i = net_i,
            .attempts = attempts,
            .pads = pads,
            .frontier = .{ .origin = .{ 0, 0 }, .cell_mm = ctx.grid.g, .cols = 0, .rows = 0, .cells = &.{} },
            .occupancy = &.{},
            .blockers = &.{},
            .layer_occupancy = &.{},
        };

        const flood = try self.floodReachable(ni, pts[0]);
        const crop = makeCrop(ctx.grid, flood.box, pads);
        const nodes = ctx.grid.nx * ctx.grid.ny;
        const n_layers = ctx.occ.len;
        const ds_cols = ceilDiv(crop.native_cols, crop.factor);
        const ds_rows = ceilDiv(crop.native_rows, crop.factor);
        const cells = try a.alloc(u2, ds_cols * ds_rows);
        @memset(cells, 0);
        var blockers = std.AutoHashMapUnmanaged(i32, u32).empty;
        const in = FrontierIn{
            .core = core,
            .ni = ni,
            .reached = flood.reached,
            .crop = crop,
            .nodes = nodes,
            .n_layers = n_layers,
            .grid = ctx.grid,
        };
        const total_copper = try fillCells(in, cells, &blockers, a);
        return .{
            .net_i = net_i,
            .attempts = attempts,
            .pads = pads,
            .frontier = .{
                .origin = crop.origin(ctx.grid),
                .cell_mm = ctx.grid.g * @as(f64, @floatFromInt(crop.factor)),
                .cols = @intCast(ds_cols),
                .rows = @intCast(ds_rows),
                .cells = cells,
            },
            .occupancy = try buildOccupancy(in, a),
            .blockers = try self.rankBlockers(&blockers, total_copper),
            .layer_occupancy = try self.computeLayerOcc(in),
        };
    }

    fn floodReachable(self: *RouteSession, ni: i32, seed: router.NetPt) Allocator.Error!Flood {
        const a = self.arena();
        const core = &self.core.?;
        const ctx = core.ctx;
        const grid = ctx.grid;
        const nodes = grid.nx * grid.ny;
        var f = Flooder{
            .core = core,
            .ni = ni,
            .reached = try a.alloc(bool, ctx.occ.len * nodes),
            .queue = .empty,
            .arena = a,
            .grid = grid,
            .nodes = nodes,
        };
        @memset(f.reached, false);
        const s = grid.nearest(seed.x, seed.y);
        const start_key = @as(usize, seed.layer) * nodes + grid.node(s[0], s[1]);
        f.reached[start_key] = true;
        try f.queue.append(a, start_key);
        var box = BBox.init(s[0], s[1]);
        var head: usize = 0;
        var expansions: usize = 0;
        while (head < f.queue.items.len and expansions < frontier_flood_cap) : (head += 1) {
            expansions += 1;
            const key = f.queue.items[head];
            const layer = key / nodes;
            const n = key % nodes;
            const ix = n % grid.nx;
            const iy = n / grid.nx;
            box.include(ix, iy);
            try f.expand(layer, ix, iy);
        }
        return .{ .reached = f.reached, .box = box };
    }

    fn rankBlockers(
        self: *RouteSession,
        blockers: *std.AutoHashMapUnmanaged(i32, u32),
        total_copper: usize,
    ) Allocator.Error![]const Blocker {
        const a = self.arena();
        const core = &self.core.?;
        var list: std.ArrayList(Blocker) = .empty;
        var it = blockers.iterator();
        while (it.next()) |e| {
            if (e.key_ptr.* < 0) continue;
            const share: f32 = if (total_copper == 0) 0 else @as(f32, @floatFromInt(e.value_ptr.*)) /
                @as(f32, @floatFromInt(total_copper));
            try list.append(a, .{
                .net_i = @intCast(e.key_ptr.*),
                .share = share,
                .rip_cost = @floatCast(traceMmForNet(core.tracks.items, e.key_ptr.*)),
            });
        }
        std.sort.pdq(Blocker, list.items, {}, blockerMoreShare);
        if (list.items.len > frontier_max_blockers) list.shrinkRetainingCapacity(frontier_max_blockers);
        return list.items;
    }

    fn computeLayerOcc(self: *RouteSession, in: FrontierIn) Allocator.Error![]const f32 {
        const occ = try self.arena().alloc(f32, in.n_layers);
        const total = in.crop.native_cols * in.crop.native_rows;
        for (occ, 0..) |*o, layer| {
            var blocked: usize = 0;
            for (0..in.crop.native_rows) |ry| {
                for (0..in.crop.native_cols) |rx| {
                    const node = (in.crop.min_iy + ry) * in.grid.nx + (in.crop.min_ix + rx);
                    if (router.blocked(in.core.ctx, layer, node, in.ni)) blocked += 1;
                }
            }
            o.* = if (total == 0) 0 else @as(f32, @floatFromInt(blocked)) / @as(f32, @floatFromInt(total));
        }
        return occ;
    }
};

// ── Frontier flood / classify support ────────────────────────────────────────

/// A reachability-flood result: the per-key reached bitset and the reached
/// region's grid-cell bounding box.
const Flood = struct {
    reached: []const bool,
    box: BBox,
};

/// The reached region's integer cell bounds (inclusive).
const BBox = struct {
    min_ix: usize,
    min_iy: usize,
    max_ix: usize,
    max_iy: usize,

    fn init(ix: usize, iy: usize) BBox {
        return .{ .min_ix = ix, .min_iy = iy, .max_ix = ix, .max_iy = iy };
    }

    fn include(self: *BBox, ix: usize, iy: usize) void {
        self.min_ix = @min(self.min_ix, ix);
        self.min_iy = @min(self.min_iy, iy);
        self.max_ix = @max(self.max_ix, ix);
        self.max_iy = @max(self.max_iy, iy);
    }
};

/// Working state for one reachability flood over the router's hard cost model.
const Flooder = struct {
    core: *const router.RouteCore,
    ni: i32,
    reached: []bool,
    queue: std.ArrayList(usize),
    arena: Allocator,
    grid: router.Grid,
    nodes: usize,

    /// Enqueue every free neighbour of `(layer, ix, iy)` — 8 same-layer steps
    /// plus a via to each other signal layer.
    fn expand(self: *Flooder, layer: usize, ix: usize, iy: usize) Allocator.Error!void {
        try self.reachDelta(layer, ix, iy, 1, 0);
        try self.reachDelta(layer, ix, iy, -1, 0);
        try self.reachDelta(layer, ix, iy, 0, 1);
        try self.reachDelta(layer, ix, iy, 0, -1);
        try self.reachDelta(layer, ix, iy, 1, 1);
        try self.reachDelta(layer, ix, iy, 1, -1);
        try self.reachDelta(layer, ix, iy, -1, 1);
        try self.reachDelta(layer, ix, iy, -1, -1);
        const n = iy * self.grid.nx + ix;
        for (0..self.core.ctx.occ.len) |l2| {
            if (l2 != layer) try self.reach(l2, n);
        }
    }

    fn reachDelta(self: *Flooder, layer: usize, ix: usize, iy: usize, dx: i64, dy: i64) Allocator.Error!void {
        const tx = @as(i64, @intCast(ix)) + dx;
        const ty = @as(i64, @intCast(iy)) + dy;
        if (tx < 0 or ty < 0 or tx >= self.grid.nx or ty >= self.grid.ny) return;
        try self.reach(layer, @as(usize, @intCast(ty)) * self.grid.nx + @as(usize, @intCast(tx)));
    }

    fn reach(self: *Flooder, layer: usize, n: usize) Allocator.Error!void {
        const key = layer * self.nodes + n;
        if (self.reached[key]) return;
        if (router.blocked(self.core.ctx, layer, n, self.ni)) return;
        self.reached[key] = true;
        try self.queue.append(self.arena, key);
    }
};

/// The downsampled crop over which the frontier grid is built. `native_*` are
/// the pre-downsample cell counts; the visible grid is `native/factor` cells.
const Crop = struct {
    min_ix: usize,
    min_iy: usize,
    native_cols: usize,
    native_rows: usize,
    factor: usize,

    fn origin(self: Crop, grid: router.Grid) [2]f64 {
        return .{ grid.worldX(self.min_ix), grid.worldY(self.min_iy) };
    }
};

/// Immutable inputs shared by the frontier's classify passes.
const FrontierIn = struct {
    core: *const router.RouteCore,
    ni: i32,
    reached: []const bool,
    crop: Crop,
    nodes: usize,
    n_layers: usize,
    grid: router.Grid,
};

/// Classification of one collapsed (all-layer) grid cell.
const CellClass = struct { class: u2, owner: i32 };

fn makeCrop(grid: router.Grid, box: BBox, pads: []const [2]f64) Crop {
    var b = box;
    for (pads) |p| {
        const nd = grid.nearest(p[0], p[1]);
        b.include(nd[0], nd[1]);
    }
    const min_ix = b.min_ix -| frontier_margin_cells;
    const min_iy = b.min_iy -| frontier_margin_cells;
    const max_ix = @min(grid.nx - 1, b.max_ix + frontier_margin_cells);
    const max_iy = @min(grid.ny - 1, b.max_iy + frontier_margin_cells);
    const native_cols = max_ix - min_ix + 1;
    const native_rows = max_iy - min_iy + 1;
    const factor = @max(1, ceilDiv(@max(native_cols, native_rows), frontier_max_cells));
    return .{
        .min_ix = min_ix,
        .min_iy = min_iy,
        .native_cols = native_cols,
        .native_rows = native_rows,
        .factor = factor,
    };
}

/// Classify every native cell of the crop into `cells` (downsampled, priority
/// merged) and tally blocked-by-copper cells per owning net into `blockers`.
/// Returns the total blocked-by-copper cell count (the `share` denominator).
fn fillCells(
    in: FrontierIn,
    cells: []u2,
    blockers: *std.AutoHashMapUnmanaged(i32, u32),
    arena: Allocator,
) Allocator.Error!usize {
    const ds_cols = ceilDiv(in.crop.native_cols, in.crop.factor);
    var total_copper: usize = 0;
    for (0..in.crop.native_rows) |ry| {
        for (0..in.crop.native_cols) |rx| {
            const node = (in.crop.min_iy + ry) * in.grid.nx + (in.crop.min_ix + rx);
            const cc = classifyCell(in, node);
            const ds_idx = (ry / in.crop.factor) * ds_cols + (rx / in.crop.factor);
            cells[ds_idx] = mergeClass(cells[ds_idx], cc.class);
            if (cc.class == 2 and cc.owner >= 0) {
                total_copper += 1;
                const gop = try blockers.getOrPut(arena, cc.owner);
                gop.value_ptr.* = (if (gop.found_existing) gop.value_ptr.* else 0) + 1;
            }
        }
    }
    return total_copper;
}

fn classifyCell(in: FrontierIn, node: usize) CellClass {
    var reached_any = false;
    var copper = false;
    var clear = false;
    var owner: i32 = empty_cell;
    for (0..in.n_layers) |l| {
        if (in.reached[l * in.nodes + node]) {
            reached_any = true;
            continue;
        }
        const o = in.core.ctx.occ[l][node];
        const rv = in.core.ctx.resv[l][node];
        const foreign_occ = o != empty_cell and o != in.ni;
        const foreign_resv = rv != empty_cell and rv != in.ni;
        if (foreign_occ or foreign_resv) {
            copper = true;
            if (owner < 0) owner = if (foreign_occ) o else rv;
        } else if (router.blocked(in.core.ctx, l, node, in.ni)) {
            clear = true;
        }
    }
    const class: u2 = if (reached_any) 1 else if (copper) 2 else if (clear) 3 else 0;
    return .{ .class = class, .owner = owner };
}

/// One occupancy grid per signal layer over the frontier crop, downsampled to
/// the same cols×rows: 0 free, 1 own copper, 2 foreign copper, 3 blocked-
/// otherwise. Unlike the frontier this ignores the flood entirely — it is the
/// router's raw per-layer grid state, the "why is this region blocked" view.
fn buildOccupancy(in: FrontierIn, arena: Allocator) Allocator.Error![]const []const u2 {
    const ds_cols = ceilDiv(in.crop.native_cols, in.crop.factor);
    const ds_rows = ceilDiv(in.crop.native_rows, in.crop.factor);
    const grids = try arena.alloc([]const u2, in.n_layers);
    for (grids, 0..) |*grid, layer| {
        const cells = try arena.alloc(u2, ds_cols * ds_rows);
        @memset(cells, 0);
        for (0..in.crop.native_rows) |ry| {
            for (0..in.crop.native_cols) |rx| {
                const node = (in.crop.min_iy + ry) * in.grid.nx + (in.crop.min_ix + rx);
                const ds_idx = (ry / in.crop.factor) * ds_cols + (rx / in.crop.factor);
                cells[ds_idx] = mergeOcc(cells[ds_idx], classifyOccCell(in, layer, node));
            }
        }
        grid.* = cells;
    }
    return grids;
}

/// Classify one native cell on one layer for the occupancy view.
fn classifyOccCell(in: FrontierIn, layer: usize, node: usize) u2 {
    const o = in.core.ctx.occ[layer][node];
    const rv = in.core.ctx.resv[layer][node];
    if ((o != empty_cell and o != in.ni) or (rv != empty_cell and rv != in.ni)) return 2;
    if (router.blocked(in.core.ctx, layer, node, in.ni)) return 3;
    if (o == in.ni or rv == in.ni) return 1;
    return 0;
}

/// Priority merge for a downsampled occupancy cell: foreign copper (2) beats
/// blocked-otherwise (3) beats own copper (1) beats free (0).
fn mergeOcc(a: u2, b: u2) u2 {
    return if (occRank(b) > occRank(a)) b else a;
}

fn occRank(c: u2) u8 {
    return switch (c) {
        2 => 3,
        3 => 2,
        1 => 1,
        else => 0,
    };
}

/// Priority merge for a downsampled cell: reached (1) beats copper (2) beats
/// clearance (3) beats unvisited (0).
fn mergeClass(a: u2, b: u2) u2 {
    return if (classRank(b) > classRank(a)) b else a;
}

fn classRank(c: u2) u8 {
    return switch (c) {
        1 => 3,
        2 => 2,
        3 => 1,
        else => 0,
    };
}

fn ceilDiv(a: usize, b: usize) usize {
    return (a + b - 1) / b;
}

fn blockerMoreShare(_: void, a: Blocker, b: Blocker) bool {
    if (a.share != b.share) return a.share > b.share;
    return a.net_i < b.net_i;
}

fn hintNet(hint: Hint) ?usize {
    return switch (hint) {
        .corridor => |c| c.net_i,
        .layers => |l| l.net_i,
        .route_now => |r| r.net_i,
        .abandon => |a| a.net_i,
        .rip => null,
    };
}

fn traceMm(tracks: []const router.Track) f64 {
    var s: f64 = 0;
    for (tracks) |t| s += std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
    return s;
}

fn traceMmForNet(tracks: []const router.Track, net: i32) f64 {
    var s: f64 = 0;
    for (tracks) |t| {
        if (t.net == net) s += std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
    }
    return s;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const Part = optimizer.Part;
const Placement = optimizer.Placement;
const FlatNet = flat_netlist.FlatNet;
const FlatPin = flat_netlist.FlatPin;

fn onePad(a: Allocator, w: f64, h: f64, thru: bool) Allocator.Error![]geometry.Pad {
    const p = try a.alloc(geometry.Pad, 1);
    p[0] = .{ .number = "1", .x = 0, .y = 0, .w = w, .h = h, .thru = thru };
    return p;
}

fn twoPinNet(a: Allocator, name: []const u8, r1: []const u8, r2: []const u8) Allocator.Error!FlatNet {
    const pins = try a.alloc(FlatPin, 2);
    pins[0] = .{ .ref_des = r1, .pin = "1" };
    pins[1] = .{ .ref_des = r2, .pin = "1" };
    return .{ .name = name, .pins = pins };
}

fn onePinNet(a: Allocator, name: []const u8, r1: []const u8) Allocator.Error!FlatNet {
    const pins = try a.alloc(FlatPin, 1);
    pins[0] = .{ .ref_des = r1, .pin = "1" };
    return .{ .name = name, .pins = pins };
}

fn passivePart(ref: []const u8, pads: []const geometry.Pad, x: f64, y: f64) Part {
    return .{ .ref_des = ref, .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = pads, .fallback = false, .x = x, .y = y };
}

fn wallPart(ref: []const u8, pads: []const geometry.Pad, x: f64, y: f64, hh: f64) Part {
    return .{ .ref_des = ref, .kind = .hub, .hw = 0.2, .hh = hh, .pads = pads, .fallback = false, .x = x, .y = y };
}

fn basePlacement(parts: []Part, nets: []const FlatNet, bounds: [4]f64) Placement {
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = bounds[0],
        .miny = bounds[1],
        .maxx = bounds[2],
        .maxy = bounds[3],
        .generated = true,
        // A board outline confines routing to the rectangle so a wall spanning
        // the full board height truly boxes a net in (no detour off-board).
        .board_rect = .{
            .minx = bounds[0],
            .miny = bounds[1],
            .w = bounds[2] - bounds[0],
            .h = bounds[3] - bounds[1],
        },
    };
}

/// A wall at x=3 with a top gap (y≈1.5) and a bottom gap (y≈-1.5). Net AT
/// (index 0) and AB (index 1) are high-priority and each take one gap; net B
/// (index 2) at y=0 is boxed in — it survives the standard pipeline as a
/// post-ripup failure because its only blockers are the protected AT/AB copper.
fn twoGap(a: Allocator) Allocator.Error!Placement {
    const small = try onePad(a, 0.4, 0.4, false);
    const wall_mid = try onePad(a, 0.4, 2.6, true);
    const wall_end = try onePad(a, 0.4, 1.3, true);
    const parts = try a.alloc(Part, 9);
    parts[0] = passivePart("AT1", small, 0, 1.5);
    parts[1] = passivePart("AT2", small, 6, 1.5);
    parts[2] = passivePart("AB1", small, 0, -1.5);
    parts[3] = passivePart("AB2", small, 6, -1.5);
    parts[4] = passivePart("B1", small, 0, 0);
    parts[5] = passivePart("B2", small, 6, 0);
    parts[6] = wallPart("WM", wall_mid, 3, 0, 1.3);
    parts[7] = wallPart("WT", wall_end, 3, 2.35, 0.65);
    parts[8] = wallPart("WB", wall_end, 3, -2.35, 0.65);
    const nets = try a.alloc(FlatNet, 6);
    nets[0] = try twoPinNet(a, "AT", "AT1", "AT2");
    nets[1] = try twoPinNet(a, "AB", "AB1", "AB2");
    nets[2] = try twoPinNet(a, "B", "B1", "B2");
    nets[3] = try onePinNet(a, "W_M", "WM");
    nets[4] = try onePinNet(a, "W_T", "WT");
    nets[5] = try onePinNet(a, "W_B", "WB");
    return basePlacement(parts, nets, .{ -1, -3, 7, 3 });
}

/// AT/AB high-priority so they route first and rip-up may not evict them.
fn twoGapOptions() route_policy.Options {
    const np = &[_]route_policy.NetPolicy{
        .{ .wave = .{ .priority = 2 } },
        .{ .wave = .{ .priority = 2 } },
        .{},
        .{},
        .{},
        .{},
    };
    return .{ .net = np };
}

/// A single full-height through-wall between B's two pads: net B has no path on
/// any layer, so it can never route (nor can any hint rescue it).
fn walled(a: Allocator) Allocator.Error!Placement {
    const small = try onePad(a, 0.4, 0.4, false);
    const wall = try onePad(a, 0.4, 6.0, true);
    const parts = try a.alloc(Part, 3);
    parts[0] = passivePart("B1", small, 0, 0);
    parts[1] = passivePart("B2", small, 6, 0);
    parts[2] = wallPart("WALL", wall, 3, 0, 3.0);
    const nets = try a.alloc(FlatNet, 2);
    nets[0] = try twoPinNet(a, "B", "B1", "B2");
    nets[1] = try onePinNet(a, "W", "WALL");
    return basePlacement(parts, nets, .{ -1, -3, 7, 3 });
}

/// An open board with one two-pad net that routes with no help.
fn simple(a: Allocator) Allocator.Error!Placement {
    const small = try onePad(a, 0.4, 0.4, false);
    const parts = try a.alloc(Part, 2);
    parts[0] = passivePart("R1", small, 0, 0);
    parts[1] = passivePart("R2", small, 3, 0);
    const nets = try a.alloc(FlatNet, 1);
    nets[0] = try twoPinNet(a, "SIG", "R1", "R2");
    return basePlacement(parts, nets, .{ -1, -1, 4, 1 });
}

// Straight-line test helpers (branching stays out of the test bodies).

fn stuckNet(status: Status) ?usize {
    return switch (status) {
        .stuck => |r| r.net_i,
        else => null,
    };
}

fn isDone(status: Status) bool {
    return switch (status) {
        .done => true,
        else => false,
    };
}

fn stuckReport(status: Status) ?StuckReport {
    return switch (status) {
        .stuck => |r| r,
        else => null,
    };
}

fn frontierHas(frontier: Frontier, value: u2) bool {
    for (frontier.cells) |c| {
        if (c == value) return true;
    }
    return false;
}

fn gridHas(cells: []const u2, value: u2) bool {
    for (cells) |c| {
        if (c == value) return true;
    }
    return false;
}

fn anyGridHas(grids: []const []const u2, value: u2) bool {
    for (grids) |g| {
        if (gridHas(g, value)) return true;
    }
    return false;
}

fn hasBlockerNet(blockers: []const Blocker, a: usize, b: usize) bool {
    for (blockers) |bl| {
        if ((bl.net_i == a or bl.net_i == b) and bl.share > 0) return true;
    }
    return false;
}

fn netTraceReachesBelow(tracks: []const router.Track, net: i32, y: f64) bool {
    for (tracks) |t| {
        if (t.net == net and (t.y1 < y or t.y2 < y)) return true;
    }
    return false;
}

fn countEventKind(timeline: []const router.RouteEvent, kind: router.RouteEventKind) usize {
    var n: usize = 0;
    for (timeline) |e| {
        if (e.kind == kind) n += 1;
    }
    return n;
}

fn lastKind(timeline: []const router.RouteEvent) router.RouteEventKind {
    return timeline[timeline.len - 1].kind;
}

fn summaryAbandons(summary: Summary, net_i: usize) bool {
    for (summary.abandoned) |a| {
        if (a == net_i) return true;
    }
    return false;
}

// spec: placement/route-session - the interactive session presents each post-ripup failed net once as a stuck report with a search-frontier snapshot
test "start presents the boxed-in net with a frontier snapshot" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();
    const placement = try twoGap(a);
    var session = try RouteSession.start(testing.allocator, &placement, .{}, twoGapOptions());
    defer session.deinit();

    const status = try session.runUntilEvent();
    try testing.expectEqual(@as(?usize, 2), stuckNet(status));
    const report = stuckReport(status).?;
    try testing.expectEqual(@as(u32, 1), report.attempts);
    try testing.expectEqual(@as(usize, 2), report.pads.len);
    try testing.expect(report.frontier.cols > 0 and report.frontier.rows > 0);
    // The frontier shows both the reached region and copper the search pressed against.
    try testing.expect(frontierHas(report.frontier, 1));
    try testing.expect(frontierHas(report.frontier, 2));
    // The stuck decision is on the shared timeline for replay.
    try testing.expect(countEventKind(session.currentRun().timeline, .stuck) >= 1);
}

// spec: placement/route-session - the stuck report ranks the nets whose copper the search pressed against
test "stuck report blockers name the walling nets" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();
    const placement = try twoGap(a);
    var session = try RouteSession.start(testing.allocator, &placement, .{}, twoGapOptions());
    defer session.deinit();

    const report = stuckReport(try session.runUntilEvent()).?;
    try testing.expect(report.blockers.len > 0);
    // AT (net 0) and/or AB (net 1) copper walls B's search.
    try testing.expect(hasBlockerNet(report.blockers, 0, 1));
    // One occupancy fraction per signal layer (≥2 on the legacy stackup).
    try testing.expect(report.layer_occupancy.len >= 2);
}

// spec: placement/route-session - the stuck report carries per-layer occupancy grids over the frontier window distinguishing foreign copper from other keepouts
test "stuck report occupancy grids expose the per-layer blockage" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();
    const placement = try twoGap(a);
    var session = try RouteSession.start(testing.allocator, &placement, .{}, twoGapOptions());
    defer session.deinit();

    const report = stuckReport(try session.runUntilEvent()).?;
    // One grid per signal layer, each covering the frontier's exact window.
    try testing.expectEqual(report.layer_occupancy.len, report.occupancy.len);
    const n_cells = @as(usize, report.frontier.cols) * @as(usize, report.frontier.rows);
    for (report.occupancy) |grid| try testing.expectEqual(n_cells, grid.len);
    // The walling nets' copper reads as foreign (2) on some layer, and the
    // open space around the crop margin reads as free (0).
    try testing.expect(anyGridHas(report.occupancy, 2));
    try testing.expect(gridHas(report.occupancy[0], 0));
}

// spec: placement/route-session - a rip hint forces the named nets off the board and retries the stuck net before them
test "a rip hint evicts a protected net and rescues the stuck net first" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();
    const placement = try twoGap(a);
    var session = try RouteSession.start(testing.allocator, &placement, .{}, twoGapOptions());
    defer session.deinit();

    _ = try session.runUntilEvent(); // present B
    try session.applyHint(.{ .rip = .{ .nets = &[_]usize{0} } }); // force-rip AT
    const status = try session.runUntilEvent();

    // B routed into the freed gap; AT rejoined the queue as the new stuck net.
    try testing.expect(session.findRoutable(2).?.ok);
    try testing.expectEqual(@as(?usize, 0), stuckNet(status));
}

// spec: placement/route-session - a corridor hint guides the retried net through its waypoints
test "a corridor hint routes the rescued net through its waypoint" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();
    const placement = try twoGap(a);
    var session = try RouteSession.start(testing.allocator, &placement, .{}, twoGapOptions());
    defer session.deinit();

    _ = try session.runUntilEvent(); // present B
    try session.applyHint(.{ .rip = .{ .nets = &[_]usize{ 0, 1 } } }); // free both gaps
    try session.applyHint(.{ .corridor = .{ .net_i = 2, .points = &[_]Waypoint{.{ .x = 3, .y = -1.5 }} } });
    _ = try session.runUntilEvent();

    try testing.expect(session.findRoutable(2).?.ok);
    // The waypoint pulled B's copper down into the bottom gap (y ≈ -1.5).
    try testing.expect(netTraceReachesBelow(session.currentRun().routed.tracks, 2, -1.0));
}

// spec: placement/route-session - an abandoned net is skipped and the finish passes still run to a done summary
test "abandoning the only failure finishes the session" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();
    const placement = try walled(a);
    var session = try RouteSession.start(testing.allocator, &placement, .{}, .{});
    defer session.deinit();

    try testing.expectEqual(@as(?usize, 0), stuckNet(try session.runUntilEvent()));
    try session.applyHint(.{ .abandon = .{ .net_i = 0 } });
    const status = try session.runUntilEvent();

    try testing.expect(isDone(status));
    try testing.expect(summaryAbandons(status.done, 0));
    // The finish passes ran: the timeline ends on the `complete` decision.
    try testing.expectEqual(router.RouteEventKind.complete, lastKind(session.currentRun().timeline));
}

// spec: placement/route-session - the non-session route entry points route identically alongside the session machinery
test "non-session route matches a hint-free session on the same board" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();
    const placement = try simple(a);

    const r = try router.route(a, placement, .{});
    try testing.expectEqual(@as(usize, 1), r.total);
    try testing.expectEqual(@as(usize, 1), r.routed);
    const rev = try router.routeWithTimeline(a, placement, .{}, .{});
    try testing.expectEqual(r.routed, rev.routed.routed);
    try testing.expectEqual(router.RouteEventKind.complete, lastKind(rev.timeline));

    var session = try RouteSession.start(testing.allocator, &placement, .{}, .{});
    defer session.deinit();
    try testing.expect(isDone(try session.runUntilEvent()));
    try testing.expectEqual(r.tracks.len, session.currentRun().routed.tracks.len);
    try testing.expectApproxEqAbs(traceMm(r.tracks), traceMm(session.currentRun().routed.tracks), 1e-9);
}

// spec: placement/route-session - accepted hints are recorded in order and appended to the timeline as decisions
test "accepted hints are logged in order and timelined" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const a = arena_inst.allocator();
    const placement = try twoGap(a);
    var session = try RouteSession.start(testing.allocator, &placement, .{}, twoGapOptions());
    defer session.deinit();

    _ = try session.runUntilEvent(); // present B
    try session.applyHint(.{ .corridor = .{ .net_i = 2, .points = &[_]Waypoint{.{ .x = 3, .y = 1.5 }} } });
    try session.applyHint(.{ .route_now = .{ .net_i = 2 } });
    try session.applyHint(.{ .layers = .{ .net_i = 2, .allowed = 1 } });

    const hints = session.acceptedHints();
    try testing.expectEqual(@as(usize, 3), hints.len);
    try testing.expectEqual(std.meta.Tag(Hint).corridor, std.meta.activeTag(hints[0]));
    try testing.expectEqual(std.meta.Tag(Hint).route_now, std.meta.activeTag(hints[1]));
    try testing.expectEqual(std.meta.Tag(Hint).layers, std.meta.activeTag(hints[2]));
    try testing.expectEqual(@as(usize, 3), countEventKind(session.currentRun().timeline, .hint_applied));
}
