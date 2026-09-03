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
//!
//! Geometry alone decides connectivity only when the caller says nothing else.
//! `Input.joins` carries an explicit junction list — normally built by
//! `net_graph.zig` from the canonical `copper_contact.zig` predicates that the
//! DRC topology oracle uses — and those junctions are added on top of the
//! centreline snapping below. Without them this module's private snap rules
//! (half-width for traces, barrel radius for vias, pad reach for terminals)
//! disagree with the DRC's copper model, and a rail whose topology carries no
//! `net_open` still comes back `disconnected`.

const std = @import("std");
const numeric = @import("../numeric.zig");

const node_eps_mm: f64 = 1e-4;
const min_piece_mm: f64 = 1e-7;
const terminal_resistance_ohm: f64 = 1e-6;
const pivot_epsilon: f64 = 1e-14;

/// Node budget for one net's conductance graph. The axis solve allocates a
/// dense `n × (n+1)` f64 matrix and eliminates it in O(n³), so an unbounded
/// graph turns a pathological net into gigabytes and minutes — the previous
/// code had no cap at all, and a 20k-node net would have asked for 3.2 GB.
/// 2048 bounds the matrix at ~34 MB, and the elimination (the tighter of the
/// two limits) at a few seconds. A real power rail resolves to tens or low
/// hundreds of nodes; a net over the cap reports `too_large`, and the caller
/// falls back to the whole-rail envelope instead of stalling the page. Raising
/// this is a sparse-solve change, not a constant change.
pub const default_max_nodes: usize = 2048;

/// Grid cell floor for the node spatial hash. Never smaller than this, so a
/// board of hairline copper cannot explode the bucket count.
const grid_cell_floor_mm: f64 = 0.05;

/// Cells a single spatial-hash query may sweep before it gives up and scans
/// every node. The cell size is chosen from the largest snap radius in the
/// input, so an ordinary query touches at most nine cells; this only guards
/// against a nonsense radius in malformed input.
const max_query_cells: usize = 4096;

/// One routed trace before it is split at electrical junctions.
pub const Segment = struct {
    route_index: usize,
    a: [2]f64,
    b: [2]f64,
    layer: u8,
    resistance_ohm_per_mm: f64,
    /// Copper width. Hand-drawn copper meets at overlapping ends, not at
    /// coincident centreline points, so an end or a junction within half
    /// this width of the centreline joins the segment.
    width_mm: f64 = 0,
};

/// One through-via barrel; resistance is the full top-to-bottom value.
pub const Barrel = struct {
    route_index: usize,
    at: [2]f64,
    resistance_ohm: f64,
    /// Barrel radius: copper whose centreline passes within it joins the via.
    radius_mm: f64 = 0,
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
/// resistance. `complete=false` drops the load from the solve (the axis then
/// reports `solved_partial` and its current under `Axis.unplaced`).
pub const Load = struct {
    contacts: []const Contact,
    typical_a: ?f64,
    maximum_a: ?f64,
    complete: bool = true,
};

/// One end of an explicit junction: the piece of copper it names, plus (for a
/// trace) the point along it where the other piece lands.
pub const Anchor = union(enum) {
    /// `index` is the trace's `route_index`; `at` is a point on or beside its
    /// centreline, which is projected onto the centreline and cut there.
    track: struct { index: usize, at: [2]f64 },
    /// A barrel's `route_index`. The junction lands on the barrel hub.
    via: usize,
    /// An index into `Input.sheets`. The junction lands on the sheet hub.
    sheet: usize,
    /// The source terminal hub.
    source,
    /// An index into `Input.loads`. The junction lands on that load's hub.
    load: usize,
};

/// Two pieces of this net's copper the canonical contact policy says are one
/// electrical node. Applied as a `terminal_resistance_ohm` tie, so a junction
/// never fabricates a resistive path the copper does not have.
pub const Join = struct { a: Anchor, b: Anchor };

/// The pads that feed this net, and whether they all resolved. An incomplete
/// source is refused outright: guessing where a rail enters the board would
/// silently invent a current path.
pub const Source = struct {
    contacts: []const Contact,
    complete: bool,
};

/// Inputs for one flattened PCB net.
pub const Input = struct {
    segments: []const Segment,
    barrels: []const Barrel,
    sheets: []const Sheet = &.{},
    counts: struct { tracks: usize, vias: usize },
    source: Source,
    loads: []const Load,
    /// Explicit junctions from the canonical copper-contact model. Empty means
    /// "geometry only", which is exactly the historical behaviour.
    joins: []const Join = &.{},
};

/// Why one current axis did or did not produce local conductor currents.
pub const Status = enum {
    solved,
    /// The source and at least one load were placed, but at least one other
    /// current-carrying load was not (see `Axis.placed` and `Axis.unplaced`).
    solved_partial,
    no_current,
    no_source_terminal,
    incomplete_load_terminals,
    disconnected,
    /// The net's copper graph exceeded the node budget (`default_max_nodes`).
    too_large,
    singular,

    /// Stable wire/UI spelling.
    pub fn name(self: Status) []const u8 {
        return switch (self) {
            .solved => "solved",
            .solved_partial => "solved-partial",
            .no_current => "no-current",
            .no_source_terminal => "no-source-terminal",
            .incomplete_load_terminals => "incomplete-load-terminals",
            .disconnected => "disconnected",
            .too_large => "too-large",
            .singular => "singular",
        };
    }

    /// Did this axis produce per-conductor currents? True for a partial solve:
    /// the placed conductors carry real solved currents, and the loads that
    /// could not be placed are reported separately rather than smeared over
    /// the whole rail.
    pub fn isSolved(self: Status) bool {
        return self == .solved or self == .solved_partial;
    }
};

/// Local currents and endpoint voltage drops for one typical/maximum axis.
pub const Axis = struct {
    status: Status,
    track_current_a: []f64,
    track_drop_v: []f64,
    via_current_a: []f64,
    via_drop_v: []f64,
    /// Per `Input.loads` entry: did this load's terminal resolve to copper the
    /// source can reach? A load that carries no current on this axis is still
    /// reported by its terminal, not by its current.
    placed: []const bool = &.{},
    /// What the loads this axis had to drop still draw. Zero on a full solve;
    /// on a partial one the caller owes this current a home elsewhere.
    unplaced: Unplaced = .{},
};

/// The current of the loads one axis could not place, on both declared axes.
/// Reported per axis because which loads got dropped is an axis decision.
pub const Unplaced = struct {
    typical_a: f64 = 0,
    maximum_a: f64 = 0,
};

/// Typical and maximum current-flow outcomes over one shared copper graph.
pub const Result = struct {
    typical: Axis,
    maximum: Axis,
};

const Key = struct { x: i64, y: i64, layer: i32 };
const EdgeKind = enum { track, via, sheet, terminal, join };
const Edge = struct { a: usize, b: usize, resistance: f64, kind: EdgeKind, route_index: usize = 0 };

const Cell = struct { x: i64, y: i64 };

/// Uniform spatial hash over the graph's LAYERED nodes (hubs carry no
/// position anyone searches by). It replaces the linear scans that made node
/// insertion, barrel contact discovery, and terminal attachment quadratic in
/// the node count. Every query returns candidates in ascending node order, so
/// the results are identical to the scan it replaced.
const Grid = struct {
    cell_mm: f64 = grid_cell_floor_mm,
    buckets: std.AutoHashMapUnmanaged(Cell, std.ArrayList(usize)) = .empty,

    fn cellOf(self: Grid, p: [2]f64) Cell {
        return .{
            .x = numeric.checkedInt(i64, @floor(p[0] / self.cell_mm)) orelse 0,
            .y = numeric.checkedInt(i64, @floor(p[1] / self.cell_mm)) orelse 0,
        };
    }

    fn insert(self: *Grid, arena: std.mem.Allocator, p: [2]f64, node: usize) std.mem.Allocator.Error!void {
        const entry = try self.buckets.getOrPut(arena, self.cellOf(p));
        if (!entry.found_existing) entry.value_ptr.* = .empty;
        try entry.value_ptr.append(arena, node);
    }

    /// Candidate nodes within `radius_mm` of `p`, ascending. `null` means the
    /// query would sweep too many cells and the caller must scan every node.
    fn near(
        self: Grid,
        arena: std.mem.Allocator,
        p: [2]f64,
        radius_mm: f64,
    ) std.mem.Allocator.Error!?[]const usize {
        const lo = self.cellOf(.{ p[0] - radius_mm, p[1] - radius_mm });
        const hi = self.cellOf(.{ p[0] + radius_mm, p[1] + radius_mm });
        const span_x: i128 = @as(i128, hi.x) - lo.x + 1;
        const span_y: i128 = @as(i128, hi.y) - lo.y + 1;
        if (span_x * span_y > max_query_cells) return null;
        var out: std.ArrayList(usize) = .empty;
        var y = lo.y;
        while (y <= hi.y) : (y += 1) {
            var x = lo.x;
            while (x <= hi.x) : (x += 1) {
                if (self.buckets.get(.{ .x = x, .y = y })) |list| try out.appendSlice(arena, list.items);
            }
        }
        std.mem.sort(usize, out.items, {}, comptime std.sort.asc(usize));
        return out.items;
    }
};

const Graph = struct {
    keys: std.ArrayList(Key) = .empty,
    /// `keys` inverted. First insertion wins, matching the scan it replaced.
    key_index: std.AutoHashMapUnmanaged(Key, usize) = .empty,
    pos: std.ArrayList([2]f64) = .empty,
    layer: std.ArrayList(?u8) = .empty,
    grid: Grid = .{},
    edges: std.ArrayList(Edge) = .empty,
    track_a: []usize,
    track_b: []usize,
    via_nodes: []std.ArrayList(usize),
    via_hub: []?usize,
    sheet_hubs: []?usize,
    source_hub: ?usize = null,
    load_hubs: []?usize,
    max_nodes: usize = default_max_nodes,
    /// The node budget was exhausted; the graph is incomplete and every axis
    /// over it reports `too_large`.
    overflow: bool = false,

    fn addNode(self: *Graph, arena: std.mem.Allocator, key: Key, p: [2]f64, layer: ?u8) std.mem.Allocator.Error!usize {
        const index = self.keys.items.len;
        try self.keys.append(arena, key);
        try self.pos.append(arena, p);
        try self.layer.append(arena, layer);
        const entry = try self.key_index.getOrPut(arena, key);
        if (!entry.found_existing) entry.value_ptr.* = index;
        if (layer != null) try self.grid.insert(arena, p, index);
        if (self.keys.items.len > self.max_nodes) self.overflow = true;
        return index;
    }

    fn nodeOf(self: *Graph, arena: std.mem.Allocator, p: [2]f64, layer: ?u8) std.mem.Allocator.Error!usize {
        const key = Key{
            .x = numeric.checkedInt(i64, @round(p[0] / node_eps_mm)) orelse 0,
            .y = numeric.checkedInt(i64, @round(p[1] / node_eps_mm)) orelse 0,
            .layer = if (layer) |value| @intCast(value) else -1,
        };
        if (self.key_index.get(key)) |index| return index;
        return self.addNode(arena, key, p, layer);
    }

    /// `nodeOf` with a geometric snap: an existing node on the same layer
    /// within `snap_mm` of `p` is the same copper point, because the two
    /// pieces of copper overlap there even though their centrelines miss.
    fn nodeNear(self: *Graph, arena: std.mem.Allocator, p: [2]f64, layer: ?u8, snap_mm: f64) std.mem.Allocator.Error!usize {
        if (snap_mm > node_eps_mm and layer != null) {
            if (try self.grid.near(arena, p, snap_mm)) |candidates| {
                for (candidates) |i| {
                    if (self.matchesSnap(i, p, layer, snap_mm)) return i;
                }
            } else {
                for (0..self.pos.items.len) |i| {
                    if (self.matchesSnap(i, p, layer, snap_mm)) return i;
                }
            }
        }
        return self.nodeOf(arena, p, layer);
    }

    fn matchesSnap(self: Graph, i: usize, p: [2]f64, layer: ?u8, snap_mm: f64) bool {
        const old_layer = self.layer.items[i];
        if (old_layer == null or layer == null or old_layer.? != layer.?) return false;
        return dist(self.pos.items[i], p) <= snap_mm;
    }

    /// Layered nodes within `radius_mm` of `p`, ascending, limited to the
    /// first `limit` nodes of the graph.
    fn layeredNear(
        self: Graph,
        arena: std.mem.Allocator,
        p: [2]f64,
        radius_mm: f64,
        limit: usize,
        out: *std.ArrayList(usize),
    ) std.mem.Allocator.Error!void {
        if (try self.grid.near(arena, p, radius_mm)) |candidates| {
            for (candidates) |node| {
                if (node >= limit or self.layer.items[node] == null) continue;
                if (dist(self.pos.items[node], p) <= radius_mm) try appendUnique(arena, out, node);
            }
            return;
        }
        for (self.pos.items[0..@min(limit, self.pos.items.len)], 0..) |point, node| {
            if (self.layer.items[node] == null or dist(point, p) > radius_mm) continue;
            try appendUnique(arena, out, node);
        }
    }

    fn newHub(self: *Graph, arena: std.mem.Allocator, p: [2]f64) std.mem.Allocator.Error!usize {
        const index = self.keys.items.len;
        const unique_layer: i32 = -1 - @as(i32, @intCast(index));
        return self.addNode(arena, .{
            .x = numeric.checkedInt(i64, @round(p[0] / node_eps_mm)) orelse 0,
            .y = numeric.checkedInt(i64, @round(p[1] / node_eps_mm)) orelse 0,
            .layer = unique_layer,
        }, p, null);
    }

    fn addEdge(self: *Graph, arena: std.mem.Allocator, edge: Edge) std.mem.Allocator.Error!void {
        if (edge.a == edge.b or invalidResistance(edge.resistance)) return;
        try self.edges.append(arena, edge);
    }
};

fn invalidResistance(value: f64) bool {
    return !(value > 0) or !std.math.isFinite(value);
}

/// Solve both declared current axes. The conductance graph is built once and
/// shared — and only when at least one axis actually needs it, so a net with
/// no annotated current (ground, most signal nets) never pays for a graph over
/// its hundreds of stitching vias.
pub fn solve(arena: std.mem.Allocator, input: Input) std.mem.Allocator.Error!Result {
    return solveWithin(arena, input, default_max_nodes);
}

/// `solve` under an explicit node budget. Exposed so the cap itself is
/// testable without synthesising thousands of traces.
pub fn solveWithin(arena: std.mem.Allocator, input: Input, max_nodes: usize) std.mem.Allocator.Error!Result {
    const typical_pre = preStatus(input, false);
    const maximum_pre = preStatus(input, true);
    if (typical_pre != null and maximum_pre != null) return .{
        .typical = try emptyAxis(arena, input, typical_pre.?),
        .maximum = try emptyAxis(arena, input, maximum_pre.?),
    };
    var graph = try buildGraph(arena, input, max_nodes);
    return .{
        .typical = if (typical_pre) |status| try emptyAxis(arena, input, status) else try solveAxis(arena, input, &graph, false),
        .maximum = if (maximum_pre) |status| try emptyAxis(arena, input, status) else try solveAxis(arena, input, &graph, true),
    };
}

/// Will `solve` build a copper graph for this input? False when no axis
/// carries current, and false when the source never resolved — so a caller
/// that pays to prepare solver inputs, notably the quadratic junction sweep in
/// `net_graph.zig`, can skip that work for ground and every unannotated net.
pub fn needsGraph(input: Input) bool {
    return preStatus(input, false) == null or preStatus(input, true) == null;
}

/// The verdicts that need no copper graph at all. Running them first is what
/// keeps a currentless net off the graph builder.
fn preStatus(input: Input, maximum: bool) ?Status {
    var total: f64 = 0;
    for (input.loads) |load| total += loadCurrent(load, maximum);
    if (!(total > 0)) return .no_current;
    if (!input.source.complete) return .no_source_terminal;
    return null;
}

fn emptyAxis(arena: std.mem.Allocator, input: Input, status: Status) std.mem.Allocator.Error!Axis {
    const track_current = try arena.alloc(f64, input.counts.tracks);
    const track_drop = try arena.alloc(f64, input.counts.tracks);
    const via_current = try arena.alloc(f64, input.counts.vias);
    const via_drop = try arena.alloc(f64, input.counts.vias);
    const placed = try arena.alloc(bool, input.loads.len);
    @memset(track_current, 0);
    @memset(track_drop, 0);
    @memset(via_current, 0);
    @memset(via_drop, 0);
    @memset(placed, false);
    return .{
        .status = status,
        .track_current_a = track_current,
        .track_drop_v = track_drop,
        .via_current_a = via_current,
        .via_drop_v = via_drop,
        .placed = placed,
    };
}

/// The largest snap radius any node lookup in this input can ask for. Using it
/// as the grid cell keeps every query inside a 3×3 neighbourhood.
fn gridCellMm(input: Input) f64 {
    var cell = grid_cell_floor_mm;
    for (input.segments) |segment| cell = @max(cell, segment.width_mm / 2);
    for (input.barrels) |barrel| cell = @max(cell, barrel.radius_mm);
    for (input.source.contacts) |contact| cell = @max(cell, contact.reach_mm);
    for (input.loads) |load| for (load.contacts) |contact| {
        cell = @max(cell, contact.reach_mm);
    };
    return if (std.math.isFinite(cell) and cell > 0) cell else grid_cell_floor_mm;
}

const Cuts = struct {
    /// Split parameters per entry of `input.segments`.
    per_segment: []const []const f64,
    /// `route_index` → index into `input.segments`.
    segment_of_route: []const ?usize,
};

fn buildGraph(arena: std.mem.Allocator, input: Input, max_nodes: usize) std.mem.Allocator.Error!Graph {
    var graph = Graph{
        .track_a = try arena.alloc(usize, input.counts.tracks),
        .track_b = try arena.alloc(usize, input.counts.tracks),
        .via_nodes = try arena.alloc(std.ArrayList(usize), input.counts.vias),
        .via_hub = try arena.alloc(?usize, input.counts.vias),
        .sheet_hubs = try arena.alloc(?usize, input.sheets.len),
        .load_hubs = try arena.alloc(?usize, input.loads.len),
        .max_nodes = @max(1, max_nodes),
    };
    @memset(graph.track_a, 0);
    @memset(graph.track_b, 0);
    for (graph.via_nodes) |*nodes| nodes.* = .empty;
    @memset(graph.via_hub, null);
    @memset(graph.sheet_hubs, null);
    @memset(graph.load_hubs, null);
    graph.grid.cell_mm = gridCellMm(input);

    const cuts = try allCuts(arena, input);
    for (input.segments, 0..) |segment, si| {
        var previous = segment.a;
        graph.track_a[segment.route_index] = try graph.nodeNear(arena, segment.a, segment.layer, segment.width_mm / 2);
        graph.track_b[segment.route_index] = try graph.nodeNear(arena, segment.b, segment.layer, segment.width_mm / 2);
        for (cuts.per_segment[si]) |t| {
            if (graph.overflow) return graph;
            const at = lerp(segment.a, segment.b, t);
            try addPiece(arena, &graph, segment, previous, at);
            previous = at;
        }
        try addPiece(arena, &graph, segment, previous, segment.b);
        if (graph.overflow) return graph;
    }
    for (input.sheets, 0..) |sheet, i| {
        try addSheet(arena, &graph, sheet, i);
        if (graph.overflow) return graph;
    }
    const forced = try forcedAnchors(arena, input);
    for (input.barrels) |barrel| {
        try addBarrel(arena, &graph, barrel, barrel.route_index < forced.vias.len and forced.vias[barrel.route_index]);
        if (graph.overflow) return graph;
    }
    graph.source_hub = try addTerminal(arena, &graph, input.source.contacts, forced.source);
    for (input.loads, 0..) |load, i| graph.load_hubs[i] = try addTerminal(arena, &graph, load.contacts, forced.loads[i]);
    if (graph.overflow) return graph;
    try applyJoins(arena, &graph, input, cuts);
    return graph;
}

/// Which barrels/terminals a junction names. Those hubs have to exist even
/// when geometry alone found no copper to hang them on — that is the whole
/// point of handing the solver the canonical contact model.
const Forced = struct { vias: []const bool, source: bool, loads: []const bool };

fn forcedAnchors(arena: std.mem.Allocator, input: Input) std.mem.Allocator.Error!Forced {
    const vias = try arena.alloc(bool, input.counts.vias);
    const loads = try arena.alloc(bool, input.loads.len);
    @memset(vias, false);
    @memset(loads, false);
    var source = false;
    for (input.joins) |join| for ([2]Anchor{ join.a, join.b }) |anchor| switch (anchor) {
        .via => |index| if (index < vias.len) {
            vias[index] = true;
        },
        .source => source = true,
        .load => |index| if (index < loads.len) {
            loads[index] = true;
        },
        else => {},
    };
    return .{ .vias = vias, .source = source, .loads = loads };
}

/// Every segment's split parameters, geometric cuts first and junction cuts
/// folded in afterwards so a caller that supplies no junctions gets exactly
/// the historical parameter list.
fn allCuts(arena: std.mem.Allocator, input: Input) std.mem.Allocator.Error!Cuts {
    const segment_of_route = try arena.alloc(?usize, input.counts.tracks);
    @memset(segment_of_route, null);
    for (input.segments, 0..) |segment, si| {
        if (segment.route_index < segment_of_route.len) segment_of_route[segment.route_index] = si;
    }
    const per_segment = try arena.alloc([]const f64, input.segments.len);
    const lists = try arena.alloc(std.ArrayList(f64), input.segments.len);
    for (input.segments, 0..) |segment, si| lists[si] = try splitParams(arena, input, segment);
    for (input.joins) |join| for ([2]Anchor{ join.a, join.b }) |anchor| switch (anchor) {
        .track => |ref| {
            const si = (if (ref.index < segment_of_route.len) segment_of_route[ref.index] else null) orelse continue;
            const segment = input.segments[si];
            const length = dist(segment.a, segment.b);
            if (length < min_piece_mm) continue;
            try appendParam(arena, &lists[si], clampParam(segment, ref.at), length);
        },
        else => {},
    };
    for (lists, 0..) |*list, si| {
        std.mem.sort(f64, list.items, {}, comptime std.sort.asc(f64));
        per_segment[si] = list.items;
    }
    return .{ .per_segment = per_segment, .segment_of_route = segment_of_route };
}

fn addSheet(arena: std.mem.Allocator, graph: *Graph, sheet: Sheet, index: usize) std.mem.Allocator.Error!void {
    if (sheet.contacts.len == 0) return;
    const hub = try graph.newHub(arena, sheet.contacts[0]);
    graph.sheet_hubs[index] = hub;
    for (sheet.contacts) |at| {
        if (graph.overflow) return;
        const node = try graph.nodeOf(arena, at, sheet.layer);
        try graph.addEdge(arena, .{ .a = node, .b = hub, .resistance = terminal_resistance_ohm, .kind = .sheet });
    }
}

fn addPiece(arena: std.mem.Allocator, graph: *Graph, segment: Segment, a: [2]f64, b: [2]f64) std.mem.Allocator.Error!void {
    const length = dist(a, b);
    if (length < min_piece_mm) return;
    const na = try graph.nodeNear(arena, a, segment.layer, segment.width_mm / 2);
    const nb = try graph.nodeNear(arena, b, segment.layer, segment.width_mm / 2);
    try graph.addEdge(arena, .{ .a = na, .b = nb, .resistance = segment.resistance_ohm_per_mm * length, .kind = .track, .route_index = segment.route_index });
}

fn addBarrel(arena: std.mem.Allocator, graph: *Graph, barrel: Barrel, forced: bool) std.mem.Allocator.Error!void {
    var contacts: std.ArrayList(usize) = .empty;
    try graph.layeredNear(arena, barrel.at, @max(barrel.radius_mm, node_eps_mm) + node_eps_mm, graph.pos.items.len, &contacts);
    if (contacts.items.len < 2 and !forced) return;
    const hub = try graph.newHub(arena, barrel.at);
    graph.via_hub[barrel.route_index] = hub;
    const spoke_resistance = barrel.resistance_ohm / 2.0;
    for (contacts.items) |node| {
        try graph.addEdge(arena, .{ .a = node, .b = hub, .resistance = spoke_resistance, .kind = .via, .route_index = barrel.route_index });
        try appendUnique(arena, &graph.via_nodes[barrel.route_index], node);
    }
    try appendUnique(arena, &graph.via_nodes[barrel.route_index], hub);
}

fn addTerminal(arena: std.mem.Allocator, graph: *Graph, contacts: []const Contact, forced: bool) std.mem.Allocator.Error!?usize {
    if (contacts.len == 0) return null;
    const copper_nodes = graph.keys.items.len;
    var touched: std.ArrayList(usize) = .empty;
    for (contacts) |contact| {
        var candidates: std.ArrayList(usize) = .empty;
        try graph.layeredNear(arena, contact.at, contact.reach_mm + node_eps_mm, copper_nodes, &candidates);
        for (candidates.items) |node| {
            if (contact.layer) |want| if (graph.layer.items[node].? != want) continue;
            try appendUnique(arena, &touched, node);
        }
    }
    if (touched.items.len == 0 and !forced) return null;
    const hub = try graph.newHub(arena, contacts[0].at);
    for (touched.items) |node| try graph.addEdge(arena, .{ .a = hub, .b = node, .resistance = terminal_resistance_ohm, .kind = .terminal });
    return hub;
}

fn applyJoins(arena: std.mem.Allocator, graph: *Graph, input: Input, cuts: Cuts) std.mem.Allocator.Error!void {
    const barrel_ohm = try arena.alloc(f64, input.counts.vias);
    @memset(barrel_ohm, 0);
    for (input.barrels) |barrel| {
        if (barrel.route_index < barrel_ohm.len) barrel_ohm[barrel.route_index] = barrel.resistance_ohm;
    }
    for (input.joins) |join| {
        const a = try anchorNode(arena, graph, input, cuts, join.a) orelse continue;
        const b = try anchorNode(arena, graph, input, cuts, join.b) orelse continue;
        if (soleBarrel(join)) |index| {
            const hub = graph.via_hub[index] orelse continue;
            try addBarrelJoin(arena, graph, index, barrel_ohm[index], if (a == hub) b else a);
            continue;
        }
        try graph.addEdge(arena, .{ .a = a, .b = b, .resistance = terminal_resistance_ohm, .kind = .join });
    }
}

fn barrelOf(anchor: Anchor) ?usize {
    return switch (anchor) {
        .via => |index| index,
        else => null,
    };
}

/// The one barrel a junction names, or null when it names none or two. A
/// via-to-via junction stays an ordinary tie: two overlapping barrels really
/// are one piece of plating, and neither is bypassed by saying so.
fn soleBarrel(join: Join) ?usize {
    const a = barrelOf(join.a);
    const b = barrelOf(join.b);
    if (a != null and b != null) return null;
    return a orelse b;
}

/// Attach one piece of copper to a barrel the way the barrel's own land does:
/// through a half-barrel spoke.
///
/// Tying it to the barrel HUB at `terminal_resistance_ohm` instead — which is
/// what an ordinary junction edge does — puts a 1 µΩ path in parallel with the
/// plating every other piece of copper on that land already reaches the hub
/// through. The transition's whole current then flows AROUND the barrel: a
/// two-layer rail carrying 0.8 A reported 0.7 mA in its via, and every
/// over-current barrel screen came back clean. `route_index` is set so the
/// current this spoke does carry is credited to the barrel.
fn addBarrelJoin(
    arena: std.mem.Allocator,
    graph: *Graph,
    index: usize,
    barrel_ohm: f64,
    node: usize,
) std.mem.Allocator.Error!void {
    const hub = graph.via_hub[index] orelse return;
    if (node == hub) return;
    // A barrel with no modelled plated area (a saved via recording no drill)
    // has no spoke to enter through and carries no current worth crediting.
    // It keeps the ordinary tie, which is the only thing holding such a net
    // together and is exactly what every junction did before.
    if (!(barrel_ohm > 0) or !std.math.isFinite(barrel_ohm)) {
        return graph.addEdge(arena, .{ .a = node, .b = hub, .resistance = terminal_resistance_ohm, .kind = .join });
    }
    // The barrel's land already attached this node: a second spoke would halve
    // the barrel's modelled resistance and split its reported current in two.
    for (graph.via_nodes[index].items) |old| if (old == node) return;
    try graph.addEdge(arena, .{ .a = node, .b = hub, .resistance = barrel_ohm / 2.0, .kind = .via, .route_index = index });
    try appendUnique(arena, &graph.via_nodes[index], node);
}

fn anchorNode(
    arena: std.mem.Allocator,
    graph: *Graph,
    input: Input,
    cuts: Cuts,
    anchor: Anchor,
) std.mem.Allocator.Error!?usize {
    return switch (anchor) {
        .via => |index| if (index < graph.via_hub.len) graph.via_hub[index] else null,
        .sheet => |index| if (index < graph.sheet_hubs.len) graph.sheet_hubs[index] else null,
        .source => graph.source_hub,
        .load => |index| if (index < graph.load_hubs.len) graph.load_hubs[index] else null,
        .track => |ref| try trackAnchorNode(arena, graph, input, cuts, ref.index, ref.at),
    };
}

/// The graph node a junction on `route_index` lands on. `allCuts` already put
/// a split at this parameter, so the point resolves to a node inside the
/// trace's own chain rather than to a fresh island beside it.
fn trackAnchorNode(
    arena: std.mem.Allocator,
    graph: *Graph,
    input: Input,
    cuts: Cuts,
    route_index: usize,
    at: [2]f64,
) std.mem.Allocator.Error!?usize {
    if (route_index >= cuts.segment_of_route.len) return null;
    const si = cuts.segment_of_route[route_index] orelse return null;
    const segment = input.segments[si];
    const length = dist(segment.a, segment.b);
    if (length < min_piece_mm) return null;
    const t = clampParam(segment, at);
    const margin = node_eps_mm / length;
    if (t <= margin) return graph.track_a[route_index];
    if (t >= 1.0 - margin) return graph.track_b[route_index];
    var use = t;
    for (cuts.per_segment[si]) |cut| if (@abs(cut - t) <= margin) {
        use = cut;
        break;
    };
    return try graph.nodeNear(arena, lerp(segment.a, segment.b, use), segment.layer, segment.width_mm / 2);
}

/// Where `point` projects onto `segment`, clamped into the trace's own span.
fn clampParam(segment: Segment, point: [2]f64) f64 {
    const dx = segment.b[0] - segment.a[0];
    const dy = segment.b[1] - segment.a[1];
    const length2 = dx * dx + dy * dy;
    if (length2 <= min_piece_mm * min_piece_mm) return 0;
    const t = ((point[0] - segment.a[0]) * dx + (point[1] - segment.a[1]) * dy) / length2;
    return std.math.clamp(t, 0, 1);
}

/// Which loads this axis can actually place, and what current the rest owe.
const Placement = struct {
    placed: []bool,
    any_placed: bool = false,
    missing_terminal: bool = false,
    unreachable_load: bool = false,
    unplaced_typical_a: f64 = 0,
    unplaced_maximum_a: f64 = 0,
};

fn placeLoads(
    arena: std.mem.Allocator,
    input: Input,
    graph: Graph,
    maximum: bool,
    reachable: []const bool,
) std.mem.Allocator.Error!Placement {
    var out = Placement{ .placed = try arena.alloc(bool, input.loads.len) };
    for (input.loads, 0..) |load, i| {
        const hub = if (load.complete) graph.load_hubs[i] else null;
        out.placed[i] = hub != null and reachable[hub.?];
        if (!(loadCurrent(load, maximum) > 0)) continue;
        if (out.placed[i]) {
            out.any_placed = true;
            continue;
        }
        if (hub == null) out.missing_terminal = true else out.unreachable_load = true;
        out.unplaced_typical_a += positiveCurrent(load.typical_a);
        out.unplaced_maximum_a += positiveCurrent(load.maximum_a);
    }
    return out;
}

fn solveAxis(arena: std.mem.Allocator, input: Input, graph: *Graph, maximum: bool) std.mem.Allocator.Error!Axis {
    if (graph.overflow) return emptyAxis(arena, input, .too_large);
    const source = graph.source_hub orelse return emptyAxis(arena, input, .no_source_terminal);
    const reachable = try reachableFrom(arena, graph.*, source);
    const place = try placeLoads(arena, input, graph.*, maximum, reachable);
    if (!place.any_placed) return emptyAxis(arena, input, if (place.missing_terminal) .incomplete_load_terminals else .disconnected);
    const node_map = try makeNodeMap(arena, reachable, source);
    const map = node_map.map;
    const unknown_count = node_map.count;
    if (unknown_count == 0) return emptyAxis(arena, input, .singular);
    const system = System{
        .cells = try arena.alloc(f64, unknown_count * (unknown_count + 1)),
        .unknowns = unknown_count,
    };
    @memset(system.cells, 0);
    stampConductors(system, graph.edges.items, reachable, map);
    if (!stampLoads(system, input, graph.*, maximum, map, place.placed)) return emptyAxis(arena, input, .singular);
    if (!gaussSolve(system)) return emptyAxis(arena, input, .singular);
    const voltage = try arena.alloc(f64, graph.keys.items.len);
    @memset(voltage, 0);
    for (map, 0..) |row, node| {
        if (row) |r| voltage[node] = system.at(r, unknown_count).*;
    }
    return buildAxisOutput(arena, input, graph.*, reachable, voltage, place);
}

/// The dense nodal-analysis system: `unknowns` rows of `unknowns + 1` cells,
/// row-major, the last column of each row the right-hand side. Bundled so the
/// stamping and elimination steps take one argument instead of two that must
/// agree.
const System = struct {
    cells: []f64,
    unknowns: usize,

    fn stride(self: System) usize {
        return self.unknowns + 1;
    }

    fn at(self: System, row: usize, col: usize) *f64 {
        return &self.cells[row * self.stride() + col];
    }
};

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

fn stampConductors(system: System, edges: []const Edge, reachable: []const bool, map: []const ?usize) void {
    for (edges) |edge| {
        if (!reachable[edge.a] or !reachable[edge.b]) continue;
        const conductance = 1.0 / edge.resistance;
        if (map[edge.a]) |a| {
            system.at(a, a).* += conductance;
            if (map[edge.b]) |b| system.at(a, b).* -= conductance;
        }
        if (map[edge.b]) |b| {
            system.at(b, b).* += conductance;
            if (map[edge.a]) |a| system.at(b, a).* -= conductance;
        }
    }
}

fn stampLoads(
    system: System,
    input: Input,
    graph: Graph,
    maximum: bool,
    map: []const ?usize,
    placed: []const bool,
) bool {
    for (input.loads, 0..) |load, i| {
        if (!placed[i]) continue;
        const current = loadCurrent(load, maximum);
        if (!(current > 0)) continue;
        const row = map[graph.load_hubs[i].?] orelse return false;
        system.at(row, system.unknowns).* -= current;
    }
    return true;
}

fn buildAxisOutput(
    arena: std.mem.Allocator,
    input: Input,
    graph: Graph,
    reachable: []const bool,
    voltage: []const f64,
    place: Placement,
) std.mem.Allocator.Error!Axis {
    const partial = place.missing_terminal or place.unreachable_load;
    var out = try emptyAxis(arena, input, if (partial) .solved_partial else .solved);
    out.placed = place.placed;
    out.unplaced = .{ .typical_a = place.unplaced_typical_a, .maximum_a = place.unplaced_maximum_a };
    for (graph.edges.items) |edge| {
        if (!reachable[edge.a] or !reachable[edge.b]) continue;
        const drop = @abs(voltage[edge.a] - voltage[edge.b]);
        const current = drop / edge.resistance;
        switch (edge.kind) {
            .track => out.track_current_a[edge.route_index] = @max(out.track_current_a[edge.route_index], current),
            .via => out.via_current_a[edge.route_index] = @max(out.via_current_a[edge.route_index], current),
            .sheet, .terminal, .join => {},
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

fn gaussSolve(system: System) bool {
    const n = system.unknowns;
    const stride = system.stride();
    var col: usize = 0;
    while (col < n) : (col += 1) {
        var pivot = col;
        var best = @abs(system.at(col, col).*);
        for (col + 1..n) |row| {
            const candidate = @abs(system.at(row, col).*);
            if (candidate > best) {
                best = candidate;
                pivot = row;
            }
        }
        if (!(best > pivot_epsilon) or !std.math.isFinite(best)) return false;
        if (pivot != col) for (0..stride) |j| std.mem.swap(f64, system.at(col, j), system.at(pivot, j));
        const divisor = system.at(col, col).*;
        for (col..stride) |j| system.at(col, j).* /= divisor;
        for (0..n) |row| {
            if (row == col) continue;
            const factor = system.at(row, col).*;
            if (factor == 0) continue;
            for (col..stride) |j| system.at(row, j).* -= factor * system.at(col, j).*;
        }
    }
    return true;
}

/// Neighbour lists in edge order, so the traversal below visits nodes in the
/// same order the all-edges rescan used to. Building this once turns the
/// flood fill from O(nodes × edges) into O(nodes + edges).
const Adjacency = struct {
    offsets: []usize,
    neighbours: []usize,
};

fn adjacency(arena: std.mem.Allocator, graph: Graph) std.mem.Allocator.Error!Adjacency {
    const n = graph.keys.items.len;
    const offsets = try arena.alloc(usize, n + 1);
    @memset(offsets, 0);
    for (graph.edges.items) |edge| {
        offsets[edge.a] += 1;
        offsets[edge.b] += 1;
    }
    var running: usize = 0;
    for (offsets) |*slot| {
        const count = slot.*;
        slot.* = running;
        running += count;
    }
    const neighbours = try arena.alloc(usize, running);
    const cursor = try arena.alloc(usize, n);
    @memcpy(cursor, offsets[0..n]);
    for (graph.edges.items) |edge| {
        neighbours[cursor[edge.a]] = edge.b;
        cursor[edge.a] += 1;
        neighbours[cursor[edge.b]] = edge.a;
        cursor[edge.b] += 1;
    }
    return .{ .offsets = offsets, .neighbours = neighbours };
}

fn reachableFrom(arena: std.mem.Allocator, graph: Graph, source: usize) std.mem.Allocator.Error![]bool {
    const adj = try adjacency(arena, graph);
    const seen = try arena.alloc(bool, graph.keys.items.len);
    @memset(seen, false);
    var queue: std.ArrayList(usize) = .empty;
    seen[source] = true;
    try queue.append(arena, source);
    var head: usize = 0;
    while (head < queue.items.len) : (head += 1) {
        const node = queue.items[head];
        for (adj.neighbours[adj.offsets[node]..adj.offsets[node + 1]]) |other| {
            if (seen[other]) continue;
            seen[other] = true;
            try queue.append(arena, other);
        }
    }
    return seen;
}

fn splitParams(
    arena: std.mem.Allocator,
    input: Input,
    segment: Segment,
) std.mem.Allocator.Error!std.ArrayList(f64) {
    var out: std.ArrayList(f64) = .empty;
    const length = dist(segment.a, segment.b);
    if (length < min_piece_mm) return out;
    const half = segment.width_mm / 2;
    for (input.segments) |other| {
        if (other.layer != segment.layer) continue;
        const join = @max(half, other.width_mm / 2);
        for ([2][2]f64{ other.a, other.b }) |point| if (projectOn(segment, point, join)) |t| try appendParam(arena, &out, t, length);
        if (crossParam(segment, other)) |t| try appendParam(arena, &out, t, length);
    }
    for (input.barrels) |barrel| if (projectOn(segment, barrel.at, barrel.radius_mm)) |t| try appendParam(arena, &out, t, length);
    for (input.sheets) |sheet| {
        if (sheet.layer != segment.layer) continue;
        for (sheet.contacts) |at| if (projectOn(segment, at, half)) |t| try appendParam(arena, &out, t, length);
    }
    return out;
}

fn appendParam(arena: std.mem.Allocator, out: *std.ArrayList(f64), t: f64, length: f64) std.mem.Allocator.Error!void {
    const margin = node_eps_mm / length;
    if (t <= margin or t >= 1.0 - margin) return;
    for (out.items) |old| if (@abs(old - t) <= margin) return;
    try out.append(arena, t);
}

/// The parameter along `segment` where `point` joins it: the point's
/// projection when it lies within `tolerance_mm` (never less than the node
/// epsilon) of the centreline, null when it misses the copper.
fn projectOn(segment: Segment, point: [2]f64, tolerance_mm: f64) ?f64 {
    const dx = segment.b[0] - segment.a[0];
    const dy = segment.b[1] - segment.a[1];
    const length2 = dx * dx + dy * dy;
    if (length2 <= min_piece_mm * min_piece_mm) return null;
    const t = ((point[0] - segment.a[0]) * dx + (point[1] - segment.a[1]) * dy) / length2;
    if (t < 0 or t > 1) return null;
    if (dist(lerp(segment.a, segment.b, t), point) > @max(tolerance_mm, node_eps_mm)) return null;
    return t;
}

/// The parameter along `a` where the two centrelines cross, or null when they
/// are parallel or cross outside either span. Public because `net_graph.zig`
/// has to name the same crossing point when it builds an explicit junction.
pub fn crossParam(a: Segment, b: Segment) ?f64 {
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
        .source = .{ .contacts = &.{.{ .at = .{ 0, 0 }, .layer = 0, .reach_mm = 0.01 }}, .complete = true },
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
        .source = .{ .contacts = &.{.{ .at = .{ 0, 0 }, .layer = 0, .reach_mm = 0.01 }}, .complete = true },
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
        .source = .{ .contacts = &.{.{ .at = .{ 0, 0 }, .layer = 2, .reach_mm = 0.01 }}, .complete = true },
        .loads = &loads,
    });
    try testing.expectEqual(Status.solved, result.typical.status);
    try testing.expectApproxEqAbs(@as(f64, 1.0), result.typical.track_current_a[0], 1e-8);
    try testing.expectApproxEqAbs(@as(f64, 0.8), result.typical.track_current_a[1], 1e-8);
    try testing.expectApproxEqAbs(@as(f64, 0.2), result.typical.track_current_a[2], 1e-8);
}

// spec: placement/power-routing - a branch whose end lands inside the trunk's copper joins the trunk even when its centreline misses the trunk's by less than the copper half-width
test "a branch ending inside the trunk copper joins the trunk" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The branch ends 0.05 mm above the 0.3 mm trunk's centreline: inside its copper.
    const segments = [_]Segment{
        .{ .route_index = 0, .a = .{ 0, 0 }, .b = .{ 2, 0 }, .layer = 0, .resistance_ohm_per_mm = 0.01, .width_mm = 0.3 },
        .{ .route_index = 1, .a = .{ 1, 0.05 }, .b = .{ 1, 1 }, .layer = 0, .resistance_ohm_per_mm = 0.01, .width_mm = 0.2 },
    };
    const loads = [_]Load{.{ .contacts = &.{.{ .at = .{ 1, 1 }, .layer = 0, .reach_mm = 0.01 }}, .typical_a = 1, .maximum_a = null }};
    const result = try solve(arena, .{
        .segments = &segments,
        .barrels = &.{},
        .counts = .{ .tracks = 2, .vias = 0 },
        .source = .{ .contacts = &.{.{ .at = .{ 0, 0 }, .layer = 0, .reach_mm = 0.01 }}, .complete = true },
        .loads = &loads,
    });
    try testing.expectEqual(Status.solved, result.typical.status);
    try testing.expectApproxEqAbs(@as(f64, 1.0), result.typical.track_current_a[1], 1e-9);
}

// spec: placement/power-routing - a via joins every track whose copper its barrel overlaps, not only tracks ending exactly at its centre
test "a via joins a track whose end sits inside its barrel" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The bottom track ends 0.03 mm from the 0.4 mm via's centre.
    const segments = [_]Segment{
        .{ .route_index = 0, .a = .{ 0, 0 }, .b = .{ 1, 0 }, .layer = 0, .resistance_ohm_per_mm = 0.01, .width_mm = 0.2 },
        .{ .route_index = 1, .a = .{ 1.03, 0 }, .b = .{ 2, 0 }, .layer = 1, .resistance_ohm_per_mm = 0.01, .width_mm = 0.2 },
    };
    const barrels = [_]Barrel{.{ .route_index = 0, .at = .{ 1, 0 }, .resistance_ohm = 0.001, .radius_mm = 0.2 }};
    const loads = [_]Load{.{ .contacts = &.{.{ .at = .{ 2, 0 }, .layer = 1, .reach_mm = 0.01 }}, .typical_a = 1, .maximum_a = null }};
    const result = try solve(arena, .{
        .segments = &segments,
        .barrels = &barrels,
        .counts = .{ .tracks = 2, .vias = 1 },
        .source = .{ .contacts = &.{.{ .at = .{ 0, 0 }, .layer = 0, .reach_mm = 0.01 }}, .complete = true },
        .loads = &loads,
    });
    try testing.expectEqual(Status.solved, result.typical.status);
    try testing.expectApproxEqAbs(@as(f64, 1.0), result.typical.via_current_a[0], 1e-9);
}

/// A 0.2 mm branch T-ing into the interior of a 2 mm trunk, 0.9 mm off the
/// trunk's centreline. The branch's whole transverse cross-section lies inside
/// the trunk's copper, so `copper_contact` (and therefore DRC topology) calls
/// this connected — but the centreline snap only reaches half the BRANCH's
/// width, so geometry alone leaves the load on its own island.
fn tJunctionInput(joins: []const Join) Input {
    const segments = &[_]Segment{
        .{ .route_index = 0, .a = .{ 0, 0 }, .b = .{ 4, 0 }, .layer = 0, .resistance_ohm_per_mm = 0.001, .width_mm = 2.0 },
        .{ .route_index = 1, .a = .{ 2, 0.9 }, .b = .{ 2, 3 }, .layer = 0, .resistance_ohm_per_mm = 0.01, .width_mm = 0.2 },
    };
    const loads = &[_]Load{.{ .contacts = &.{.{ .at = .{ 2, 3 }, .layer = 0, .reach_mm = 0.01 }}, .typical_a = 1, .maximum_a = null }};
    return .{
        .segments = segments,
        .barrels = &.{},
        .counts = .{ .tracks = 2, .vias = 0 },
        .source = .{ .contacts = &.{.{ .at = .{ 0, 0 }, .layer = 0, .reach_mm = 0.01 }}, .complete = true },
        .loads = loads,
        .joins = joins,
    };
}

// spec: placement/power-routing - an explicit copper-contact junction joins a branch that overlaps the trunk's copper but whose centreline misses it by more than the branch half-width
test "an explicit junction joins a branch the centreline snap cannot reach" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // Geometry alone: the branch never reaches the trunk.
    const bare = try solve(arena, tJunctionInput(&.{}));
    try testing.expectEqual(Status.disconnected, bare.typical.status);

    const joins = [_]Join{.{
        .a = .{ .track = .{ .index = 0, .at = .{ 2, 0.9 } } },
        .b = .{ .track = .{ .index = 1, .at = .{ 2, 0.9 } } },
    }};
    const joined = try solve(arena, tJunctionInput(&joins));
    try testing.expectEqual(Status.solved, joined.typical.status);
    try testing.expectApproxEqAbs(@as(f64, 1.0), joined.typical.track_current_a[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.0), joined.typical.track_current_a[1], 1e-9);
}

// spec: placement/power-routing - a junction naming a via whose geometry found fewer than two contacts still creates the barrel hub so the layer jump conducts
test "an explicit junction creates a via hub geometry alone would skip" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // The two traces both stop 0.5 mm short of the 0.2 mm-radius barrel, so
    // the geometric barrel scan finds no contacts at all.
    const segments = [_]Segment{
        .{ .route_index = 0, .a = .{ 0, 0 }, .b = .{ 0.5, 0 }, .layer = 0, .resistance_ohm_per_mm = 0.01, .width_mm = 0.2 },
        .{ .route_index = 1, .a = .{ 1.5, 0 }, .b = .{ 2, 0 }, .layer = 1, .resistance_ohm_per_mm = 0.01, .width_mm = 0.2 },
    };
    const barrels = [_]Barrel{.{ .route_index = 0, .at = .{ 1, 0 }, .resistance_ohm = 0.001, .radius_mm = 0.2 }};
    const loads = [_]Load{.{ .contacts = &.{.{ .at = .{ 2, 0 }, .layer = 1, .reach_mm = 0.01 }}, .typical_a = 1, .maximum_a = null }};
    const joins = [_]Join{
        .{ .a = .{ .track = .{ .index = 0, .at = .{ 0.5, 0 } } }, .b = .{ .via = 0 } },
        .{ .a = .{ .track = .{ .index = 1, .at = .{ 1.5, 0 } } }, .b = .{ .via = 0 } },
    };
    const result = try solve(arena, .{
        .segments = &segments,
        .barrels = &barrels,
        .counts = .{ .tracks = 2, .vias = 1 },
        .source = .{ .contacts = &.{.{ .at = .{ 0, 0 }, .layer = 0, .reach_mm = 0.01 }}, .complete = true },
        .loads = &loads,
        .joins = &joins,
    });
    try testing.expectEqual(Status.solved, result.typical.status);
    try testing.expectApproxEqAbs(@as(f64, 1.0), result.typical.track_current_a[1], 1e-9);
}

// spec: placement/power-routing - a junction naming a barrel enters it through the barrel's own spoke, so the transition's current flows through the plating instead of around it
test "a junction into a barrel does not short the barrel it names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Both traces END on the barrel, so the geometric scan already attached
    // them: the canonical contact policy names the SAME two junctions on top.
    // Tying those to the barrel hub at the ordinary junction resistance put a
    // 1 microohm path in parallel with the plating, and the whole rail flowed
    // around the barrel — 0.7 mA reported in a via carrying 1 A.
    const segments = [_]Segment{
        .{ .route_index = 0, .a = .{ 0, 0 }, .b = .{ 1, 0 }, .layer = 0, .resistance_ohm_per_mm = 0.01, .width_mm = 0.2 },
        .{ .route_index = 1, .a = .{ 1, 0 }, .b = .{ 2, 0 }, .layer = 1, .resistance_ohm_per_mm = 0.01, .width_mm = 0.2 },
    };
    const barrels = [_]Barrel{.{ .route_index = 0, .at = .{ 1, 0 }, .resistance_ohm = 0.002, .radius_mm = 0.2 }};
    const loads = [_]Load{.{ .contacts = &.{.{ .at = .{ 2, 0 }, .layer = 1, .reach_mm = 0.01 }}, .typical_a = 1, .maximum_a = null }};
    const joins = [_]Join{
        .{ .a = .{ .track = .{ .index = 0, .at = .{ 1, 0 } } }, .b = .{ .via = 0 } },
        .{ .a = .{ .track = .{ .index = 1, .at = .{ 1, 0 } } }, .b = .{ .via = 0 } },
    };
    const input: Input = .{
        .segments = &segments,
        .barrels = &barrels,
        .counts = .{ .tracks = 2, .vias = 1 },
        .source = .{ .contacts = &.{.{ .at = .{ 0, 0 }, .layer = 0, .reach_mm = 0.01 }}, .complete = true },
        .loads = &loads,
        .joins = &joins,
    };
    const joined = try solve(arena, input);
    try testing.expectEqual(Status.solved, joined.typical.status);
    try testing.expectApproxEqAbs(@as(f64, 1.0), joined.typical.via_current_a[0], 1e-9);

    // The junctions add nothing the barrel's own land did not already have, so
    // the answer is the geometry-only one to the last bit.
    var bare = input;
    bare.joins = &.{};
    const alone = try solve(arena, bare);
    try testing.expectApproxEqAbs(alone.typical.via_current_a[0], joined.typical.via_current_a[0], 1e-12);
    try testing.expectApproxEqAbs(alone.typical.via_drop_v[0], joined.typical.via_drop_v[0], 1e-12);
}

// spec: placement/power-routing - one unplaceable load leaves the rest of the rail solved and reports the dropped current instead of refusing the axis
test "a load with no terminal leaves the reachable load solved and its current unplaced" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const segments = [_]Segment{
        .{ .route_index = 0, .a = .{ 0, 0 }, .b = .{ 1, 0 }, .layer = 0, .resistance_ohm_per_mm = 0.01 },
        .{ .route_index = 1, .a = .{ 1, 0 }, .b = .{ 2, 1 }, .layer = 0, .resistance_ohm_per_mm = 0.01 },
    };
    const loads = [_]Load{
        .{ .contacts = &.{.{ .at = .{ 2, 1 }, .layer = 0, .reach_mm = 0.01 }}, .typical_a = 0.8, .maximum_a = 1.5 },
        // Annotated but never mapped to pads on this net.
        .{ .contacts = &.{}, .typical_a = 0.2, .maximum_a = 0.4, .complete = false },
    };
    const result = try solve(arena, .{
        .segments = &segments,
        .barrels = &.{},
        .counts = .{ .tracks = 2, .vias = 0 },
        .source = .{ .contacts = &.{.{ .at = .{ 0, 0 }, .layer = 0, .reach_mm = 0.01 }}, .complete = true },
        .loads = &loads,
    });
    try testing.expectEqual(Status.solved_partial, result.typical.status);
    try testing.expect(result.typical.status.isSolved());
    try testing.expect(result.typical.placed[0]);
    try testing.expect(!result.typical.placed[1]);
    try testing.expectApproxEqAbs(@as(f64, 0.2), result.typical.unplaced.typical_a, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.4), result.typical.unplaced.maximum_a, 1e-12);
    // The placed branch still carries exactly its own current, not the rail envelope.
    try testing.expectApproxEqAbs(@as(f64, 0.8), result.typical.track_current_a[0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.8), result.typical.track_current_a[1], 1e-9);
}

// spec: placement/power-routing - a rail whose every annotated load is unplaceable still refuses the axis rather than reporting a partial solve
test "every load unplaceable keeps the refusing statuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const segments = [_]Segment{.{ .route_index = 0, .a = .{ 0, 0 }, .b = .{ 1, 0 }, .layer = 0, .resistance_ohm_per_mm = 0.01 }};
    const base: Input = .{
        .segments = &segments,
        .barrels = &.{},
        .counts = .{ .tracks = 1, .vias = 0 },
        .source = .{ .contacts = &.{.{ .at = .{ 0, 0 }, .layer = 0, .reach_mm = 0.01 }}, .complete = true },
        .loads = &.{},
    };
    var missing = base;
    missing.loads = &[_]Load{.{ .contacts = &.{}, .typical_a = 1, .maximum_a = null, .complete = false }};
    try testing.expectEqual(Status.incomplete_load_terminals, (try solve(arena, missing)).typical.status);

    var island = base;
    island.loads = &[_]Load{.{ .contacts = &.{.{ .at = .{ 9, 9 }, .layer = 0, .reach_mm = 0.01 }}, .typical_a = 1, .maximum_a = null }};
    try testing.expectEqual(Status.incomplete_load_terminals, (try solve(arena, island)).typical.status);

    var no_source = base;
    no_source.source.complete = false;
    no_source.loads = &[_]Load{.{ .contacts = &.{.{ .at = .{ 1, 0 }, .layer = 0, .reach_mm = 0.01 }}, .typical_a = 1, .maximum_a = null }};
    try testing.expectEqual(Status.no_source_terminal, (try solve(arena, no_source)).typical.status);
}

// spec: placement/power-routing - a load on copper the source cannot reach reports disconnected, not a partial solve, when it is the only load
test "an unreachable sole load still reports disconnected" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const segments = [_]Segment{
        .{ .route_index = 0, .a = .{ 0, 0 }, .b = .{ 1, 0 }, .layer = 0, .resistance_ohm_per_mm = 0.01 },
        .{ .route_index = 1, .a = .{ 5, 0 }, .b = .{ 6, 0 }, .layer = 0, .resistance_ohm_per_mm = 0.01 },
    };
    const loads = [_]Load{.{ .contacts = &.{.{ .at = .{ 6, 0 }, .layer = 0, .reach_mm = 0.01 }}, .typical_a = 1, .maximum_a = null }};
    const result = try solve(arena, .{
        .segments = &segments,
        .barrels = &.{},
        .counts = .{ .tracks = 2, .vias = 0 },
        .source = .{ .contacts = &.{.{ .at = .{ 0, 0 }, .layer = 0, .reach_mm = 0.01 }}, .complete = true },
        .loads = &loads,
    });
    try testing.expectEqual(Status.disconnected, result.typical.status);
    try testing.expect(!result.typical.status.isSolved());
}

// spec: placement/power-routing - a net whose copper graph exceeds the node budget reports too-large instead of allocating a dense n-squared matrix
test "a graph over the node budget reports too large" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var segments: [8]Segment = undefined;
    for (&segments, 0..) |*segment, i| {
        const x: f64 = @floatFromInt(i);
        segment.* = .{ .route_index = i, .a = .{ x, 0 }, .b = .{ x + 1, 0 }, .layer = 0, .resistance_ohm_per_mm = 0.01 };
    }
    const loads = [_]Load{.{ .contacts = &.{.{ .at = .{ 8, 0 }, .layer = 0, .reach_mm = 0.01 }}, .typical_a = 1, .maximum_a = null }};
    const input: Input = .{
        .segments = &segments,
        .barrels = &.{},
        .counts = .{ .tracks = 8, .vias = 0 },
        .source = .{ .contacts = &.{.{ .at = .{ 0, 0 }, .layer = 0, .reach_mm = 0.01 }}, .complete = true },
        .loads = &loads,
    };
    try testing.expectEqual(Status.solved, (try solve(arena, input)).typical.status);

    // Nine nodes on eight collinear pieces: a budget of four cannot hold them.
    const result = try solveWithin(arena, input, 4);
    try testing.expectEqual(Status.too_large, result.typical.status);
    try testing.expect(!result.typical.status.isSolved());
}

// spec: placement/power-routing - a net with no annotated current never builds a copper graph at all
test "a currentless net short-circuits before the graph build" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // A node budget of one would overflow instantly if the graph were built.
    const segments = [_]Segment{.{ .route_index = 0, .a = .{ 0, 0 }, .b = .{ 1, 0 }, .layer = 0, .resistance_ohm_per_mm = 0.01 }};
    const loads = [_]Load{.{ .contacts = &.{.{ .at = .{ 1, 0 }, .layer = 0, .reach_mm = 0.01 }}, .typical_a = null, .maximum_a = null }};
    const result = try solveWithin(arena, .{
        .segments = &segments,
        .barrels = &.{},
        .counts = .{ .tracks = 1, .vias = 0 },
        .source = .{ .contacts = &.{.{ .at = .{ 0, 0 }, .layer = 0, .reach_mm = 0.01 }}, .complete = true },
        .loads = &loads,
    }, 1);
    try testing.expectEqual(Status.no_current, result.typical.status);
    try testing.expectEqual(Status.no_current, result.maximum.status);
}

// spec: placement/power-routing - the node spatial hash returns the same node the linear scan did, so a dense same-layer cluster keeps its historical currents
test "the node spatial hash reproduces the linear-scan snap" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // Four collinear pieces whose shared ends sit 0.02 mm apart: every join
    // depends on the half-width snap finding the FIRST matching node.
    const segments = [_]Segment{
        .{ .route_index = 0, .a = .{ 0, 0 }, .b = .{ 1, 0 }, .layer = 0, .resistance_ohm_per_mm = 0.01, .width_mm = 0.3 },
        .{ .route_index = 1, .a = .{ 1.02, 0 }, .b = .{ 2, 0 }, .layer = 0, .resistance_ohm_per_mm = 0.01, .width_mm = 0.3 },
        .{ .route_index = 2, .a = .{ 2.02, 0 }, .b = .{ 3, 0 }, .layer = 0, .resistance_ohm_per_mm = 0.01, .width_mm = 0.3 },
        .{ .route_index = 3, .a = .{ 3.02, 0 }, .b = .{ 4, 0 }, .layer = 0, .resistance_ohm_per_mm = 0.01, .width_mm = 0.3 },
    };
    const loads = [_]Load{.{ .contacts = &.{.{ .at = .{ 4, 0 }, .layer = 0, .reach_mm = 0.01 }}, .typical_a = 2, .maximum_a = null }};
    const result = try solve(arena, .{
        .segments = &segments,
        .barrels = &.{},
        .counts = .{ .tracks = 4, .vias = 0 },
        .source = .{ .contacts = &.{.{ .at = .{ 0, 0 }, .layer = 0, .reach_mm = 0.01 }}, .complete = true },
        .loads = &loads,
    });
    try testing.expectEqual(Status.solved, result.typical.status);
    for (result.typical.track_current_a) |current| try testing.expectApproxEqAbs(@as(f64, 2.0), current, 1e-9);
}
