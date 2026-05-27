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
pub const Band = struct { v: f64, x: f64, y: f64, w: f64, h: f64 };

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

// ── power view: voltage-band layout ─────────────────────────────────────
//
// The power view is laid out as a supply *tree*, not a signal-flow graph:
// producers (any node that sources a power edge — battery, regulators, the pi
// filter) sit in layered columns on the left; pure consumers are grouped into
// stacked, tinted voltage *bands* on the right, one band per rail level.

const volt_eps: f64 = 0.05; // group voltages within 50 mV as one band
const power_channel: f64 = 120; // gap between the producer column and the bands
const power_supply_margin: f64 = 52; // left margin for producer→producer supply links
const band_pad: f64 = 14;
const band_heading_h: f64 = 24;
const band_gap: f64 = 22;
const cell_gx: f64 = 24; // horizontal gap between boxes inside a band
const cell_gy: f64 = v_gap; // vertical gap between band rows

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

    // Each consumer's band = the incoming power voltage it mostly runs on.
    const band_v = try arena.alloc(f64, n);
    for (band_v) |*x| x.* = std.math.nan(f64);
    for (0..n) |i| {
        if (participates[i] and !is_producer[i]) band_v[i] = consumerVoltage(graph, @intCast(i));
    }

    // Distinct band voltages (ascending) + a trailing "Other" band for unresolved.
    var bvs: std.ArrayListUnmanaged(f64) = .empty;
    var has_unspec = false;
    for (0..n) |i| {
        if (!participates[i] or is_producer[i]) continue;
        if (std.math.isNan(band_v[i])) {
            has_unspec = true;
            continue;
        }
        var seen = false;
        for (bvs.items) |x| if (@abs(x - band_v[i]) < volt_eps) {
            seen = true;
            break;
        };
        if (!seen) try bvs.append(arena, band_v[i]);
    }
    std.mem.sort(f64, bvs.items, {}, std.sort.asc(f64));
    const band_count = bvs.items.len + @as(usize, @intFromBool(has_unspec));

    // Tally consumers per band.
    const band_of = try arena.alloc(usize, n);
    @memset(band_of, 0);
    const counts = try arena.alloc(usize, band_count);
    @memset(counts, 0);
    var max_band: usize = 0;
    for (0..n) |i| {
        if (!participates[i] or is_producer[i]) continue;
        const bi = bandIndexOf(bvs.items, band_v[i]);
        band_of[i] = bi;
        counts[bi] += 1;
        max_band = @max(max_band, counts[bi]);
    }

    const px = try arena.alloc(f64, n);
    const py = try arena.alloc(f64, n);
    const has_pos = try arena.alloc(bool, n);
    @memset(has_pos, false);

    // Producers (battery, regulators, filter) stack in one left column. A left
    // margin holds the supply links between them, drawn as tidy brackets, so the
    // connector↔regulator feedback loop never forces a backward hook.
    var has_supply = false;
    for (graph.edges) |e| {
        if (e.class == .power and e.from != e.to and is_producer[e.from] and is_producer[e.to]) {
            has_supply = true;
            break;
        }
    }
    const supply_margin: f64 = if (has_supply) power_supply_margin else 0;
    const col_x = pad + supply_margin;
    var infra_bottom: f64 = pad;
    var stack_idx: usize = 0;
    for (0..n) |i| {
        if (!is_producer[i]) continue;
        px[i] = col_x;
        py[i] = pad + @as(f64, @floatFromInt(stack_idx)) * (node_h + v_gap);
        stack_idx += 1;
        has_pos[i] = true;
        infra_bottom = @max(infra_bottom, py[i] + node_h);
    }

    const bands_x = col_x + node_w + power_channel;

    // Band geometry: a fixed grid width, bands stacked top→bottom by voltage.
    const cols = powerColsFor(max_band);
    const fcols: f64 = @floatFromInt(cols);
    const band_w = fcols * node_w + (fcols - 1) * cell_gx + 2 * band_pad;
    const bands = try arena.alloc(Band, band_count);
    const seat = try arena.alloc(usize, band_count);
    @memset(seat, 0);
    var ycur = pad;
    for (0..band_count) |bi| {
        const rows = @max((counts[bi] + cols - 1) / cols, 1);
        const frows: f64 = @floatFromInt(rows);
        const bh = band_heading_h + frows * node_h + (frows - 1) * cell_gy + band_pad;
        const bv: f64 = if (bi < bvs.items.len) bvs.items[bi] else std.math.nan(f64);
        bands[bi] = .{ .v = bv, .x = bands_x, .y = ycur, .w = band_w, .h = bh };
        ycur += bh + band_gap;
    }
    const bands_bottom = if (band_count > 0) ycur - band_gap else pad;

    // Seat consumers into their band's grid.
    for (0..n) |i| {
        if (!participates[i] or is_producer[i]) continue;
        const bi = band_of[i];
        const k = seat[bi];
        seat[bi] += 1;
        px[i] = bands_x + band_pad + @as(f64, @floatFromInt(k % cols)) * (node_w + cell_gx);
        py[i] = bands[bi].y + band_heading_h + @as(f64, @floatFromInt(k / cols)) * (node_h + cell_gy);
        has_pos[i] = true;
    }

    var lnodes: std.ArrayListUnmanaged(LNode) = .empty;
    for (0..n) |i| if (has_pos[i]) try lnodes.append(arena, .{ .gid = @intCast(i), .x = px[i], .y = py[i] });
    const routes = try buildPowerRoutes(arena, graph, is_producer, band_of, bands, band_v, px, py, bands_x, supply_margin);

    const width = if (band_count > 0) bands_x + band_w + pad else col_x + node_w + pad;
    const height = @max(infra_bottom, bands_bottom) + pad;
    return .{ .nodes = try lnodes.toOwnedSlice(arena), .routes = routes, .bands = bands, .width = width, .height = height };
}

/// The rail voltage a consumer mostly runs on: the incoming power voltage
/// carried by the most edges (ties broken toward the lowest). NaN ⇒ none resolved.
fn consumerVoltage(graph: *const Graph, node: u32) f64 {
    var best_v: f64 = std.math.nan(f64);
    var best_count: u32 = 0;
    for (graph.edges) |e| {
        if (e.class != .power or e.to != node) continue;
        const v = e.voltage orelse continue;
        var c: u32 = 0;
        for (graph.edges) |f| {
            if (f.class == .power and f.to == node and f.voltage != null) {
                if (@abs(f.voltage.? - v) < volt_eps) c += 1;
            }
        }
        if (c > best_count or (c == best_count and (std.math.isNan(best_v) or v < best_v))) {
            best_count = c;
            best_v = v;
        }
    }
    return best_v;
}

fn bandIndexOf(bvs: []const f64, v: f64) usize {
    if (std.math.isNan(v)) return bvs.len; // the trailing "Other" band
    for (bvs, 0..) |x, i| if (@abs(x - v) < volt_eps) return i;
    return 0;
}

/// Roughly-square column count for a band's grid, capped at 4 wide.
fn powerColsFor(max_band: usize) usize {
    var cols: usize = 1;
    while (cols * cols < max_band) cols += 1;
    return @max(1, @min(cols, 4));
}

fn mkPowerRoute(from: u32, to: u32, v: ?f64, pts: []Pt) Route {
    return .{ .from_gid = from, .to_gid = to, .class = .power, .label = "", .voltage = v, .fanout = 1, .pts = pts, .arrow_at_start = false };
}

const PRouteKey = struct { kind: u8, a: u32, b: u32 };

/// Edges for the banded power view: producer→producer supply links routed as
/// brackets in the left margin, and one feeder per (producer, band) into the
/// band's left edge. Each distinct link/feeder is drawn once.
fn buildPowerRoutes(
    arena: Allocator,
    graph: *const Graph,
    is_producer: []const bool,
    band_of: []const usize,
    bands: []const Band,
    band_v: []const f64,
    px: []const f64,
    py: []const f64,
    bands_x: f64,
    supply_margin: f64,
) Allocator.Error![]Route {
    // Pre-assign each distinct supply link a left-margin lane so they don't overlap.
    var lane_of = std.AutoHashMapUnmanaged(PRouteKey, u32){};
    var lanes: u32 = 0;
    for (graph.edges) |e| {
        if (e.class != .power or e.from == e.to or !is_producer[e.to]) continue;
        const gop = try lane_of.getOrPut(arena, .{ .kind = 0, .a = e.from, .b = e.to });
        if (!gop.found_existing) {
            gop.value_ptr.* = lanes;
            lanes += 1;
        }
    }
    const ntotal: f64 = @floatFromInt(@max(lanes, 1));
    const nb: f64 = @floatFromInt(@max(bands.len, 1));

    var routes: std.ArrayListUnmanaged(Route) = .empty;
    var drawn = std.AutoHashMapUnmanaged(PRouteKey, void){};
    for (graph.edges) |e| {
        if (e.class != .power) continue;
        const fcyv = py[e.from] + node_h / 2;
        var pts: std.ArrayListUnmanaged(Pt) = .empty;
        if (is_producer[e.to]) {
            const key = PRouteKey{ .kind = 0, .a = e.from, .b = e.to };
            if (e.from == e.to or (try drawn.getOrPut(arena, key)).found_existing) continue;
            const lane: f64 = @floatFromInt(lane_of.get(key).?);
            const mx = pad + (lane + 1) / (ntotal + 1) * supply_margin;
            const tcyv = py[e.to] + node_h / 2;
            try pts.append(arena, .{ .x = px[e.from], .y = fcyv });
            try pts.append(arena, .{ .x = mx, .y = fcyv });
            try pts.append(arena, .{ .x = mx, .y = tcyv });
            try pts.append(arena, .{ .x = px[e.to], .y = tcyv });
            try routes.append(arena, mkPowerRoute(e.from, e.to, e.voltage, try pts.toOwnedSlice(arena)));
        } else {
            const bi = band_of[e.to];
            if ((try drawn.getOrPut(arena, .{ .kind = 1, .a = e.from, .b = @intCast(bi) })).found_existing) continue;
            const band = bands[bi];
            const bcy = band.y + band.h / 2;
            const chx = bands_x - power_channel + (@as(f64, @floatFromInt(bi)) + 1) / (nb + 1) * power_channel;
            try pts.append(arena, .{ .x = px[e.from] + node_w, .y = fcyv });
            try pts.append(arena, .{ .x = chx, .y = fcyv });
            try pts.append(arena, .{ .x = chx, .y = bcy });
            try pts.append(arena, .{ .x = band.x, .y = bcy });
            const v: ?f64 = if (std.math.isNan(band_v[e.to])) null else band_v[e.to];
            try routes.append(arena, mkPowerRoute(e.from, e.to, v, try pts.toOwnedSlice(arena)));
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
    // Two bands (1.8 V, 3.3 V) sorted ascending; 3.3 V band sits below 1.8 V.
    try testing.expectEqual(@as(usize, 2), lay.bands.len);
    try testing.expectApproxEqAbs(@as(f64, 1.8), lay.bands[0].v, 0.01);
    try testing.expectApproxEqAbs(@as(f64, 3.3), lay.bands[1].v, 0.01);
    try testing.expect(lay.bands[1].y > lay.bands[0].y);
    // All five nodes (2 regulators + 3 consumers) placed.
    try testing.expectEqual(@as(usize, 5), lay.nodes.len);
}
