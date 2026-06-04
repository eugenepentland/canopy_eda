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
//! no rip-up, so congested boards can leave nets unrouted (reported in
//! `RouteResult.failed`). It's aimed at module-scale boards. Coordinates are
//! millimetres, y-down (KiCad convention).

const std = @import("std");
const optimizer = @import("optimizer.zig");
const export_kicad = @import("../export_kicad.zig");

const Part = optimizer.Part;
const FlatNet = export_kicad.FlatNet;

/// Design-rule inputs for routing (millimetres). Defaults are conservative
/// proto-fab capabilities; the page lets the user override them.
pub const RouteParams = struct {
    track_width: f64 = 0.127, // 5 mil
    clearance: f64 = 0.127, // 5 mil
    via_drill: f64 = 0.3,
    via_dia: f64 = 0.6,
};

/// A pad as a routing obstacle: its world rect and the net it belongs to.
pub const PadObs = struct { x0: f64, y0: f64, x1: f64, y1: f64, net: i32 };

/// A routed copper segment. `layer` 0 = top, 1 = bottom signal. `net` is the
/// flattened-net index it carries (for the design-rule check).
pub const Track = struct { x1: f64, y1: f64, x2: f64, y2: f64, layer: u8, width: f64, net: i32 };

/// A via (drawn as the pad ring; spans the layers it connects). `net` is the
/// flattened-net index it belongs to (for the design-rule check).
pub const Via = struct { x: f64, y: f64, dia: f64, net: i32 };

/// Router output: the copper, plus how many nets routed of the total tried.
pub const RouteResult = struct {
    tracks: []const Track,
    vias: []const Via,
    routed: usize,
    total: usize,
};

/// Largest grid (nodes per layer) the router will attempt — keeps a huge board
/// from allocating an enormous grid; modules stay far under this.
const MAX_NODES: usize = 200_000;
const EMPTY: i32 = -1;
const VIA_COST_MULT: f64 = 4.0; // a layer change costs ~4 grid steps
const SQRT2: f64 = 1.4142135623730951; // diagonal step length vs. orthogonal

/// Route `placement` under `params`. All output is allocated in `arena`.
pub fn route(arena: std.mem.Allocator, placement: optimizer.Placement, params: RouteParams) std.mem.Allocator.Error!RouteResult {
    var tracks: std.ArrayListUnmanaged(Track) = .empty;
    var vias: std.ArrayListUnmanaged(Via) = .empty;

    // ref-des → part index, for resolving each net pin to a pad.
    var idx_of = std.StringHashMap(usize).init(arena);
    for (placement.parts, 0..) |p, i| try idx_of.put(p.ref_des, i);

    const g = @max(params.track_width + params.clearance, 0.05);
    const margin = 1.0;
    const ox = placement.minx - margin;
    const oy = placement.miny - margin;
    const nx: usize = @intFromFloat(@ceil((placement.maxx - placement.minx + 2 * margin) / g) + 1);
    const ny: usize = @intFromFloat(@ceil((placement.maxy - placement.miny + 2 * margin) / g) + 1);
    if (nx * ny == 0 or nx * ny > MAX_NODES) {
        return .{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 };
    }
    const grid = Grid{ .ox = ox, .oy = oy, .g = g, .nx = nx, .ny = ny };

    // Routed-copper occupancy per signal layer (one net per grid line ⇒
    // adjacent lines are track+clearance apart, satisfying trace-to-trace DRC).
    const occ = [2][]i32{ try arena.alloc(i32, nx * ny), try arena.alloc(i32, nx * ny) };
    @memset(occ[0], EMPTY);
    @memset(occ[1], EMPTY);

    // Pad obstacles: every pad's *rectangle* + its net, so a trace keeps the
    // clearance from foreign pads (the old point-radius let traces cut across
    // big pads like the IC's exposed pad).
    var obs: std.ArrayListUnmanaged(PadObs) = .empty;
    for (placement.nets, 0..) |net, net_i| {
        for (net.pins) |pin| {
            const pi = idx_of.get(pin.ref_des) orelse continue;
            const r = padWorldRect(placement.parts[pi], pin.pin) orelse continue;
            try obs.append(arena, .{ .x0 = r.x0, .y0 = r.y0, .x1 = r.x1, .y1 = r.y1, .net = @intCast(net_i) });
        }
    }

    // Route each net. Ground → plane vias; others → maze on the signal layers.
    const reach = params.track_width / 2 + params.clearance;
    var ctx = Ctx{ .arena = arena, .grid = grid, .obs = obs.items, .reach = reach, .occ = occ, .params = params };
    var routed: usize = 0;
    var total: usize = 0;
    for (placement.nets, 0..) |net, net_i| {
        const pts = try netPoints(arena, placement, &idx_of, net);
        if (pts.len < 2) continue;
        total += 1;
        if (isGroundName(shortName(net.name))) {
            for (pts) |c| try vias.append(arena, .{ .x = c[0], .y = c[1], .dia = params.via_dia, .net = @intCast(net_i) });
            routed += 1;
            continue;
        }
        if (try routeNet(&ctx, @intCast(net_i), pts, &tracks, &vias)) routed += 1;
    }

    // Escape breakouts: the optimizer reserved a corridor in front of every
    // single-pin signal pad; emit each as a real 2 mm trace stub so the signal
    // has actual copper leaving the part (not just a placement hint).
    for (placement.stubs) |st| {
        const part = placement.parts[st.part];
        const a = optimizer.worldPadCenter(part, st.ax, st.ay);
        const b = optimizer.worldPadCenter(part, st.bx, st.by);
        try tracks.append(arena, .{ .x1 = a[0], .y1 = a[1], .x2 = b[0], .y2 = b[1], .layer = 0, .width = params.track_width, .net = st.net });
    }

    return .{
        .tracks = try tracks.toOwnedSlice(arena),
        .vias = try vias.toOwnedSlice(arena),
        .routed = routed,
        .total = total,
    };
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
        idx_of: *std.StringHashMap(usize),
        params: RouteParams,
    ) std.mem.Allocator.Error!LoopRouter {
        // Bounding box over part courtyards (pads live inside), rotation-aware,
        // then the same grid pitch + 1 mm margin `route` uses.
        var minx: f64 = std.math.inf(f64);
        var miny: f64 = std.math.inf(f64);
        var maxx: f64 = -std.math.inf(f64);
        var maxy: f64 = -std.math.inf(f64);
        for (parts) |p| {
            const q = @mod(@round(p.rot), 360);
            const quarter = (q == 90 or q == 270);
            const ehw = if (quarter) p.hh else p.hw;
            const ehh = if (quarter) p.hw else p.hh;
            minx = @min(minx, p.x - ehw);
            miny = @min(miny, p.y - ehh);
            maxx = @max(maxx, p.x + ehw);
            maxy = @max(maxy, p.y + ehh);
        }
        if (!std.math.isFinite(minx)) return .{ .ctx = undefined, .ready = false };

        const g = @max(params.track_width + params.clearance, 0.05);
        const margin = 1.0;
        const ox = minx - margin;
        const oy = miny - margin;
        const nx: usize = @intFromFloat(@ceil((maxx - minx + 2 * margin) / g) + 1);
        const ny: usize = @intFromFloat(@ceil((maxy - miny + 2 * margin) / g) + 1);
        if (nx * ny == 0 or nx * ny > MAX_NODES) return .{ .ctx = undefined, .ready = false };
        const grid = Grid{ .ox = ox, .oy = oy, .g = g, .nx = nx, .ny = ny };

        const occ = [2][]i32{ try arena.alloc(i32, nx * ny), try arena.alloc(i32, nx * ny) };

        // Every pad is an obstacle tagged with its net — same indexing as `route`
        // (absolute position in `nets`), so a leg routed on net N treats N's pads
        // as passable (its own copper) and all others as obstacles to detour.
        var obs: std.ArrayListUnmanaged(PadObs) = .empty;
        for (nets, 0..) |net, net_i| {
            for (net.pins) |pin| {
                const pi = idx_of.get(pin.ref_des) orelse continue;
                const r = padWorldRect(parts[pi], pin.pin) orelse continue;
                try obs.append(arena, .{ .x0 = r.x0, .y0 = r.y0, .x1 = r.x1, .y1 = r.y1, .net = @intCast(net_i) });
            }
        }

        const reach = params.track_width / 2 + params.clearance;
        return .{
            .ctx = .{ .arena = arena, .grid = grid, .obs = try obs.toOwnedSlice(arena), .reach = reach, .occ = occ, .params = params },
            .ready = true,
        };
    }

    /// Real routed copper length (mm) from world point `cap_c` to `hub_c` on net
    /// `net_id` (their shared rail), detouring foreign pads. Null when the maze
    /// can't connect them (boxed in) or the router isn't ready.
    pub fn legLen(self: *LoopRouter, cap_c: [2]f64, hub_c: [2]f64, net_id: i32) std.mem.Allocator.Error!?f64 {
        if (!self.ready or net_id < 0) return null;
        @memset(self.ctx.occ[0], EMPTY);
        @memset(self.ctx.occ[1], EMPTY);
        var tracks: std.ArrayListUnmanaged(Track) = .empty;
        var vias: std.ArrayListUnmanaged(Via) = .empty;
        var pts = [_][2]f64{ cap_c, hub_c };
        if (!try routeNet(&self.ctx, net_id, &pts, &tracks, &vias)) return null;
        var len: f64 = 0;
        for (tracks.items) |t| len += std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
        return len;
    }
};

// ── Grid + helpers ─────────────────────────────────────────────────────────

const Grid = struct {
    ox: f64,
    oy: f64,
    g: f64,
    nx: usize,
    ny: usize,

    fn node(self: Grid, ix: usize, iy: usize) usize {
        return iy * self.nx + ix;
    }
    fn worldX(self: Grid, ix: usize) f64 {
        return self.ox + @as(f64, @floatFromInt(ix)) * self.g;
    }
    fn worldY(self: Grid, iy: usize) f64 {
        return self.oy + @as(f64, @floatFromInt(iy)) * self.g;
    }
    /// Nearest grid node to a world point, clamped to the grid.
    fn nearest(self: Grid, x: f64, y: f64) [2]usize {
        const fx = std.math.clamp(@round((x - self.ox) / self.g), 0, @as(f64, @floatFromInt(self.nx - 1)));
        const fy = std.math.clamp(@round((y - self.oy) / self.g), 0, @as(f64, @floatFromInt(self.ny - 1)));
        return .{ @intFromFloat(fx), @intFromFloat(fy) };
    }
};

const Rect = struct { x0: f64, y0: f64, x1: f64, y1: f64 };

/// World rect of `pin` on `part` (rotation-aware), or null if absent.
fn padWorldRect(part: Part, pin: []const u8) ?Rect {
    for (part.pads) |pad| {
        if (!std.mem.eql(u8, pad.number, pin)) continue;
        const c = optimizer.worldPadCenter(part, pad.x, pad.y);
        const q = @mod(@round(part.rot), 360);
        const hw = if (q == 90 or q == 270) pad.h / 2 else pad.w / 2;
        const hh = if (q == 90 or q == 270) pad.w / 2 else pad.h / 2;
        return .{ .x0 = c[0] - hw, .y0 = c[1] - hh, .x1 = c[0] + hw, .y1 = c[1] + hh };
    }
    return null;
}

/// Distance from a point to an axis-aligned rect (0 if inside).
fn distPointRect(px: f64, py: f64, r: Rect) f64 {
    const dx = @max(@max(r.x0 - px, px - r.x1), 0);
    const dy = @max(@max(r.y0 - py, py - r.y1), 0);
    return @sqrt(dx * dx + dy * dy);
}

/// World centres (mm) of every resolvable pad on `net`.
fn netPoints(arena: std.mem.Allocator, placement: optimizer.Placement, idx_of: *std.StringHashMap(usize), net: FlatNet) std.mem.Allocator.Error![][2]f64 {
    var list: std.ArrayListUnmanaged([2]f64) = .empty;
    for (net.pins) |pin| {
        const pi = idx_of.get(pin.ref_des) orelse continue;
        const c = padCenter(placement.parts[pi], pin.pin) orelse continue;
        try list.append(arena, c);
    }
    return list.toOwnedSlice(arena);
}

/// World centre of `pin` on `part`, or null if the pad isn't in the footprint.
fn padCenter(part: Part, pin: []const u8) ?[2]f64 {
    for (part.pads) |pad| {
        if (std.mem.eql(u8, pad.number, pin)) return optimizer.worldPadCenter(part, pad.x, pad.y);
    }
    return null;
}

// ── Maze routing ─────────────────────────────────────────────────────────

const Ctx = struct {
    arena: std.mem.Allocator,
    grid: Grid,
    obs: []const PadObs,
    reach: f64,
    occ: [2][]i32,
    params: RouteParams,
};

/// True if node (layer, n) can't carry net `net`: copper of another net is
/// there, or (on top) a foreign pad is within clearance. A node sitting on the
/// net's *own* pad is always allowed (that's where the trace must connect).
fn blocked(ctx: *Ctx, layer: usize, n: usize, net: i32) bool {
    const o = ctx.occ[layer][n];
    if (o != EMPTY and o != net) return true;
    if (layer != 0) return false; // pads (and their clearance) live on top
    const px = ctx.grid.worldX(n % ctx.grid.nx);
    const py = ctx.grid.worldY(n / ctx.grid.nx);
    var on_own = false;
    var foreign = false;
    for (ctx.obs) |p| {
        const d = distPointRect(px, py, .{ .x0 = p.x0, .y0 = p.y0, .x1 = p.x1, .y1 = p.y1 });
        if (p.net == net) {
            if (d <= 1e-9) on_own = true;
        } else if (d < ctx.reach) {
            foreign = true;
        }
    }
    return foreign and !on_own;
}

const QItem = struct { d: f64, key: usize }; // key = layer*nodes + node
fn qLess(_: void, a: QItem, b: QItem) std.math.Order {
    return std.math.order(a.d, b.d);
}

/// Connect every pad of one net by repeatedly maze-routing the next pad to the
/// net's routed-so-far copper. Returns true if all pads were joined.
fn routeNet(ctx: *Ctx, net: i32, pts: [][2]f64, tracks: *std.ArrayListUnmanaged(Track), vias: *std.ArrayListUnmanaged(Via)) std.mem.Allocator.Error!bool {
    // Seed the net with its first pad's access node (top layer).
    const p0 = ctx.grid.nearest(pts[0][0], pts[0][1]);
    ctx.occ[0][ctx.grid.node(p0[0], p0[1])] = net;

    var all_ok = true;
    for (pts[1..]) |pt| {
        const goal = ctx.grid.nearest(pt[0], pt[1]);
        const goal_key = ctx.grid.node(goal[0], goal[1]); // top-layer key
        if (try dijkstra(ctx, net, goal_key, tracks, vias)) {
            // path already stamped + emitted by dijkstra
        } else {
            all_ok = false;
            // Still mark the goal pad as occupied so later pads can target it.
            ctx.occ[0][goal_key] = net;
        }
    }
    // The maze routes between pad *access nodes* (nearest grid node); add a
    // short stub from each pad's true centre to its access node so the copper
    // begins and ends in the centre of the pad, not a grid point beside it.
    for (pts) |pt| try addStub(ctx, net, pt, tracks);
    return all_ok;
}

/// Append a top-layer stub from pad centre `pt` to its grid access node, if
/// they differ (the maze trace continues from that node).
fn addStub(ctx: *Ctx, net: i32, pt: [2]f64, tracks: *std.ArrayListUnmanaged(Track)) std.mem.Allocator.Error!void {
    const a = ctx.grid.nearest(pt[0], pt[1]);
    const ax = ctx.grid.worldX(a[0]);
    const ay = ctx.grid.worldY(a[1]);
    if (@abs(ax - pt[0]) < 1e-6 and @abs(ay - pt[1]) < 1e-6) return;
    try tracks.append(ctx.arena, .{ .x1 = pt[0], .y1 = pt[1], .x2 = ax, .y2 = ay, .layer = 0, .width = ctx.params.track_width, .net = net });
}

/// Dijkstra from all of net's current copper (occ==net) to `goal_key` (a top
/// node). On success, stamps the path as the net's copper and emits the
/// tracks/vias. Returns false if unreachable.
fn dijkstra(ctx: *Ctx, net: i32, goal_key: usize, tracks: *std.ArrayListUnmanaged(Track), vias: *std.ArrayListUnmanaged(Via)) std.mem.Allocator.Error!bool {
    const grid = ctx.grid;
    const nodes = grid.nx * grid.ny;
    const dist = try ctx.arena.alloc(f64, 2 * nodes);
    const prev = try ctx.arena.alloc(i64, 2 * nodes);
    @memset(dist, std.math.inf(f64));
    @memset(prev, -1);

    var pq = std.PriorityQueue(QItem, void, qLess).init(ctx.arena, {});
    // Sources: every node already owned by this net, on either signal layer.
    for (0..2) |layer| {
        for (0..nodes) |n| {
            if (ctx.occ[layer][n] == net) {
                const k = layer * nodes + n;
                dist[k] = 0;
                try pq.add(.{ .d = 0, .key = k });
            }
        }
    }

    var found_key: ?usize = null;
    while (pq.removeOrNull()) |it| {
        if (it.d > dist[it.key]) continue;
        const layer = it.key / nodes;
        const n = it.key % nodes;
        if (layer == 0 and n == goal_key) {
            found_key = it.key;
            break;
        }
        const ix = n % grid.nx;
        const iy = n / grid.nx;
        // Same-layer 4-neighbours (orthogonal, cost g).
        try relaxStep(ctx, &pq, dist, prev, net, it.key, layer, neighbor(grid, ix, iy, 1, 0), grid.g);
        try relaxStep(ctx, &pq, dist, prev, net, it.key, layer, neighbor(grid, ix, iy, -1, 0), grid.g);
        try relaxStep(ctx, &pq, dist, prev, net, it.key, layer, neighbor(grid, ix, iy, 0, 1), grid.g);
        try relaxStep(ctx, &pq, dist, prev, net, it.key, layer, neighbor(grid, ix, iy, 0, -1), grid.g);
        // Same-layer diagonals (45° bends, cost g·√2). Guarded against corner-cutting.
        try relaxDiag(ctx, &pq, dist, prev, net, it.key, layer, ix, iy, 1, 1);
        try relaxDiag(ctx, &pq, dist, prev, net, it.key, layer, ix, iy, 1, -1);
        try relaxDiag(ctx, &pq, dist, prev, net, it.key, layer, ix, iy, -1, 1);
        try relaxDiag(ctx, &pq, dist, prev, net, it.key, layer, ix, iy, -1, -1);
        // Via to the other signal layer at the same (ix,iy).
        try relaxStep(ctx, &pq, dist, prev, net, it.key, 1 - layer, n, grid.g * VIA_COST_MULT);
    }

    const goal = found_key orelse return false;
    try emitPath(ctx, prev, goal, net, tracks, vias);
    return true;
}

/// Resolve a 4-neighbour node index, or null at the grid edge.
fn neighbor(grid: Grid, ix: usize, iy: usize, dx: i64, dy: i64) ?usize {
    const x = @as(i64, @intCast(ix)) + dx;
    const y = @as(i64, @intCast(iy)) + dy;
    if (x < 0 or y < 0 or x >= grid.nx or y >= grid.ny) return null;
    return @as(usize, @intCast(y)) * grid.nx + @as(usize, @intCast(x));
}

const PQ = std.PriorityQueue(QItem, void, qLess);

fn relaxStep(
    ctx: *Ctx,
    pq: *PQ,
    dist: []f64,
    prev: []i64,
    net: i32,
    from_key: usize,
    to_layer: usize,
    to_node: ?usize,
    step: f64,
) std.mem.Allocator.Error!void {
    const tn = to_node orelse return;
    if (blocked(ctx, to_layer, tn, net)) return;
    const nodes = ctx.grid.nx * ctx.grid.ny;
    const to_key = to_layer * nodes + tn;
    const nd = dist[from_key] + step;
    if (nd < dist[to_key]) {
        dist[to_key] = nd;
        prev[to_key] = @intCast(from_key);
        try pq.add(.{ .d = nd, .key = to_key });
    }
}

/// Relax the diagonal neighbour (dx,dy) of (ix,iy) on `layer`. Refuses the move
/// if either orthogonal cell it squeezes past is blocked, so a 45° trace never
/// clips the corner of a pad it must clear (no corner-cutting).
fn relaxDiag(
    ctx: *Ctx,
    pq: *PQ,
    dist: []f64,
    prev: []i64,
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
    try relaxStep(ctx, pq, dist, prev, net, from_key, layer, neighbor(grid, ix, iy, dx, dy), grid.g * SQRT2);
}

/// Walk `prev` from the goal back to a source, stamp the path as net copper,
/// and emit merged track segments (per straight run) + vias (per layer change).
fn emitPath(
    ctx: *Ctx,
    prev: []i64,
    goal_key: usize,
    net: i32,
    tracks: *std.ArrayListUnmanaged(Track),
    vias: *std.ArrayListUnmanaged(Via),
) std.mem.Allocator.Error!void {
    const grid = ctx.grid;
    const nodes = grid.nx * grid.ny;
    var key: i64 = @intCast(goal_key);
    // Collect the path (goal → source).
    var path: std.ArrayListUnmanaged(usize) = .empty;
    while (key >= 0) : (key = prev[@intCast(key)]) {
        const k: usize = @intCast(key);
        ctx.occ[k / nodes][k % nodes] = net;
        try path.append(ctx.arena, k);
    }
    const ks = path.items;
    if (ks.len < 2) return;
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
            try vias.append(ctx.arena, .{ .x = grid.worldX(n % grid.nx), .y = grid.worldY(n / grid.nx), .dia = ctx.params.via_dia, .net = net });
            run_start = i;
        } else if (i >= 2 and !sameDir(grid, nodes, ks[i - 2], ks[i - 1], ks[i])) {
            try emitSeg(ctx, tracks, ks[run_start], ks[i - 1], net);
            run_start = i - 1;
        }
    }
    try emitSeg(ctx, tracks, ks[run_start], ks[ks.len - 1], net);
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

fn emitSeg(ctx: *Ctx, tracks: *std.ArrayListUnmanaged(Track), a_key: usize, b_key: usize, net: i32) std.mem.Allocator.Error!void {
    const grid = ctx.grid;
    const nodes = grid.nx * grid.ny;
    if (a_key == b_key) return;
    const layer: u8 = @intCast(a_key / nodes);
    const a = a_key % nodes;
    const b = b_key % nodes;
    try tracks.append(ctx.arena, .{
        .x1 = grid.worldX(a % grid.nx),
        .y1 = grid.worldY(a / grid.nx),
        .x2 = grid.worldX(b % grid.nx),
        .y2 = grid.worldY(b / grid.nx),
        .layer = layer,
        .width = ctx.params.track_width,
        .net = net,
    });
}

// ── Small helpers (mirror optimizer.zig) ───────────────────────────────────

fn isGroundName(name: []const u8) bool {
    const grounds = [_][]const u8{ "GND", "GNDA", "AGND", "PGND", "DGND", "GNDD", "VSS", "VSSA" };
    for (grounds) |gg| {
        if (std.mem.eql(u8, name, gg)) return true;
    }
    return false;
}

fn shortName(s: []const u8) []const u8 {
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
    const pins_a = [_]export_kicad.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
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
}

// spec: placement/router - LoopRouter measures a real per-leg trace length that detours foreign pads
test "LoopRouter.legLen lengthens a leg that must route around an obstacle" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const G = @import("geometry.zig");
    const pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const sig = [_]export_kicad.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };

    // Clear board: R1 → R2, 4 mm apart on net SIG (index 0). The real trace is
    // ~straight, so its length is close to the 4 mm separation.
    var clear_parts = [_]Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 4, .y = 0 },
    };
    const clear_nets = [_]FlatNet{.{ .name = "SIG", .pins = &sig }};
    var clear_idx = std.StringHashMap(usize).init(arena);
    try clear_idx.put("R1", 0);
    try clear_idx.put("R2", 1);
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
    const other = [_]export_kicad.FlatPin{.{ .ref_des = "U9", .pin = "1" }};
    const blk_nets = [_]FlatNet{ .{ .name = "SIG", .pins = &sig }, .{ .name = "OTHER", .pins = &other } };
    var blk_idx = std.StringHashMap(usize).init(arena);
    try blk_idx.put("R1", 0);
    try blk_idx.put("R2", 1);
    try blk_idx.put("U9", 2);
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
    const pins = [_]export_kicad.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
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
