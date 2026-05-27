//! Layered (Sugiyama-style) auto-layout for one diagram view.
//!
//! Pipeline: filter edges to the view → break cycles (DFS back-edge reversal)
//! → longest-path layering (columns left→right by signal flow) → median
//! crossing-reduction within each layer → coordinate assignment → orthogonal
//! routing through per-channel lanes. Long edges get *dummy* vertices at each
//! intermediate rank so their horizontal runs sit in a free row and never
//! cross a node body. Everything is allocated in the caller-supplied arena.
//!
//! The power view is the exception: it uses `powerLayout`, a supply-tree layout
//! that keeps producers (battery, regulators) in left columns and groups pure
//! consumers into stacked, voltage-tinted bands on the right.

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

/// A voltage band in the power view: a tinted background strip grouping all
/// consumers of one rail level. `v` is the rail voltage (NaN ⇒ "Other").
/// `label_x` overrides the heading x (-1 ⇒ default inset) so the overlapping
/// 1.8 V / 3.3 V headings can sit on opposite sides.
pub const Band = struct { v: f64, x: f64, y: f64, w: f64, h: f64, label_x: f64 = -1 };

/// A laid-out view: placed real nodes, routed edges, the SVG canvas size, and
/// (power view only) the voltage bands consumers are grouped into.
pub const Layout = struct {
    nodes: []LNode,
    routes: []Route,
    width: f64,
    height: f64,
    bands: []const Band = &.{},
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
/// The power view uses a dedicated voltage-band layout (`powerLayout`); the
/// other views use the layered/Sugiyama pipeline below.
pub fn computeLayout(arena: Allocator, graph: *const Graph, view: View) Allocator.Error!?Layout {
    if (view == .power) return powerLayout(arena, graph);

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
    // Vertical lane per channel, keyed by source vertex: every edge leaving the
    // same node shares one trunk x, so a fanout reads as a clean comb. `lane_of`
    // is indexed by (channel rank × vertex-count + source vertex); `distinct`
    // counts the distinct sources per channel.
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

// ── power view: voltage-band supply tree ────────────────────────────────
//
// Producers (battery, regulators, filter) flow left→right in two columns — the
// source feeds the regulators — and pure consumers are grouped into voltage
// bands on the right. The 1.8 V and 3.3 V bands are drawn as an overlapping
// pair: a part using *both* rails sits in their shared zone.

const volt_eps: f64 = 0.05; // group voltages within 50 mV as one band
const power_channel: f64 = 120; // gap between the producer columns and the bands
const power_supply_margin: f64 = 52; // left margin for return (back-edge) supply links
const band_pad: f64 = 14;
const band_heading_h: f64 = 24;
const band_gap: f64 = 22;
const cell_gx: f64 = 24; // horizontal gap between boxes inside a band
const cell_gy: f64 = v_gap; // vertical gap between band rows
const zone_gap: f64 = 34; // gap between zones inside the overlap super-band
const overlap_lo: f64 = 1.8; // the lower rail of the overlapping band pair
const overlap_hi: f64 = 3.3; // the higher rail of the overlapping band pair
const band_label_w: f64 = 44; // approx heading width, to right-align the 3.3 V label

const zone_lo: u8 = 0; // 1.8 V-only
const zone_ov: u8 = 1; // uses both 1.8 V and 3.3 V (the overlap)
const zone_hi: u8 = 2; // 3.3 V-only
const zone_norm: u8 = 3; // a single-voltage band (2.5 V, 5.0 V, …) or unspecified

const InfraEdge = struct { from: u32, to: u32 };
const RowDims = struct { cols: usize, w: f64, h: f64 };

fn railsHas(rails: []const f64, v: f64) bool {
    for (rails) |r| if (@abs(r - v) < volt_eps) return true;
    return false;
}

/// Grid footprint (columns + inner width/height) for `count` boxes.
fn gridDims(count: usize) RowDims {
    if (count == 0) return .{ .cols = 0, .w = 0, .h = 0 };
    const cols = powerColsFor(count);
    const rows = (count + cols - 1) / cols;
    const fc: f64 = @floatFromInt(cols);
    const fr: f64 = @floatFromInt(rows);
    return .{ .cols = cols, .w = fc * node_w + (fc - 1) * cell_gx, .h = fr * node_h + (fr - 1) * cell_gy };
}

fn cmpAscF64(_: void, a: f64, b: f64) bool {
    return a < b;
}

fn powerLayout(arena: Allocator, graph: *const Graph) Allocator.Error!?Layout {
    const n = graph.nodes.len;
    const is_producer = try arena.alloc(bool, n);
    const participates = try arena.alloc(bool, n);
    @memset(is_producer, false);
    @memset(participates, false);
    var any = false;
    for (graph.edges) |e| {
        if (e.class != .power) continue;
        any = true;
        is_producer[e.from] = true;
        participates[e.from] = true;
        participates[e.to] = true;
    }
    if (!any) return null;

    const px = try arena.alloc(f64, n);
    const py = try arena.alloc(f64, n);
    const has_pos = try arena.alloc(bool, n);
    @memset(has_pos, false);

    // Producers: two columns (source → regulators), stacked within each.
    const pc = try producerColumns(arena, graph, is_producer);
    const ret_margin: f64 = if (pc.has_back) power_supply_margin else 0;
    const col_base = pad + ret_margin;
    var max_pcol: u8 = 0;
    for (0..n) |i| if (is_producer[i]) {
        max_pcol = @max(max_pcol, pc.col[i]);
    };
    const col_count = try arena.alloc(usize, @as(usize, max_pcol) + 1);
    @memset(col_count, 0);
    var infra_bottom: f64 = pad;
    for (0..n) |i| {
        if (!is_producer[i]) continue;
        const c = pc.col[i];
        px[i] = col_base + @as(f64, @floatFromInt(c)) * (node_w + h_gap);
        py[i] = pad + @as(f64, @floatFromInt(col_count[c])) * (node_h + v_gap);
        col_count[c] += 1;
        has_pos[i] = true;
        infra_bottom = @max(infra_bottom, py[i] + node_h);
    }
    const bands_x = col_base + @as(f64, @floatFromInt(max_pcol)) * (node_w + h_gap) + node_w + power_channel;

    // Classify each consumer into a band zone.
    const zone = try arena.alloc(u8, n);
    const norm_v = try arena.alloc(f64, n);
    @memset(zone, zone_norm);
    for (norm_v) |*x| x.* = std.math.nan(f64);
    for (0..n) |i| {
        if (!participates[i] or is_producer[i]) continue;
        zone[i] = consumerZone(graph, @intCast(i), &norm_v[i]);
    }

    // Distinct normal-band voltages (ascending) + the overlap super-band.
    var nvs: std.ArrayListUnmanaged(f64) = .empty;
    var has_unspec = false;
    for (0..n) |i| {
        if (zone[i] != zone_norm or !participates[i] or is_producer[i]) continue;
        if (std.math.isNan(norm_v[i])) {
            has_unspec = true;
            continue;
        }
        if (!railsHas(nvs.items, norm_v[i])) try nvs.append(arena, norm_v[i]);
    }
    std.mem.sort(f64, nvs.items, {}, cmpAscF64);
    var c_lo: usize = 0;
    var c_ov: usize = 0;
    var c_hi: usize = 0;
    for (0..n) |i| switch (zone[i]) {
        zone_lo => c_lo += 1,
        zone_ov => c_ov += 1,
        zone_hi => c_hi += 1,
        else => {},
    };
    const super_exists = c_lo + c_ov + c_hi > 0;

    var bands: std.ArrayListUnmanaged(Band) = .empty;
    var ycur = pad;
    var content_right = bands_x;

    // Band units stacked by voltage; the super-band sits at its 3.3 V slot.
    var super_placed = false;
    for (nvs.items) |v| {
        if (super_exists and !super_placed and v > overlap_hi) {
            try placeSuper(arena, graph, zone, bands_x, &ycur, &bands, px, py, has_pos, &content_right, .{ c_lo, c_ov, c_hi });
            super_placed = true;
        }
        try placeNormalBand(arena, graph, zone, norm_v, v, bands_x, &ycur, &bands, px, py, has_pos, &content_right);
    }
    if (super_exists and !super_placed) {
        try placeSuper(arena, graph, zone, bands_x, &ycur, &bands, px, py, has_pos, &content_right, .{ c_lo, c_ov, c_hi });
    }
    if (has_unspec) try placeUnspecBand(arena, graph, zone, norm_v, bands_x, &ycur, &bands, px, py, has_pos, &content_right);

    var lnodes: std.ArrayListUnmanaged(LNode) = .empty;
    for (0..n) |i| if (has_pos[i]) try lnodes.append(arena, .{ .gid = @intCast(i), .x = px[i], .y = py[i] });
    const routes = try buildPowerRoutes(arena, graph, is_producer, pc.col, bands.items, px, py, bands_x, ret_margin);

    const bands_bottom = if (ycur > pad) ycur - band_gap else pad;
    return .{
        .nodes = try lnodes.toOwnedSlice(arena),
        .routes = routes,
        .bands = try bands.toOwnedSlice(arena),
        .width = content_right + pad,
        .height = @max(infra_bottom, bands_bottom) + pad,
    };
}

/// Which band zone a consumer belongs to. Uses both rails → overlap; else its
/// primary rail (most pins) decides — 1.8 V / 3.3 V join the super-band, any
/// other voltage is a normal band (its voltage written to `out_norm`).
fn consumerZone(graph: *const Graph, node: u32, out_norm: *f64) u8 {
    const prim = consumerVoltage(graph, node);
    const rails = graph.nodes[node].rails;
    if (railsHas(rails, overlap_lo) and railsHas(rails, overlap_hi)) return zone_ov;
    if (!std.math.isNan(prim) and @abs(prim - overlap_lo) < volt_eps) return zone_lo;
    if (!std.math.isNan(prim) and @abs(prim - overlap_hi) < volt_eps) return zone_hi;
    out_norm.* = prim;
    return zone_norm;
}

/// The band a consumer groups under: its `power_rail` (most-pinned rail), or the
/// highest declared port / incoming edge when `power_rail` is unset (unit tests).
fn consumerVoltage(graph: *const Graph, node: u32) f64 {
    if (graph.nodes[node].power_rail >= 0) return graph.nodes[node].power_rail;
    var best_v: f64 = std.math.nan(f64);
    for (graph.nodes[node].inputs) |in| {
        if (in.voltage) |v| {
            if (std.math.isNan(best_v) or v > best_v) best_v = v;
        }
    }
    for (graph.edges) |e| {
        if (e.class != .power or e.to != node) continue;
        const v = e.voltage orelse continue;
        if (std.math.isNan(best_v) or v > best_v) best_v = v;
    }
    return best_v;
}

/// Roughly-square column count for a band's grid, capped at 4 wide.
fn powerColsFor(count: usize) usize {
    var cols: usize = 1;
    while (cols * cols < count) cols += 1;
    return @max(1, @min(cols, 4));
}

fn seatInGrid(px: []f64, py: []f64, has_pos: []bool, gid: usize, gx: f64, gy: f64, cols: usize, k: usize) void {
    px[gid] = gx + @as(f64, @floatFromInt(k % cols)) * (node_w + cell_gx);
    py[gid] = gy + @as(f64, @floatFromInt(k / cols)) * (node_h + cell_gy);
    has_pos[gid] = true;
}

/// Place a single-voltage band: a grid of its consumers under one tinted rect.
fn placeNormalBand(
    arena: Allocator,
    graph: *const Graph,
    zone: []const u8,
    norm_v: []const f64,
    v: f64,
    bands_x: f64,
    ycur: *f64,
    bands: *std.ArrayListUnmanaged(Band),
    px: []f64,
    py: []f64,
    has_pos: []bool,
    content_right: *f64,
) Allocator.Error!void {
    var count: usize = 0;
    for (graph.nodes, 0..) |_, i| {
        if (zone[i] == zone_norm and !std.math.isNan(norm_v[i]) and @abs(norm_v[i] - v) < volt_eps) count += 1;
    }
    const d = gridDims(count);
    const gy = ycur.* + band_heading_h;
    var slot: usize = 0;
    for (graph.nodes, 0..) |_, i| {
        if (zone[i] != zone_norm or std.math.isNan(norm_v[i]) or @abs(norm_v[i] - v) >= volt_eps) continue;
        seatInGrid(px, py, has_pos, i, bands_x + band_pad, gy, d.cols, slot);
        slot += 1;
    }
    const bh = band_heading_h + d.h + band_pad;
    try bands.append(arena, .{ .v = v, .x = bands_x, .y = ycur.*, .w = d.w + 2 * band_pad, .h = bh });
    content_right.* = @max(content_right.*, bands_x + d.w + 2 * band_pad);
    ycur.* += bh + band_gap;
}

fn placeUnspecBand(
    arena: Allocator,
    graph: *const Graph,
    zone: []const u8,
    norm_v: []const f64,
    bands_x: f64,
    ycur: *f64,
    bands: *std.ArrayListUnmanaged(Band),
    px: []f64,
    py: []f64,
    has_pos: []bool,
    content_right: *f64,
) Allocator.Error!void {
    var count: usize = 0;
    for (graph.nodes, 0..) |_, i| {
        if (zone[i] == zone_norm and std.math.isNan(norm_v[i])) count += 1;
    }
    if (count == 0) return;
    const d = gridDims(count);
    const gy = ycur.* + band_heading_h;
    var slot: usize = 0;
    for (graph.nodes, 0..) |_, i| {
        if (zone[i] != zone_norm or !std.math.isNan(norm_v[i])) continue;
        seatInGrid(px, py, has_pos, i, bands_x + band_pad, gy, d.cols, slot);
        slot += 1;
    }
    const bh = band_heading_h + d.h + band_pad;
    try bands.append(arena, .{ .v = std.math.nan(f64), .x = bands_x, .y = ycur.*, .w = d.w + 2 * band_pad, .h = bh });
    content_right.* = @max(content_right.*, bands_x + d.w + 2 * band_pad);
    ycur.* += bh + band_gap;
}

/// Place the overlapping 1.8 V / 3.3 V super-band: three zones side by side
/// (1.8-only | overlap | 3.3-only) under two overlapping tinted rects.
fn placeSuper(
    arena: Allocator,
    graph: *const Graph,
    zone: []const u8,
    bands_x: f64,
    ycur: *f64,
    bands: *std.ArrayListUnmanaged(Band),
    px: []f64,
    py: []f64,
    has_pos: []bool,
    content_right: *f64,
    cnt: [3]usize,
) Allocator.Error!void {
    const c_lo = cnt[0];
    const c_ov = cnt[1];
    const c_hi = cnt[2];
    const dlo = gridDims(c_lo);
    const dov = gridDims(c_ov);
    const dhi = gridDims(c_hi);
    const inner_h = @max(@max(dlo.h, dov.h), dhi.h);
    const bh = band_heading_h + inner_h + band_pad;
    const gy = ycur.* + band_heading_h;
    const lo_x = bands_x + band_pad;
    const ov_x = lo_x + (if (c_lo > 0) dlo.w + zone_gap else 0);
    const hi_x = ov_x + (if (c_ov > 0) dov.w + zone_gap else 0);
    seatZone(graph, zone, zone_lo, px, py, has_pos, lo_x, gy, dlo.cols);
    seatZone(graph, zone, zone_ov, px, py, has_pos, ov_x, gy, dov.cols);
    seatZone(graph, zone, zone_hi, px, py, has_pos, hi_x, gy, dhi.cols);

    // 1.8 V rect spans 1.8-only + overlap; 3.3 V rect spans overlap + 3.3-only.
    const lo_left = lo_x - band_pad;
    const lo_right = (if (c_ov > 0) ov_x + dov.w else lo_x + dlo.w) + band_pad;
    const hi_left = (if (c_ov > 0) ov_x else hi_x) - band_pad;
    const hi_right = hi_x + dhi.w + band_pad;
    if (c_lo > 0 or c_ov > 0) {
        try bands.append(arena, .{ .v = overlap_lo, .x = lo_left, .y = ycur.*, .w = lo_right - lo_left, .h = bh, .label_x = lo_left + band_pad });
    }
    if (c_hi > 0 or c_ov > 0) {
        try bands.append(arena, .{ .v = overlap_hi, .x = hi_left, .y = ycur.*, .w = hi_right - hi_left, .h = bh, .label_x = hi_right - band_label_w });
    }
    content_right.* = @max(content_right.*, hi_right);
    ycur.* += bh + band_gap;
}

fn seatZone(graph: *const Graph, zone: []const u8, want: u8, px: []f64, py: []f64, has_pos: []bool, gx: f64, gy: f64, cols: usize) void {
    if (cols == 0) return;
    var k: usize = 0;
    for (graph.nodes, 0..) |_, i| {
        if (zone[i] != want) continue;
        seatInGrid(px, py, has_pos, i, gx, gy, cols, k);
        k += 1;
    }
}

fn dfsBack(u: u32, elist: []const InfraEdge, adj: []const std.ArrayListUnmanaged(u32), color: []u8, back: []bool) void {
    color[u] = 1;
    for (adj[u].items) |ei| {
        const v = elist[ei].to;
        if (color[v] == 1) {
            back[ei] = true;
        } else if (color[v] == 0) {
            dfsBack(v, elist, adj, color, back);
        }
    }
    color[u] = 2;
}

const ProducerCols = struct { col: []u8, has_back: bool };

/// Column per producer: 0 for sources (fed by nothing), 1 for regulators (fed
/// by a forward supply edge). Cycle-broken so a rail flowing back into the
/// source (2.5 V → mezzanine) doesn't demote the source out of column 0.
fn producerColumns(arena: Allocator, graph: *const Graph, is_producer: []const bool) Allocator.Error!ProducerCols {
    const n = is_producer.len;
    var elist: std.ArrayListUnmanaged(InfraEdge) = .empty;
    for (graph.edges) |e| {
        if (e.class != .power or e.from == e.to) continue;
        if (!is_producer[e.from] or !is_producer[e.to]) continue;
        try elist.append(arena, .{ .from = e.from, .to = e.to });
    }
    const adj = try arena.alloc(std.ArrayListUnmanaged(u32), n);
    for (adj) |*a| a.* = .empty;
    for (elist.items, 0..) |ed, i| try adj[ed.from].append(arena, @intCast(i));
    const back = try arena.alloc(bool, elist.items.len);
    @memset(back, false);
    const color = try arena.alloc(u8, n);
    @memset(color, 0);
    for (0..n) |s| if (is_producer[s] and color[s] == 0) dfsBack(@intCast(s), elist.items, adj, color, back);
    const col = try arena.alloc(u8, n);
    @memset(col, 0);
    var has_back = false;
    for (elist.items, 0..) |ed, i| {
        if (back[i]) {
            has_back = true;
        } else {
            col[ed.to] = 1;
        }
    }
    return .{ .col = col, .has_back = has_back };
}

fn mkPowerRoute(from: u32, to: u32, v: ?f64, pts: []Pt) Route {
    return .{ .from_gid = from, .to_gid = to, .class = .power, .label = "", .voltage = v, .fanout = 1, .pts = pts, .arrow_at_start = false };
}

/// The band rect whose voltage matches `v` (NaN matches the unspecified band).
fn bandForVoltage(bands: []const Band, v: ?f64) ?usize {
    const want = v orelse return null;
    for (bands, 0..) |b, i| {
        if (!std.math.isNan(b.v) and @abs(b.v - want) < volt_eps) return i;
    }
    return null;
}

const PRouteKey = struct { kind: u8, a: u32, b: u32 };

/// Edges for the banded power view: producer→producer supply links (forward in
/// the column gap, back-edges via the left return margin) and one feeder per
/// (producer, band) into the matching band's left edge.
fn buildPowerRoutes(
    arena: Allocator,
    graph: *const Graph,
    is_producer: []const bool,
    pcol: []const u8,
    bands: []const Band,
    px: []const f64,
    py: []const f64,
    bands_x: f64,
    ret_margin: f64,
) Allocator.Error![]Route {
    var routes: std.ArrayListUnmanaged(Route) = .empty;
    var drawn = std.AutoHashMapUnmanaged(PRouteKey, void){};
    for (graph.edges) |e| {
        if (e.class != .power or e.from == e.to) continue;
        const fcyv = py[e.from] + node_h / 2;
        const tcyv = py[e.to] + node_h / 2;
        var pts: std.ArrayListUnmanaged(Pt) = .empty;
        if (is_producer[e.to]) {
            const key = PRouteKey{ .kind = 0, .a = e.from, .b = e.to };
            if ((try drawn.getOrPut(arena, key)).found_existing) continue;
            if (pcol[e.from] < pcol[e.to]) {
                // forward supply link: elbow in the column gap.
                const midx = px[e.from] + node_w + h_gap / 2;
                try pts.append(arena, .{ .x = px[e.from] + node_w, .y = fcyv });
                try pts.append(arena, .{ .x = midx, .y = fcyv });
                try pts.append(arena, .{ .x = midx, .y = tcyv });
                try pts.append(arena, .{ .x = px[e.to], .y = tcyv });
            } else {
                // return link (e.g. 2.5 V back to the source): bracket in the left margin.
                const mx = pad + ret_margin / 2;
                try pts.append(arena, .{ .x = px[e.from], .y = fcyv });
                try pts.append(arena, .{ .x = mx, .y = fcyv });
                try pts.append(arena, .{ .x = mx, .y = tcyv });
                try pts.append(arena, .{ .x = px[e.to], .y = tcyv });
            }
            try routes.append(arena, mkPowerRoute(e.from, e.to, e.voltage, try pts.toOwnedSlice(arena)));
        } else {
            const v = if (e.voltage) |ev| ev else consumerVoltage(graph, e.to);
            const bi = bandForVoltage(bands, v) orelse continue;
            if ((try drawn.getOrPut(arena, .{ .kind = 1, .a = e.from, .b = @intCast(bi) })).found_existing) continue;
            const band = bands[bi];
            const bcy = band.y + band.h / 2;
            const chx = bands_x - power_channel / 2;
            try pts.append(arena, .{ .x = px[e.from] + node_w, .y = fcyv });
            try pts.append(arena, .{ .x = chx, .y = fcyv });
            try pts.append(arena, .{ .x = chx, .y = bcy });
            try pts.append(arena, .{ .x = band.x, .y = bcy });
            try routes.append(arena, mkPowerRoute(e.from, e.to, if (std.math.isNan(v)) null else v, try pts.toOwnedSlice(arena)));
        }
    }
    return routes.toOwnedSlice(arena);
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

// spec: diagram/layout - Groups power consumers into voltage bands fed from the left
test "computeLayout groups power consumers into voltage bands" {
    var nodes = [_]types.Node{ mkNode("REG18"), mkNode("REG33"), mkNode("A"), mkNode("B"), mkNode("C") };
    var edges = [_]types.Edge{
        .{ .from = 0, .to = 2, .class = .power, .label = "v18", .voltage = 1.8 },
        .{ .from = 1, .to = 3, .class = .power, .label = "v33", .voltage = 3.3 },
        .{ .from = 1, .to = 4, .class = .power, .label = "v33b", .voltage = 3.3 },
    };
    const graph = Graph{ .nodes = &nodes, .edges = &edges };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lay = (try computeLayout(arena.allocator(), &graph, .power)) orelse return error.TestUnexpectedResult;
    // The 1.8 V / 3.3 V pair renders as two side-by-side bands (3.3 V to the right).
    try testing.expectEqual(@as(usize, 2), lay.bands.len);
    try testing.expectApproxEqAbs(@as(f64, 1.8), lay.bands[0].v, 0.01);
    try testing.expectApproxEqAbs(@as(f64, 3.3), lay.bands[1].v, 0.01);
    try testing.expect(lay.bands[1].x > lay.bands[0].x);
    // All five nodes (2 regulators + 3 consumers) placed.
    try testing.expectEqual(@as(usize, 5), lay.nodes.len);
}

// spec: diagram/layout - Places a dual-rail consumer in the 1.8 V / 3.3 V overlap
test "computeLayout overlaps the 1.8 and 3.3 bands for a dual-rail part" {
    var dual = mkNode("DUAL");
    dual.rails = &[_]f64{ 1.8, 3.3 };
    dual.power_rail = 3.3;
    var nodes = [_]types.Node{ mkNode("REG"), dual };
    var edges = [_]types.Edge{.{ .from = 0, .to = 1, .class = .power, .label = "v", .voltage = 3.3 }};
    const graph = Graph{ .nodes = &nodes, .edges = &edges };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lay = (try computeLayout(arena.allocator(), &graph, .power)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 2), lay.bands.len);
    var lo: ?Band = null;
    var hi: ?Band = null;
    for (lay.bands) |b| {
        if (@abs(b.v - 1.8) < 0.01) lo = b;
        if (@abs(b.v - 3.3) < 0.01) hi = b;
    }
    try testing.expect(lo != null and hi != null);
    // The two band rects overlap (share the dual-rail part's zone).
    try testing.expect(hi.?.x < lo.?.x + lo.?.w);
}

// spec: diagram/layout - Flows power producers left-to-right from source to regulators
test "computeLayout puts the power source left of the regulators it feeds" {
    var nodes = [_]types.Node{ mkNode("MEZZ"), mkNode("REG"), mkNode("LOAD") };
    var edges = [_]types.Edge{
        .{ .from = 0, .to = 1, .class = .power, .label = "VBATT", .voltage = 3.7 }, // source → regulator
        .{ .from = 1, .to = 2, .class = .power, .label = "v5", .voltage = 5.0 }, // regulator → load
    };
    const graph = Graph{ .nodes = &nodes, .edges = &edges };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lay = (try computeLayout(arena.allocator(), &graph, .power)) orelse return error.TestUnexpectedResult;
    var mx: f64 = -1;
    var rx: f64 = -1;
    for (lay.nodes) |ln| {
        if (ln.gid == 0) mx = ln.x;
        if (ln.gid == 1) rx = ln.x;
    }
    try testing.expect(mx >= 0 and rx >= 0);
    try testing.expect(mx < rx); // source column is left of the regulator column
}

// spec: diagram/layout - Groups a multi-rail consumer under its highest rail
test "computeLayout groups a multi-rail consumer under its highest rail" {
    var nodes = [_]types.Node{ mkNode("REG18"), mkNode("REG33"), mkNode("DUAL") };
    var edges = [_]types.Edge{
        .{ .from = 0, .to = 2, .class = .power, .label = "v18", .voltage = 1.8 },
        .{ .from = 1, .to = 2, .class = .power, .label = "v33", .voltage = 3.3 },
    };
    const graph = Graph{ .nodes = &nodes, .edges = &edges };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lay = (try computeLayout(arena.allocator(), &graph, .power)) orelse return error.TestUnexpectedResult;
    // DUAL runs on both 1.8 V and 3.3 V ⇒ a single band at the higher rail.
    try testing.expectEqual(@as(usize, 1), lay.bands.len);
    try testing.expectApproxEqAbs(@as(f64, 3.3), lay.bands[0].v, 0.01);
}
