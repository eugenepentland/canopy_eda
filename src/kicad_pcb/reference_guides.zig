//! Sparse routing-topology hints recovered from a completed KiCad reference.
//!
//! Path mode exposes hard waypoints or root-to-terminal branches. Every
//! selected net can also expose its reference centerlines and through-vias as
//! soft, non-copper maze costs. Via/corridor modes deliberately stay soft so
//! the native router synthesizes all trace geometry.

const std = @import("std");
const snapshot_mod = @import("snapshot.zig");
const optimizer = @import("../placement/optimizer.zig");
const geometry = @import("../placement/geometry.zig");
const export_kicad = @import("../export_kicad.zig");
const route_policy = @import("../placement/route_policy.zig");
const track_segment = @import("track_segment.zig");

const point_epsilon_mm: f64 = 1e-5;
const terminal_attach_limit_mm: f64 = 2.0;
const long_terminal_leg_mm: f64 = 3.0;

/// Per-net route policies plus counts describing how much reference topology
/// was usable. Policies are index-aligned with `Placement.nets`.
pub const ReferenceGuides = struct {
    policies: []const route_policy.NetPolicy,
    tracks: []const route_policy.GuideTrack,
    vias: []const route_policy.GuideVia,
    guided_nets: usize,
    waypoints: usize,
};

/// Amount of reference geometry exposed to the native router.
pub const Detail = enum {
    /// Only soft reference via sites; trace geometry and transitions are free.
    vias,
    /// Soft reference trace centerlines plus via sites and preferred layers.
    corridor,
    /// Compressed reference path vertices; establishes a replay upper bound.
    path,
};

const Node = struct {
    x: f64,
    y: f64,
    layer: u8,
};

const Edge = struct {
    a: usize,
    b: usize,
    cost: f64,
};

const Graph = struct {
    nodes: std.ArrayList(Node) = .empty,
    edges: std.ArrayList(Edge) = .empty,
};

const Terminal = struct {
    x: f64,
    y: f64,
    layer: u8,
};

/// Recover ordered transitions or topology branches for selected reference
/// nets. An empty `requested` slice considers every net; names ignore case.
pub fn build(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    board: snapshot_mod.Snapshot,
    requested: []const []const u8,
    detail: Detail,
    corridor_tolerance_mm: f64,
) std.mem.Allocator.Error!ReferenceGuides {
    const policies = try arena.alloc(route_policy.NetPolicy, placement.nets.len);
    @memset(policies, .{});
    var tracks: std.ArrayList(route_policy.GuideTrack) = .empty;
    var vias: std.ArrayList(route_policy.GuideVia) = .empty;
    var guided_nets: usize = 0;
    var waypoint_count: usize = 0;
    for (placement.nets, 0..) |net, net_i| {
        if (!selected(requested, net.name) or net.pins.len < 2) continue;
        policies[net_i].replay_reference_copper = detail == .path;
        policies[net_i].preferred_layers = referenceLayerMask(placement.rules, board, net.name);
        const track_mark = tracks.items.len;
        const via_mark = vias.items.len;
        try appendSoftGuides(.{
            .arena = arena,
            .tracks = &tracks,
            .vias = &vias,
            .placement = placement,
            .board = board,
        }, net_i, detail);
        var used = policies[net_i].preferred_layers != 0 or
            tracks.items.len > track_mark or vias.items.len > via_mark;
        if (detail != .path) {
            guided_nets += @intFromBool(used);
            continue;
        }
        if (net.pins.len == 2) {
            const waypoints = try netWaypoints(
                arena,
                placement,
                board,
                net_i,
                detail,
                corridor_tolerance_mm,
            );
            policies[net_i].waypoints = waypoints;
            waypoint_count += waypoints.len;
            used = used or waypoints.len > 0;
        } else {
            const branches = try netBranches(
                arena,
                placement,
                board,
                net_i,
                detail,
                corridor_tolerance_mm,
            );
            policies[net_i].branches = branches;
            for (branches) |branch| waypoint_count += branch.waypoints.len;
            used = used or branches.len > 0;
        }
        guided_nets += @intFromBool(used);
    }
    return .{
        .policies = policies,
        .tracks = tracks.items,
        .vias = vias.items,
        .guided_nets = guided_nets,
        .waypoints = waypoint_count,
    };
}

fn referenceLayerMask(
    rules: optimizer.BoardRules,
    board: snapshot_mod.Snapshot,
    net_name: []const u8,
) u64 {
    var mask: u64 = 0;
    for (board.segments) |item| {
        if (!std.ascii.eqlIgnoreCase(item.net, net_name)) continue;
        const layer = signalLayerIndex(rules, item.layer) orelse continue;
        if (layer < 64) mask |= @as(u64, 1) << @intCast(layer);
    }
    for (board.arcs) |item| {
        if (!std.ascii.eqlIgnoreCase(item.net, net_name)) continue;
        const layer = signalLayerIndex(rules, item.layer) orelse continue;
        if (layer < 64) mask |= @as(u64, 1) << @intCast(layer);
    }
    return mask;
}

const SoftGuideSink = struct {
    arena: std.mem.Allocator,
    tracks: *std.ArrayList(route_policy.GuideTrack),
    vias: *std.ArrayList(route_policy.GuideVia),
    placement: optimizer.Placement,
    board: snapshot_mod.Snapshot,
};

fn appendSoftGuides(sink: SoftGuideSink, net_i: usize, detail: Detail) std.mem.Allocator.Error!void {
    const name = sink.placement.nets[net_i].name;
    const net: i32 = @intCast(net_i);
    if (detail != .vias) {
        for (sink.board.segments) |item| {
            if (!std.ascii.eqlIgnoreCase(item.net, name)) continue;
            const layer = signalLayerIndex(sink.placement.rules, item.layer) orelse continue;
            try sink.tracks.append(sink.arena, track_segment.from(route_policy.GuideTrack, item.start, item.end, item.width, layer, net));
        }
        for (sink.board.arcs) |item| {
            if (!std.ascii.eqlIgnoreCase(item.net, name)) continue;
            const layer = signalLayerIndex(sink.placement.rules, item.layer) orelse continue;
            try sink.tracks.append(sink.arena, track_segment.from(route_policy.GuideTrack, item.start, item.mid, item.width, layer, net));
            try sink.tracks.append(sink.arena, track_segment.from(route_policy.GuideTrack, item.mid, item.end, item.width, layer, net));
        }
    }
    for (sink.board.vias) |item| {
        if (!std.ascii.eqlIgnoreCase(item.net, name) or
            !std.ascii.eqlIgnoreCase(item.kind, "through")) continue;
        try sink.vias.append(sink.arena, .{
            .x = item.at.x,
            .y = item.at.y,
            .net = net,
            .dia = item.size,
            .drill = item.drill,
        });
    }
}

fn selected(requested: []const []const u8, name: []const u8) bool {
    if (requested.len == 0) return true;
    for (requested) |want| if (std.ascii.eqlIgnoreCase(want, name)) return true;
    return false;
}

fn netWaypoints(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    board: snapshot_mod.Snapshot,
    net_i: usize,
    detail: Detail,
    corridor_tolerance_mm: f64,
) std.mem.Allocator.Error![]const route_policy.Waypoint {
    const net = placement.nets[net_i];
    const start = terminalForPin(placement, net.pins[0]) orelse return &.{};
    const goal = terminalForPin(placement, net.pins[1]) orelse return &.{};
    var graph: Graph = .{};
    try addNetCopper(arena, &graph, placement.rules, board, net.name);
    if (graph.nodes.items.len == 0) return &.{};
    const path = try terminalPath(arena, graph, start, goal);
    if (path.len == 0) return &.{};

    var out: std.ArrayList(route_policy.Waypoint) = .empty;
    if (detail == .path) {
        for (path) |node_i| try appendWaypoint(arena, &out, graph.nodes.items[node_i]);
        return out.toOwnedSlice(arena);
    }
    if (detail == .corridor) {
        const span = transitionSpan(graph.nodes.items, path) orelse return &.{};
        try appendSimplifiedPath(
            arena,
            &out,
            graph.nodes.items,
            path[span[0] .. span[1] + 1],
            corridor_tolerance_mm,
        );
        return out.toOwnedSlice(arena);
    }
    for (path[0 .. path.len - 1], path[1..]) |a_i, b_i| {
        const a = graph.nodes.items[a_i];
        const b = graph.nodes.items[b_i];
        if (a.layer == b.layer or !samePoint(a, b)) continue;
        try appendWaypoint(arena, &out, a);
        try appendWaypoint(arena, &out, b);
    }
    return out.toOwnedSlice(arena);
}

fn netBranches(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    board: snapshot_mod.Snapshot,
    net_i: usize,
    detail: Detail,
    corridor_tolerance_mm: f64,
) std.mem.Allocator.Error![]const route_policy.GuideBranch {
    const net = placement.nets[net_i];
    if (net.pins.len < 3) return &.{};
    const root = terminalForPin(placement, net.pins[0]) orelse return &.{};
    var graph: Graph = .{};
    try addNetCopper(arena, &graph, placement.rules, board, net.name);
    if (graph.nodes.items.len == 0) return &.{};
    var branches: std.ArrayList(route_policy.GuideBranch) = .empty;
    for (net.pins[1..]) |pin| {
        const terminal = terminalForPin(placement, pin) orelse return &.{};
        const path = try terminalPath(arena, graph, root, terminal);
        if (path.len == 0) return &.{};
        const points = try branchWaypoints(
            arena,
            graph.nodes.items,
            path,
            detail,
            corridor_tolerance_mm,
        );
        try branches.append(arena, .{ .waypoints = points });
    }
    return branches.toOwnedSlice(arena);
}

fn branchWaypoints(
    arena: std.mem.Allocator,
    nodes: []const Node,
    path: []const usize,
    detail: Detail,
    corridor_tolerance_mm: f64,
) std.mem.Allocator.Error![]const route_policy.Waypoint {
    var out: std.ArrayList(route_policy.Waypoint) = .empty;
    if (detail == .path) {
        for (path) |node_i| try appendWaypoint(arena, &out, nodes[node_i]);
        return out.toOwnedSlice(arena);
    }
    if (detail == .corridor) {
        const span = transitionSpan(nodes, path) orelse return &.{};
        try appendSimplifiedPath(
            arena,
            &out,
            nodes,
            path[span[0] .. span[1] + 1],
            corridor_tolerance_mm,
        );
        return out.toOwnedSlice(arena);
    }
    for (path[0 .. path.len - 1], path[1..]) |a_i, b_i| {
        const a = nodes[a_i];
        const b = nodes[b_i];
        if (a.layer == b.layer or !samePoint(a, b)) continue;
        try appendWaypoint(arena, &out, a);
        try appendWaypoint(arena, &out, b);
    }
    return out.toOwnedSlice(arena);
}

fn appendSimplifiedPath(
    arena: std.mem.Allocator,
    out: *std.ArrayList(route_policy.Waypoint),
    nodes: []const Node,
    path: []const usize,
    tolerance_mm: f64,
) std.mem.Allocator.Error!void {
    if (path.len == 0) return;
    var run_start: usize = 0;
    for (path[1..], 1..) |node_i, i| {
        if (nodes[node_i].layer == nodes[path[i - 1]].layer) continue;
        try appendLayerRun(arena, out, nodes, path[run_start..i], tolerance_mm);
        run_start = i;
    }
    try appendLayerRun(arena, out, nodes, path[run_start..], tolerance_mm);
}

fn appendLayerRun(
    arena: std.mem.Allocator,
    out: *std.ArrayList(route_policy.Waypoint),
    nodes: []const Node,
    path: []const usize,
    tolerance_mm: f64,
) std.mem.Allocator.Error!void {
    if (path.len == 0) return;
    if (path.len <= 2) {
        for (path) |node_i| try appendWaypoint(arena, out, nodes[node_i]);
        return;
    }
    const first = nodes[path[0]];
    const last = nodes[path[path.len - 1]];
    var split: usize = 0;
    var max_distance: f64 = 0;
    for (path[1 .. path.len - 1], 1..) |node_i, i| {
        const distance = pointSegmentDistance(nodes[node_i], first, last);
        if (distance <= max_distance) continue;
        max_distance = distance;
        split = i;
    }
    if (max_distance <= tolerance_mm) {
        try appendWaypoint(arena, out, first);
        try appendWaypoint(arena, out, last);
        return;
    }
    try appendLayerRun(arena, out, nodes, path[0 .. split + 1], tolerance_mm);
    try appendLayerRun(arena, out, nodes, path[split..], tolerance_mm);
}

fn pointSegmentDistance(point: Node, a: Node, b: Node) f64 {
    const dx = b.x - a.x;
    const dy = b.y - a.y;
    const length2 = dx * dx + dy * dy;
    if (length2 <= point_epsilon_mm * point_epsilon_mm)
        return std.math.hypot(point.x - a.x, point.y - a.y);
    const projection = ((point.x - a.x) * dx + (point.y - a.y) * dy) / length2;
    const t = std.math.clamp(projection, 0, 1);
    return std.math.hypot(point.x - (a.x + t * dx), point.y - (a.y + t * dy));
}

fn transitionSpan(nodes: []const Node, path: []const usize) ?[2]usize {
    var first: ?usize = null;
    var last: usize = 0;
    for (path[0 .. path.len - 1], path[1..], 0..) |a_i, b_i, edge_i| {
        const a = nodes[a_i];
        const b = nodes[b_i];
        if (a.layer == b.layer or !samePoint(a, b)) continue;
        if (first == null) first = edge_i;
        last = edge_i + 1;
    }
    if (first) |first_transition| {
        const start = if (pathLength(nodes, path[0 .. first_transition + 1]) > long_terminal_leg_mm)
            0
        else
            first_transition;
        const end = if (pathLength(nodes, path[last..]) > long_terminal_leg_mm)
            path.len - 1
        else
            last;
        return .{ start, end };
    }
    return null;
}

fn pathLength(nodes: []const Node, path: []const usize) f64 {
    if (path.len < 2) return 0;
    var length: f64 = 0;
    for (path[0 .. path.len - 1], path[1..]) |a_i, b_i| {
        const a = nodes[a_i];
        const b = nodes[b_i];
        length += std.math.hypot(b.x - a.x, b.y - a.y);
    }
    return length;
}

fn terminalForPin(placement: optimizer.Placement, pin: export_kicad.FlatPin) ?Terminal {
    for (placement.parts) |part| {
        if (!std.mem.eql(u8, part.ref_des, pin.ref_des)) continue;
        for (part.pads) |pad| {
            if (!std.mem.eql(u8, pad.number, pin.pin)) continue;
            const point = optimizer.worldPadCenter(&part, pad.x, pad.y);
            return .{
                .x = point[0],
                .y = point[1],
                .layer = if (part.side == .bottom) 1 else 0,
            };
        }
    }
    return null;
}

fn addNetCopper(
    arena: std.mem.Allocator,
    graph: *Graph,
    rules: optimizer.BoardRules,
    board: snapshot_mod.Snapshot,
    net_name: []const u8,
) std.mem.Allocator.Error!void {
    for (board.segments) |item| {
        if (!std.ascii.eqlIgnoreCase(item.net, net_name)) continue;
        const layer = signalLayerIndex(rules, item.layer) orelse continue;
        try addTrace(arena, graph, item.start, item.end, layer);
    }
    for (board.arcs) |item| {
        if (!std.ascii.eqlIgnoreCase(item.net, net_name)) continue;
        const layer = signalLayerIndex(rules, item.layer) orelse continue;
        try addTrace(arena, graph, item.start, item.mid, layer);
        try addTrace(arena, graph, item.mid, item.end, layer);
    }
    for (board.vias) |item| {
        if (!std.ascii.eqlIgnoreCase(item.net, net_name)) continue;
        if (!std.ascii.eqlIgnoreCase(item.kind, "through")) continue;
        try addThroughVia(arena, graph, rules.signalLayerCount(), item.at);
    }
}

fn addTrace(
    arena: std.mem.Allocator,
    graph: *Graph,
    a: snapshot_mod.Point,
    b: snapshot_mod.Point,
    layer: u8,
) std.mem.Allocator.Error!void {
    const ai = try nodeIndex(arena, graph, .{ .x = a.x, .y = a.y, .layer = layer });
    const bi = try nodeIndex(arena, graph, .{ .x = b.x, .y = b.y, .layer = layer });
    try graph.edges.append(arena, .{
        .a = ai,
        .b = bi,
        .cost = std.math.hypot(b.x - a.x, b.y - a.y),
    });
}

fn addThroughVia(
    arena: std.mem.Allocator,
    graph: *Graph,
    layer_count: u8,
    at: snapshot_mod.Point,
) std.mem.Allocator.Error!void {
    var layer_nodes: [64]usize = undefined;
    const count = @min(layer_count, layer_nodes.len);
    for (0..count) |layer| {
        layer_nodes[layer] = try nodeIndex(arena, graph, .{
            .x = at.x,
            .y = at.y,
            .layer = @intCast(layer),
        });
    }
    for (0..count) |a| for (a + 1..count) |b| {
        try graph.edges.append(arena, .{ .a = layer_nodes[a], .b = layer_nodes[b], .cost = 0 });
    };
}

fn nodeIndex(arena: std.mem.Allocator, graph: *Graph, want: Node) std.mem.Allocator.Error!usize {
    for (graph.nodes.items, 0..) |node, i| {
        if (node.layer == want.layer and samePoint(node, want)) return i;
    }
    try graph.nodes.append(arena, want);
    return graph.nodes.items.len - 1;
}

fn samePoint(a: Node, b: Node) bool {
    return @abs(a.x - b.x) <= point_epsilon_mm and @abs(a.y - b.y) <= point_epsilon_mm;
}

/// Find the least-cost connected path between any copper nodes close enough to
/// the two terminals. A completed board can contain short dangling segments or
/// several vertices inside a large pad, so selecting the individually closest
/// node at either end can choose a disconnected island even when a valid
/// terminal-to-terminal copper path exists.
fn terminalPath(
    arena: std.mem.Allocator,
    graph: Graph,
    start: Terminal,
    goal: Terminal,
) std.mem.Allocator.Error![]const usize {
    const count = graph.nodes.items.len;
    const distances = try arena.alloc(f64, count);
    const previous = try arena.alloc(usize, count);
    const visited = try arena.alloc(bool, count);
    @memset(distances, std.math.inf(f64));
    @memset(previous, std.math.maxInt(usize));
    @memset(visited, false);
    var start_candidates: usize = 0;
    for (graph.nodes.items, 0..) |node, i| {
        const attach = terminalDistance(node, start) orelse continue;
        distances[i] = attach;
        start_candidates += 1;
    }
    if (start_candidates == 0) return &.{};

    while (true) {
        const current = nearestUnvisited(distances, visited) orelse break;
        visited[current] = true;
        for (graph.edges.items) |edge| {
            const next = if (edge.a == current) edge.b else if (edge.b == current) edge.a else continue;
            if (visited[next]) continue;
            const candidate = distances[current] + edge.cost;
            if (candidate >= distances[next]) continue;
            distances[next] = candidate;
            previous[next] = current;
        }
    }

    var goal_i: ?usize = null;
    var best_cost = std.math.inf(f64);
    for (graph.nodes.items, 0..) |node, i| {
        const attach = terminalDistance(node, goal) orelse continue;
        const cost = distances[i] + attach;
        if (cost < best_cost) {
            best_cost = cost;
            goal_i = i;
        }
    }
    if (goal_i == null or !std.math.isFinite(best_cost)) return &.{};

    var reverse: std.ArrayList(usize) = .empty;
    var current = goal_i.?;
    while (true) {
        try reverse.append(arena, current);
        if (previous[current] == std.math.maxInt(usize)) break;
        current = previous[current];
    }
    const out = try arena.alloc(usize, reverse.items.len);
    for (reverse.items, 0..) |node, i| out[out.len - 1 - i] = node;
    return out;
}

fn terminalDistance(node: Node, terminal: Terminal) ?f64 {
    if (node.layer != terminal.layer) return null;
    const distance = std.math.hypot(node.x - terminal.x, node.y - terminal.y);
    return if (distance <= terminal_attach_limit_mm) distance else null;
}

fn nearestUnvisited(distances: []const f64, visited: []const bool) ?usize {
    var best: ?usize = null;
    var best_distance = std.math.inf(f64);
    for (distances, visited, 0..) |distance, done, i| {
        if (!done and distance < best_distance) {
            best = i;
            best_distance = distance;
        }
    }
    return best;
}

fn appendWaypoint(
    arena: std.mem.Allocator,
    out: *std.ArrayList(route_policy.Waypoint),
    node: Node,
) std.mem.Allocator.Error!void {
    if (out.items.len > 0) {
        const last = out.items[out.items.len - 1];
        if (last.layer == node.layer and
            @abs(last.x - node.x) <= point_epsilon_mm and
            @abs(last.y - node.y) <= point_epsilon_mm) return;
    }
    if (out.items.len >= 2) {
        const before = out.items[out.items.len - 2];
        const last = out.items[out.items.len - 1];
        if (before.layer == last.layer and last.layer == node.layer) {
            const ux = last.x - before.x;
            const uy = last.y - before.y;
            const vx = node.x - last.x;
            const vy = node.y - last.y;
            if (@abs(ux * vy - uy * vx) <= point_epsilon_mm and ux * vx + uy * vy >= 0) {
                out.items[out.items.len - 1] = .{ .x = node.x, .y = node.y, .layer = node.layer };
                return;
            }
        }
    }
    try out.append(arena, .{ .x = node.x, .y = node.y, .layer = node.layer });
}

/// The routable index of a board layer NAME, through the shared layer model.
fn signalLayerIndex(rules: optimizer.BoardRules, name: []const u8) ?u8 {
    return rules.signalIndexOfName(name);
}

test "terminal path ignores closer disconnected copper" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var graph: Graph = .{};
    try graph.nodes.appendSlice(arena, &.{
        .{ .x = 0, .y = 0, .layer = 0 },
        .{ .x = 0.5, .y = 0, .layer = 0 },
        .{ .x = 9.5, .y = 0, .layer = 0 },
        .{ .x = 10, .y = 0, .layer = 0 },
    });
    try graph.edges.append(arena, .{ .a = 1, .b = 2, .cost = 9 });

    const path = try terminalPath(
        arena,
        graph,
        .{ .x = 0, .y = 0, .layer = 0 },
        .{ .x = 10, .y = 0, .layer = 0 },
    );
    try std.testing.expectEqualSlices(usize, &.{ 1, 2 }, path);
}

test "terminal path preserves a shared attachment node" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var graph: Graph = .{};
    try graph.nodes.append(arena, .{ .x = 0.5, .y = 0, .layer = 0 });

    const path = try terminalPath(
        arena,
        graph,
        .{ .x = 0, .y = 0, .layer = 0 },
        .{ .x = 1, .y = 0, .layer = 0 },
    );
    try std.testing.expectEqualSlices(usize, &.{0}, path);
}

test "branch waypoint detail sparsifies a multi-terminal reference path" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const nodes = [_]Node{
        .{ .x = 0, .y = 0, .layer = 0 },
        .{ .x = 1, .y = 0, .layer = 0 },
        .{ .x = 1, .y = 0, .layer = 1 },
        .{ .x = 5, .y = 0, .layer = 1 },
        .{ .x = 5, .y = 2, .layer = 1 },
    };
    const path = [_]usize{ 0, 1, 2, 3, 4 };

    const vias = try branchWaypoints(arena, &nodes, &path, .vias, 0.2);
    try std.testing.expectEqual(@as(usize, 2), vias.len);
    try std.testing.expectEqual(@as(u8, 0), vias[0].layer);
    try std.testing.expectEqual(@as(u8, 1), vias[1].layer);

    const corridor = try branchWaypoints(arena, &nodes, &path, .corridor, 0.2);
    try std.testing.expectEqual(@as(usize, 4), corridor.len);
    try std.testing.expectEqual(@as(f64, 1), corridor[0].x);
    try std.testing.expectEqual(@as(f64, 2), corridor[3].y);

    const full = try branchWaypoints(arena, &nodes, &path, .path, 0.2);
    try std.testing.expectEqual(@as(usize, 5), full.len);

    const near_nodes = [_]Node{
        .{ .x = 0, .y = 0, .layer = 0 },
        .{ .x = 1, .y = 0.1, .layer = 0 },
        .{ .x = 2, .y = 0, .layer = 0 },
    };
    const near_path = [_]usize{ 0, 1, 2 };
    var simplified: std.ArrayList(route_policy.Waypoint) = .empty;
    try appendSimplifiedPath(arena, &simplified, &near_nodes, &near_path, 0.2);
    try std.testing.expectEqual(@as(usize, 2), simplified.items.len);
}

test "reference guide modes recover soft vias and ordered paths" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const a_pads = [_]geometry.Pad{.{
        .number = "1",
        .x = 0,
        .y = 0,
        .w = 0.5,
        .h = 0.5,
    }};
    const b_pads = [_]geometry.Pad{.{
        .number = "1",
        .x = 0,
        .y = 0,
        .w = 0.5,
        .h = 0.5,
    }};
    const parts = [_]optimizer.Part{
        .{
            .ref_des = "J1",
            .kind = .passive,
            .hw = 0.25,
            .hh = 0.25,
            .pads = &a_pads,
            .fallback = false,
            .x = 0,
            .y = 0,
        },
        .{
            .ref_des = "J2",
            .kind = .passive,
            .hw = 0.25,
            .hh = 0.25,
            .pads = &b_pads,
            .fallback = false,
            .x = 4,
            .y = 0,
            .side = .bottom,
        },
    };
    const pins = [_]export_kicad.FlatPin{
        .{ .ref_des = "J1", .pin = "1" },
        .{ .ref_des = "J2", .pin = "1" },
    };
    const nets = [_]export_kicad.FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = @constCast(&parts),
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 4,
        .maxy = 0,
        .generated = false,
        .rules = .{ .copper_layers = 2 },
    };
    const segments = [_]snapshot_mod.Segment{
        .{
            .start = .{ .x = 0, .y = 0 },
            .end = .{ .x = 1, .y = 0 },
            .layer = "F.Cu",
            .net = "SIG",
        },
        .{
            .start = .{ .x = 1, .y = 0 },
            .end = .{ .x = 4, .y = 0 },
            .layer = "B.Cu",
            .net = "SIG",
        },
    };
    const vias = [_]snapshot_mod.Via{.{
        .at = .{ .x = 1, .y = 0 },
        .layers = &.{ "F.Cu", "B.Cu" },
        .net = "SIG",
    }};
    const got = try build(
        arena,
        placement,
        .{ .segments = &segments, .vias = &vias },
        &.{"sig"},
        .vias,
        0.2,
    );
    try std.testing.expectEqual(@as(usize, 1), got.guided_nets);
    try std.testing.expectEqual(@as(usize, 0), got.waypoints);
    try std.testing.expectEqual(@as(usize, 0), got.tracks.len);
    try std.testing.expectEqual(@as(usize, 1), got.vias.len);
    try std.testing.expectEqual(@as(f64, 1), got.vias[0].x);
    try std.testing.expectEqual(@as(usize, 0), got.policies[0].waypoints.len);
    try std.testing.expectEqual(@as(u64, 0b11), got.policies[0].preferred_layers);

    const corridor = try build(
        arena,
        placement,
        .{ .segments = &segments, .vias = &vias },
        &.{"SIG"},
        .corridor,
        0.2,
    );
    try std.testing.expectEqual(@as(usize, 0), corridor.waypoints);
    try std.testing.expectEqual(@as(usize, 2), corridor.tracks.len);
    try std.testing.expectEqual(@as(usize, 1), corridor.vias.len);
    try std.testing.expect(!corridor.policies[0].replay_reference_copper);

    const path = try build(
        arena,
        placement,
        .{ .segments = &segments, .vias = &vias },
        &.{"SIG"},
        .path,
        0.2,
    );
    try std.testing.expectEqual(@as(usize, 3), path.waypoints);
    try std.testing.expect(path.policies[0].replay_reference_copper);
}
