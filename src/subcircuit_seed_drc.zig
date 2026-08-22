//! Deterministic board-level acceptance gate for hierarchical route seeds.
//!
//! Candidates arrive in authored sub-circuit order. Each net is judged against
//! saved board copper plus all earlier accepted candidates; a collision rejects
//! only the current net, so a later module cannot evict valid copper already
//! frozen by an earlier module.

const std = @import("std");
const optimizer = @import("placement/optimizer.zig");
const route_policy = @import("placement/route_policy.zig");
const router = @import("placement/router.zig");
const drc = @import("placement/drc.zig");
const route_cleanup = @import("placement/route_cleanup.zig");
const geometry = @import("placement/geometry.zig");
const flat_netlist = @import("flat_netlist.zig");

fn routedResult(
    comptime SeedTrack: type,
    comptime SeedVia: type,
    alloc: std.mem.Allocator,
    tracks: []const SeedTrack,
    vias: []const SeedVia,
) std.mem.Allocator.Error!router.RouteResult {
    const rt = try alloc.alloc(router.Track, tracks.len);
    for (tracks, 0..) |item, i| rt[i] = .{
        .x1 = item.copper.x1,
        .y1 = item.copper.y1,
        .x2 = item.copper.x2,
        .y2 = item.copper.y2,
        .layer = item.copper.layer,
        .width = item.copper.width,
        .net = item.copper.net,
    };
    const rv = try alloc.alloc(router.Via, vias.len);
    for (vias, 0..) |item, i| rv[i] = .{
        .x = item.copper.x,
        .y = item.copper.y,
        .dia = item.copper.dia,
        .drill = item.copper.drill,
        .net = item.copper.net,
    };
    return .{ .tracks = rt, .vias = rv, .routed = 0, .total = 0 };
}

fn actionable(v: drc.Violation) bool {
    return v.severity == .err or v.kind == .land_transit or v.kind == .implicit_junction;
}

fn marksFirst(v: drc.Violation) bool {
    return switch (v.kind) {
        .via_pad, .via_via, .via_spacing, .via_track, .track_track, .track_pad, .annular, .min_drill, .track_width, .copper_stub, .implicit_junction, .sharp_bend, .land_transit, .keepout_violation, .perimeter_keepout => true,
        .board_edge, .hole_hole => v.who.part_a < 0,
        else => false,
    };
}

fn marksSecond(v: drc.Violation) bool {
    return switch (v.kind) {
        .via_via, .via_spacing, .via_track, .track_track => true,
        .hole_hole => v.who.part_b < 0,
        else => false,
    };
}

fn markViolation(rejected: []bool, v: drc.Violation) void {
    if (!actionable(v)) return;
    if (marksFirst(v) and v.who.net_a >= 0) {
        const ni: usize = @intCast(v.who.net_a);
        if (ni < rejected.len) rejected[ni] = true;
    }
    if (marksSecond(v) and v.who.net_b >= 0) {
        const ni: usize = @intCast(v.who.net_b);
        if (ni < rejected.len) rejected[ni] = true;
    }
}

fn sameTrack(a: route_policy.ExistingTrack, b: route_policy.ExistingTrack) bool {
    return a.net == b.net and a.layer == b.layer and a.width == b.width and
        a.x1 == b.x1 and a.y1 == b.y1 and a.x2 == b.x2 and a.y2 == b.y2;
}

fn sameVia(a: route_policy.ExistingVia, b: route_policy.ExistingVia) bool {
    return a.net == b.net and a.x == b.x and a.y == b.y and a.dia == b.dia and a.drill == b.drill;
}

fn hasTrack(items: []const route_policy.ExistingTrack, want: route_policy.ExistingTrack) bool {
    for (items) |item| if (sameTrack(item, want)) return true;
    return false;
}

fn hasVia(items: []const route_policy.ExistingVia, want: route_policy.ExistingVia) bool {
    for (items) |item| if (sameVia(item, want)) return true;
    return false;
}

fn candidateViolationCounts(
    alloc: std.mem.Allocator,
    selected: []const bool,
    violations: []const drc.Violation,
) std.mem.Allocator.Error![]usize {
    const counts = try alloc.alloc(usize, selected.len);
    @memset(counts, 0);
    for (violations) |v| {
        if (!actionable(v)) continue;
        if (marksFirst(v) and v.who.net_a >= 0) {
            const ni: usize = @intCast(v.who.net_a);
            if (ni < selected.len and selected[ni]) counts[ni] += 1;
        }
        if (marksSecond(v) and v.who.net_b >= 0) {
            const ni: usize = @intCast(v.who.net_b);
            if (ni < selected.len and selected[ni]) counts[ni] += 1;
        }
    }
    return counts;
}

fn normalizeCandidates(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    clearance: f64,
    input: anytype,
) std.mem.Allocator.Error!void {
    const baseline_result = try routedResult(
        @TypeOf(input.track_list.items[0]),
        @TypeOf(input.via_list.items[0]),
        alloc,
        input.track_list.items,
        input.via_list.items,
    );
    const baseline = try candidateViolationCounts(
        alloc,
        input.candidate,
        try drc.check(alloc, placement, baseline_result, clearance),
    );
    var tracks: std.ArrayList(router.Track) = .empty;
    var mutable: std.ArrayList(bool) = .empty;
    for (input.track_list.items) |item| {
        try tracks.append(alloc, .{
            .x1 = item.copper.x1,
            .y1 = item.copper.y1,
            .x2 = item.copper.x2,
            .y2 = item.copper.y2,
            .layer = item.copper.layer,
            .width = item.copper.width,
            .net = item.copper.net,
        });
        try mutable.append(alloc, true);
    }
    const vias = try alloc.alloc(router.Via, input.via_list.items.len);
    for (input.via_list.items, vias) |item, *via| via.* = .{
        .x = item.copper.x,
        .y = item.copper.y,
        .dia = item.copper.dia,
        .drill = item.copper.drill,
        .net = item.copper.net,
    };
    const pads = try router.buildObstacles(alloc, placement.parts, placement.nets);
    try router.canonicalizeTraceJunctions(alloc, &tracks, &mutable, vias);
    _ = route_cleanup.snapLandTransitEndpoints(pads, &tracks, input.candidate);
    _ = try route_cleanup.reanchorLandTransit(alloc, pads, &tracks, input.candidate);
    mutable.clearRetainingCapacity();
    for (tracks.items) |_| try mutable.append(alloc, true);
    try router.canonicalizeTraceJunctions(alloc, &tracks, &mutable, vias);

    const normalized = try candidateViolationCounts(
        alloc,
        input.candidate,
        try drc.check(alloc, placement, .{ .tracks = tracks.items, .vias = vias, .routed = 0, .total = 0 }, clearance),
    );
    var improved = false;
    for (baseline, normalized) |before, after| {
        if (after > before) return;
        if (after < before) improved = true;
    }
    if (!improved) return;

    input.track_list.clearRetainingCapacity();
    for (tracks.items) |track| try input.track_list.append(alloc, .{ .net = @intCast(track.net), .copper = .{
        .x1 = track.x1,
        .y1 = track.y1,
        .x2 = track.x2,
        .y2 = track.y2,
        .layer = track.layer,
        .width = track.width,
        .net = track.net,
    } });
}

/// Reject invalid candidates in place while preserving every earlier valid net.
pub fn reject(alloc: std.mem.Allocator, input: anytype) std.mem.Allocator.Error!void {
    const placement = input.placement;
    const params = input.params;
    const options = input.options;
    const rejected = input.rejected;
    if (@hasField(@TypeOf(input), "track_list")) try normalizeCandidates(alloc, placement, params.clearance, input);
    const tracks = if (@hasField(@TypeOf(input), "track_list")) input.track_list.items else input.tracks;
    const vias = if (@hasField(@TypeOf(input), "via_list")) input.via_list.items else input.vias;
    const SeedTrack = @typeInfo(@TypeOf(tracks)).pointer.child;
    const SeedVia = @typeInfo(@TypeOf(vias)).pointer.child;
    var accepted_tracks: std.ArrayList(SeedTrack) = .empty;
    var accepted_vias: std.ArrayList(SeedVia) = .empty;
    for (options.existing_tracks) |track| {
        if (track.net < 0) continue;
        try accepted_tracks.append(alloc, .{ .net = @intCast(track.net), .copper = track });
    }
    for (options.existing_vias) |via| {
        if (via.net < 0) continue;
        try accepted_vias.append(alloc, .{ .net = @intCast(via.net), .copper = via });
    }

    var order: std.ArrayList(usize) = .empty;
    const queued = try alloc.alloc(bool, placement.nets.len);
    @memset(queued, false);
    for (tracks) |item| {
        if (item.net >= queued.len or queued[item.net]) continue;
        queued[item.net] = true;
        try order.append(alloc, item.net);
    }
    for (vias) |item| {
        if (item.net >= queued.len or queued[item.net]) continue;
        queued[item.net] = true;
        try order.append(alloc, item.net);
    }

    for (order.items) |ni| {
        if (rejected[ni]) continue;
        const track_mark = accepted_tracks.items.len;
        const via_mark = accepted_vias.items.len;
        for (tracks) |item| if (item.net == ni and !hasTrack(options.existing_tracks, item.copper)) {
            try accepted_tracks.append(alloc, item);
        };
        for (vias) |item| if (item.net == ni and !hasVia(options.existing_vias, item.copper)) {
            try accepted_vias.append(alloc, item);
        };
        const routed = try routedResult(SeedTrack, SeedVia, alloc, accepted_tracks.items, accepted_vias.items);
        const violations = try drc.check(alloc, placement, routed, params.clearance);
        const touched = try alloc.alloc(bool, placement.nets.len);
        @memset(touched, false);
        for (violations) |v| markViolation(touched, v);
        if (!touched[ni]) continue;
        rejected[ni] = true;
        accepted_tracks.shrinkRetainingCapacity(track_mark);
        accepted_vias.shrinkRetainingCapacity(via_mark);
    }
}

// spec: placement/land-transit - a hierarchical route seed carrying a same-net land transit is rejected before the assembled-board router can reuse it
test "hierarchical seeds reject warning-severity own-land transit" {
    var rejected = [_]bool{ false, false };
    markViolation(&rejected, .{
        .x = 0,
        .y = 0,
        .gap = 0,
        .clearance = 0,
        .kind = .land_transit,
        .severity = .warn,
        .who = .{ .net_a = 1 },
    });
    try std.testing.expect(!rejected[0]);
    try std.testing.expect(rejected[1]);
}

// spec: placement/land-transit - A hierarchical route seed is centre-anchored through same-net lands before board acceptance and remains rejected when the normalized copper is not DRC-clean.
test "hierarchical seed normalization centres an own-land crossing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.8 }};
    var parts = [_]optimizer.Part{.{
        .ref_des = "A",
        .kind = .passive,
        .hw = 0.4,
        .hh = 0.5,
        .pads = &pad,
        .fallback = false,
        .x = 0,
        .y = 0,
    }};
    const pins = [_]flat_netlist.FlatPin{.{ .ref_des = "A", .pin = "1" }};
    const nets = [_]flat_netlist.FlatNet{.{ .name = "N", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = -1,
        .maxx = 2,
        .maxy = 1,
        .generated = false,
        .rules = .{ .plane_nets = &.{}, .copper_layers = 2 },
    };
    const TestTrack = struct { copper: route_policy.ExistingTrack, net: usize };
    const TestVia = struct { copper: route_policy.ExistingVia, net: usize };
    var tracks: std.ArrayList(TestTrack) = .empty;
    try tracks.append(alloc, .{ .net = 0, .copper = .{
        .x1 = -1,
        .y1 = 0.3,
        .x2 = 1,
        .y2 = 0.3,
        .layer = 0,
        .width = 0.12,
        .net = 0,
    } });
    var vias: std.ArrayList(TestVia) = .empty;
    const selected = [_]bool{true};
    try normalizeCandidates(alloc, placement, 0.127, .{ .track_list = &tracks, .via_list = &vias, .candidate = &selected });
    const normalized = try routedResult(TestTrack, TestVia, alloc, tracks.items, vias.items);
    const violations = try drc.check(alloc, placement, normalized, 0.127);
    try std.testing.expectEqual(@as(usize, 0), drc.countKind(violations, .land_transit));
}

// spec: Web Server - When two local candidates collide, the earlier DRC-clean net remains frozen and only the later candidate is deferred to the global route
test "ordered seed DRC keeps the earlier crossing candidate" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.5, .h = 0.5 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "A0", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "A1", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 4, .y = 4 },
        .{ .ref_des = "B0", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 0, .y = 4 },
        .{ .ref_des = "B1", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 4, .y = 0 },
    };
    const a_pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "A0", .pin = "1" }, .{ .ref_des = "A1", .pin = "1" } };
    const b_pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "B0", .pin = "1" }, .{ .ref_des = "B1", .pin = "1" } };
    const nets = [_]flat_netlist.FlatNet{ .{ .name = "A", .pins = &a_pins }, .{ .name = "B", .pins = &b_pins } };
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1,
        .miny = -1,
        .maxx = 5,
        .maxy = 5,
        .generated = false,
        .rules = .{ .plane_nets = &.{}, .copper_layers = 2 },
    };
    const TestTrack = struct { copper: route_policy.ExistingTrack, net: usize };
    const TestVia = struct { copper: route_policy.ExistingVia, net: usize };
    const tracks = [_]TestTrack{
        .{ .net = 0, .copper = .{ .x1 = 0, .y1 = 0, .x2 = 4, .y2 = 4, .layer = 0, .width = 0.2, .net = 0 } },
        .{ .net = 1, .copper = .{ .x1 = 0, .y1 = 4, .x2 = 4, .y2 = 0, .layer = 0, .width = 0.2, .net = 1 } },
    };
    const no_vias = [_]TestVia{};
    const track_slice: []const TestTrack = &tracks;
    const via_slice: []const TestVia = &no_vias;
    var rejected = [_]bool{ false, false };
    try reject(alloc, .{
        .placement = placement,
        .params = router.RouteParams{},
        .options = route_policy.Options{},
        .rejected = &rejected,
        .tracks = track_slice,
        .vias = via_slice,
    });
    try std.testing.expect(!rejected[0]);
    try std.testing.expect(rejected[1]);
}
