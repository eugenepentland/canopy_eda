//! Resistive current-flow solve over routed trace and through-via geometry.
//!
//! The caller identifies source and load pads; this module turns the actual
//! copper into a conductance graph, applies the annotated loads as current
//! sinks, and solves Kirchhoff's current law. Stored segments are split at
//! branches and crossings before solving, so a 1 A trunk feeding 0.8 A and
//! 0.2 A branches reports those three local currents rather than stamping the
//! whole rail envelope onto every piece. Parallel paths share current according
//! to their resistance. Computed plane/pour components enter as equipotential
//! sheet regions: they complete real copper topology without pretending that
//! this compact solve is a current-density mesh of the sheet itself.

const std = @import("std");
const numeric = @import("../numeric.zig");

const node_eps_mm: f64 = 1e-4;
const min_piece_mm: f64 = 1e-7;
const terminal_resistance_ohm: f64 = 1e-6;
const pivot_epsilon: f64 = 1e-14;

/// One routed trace before it is split at electrical junctions.
pub const Segment = struct {
    route_index: usize,
    a: [2]f64,
    b: [2]f64,
    layer: u8,
    resistance_ohm_per_mm: f64,
};

/// One through-via barrel; resistance is the full top-to-bottom value.
pub const Barrel = struct {
    route_index: usize,
    at: [2]f64,
    resistance_ohm: f64,
};

/// One connected component of a computed copper pour/plane. `contacts` are
/// sparse representative points where routed copper, vias, or pads touch the
/// component. They all join one low-resistance hub; the separate power-
/// integrity screen remains responsible for proving the sheet's neck width.
pub const Sheet = struct {
    layer: u8,
    contacts: []const [2]f64,
};

/// One physical pad contact. `layer=null` means plated through-hole/all layers.
pub const Contact = struct {
    at: [2]f64,
    layer: ?u8,
    reach_mm: f64,
};

/// One annotated load group. Multiple contacts are treated as one equipotential
/// device rail, allowing current to divide between its supply pads by route
/// resistance. `complete=false` refuses a solve rather than dropping a pin.
pub const Load = struct {
    contacts: []const Contact,
    typical_a: ?f64,
    maximum_a: ?f64,
    complete: bool = true,
};

/// Inputs for one flattened PCB net.
pub const Input = struct {
    segments: []const Segment,
    barrels: []const Barrel,
    sheets: []const Sheet = &.{},
    counts: struct { tracks: usize, vias: usize },
    source_contacts: []const Contact,
    source_complete: bool,
    loads: []const Load,
};

/// Why one current axis did or did not produce local conductor currents.
pub const Status = enum {
    solved,
    no_current,
    no_source_terminal,
    incomplete_load_terminals,
    disconnected,
    singular,

    /// Stable wire/UI spelling.
    pub fn name(self: Status) []const u8 {
        return switch (self) {
            .solved => "solved",
            .no_current => "no-current",
            .no_source_terminal => "no-source-terminal",
            .incomplete_load_terminals => "incomplete-load-terminals",
            .disconnected => "disconnected",
            .singular => "singular",
        };
    }
};

/// Local currents and endpoint voltage drops for one typical/maximum axis.
pub const Axis = struct {
    status: Status,
    track_current_a: []f64,
    track_drop_v: []f64,
    via_current_a: []f64,
    via_drop_v: []f64,
};

/// Typical and maximum current-flow outcomes over one shared copper graph.
pub const Result = struct {
    typical: Axis,
    maximum: Axis,
};

const Key = struct { x: i64, y: i64, layer: i16 };
const EdgeKind = enum { track, via, sheet, terminal };
const Edge = struct { a: usize, b: usize, resistance: f64, kind: EdgeKind, route_index: usize = 0 };

const Graph = struct {
    keys: std.ArrayList(Key) = .empty,
    pos: std.ArrayList([2]f64) = .empty,
    layer: std.ArrayList(?u8) = .empty,
    edges: std.ArrayList(Edge) = .empty,
    track_a: []usize,
    track_b: []usize,
    via_nodes: []std.ArrayList(usize),
    source_hub: ?usize = null,
    load_hubs: []?usize,

    fn nodeOf(self: *Graph, arena: std.mem.Allocator, p: [2]f64, layer: ?u8) std.mem.Allocator.Error!usize {
        const key = Key{
            .x = numeric.checkedInt(i64, @round(p[0] / node_eps_mm)) orelse 0,
            .y = numeric.checkedInt(i64, @round(p[1] / node_eps_mm)) orelse 0,
            .layer = if (layer) |value| @intCast(value) else -1,
        };
        for (self.keys.items, 0..) |old, i| {
            if (old.x == key.x and old.y == key.y and old.layer == key.layer) return i;
        }
        try self.keys.append(arena, key);
        try self.pos.append(arena, p);
        try self.layer.append(arena, layer);
        return self.keys.items.len - 1;
    }

    fn newHub(self: *Graph, arena: std.mem.Allocator, p: [2]f64) std.mem.Allocator.Error!usize {
        const index = self.keys.items.len;
        const unique_layer: i16 = -1 - @as(i16, @intCast(index));
        try self.keys.append(arena, .{
            .x = numeric.checkedInt(i64, @round(p[0] / node_eps_mm)) orelse 0,
            .y = numeric.checkedInt(i64, @round(p[1] / node_eps_mm)) orelse 0,
            .layer = unique_layer,
        });
        try self.pos.append(arena, p);
        try self.layer.append(arena, null);
        return index;
    }

    fn addEdge(self: *Graph, arena: std.mem.Allocator, edge: Edge) std.mem.Allocator.Error!void {
        if (edge.a == edge.b or invalidResistance(edge.resistance)) return;
        try self.edges.append(arena, edge);
    }
};

fn invalidResistance(value: f64) bool {
    return !(value > 0) or !std.math.isFinite(value);
}

/// Solve both declared current axes. A graph is built once and shared.
pub fn solve(arena: std.mem.Allocator, input: Input) std.mem.Allocator.Error!Result {
    var graph = try buildGraph(arena, input);
    return .{
        .typical = try solveAxis(arena, input, &graph, false),
        .maximum = try solveAxis(arena, input, &graph, true),
    };
}

fn emptyAxis(arena: std.mem.Allocator, input: Input, status: Status) std.mem.Allocator.Error!Axis {
    const track_current = try arena.alloc(f64, input.counts.tracks);
    const track_drop = try arena.alloc(f64, input.counts.tracks);
    const via_current = try arena.alloc(f64, input.counts.vias);
    const via_drop = try arena.alloc(f64, input.counts.vias);
    @memset(track_current, 0);
    @memset(track_drop, 0);
    @memset(via_current, 0);
    @memset(via_drop, 0);
    return .{ .status = status, .track_current_a = track_current, .track_drop_v = track_drop, .via_current_a = via_current, .via_drop_v = via_drop };
}

fn buildGraph(arena: std.mem.Allocator, input: Input) std.mem.Allocator.Error!Graph {
    var graph = Graph{
        .track_a = try arena.alloc(usize, input.counts.tracks),
        .track_b = try arena.alloc(usize, input.counts.tracks),
        .via_nodes = try arena.alloc(std.ArrayList(usize), input.counts.vias),
        .load_hubs = try arena.alloc(?usize, input.loads.len),
    };
    @memset(graph.track_a, 0);
    @memset(graph.track_b, 0);
    for (graph.via_nodes) |*nodes| nodes.* = .empty;
    @memset(graph.load_hubs, null);

    for (input.segments) |segment| {
        const cuts = try splitParams(arena, input.segments, input.barrels, input.sheets, segment);
        var previous = segment.a;
        graph.track_a[segment.route_index] = try graph.nodeOf(arena, segment.a, segment.layer);
        graph.track_b[segment.route_index] = try graph.nodeOf(arena, segment.b, segment.layer);
        for (cuts) |t| {
            const at = lerp(segment.a, segment.b, t);
            try addPiece(arena, &graph, segment, previous, at);
            previous = at;
        }
        try addPiece(arena, &graph, segment, previous, segment.b);
    }
    for (input.sheets) |sheet| try addSheet(arena, &graph, sheet);
    for (input.barrels) |barrel| try addBarrel(arena, &graph, barrel);
    graph.source_hub = try addTerminal(arena, &graph, input.source_contacts);
    for (input.loads, 0..) |load, i| graph.load_hubs[i] = try addTerminal(arena, &graph, load.contacts);
    return graph;
}

fn addSheet(arena: std.mem.Allocator, graph: *Graph, sheet: Sheet) std.mem.Allocator.Error!void {
    if (sheet.contacts.len == 0) return;
    const hub = try graph.newHub(arena, sheet.contacts[0]);
    for (sheet.contacts) |at| {
        const node = try graph.nodeOf(arena, at, sheet.layer);
        try graph.addEdge(arena, .{ .a = node, .b = hub, .resistance = terminal_resistance_ohm, .kind = .sheet });
    }
}

fn addPiece(arena: std.mem.Allocator, graph: *Graph, segment: Segment, a: [2]f64, b: [2]f64) std.mem.Allocator.Error!void {
    const length = dist(a, b);
    if (length < min_piece_mm) return;
    const na = try graph.nodeOf(arena, a, segment.layer);
    const nb = try graph.nodeOf(arena, b, segment.layer);
    try graph.addEdge(arena, .{ .a = na, .b = nb, .resistance = segment.resistance_ohm_per_mm * length, .kind = .track, .route_index = segment.route_index });
}

fn addBarrel(arena: std.mem.Allocator, graph: *Graph, barrel: Barrel) std.mem.Allocator.Error!void {
    var contacts: std.ArrayList(usize) = .empty;
    for (graph.pos.items, graph.layer.items, 0..) |point, layer, node| {
        if (layer == null or dist(point, barrel.at) > node_eps_mm) continue;
        try appendUnique(arena, &contacts, node);
    }
    if (contacts.items.len < 2) return;
    const hub = try graph.newHub(arena, barrel.at);
    const spoke_resistance = barrel.resistance_ohm / 2.0;
    for (contacts.items) |node| {
        try graph.addEdge(arena, .{ .a = node, .b = hub, .resistance = spoke_resistance, .kind = .via, .route_index = barrel.route_index });
        try appendUnique(arena, &graph.via_nodes[barrel.route_index], node);
    }
    try appendUnique(arena, &graph.via_nodes[barrel.route_index], hub);
}

fn addTerminal(arena: std.mem.Allocator, graph: *Graph, contacts: []const Contact) std.mem.Allocator.Error!?usize {
    const copper_nodes = graph.keys.items.len;
    var touched: std.ArrayList(usize) = .empty;
    for (contacts) |contact| {
        for (graph.pos.items[0..copper_nodes], graph.layer.items[0..copper_nodes], 0..) |point, layer, node| {
            if (layer == null) continue;
            if (contact.layer) |want| if (layer.? != want) continue;
            if (dist(point, contact.at) <= contact.reach_mm + node_eps_mm) try appendUnique(arena, &touched, node);
        }
    }
    if (touched.items.len == 0) return null;
    const hub = try graph.newHub(arena, contacts[0].at);
    for (touched.items) |node| try graph.addEdge(arena, .{ .a = hub, .b = node, .resistance = terminal_resistance_ohm, .kind = .terminal });
    return hub;
}

fn solveAxis(arena: std.mem.Allocator, input: Input, graph: *Graph, maximum: bool) std.mem.Allocator.Error!Axis {
    if (axisInputStatus(input, graph.*, maximum)) |status| return emptyAxis(arena, input, status);
    const source = graph.source_hub orelse return emptyAxis(arena, input, .no_source_terminal);
    const reachable = try reachableFrom(arena, graph.*, source);
    if (!loadsReachable(input, graph.*, maximum, reachable)) return emptyAxis(arena, input, .disconnected);
    const node_map = try makeNodeMap(arena, reachable, source);
    const map = node_map.map;
    const unknown_count = node_map.count;
    if (unknown_count == 0) return emptyAxis(arena, input, .singular);
    const stride = unknown_count + 1;
    const matrix = try arena.alloc(f64, unknown_count * stride);
    @memset(matrix, 0);
    stampConductors(matrix, stride, graph.edges.items, reachable, map);
    if (!stampLoads(matrix, stride, input, graph.*, maximum, map)) return emptyAxis(arena, input, .singular);
    if (!gaussSolve(matrix, unknown_count, stride)) return emptyAxis(arena, input, .singular);
    const voltage = try arena.alloc(f64, graph.keys.items.len);
    @memset(voltage, 0);
    for (map, 0..) |row, node| {
        if (row) |r| voltage[node] = matrix[r * stride + unknown_count];
    }
    return buildAxisOutput(arena, input, graph.*, reachable, voltage);
}

fn axisInputStatus(input: Input, graph: Graph, maximum: bool) ?Status {
    var total: f64 = 0;
    for (input.loads) |load| total += loadCurrent(load, maximum);
    if (!(total > 0)) return .no_current;
    if (!input.source_complete or graph.source_hub == null) return .no_source_terminal;
    for (input.loads, 0..) |load, i| {
        if (!(loadCurrent(load, maximum) > 0)) continue;
        if (!load.complete or graph.load_hubs[i] == null) return .incomplete_load_terminals;
    }
    return null;
}

fn loadsReachable(input: Input, graph: Graph, maximum: bool, reachable: []const bool) bool {
    for (input.loads, 0..) |load, i| {
        if (loadCurrent(load, maximum) > 0 and !reachable[graph.load_hubs[i].?]) return false;
    }
    return true;
}

const NodeMap = struct { map: []?usize, count: usize };

fn makeNodeMap(arena: std.mem.Allocator, reachable: []const bool, source: usize) std.mem.Allocator.Error!NodeMap {
    const map = try arena.alloc(?usize, reachable.len);
    @memset(map, null);
    var count: usize = 0;
    for (reachable, 0..) |yes, node| {
        if (!yes or node == source) continue;
        map[node] = count;
        count += 1;
    }
    return .{ .map = map, .count = count };
}

fn stampConductors(matrix: []f64, stride: usize, edges: []const Edge, reachable: []const bool, map: []const ?usize) void {
    for (edges) |edge| {
        if (!reachable[edge.a] or !reachable[edge.b]) continue;
        const conductance = 1.0 / edge.resistance;
        if (map[edge.a]) |a| {
            matrix[a * stride + a] += conductance;
            if (map[edge.b]) |b| matrix[a * stride + b] -= conductance;
        }
        if (map[edge.b]) |b| {
            matrix[b * stride + b] += conductance;
            if (map[edge.a]) |a| matrix[b * stride + a] -= conductance;
        }
    }
}

fn stampLoads(matrix: []f64, stride: usize, input: Input, graph: Graph, maximum: bool, map: []const ?usize) bool {
    const rhs = stride - 1;
    for (input.loads, 0..) |load, i| {
        const current = loadCurrent(load, maximum);
        if (!(current > 0)) continue;
        const row = map[graph.load_hubs[i].?] orelse return false;
        matrix[row * stride + rhs] -= current;
    }
    return true;
}

fn buildAxisOutput(
    arena: std.mem.Allocator,
    input: Input,
    graph: Graph,
    reachable: []const bool,
    voltage: []const f64,
) std.mem.Allocator.Error!Axis {
    var out = try emptyAxis(arena, input, .solved);
    for (graph.edges.items) |edge| {
        if (!reachable[edge.a] or !reachable[edge.b]) continue;
        const drop = @abs(voltage[edge.a] - voltage[edge.b]);
        const current = drop / edge.resistance;
        switch (edge.kind) {
            .track => out.track_current_a[edge.route_index] = @max(out.track_current_a[edge.route_index], current),
            .via => out.via_current_a[edge.route_index] = @max(out.via_current_a[edge.route_index], current),
            .sheet, .terminal => {},
        }
    }
    for (input.segments) |segment| {
        const a = graph.track_a[segment.route_index];
        const b = graph.track_b[segment.route_index];
        out.track_drop_v[segment.route_index] = @abs(voltage[a] - voltage[b]);
    }
    for (input.barrels) |barrel| {
        var lo = std.math.inf(f64);
        var hi = -std.math.inf(f64);
        for (graph.via_nodes[barrel.route_index].items) |node| {
            lo = @min(lo, voltage[node]);
            hi = @max(hi, voltage[node]);
        }
        if (std.math.isFinite(lo) and std.math.isFinite(hi)) out.via_drop_v[barrel.route_index] = hi - lo;
    }
    return out;
}

fn loadCurrent(load: Load, maximum: bool) f64 {
    return positiveCurrent(if (maximum) load.maximum_a else load.typical_a);
}

fn gaussSolve(matrix: []f64, n: usize, stride: usize) bool {
    var col: usize = 0;
    while (col < n) : (col += 1) {
        var pivot = col;
        var best = @abs(matrix[col * stride + col]);
        for (col + 1..n) |row| {
            const candidate = @abs(matrix[row * stride + col]);
            if (candidate > best) {
                best = candidate;
                pivot = row;
            }
        }
        if (!(best > pivot_epsilon) or !std.math.isFinite(best)) return false;
        if (pivot != col) for (0..stride) |j| std.mem.swap(f64, &matrix[col * stride + j], &matrix[pivot * stride + j]);
        const divisor = matrix[col * stride + col];
        for (col..stride) |j| matrix[col * stride + j] /= divisor;
        for (0..n) |row| {
            if (row == col) continue;
            const factor = matrix[row * stride + col];
            if (factor == 0) continue;
            for (col..stride) |j| matrix[row * stride + j] -= factor * matrix[col * stride + j];
        }
    }
    return true;
}

fn reachableFrom(arena: std.mem.Allocator, graph: Graph, source: usize) std.mem.Allocator.Error![]bool {
    const seen = try arena.alloc(bool, graph.keys.items.len);
    @memset(seen, false);
    var queue: std.ArrayList(usize) = .empty;
    seen[source] = true;
    try queue.append(arena, source);
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const node = queue.items[head];
        for (graph.edges.items) |edge| {
            const other = if (edge.a == node) edge.b else if (edge.b == node) edge.a else continue;
            if (seen[other]) continue;
            seen[other] = true;
            try queue.append(arena, other);
        }
    }
    return seen;
}

fn splitParams(
    arena: std.mem.Allocator,
    segments: []const Segment,
    barrels: []const Barrel,
    sheets: []const Sheet,
    segment: Segment,
) std.mem.Allocator.Error![]const f64 {
    var out: std.ArrayList(f64) = .empty;
    const length = dist(segment.a, segment.b);
    if (length < min_piece_mm) return out.items;
    for (segments) |other| {
        if (other.layer != segment.layer) continue;
        for ([2][2]f64{ other.a, other.b }) |point| if (projectOn(segment, point)) |t| try appendParam(arena, &out, t, length);
        if (crossParam(segment, other)) |t| try appendParam(arena, &out, t, length);
    }
    for (barrels) |barrel| if (projectOn(segment, barrel.at)) |t| try appendParam(arena, &out, t, length);
    for (sheets) |sheet| {
        if (sheet.layer != segment.layer) continue;
        for (sheet.contacts) |at| if (projectOn(segment, at)) |t| try appendParam(arena, &out, t, length);
    }
    std.mem.sort(f64, out.items, {}, comptime std.sort.asc(f64));
    return out.items;
}

fn appendParam(arena: std.mem.Allocator, out: *std.ArrayList(f64), t: f64, length: f64) std.mem.Allocator.Error!void {
    const margin = node_eps_mm / length;
    if (t <= margin or t >= 1.0 - margin) return;
    for (out.items) |old| if (@abs(old - t) <= margin) return;
    try out.append(arena, t);
}

fn projectOn(segment: Segment, point: [2]f64) ?f64 {
    const dx = segment.b[0] - segment.a[0];
    const dy = segment.b[1] - segment.a[1];
    const length2 = dx * dx + dy * dy;
    if (length2 <= min_piece_mm * min_piece_mm) return null;
    const t = ((point[0] - segment.a[0]) * dx + (point[1] - segment.a[1]) * dy) / length2;
    if (t < 0 or t > 1) return null;
    if (dist(lerp(segment.a, segment.b, t), point) > node_eps_mm) return null;
    return t;
}

fn crossParam(a: Segment, b: Segment) ?f64 {
    const r = [2]f64{ a.b[0] - a.a[0], a.b[1] - a.a[1] };
    const s = [2]f64{ b.b[0] - b.a[0], b.b[1] - b.a[1] };
    const den = r[0] * s[1] - r[1] * s[0];
    if (@abs(den) <= min_piece_mm) return null;
    const q = [2]f64{ b.a[0] - a.a[0], b.a[1] - a.a[1] };
    const t = (q[0] * s[1] - q[1] * s[0]) / den;
    const u = (q[0] * r[1] - q[1] * r[0]) / den;
    if (t < 0 or t > 1 or u < 0 or u > 1) return null;
    return t;
}

fn appendUnique(arena: std.mem.Allocator, list: *std.ArrayList(usize), value: usize) std.mem.Allocator.Error!void {
    for (list.items) |old| if (old == value) return;
    try list.append(arena, value);
}

fn positiveCurrent(value: ?f64) f64 {
    const current = value orelse return 0;
    return if (current > 0 and std.math.isFinite(current)) current else 0;
}

fn lerp(a: [2]f64, b: [2]f64, t: f64) [2]f64 {
    return .{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t };
}

fn dist(a: [2]f64, b: [2]f64) f64 {
    return std.math.hypot(a[0] - b[0], a[1] - b[1]);
}

const testing = std.testing;

test "one amp trunk splits into point eight and point two amp branches" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const segments = [_]Segment{
        .{ .route_index = 0, .a = .{ 0, 0 }, .b = .{ 1, 0 }, .layer = 0, .resistance_ohm_per_mm = 0.01 },
        .{ .route_index = 1, .a = .{ 1, 0 }, .b = .{ 2, 1 }, .layer = 0, .resistance_ohm_per_mm = 0.01 },
        .{ .route_index = 2, .a = .{ 1, 0 }, .b = .{ 2, -1 }, .layer = 0, .resistance_ohm_per_mm = 0.01 },
    };
    const loads = [_]Load{
        .{ .contacts = &.{.{ .at = .{ 2, 1 }, .layer = 0, .reach_mm = 0.01 }}, .typical_a = 0.8, .maximum_a = null },
        .{ .contacts = &.{.{ .at = .{ 2, -1 }, .layer = 0, .reach_mm = 0.01 }}, .typical_a = 0.2, .maximum_a = null },
    };
    const result = try solve(arena, .{
        .segments = &segments,
        .barrels = &.{},
        .counts = .{ .tracks = 3, .vias = 0 },
        .source_contacts = &.{.{ .at = .{ 0, 0 }, .layer = 0, .reach_mm = 0.01 }},
        .source_complete = true,
        .loads = &loads,
    });
    try testing.expectEqual(Status.solved, result.typical.status);
    try testing.expectApproxEqAbs(@as(f64, 1.0), result.typical.track_current_a[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.8), result.typical.track_current_a[1], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.2), result.typical.track_current_a[2], 1e-9);
    try testing.expectEqual(Status.no_current, result.maximum.status);
}

test "equal-resistance parallel paths share current equally" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const segments = [_]Segment{
        .{ .route_index = 0, .a = .{ 0, 0 }, .b = .{ 1, 1 }, .layer = 0, .resistance_ohm_per_mm = 0.01 },
        .{ .route_index = 1, .a = .{ 1, 1 }, .b = .{ 2, 0 }, .layer = 0, .resistance_ohm_per_mm = 0.01 },
        .{ .route_index = 2, .a = .{ 0, 0 }, .b = .{ 1, -1 }, .layer = 0, .resistance_ohm_per_mm = 0.01 },
        .{ .route_index = 3, .a = .{ 1, -1 }, .b = .{ 2, 0 }, .layer = 0, .resistance_ohm_per_mm = 0.01 },
    };
    const loads = [_]Load{.{ .contacts = &.{.{ .at = .{ 2, 0 }, .layer = 0, .reach_mm = 0.01 }}, .typical_a = 1, .maximum_a = null }};
    const result = try solve(arena, .{
        .segments = &segments,
        .barrels = &.{},
        .counts = .{ .tracks = 4, .vias = 0 },
        .source_contacts = &.{.{ .at = .{ 0, 0 }, .layer = 0, .reach_mm = 0.01 }},
        .source_complete = true,
        .loads = &loads,
    });
    for (result.typical.track_current_a) |current| try testing.expectApproxEqAbs(@as(f64, 0.5), current, 1e-9);
}

test "computed sheet component completes a split rail across separate traces" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const segments = [_]Segment{
        .{ .route_index = 0, .a = .{ 0, 0 }, .b = .{ 1, 0 }, .layer = 2, .resistance_ohm_per_mm = 0.01 },
        .{ .route_index = 1, .a = .{ 2, 1 }, .b = .{ 3, 1 }, .layer = 2, .resistance_ohm_per_mm = 0.01 },
        .{ .route_index = 2, .a = .{ 2, -1 }, .b = .{ 3, -1 }, .layer = 2, .resistance_ohm_per_mm = 0.01 },
    };
    const sheet_points = [_][2]f64{ .{ 1, 0 }, .{ 2, 1 }, .{ 2, -1 } };
    const loads = [_]Load{
        .{ .contacts = &.{.{ .at = .{ 3, 1 }, .layer = 2, .reach_mm = 0.01 }}, .typical_a = 0.8, .maximum_a = null },
        .{ .contacts = &.{.{ .at = .{ 3, -1 }, .layer = 2, .reach_mm = 0.01 }}, .typical_a = 0.2, .maximum_a = null },
    };
    const result = try solve(arena, .{
        .segments = &segments,
        .barrels = &.{},
        .sheets = &.{.{ .layer = 2, .contacts = &sheet_points }},
        .counts = .{ .tracks = 3, .vias = 0 },
        .source_contacts = &.{.{ .at = .{ 0, 0 }, .layer = 2, .reach_mm = 0.01 }},
        .source_complete = true,
        .loads = &loads,
    });
    try testing.expectEqual(Status.solved, result.typical.status);
    try testing.expectApproxEqAbs(@as(f64, 1.0), result.typical.track_current_a[0], 1e-8);
    try testing.expectApproxEqAbs(@as(f64, 0.8), result.typical.track_current_a[1], 1e-8);
    try testing.expectApproxEqAbs(@as(f64, 0.2), result.typical.track_current_a[2], 1e-8);
}
