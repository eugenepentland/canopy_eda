//! Stuck-net diagnostics — the agent-actionable "why did this net fail to route,
//! and what do I change to unstick it" layer over a finished route.
//!
//! `capture` runs read-only over the router's LIVE grid (the same `RouteCore`
//! the finish passes just populated — the caller must call it while `ctx` is
//! still alive, before the arena is dropped). For every net in the residual
//! `failed` set it:
//!
//!   1. re-floods the reachable free space from the net's first pad over the
//!      router's own hard cost model (`router.blocked`), so the flood shows
//!      exactly what the maze pressed against;
//!   2. classifies the flood shape + the foreign copper ringing it into ONE
//!      `FailureMode` (order_congestion / blocked_by_higher / search_budget /
//!      escape_blocked / grid_quantization);
//!   3. rolls up ranked `Blocker`s from the foreign copper that ACTUALLY BOUNDS
//!      this net's frontier — restricted to the net's own pad-corridor crop
//!      (the pad bounding box, not the whole flood) and to cells that border a
//!      reached cell (the walls the search hit), so attribution is genuinely
//!      per-net and local, never a board-wide owner tally. Each `Blocker`
//!      carries net, layer, the world centroid of that owner's bounding copper,
//!      its share of THIS net's blocked boundary, and a rippable-vs-protected
//!      tag from the router's own `collectRippable` rip-up predicate. Only when
//!      the frontier flood finds no bounding owner does a goal-directed probe
//!      fallback fire (`share == 0` marks those, distinct from flood-local
//!      owners whose `share > 0`); and
//!   4. emits a ranked `Remedy` list — each a concrete constraint-DSL snippet an
//!      agent can paste (raise a net-class priority, add a routing wave, drop a
//!      waypoint, open a layer/escape) OR, for the grid-quantization fork, a
//!      `target = .code` router-fix note telling the agent the corridor is open
//!      but sub-grid-narrow so no DSL edit will help.
//!
//! The dsl↔code fork on `Remedy.target` is the key output: it tells a routing
//! agent whether to edit the `(pcb-plan …)` / `(net-class …)` DSL or the router
//! itself. Everything here is pure — a fixed-order BFS/scan over the grid, no
//! time, no rng — so a given board always yields the same diagnosis.

const std = @import("std");
const board_layers = @import("../board_layers.zig");
const router = @import("router.zig");
const optimizer = @import("optimizer.zig");
const fine_window = @import("fine_window.zig");
const cdt_route = @import("cdt_route.zig");
const net_name = @import("../net_name.zig");

const Allocator = std.mem.Allocator;

/// Empty-cell sentinel in the router's occupancy/reservation grids (mirrors the
/// router's private `empty_cell`, as `route_session.zig` does).
const empty_cell: i32 = -1;
/// Reachability-flood expansion budget — bounds the picture on a huge board.
const flood_cap: usize = 20_000;
/// Cells of slack around the reached region so the scan sees the copper the
/// search pressed against, not just the reached interior.
const margin_cells: usize = 3;
/// Cap on ranked blockers per stuck net.
const max_blockers: usize = 8;
/// Hard cap on how many failed nets get a full diagnosis, in the route's own
/// failed-net order. Each diagnosis is a reachability flood plus a remedy/CDT
/// probe search — measured at HOURS of Debug-build grind on a pathological
/// board with ~87 failed nets, stalling the route response (and pinning a
/// live-route job at full CPU) for stuck reports nobody can read that many of.
/// Sixteen sits with the module's other bounds (probe_max_legs); the response
/// stays honest because the COMPLETE failed-net list still reaches clients via
/// the result's `unrouted` array — a capped `stuck` alongside a longer
/// `unrouted` is self-consistent, not truncated data.
const max_stuck: usize = 16;
/// Per-net leg cap for the CDT feasibility probe. The CDT engine is already
/// bounded internally (its own point/flip caps), but a pathological many-terminal
/// net would still run the engine once per leg per config; this holds the per-net
/// probe cost flat. Real stuck nets are 2–a-handful of terminals.
const probe_max_legs: usize = 16;
/// Corridor-occupancy cutoff for the with-copper verdict. A leg window overlapping
/// more than this many finished tracks+vias is copper-packed — congestion, given
/// isolation already proved the geometry open. Running the CDT engine over that
/// much foreign copper is infeasible per stuck net (its constraint-insertion flip
/// loop thrashes on hundreds of near-collinear track edges), so with-copper reads
/// occupancy by count instead; a sparse window (≤ cutoff) is an unfilled corridor
/// the maze missed (a maze gap).
const max_window_obstacles: usize = 48;
/// Below this many reached free cells (and with no other pad reached) the net's
/// first pad reads as sealed inside its own footprint → escape_blocked.
const escape_seal_cells: usize = 14;
/// Suggested net-class priority tiers for the raise-priority remedies (0-7).
const congestion_priority: u8 = 4;
const budget_priority: u8 = 5;
/// Remedy `kind` tags shared by several modes (extracted so each stays a single
/// spelling — the repeated-literal gate).
const kind_waypoint = "waypoint";
const kind_raise_priority = "raise_priority";
const kind_reorder_wave = "reorder_wave";

/// Whether a remedy is a constraint-DSL edit an agent can paste, or a router
/// code change (the sub-grid channel case where no DSL knob helps).
pub const Target = enum { dsl, code };

/// One CDT feasibility verdict: did the gridless engine thread the stuck net's
/// corridor, or not, under a given obstacle set.
pub const CdtVerdict = enum { routable, blocked };

/// The CDT feasibility probe result for one stuck net — the same gridless engine
/// the router's last-resort rescue uses, run twice over the net's corridor as a
/// controlled experiment the flood-shape heuristic cannot run itself:
///   • `isolation`   — obstacles are the pads/board only; all foreign nets'
///                     routed tracks and vias are removed. "Could this corridor
///                     hold a path if nothing else were routed?"
///   • `with_copper` — obstacles are the full current copper (the same set the
///                     maze faced). "Can it hold a path against what's there now?"
/// Because `isolation`'s obstacle set is a strict subset of `with_copper`'s, a
/// `with_copper == .routable` implies `isolation == .routable`; the three
/// reachable combinations are exactly the dsl↔code fork:
///   routable + blocked  → CONGESTION (foreign copper fills an open corridor; a
///                         reorder is the dsl lever).
///   blocked  + blocked  → GEOMETRY LIMIT (no path even with the board empty; a
///                         placement/router change, never a reorder).
///   routable + routable → MAZE GAP (the grid maze failed where CDT threads; a
///                         router/grid-pitch limitation, reported, not auto-routed).
pub const CdtProbe = struct {
    isolation: CdtVerdict,
    with_copper: CdtVerdict,
};

/// One foreign net whose routed copper rings the stuck net's search frontier.
/// `share` is the fraction of the frontier's blocked-copper cells it owns; `x`
/// / `y` are the world centroid (mm) of that copper within the crop; `rippable`
/// is the router's own rip-up verdict (lower/equal priority, not plane/pour/
/// ground) — the discriminator between order-congestion and a protected wall.
pub const Blocker = struct {
    net: []const u8,
    layer: []const u8,
    x: f64,
    y: f64,
    share: f32,
    rippable: bool,
};

/// One ranked fix. `kind` is a stable machine tag; `dsl` is a paste-ready
/// constraint-DSL snippet (empty for a `.code` / info remedy); `rationale`
/// explains the causal link; `confidence` is "high"/"med"/"low"; `target`
/// forks agent action between editing the DSL and editing the router.
pub const Remedy = struct {
    kind: []const u8,
    dsl: []const u8,
    rationale: []const u8,
    confidence: []const u8,
    target: Target,
};

/// The diagnosis for one stuck net: the single inferred failure mode, a plain
/// "why", the ranked blockers, the ranked remedies, and any related DRC ids.
pub const Diagnosis = struct {
    net: []const u8,
    failure_mode: []const u8,
    why: []const u8,
    blockers: []const Blocker,
    remedies: []const Remedy,
    drc_related: []const []const u8,
    /// The CDT feasibility probe (isolation vs. with-copper). Null for a net that
    /// was never probed (a trivial <2-pad net, or one with no CDT-attemptable
    /// leg); a real two-word verdict for every genuinely-stuck routable net.
    cdt_probe: ?CdtProbe = null,
};

/// The inferred cause of one stuck net. Borrows the scheduler `Failure`
/// vocabulary where it maps; the last two are diagnostic-only shapes.
const FailureMode = enum {
    order_congestion,
    blocked_by_higher,
    search_budget,
    escape_blocked,
    grid_quantization,
    unknown,

    fn name(self: FailureMode) []const u8 {
        return @tagName(self);
    }
};

/// Diagnose every net in the finished route's residual `failed` set. Read-only
/// over `core`'s live grid (call before the routing arena is dropped). All
/// output is allocated in `scratch`.
pub fn capture(
    core: *const router.RouteCore,
    result: router.RouteResult,
    placement: optimizer.Placement,
    scratch: Allocator,
) Allocator.Error![]Diagnosis {
    // The finish pass DRAINS the live core's copper lists into `result`
    // (`toOwnedSlice`), so `core.tracks.items` is empty by now — the CDT probe's
    // with-copper obstacle set must read the finished copper from `result`.
    const copper = ProbeCopper{ .tracks = result.tracks, .vias = result.vias };
    var out: std.ArrayList(Diagnosis) = .empty;
    for (result.failed) |name| {
        if (out.items.len >= max_stuck) break;
        const net_i = indexOfNet(placement, name) orelse continue;
        const limited = containsIndex(result.search_limited, net_i);
        try out.append(scratch, try diagnoseNet(core, placement, .{
            .net_i = net_i,
            .name = name,
            .search_limited = limited,
        }, copper, scratch));
    }
    return out.toOwnedSlice(scratch);
}

/// Per-net inputs, bundled to keep the param count small.
const NetRef = struct { net_i: usize, name: []const u8, search_limited: bool };

/// The finished board copper the CDT probe measures its with-copper feasibility
/// against — read from the `RouteResult`, not the drained live core lists.
const ProbeCopper = struct { tracks: []const router.Track, vias: []const router.Via };

/// Measured shape of one stuck net's search frontier — the raw signals the
/// classifier reads. Non-pub, so its field count is unconstrained.
const Shape = struct {
    reached_cells: usize = 0,
    open_cells: usize = 0,
    clearance_cells: usize = 0,
    copper_cells: usize = 0,
    reaches_all_pads: bool = false,
    reaches_other_pad: bool = false,
    capped: bool = false,
    gap_x: f64 = 0,
    gap_y: f64 = 0,
    gap_layer: u8 = 0,
};

/// Running per-owner tally of ringing copper: cell count + integer world-cell
/// centroid sums + the layer it was first seen on.
const OwnerTally = struct { count: u32, sum_ix: u64, sum_iy: u64, layer: u8 };

fn diagnoseNet(
    core: *const router.RouteCore,
    placement: optimizer.Placement,
    ref: NetRef,
    copper: ProbeCopper,
    scratch: Allocator,
) Allocator.Error!Diagnosis {
    const ctx = core.ctx;
    router.setNetParams(ctx, placement, ref.net_i);
    const pts = try router.netPoints(scratch, placement, core.idx_of, placement.nets[ref.net_i]);
    if (pts.len < 2) return trivialDiagnosis(ref.name);

    const ni: i32 = @intCast(ref.net_i);
    // Bound the whole diagnosis to THIS net's pad corridor (its pad bounding
    // box + a small margin), so blocker attribution is local to the net even
    // when its reachability flood escaped into the board-wide free space.
    const crop = padCrop(ctx.grid, pts);
    var owners = std.AutoHashMapUnmanaged(i32, OwnerTally).empty;
    const shape = try measureShape(core, ni, pts, crop, &owners, scratch);

    var blockers = try buildBlockers(core, placement, ref.net_i, &owners, scratch);
    if (blockers.len == 0 and (shape.capped or ref.search_limited))
        blockers = try fallbackBlockers(core, placement, ref.net_i, crop, scratch);

    // The flood-shape heuristic classifies first; the CDT probe then re-runs the
    // corridor as a controlled experiment (foreign copper present vs. removed) and
    // sharpens the dsl↔code fork the shape signal alone can only guess at.
    const probe = try cdtProbe(core, placement, ref.net_i, pts, copper, scratch);
    const mode = reviseMode(classify(shape, blockers, ref.search_limited), probe);
    const rc = try remedyContext(core, placement, ref, shape, blockers, scratch);
    return .{
        .net = ref.name,
        .failure_mode = mode.name(),
        .why = try whyText(mode, ref.name, blockers, scratch),
        .blockers = blockers,
        .remedies = try remediesFor(mode, rc, probe, scratch),
        .drc_related = &.{},
        .cdt_probe = probe,
    };
}

fn trivialDiagnosis(name: []const u8) Diagnosis {
    return .{
        .net = name,
        .failure_mode = FailureMode.unknown.name(),
        .why = "net has fewer than two resolvable pads — nothing to route",
        .blockers = &.{},
        .remedies = &.{},
        .drc_related = &.{},
    };
}

// ── CDT feasibility probe ────────────────────────────────────────────────────

/// Run the gridless CDT engine over the stuck net's corridor twice — once with
/// every foreign net's copper removed (isolation), once against the full current
/// copper — and fold the pair into a `CdtProbe`. This is the same engine the
/// router's last-resort rescue tier uses, so a `routable` verdict means a real
/// clearance-honouring path exists; `blocked` means the engine declined at that
/// obstacle set. Read-only over the live grid: it allocates its meshes in a
/// scoped arena freed on return and never touches the board copper. Bounded and
/// deterministic (no rng, no clock) — identical routes always probe identically.
fn cdtProbe(
    core: *const router.RouteCore,
    placement: optimizer.Placement,
    net_i: usize,
    pts: []const router.NetPt,
    copper: ProbeCopper,
    scratch: Allocator,
) Allocator.Error!?CdtProbe {
    if (pts.len < 2) return null;
    var mesh_arena = std.heap.ArenaAllocator.init(scratch);
    defer mesh_arena.deinit();
    const a = mesh_arena.allocator();

    const ctx = core.ctx;
    router.setNetParams(ctx, placement, net_i); // effective width/clearance for THIS net
    const base = fine_window.netPitch(ctx.base, placement, net_i);
    const legs = try fine_window.mstLegs(a, pts);
    if (legs.len == 0 or legs.len > probe_max_legs) return null;

    const pc = ProbeCtx{
        .placement = placement,
        .net_i = net_i,
        .pads = ctx.obs,
        .track_width = ctx.params.track_width,
        .clearance = ctx.params.clearance,
        .base = base,
    };
    // A net with any cross-layer or over-budget-window leg is NOT CDT-probeable
    // (a board-spanning multi-terminal net — SPI, a rail — has no budgeted window):
    // return null rather than a misleading `blocked`, which the fork would read as a
    // geometry limit for what is really an order/congestion or simply too-large net.
    if (!legsAttemptable(pc, pts, legs)) return null;

    // One pass per leg over the real CDT engine — but ONLY over the board GEOMETRY
    // (pads, no foreign copper), the isolation question "does a clearance-honouring
    // path fit at all?". Re-meshing OVER the finished copper is infeasible per stuck
    // net (the engine's constraint insertion thrashes on hundreds of near-collinear
    // track edges), so with-copper reuses that same isolation path and asks whether
    // the copper now OCCUPIES it — an O(copper) clearance scan, no second mesh.
    return try probeVerdict(pc, pts, legs, copper.tracks, copper.vias, a);
}

/// Every leg is a same-layer pair with a budgeted window — the precondition for
/// the CDT engine to even attempt the net (see `cdtProbe`'s null gate). A leg's
/// window is budgeted iff at least one tier is under the fine-grid cell cap.
fn legsAttemptable(pc: ProbeCtx, pts: []const router.NetPt, legs: []const [2]usize) bool {
    for (legs) |leg| {
        const p0 = pts[leg[0]];
        const p1 = pts[leg[1]];
        if (p0.layer != p1.layer) return false;
        const ws = fine_window.legWindows(pc.placement, p0, p1, pc.base, null);
        if (ws[0] == null and ws[1] == null) return false;
    }
    return true;
}

/// The window/geometry constants the CDT probe threads into every leg, so the
/// isolation and with-copper passes needn't re-derive them. `pads` is the board's
/// pad-obstacle list (the isolation obstacle set); the finished tracks/vias are
/// read separately by the with-copper occupancy scan.
const ProbeCtx = struct {
    placement: optimizer.Placement,
    net_i: usize,
    pads: []const router.PadObs,
    track_width: f64,
    clearance: f64,
    base: f64,
};

/// The two-verdict feasibility for the whole net. Per leg: run the CDT engine over
/// the pads-only geometry (isolation) — a null path means the geometry itself seals
/// the leg (→ blocked/blocked). Then read with-copper off that isolation path: a
/// window packed past the obstacle budget, OR an isolation path running within
/// clearance of a finished track/via, means the copper occupies the open corridor
/// (→ with-copper blocked = congestion); otherwise the corridor is clear and the
/// maze simply missed it (→ maze gap). Legs are pre-filtered same-layer + budgeted.
fn probeVerdict(pc: ProbeCtx, pts: []const router.NetPt, legs: []const [2]usize, tracks: []const router.Track, vias: []const router.Via, a: Allocator) Allocator.Error!CdtProbe {
    var copper_blocked = false;
    for (legs) |leg| {
        const p0 = pts[leg[0]];
        const p1 = pts[leg[1]];
        const ws = fine_window.legWindows(pc.placement, p0, p1, pc.base, null);
        const w = (ws[0] orelse ws[1]) orelse return blocked_probe;
        const iso = try cdt_route.route(a, .{
            .rect = w.rect,
            .layer = p0.layer,
            .obstacles = .{ .pads = pc.pads, .tracks = &.{}, .vias = &.{}, .skip_net = @intCast(pc.net_i) },
            .start = .{ p0.x, p0.y },
            .goal = .{ p1.x, p1.y },
            .track_width = pc.track_width,
            .clearance = pc.clearance,
        });
        const path = iso orelse return blocked_probe;
        if (windowObstacleCount(w.rect, tracks, vias) > max_window_obstacles or
            pathHitsCopper(path, tracks, vias, pc.clearance, pc.track_width))
            copper_blocked = true;
    }
    return .{ .isolation = .routable, .with_copper = if (copper_blocked) .blocked else .routable };
}

/// The both-blocked verdict for a leg whose GEOMETRY (pads/board) seals it — a
/// resolution/geometry limit regardless of copper.
const blocked_probe = CdtProbe{ .isolation = .blocked, .with_copper = .blocked };

/// True when the isolation path runs within its DRC clearance of any finished track
/// or via — the copper now occupies the geometrically-open corridor (congestion).
/// The required gap is the clearance plus both half-widths (track) or the routed
/// half-width + via radius (via). O(path × copper); the path is a handful of points.
fn pathHitsCopper(path: []const [2]f64, tracks: []const router.Track, vias: []const router.Via, clearance: f64, track_width: f64) bool {
    if (path.len < 2) return false;
    for (0..path.len - 1) |i| {
        const s0 = path[i];
        const s1 = path[i + 1];
        for (tracks) |t| {
            const need = clearance + (track_width + t.width) / 2;
            if (segSegDist(s0, s1, .{ t.x1, t.y1 }, .{ t.x2, t.y2 }) < need) return true;
        }
        for (vias) |v| {
            const need = clearance + track_width / 2 + v.dia / 2;
            if (segPointDist(s0, s1, .{ v.x, v.y }) < need) return true;
        }
    }
    return false;
}

/// Minimum distance between segments a0–a1 and b0–b1 (0 when they cross).
fn segSegDist(a0: [2]f64, a1: [2]f64, b0: [2]f64, b1: [2]f64) f64 {
    if (segsCross(a0, a1, b0, b1)) return 0;
    return @min(
        @min(segPointDist(a0, a1, b0), segPointDist(a0, a1, b1)),
        @min(segPointDist(b0, b1, a0), segPointDist(b0, b1, a1)),
    );
}

/// Distance from point p to segment a0–a1.
fn segPointDist(a0: [2]f64, a1: [2]f64, p: [2]f64) f64 {
    const dx = a1[0] - a0[0];
    const dy = a1[1] - a0[1];
    const len2 = dx * dx + dy * dy;
    if (len2 == 0) return std.math.hypot(p[0] - a0[0], p[1] - a0[1]);
    const tt = std.math.clamp(((p[0] - a0[0]) * dx + (p[1] - a0[1]) * dy) / len2, 0, 1);
    return std.math.hypot(p[0] - (a0[0] + tt * dx), p[1] - (a0[1] + tt * dy));
}

/// True when segments a0–a1 and b0–b1 properly cross (opposite orientations).
fn segsCross(a0: [2]f64, a1: [2]f64, b0: [2]f64, b1: [2]f64) bool {
    const d1 = orient(b0, b1, a0);
    const d2 = orient(b0, b1, a1);
    const d3 = orient(a0, a1, b0);
    const d4 = orient(a0, a1, b1);
    return ((d1 > 0) != (d2 > 0)) and ((d3 > 0) != (d4 > 0));
}

/// Signed area sign of triangle o,a,b (> 0 when b is left of o→a).
fn orient(o: [2]f64, a: [2]f64, b: [2]f64) f64 {
    return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0]);
}

/// How many of `tracks`+`vias` have a bounding box overlapping `rect` — the corridor
/// copper-occupancy count the with-copper verdict reads. Track boxes grow by half
/// their width, via boxes by their radius, so the count is conservative (a grazing
/// obstacle counts). Isolation passes empty slices, so it always counts 0.
fn windowObstacleCount(rect: fine_window.WindowRect, tracks: []const router.Track, vias: []const router.Via) usize {
    var n: usize = 0;
    for (tracks) |t| {
        const hw = t.width / 2;
        const bx0 = @min(t.x1, t.x2) - hw;
        const by0 = @min(t.y1, t.y2) - hw;
        const bx1 = @max(t.x1, t.x2) + hw;
        const by1 = @max(t.y1, t.y2) + hw;
        if (bx1 >= rect.x0 and bx0 <= rect.x1 and by1 >= rect.y0 and by0 <= rect.y1) n += 1;
    }
    for (vias) |v| {
        const r = v.dia / 2;
        if (v.x + r >= rect.x0 and v.x - r <= rect.x1 and v.y + r >= rect.y0 and v.y - r <= rect.y1) n += 1;
    }
    return n;
}

/// The three dsl↔code forks the probe distinguishes (see `CdtProbe`). Total over
/// the reachable `(isolation, with_copper)` combinations: an isolation `blocked`
/// is a geometry limit regardless of the with-copper verdict; an isolation
/// `routable` splits on whether foreign copper blocks it.
const ProbeFork = enum { congestion, geometry_limit, maze_gap };

fn probeFork(p: CdtProbe) ProbeFork {
    if (p.isolation == .blocked) return .geometry_limit;
    return if (p.with_copper == .routable) .maze_gap else .congestion;
}

/// Fold the probe verdict into the flood-shape mode. Only the congestion fork
/// overrides the heuristic — and only when it landed on a code-target or
/// unclassified verdict (`grid_quantization` / `unknown`): the probe has PROVEN
/// the corridor is geometrically open and merely occupied, so the dsl reorder
/// modes are the correct fork. A genuine order mode the heuristic already found
/// (order_congestion / blocked_by_higher / search_budget) keeps its net-aware
/// blocker attribution. The geometry-limit and maze-gap forks leave the mode
/// alone (their signal rides in the leading remedy, below).
fn reviseMode(mode: FailureMode, probe: ?CdtProbe) FailureMode {
    const p = probe orelse return mode;
    return switch (probeFork(p)) {
        .congestion => switch (mode) {
            .grid_quantization, .unknown => .order_congestion,
            else => mode,
        },
        .geometry_limit, .maze_gap => mode,
    };
}

// ── Frontier flood + crop scan ───────────────────────────────────────────────

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

const Flood = struct { reached: []const bool, capped: bool };

/// BFS the free space reachable from `seed` over the router's hard cost model
/// (`router.blocked`), 8-connected per layer plus vias — the same reachability
/// `route_session` captures, minus the downsampled grid payload.
fn floodFrom(core: *const router.RouteCore, ni: i32, seed: router.NetPt, scratch: Allocator) Allocator.Error!Flood {
    const ctx = core.ctx;
    const grid = ctx.grid;
    const nodes = grid.nx * grid.ny;
    const n_layers = ctx.occ.len;
    const reached = try scratch.alloc(bool, n_layers * nodes);
    @memset(reached, false);
    var queue: std.ArrayList(usize) = .empty;
    const s = grid.nearest(seed.x, seed.y);
    const start = @as(usize, seed.layer) * nodes + grid.node(s[0], s[1]);
    reached[start] = true;
    try queue.append(scratch, start);
    var head: usize = 0;
    var expansions: usize = 0;
    while (head < queue.items.len and expansions < flood_cap) : (head += 1) {
        expansions += 1;
        const key = queue.items[head];
        const layer = key / nodes;
        const n = key % nodes;
        try floodExpand(.{ .core = core, .ni = ni, .reached = reached, .queue = &queue, .scratch = scratch }, layer, n);
    }
    return .{ .reached = reached, .capped = head < queue.items.len };
}

/// Shared flood state (pointer bundle keeps `floodExpand`/`floodReach` at two
/// params).
const FloodState = struct {
    core: *const router.RouteCore,
    ni: i32,
    reached: []bool,
    queue: *std.ArrayList(usize),
    scratch: Allocator,
};

fn floodExpand(st: FloodState, layer: usize, n: usize) Allocator.Error!void {
    const grid = st.core.ctx.grid;
    const ix = n % grid.nx;
    const iy = n / grid.nx;
    try floodStep(st, layer, ix, iy, 1, 0);
    try floodStep(st, layer, ix, iy, -1, 0);
    try floodStep(st, layer, ix, iy, 0, 1);
    try floodStep(st, layer, ix, iy, 0, -1);
    try floodStep(st, layer, ix, iy, 1, 1);
    try floodStep(st, layer, ix, iy, 1, -1);
    try floodStep(st, layer, ix, iy, -1, 1);
    try floodStep(st, layer, ix, iy, -1, -1);
    for (0..st.core.ctx.occ.len) |l2| {
        if (l2 != layer) try floodReach(st, l2, n);
    }
}

fn floodStep(st: FloodState, layer: usize, ix: usize, iy: usize, dx: i64, dy: i64) Allocator.Error!void {
    const grid = st.core.ctx.grid;
    const tx = @as(i64, @intCast(ix)) + dx;
    const ty = @as(i64, @intCast(iy)) + dy;
    if (tx < 0 or ty < 0 or tx >= grid.nx or ty >= grid.ny) return;
    try floodReach(st, layer, @as(usize, @intCast(ty)) * grid.nx + @as(usize, @intCast(tx)));
}

fn floodReach(st: FloodState, layer: usize, n: usize) Allocator.Error!void {
    const nodes = st.core.ctx.grid.nx * st.core.ctx.grid.ny;
    const key = layer * nodes + n;
    if (st.reached[key]) return;
    if (router.blocked(st.core.ctx, layer, n, st.ni)) return;
    st.reached[key] = true;
    try st.queue.append(st.scratch, key);
}

/// The crop over which the frontier is measured — the net's own corridor: the
/// bounding box of its PADS grown by `margin_cells`, clamped to the grid. It is
/// deliberately NOT the flood box: an undirected flood escapes into the shared
/// board-wide free space, so a flood-box crop would tally every net's copper the
/// same way (the board-global-tally bug). Bounding to the pad corridor keeps
/// each stuck net's blockers local to where its own copper needed to run.
const Crop = struct { min_ix: usize, min_iy: usize, max_ix: usize, max_iy: usize };

fn padCrop(grid: router.Grid, pts: []const router.NetPt) Crop {
    const seed = grid.nearest(pts[0].x, pts[0].y);
    var b = BBox.init(seed[0], seed[1]);
    for (pts) |p| {
        const nd = grid.nearest(p.x, p.y);
        b.include(nd[0], nd[1]);
    }
    return .{
        .min_ix = b.min_ix -| margin_cells,
        .min_iy = b.min_iy -| margin_cells,
        .max_ix = @min(grid.nx - 1, b.max_ix + margin_cells),
        .max_iy = @min(grid.ny - 1, b.max_iy + margin_cells),
    };
}

/// Flood the net, then scan its pad-corridor `crop` cell-by-cell to fill `Shape`
/// and tally the copper that BOUNDS the reached frontier per owner into `owners`
/// (frontier-adjacent foreign copper only — see `classifyCell`).
fn measureShape(
    core: *const router.RouteCore,
    ni: i32,
    pts: []const router.NetPt,
    crop: Crop,
    owners: *std.AutoHashMapUnmanaged(i32, OwnerTally),
    scratch: Allocator,
) Allocator.Error!Shape {
    const ctx = core.ctx;
    const grid = ctx.grid;
    const nodes = grid.nx * grid.ny;
    const flood = try floodFrom(core, ni, pts[0], scratch);
    var sh: Shape = .{ .capped = flood.capped, .gap_layer = pts[0].layer };
    var gap = OwnerTally{ .count = 0, .sum_ix = 0, .sum_iy = 0, .layer = pts[0].layer };
    const in = ScanIn{ .core = core, .ni = ni, .nodes = nodes, .reached = flood.reached };
    const acc = Accum{ .sh = &sh, .gap = &gap, .owners = owners };
    for (crop.min_iy..crop.max_iy + 1) |iy| {
        for (crop.min_ix..crop.max_ix + 1) |ix| {
            try classifyCell(in, ix, iy, acc, scratch);
        }
    }
    if (gap.count > 0) {
        sh.gap_x = grid.worldX(gap.sum_ix / gap.count);
        sh.gap_y = grid.worldY(gap.sum_iy / gap.count);
    } else {
        sh.gap_x = midX(pts);
        sh.gap_y = midY(pts);
    }
    fillReachedPads(core, pts, flood.reached, &sh);
    return sh;
}

/// Immutable per-scan inputs (keeps `classifyCell` at a small param count).
const ScanIn = struct {
    core: *const router.RouteCore,
    ni: i32,
    nodes: usize,
    reached: []const bool,

    fn reachedAt(self: ScanIn, layer: usize, node: usize) bool {
        return self.reached[layer * self.nodes + node];
    }
};

/// The running frontier accumulators, bundled so the per-cell scan stays under
/// the param cap.
const Accum = struct {
    sh: *Shape,
    gap: *OwnerTally,
    owners: *std.AutoHashMapUnmanaged(i32, OwnerTally),
};

/// Scan one grid column (all layers) of the corridor crop into the running
/// `Shape` tallies. A foreign-copper cell is only attributed to its owner when
/// it is FRONTIER-ADJACENT — it borders a reached cell on the same layer (8-conn)
/// or the same node on a layer the net reached (a via step). That is exactly the
/// copper the flood pressed against, so the roll-up names the walls that bound
/// THIS net, not every piece of copper that happens to lie in the crop.
fn classifyCell(in: ScanIn, ix: usize, iy: usize, acc: Accum, scratch: Allocator) Allocator.Error!void {
    const ctx = in.core.ctx;
    const node = iy * ctx.grid.nx + ix;
    var v = CellVerdict{};
    for (0..ctx.occ.len) |l| {
        if (in.reachedAt(l, node)) {
            v.reached = true;
            continue;
        }
        const owner = foreignOwnerAt(in, l, node);
        if (owner != empty_cell) {
            v.has_foreign = true;
            if (frontierAdjacent(in, l, ix, iy)) {
                v.wall = true;
                try tallyOwner(acc.owners, owner, ix, iy, @intCast(l), scratch);
            }
        } else if (router.blocked(ctx, l, node, in.ni)) {
            v.clear = true;
        } else {
            v.free = true;
        }
    }
    tallyColumn(acc, ix, iy, v);
}

/// The foreign net owning `(layer, node)` — the occupancy owner first, else the
/// reservation owner — or `empty_cell` when the cell is free or the net's own.
fn foreignOwnerAt(in: ScanIn, layer: usize, node: usize) i32 {
    const ctx = in.core.ctx;
    const o = ctx.occ[layer][node];
    if (o != empty_cell and o != in.ni) return o;
    const rv = ctx.resv[layer][node];
    if (rv != empty_cell and rv != in.ni) return rv;
    return empty_cell;
}

/// True when cell `(layer, ix, iy)` borders the reached region — a same-layer
/// 8-neighbour is reached, or the net reached the same node on another layer (a
/// via step). Foreign copper here is a wall the flood actually hit.
fn frontierAdjacent(in: ScanIn, layer: usize, ix: usize, iy: usize) bool {
    const grid = in.core.ctx.grid;
    const node = iy * grid.nx + ix;
    for (0..in.core.ctx.occ.len) |l2| {
        if (l2 != layer and in.reachedAt(l2, node)) return true;
    }
    return neighborReached(in, layer, ix, iy);
}

/// True when any of the 8 same-layer neighbours of `(ix, iy)` is reached.
fn neighborReached(in: ScanIn, layer: usize, ix: usize, iy: usize) bool {
    const grid = in.core.ctx.grid;
    const offs = [_][2]i64{ .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 }, .{ 1, 1 }, .{ 1, -1 }, .{ -1, 1 }, .{ -1, -1 } };
    for (offs) |d| {
        const tx = @as(i64, @intCast(ix)) + d[0];
        const ty = @as(i64, @intCast(iy)) + d[1];
        if (tx < 0 or ty < 0 or tx >= grid.nx or ty >= grid.ny) continue;
        const tn = @as(usize, @intCast(ty)) * grid.nx + @as(usize, @intCast(tx));
        if (in.reachedAt(layer, tn)) return true;
    }
    return false;
}

/// Add one bounding-copper cell to its owner's centroid tally.
fn tallyOwner(owners: *std.AutoHashMapUnmanaged(i32, OwnerTally), owner: i32, ix: usize, iy: usize, layer: u8, scratch: Allocator) Allocator.Error!void {
    const gop = try owners.getOrPut(scratch, owner);
    if (!gop.found_existing) gop.value_ptr.* = .{ .count = 0, .sum_ix = 0, .sum_iy = 0, .layer = layer };
    gop.value_ptr.count += 1;
    gop.value_ptr.sum_ix += ix;
    gop.value_ptr.sum_iy += iy;
}

/// Per-column signals collected across all layers. `wall` = frontier-adjacent
/// foreign copper (a real boundary wall); `has_foreign` = any foreign copper
/// (a `wall` column always has this too); `free` = a routable-but-unreached
/// cell; `clear` = blocked for a non-foreign-copper reason (own pad / outline).
const CellVerdict = struct {
    reached: bool = false,
    wall: bool = false,
    has_foreign: bool = false,
    clear: bool = false,
    free: bool = false,
};

/// Fold one column's verdict into the `Shape` tallies. A reached column counts
/// as interior; a wall column counts as bounding copper; a purely-free unreached
/// column feeds the open-channel (gap) centroid; interior foreign copper that
/// never touched the frontier is intentionally ignored (it is not a wall).
fn tallyColumn(acc: Accum, ix: usize, iy: usize, v: CellVerdict) void {
    if (v.reached) {
        acc.sh.reached_cells += 1;
    } else if (v.wall) {
        acc.sh.copper_cells += 1;
    } else if (v.has_foreign) {
        // Interior foreign copper the flood never reached — not a bounding wall.
    } else if (v.free) {
        acc.sh.open_cells += 1;
        acc.gap.count += 1;
        acc.gap.sum_ix += ix;
        acc.gap.sum_iy += iy;
    } else if (v.clear) {
        acc.sh.clearance_cells += 1;
    }
}

/// Mark whether the flood reached every pad / any pad past the first.
fn fillReachedPads(core: *const router.RouteCore, pts: []const router.NetPt, reached: []const bool, sh: *Shape) void {
    const grid = core.ctx.grid;
    const nodes = grid.nx * grid.ny;
    var all = true;
    var other = false;
    for (pts, 0..) |p, i| {
        const nd = grid.nearest(p.x, p.y);
        const key = @as(usize, p.layer) * nodes + grid.node(nd[0], nd[1]);
        const hit = reached[key];
        if (!hit) all = false;
        if (i > 0 and hit) other = true;
    }
    sh.reaches_all_pads = all;
    sh.reaches_other_pad = other;
}

// ── Blocker roll-up ──────────────────────────────────────────────────────────

fn buildBlockers(
    core: *const router.RouteCore,
    placement: optimizer.Placement,
    net_i: usize,
    owners: *std.AutoHashMapUnmanaged(i32, OwnerTally),
    scratch: Allocator,
) Allocator.Error![]Blocker {
    const fail_pri = priorityOf(core.result.routable, net_i);
    var ids: std.ArrayList(i32) = .empty;
    var boundary_total: u64 = 0;
    var it = owners.iterator();
    while (it.next()) |e| {
        if (e.key_ptr.* < 0) continue;
        try ids.append(scratch, e.key_ptr.*);
        boundary_total += e.value_ptr.count;
    }
    const rip = try router.collectRippable(scratch, placement, core.result.routable, ids.items, fail_pri);
    var list: std.ArrayList(Blocker) = .empty;
    var vit = owners.iterator();
    while (vit.next()) |e| {
        if (e.key_ptr.* < 0) continue;
        const t = e.value_ptr.*;
        // Per-net-normalized: each owner's share of THIS net's own bounding
        // frontier, so shares are meaningful per net and sum to ≤ 1.
        const share: f32 = if (boundary_total == 0) 0 else @as(f32, @floatFromInt(t.count)) / @as(f32, @floatFromInt(boundary_total));
        try list.append(scratch, .{
            .net = shortNetName(placement, e.key_ptr.*),
            .layer = try layerName(scratch, placement.rules, t.layer),
            .x = core.ctx.grid.worldX(t.sum_ix / t.count),
            .y = core.ctx.grid.worldY(t.sum_iy / t.count),
            .share = share,
            .rippable = isRippableId(core.result.routable, rip, e.key_ptr.*),
        });
    }
    std.sort.pdq(Blocker, list.items, {}, blockerMoreShare);
    if (list.items.len > max_blockers) list.shrinkRetainingCapacity(max_blockers);
    return list.items;
}

/// Last-resort fallback, used ONLY when the net's own frontier flood found no
/// bounding copper in its corridor but the net is search-limited or the flood
/// hit its cap (e.g. a long rail whose pads sit far apart, so the direct wall is
/// past the reached region): the router's goal-directed soft probe reports which
/// nets wall the pad-to-pad path. Their centroids are resolved by a scan
/// RESTRICTED to this net's own corridor `crop` (never a board-wide scan), so
/// even the fallback stays per-net-local; owners with no copper inside the crop
/// fall back to the crop centre. Every fallback blocker is marked with
/// `share == 0` — the discriminator from a flood-local blocker (`share > 0`).
fn fallbackBlockers(
    core: *const router.RouteCore,
    placement: optimizer.Placement,
    net_i: usize,
    crop: Crop,
    scratch: Allocator,
) Allocator.Error![]Blocker {
    const ids = try router.detectBlockers(core.ctx, placement, core.idx_of, net_i, scratch);
    if (ids.len == 0) return &.{};
    const fail_pri = priorityOf(core.result.routable, net_i);
    const rip = try router.collectRippable(scratch, placement, core.result.routable, ids, fail_pri);
    var centroids = std.AutoHashMapUnmanaged(i32, OwnerTally).empty;
    try scanOwnerCentroids(core, @intCast(net_i), crop, &centroids, scratch);
    const grid = core.ctx.grid;
    const crop_cx = grid.worldX((crop.min_ix + crop.max_ix) / 2);
    const crop_cy = grid.worldY((crop.min_iy + crop.max_iy) / 2);
    var list: std.ArrayList(Blocker) = .empty;
    for (ids) |id| {
        const t = centroids.get(id);
        try list.append(scratch, .{
            .net = shortNetName(placement, id),
            .layer = try layerName(scratch, placement.rules, if (t) |tt| tt.layer else 0),
            .x = if (t) |tt| grid.worldX(tt.sum_ix / @max(1, tt.count)) else crop_cx,
            .y = if (t) |tt| grid.worldY(tt.sum_iy / @max(1, tt.count)) else crop_cy,
            .share = 0,
            .rippable = isRippableId(core.result.routable, rip, id),
        });
        if (list.items.len >= max_blockers) break;
    }
    std.sort.pdq(Blocker, list.items, {}, blockerMoreShare);
    return list.items;
}

/// Bucket every foreign-copper cell WITHIN `crop` into its owner's world
/// centroid — the coordinate source for fallback blockers, which arrive from the
/// probe as bare net ids. Scoped to the crop (not the whole grid) so a fallback
/// blocker's location stays inside the net's own corridor.
fn scanOwnerCentroids(
    core: *const router.RouteCore,
    ni: i32,
    crop: Crop,
    out: *std.AutoHashMapUnmanaged(i32, OwnerTally),
    scratch: Allocator,
) Allocator.Error!void {
    const ctx = core.ctx;
    for (0..ctx.occ.len) |l| {
        for (crop.min_iy..crop.max_iy + 1) |iy| {
            for (crop.min_ix..crop.max_ix + 1) |ix| {
                const n = iy * ctx.grid.nx + ix;
                const o = ctx.occ[l][n];
                if (o == empty_cell or o == ni) continue;
                const gop = try out.getOrPut(scratch, o);
                if (!gop.found_existing) gop.value_ptr.* = .{ .count = 0, .sum_ix = 0, .sum_iy = 0, .layer = @intCast(l) };
                gop.value_ptr.count += 1;
                gop.value_ptr.sum_ix += ix;
                gop.value_ptr.sum_iy += iy;
            }
        }
    }
}

// ── Classification ───────────────────────────────────────────────────────────

fn classify(sh: Shape, blockers: []const Blocker, search_limited: bool) FailureMode {
    if (isSealed(sh)) return .escape_blocked;
    const rippable = countRippable(blockers);
    if (search_limited) {
        if (rippable == 0 and openCorridor(sh)) return .grid_quantization;
        return .search_budget;
    }
    // A free-space path already connects every pad, yet the maze failed on it —
    // the design's "reaches all pads but maze failed → quantization" rule. The
    // corridor exists; the router (order or grid pitch) could not thread it.
    if (sh.reaches_all_pads) return .grid_quantization;
    // The flood is walled into a pocket: the ringing copper is the real barrier.
    if (rippable > 0) return .order_congestion;
    if (blockers.len > 0) return .blocked_by_higher;
    return .grid_quantization;
}

/// The pad barely escaped its own footprint: little free space reached and no
/// other pad connected.
fn isSealed(sh: Shape) bool {
    return !sh.reaches_other_pad and sh.reached_cells <= escape_seal_cells;
}

/// The frontier is mostly open channel — the copper it pressed against is a tiny
/// fraction of the free space it reached (a sub-grid corridor, not a wall).
fn openCorridor(sh: Shape) bool {
    if (sh.reached_cells == 0) return false;
    return sh.copper_cells * 5 <= sh.reached_cells;
}

fn countRippable(blockers: []const Blocker) usize {
    var n: usize = 0;
    for (blockers) |b| {
        if (b.rippable) n += 1;
    }
    return n;
}

// ── Remedy synthesis ─────────────────────────────────────────────────────────

/// Everything the remedy builders need — the stuck net's name, its top blocker,
/// the top RIPPABLE blocker (the one a demote/reorder can actually move), the
/// open-corridor waypoint, and the diff-pair twin when the net looks paired.
const RemedyCtx = struct {
    net: []const u8,
    top: ?Blocker,
    top_rippable: ?Blocker,
    gap_x: f64,
    gap_y: f64,
    gap_layer: []const u8,
    pair_twin: []const u8,
    /// Is this net's routing order fixed by its plan wave? See `raisePriority`.
    wave_ordered: bool = false,
};

fn remedyContext(
    core: *const router.RouteCore,
    placement: optimizer.Placement,
    ref: NetRef,
    sh: Shape,
    blockers: []const Blocker,
    scratch: Allocator,
) Allocator.Error!RemedyCtx {
    return .{
        .net = ref.name,
        .wave_ordered = router.waveOrdered(core, ref.net_i),
        .top = if (blockers.len > 0) blockers[0] else null,
        .top_rippable = firstRippable(blockers),
        .gap_x = sh.gap_x,
        .gap_y = sh.gap_y,
        .gap_layer = try layerName(scratch, placement.rules, sh.gap_layer),
        .pair_twin = pairTwin(placement, ref.name, scratch) catch "",
    };
}

fn firstRippable(blockers: []const Blocker) ?Blocker {
    for (blockers) |b| {
        if (b.rippable) return b;
    }
    return null;
}

/// The "route it earlier" remedy, in the spelling that actually works for THIS
/// net — the lever shared by the congestion, budget, and quantization modes.
///
/// For an ordinary net that is a `(net-class … (priority N) (nets …))`. For one
/// named by a `(pcb-plan (route (wave …)))` wave it is NOT: the plan writes a
/// member's whole policy and takes its routing order from the wave's POSITION,
/// so a class priority reaches only the rip-up/rescue tier and the net routes
/// exactly when it did before. Emitting that form for a wave-bound net sends
/// its reader after an inert lever — measured on board-a, where the class the
/// remedy asked for produced a byte-identical board. The wave itself is the
/// lever there, so that is what is offered.
fn raisePriority(s: Allocator, rc: RemedyCtx, tier: u8, rationale: []const u8, confidence: []const u8) Allocator.Error!Remedy {
    if (rc.wave_ordered) return .{
        .kind = kind_reorder_wave,
        .dsl = try std.fmt.allocPrint(
            s,
            ";; move the (wave …) naming \"{s}\" earlier in (pcb-plan (route …))",
            .{rc.net},
        ),
        .rationale = "this net's routing order is its wave's position in the plan, which overrides any (net-class … (priority …)) — that form would change only its rip-up/rescue tier",
        .confidence = confidence,
        .target = .dsl,
    };
    return .{
        .kind = kind_raise_priority,
        .dsl = try std.fmt.allocPrint(s, "(net-class \"{s}-pri\" (priority {d}) (nets \"{s}\"))", .{ leaf(rc.net), tier, rc.net }),
        .rationale = rationale,
        .confidence = confidence,
        .target = .dsl,
    };
}

fn remediesFor(mode: FailureMode, rc: RemedyCtx, probe: ?CdtProbe, scratch: Allocator) Allocator.Error![]const Remedy {
    const base = try modeRemedies(mode, rc, scratch);
    return prependProbeRemedy(base, probe, rc, scratch);
}

fn modeRemedies(mode: FailureMode, rc: RemedyCtx, scratch: Allocator) Allocator.Error![]const Remedy {
    return switch (mode) {
        .order_congestion => congestionRemedies(rc, scratch),
        .blocked_by_higher => higherRemedies(rc, scratch),
        .search_budget => budgetRemedies(rc, scratch),
        .escape_blocked => escapeRemedies(rc, scratch),
        .grid_quantization => quantizationRemedies(rc, scratch),
        .unknown => &.{},
    };
}

/// Lead the remedy list with the CDT probe's verdict — the sharpened, higher-
/// confidence signal an obstacle-controlled experiment gives that the flood shape
/// cannot. Each fork's leading remedy carries the right target so the agent knows
/// immediately whether to edit the plan (congestion) or accept a code/placement
/// limit (geometry limit / maze gap). No probe → the mode's remedies verbatim.
fn prependProbeRemedy(base: []const Remedy, probe: ?CdtProbe, rc: RemedyCtx, s: Allocator) Allocator.Error![]const Remedy {
    const p = probe orelse return base;
    const lead: Remedy = switch (probeFork(p)) {
        .congestion => .{
            .kind = "cdt_congestion",
            .dsl = try std.fmt.allocPrint(s, "(net-class \"{s}-pri\" (priority {d}) (nets \"{s}\"))", .{ leaf(rc.net), congestion_priority, rc.net }),
            .rationale = "CDT threads this corridor with foreign copper removed, not against the copper there now — congestion, not a router limit: route it earlier (priority or earlier wave)",
            .confidence = "high",
            .target = .dsl,
        },
        .geometry_limit => .{
            .kind = "cdt_geometry_limit",
            .dsl = "",
            .rationale = "CDT finds no path even with every foreign net removed — the corridor is sealed by pad/board geometry; no priority edit reopens it: move the part or widen the channel",
            .confidence = "high",
            .target = .code,
        },
        .maze_gap => .{
            .kind = "cdt_maze_gap",
            .dsl = "",
            .rationale = "CDT threads this corridor against the current copper yet the maze failed — a router/grid-pitch limit, not a plan issue; the CDT rescue tier or a finer grid routes it",
            .confidence = "med",
            .target = .code,
        },
    };
    var list: std.ArrayList(Remedy) = .empty;
    try list.append(s, lead);
    try list.appendSlice(s, base);
    return list.items;
}

fn congestionRemedies(rc: RemedyCtx, s: Allocator) Allocator.Error![]const Remedy {
    var list: std.ArrayList(Remedy) = .empty;
    const why = try std.fmt.allocPrint(s, "{s} is boxed by lower/equal-priority routed copper; a higher priority routes it first, before that copper claims the channel", .{rc.net});
    try list.append(s, try raisePriority(s, rc, congestion_priority, why, "high"));
    try list.append(s, .{
        .kind = "route_wave",
        .dsl = try std.fmt.allocPrint(s, "(pcb-plan (route (wave \"{s}-first\" (nets \"{s}\") (reason \"route before power\"))))", .{ leaf(rc.net), rc.net }),
        .rationale = "order this net ahead of the congesting nets in an explicit routing wave",
        .confidence = "high",
        .target = .dsl,
    });
    if (rc.top_rippable) |b| try list.append(s, .{
        .kind = "demote_blocker",
        .dsl = try std.fmt.allocPrint(s, "; Move the existing wave owning {s} after the wave owning {s}, preserving its selectors and policies. Do not append a duplicate wave.", .{ b.net, rc.net }),
        .rationale = try std.fmt.allocPrint(s, "move the existing owning wave for blocker {s} later; first-wave ownership means an appended selector cannot override it", .{b.net}),
        .confidence = "med",
        .target = .dsl,
    });
    return list.items;
}

fn higherRemedies(rc: RemedyCtx, s: Allocator) Allocator.Error![]const Remedy {
    var list: std.ArrayList(Remedy) = .empty;
    try list.append(s, .{
        .kind = kind_waypoint,
        .dsl = try std.fmt.allocPrint(s, "(pcb-plan (route (wave \"{s}-detour\" (nets \"{s}\") (waypoints (at {d:.1} {d:.1} \"{s}\")))))", .{ leaf(rc.net), rc.net, rc.gap_x, rc.gap_y, rc.gap_layer }),
        .rationale = "route through the open channel; the net is walled by protected/higher-priority copper and must detour",
        .confidence = "med",
        .target = .dsl,
    });
    const blocker = if (rc.top) |b| b.net else "protected copper";
    try list.append(s, .{
        .kind = "accept",
        .dsl = try std.fmt.allocPrint(s, "(pcb-plan (route (wave \"{s}\" (nets \"{s}\") (reason \"conflicts with protected {s} — hand-route or accept unrouted\"))))", .{ leaf(rc.net), rc.net, blocker }),
        .rationale = "the wall is a plane/pour/ground or a strictly higher-priority net the router never rips; sign off or hand-route",
        .confidence = "low",
        .target = .dsl,
    });
    return list.items;
}

fn budgetRemedies(rc: RemedyCtx, s: Allocator) Allocator.Error![]const Remedy {
    var list: std.ArrayList(Remedy) = .empty;
    const why = "the unguided maze hit its expansion budget; routing this net earlier gives it the open board so its path is found within budget";
    try list.append(s, try raisePriority(s, rc, budget_priority, why, "high"));
    try list.append(s, .{
        .kind = kind_waypoint,
        .dsl = try std.fmt.allocPrint(s, "(pcb-plan (route (wave \"{s}-guide\" (nets \"{s}\") (waypoints (at {d:.1} {d:.1} \"{s}\")))))", .{ leaf(rc.net), rc.net, rc.gap_x, rc.gap_y, rc.gap_layer }),
        .rationale = "a waypoint through the open corridor shortens the search so it completes within budget",
        .confidence = "med",
        .target = .dsl,
    });
    if (rc.top == null) try list.append(s, .{
        .kind = "info",
        .dsl = "",
        .rationale = "budget-bound with no copper to blame — the router already escalated its rip-up/expansion passes; a waypoint or higher priority is the remaining lever",
        .confidence = "med",
        .target = .dsl,
    });
    return list.items;
}

fn escapeRemedies(rc: RemedyCtx, s: Allocator) Allocator.Error![]const Remedy {
    var list: std.ArrayList(Remedy) = .empty;
    try list.append(s, .{
        .kind = "open_escape",
        .dsl = try std.fmt.allocPrint(s, "(net-class \"{s}-esc\" (escape 0) (nets \"{s}\"))", .{ leaf(rc.net), rc.net }),
        .rationale = "the pad cannot leave its own footprint — copper/pads seal every exit; (escape 0) drops the forced straight break-out so the pad can turn immediately",
        .confidence = "high",
        .target = .dsl,
    });
    try list.append(s, .{
        .kind = "open_layer",
        .dsl = try std.fmt.allocPrint(s, "(pcb-plan (route (wave \"{s}-esc\" (nets \"{s}\") (allowed-layers \"" ++ board_layers.f_cu ++ "\" \"" ++ board_layers.b_cu ++ "\"))))", .{ leaf(rc.net), rc.net }),
        .rationale = "open another copper layer so the sealed pad can via out of the congested face",
        .confidence = "med",
        .target = .dsl,
    });
    if (rc.pair_twin.len > 0) try list.append(s, .{
        .kind = "diff_pair",
        .dsl = try std.fmt.allocPrint(s, "(net-class \"{s}-pair\" (diff-pair 0.2) (nets \"{s}\" \"{s}\"))", .{ leaf(rc.net), rc.net, rc.pair_twin }),
        .rationale = try std.fmt.allocPrint(s, "this looks like a differential leg of {s}; declaring the pair routes the twin into a matched corridor together", .{rc.pair_twin}),
        .confidence = "med",
        .target = .dsl,
    });
    return list.items;
}

fn quantizationRemedies(rc: RemedyCtx, s: Allocator) Allocator.Error![]const Remedy {
    var list: std.ArrayList(Remedy) = .empty;
    // A free path exists but the maze failed on it. Try the cheap DSL levers
    // first (route this net earlier / steer it through the corridor)…
    const why = "an open path exists but the maze failed to thread it; routing this net earlier gives it the corridor before other copper narrows it";
    try list.append(s, try raisePriority(s, rc, congestion_priority, why, "high"));
    try list.append(s, .{
        .kind = kind_waypoint,
        .dsl = try std.fmt.allocPrint(s, "(pcb-plan (route (wave \"{s}-guide\" (nets \"{s}\") (waypoints (at {d:.1} {d:.1} \"{s}\")))))", .{ leaf(rc.net), rc.net, rc.gap_x, rc.gap_y, rc.gap_layer }),
        .rationale = "steer the route through the open channel; may not help if the channel is narrower than the routing grid pitch",
        .confidence = "med",
        .target = .dsl,
    });
    // …then the honest fallback: if reordering and waypoints don't take, the
    // corridor is sub-grid-narrow and only a finer grid / CDT router opens it.
    try list.append(s, .{
        .kind = "router_fix",
        .dsl = "",
        .rationale = "if the DSL levers above don't route it, the corridor is sub-grid-narrow — no constraint reopens it; needs a finer routing grid or a CDT/shape-based router (code change)",
        .confidence = "med",
        .target = .code,
    });
    return list.items;
}

fn whyText(mode: FailureMode, net: []const u8, blockers: []const Blocker, s: Allocator) Allocator.Error![]const u8 {
    const top = if (blockers.len > 0) blockers[0].net else "";
    return switch (mode) {
        .order_congestion => std.fmt.allocPrint(s, "{s} was walled in by lower/equal-priority copper (chiefly {s}) that routed first", .{ net, top }),
        .blocked_by_higher => std.fmt.allocPrint(s, "{s} is ringed only by protected copper (chiefly {s}) the router never rips", .{ net, top }),
        .search_budget => std.fmt.allocPrint(s, "{s}'s unguided maze search reached its expansion budget before connecting all pads", .{net}),
        .escape_blocked => std.fmt.allocPrint(s, "{s}'s first pad could not break out of its own footprint — every exit is sealed", .{net}),
        .grid_quantization => std.fmt.allocPrint(s, "{s} has a free-space path to its pads, but the maze could not thread it — reorder it first or the corridor is sub-grid-narrow", .{net}),
        .unknown => std.fmt.allocPrint(s, "{s} failed for an unclassified reason", .{net}),
    };
}

// ── Small helpers ────────────────────────────────────────────────────────────

fn indexOfNet(placement: optimizer.Placement, name: []const u8) ?usize {
    for (placement.nets, 0..) |n, i| {
        if (std.mem.eql(u8, n.name, name)) return i;
    }
    return null;
}

fn containsIndex(haystack: []const usize, needle: usize) bool {
    for (haystack) |h| {
        if (h == needle) return true;
    }
    return false;
}

fn priorityOf(routable: []const router.RipNet, net_i: usize) u64 {
    for (routable) |rn| {
        if (rn.net_i == net_i) return rn.pri;
    }
    return 0;
}

fn isRippableId(routable: []const router.RipNet, rip: []const usize, net_id: i32) bool {
    for (rip) |idx| {
        if (idx < routable.len and routable[idx].net_i == @as(usize, @intCast(net_id))) return true;
    }
    return false;
}

fn shortNetName(placement: optimizer.Placement, id: i32) []const u8 {
    const i: usize = @intCast(id);
    if (i >= placement.nets.len) return "?";
    return leaf(placement.nets[i].name);
}

/// The module-local leaf of a possibly sub-block-prefixed net name (drops a
/// leading `slug/` path), so remedies name the net the way the source does.
const leaf = net_name.leaf;

/// KiCad copper-layer name for a routed track's SIGNAL index, for the
/// human-readable remedies — resolved through THIS board's stackup
/// (`rules.signalLayerName`), the same authority `escape_assign` spells the
/// layer of a `(pcb-plan …)` wave with.
///
/// A signal index is not a stack position: a `(plane …)` claims an inner layer
/// and the routable ones close up behind it. Reading the index AS a stack
/// position (`board_layers.StackIndex.of(layer)`, what this did) is exact only
/// where no plane claims an inner layer, and board-a declares two — so its
/// In2.Cu blockers printed "In1.Cu" and its In3.Cu blockers "In2.Cu", one layer
/// off each, naming In1.Cu, which that board's router cannot lay a track on at
/// all. During the routing campaign that made plan-compliant copper read as a
/// layer-contract violation in `stuck[]`.
fn layerName(scratch: Allocator, rules: optimizer.BoardRules, layer: u8) Allocator.Error![]const u8 {
    var buf: [board_layers.name_buf_len]u8 = undefined;
    return scratch.dupe(u8, rules.signalLayerName(layer, &buf));
}

/// The differential twin of `name` (swaps a trailing +/- or _P/_N/P/N), when
/// that twin actually exists in the netlist — else "" (not a pair).
fn pairTwin(placement: optimizer.Placement, name: []const u8, scratch: Allocator) Allocator.Error![]const u8 {
    const twin = twinName(name, scratch) catch return "";
    if (twin.len == 0) return "";
    if (indexOfNet(placement, twin) != null) return twin;
    return "";
}

fn twinName(name: []const u8, scratch: Allocator) Allocator.Error![]const u8 {
    if (name.len == 0) return "";
    const last = name[name.len - 1];
    const head = name[0 .. name.len - 1];
    if (last == '+') return std.fmt.allocPrint(scratch, "{s}-", .{head});
    if (last == '-') return std.fmt.allocPrint(scratch, "{s}+", .{head});
    if (name.len >= 2 and name[name.len - 2] == '_') {
        if (last == 'P' or last == 'p') return std.fmt.allocPrint(scratch, "{s}N", .{head});
        if (last == 'N' or last == 'n') return std.fmt.allocPrint(scratch, "{s}P", .{head});
    }
    return "";
}

fn midX(pts: []const router.NetPt) f64 {
    return 0.5 * (pts[0].x + pts[pts.len - 1].x);
}
fn midY(pts: []const router.NetPt) f64 {
    return 0.5 * (pts[0].y + pts[pts.len - 1].y);
}

fn blockerMoreShare(_: void, a: Blocker, b: Blocker) bool {
    if (a.share != b.share) return a.share > b.share;
    return std.mem.lessThan(u8, a.net, b.net);
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const geometry = @import("geometry.zig");
const flat_netlist = @import("../flat_netlist.zig");

/// Route `placement` fresh (no plan) and diagnose its residual stuck nets — the
/// test-facing twin of `route_plan.routePlannedDiagnostic`.
fn routeAndDiagnose(alloc: Allocator, placement: optimizer.Placement, params: router.RouteParams) ![]const Diagnosis {
    const fin = try router.routeCoreFinished(alloc, placement, params, .{}, .off);
    if (fin.core) |core| return capture(&core, fin.result, placement, alloc);
    return &.{};
}

fn passivePart(ref: []const u8, x: f64, y: f64, pads: []const geometry.Pad) optimizer.Part {
    return .{ .ref_des = ref, .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = pads, .fallback = false, .x = x, .y = y };
}

fn findMode(diags: []const Diagnosis, mode: []const u8) ?Diagnosis {
    for (diags) |d| {
        if (std.mem.eql(u8, d.failure_mode, mode)) return d;
    }
    return null;
}

fn hasRemedyKind(remedies: []const Remedy, kind: []const u8) bool {
    for (remedies) |r| {
        if (std.mem.eql(u8, r.kind, kind)) return true;
    }
    return false;
}

fn hasCodeRemedy(remedies: []const Remedy) bool {
    for (remedies) |r| {
        if (r.target == .code and r.dsl.len == 0) return true;
    }
    return false;
}

fn dslOfKind(remedies: []const Remedy, kind: []const u8) []const u8 {
    for (remedies) |r| {
        if (std.mem.eql(u8, r.kind, kind)) return r.dsl;
    }
    return "";
}

// spec: Web Server - a stuck net whose routing order comes from a plan wave is offered the wave-reorder lever, never the net-class priority form that cannot move it
test "a wave-bound stuck net is offered its wave, not an inert priority class" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ordinary = try raisePriority(a, .{
        .net = "SPI_SCK",
        .top = null,
        .top_rippable = null,
        .gap_x = 0,
        .gap_y = 0,
        .gap_layer = "F.Cu",
        .pair_twin = "",
    }, 4, "routes it before the copper now in its way", "high");
    try testing.expectEqualStrings("raise_priority", ordinary.kind);
    try testing.expect(std.mem.indexOf(u8, ordinary.dsl, "(priority 4)") != null);

    // The same net, named by a plan wave: the class form would change only its
    // rip-up tier, so the wave that owns its order is what is offered instead.
    const wave_bound = try raisePriority(a, .{
        .net = "SPI_SCK",
        .top = null,
        .top_rippable = null,
        .gap_x = 0,
        .gap_y = 0,
        .gap_layer = "F.Cu",
        .pair_twin = "",
        .wave_ordered = true,
    }, 4, "routes it before the copper now in its way", "high");
    try testing.expectEqualStrings("reorder_wave", wave_bound.kind);
    try testing.expect(std.mem.indexOf(u8, wave_bound.dsl, "(priority") == null);
    try testing.expect(std.mem.indexOf(u8, wave_bound.dsl, "(wave") != null);
    try testing.expect(std.mem.indexOf(u8, wave_bound.dsl, "SPI_SCK") != null);
    try testing.expect(std.mem.indexOf(u8, wave_bound.rationale, "wave's position") != null);
}

// spec: Web Server - pcb-describe stuck diagnostics name the rippable equal-priority net boxing a congested net
test "an order-congested net names its rippable copper blocker with a priority remedy" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A frontier ringed by a routed net's copper the rip-up predicate deems
    // rippable (equal/lower priority, not a plane): order congestion.
    const blockers = [_]Blocker{.{ .net = "V_6VA", .layer = "B.Cu", .x = 4.1, .y = 1.9, .share = 0.6, .rippable = true }};
    const sh = Shape{ .reached_cells = 220, .copper_cells = 40, .reaches_other_pad = false };
    const mode = classify(sh, &blockers, false);
    try testing.expectEqualStrings("order_congestion", mode.name());
    const rc = try remedyCtxFor("SPI_SCK", blockers[0]);
    const remedies = try remediesFor(mode, rc, null, a);
    try testing.expect(hasRemedyKind(remedies, "raise_priority"));
    const dsl = dslOfKind(remedies, "raise_priority");
    try testing.expect(std.mem.indexOf(u8, dsl, "(net-class") != null);
    try testing.expect(std.mem.indexOf(u8, dsl, "(priority 4)") != null);
    try testing.expect(std.mem.indexOf(u8, dsl, "SPI_SCK") != null);
    // The demote-blocker remedy names the actual rippable blocker.
    try testing.expect(std.mem.indexOf(u8, dslOfKind(remedies, "demote_blocker"), "V_6VA") != null);
    try testing.expect(std.mem.indexOf(u8, dslOfKind(remedies, "demote_blocker"), "(rest)") == null);
    try testing.expect(std.mem.indexOf(u8, dslOfKind(remedies, "demote_blocker"), "existing wave") != null);
}

fn remedyCtxFor(net: []const u8, top: Blocker) !RemedyCtx {
    return .{ .net = net, .top = top, .top_rippable = top, .gap_x = 4, .gap_y = 2, .gap_layer = board_layers.f_cu, .pair_twin = "" };
}

// spec: Web Server - a stuck-net blocker names its copper layer through the board's own stackup, so a declared inner plane does not shift every inner name by one
test "a blocker layer name follows the board's declared planes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    // board-a's stackup: `(stackup 6 (plane 2 "GND") (plane 5 "GND"))`, so the
    // routable inners are stack 3 and 4 — In2.Cu and In3.Cu. Reading a SIGNAL
    // index as a stack position named them In1.Cu and In2.Cu, and In1.Cu is the
    // plane, a layer this board's router cannot lay a track on at all.
    const declared = [_]optimizer.PlaneAt{ .{ .index = 2, .net = "GND" }, .{ .index = 5, .net = "GND" } };
    const six = optimizer.BoardRules{ .plane_nets = &.{}, .copper_layers = 6, .planes = .{ .declared = &declared } };
    try testing.expectEqualStrings(board_layers.f_cu, try layerName(a, six, 0));
    try testing.expectEqualStrings(board_layers.b_cu, try layerName(a, six, 1));
    try testing.expectEqualStrings("In2.Cu", try layerName(a, six, 2));
    try testing.expectEqualStrings("In3.Cu", try layerName(a, six, 3));

    // A board with no plane claiming an inner layer is unchanged: there the two
    // readings agree, which is why this went unnoticed on the plain stackups.
    const plain = optimizer.BoardRules{ .plane_nets = &.{}, .copper_layers = 4 };
    try testing.expectEqualStrings("In1.Cu", try layerName(a, plain, 2));
    try testing.expectEqualStrings("In2.Cu", try layerName(a, plain, 3));
}

// spec: Web Server - pcb-describe stuck diagnostics flag a sealed pad as escape-blocked with an escape remedy
test "a pad sealed by through-hole copper reads as escape-blocked end to end" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const up = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.3, .h = 0.3 }};
    // Through-hole wall pads exist on BOTH copper layers, so U1's SMD pad is
    // physically sealed — no via escape — and its net to the far R9 pad fails.
    var parts = [_]optimizer.Part{
        passivePart("U1", 0, 0, &up),
        passivePart("R9", 0, 3, &up),
        passivePart("WN", 0, -0.55, &thruPad),
        passivePart("WS", 0, 0.55, &thruPad),
        passivePart("WE", 0.55, 0, &thruPad),
        passivePart("WW", -0.55, 0, &thruPad),
        passivePart("WA", 0.5, -0.5, &thruPad),
        passivePart("WB", -0.5, -0.5, &thruPad),
        passivePart("WC", 0.5, 0.5, &thruPad),
        passivePart("WD", -0.5, 0.5, &thruPad),
    };
    const s_pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "R9", .pin = "1" } };
    const w_pins = wallRing();
    const nets = [_]optimizer.FlatNet{ .{ .name = "S", .pins = &s_pins }, .{ .name = "W", .pins = &w_pins } };
    const diags = try routeAndDiagnose(a, sealPlacement(&parts, &nets), .{ .track_width = 0.2, .clearance = 0.2 });
    const d = findMode(diags, "escape_blocked") orelse return error.NoEscapeBlock;
    try testing.expect(hasRemedyKind(d.remedies, "open_escape"));
    try testing.expect(std.mem.indexOf(u8, dslOfKind(d.remedies, "open_escape"), "(escape 0)") != null);
}

const thruPad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6, .thru = true, .drill = 0.3 }};

fn wallRing() [8]flat_netlist.FlatPin {
    return .{
        .{ .ref_des = "WN", .pin = "1" }, .{ .ref_des = "WS", .pin = "1" },
        .{ .ref_des = "WE", .pin = "1" }, .{ .ref_des = "WW", .pin = "1" },
        .{ .ref_des = "WA", .pin = "1" }, .{ .ref_des = "WB", .pin = "1" },
        .{ .ref_des = "WC", .pin = "1" }, .{ .ref_des = "WD", .pin = "1" },
    };
}

fn sealPlacement(parts: []optimizer.Part, nets: []const optimizer.FlatNet) optimizer.Placement {
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
        .maxx = 1,
        .maxy = 3.3,
        .board_rect = .{ .minx = -1, .miny = -1, .w = 2, .h = 4.3 },
        .generated = true,
        .rules = .{ .copper_layers = 2 },
    };
}

// spec: Web Server - a stuck net with an open sub-grid corridor and no rippable copper yields a router-code remedy
test "an open sub-grid corridor forks to a router-code remedy" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A broadly-reached frontier (500 cells) with no ringing copper on a
    // search-limited net: the corridor is open but sub-grid-narrow.
    const sh = Shape{ .reached_cells = 500, .copper_cells = 0, .open_cells = 400, .reaches_other_pad = false };
    const mode = classify(sh, &.{}, true);
    try testing.expectEqualStrings("grid_quantization", mode.name());
    const rc = RemedyCtx{ .net = "EN_UV", .top = null, .top_rippable = null, .gap_x = 4.2, .gap_y = 1.5, .gap_layer = "F.Cu", .pair_twin = "" };
    const remedies = try remediesFor(mode, rc, null, a);
    try testing.expect(hasCodeRemedy(remedies));
    try testing.expect(hasRemedyKind(remedies, "router_fix"));
    // The fork also offers a low-confidence DSL waypoint the agent can try first.
    try testing.expect(hasRemedyKind(remedies, "waypoint"));
    try testing.expect(std.mem.indexOf(u8, dslOfKind(remedies, "waypoint"), "(waypoints (at 4.2 1.5") != null);
}

// spec: Web Server - the CDT probe forks a copper-blocked isolation-routable net to congestion, an isolation-blocked net to a geometry limit, and a both-routable net to a maze gap
test "the CDT probe forks congestion, geometry limit, and maze gap by its two verdicts" {
    // Foreign copper fills an otherwise-open corridor → congestion (dsl).
    try testing.expectEqual(ProbeFork.congestion, probeFork(.{ .isolation = .routable, .with_copper = .blocked }));
    // No path even with the board emptied → a geometry limit (code/placement).
    try testing.expectEqual(ProbeFork.geometry_limit, probeFork(.{ .isolation = .blocked, .with_copper = .blocked }));
    // CDT threads it against live copper yet the maze failed → a maze gap (code).
    try testing.expectEqual(ProbeFork.maze_gap, probeFork(.{ .isolation = .routable, .with_copper = .routable }));
}

// spec: Web Server - the CDT congestion verdict upgrades a code-target or unclassified stuck mode to order-congestion while leaving a genuine order mode intact
test "the CDT congestion verdict upgrades only a code-target or unclassified mode" {
    const congested = CdtProbe{ .isolation = .routable, .with_copper = .blocked };
    // A grid_quantization (code) or unknown verdict the probe proves is really an
    // occupied-but-open corridor is upgraded to the dsl reorder mode…
    try testing.expectEqual(FailureMode.order_congestion, reviseMode(.grid_quantization, congested));
    try testing.expectEqual(FailureMode.order_congestion, reviseMode(.unknown, congested));
    // …but a genuine order-aware mode keeps its per-net blocker attribution.
    try testing.expectEqual(FailureMode.blocked_by_higher, reviseMode(.blocked_by_higher, congested));
    // A geometry-limit verdict never rewrites the mode (its signal is the remedy).
    const sealed = CdtProbe{ .isolation = .blocked, .with_copper = .blocked };
    try testing.expectEqual(FailureMode.grid_quantization, reviseMode(.grid_quantization, sealed));
    // No probe at all leaves the mode untouched.
    try testing.expectEqual(FailureMode.unknown, reviseMode(.unknown, null));
}

// spec: Web Server - the CDT probe verdict leads the remedy list with a dsl reorder for congestion and a code fix for a geometry limit or maze gap
test "the CDT probe leads the remedy list with the right target per fork" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const rc = RemedyCtx{ .net = "EN_UV", .top = null, .top_rippable = null, .gap_x = 0, .gap_y = 0, .gap_layer = "F.Cu", .pair_twin = "" };
    // Congestion: the leading remedy is a high-confidence dsl reorder naming the net.
    const cong = try remediesFor(.grid_quantization, rc, .{ .isolation = .routable, .with_copper = .blocked }, a);
    try testing.expectEqualStrings("cdt_congestion", cong[0].kind);
    try testing.expectEqual(Target.dsl, cong[0].target);
    try testing.expect(std.mem.indexOf(u8, cong[0].dsl, "EN_UV") != null);
    // Geometry limit: the leading remedy is a code fix with no dsl snippet.
    const geo = try remediesFor(.grid_quantization, rc, .{ .isolation = .blocked, .with_copper = .blocked }, a);
    try testing.expectEqualStrings("cdt_geometry_limit", geo[0].kind);
    try testing.expectEqual(Target.code, geo[0].target);
    try testing.expectEqual(@as(usize, 0), geo[0].dsl.len);
    // Maze gap: a code fix flagging the router beat the maze where the plan can't help.
    const gap = try remediesFor(.grid_quantization, rc, .{ .isolation = .routable, .with_copper = .routable }, a);
    try testing.expectEqualStrings("cdt_maze_gap", gap[0].kind);
    try testing.expectEqual(Target.code, gap[0].target);
}

// spec: Web Server - the CDT probe's window obstacle count includes a track or via whose box overlaps the window and excludes one clear of it
test "the probe window obstacle count sees overlapping copper and skips clear copper" {
    const rect = fine_window.WindowRect{ .x0 = 0, .y0 = 0, .x1 = 2, .y1 = 2 };
    const tracks = [_]router.Track{
        .{ .x1 = 1, .y1 = -1, .x2 = 1, .y2 = 3, .layer = 0, .width = 0.2, .net = 5 }, // crosses the window
        .{ .x1 = 10, .y1 = 10, .x2 = 12, .y2 = 12, .layer = 0, .width = 0.2, .net = 6 }, // clear of it
    };
    const vias = [_]router.Via{
        .{ .x = 1, .y = 1, .dia = 0.4, .net = 7 }, // inside
        .{ .x = 9, .y = 9, .dia = 0.4, .net = 8 }, // clear
    };
    // One overlapping track + one overlapping via.
    try testing.expectEqual(@as(usize, 2), windowObstacleCount(rect, &tracks, &vias));
    // Isolation passes no copper, so it always counts zero.
    try testing.expectEqual(@as(usize, 0), windowObstacleCount(rect, &.{}, &.{}));
}

// spec: Web Server - the CDT probe reads a with-copper corridor as blocked when the isolation path runs within clearance of a routed track
test "the probe flags an isolation path grazing a routed track as copper-occupied" {
    const path = [_][2]f64{ .{ 0, 0 }, .{ 4, 0 } }; // isolation path along y=0
    // A track sitting right on the path is within clearance → the copper occupies it.
    const near = [_]router.Track{.{ .x1 = 2, .y1 = 0.05, .x2 = 2, .y2 = 1, .layer = 0, .width = 0.2, .net = 9 }};
    try testing.expect(pathHitsCopper(&path, &near, &.{}, 0.2, 0.2));
    // The same track moved well clear of the path leaves the corridor open.
    const clear = [_]router.Track{.{ .x1 = 2, .y1 = 5, .x2 = 2, .y2 = 6, .layer = 0, .width = 0.2, .net = 9 }};
    try testing.expect(!pathHitsCopper(&path, &clear, &.{}, 0.2, 0.2));
}

// spec: Web Server - stuck-net blocker attribution crops to each net's own pad corridor, so nets with disjoint pads get disjoint attribution windows
test "padCrop bounds blocker attribution to each net's own pad corridor" {
    const grid = router.Grid{ .ox = 0, .oy = 0, .g = 0.2, .nx = 400, .ny = 400 };
    const near = [_]router.NetPt{ .{ .x = 1, .y = 1, .layer = 0 }, .{ .x = 2, .y = 2, .layer = 0 } };
    const far = [_]router.NetPt{ .{ .x = 40, .y = 40, .layer = 0 }, .{ .x = 42, .y = 41, .layer = 0 } };
    const ca = padCrop(grid, &near);
    const cb = padCrop(grid, &far);
    // The near crop hugs cells 5..10 (1..2 mm at 0.2-mm pitch) plus a small margin.
    try testing.expect(ca.min_ix <= 5 and ca.max_ix >= 10 and ca.max_ix < 20);
    // The far crop hugs cells ~200 — a wholly disjoint window, so the two nets
    // can never share a board-wide copper tally.
    try testing.expect(cb.min_ix > ca.max_ix);
    try testing.expect(cb.min_iy > ca.max_iy);
}

// spec: Web Server - stuck-net blocker shares are per-net-normalized and a goal-directed-probe fallback blocker is marked with share 0
test "blocker shares normalize per net and a fallback blocker is marked share 0" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var parts = wallParts();
    const wt = [_]flat_netlist.FlatPin{ .{ .ref_des = "A1", .pin = "1" }, .{ .ref_des = "A2", .pin = "1" } };
    const wb = [_]flat_netlist.FlatPin{ .{ .ref_des = "BA1", .pin = "1" }, .{ .ref_des = "BA2", .pin = "1" } };
    const ws = [_]flat_netlist.FlatPin{ .{ .ref_des = "S0", .pin = "1" }, .{ .ref_des = "S1", .pin = "1" } };
    const nets = [_]optimizer.FlatNet{
        .{ .name = "WALL_T", .pins = &wt },
        .{ .name = "WALL_B", .pins = &wb },
        .{ .name = "STUCK", .pins = &ws },
    };
    const placement = wallPlacement(&parts, &nets);
    const core = try coreFor(a, placement, .{ .track_width = 0.2, .clearance = 0.2 });
    // Flood-local rollup: a per-net bounding-copper tally normalizes each owner's
    // share against THIS net's own boundary — > 0, descending, summing to ≤ 1.
    var owners = std.AutoHashMapUnmanaged(i32, OwnerTally).empty;
    try owners.put(a, 0, .{ .count = 30, .sum_ix = 0, .sum_iy = 0, .layer = 0 });
    try owners.put(a, 1, .{ .count = 10, .sum_ix = 0, .sum_iy = 0, .layer = 0 });
    const local = try buildBlockers(&core, placement, 2, &owners, a);
    try testing.expectEqual(@as(usize, 2), local.len);
    try testing.expect(local[0].share > local[1].share);
    try testing.expect(local[1].share > 0);
    try testing.expect(local[0].share + local[1].share <= 1.0 + 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0.75), local[0].share, 1e-4);
    // Fallback path: the WALL_T/WALL_B copper walls STUCK on both layers, so the
    // goal-directed probe must cross a wall and reports it — marked with share 0,
    // the discriminator from a flood-local (> 0) blocker.
    router.setNetParams(core.ctx, placement, 2);
    const pts = try router.netPoints(a, placement, core.idx_of, placement.nets[2]);
    const fb = try fallbackBlockers(&core, placement, 2, padCrop(core.ctx.grid, pts), a);
    try testing.expect(fb.len >= 1);
    try testing.expect(allShareZero(fb));
}

fn allShareZero(fb: []const Blocker) bool {
    for (fb) |b| {
        if (b.share != 0) return false;
    }
    return true;
}

fn coreFor(alloc: Allocator, placement: optimizer.Placement, params: router.RouteParams) !router.RouteCore {
    const fin = try router.routeCoreFinished(alloc, placement, params, .{}, .off);
    return fin.core orelse error.NoCore;
}

/// One 0.3-mm pad at the part origin — the shared footprint for the wall board.
const one_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.3, .h = 0.3 }};

/// Six single-pad parts forming a channel walled on BOTH copper layers at x=6.5.
/// A1/A2's WALL_T routes a full-height vertical wall on the top layer and
/// BA1/BA2's WALL_B the same on the bottom layer. The pads sit at the board's
/// top and bottom EDGES (y≈0.4 / 9.6), so the STUCK net's y=5 crossing line
/// meets pure ROUTED TRACK copper (soft-crossable at a penalty), not a pad
/// clearance halo (a hard block the probe cannot cross). The tracks span the
/// board and the edge pads close the ends, so on both layers there is no detour:
/// the goal-directed probe must cross a wall's copper and reports it. (The board
/// always has two signal layers, so a one-layer wall alone would be vias-around.)
fn wallParts() [6]optimizer.Part {
    var parts = [_]optimizer.Part{
        passivePart("A1", 6.5, 0.4, &one_pad),
        passivePart("A2", 6.5, 9.6, &one_pad),
        passivePart("BA1", 6.5, 0.4, &one_pad),
        passivePart("BA2", 6.5, 9.6, &one_pad),
        passivePart("S0", 0.5, 5.0, &one_pad),
        passivePart("S1", 12.5, 5.0, &one_pad),
    };
    parts[2].side = .bottom;
    parts[3].side = .bottom;
    return parts;
}

fn wallPlacement(parts: []optimizer.Part, nets: []const optimizer.FlatNet) optimizer.Placement {
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 13,
        .maxy = 10,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 13, .h = 10 },
        .generated = true,
        .rules = .{ .copper_layers = 1 },
    };
}

/// The stacked-pairs footprint: one 0.4 mm pad at the part origin.
const stacked_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};

/// A many-failure board built cheaply: parts plus `n` two-pad nets.
const StackedBoard = struct { parts: []optimizer.Part, nets: []optimizer.FlatNet };

/// `n` two-pad nets whose pads ALL stack at the same two spots — at most a
/// couple of nets can own that copper, so nearly all fail, and each failure is
/// instant (the source pad sits sealed under foreign pads), keeping the
/// fixture fast despite the failure count.
fn stackedPairs(a: Allocator, n: usize) !StackedBoard {
    var parts: std.ArrayList(optimizer.Part) = .empty;
    var nets: std.ArrayList(optimizer.FlatNet) = .empty;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const ar = try std.fmt.allocPrint(a, "A{d}", .{i});
        const br = try std.fmt.allocPrint(a, "B{d}", .{i});
        try parts.append(a, passivePart(ar, 0, 0, &stacked_pad));
        try parts.append(a, passivePart(br, 0, 3, &stacked_pad));
        const pins = try a.dupe(flat_netlist.FlatPin, &.{
            .{ .ref_des = ar, .pin = "1" },
            .{ .ref_des = br, .pin = "1" },
        });
        try nets.append(a, .{ .name = try std.fmt.allocPrint(a, "N{d}", .{i}), .pins = pins });
    }
    return .{ .parts = parts.items, .nets = nets.items };
}

// spec: Web Server - stuck-net diagnosis is hard-capped so a heavily-failed board cannot stall the route response
test "stuck diagnosis is hard-capped on a heavily-failed board" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const params = router.RouteParams{ .track_width = 0.2, .clearance = 0.2 };
    // Well past the cap: 20 stacked net pairs leave (nearly) every net failed,
    // yet only the first max_stuck get the expensive full diagnosis — the
    // remainder still reach clients through the result's failed/unrouted list.
    const big = try stackedPairs(a, 20);
    const fin = try router.routeCoreFinished(a, sealPlacement(big.parts, big.nets), params, .{}, .off);
    const core = fin.core orelse return error.NoCore;
    try testing.expect(fin.result.failed.len > max_stuck);
    const capped = try capture(&core, fin.result, sealPlacement(big.parts, big.nets), a);
    try testing.expectEqual(max_stuck, capped.len);
    // Below the cap the behavior is unchanged: every failed net is diagnosed.
    const small = try stackedPairs(a, 3);
    const fin2 = try router.routeCoreFinished(a, sealPlacement(small.parts, small.nets), params, .{}, .off);
    const core2 = fin2.core orelse return error.NoCore;
    const full = try capture(&core2, fin2.result, sealPlacement(small.parts, small.nets), a);
    try testing.expect(fin2.result.failed.len < max_stuck);
    try testing.expectEqual(fin2.result.failed.len, full.len);
}
