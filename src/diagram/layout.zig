//! Layered (Sugiyama-style) auto-layout for one diagram view.
//!
//! Pipeline: filter edges to the view → break cycles (DFS back-edge reversal)
//! → longest-path layering (columns left→right by signal flow) → median
//! crossing-reduction within each layer → coordinate assignment → orthogonal
//! routing through per-channel lanes. Long edges get *dummy* vertices at each
//! intermediate rank so their horizontal runs sit in a free row and never
//! cross a node body. Everything is allocated in the caller-supplied arena.

const std = @import("std");
const types = @import("types.zig");

const Allocator = std.mem.Allocator;
const Graph = types.Graph;
const View = types.View;
const NetClass = types.NetClass;
const Pt = types.Pt;

// ── geometry (shared with render.zig) ──────────────────────────────────
pub const node_w: f64 = 200;
pub const node_h: f64 = 56;
pub const h_gap: f64 = 132;
pub const v_gap: f64 = 30;
pub const pad: f64 = 20;
pub const dummy_h: f64 = 14;

/// A placed real node: its global graph id and top-left corner (width/height
/// are the module `node_w`/`node_h` constants).
pub const LNode = struct { gid: u32, x: f64, y: f64 };

/// One routed edge: the orthogonal polyline `pts` plus the metadata the
/// renderer needs for its label and arrowhead.
pub const Route = struct {
    from_gid: u32,
    to_gid: u32,
    class: NetClass,
    label: []const u8,
    voltage: ?f64,
    fanout: u16,
    pts: []Pt,
    /// True when the logical arrow points at the *first* point (the edge was a
    /// reversed back-edge, so `to` sits on the lower-rank side).
    arrow_at_start: bool,
};

/// A laid-out view: placed real nodes, routed edges, and the SVG canvas size.
pub const Layout = struct {
    nodes: []LNode,
    routes: []Route,
    width: f64,
    height: f64,
};

const Vertex = struct {
    is_dummy: bool,
    gid: u32,
    rank: u32,
    h: f64,
    y: f64 = 0,
};

const RawEdge = struct { from_l: u32, to_l: u32, eidx: usize };
const Chain = struct { verts: []u32, eidx: usize, arrow_at_start: bool };

/// Compute the layout for `view`. Returns `null` when the view has no edges.
pub fn computeLayout(arena: Allocator, graph: *const Graph, view: View) Allocator.Error!?Layout {
    // 1. Filter edges to this view + collect participating nodes.
    var local_of = std.AutoHashMapUnmanaged(u32, u32){};
    var gids: std.ArrayListUnmanaged(u32) = .empty;
    var raw: std.ArrayListUnmanaged(RawEdge) = .empty;
    for (graph.edges, 0..) |e, eidx| {
        if (types.viewOf(e.class) != view) continue;
        const fl = try internNode(arena, &local_of, &gids, e.from);
        const tl = try internNode(arena, &local_of, &gids, e.to);
        if (fl == tl) continue;
        try raw.append(arena, .{ .from_l = fl, .to_l = tl, .eidx = eidx });
    }
    if (raw.items.len == 0) return null;
    const m: u32 = @intCast(gids.items.len);

    // 2. Cycle break → effective DAG; 3. longest-path ranks.
    const reversed = try breakCycles(arena, m, raw.items);
    const rank = try assignRanks(arena, m, raw.items, reversed);
    var max_rank: u32 = 0;
    for (rank) |r| max_rank = @max(max_rank, r);

    // 4. Vertices (reals + dummies) and per-edge waypoint chains, bucketed
    //    into layers.
    var verts: std.ArrayListUnmanaged(Vertex) = .empty;
    for (gids.items, 0..) |gid, i| try verts.append(arena, .{ .is_dummy = false, .gid = gid, .rank = rank[i], .h = node_h });
    var layers = try arena.alloc(std.ArrayListUnmanaged(u32), max_rank + 1);
    for (layers) |*l| l.* = .empty;
    for (0..m) |i| try layers[rank[i]].append(arena, @intCast(i));

    const chains = try buildChains(arena, raw.items, rank, &verts, layers);

    // 5. Crossing reduction + 6. coordinates.
    try orderLayers(arena, verts.items, layers, chains);
    const dims = assignCoords(verts.items, layers);

    // 7. Routing + materialise nodes.
    const routes = try routeChains(arena, graph, verts.items, rank, chains, max_rank);
    const nodes = try arena.alloc(LNode, m);
    for (0..m) |i| nodes[i] = .{ .gid = gids.items[i], .x = colX(verts.items[i].rank), .y = verts.items[i].y };

    return .{ .nodes = nodes, .routes = routes, .width = dims.w, .height = dims.h };
}

fn internNode(
    arena: Allocator,
    local_of: *std.AutoHashMapUnmanaged(u32, u32),
    gids: *std.ArrayListUnmanaged(u32),
    gid: u32,
) Allocator.Error!u32 {
    const gop = try local_of.getOrPut(arena, gid);
    if (!gop.found_existing) {
        gop.value_ptr.* = @intCast(gids.items.len);
        try gids.append(arena, gid);
    }
    return gop.value_ptr.*;
}

// ── cycle breaking ─────────────────────────────────────────────────────

fn breakCycles(arena: Allocator, m: u32, raw: []const RawEdge) Allocator.Error![]bool {
    const reversed = try arena.alloc(bool, raw.len);
    @memset(reversed, false);
    // adjacency: node → list of (rawIdx)
    var adj = try arena.alloc(std.ArrayListUnmanaged(u32), m);
    for (adj) |*a| a.* = .empty;
    for (raw, 0..) |e, i| try adj[e.from_l].append(arena, @intCast(i));
    const color = try arena.alloc(u8, m); // 0 white, 1 gray, 2 black
    @memset(color, 0);
    for (0..m) |s| {
        if (color[s] == 0) dfsBreak(@intCast(s), raw, adj, color, reversed);
    }
    return reversed;
}

fn dfsBreak(u: u32, raw: []const RawEdge, adj: []std.ArrayListUnmanaged(u32), color: []u8, reversed: []bool) void {
    color[u] = 1;
    for (adj[u].items) |ri| {
        const v = raw[ri].to_l;
        if (color[v] == 1) {
            reversed[ri] = true; // back-edge
        } else if (color[v] == 0) {
            dfsBreak(v, raw, adj, color, reversed);
        }
    }
    color[u] = 2;
}

// ── layering ───────────────────────────────────────────────────────────

fn assignRanks(arena: Allocator, m: u32, raw: []const RawEdge, reversed: []const bool) Allocator.Error![]u32 {
    // Effective edges src→dst (reversed back-edges flipped) for a DAG.
    var out = try arena.alloc(std.ArrayListUnmanaged(u32), m);
    for (out) |*o| o.* = .empty;
    const indeg = try arena.alloc(u32, m);
    @memset(indeg, 0);
    for (raw, 0..) |e, i| {
        const src = if (reversed[i]) e.to_l else e.from_l;
        const dst = if (reversed[i]) e.from_l else e.to_l;
        try out[src].append(arena, dst);
        indeg[dst] += 1;
    }
    const rank = try arena.alloc(u32, m);
    @memset(rank, 0);
    var queue: std.ArrayListUnmanaged(u32) = .empty;
    for (0..m) |i| if (indeg[i] == 0) try queue.append(arena, @intCast(i));
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const u = queue.items[head];
        for (out[u].items) |w| {
            if (rank[u] + 1 > rank[w]) rank[w] = rank[u] + 1;
            indeg[w] -= 1;
            if (indeg[w] == 0) try queue.append(arena, w);
        }
    }
    return rank;
}

// ── vertices + chains ──────────────────────────────────────────────────

fn buildChains(
    arena: Allocator,
    raw: []const RawEdge,
    rank: []const u32,
    verts: *std.ArrayListUnmanaged(Vertex),
    layers: []std.ArrayListUnmanaged(u32),
) Allocator.Error![]Chain {
    const chains = try arena.alloc(Chain, raw.len);
    for (raw, 0..) |e, i| {
        const lo: u32 = if (rank[e.from_l] <= rank[e.to_l]) e.from_l else e.to_l;
        const hi: u32 = if (rank[e.from_l] <= rank[e.to_l]) e.to_l else e.from_l;
        const rl = rank[lo];
        const rh = rank[hi];
        var verts_list: std.ArrayListUnmanaged(u32) = .empty;
        try verts_list.append(arena, lo);
        var r = rl + 1;
        while (r < rh) : (r += 1) {
            const di: u32 = @intCast(verts.items.len);
            try verts.append(arena, .{ .is_dummy = true, .gid = 0, .rank = r, .h = dummy_h });
            try layers[r].append(arena, di);
            try verts_list.append(arena, di);
        }
        try verts_list.append(arena, hi);
        chains[i] = .{
            .verts = try verts_list.toOwnedSlice(arena),
            .eidx = e.eidx,
            .arrow_at_start = (e.to_l == lo),
        };
    }
    return chains;
}

// ── crossing reduction (median heuristic) ──────────────────────────────

fn orderLayers(arena: Allocator, verts: []const Vertex, layers: []std.ArrayListUnmanaged(u32), chains: []const Chain) Allocator.Error!void {
    var adj = try arena.alloc(std.ArrayListUnmanaged(u32), verts.len);
    for (adj) |*a| a.* = .empty;
    for (chains) |c| {
        var i: usize = 0;
        while (i + 1 < c.verts.len) : (i += 1) {
            try adj[c.verts[i]].append(arena, c.verts[i + 1]);
            try adj[c.verts[i + 1]].append(arena, c.verts[i]);
        }
    }
    const order = try arena.alloc(f64, verts.len);
    const keys = try arena.alloc(f64, verts.len);
    refreshOrder(layers, order);

    var sweep: usize = 0;
    while (sweep < 4) : (sweep += 1) {
        const down = (sweep % 2 == 0);
        var ri: usize = 0;
        while (ri < layers.len) : (ri += 1) {
            const r: usize = if (down) ri else layers.len - 1 - ri;
            const adj_rank: i64 = if (down) @as(i64, @intCast(r)) - 1 else @as(i64, @intCast(r)) + 1;
            if (adj_rank < 0 or adj_rank >= @as(i64, @intCast(layers.len))) continue;
            medianKeys(verts, layers[r].items, adj[0..], order, @intCast(adj_rank), keys);
            stableSortByKey(layers[r].items, keys);
            refreshLayerOrder(layers[r].items, order);
        }
    }
}

fn refreshOrder(layers: []std.ArrayListUnmanaged(u32), order: []f64) void {
    for (layers) |l| refreshLayerOrder(l.items, order);
}
fn refreshLayerOrder(layer: []const u32, order: []f64) void {
    for (layer, 0..) |v, i| order[v] = @floatFromInt(i);
}

fn medianKeys(verts: []const Vertex, layer: []const u32, adj: []std.ArrayListUnmanaged(u32), order: []const f64, adj_rank: u32, keys: []f64) void {
    var buf: [256]f64 = undefined;
    for (layer, 0..) |v, idx| {
        var n: usize = 0;
        for (adj[v].items) |nb| {
            if (verts[nb].rank == adj_rank and n < buf.len) {
                buf[n] = order[nb];
                n += 1;
            }
        }
        if (n == 0) {
            keys[idx] = @floatFromInt(idx); // no fixed neighbor → keep position
        } else {
            std.mem.sort(f64, buf[0..n], {}, std.sort.asc(f64));
            keys[idx] = buf[n / 2];
        }
    }
}

/// Stable insertion sort of `layer` by parallel `keys` (keys aligned by
/// position). Layers are small, so insertion sort is cheap and keeps equal
/// keys in place (important for median stability).
fn stableSortByKey(layer: []u32, keys: []f64) void {
    var i: usize = 1;
    while (i < layer.len) : (i += 1) {
        const v = layer[i];
        const k = keys[i];
        var j = i;
        while (j > 0 and keys[j - 1] > k) : (j -= 1) {
            layer[j] = layer[j - 1];
            keys[j] = keys[j - 1];
        }
        layer[j] = v;
        keys[j] = k;
    }
}

// ── coordinates ────────────────────────────────────────────────────────

fn colX(rank: u32) f64 {
    return pad + @as(f64, @floatFromInt(rank)) * (node_w + h_gap);
}

const Dims = struct { w: f64, h: f64 };

fn assignCoords(verts: []Vertex, layers: []std.ArrayListUnmanaged(u32)) Dims {
    var max_h: f64 = node_h;
    for (layers) |l| {
        var sum: f64 = 0;
        for (l.items) |v| sum += verts[v].h;
        if (l.items.len > 0) sum += @as(f64, @floatFromInt(l.items.len - 1)) * v_gap;
        max_h = @max(max_h, sum);
    }
    for (layers) |l| {
        var sum: f64 = 0;
        for (l.items) |v| sum += verts[v].h;
        if (l.items.len > 0) sum += @as(f64, @floatFromInt(l.items.len - 1)) * v_gap;
        var cursor = pad + (max_h - sum) / 2;
        for (l.items) |v| {
            verts[v].y = cursor;
            cursor += verts[v].h + v_gap;
        }
    }
    const cols: f64 = @floatFromInt(layers.len);
    const w = pad * 2 + cols * node_w + @max(0, cols - 1) * h_gap;
    return .{ .w = w, .h = pad * 2 + max_h };
}

fn cy(v: Vertex) f64 {
    return v.y + v.h / 2;
}

// ── orthogonal routing with per-channel lanes ──────────────────────────

fn routeChains(arena: Allocator, graph: *const Graph, verts: []const Vertex, rank: []const u32, chains: []const Chain, max_rank: u32) Allocator.Error![]Route {
    _ = rank;
    // Assign each channel segment a vertical lane *keyed by its source vertex*,
    // not per-segment. Every edge leaving the same node in a channel then shares
    // one trunk x, so a fanout reads as a clean comb (one stub → one trunk →
    // branches) instead of a staircase of separate bends. `lane_of` is indexed
    // by (channel rank × vertex-count + source vertex); `distinct` counts the
    // distinct sources per channel (the trunk slots to spread across the gap).
    const slots = verts.len;
    const lane_of = try arena.alloc(i32, (max_rank + 1) * slots);
    @memset(lane_of, -1);
    const distinct = try arena.alloc(u32, max_rank + 1);
    @memset(distinct, 0);
    for (chains) |c| {
        var i: usize = 0;
        while (i + 1 < c.verts.len) : (i += 1) {
            const src = c.verts[i];
            const r = verts[src].rank;
            const key = r * slots + src;
            if (lane_of[key] < 0) {
                lane_of[key] = @intCast(distinct[r]);
                distinct[r] += 1;
            }
        }
    }

    const routes = try arena.alloc(Route, chains.len);
    for (chains, 0..) |c, ci| {
        var pts: std.ArrayListUnmanaged(Pt) = .empty;
        const w0 = verts[c.verts[0]];
        try pts.append(arena, .{ .x = colX(w0.rank) + node_w, .y = cy(w0) });
        var i: usize = 0;
        while (i + 1 < c.verts.len) : (i += 1) {
            const a = verts[c.verts[i]];
            const b = verts[c.verts[i + 1]];
            const r = a.rank;
            const lane: u32 = @intCast(lane_of[r * slots + c.verts[i]]);
            const frac = (@as(f64, @floatFromInt(lane)) + 1) / (@as(f64, @floatFromInt(distinct[r])) + 1);
            const chx = colX(r) + node_w + frac * h_gap;
            try pts.append(arena, .{ .x = chx, .y = cy(a) });
            try pts.append(arena, .{ .x = chx, .y = cy(b) });
        }
        const wk = verts[c.verts[c.verts.len - 1]];
        try pts.append(arena, .{ .x = colX(wk.rank), .y = cy(wk) });

        const e = graph.edges[c.eidx];
        routes[ci] = .{
            .from_gid = e.from,
            .to_gid = e.to,
            .class = e.class,
            .label = e.label,
            .voltage = e.voltage,
            .fanout = e.fanout,
            .pts = try pts.toOwnedSlice(arena),
            .arrow_at_start = c.arrow_at_start,
        };
    }
    return routes;
}

// ── tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

fn mkNode(label: []const u8) types.Node {
    return .{ .label = label, .subtitle = "", .category = .peripheral, .slug = "", .inputs = &.{}, .outputs = &.{} };
}

// spec: diagram/layout - Returns null for a view with no edges
test "computeLayout returns null when the view has no edges" {
    var nodes = [_]types.Node{ mkNode("A"), mkNode("B") };
    const graph = Graph{ .nodes = &nodes, .edges = &.{} };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lay = try computeLayout(arena.allocator(), &graph, .rf);
    try testing.expect(lay == null);
}

// spec: diagram/layout - Ranks nodes left-to-right by signal flow, breaking cycles for layering
test "computeLayout breaks a cycle and ranks across columns" {
    var nodes = [_]types.Node{ mkNode("A"), mkNode("B"), mkNode("C") };
    var edges = [_]types.Edge{
        .{ .from = 0, .to = 1, .class = .rf, .label = "x" },
        .{ .from = 1, .to = 2, .class = .rf, .label = "y" },
        .{ .from = 2, .to = 0, .class = .rf, .label = "z" }, // back-edge → cycle
    };
    const graph = Graph{ .nodes = &nodes, .edges = &edges };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lay = (try computeLayout(arena.allocator(), &graph, .rf)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 3), lay.nodes.len);
    // Three ranks ⇒ at least three columns wide.
    try testing.expect(lay.width > node_w * 2);
}

// spec: diagram/layout - Routes edges sharing a source through one common vertical trunk
test "computeLayout gives a shared-source fanout one common bend x" {
    var nodes = [_]types.Node{ mkNode("SRC"), mkNode("A"), mkNode("B"), mkNode("C") };
    var edges = [_]types.Edge{
        .{ .from = 0, .to = 1, .class = .clock, .label = "r1" },
        .{ .from = 0, .to = 2, .class = .clock, .label = "r2" },
        .{ .from = 0, .to = 3, .class = .clock, .label = "r3" },
    };
    const graph = Graph{ .nodes = &nodes, .edges = &edges };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lay = (try computeLayout(arena.allocator(), &graph, .clocks)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 3), lay.routes.len);
    // The first vertical channel segment is pts[1]→pts[2]; its x is the bend.
    // All three edges leave the same source, so they must share one trunk x.
    const bend = lay.routes[0].pts[1].x;
    for (lay.routes) |r| {
        try testing.expect(r.pts.len >= 4);
        try testing.expectApproxEqAbs(bend, r.pts[1].x, 0.01);
    }
}
