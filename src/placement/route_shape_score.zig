//! Deterministic geometric route-shape measurements.
//!
//! Connectivity and DRC remain hard gates. These metrics quantify the visual
//! lattice artifacts that the v1 route score cannot see: direction changes,
//! tiny jogs, non-octilinear segments, and bends whose two arms could be
//! replaced by one clearance-clean chord. This module discovers topology and
//! uses the DRC's reusable track-addition gate for the removable-bend verdict.

const std = @import("std");
const numeric = @import("../numeric.zig");
const optimizer = @import("optimizer.zig");
const drc = @import("drc.zig");
const route_result = @import("route_result.zig");

const Track = route_result.Track;
const nm_per_mm: f64 = 1_000_000;
const direction_epsilon: f64 = 1e-9;

/// Geometry dimensions reported beside connectivity, DRC, and route score.
pub const Metrics = struct {
    bends: usize = 0,
    removable_bends: usize = 0,
    removable_detour_mm: f64 = 0,
    micro_jogs: usize = 0,
    non_octilinear_segments: usize = 0,
    shortest_segment_mm: f64 = 0,
};

const Bend = struct {
    net: i32,
    layer: u8,
    width: f64,
    at: [2]f64,
    a: [2]f64,
    c: [2]f64,
    detour_mm: f64,
};

const Analysis = struct {
    metrics: Metrics,
    bends: []const Bend,
};

const PointKey = struct { x: i64, y: i64, net: i32, layer: u8 };
const Arm = struct { other: [2]f64 = .{ 0, 0 }, track_i: usize = 0 };
const Node = struct {
    degree: u16 = 0,
    arms: [2]Arm = @splat(.{}),
    bend: bool = false,
};

fn key(track: Track, x: f64, y: f64) ?PointKey {
    return .{
        .x = numeric.checkedInt(i64, @round(x * nm_per_mm)) orelse return null,
        .y = numeric.checkedInt(i64, @round(y * nm_per_mm)) orelse return null,
        .net = track.net,
        .layer = track.layer,
    };
}

fn addArm(
    arena: std.mem.Allocator,
    nodes: *std.AutoHashMapUnmanaged(PointKey, Node),
    at: PointKey,
    other: [2]f64,
    track_i: usize,
) std.mem.Allocator.Error!void {
    const gop = try nodes.getOrPut(arena, at);
    if (!gop.found_existing) gop.value_ptr.* = .{};
    const node = gop.value_ptr;
    if (node.degree < 2) node.arms[node.degree] = .{ .other = other, .track_i = track_i };
    node.degree +|= 1;
}

fn isTurn(at: [2]f64, a: [2]f64, c: [2]f64) bool {
    const ax = a[0] - at[0];
    const ay = a[1] - at[1];
    const cx = c[0] - at[0];
    const cy = c[1] - at[1];
    const al = std.math.hypot(ax, ay);
    const cl = std.math.hypot(cx, cy);
    if (al <= direction_epsilon or cl <= direction_epsilon) return false;
    const cross = @abs(ax * cy - ay * cx);
    const dot = ax * cx + ay * cy;
    return cross > direction_epsilon * al * cl or dot >= 0;
}

fn octilinear(track: Track) bool {
    const dx = @abs(track.x2 - track.x1);
    const dy = @abs(track.y2 - track.y1);
    const scale = @max(@max(dx, dy), 1);
    return dx <= direction_epsilon or dy <= direction_epsilon or @abs(dx - dy) <= direction_epsilon * scale;
}

/// Discover bend topology and the shape-only metrics. The removable counters
/// start at zero; the router fills them after probing every `Bend.a -> Bend.c`
/// chord against the finished board.
fn analyze(arena: std.mem.Allocator, tracks: []const Track) std.mem.Allocator.Error!Analysis {
    var nodes = std.AutoHashMapUnmanaged(PointKey, Node).empty;
    defer nodes.deinit(arena);
    var metrics = Metrics{};
    var shortest = std.math.inf(f64);
    for (tracks, 0..) |track, i| {
        const len = std.math.hypot(track.x2 - track.x1, track.y2 - track.y1);
        if (len <= direction_epsilon) continue;
        shortest = @min(shortest, len);
        if (!octilinear(track)) metrics.non_octilinear_segments += 1;
        const first = key(track, track.x1, track.y1) orelse continue;
        const second = key(track, track.x2, track.y2) orelse continue;
        try addArm(arena, &nodes, first, .{ track.x2, track.y2 }, i);
        try addArm(arena, &nodes, second, .{ track.x1, track.y1 }, i);
    }
    metrics.shortest_segment_mm = if (std.math.isFinite(shortest)) shortest else 0;

    var bends: std.ArrayList(Bend) = .empty;
    var it = nodes.iterator();
    while (it.next()) |entry| {
        const node = entry.value_ptr;
        if (node.degree != 2) continue;
        const k = entry.key_ptr.*;
        const at = [2]f64{
            @as(f64, @floatFromInt(k.x)) / nm_per_mm,
            @as(f64, @floatFromInt(k.y)) / nm_per_mm,
        };
        const a = node.arms[0].other;
        const c = node.arms[1].other;
        if (!isTurn(at, a, c)) continue;
        node.bend = true;
        metrics.bends += 1;
        try bends.append(arena, .{
            .net = k.net,
            .layer = k.layer,
            .width = @max(tracks[node.arms[0].track_i].width, tracks[node.arms[1].track_i].width),
            .at = at,
            .a = a,
            .c = c,
            .detour_mm = @max(
                std.math.hypot(a[0] - at[0], a[1] - at[1]) +
                    std.math.hypot(c[0] - at[0], c[1] - at[1]) -
                    std.math.hypot(c[0] - a[0], c[1] - a[1]),
                0,
            ),
        });
    }

    for (tracks) |track| {
        const len = std.math.hypot(track.x2 - track.x1, track.y2 - track.y1);
        if (len > @max(track.width, 0.15) + direction_epsilon) continue;
        const first = nodes.get(key(track, track.x1, track.y1) orelse continue) orelse continue;
        const second = nodes.get(key(track, track.x2, track.y2) orelse continue) orelse continue;
        if (first.bend and second.bend) metrics.micro_jogs += 1;
    }
    return .{ .metrics = metrics, .bends = try bends.toOwnedSlice(arena) };
}

/// Measure a finished route and classify bend shortcuts with the DRC's
/// pairwise pad/track/via/edge clearance rules. Connectivity and the full DRC
/// remain separate hard gates in the benchmark.
pub fn measure(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: route_result.RouteResult,
    clearance: f64,
) std.mem.Allocator.Error!Metrics {
    const analysis = try analyze(arena, routed.tracks);
    var metrics = analysis.metrics;
    const gate = try drc.TrackAdditionGate.build(arena, placement, routed, clearance);
    for (analysis.bends) |bend| {
        if (!gate.clear(.{
            .x1 = bend.a[0],
            .y1 = bend.a[1],
            .x2 = bend.c[0],
            .y2 = bend.c[1],
            .layer = bend.layer,
            .width = bend.width,
            .net = bend.net,
        })) continue;
        metrics.removable_bends += 1;
        metrics.removable_detour_mm += bend.detour_mm;
    }
    return metrics;
}

const testing = std.testing;
const flat_netlist = @import("../flat_netlist.zig");
const test_nets = [_]flat_netlist.FlatNet{.{ .name = "SIG", .pins = &.{} }};

fn fixture() optimizer.Placement {
    return .{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &test_nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 },
        .generated = false,
    };
}

// spec: bench-route - degree-two direction changes are bends and a short segment trapped between two bends is a micro-jog
test "counts bends and a micro jog" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const tracks = [_]Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 1, .y1 = 0, .x2 = 1, .y2 = 0.1, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 1, .y1 = 0.1, .x2 = 2, .y2 = 0.1, .layer = 0, .width = 0.2, .net = 0 },
    };
    const result = try analyze(arena_i.allocator(), &tracks);
    try testing.expectEqual(@as(usize, 2), result.metrics.bends);
    try testing.expectEqual(@as(usize, 1), result.metrics.micro_jogs);
}

// spec: bench-route - collinear track runs do not count as bends
test "ignores a collinear split" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const tracks = [_]Track{
        .{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 1, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
    };
    const result = try analyze(arena_i.allocator(), &tracks);
    try testing.expectEqual(@as(usize, 0), result.metrics.bends);
}

// spec: bench-route - a bend with a core-DRC-clear shortcut is reported as removable
test "DRC-clear shortcut makes a bend removable" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const tracks = [_]Track{
        .{ .x1 = 1, .y1 = 1, .x2 = 2, .y2 = 1, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 2, .y1 = 1, .x2 = 2, .y2 = 2, .layer = 0, .width = 0.2, .net = 0 },
    };
    const result = try measure(arena_i.allocator(), fixture(), .{
        .tracks = &tracks,
        .vias = &.{},
        .routed = 1,
        .total = 1,
    }, 0.2);
    try testing.expectEqual(@as(usize, 1), result.bends);
    try testing.expectEqual(@as(usize, 1), result.removable_bends);
    try testing.expect(result.removable_detour_mm > 0);
}
