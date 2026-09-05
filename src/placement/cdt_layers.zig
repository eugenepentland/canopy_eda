//! Multi-layer, via-transitioning shape router — the CDT engine lifted off one
//! layer.
//!
//! `cdt_route` triangulates ONE layer's free space and pulls a taut path across
//! it, which answers "is there a sub-grid channel here?" but not "is there a way
//! through at all?". A net the maze cannot thread often has no single-layer
//! answer: board-a's remaining opens thread a neck whose walls are fixed RF
//! parts, and the room they need is on another layer. This module is that
//! search — one navmesh per allowed signal layer over the SAME window, joined at
//! via sites, a single Dijkstra over the resulting (triangle, layer) channel
//! graph, and a per-layer funnel on the way out.
//!
//! Pure geometry over plain data, exactly like `cdt_route`. The caller hands the
//! window, the foreign copper, the two terminals, the layers the net may use,
//! and the points where a via barrel is legal — which only the router can decide
//! (`router.directViaClear` weighs the outline, keepouts, drill walls and every
//! foreign net's copper), so this module never guesses at via legality, it only
//! routes through sites it was given. Emitting copper and gating it on DRC stay
//! the caller's, so a path this module proposes can never itself introduce a
//! violation.
//!
//! Determinism matches `cdt_route`: no RNG, no clock, ties broken by node index,
//! and every per-layer mesh built by the same exact-predicate engine.

const std = @import("std");
const cdt = @import("cdt_route.zig");

/// One non-copper region a route must clear, re-exported so a caller that talks
/// to the LAYERED engine never has to reach past it into the single-layer one to
/// name the type its own `field.obstacles` carries.
pub const Keepout = cdt.Keepout;

/// A board point where a via barrel is legal. Vias here are through-only (the
/// router's `Via` carries no layer span), so one site serves every layer pair
/// and the caller's legality answer is a single 2-D question.
pub const ViaSite = struct { x: f64, y: f64 };

/// One end of the route: where it is and which signal layer its pad is on.
pub const Terminal = struct { at: [2]f64, layer: u8 };

/// A signal layer the route may use, and the multiplier on travel across it.
/// The cost mirrors the maze's own layer pricing (an inner layer and a poured
/// outer face are each dearer than a clear outer face), so the shape router
/// prefers the same layers the maze would rather than inventing a preference.
pub const Layer = struct { index: u8, cost: f64 = 1.0 };

/// One multi-layer routing request: the shared geometry, the layers the net may
/// use, its two terminals, and the via sites a layer change may go through.
pub const Input = struct {
    /// Window, foreign copper, and the width/clearance the path must keep. Its
    /// `layer` field is ignored — one navmesh is built per entry of `layers`.
    field: cdt.Field,
    layers: []const Layer,
    start: Terminal,
    goal: Terminal,
    via_sites: []const ViaSite,
    /// Trace-millimetres charged for one layer change, so a via competes with a
    /// detour on the same terms the maze prices them.
    via_cost_mm: f64,
};

/// One taut polyline on one signal layer. Consecutive legs are joined by the
/// via at the shared endpoint.
pub const Leg = struct { layer: u8, path: []const [2]f64 };

/// A multi-layer route: the per-layer legs in order, and the via sites between
/// them (`vias.len == legs.len - 1`).
pub const Route = struct { legs: []const Leg, vias: []const ViaSite };

/// Ceiling on the channel graph, so a pathological window fails fast rather than
/// allocating for a mesh no route will come out of.
const max_nodes: usize = 4_000_000;

/// Index of `layer` within `layers`, or null when the net may not use it.
fn slotOf(layers: []const Layer, layer: u8) ?usize {
    for (layers, 0..) |l, i| {
        if (l.index == layer) return i;
    }
    return null;
}

/// The per-layer navmeshes plus the node numbering laid over them.
///
/// Nodes are the triangles of every layer's mesh laid end to end, then one node
/// per via site. A via node is what makes a layer change a single graph edge
/// instead of a special case in the search: it connects to the fan of triangles
/// around the site on EVERY layer, so entering it from one layer and leaving to
/// another is an ordinary two-edge walk priced at `via_cost_mm`.
const Graph = struct {
    scenes: []cdt.LayerScene,
    layers: []const Layer,
    /// First node index of each layer's triangles.
    off: []const usize,
    /// First via node index.
    via_base: usize,
    n: usize,
    /// `fan[li][si]` — triangles of layer `li` touching via site `si`.
    fan: []const []const []const u32,
    /// Reverse of `fan`, bucketed per triangle: `via_at[li]` holds, for triangle
    /// `t`, the sites in `items[start[t]..start[t+1]]`.
    via_at: []const TriVias,

    fn layerOf(g: *const Graph, node: usize) usize {
        var li: usize = g.off.len - 1;
        while (li > 0 and node < g.off[li]) : (li -= 1) {}
        return li;
    }
};

/// Per-layer map from a triangle to the via sites whose fan includes it, built
/// by counting sort so it allocates twice and stays deterministic.
const TriVias = struct { start: []const usize, items: []const u32 };

fn buildTriVias(a: std.mem.Allocator, fan: []const []const u32, tris: usize) std.mem.Allocator.Error!TriVias {
    const start = try a.alloc(usize, tris + 1);
    @memset(start, 0);
    for (fan) |tl| {
        for (tl) |t| start[t] += 1;
    }
    var total: usize = 0;
    for (start) |*c| {
        const k = c.*;
        c.* = total;
        total += k;
    }
    const items = try a.alloc(u32, total);
    const cursor = try a.alloc(usize, tris);
    for (0..tris) |i| cursor[i] = start[i];
    for (fan, 0..) |tl, si| {
        for (tl) |t| {
            items[cursor[t]] = @intCast(si);
            cursor[t] += 1;
        }
    }
    return .{ .start = start, .items = items };
}

/// Build one navmesh per allowed layer over the same window, each carrying both
/// terminals and every via site as real mesh vertices, then lay the node
/// numbering and the via adjacency over them.
fn buildGraph(a: std.mem.Allocator, in: Input) std.mem.Allocator.Error!?Graph {
    const pts = try a.alloc([2]f64, 2 + in.via_sites.len);
    pts[0] = in.start.at;
    pts[1] = in.goal.at;
    for (in.via_sites, 0..) |v, i| pts[2 + i] = .{ v.x, v.y };

    const scenes = try a.alloc(cdt.LayerScene, in.layers.len);
    const off = try a.alloc(usize, in.layers.len);
    var total: usize = 0;
    for (in.layers, 0..) |l, li| {
        var f = in.field;
        f.layer = l.index;
        scenes[li] = (try cdt.buildField(a, f, pts)) orelse return null;
        off[li] = total;
        total += cdt.triCount(&scenes[li].scene);
        if (total > max_nodes) return null;
    }

    const fan = try a.alloc([]const []const u32, in.layers.len);
    const via_at = try a.alloc(TriVias, in.layers.len);
    for (0..in.layers.len) |li| {
        const per = try a.alloc([]const u32, in.via_sites.len);
        for (0..in.via_sites.len) |si| {
            per[si] = if (scenes[li].verts[2 + si]) |vi|
                try cdt.fanTris(a, &scenes[li].scene, vi)
            else
                &.{};
        }
        fan[li] = per;
        via_at[li] = try buildTriVias(a, per, cdt.triCount(&scenes[li].scene));
    }
    return .{
        .scenes = scenes,
        .layers = in.layers,
        .off = off,
        .via_base = total,
        .n = total + in.via_sites.len,
        .fan = fan,
        .via_at = via_at,
    };
}

const QItem = struct { d: f64, node: u32 };
fn qLess(_: void, a: QItem, b: QItem) std.math.Order {
    const by_d = std.math.order(a.d, b.d);
    return if (by_d == .eq) std.math.order(a.node, b.node) else by_d;
}

/// The search's mutable arrays. `entry` is the point each node was reached
/// through — the portal midpoint for a triangle, the site for a via — which is
/// what lets the step cost track the corridor's centre-line instead of hopping
/// between fat triangle centroids.
const Search = struct {
    dist: []f64,
    prev: []i64,
    entry: [][2]f64,
    pq: std.PriorityQueue(QItem, void, qLess),
};

fn relax(a: std.mem.Allocator, s: *Search, node: usize, d: f64, from: i64, at: [2]f64) std.mem.Allocator.Error!void {
    if (d >= s.dist[node]) return;
    s.dist[node] = d;
    s.prev[node] = from;
    s.entry[node] = at;
    try s.pq.push(a, .{ .d = d, .node = @intCast(node) });
}

fn dist2d(p: [2]f64, q: [2]f64) f64 {
    return std.math.hypot(q[0] - p[0], q[1] - p[1]);
}

/// Dijkstra over the layered channel graph, from every free triangle around the
/// start terminal to any free triangle around the goal terminal. Returns the
/// node path, or null when no corridor — on any layer, through any via — joins
/// them.
fn search(a: std.mem.Allocator, in: Input, g: *Graph, slots: Slots, mode: Mode) std.mem.Allocator.Error!?[]const usize {
    const s_slot = slots.start;
    const g_slot = slots.goal;
    const start_v = g.scenes[s_slot].verts[0] orelse return null;
    const goal_v = g.scenes[g_slot].verts[1] orelse return null;
    const goal_fan = try a.alloc(bool, cdt.triCount(&g.scenes[g_slot].scene));
    @memset(goal_fan, false);
    for (try cdt.fanTris(a, &g.scenes[g_slot].scene, goal_v)) |t| goal_fan[t] = true;

    var s = Search{
        .dist = try a.alloc(f64, g.n),
        .prev = try a.alloc(i64, g.n),
        .entry = try a.alloc([2]f64, g.n),
        .pq = std.PriorityQueue(QItem, void, qLess).initContext({}),
    };
    defer s.pq.deinit(a);
    @memset(s.dist, std.math.inf(f64));
    @memset(s.prev, -1);

    var seeded = false;
    for (try cdt.fanTris(a, &g.scenes[s_slot].scene, start_v)) |t| {
        if (!cdt.triFree(&g.scenes[s_slot].scene, t)) continue;
        try relax(a, &s, g.off[s_slot] + t, 0, -2, in.start.at);
        seeded = true;
    }
    if (!seeded) return null;

    while (s.pq.pop()) |it| {
        const node: usize = it.node;
        if (it.d > s.dist[node]) continue;
        if (node >= g.via_base) {
            try expandVia(a, in, g, &s, node, mode);
            continue;
        }
        const li = g.layerOf(node);
        const t: u32 = @intCast(node - g.off[li]);
        if (li == g_slot and goal_fan[t]) return try tracePath(a, s.prev, node);
        try expandTri(a, in, g, &s, .{ .li = li, .t = t }, mode);
    }
    return null;
}

/// Step out of a triangle: through each open portal into free space, and down
/// any via site the triangle's fan touches.
fn expandTri(a: std.mem.Allocator, in: Input, g: *Graph, s: *Search, tri: TriAt, mode: Mode) std.mem.Allocator.Error!void {
    const li = tri.li;
    const t = tri.t;
    const sc = &g.scenes[li].scene;
    const node = g.off[li] + t;
    const from = s.entry[node];
    const mult = g.layers[li].cost;
    for (0..3) |e| {
        const p = (if (mode == .free) cdt.portalOut(sc, t, e) else cdt.wallOut(sc, t, e)) orelse continue;
        const free = cdt.triFree(sc, p.to);
        if (mode == .free and !free) continue;
        const wall: f64 = if (free) 1 else wall_cost_mult;
        try relax(a, s, g.off[li] + p.to, s.dist[node] + dist2d(from, p.mid) * mult * wall, @intCast(node), p.mid);
    }
    const map = g.via_at[li];
    for (map.items[map.start[t]..map.start[t + 1]]) |si| {
        const site = in.via_sites[si];
        const at = [2]f64{ site.x, site.y };
        // Half the via cost on the way in and half on the way out, so one layer
        // change costs exactly `via_cost_mm` however many layers it skips.
        const d = s.dist[node] + dist2d(from, at) * mult + in.via_cost_mm / 2;
        try relax(a, s, g.via_base + si, d, @intCast(node), at);
    }
}

/// Step out of a via site onto every layer whose free space reaches it.
fn expandVia(a: std.mem.Allocator, in: Input, g: *Graph, s: *Search, node: usize, mode: Mode) std.mem.Allocator.Error!void {
    const si = node - g.via_base;
    const site = in.via_sites[si];
    const at = [2]f64{ site.x, site.y };
    for (0..g.layers.len) |lj| {
        const sc = &g.scenes[lj].scene;
        for (g.fan[lj][si]) |t| {
            if (mode == .free and !cdt.triFree(sc, t)) continue;
            try relax(a, s, g.off[lj] + t, s.dist[node] + in.via_cost_mm / 2, @intCast(node), at);
        }
    }
}

fn tracePath(a: std.mem.Allocator, prev: []const i64, goal: usize) std.mem.Allocator.Error![]const usize {
    var rev: std.ArrayList(usize) = .empty;
    var cur: i64 = @intCast(goal);
    while (cur >= 0) {
        try rev.append(a, @intCast(cur));
        if (prev[@intCast(cur)] < 0) break; // reached a seed
        cur = prev[@intCast(cur)];
    }
    const out = try a.alloc(usize, rev.items.len);
    for (rev.items, 0..) |v, i| out[out.len - 1 - i] = v;
    return out;
}

/// Cut the node path at its via nodes and funnel each same-layer run between the
/// points that bound it — the start terminal or the previous via, and the next
/// via or the goal terminal. Each run is a genuine triangle corridor (successive
/// triangle nodes are portal neighbours by construction), so the funnel returns
/// the taut geodesic through it exactly as the single-layer engine does.
fn extract(a: std.mem.Allocator, in: Input, g: *Graph, path: []const usize, s_slot: usize) std.mem.Allocator.Error!?Route {
    var legs: std.ArrayList(Leg) = .empty;
    var vias: std.ArrayList(ViaSite) = .empty;
    var run: std.ArrayList(u32) = .empty;
    var li = s_slot;
    var entry = in.start.at;
    for (path) |node| {
        if (node < g.via_base) {
            li = g.layerOf(node);
            try run.append(a, @intCast(node - g.off[li]));
            continue;
        }
        const site = in.via_sites[node - g.via_base];
        const exit = [2]f64{ site.x, site.y };
        try pushLeg(a, &legs, g, .{ .li = li, .run = run.items, .from = entry, .to = exit });
        try vias.append(a, site);
        entry = exit;
        run.clearRetainingCapacity();
    }
    try pushLeg(a, &legs, g, .{ .li = li, .run = run.items, .from = entry, .to = in.goal.at });
    if (legs.items.len == 0) return null;
    return .{ .legs = try legs.toOwnedSlice(a), .vias = try vias.toOwnedSlice(a) };
}

/// One same-layer stretch of the node path, ready to funnel: which layer, the
/// triangle corridor, and the two points that bound it.
const Stretch = struct { li: usize, run: []const u32, from: [2]f64, to: [2]f64 };

fn pushLeg(a: std.mem.Allocator, legs: *std.ArrayList(Leg), g: *Graph, st: Stretch) std.mem.Allocator.Error!void {
    if (st.run.len == 0) return;
    const path = (try cdt.tautLeg(a, &g.scenes[st.li].scene, st.run, st.from, st.to)) orelse return;
    try legs.append(a, .{ .layer = g.layers[st.li].index, .path = path });
}

/// Which free space one search may walk.
///
/// The two ask opposite questions of the same mesh. `.free` is the ROUTE: it
/// steps through open portals into free triangles only, so anything it returns
/// is a corridor copper can be laid in. `.through_walls` is the DIAGNOSIS that
/// runs when the route found nothing: it may cross a constraint edge and enter
/// an obstacle's interior, at a cost so large that the cheapest such path is the
/// one crossing the least obstacle — which is the narrowest cut through the
/// walls between the two terminals. Nothing it returns may ever become copper.
const Mode = enum { free, through_walls };

/// The multiplier on a millimetre travelled INSIDE an obstacle.
///
/// Large enough that no amount of free-space detour is ever preferred to a
/// shorter wall crossing (the search window is tens of millimetres and this
/// prices one of them above any whole-window detour), and finite so the path is
/// still a Dijkstra answer rather than a special case — the free length remains
/// the tie-break between two equally thin walls.
const wall_cost_mult: f64 = 1e6;

/// The two layer slots one search runs between.
const Slots = struct { start: usize, goal: usize };

/// One triangle in the layered graph: which layer's mesh, and which triangle of
/// it.
const TriAt = struct { li: usize, t: u32 };

/// Why no channel exists: the narrowest wall between the two terminals, and who
/// owns the copper on each side of it.
///
/// `have_mm` is the physical clearance between the two bodies — what a trace
/// squeezing between them would actually have to fit through — and `need_mm` is
/// what this request's own width and clearance demand. A wall owned by a SINGLE
/// obstacle has no channel to measure at all: `b` is null and `have_mm` is zero,
/// which reads "this one thing spans it" rather than "these two are too close".
pub const Pinch = struct {
    a: cdt.Owner,
    b: ?cdt.Owner = null,
    /// Where on the board the wall was crossed (world mm).
    at: [2]f64,
    /// The signal layer it was crossed on.
    layer: u8,
    have_mm: f64 = 0,
    need_mm: f64 = 0,
};

/// A route, or — when there is none — why not.
pub const Found = struct { route: ?Route = null, pinch: ?Pinch = null };

/// `route`, plus a diagnosis when it fails.
///
/// Kept apart from `route` itself so that no ordinary routing caller pays for
/// the second search: a failed shape route is a common, cheap answer on the
/// rescue ladder, and only a caller that intends to ACT on the reason — to rip
/// the copper that owns the wall — has a use for one. The route half is
/// byte-identical to `route`'s: same graph, same Dijkstra, same funnel.
pub fn routeDiagnosed(a: std.mem.Allocator, in: Input) std.mem.Allocator.Error!Found {
    if (in.layers.len == 0) return .{};
    const s_slot = slotOf(in.layers, in.start.layer) orelse return .{};
    const g_slot = slotOf(in.layers, in.goal.layer) orelse return .{};
    var g = (try buildGraph(a, in)) orelse return .{};
    const slots = Slots{ .start = s_slot, .goal = g_slot };
    if (try search(a, in, &g, slots, .free)) |path| {
        return .{ .route = try extract(a, in, &g, path, s_slot) };
    }
    return .{ .pinch = try pinchOf(a, in, &g, slots) };
}

/// The narrowest wall between the terminals, named.
///
/// The relaxed search answers WHERE — the cheapest path that is allowed to cross
/// obstacles crosses the least of them, which is the practical min-cut through
/// the mesh's free space. This then reads the blocked stretches off that path,
/// takes the thinnest one that anybody owns, and measures the two bodies whose
/// inflated polygons met there. A stretch owned by nobody is the window's own
/// hull seal, which is a fact about the caller's search window rather than about
/// the board, so it is skipped rather than reported as copper.
fn pinchOf(a: std.mem.Allocator, in: Input, g: *Graph, slots: Slots) std.mem.Allocator.Error!?Pinch {
    const path = (try search(a, in, g, slots, .through_walls)) orelse return null;
    const wall = (try narrowestWall(a, g, path)) orelse return null;
    var field = in.field;
    field.layer = wall.layer;
    const need = cdt.requiredGap(field);
    const pair = try closestPair(a, field, wall.owners);
    return .{
        .a = wall.owners[pair.a],
        .b = if (pair.a == pair.b) null else wall.owners[pair.b],
        .at = wall.at,
        .layer = wall.layer,
        .have_mm = pair.gap_mm,
        .need_mm = need,
    };
}

/// One stretch of the relaxed path that ran inside obstacles: where it entered,
/// on which layer, how far it travelled walled, and who owned the copper.
const WallRun = struct {
    at: [2]f64,
    layer: u8,
    mm: f64,
    owners: []const cdt.Owner,
};

/// Every walled stretch of the relaxed path, thinnest first — and of those, the
/// first that anybody owns.
fn narrowestWall(
    a: std.mem.Allocator,
    g: *Graph,
    path: []const usize,
) std.mem.Allocator.Error!?WallRun {
    var best: ?WallRun = null;
    var owners: std.ArrayList(cdt.Owner) = .empty;
    var run: ?WallRun = null;
    var last: ?[2]f64 = null;
    for (path) |node| {
        if (node >= g.via_base) {
            best = keepThinner(best, closeRun(&run, &owners, a));
            last = null;
            continue;
        }
        const li = g.layerOf(node);
        const t: u32 = @intCast(node - g.off[li]);
        const sc = &g.scenes[li].scene;
        const centre = cdt.triCenter(sc, t);
        if (cdt.triFree(sc, t)) {
            best = keepThinner(best, closeRun(&run, &owners, a));
            last = null;
            continue;
        }
        if (run == null) {
            run = .{ .at = centre, .layer = g.layers[li].index, .mm = 0, .owners = &.{} };
            owners = .empty;
        } else if (last) |prev| {
            run.?.mm += dist2d(prev, centre);
        }
        for (try cdt.triBlockers(a, sc, t)) |owner| try addOwner(a, &owners, owner);
        last = centre;
    }
    best = keepThinner(best, closeRun(&run, &owners, a));
    return best;
}

/// Finish the stretch in hand, or null when there is none (or nobody owns it).
fn closeRun(
    run: *?WallRun,
    owners: *std.ArrayList(cdt.Owner),
    a: std.mem.Allocator,
) ?WallRun {
    const open = run.* orelse return null;
    run.* = null;
    if (owners.items.len == 0) return null;
    var done = open;
    done.owners = owners.toOwnedSlice(a) catch return null;
    return done;
}

/// The thinner of two walled stretches — a wall one triangle thick is the
/// narrowest a mesh can express, so zero length wins.
fn keepThinner(best: ?WallRun, next: ?WallRun) ?WallRun {
    const candidate = next orelse return best;
    const held = best orelse return candidate;
    return if (candidate.mm < held.mm) candidate else held;
}

/// Append an owner unless the stretch already names the same obstacle.
fn addOwner(
    a: std.mem.Allocator,
    owners: *std.ArrayList(cdt.Owner),
    owner: cdt.Owner,
) std.mem.Allocator.Error!void {
    for (owners.items) |seen| {
        if (seen.kind == owner.kind and seen.src == owner.src) return;
    }
    try owners.append(a, owner);
}

/// Which two of a wall's owners sit closest together, and how far apart their
/// bodies actually are — the channel the pinch closed. A wall with one owner
/// answers with that owner twice and a zero gap, which is the honest reading:
/// one body spans it and there is no channel between two things at all.
const ClosestPair = struct { a: usize, b: usize, gap_mm: f64 };

fn closestPair(
    alloc: std.mem.Allocator,
    field: cdt.Field,
    owners: []const cdt.Owner,
) std.mem.Allocator.Error!ClosestPair {
    var best = ClosestPair{ .a = 0, .b = 0, .gap_mm = 0 };
    var found = false;
    for (owners, 0..) |x, i| {
        for (owners[i + 1 ..], i + 1..) |y, j| {
            const gap = (try cdt.ownerGap(alloc, field, x, y)) orelse continue;
            if (found and !(gap < best.gap_mm)) continue;
            best = .{ .a = i, .b = j, .gap_mm = gap };
            found = true;
        }
    }
    return best;
}

/// Route `in.start` to `in.goal` across every allowed layer, diving through the
/// caller's via sites where that is shorter than staying put. Null when no
/// corridor joins the terminals on any layer.
pub fn route(a: std.mem.Allocator, in: Input) std.mem.Allocator.Error!?Route {
    if (in.layers.len == 0) return null;
    const s_slot = slotOf(in.layers, in.start.layer) orelse return null;
    const g_slot = slotOf(in.layers, in.goal.layer) orelse return null;
    var g = (try buildGraph(a, in)) orelse return null;
    const path = (try search(a, in, &g, .{ .start = s_slot, .goal = g_slot }, .free)) orelse return null;
    const found = (try extract(a, in, &g, path, s_slot)) orelse return null;
    // A route that never left its layer is exactly what the single-layer engine
    // already answers; returning it is still correct and the caller emits it the
    // same way, so no special case is needed here.
    return found;
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;
const router = @import("router.zig");

test {
    testing.refAllDecls(@This());
}

/// A wall of pads spanning the window on `layer`, with no gap — the shape that
/// makes a single-layer route impossible and a layer change necessary.
fn wallPads(a: std.mem.Allocator, layer: u8, n: usize) std.mem.Allocator.Error![]router.PadObs {
    const pads = try a.alloc(router.PadObs, n);
    for (0..n) |i| {
        const y = @as(f64, @floatFromInt(i)) * 0.9;
        pads[i] = .{ .x0 = 4.6, .y0 = y, .x1 = 5.4, .y1 = y + 0.9, .net = @intCast(i + 1), .layer = layer };
    }
    return pads;
}

fn twoLayers() [2]Layer {
    return .{ .{ .index = 0 }, .{ .index = 1 } };
}

fn wallInput(pads: []const router.PadObs, sites: []const ViaSite, layers: []const Layer) Input {
    return .{
        .field = .{
            .rect = .{ .x0 = 0, .y0 = 0, .x1 = 10, .y1 = 10 },
            .layer = 0,
            .obstacles = .{ .pads = pads, .tracks = &.{}, .vias = &.{}, .skip_net = 0 },
            .track_width = 0.127,
            .clearance = 0.127,
        },
        .layers = layers,
        .start = .{ .at = .{ 2.0, 5.0 }, .layer = 0 },
        .goal = .{ .at = .{ 8.0, 5.0 }, .layer = 0 },
        .via_sites = sites,
        .via_cost_mm = 1.0,
    };
}

/// Total length of every leg (mm).
fn routeLen(r: Route) f64 {
    var sum: f64 = 0;
    for (r.legs) |leg| {
        for (0..leg.path.len -| 1) |i| sum += std.math.hypot(leg.path[i + 1][0] - leg.path[i][0], leg.path[i + 1][1] - leg.path[i][1]);
    }
    return sum;
}

// spec: placement/router - the multi-layer CDT router dives through a via to cross a wall that seals its own layer
test "layered CDT crosses a sealed layer through a via" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const a = arena_i.allocator();
    // Layer 0 is walled from end to end; layer 1 is clear. The only way across
    // is down at one via site and back up at the other.
    const pads = try wallPads(a, 0, 12);
    const sites = [_]ViaSite{ .{ .x = 3.5, .y = 5.0 }, .{ .x = 6.5, .y = 5.0 } };
    const layers = twoLayers();
    const found = (try route(a, wallInput(pads, &sites, &layers))) orelse return error.NoRoute;
    // Three legs: across layer 0, along layer 1 under the wall, back on layer 0.
    try testing.expectEqual(@as(usize, 3), found.legs.len);
    try testing.expectEqual(@as(usize, 2), found.vias.len);
    try testing.expectEqual(@as(u8, 0), found.legs[0].layer);
    try testing.expectEqual(@as(u8, 1), found.legs[1].layer);
    try testing.expectEqual(@as(u8, 0), found.legs[2].layer);
    // The legs join at the vias and terminate exactly on the terminals.
    try testing.expectApproxEqAbs(@as(f64, 2.0), found.legs[0].path[0][0], 1e-9);
    try testing.expectApproxEqAbs(sites[0].x, found.legs[0].path[found.legs[0].path.len - 1][0], 1e-9);
    try testing.expectApproxEqAbs(sites[1].x, found.legs[2].path[0][0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 8.0), found.legs[2].path[found.legs[2].path.len - 1][0], 1e-9);
    // Taut: the 6 mm straight run plus only what the dive costs in geometry.
    try testing.expect(routeLen(found) >= 6.0 - 1e-6 and routeLen(found) < 6.0 * 1.2);
}

// spec: placement/router - the multi-layer CDT router stays on one layer when that layer already has a channel
test "layered CDT stays on one layer when it need not dive" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const a = arena_i.allocator();
    // Nothing blocks layer 0, and a via costs 1 mm, so diving can only lose.
    const sites = [_]ViaSite{ .{ .x = 3.5, .y = 5.0 }, .{ .x = 6.5, .y = 5.0 } };
    const layers = twoLayers();
    const found = (try route(a, wallInput(&.{}, &sites, &layers))) orelse return error.NoRoute;
    try testing.expectEqual(@as(usize, 1), found.legs.len);
    try testing.expectEqual(@as(usize, 0), found.vias.len);
    try testing.expectEqual(@as(u8, 0), found.legs[0].layer);
    try testing.expect(routeLen(found) < 6.0 * 1.01); // the straight run
}

// spec: placement/router - the multi-layer CDT router reports no route when the only via site is sealed on the far layer
test "layered CDT fails when no via site reaches the far side" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const a = arena_i.allocator();
    // Both layers are walled at the same x, so the dive changes nothing: there
    // is no corridor on any layer and the engine must say so rather than
    // inventing copper through the wall.
    const p0 = try wallPads(a, 0, 12);
    const p1 = try wallPads(a, 1, 12);
    const both = try a.alloc(router.PadObs, p0.len + p1.len);
    @memcpy(both[0..p0.len], p0);
    @memcpy(both[p0.len..], p1);
    for (both[p0.len..], 0..) |*p, i| p.net = @intCast(1000 + i); // distinct nets
    const sites = [_]ViaSite{ .{ .x = 3.5, .y = 5.0 }, .{ .x = 6.5, .y = 5.0 } };
    const layers = twoLayers();
    try testing.expect((try route(a, wallInput(both, &sites, &layers))) == null);
}

// spec: placement/router - the multi-layer CDT router is deterministic across identical runs
test "layered CDT routes deterministically" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const a = arena_i.allocator();
    const pads = try wallPads(a, 0, 12);
    const sites = [_]ViaSite{ .{ .x = 3.5, .y = 5.0 }, .{ .x = 6.5, .y = 5.0 }, .{ .x = 3.5, .y = 2.0 } };
    const layers = twoLayers();
    const in = wallInput(pads, &sites, &layers);
    const r1 = (try route(a, in)) orelse return error.NoRoute;
    const r2 = (try route(a, in)) orelse return error.NoRoute;
    try testing.expectEqual(r1.legs.len, r2.legs.len);
    try testing.expectEqual(r1.vias.len, r2.vias.len);
    try testing.expectApproxEqAbs(routeLen(r1), routeLen(r2), 1e-12);
    for (r1.vias, r2.vias) |x, y| {
        try testing.expectApproxEqAbs(x.x, y.x, 1e-12);
        try testing.expectApproxEqAbs(x.y, y.y, 1e-12);
    }
}

/// Four pad walls sealing a box about `at` on `layer` — the shape a terminal's
/// own free-space pocket takes in a congested pad field.
fn penPads(a: std.mem.Allocator, layer: u8, at: [2]f64, half: f64, wall: f64) std.mem.Allocator.Error![]router.PadObs {
    const pads = try a.alloc(router.PadObs, 4);
    const lo_x = at[0] - half;
    const hi_x = at[0] + half;
    const lo_y = at[1] - half;
    const hi_y = at[1] + half;
    pads[0] = .{ .x0 = lo_x - wall, .y0 = lo_y - wall, .x1 = lo_x, .y1 = hi_y + wall, .net = 101, .layer = layer };
    pads[1] = .{ .x0 = hi_x, .y0 = lo_y - wall, .x1 = hi_x + wall, .y1 = hi_y + wall, .net = 102, .layer = layer };
    pads[2] = .{ .x0 = lo_x - wall, .y0 = lo_y - wall, .x1 = hi_x + wall, .y1 = lo_y, .net = 103, .layer = layer };
    pads[3] = .{ .x0 = lo_x - wall, .y0 = hi_y, .x1 = hi_x + wall, .y1 = hi_y + wall, .net = 104, .layer = layer };
    return pads;
}

// spec: placement/router - the multi-layer CDT router escapes a terminal sealed in its own pocket only when a via site lies inside that pocket
test "layered CDT escapes a sealed terminal pocket only through a site inside it" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const a = arena_i.allocator();
    // The exact refusal shape measured on board-a: the START terminal sits in
    // a small pocket of layer-0 free space walled off by foreign pads, layer 1
    // is clear, and the goal is out in the open. The dive is the only way out.
    const pads = try penPads(a, 0, .{ 2.0, 5.0 }, 0.6, 0.4);
    const layers = twoLayers();
    // Offered only the sites the window lattice and the on-axis run would
    // produce — all of them millimetres away, OUTSIDE the pocket — the engine
    // correctly reports no channel: there is no layer-change edge where the
    // terminal needs one.
    const far = [_]ViaSite{ .{ .x = 5.0, .y = 5.0 }, .{ .x = 6.0, .y = 5.0 } };
    try testing.expect((try route(a, wallInput(pads, &far, &layers))) == null);
    // Add ONE candidate inside the pocket — what `shapeTerminalSites` supplies —
    // and the same board routes: down inside the pen, across layer 1, back up.
    const near = [_]ViaSite{ .{ .x = 2.4, .y = 5.0 }, .{ .x = 5.0, .y = 5.0 }, .{ .x = 6.0, .y = 5.0 } };
    const found = (try route(a, wallInput(pads, &near, &layers))) orelse return error.NoRoute;
    try testing.expect(found.vias.len >= 2);
    try testing.expectApproxEqAbs(@as(f64, 2.4), found.vias[0].x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 5.0), found.vias[0].y, 1e-9);
    // The first leg is the escape inside the pen and the last lands on the goal.
    try testing.expectEqual(@as(u8, 0), found.legs[0].layer);
    try testing.expectEqual(@as(u8, 0), found.legs[found.legs.len - 1].layer);
    const end = found.legs[found.legs.len - 1].path;
    try testing.expectApproxEqAbs(@as(f64, 8.0), end[end.len - 1][0], 1e-9);
}

// spec: placement/router - the multi-layer CDT router refuses a terminal on a layer the net may not use
test "layered CDT refuses a terminal on a disallowed layer" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const a = arena_i.allocator();
    const only_inner = [_]Layer{.{ .index = 1 }};
    // Both terminals sit on layer 0, which is not in the allowed set.
    try testing.expect((try route(a, wallInput(&.{}, &.{}, &only_inner))) == null);
}

/// Two pads facing each other across a channel narrower than the request's own
/// trace needs: no route on any layer, and a wall that has a name.
fn pinchedPads(a: std.mem.Allocator) std.mem.Allocator.Error![]router.PadObs {
    const pads = try a.alloc(router.PadObs, 2);
    pads[0] = .{ .x0 = 4.6, .y0 = 0, .x1 = 5.4, .y1 = 4.9, .net = 1, .layer = 0 };
    pads[1] = .{ .x0 = 4.6, .y0 = 5.1, .x1 = 5.4, .y1 = 10, .net = 2, .layer = 0 };
    return pads;
}

// spec: placement/router - when no channel joins two terminals on any layer the multi-layer CDT search names the narrowest wall between them, the copper on each side of it, and the clearance there against the clearance the request needed
test "a sealed layered CDT search names the wall that sealed it" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const a = arena_i.allocator();
    const one = [_]Layer{.{ .index = 0 }};
    const in = wallInput(try pinchedPads(a), &.{}, &one);

    // The route is exactly what it was before the diagnosis existed: nothing.
    try testing.expect((try route(a, in)) == null);
    const found = try routeDiagnosed(a, in);
    try testing.expect(found.route == null);
    const pinch = found.pinch orelse return error.TestNoPinch;

    // The wall is real copper, named by the net it carries, and the two numbers
    // say why it is a wall: less room than the request's own trace and clearance.
    try testing.expectEqual(cdt.OwnerKind.pad, pinch.a.kind);
    try testing.expect(pinch.a.net == 1 or pinch.a.net == 2);
    try testing.expectApproxEqAbs(in.field.track_width + 2 * in.field.clearance, pinch.need_mm, 1e-9);
    try testing.expect(pinch.have_mm < pinch.need_mm);
    // It stands where the channel is, on the layer the request was sealed on.
    try testing.expectEqual(@as(u8, 0), pinch.layer);
    try testing.expect(pinch.at[0] > 4.0 and pinch.at[0] < 6.0);
    // Both sides of a two-owner wall are two different bodies, never one twice.
    try testing.expect(pinchSidesDiffer(pinch));
}

/// Are a pinch's two sides different bodies? A wall one body spans alone has no
/// second side to differ from, which is the honest answer rather than a failure.
fn pinchSidesDiffer(pinch: Pinch) bool {
    const other = pinch.b orelse return true;
    return pinch.a.src != other.src or pinch.a.kind != other.kind;
}

// spec: placement/router - a mesh search that finds its channel reports the route and no pinch, so the diagnosis is paid for only where there is something to diagnose
test "a layered CDT search that routes reports no pinch" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const a = arena_i.allocator();
    const pads = try wallPads(a, 0, 12);
    const sites = [_]ViaSite{ .{ .x = 3.5, .y = 5.0 }, .{ .x = 6.5, .y = 5.0 } };
    const layers = twoLayers();
    const found = try routeDiagnosed(a, wallInput(pads, &sites, &layers));
    const path = found.route orelse return error.TestNoRoute;
    try testing.expect(found.pinch == null);
    // …and it is the SAME route the undiagnosed entry point returns.
    const plain = (try route(a, wallInput(pads, &sites, &layers))) orelse return error.TestNoRoute;
    try testing.expectEqual(plain.legs.len, path.legs.len);
    try testing.expectEqual(plain.vias.len, path.vias.len);
}
