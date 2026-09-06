//! Direct synthesis — the geometry-first attempts a net gets before the maze.
//!
//! The maze routes on a raster whose pitch is `track_width + clearance`, which
//! is the right model for a congested board and the wrong one for the many
//! connections that want a straight line, one bend, or a single via. Those are
//! synthesised here from exact geometry instead, and every candidate is judged
//! by the same clearance predicates the maze's own copper must pass — so a
//! direct route is never a looser route, only a cheaper way to find the same
//! legal one.
//!
//! The ladder, in the order `routeNetAttempt` spends it:
//!
//!   * `tryDirectPair` / `tryDirectTerminalTree` — a straight segment, then a
//!     dogleg (`findSimpleDogleg`, `findThreeBend`, the escape-candidate fan),
//!     then the continuous multi-bend search and the sub-grid fine lattice
//!     (`findFineGridPath`) for a pad the raster cannot escape.
//!   * the guided family (`tryGuidedRoute` / `tryGuidedTree` /
//!     `tryMazeGuidedTree`) — the same synthesis constrained to an authored
//!     `(waypoints …)` / `(branches …)` corridor.
//!   * the via-seeded tiers — one via (`tryDirectOneVia`), a preferred-layer
//!     transition, a three-bend via lattice ring, and finally a maze seeded
//!     from one or two synthesised via sites.
//!
//! `DirectRun` is one net attempt's mutable state (its copper lists and marks);
//! `DirectPath` is the immutable view a clearance probe needs. Split out of
//! `router.zig` verbatim (2026-09-05).

const std = @import("std");
const optimizer = @import("optimizer.zig");
const route_policy = @import("route_policy.zig");
const octilinear = @import("octilinear.zig");
const net_topology = @import("net_topology.zig");
const maze_scratch = @import("maze_scratch.zig");
const pad_shape = @import("pad_shape.zig");
const pad_grid = @import("pad_grid.zig");
const plane_via = @import("plane_via.zig");
const lane_reserve = @import("lane_reserve.zig");
const route_cleanup = @import("route_cleanup.zig");
const route_grid = @import("route_grid.zig");
const route_result = @import("route_result.zig");
const router_support = @import("router_support.zig");
const numeric = @import("../numeric.zig");
const router = @import("router.zig");
const router_ctx = @import("router_ctx.zig");
const router_maze = @import("router_maze.zig");

const segPointDist = pad_shape.segPointDist;
const selectedCount = route_grid.selectedCount;
const fine_selection_max_nets = route_grid.fine_selection_max_nets;
const RouteParams = router_support.RouteParams;
const PadObs = pad_grid.PadObs;
const Track = route_result.Track;
const Via = route_result.Via;

// The routing context and its board model (see `router_ctx.zig`).
const Ctx = router_ctx.Ctx;
const NetPt = router_ctx.NetPt;
const Grid = router_ctx.Grid;
const PadGrid = router_ctx.PadGrid;
const clearance_eps = router_ctx.clearance_eps;
const gate_rings = router_ctx.gate_rings;
const sqrt2 = router_ctx.sqrt2;
const copperIdx = router_ctx.copperIdx;
const copperReach = router_ctx.copperReach;
const gridBounds = router_ctx.gridBounds;
const layerInMask = router_ctx.layerInMask;
const outlineBlocked = router_ctx.outlineBlocked;
const padIndexReach = router_ctx.padIndexReach;
const padSegmentClears = router_ctx.padSegmentClears;
const pointMissesBox = router_ctx.pointMissesBox;
const probeBudgetExhausted = router_ctx.probeBudgetExhausted;
const segClearsPadsOnLayer = router_ctx.segClearsPadsOnLayer;
const segClearsTracks = router_ctx.segClearsTracks;
const segClearsVias = router_ctx.segClearsVias;
const stampCurrentRf = router_ctx.stampCurrentRf;
const stampStubOcc = router_ctx.stampStubOcc;
const stampViaOcc = router_ctx.stampViaOcc;
const viaClearsHoles = router_ctx.viaClearsHoles;
const viaClearsOutline = router_ctx.viaClearsOutline;
const viaClearsPads = router_ctx.viaClearsPads;
const viaClearsTracks = router_ctx.viaClearsTracks;
const viaClearsVias = router_ctx.viaClearsVias;
const viaPairCenterNeed = router_ctx.viaPairCenterNeed;
const viaR = router_ctx.viaR;

// The maze this ladder falls back to, and seeds.
const Pq = router_maze.Pq;
const clearNetOcc = router_maze.clearNetOcc;
const dijkstra = router_maze.dijkstra;
const escapeActive = router_maze.escapeActive;
const gateStub = router_maze.gateStub;

// Still owned by `router.zig`.
const ownPadBox = router.ownPadBox;
const padMazeEnds = router.padMazeEnds;
const tryMazeTerminalTree = router.tryMazeTerminalTree;
const zoneBlocksPoint = router.zoneBlocksPoint;

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
pub fn netLands(ctx: *Ctx, net: i32, pts: []const NetPt) std.mem.Allocator.Error![]const net_topology.Land {
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

pub fn axisExitDogleg(path: DirectPath, pt: NetPt, target: [2]f64) ?Dogleg {
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

pub fn tryDirectPair(run: DirectRun, from: NetPt, to: NetPt) std.mem.Allocator.Error!bool {
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
    const max_ring: i64 = numeric.checkedInt(i64, @ceil(direct_tree_via_radius_mm / direct_via_grid_mm)) orelse return false;
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

pub fn tryGuidedRoute(
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

pub fn sameTrackGeometry(a: Track, b: Track) bool {
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

pub fn tryGuidedTree(
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

pub fn trySharedGuidedTree(
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
pub fn tryMazeGuidedTree(
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
pub fn tryDirectTerminalTree(run: DirectRun, pts: []const NetPt) std.mem.Allocator.Error!bool {
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

pub const Dogleg = struct {
    count: u2 = 0,
    bends: [3][2]f64 = .{ .{ 0, 0 }, .{ 0, 0 }, .{ 0, 0 } },
};

const direct_escape_grid_mm: f64 = 0.025;

pub fn directSegmentInside(path: DirectPath, a: [2]f64, b: [2]f64) bool {
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

pub fn clearDoglegSegmentWidth(path: DirectPath, a: [2]f64, b: [2]f64, width: f64) bool {
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
            if (std.math.hypot(point[0] - existing[0], point[1] - existing[1]) < clearance_eps) return;
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

fn continuousPointKey(point: [2]f64) ?ContinuousPointKey {
    return .{
        .x = numeric.checkedInt(i32, point[0] * 1000.0) orelse return null,
        .y = numeric.checkedInt(i32, point[1] * 1000.0) orelse return null,
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
    try best.put(path.ctx.arena, continuousPointKey(a) orelse return null, 0);
    try queue.add(.{ .d = std.math.hypot(b[0] - a[0], b[1] - a[1]), .key = 0 });

    var expansions: usize = 0;
    while (queue.removeOrNull()) |item| {
        if (expansions >= max_continuous_expansions) break;
        const state = states.items[item.key];
        const known = best.get(continuousPointKey(state.point) orelse continue) orelse continue;
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
            const key = continuousPointKey(point) orelse continue;
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

pub fn finePointClear(path: DirectPath, point: [2]f64) bool {
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
    const cx: i64 = numeric.checkedInt(i64, (target[0] - grid.ox) / fine_grid_mm) orelse return &.{};
    const cy: i64 = numeric.checkedInt(i64, (target[1] - grid.oy) / fine_grid_mm) orelse return &.{};
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
        if (std.math.hypot(last[0] - reversed.items[i][0], last[1] - reversed.items[i][1]) > clearance_eps)
            try points.append(arena, reversed.items[i]);
    }
    const last = points.items[points.items.len - 1];
    if (std.math.hypot(last[0] - b[0], last[1] - b[1]) > clearance_eps)
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

pub fn emitDogleg(
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
pub fn tryDirectDogleg(run: DirectRun, from: NetPt, to: NetPt) std.mem.Allocator.Error!bool {
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
pub const direct_span_mm: f64 = 6.0;
/// Per-net exact-clearance probe ceiling for the plain-net direct path
/// (`clearDoglegSegment` / `directViaClear`). A net that cannot close direct
/// burns this and falls to the maze; with the copper index each probe is
/// O(local), so this is a wall-clock safety net, not the primary bound.
pub const direct_probe_budget: usize = 200_000;
/// A failed hard guide's immediate whole-board fine retry runs inline before
/// lower-priority nets get a turn. Keep its off-grid escape experiment small:
/// Board A's first failed guide spent the entire 270-second board allowance
/// in this one retry at the ordinary 200k ceiling. The maze still gets its
/// bounded fine-grid search; only the multiplicative exact-dogleg fallback is
/// shortened here.
pub const immediate_fine_probe_budget: usize = 8_192;
/// Under a whole-board deadline, a hard waypoint is a quick authored attempt,
/// not permission to monopolize the transaction. A valid coarse guide needs
/// a bounded allowance for every leg; Board A's seven-leg control guides
/// exhausted both the former 512-probe ceiling and a later 2,048-probe ceiling
/// before reaching their final pad. 8,192 matches the already-bounded
/// immediate fine retry and lets the cheap exact attempt finish before the
/// much more expensive guided maze takes over.
/// A route that exhausts this still falls through to the maze, and the shared
/// wall-clock deadline remains the outer bound across every net and retry.
pub const deadline_guided_probe_budget: usize = 8_192;
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
    // UNTESTED-ERROR: `dijkstra`'s only error is OutOfMemory; this catch adds
    // no handling, it just restores `allow_vias` before re-raising, and the
    // whole router runs on a caller-owned arena, so there is no seam at which a
    // test could make this allocation fail without faking the allocator.
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

pub fn tryTwoViaSeededMaze(run: DirectRun, from: NetPt, to: NetPt) std.mem.Allocator.Error!bool {
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
    ring = numeric.checkedInt(i64, @ceil(0.4 / direct_via_grid_mm)) orelse return false;
    while (ring <= max_ring) : (ring += 1) {
        if (try tryThreeBendViaLatticeRing(run, from, to, ring)) return true;
    }
    return try tryViaSeededMaze(run, from, to);
}

// ── Tests ──────────────────────────────────────────────────────────────────

const testing = std.testing;
const geometry = @import("geometry.zig");
const pad_exit = @import("pad_exit.zig");
const PadDrills = router_ctx.PadDrills;
const allocLayerGrids = router_ctx.allocLayerGrids;
const copperCompacted = router_ctx.copperCompacted;
const rebuildCopperIndex = router_ctx.rebuildCopperIndex;
const viaAllowed = router_ctx.viaAllowed;
const viaClearsPadDrills = router_ctx.viaClearsPadDrills;

/// A routing context carrying ONE through pad on net 1 — the board-a shape:
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

    // The measured board-a site: a 0.20 mm bore at (5,5) and a 0.30 mm barrel
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
