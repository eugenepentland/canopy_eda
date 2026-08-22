//! Hierarchical autorouting's local phase.
//!
//! Each first-level sub-circuit is routed against a placement view containing
//! only that sub-circuit's parts. The view keeps the board outline and routing
//! rules, but drops every other component and all pre-existing board copper.
//! Its copper is returned in the parent placement's net-index namespace so the
//! caller can validate and freeze it before starting the global route.

const std = @import("std");
const env = @import("../eval/env.zig");
const export_kicad = @import("../export_kicad.zig");
const optimizer = @import("../placement/optimizer.zig");
const drc = @import("../placement/drc.zig");
const route_policy = @import("../placement/route_policy.zig");
const router = @import("../placement/router.zig");
const route_plan = @import("route_plan.zig");

/// One parent-indexed track produced by an isolated sub-circuit pass.
pub const SeedTrack = struct { copper: route_policy.ExistingTrack, net: usize };

/// One parent-indexed via produced by an isolated sub-circuit pass.
pub const SeedVia = struct { copper: route_policy.ExistingVia, net: usize };

/// Copper produced by all isolated sub-circuit passes, plus a parent-net mask
/// identifying which nets should supersede saved module-snapshot seeds.
pub const Result = struct {
    tracks: []const SeedTrack = &.{},
    vias: []const SeedVia = &.{},
    nets: []const bool = &.{},
};

fn memberRef(path: []const u8, ref_des: []const u8) bool {
    return ref_des.len > path.len and std.mem.startsWith(u8, ref_des, path) and ref_des[path.len] == '/';
}

fn enabled(options: route_policy.Options, net: usize) bool {
    return options.selected_nets.len == 0 or
        (net < options.selected_nets.len and options.selected_nets[net]);
}

fn selectedNets(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    path: []const u8,
    base: route_policy.Options,
) std.mem.Allocator.Error![]bool {
    const selected = try alloc.alloc(bool, placement.nets.len);
    @memset(selected, false);
    for (placement.nets, 0..) |net, ni| {
        if (!enabled(base, ni)) continue;
        var local_terminals: usize = 0;
        for (net.pins) |pin| if (memberRef(path, pin.ref_des)) {
            local_terminals += 1;
        };
        // A one-terminal boundary net has nothing to connect inside this
        // sub-circuit. Two or more terminals route locally even when the same
        // parent net continues elsewhere; the global pass joins those islands.
        selected[ni] = local_terminals >= 2;
    }
    return selected;
}

fn anySelected(selected: []const bool) bool {
    for (selected) |yes| if (yes) return true;
    return false;
}

fn localPlacement(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    path: []const u8,
) std.mem.Allocator.Error!?optimizer.Placement {
    const old_to_new = try alloc.alloc(?usize, placement.parts.len);
    @memset(old_to_new, null);

    var parts: std.ArrayList(optimizer.Part) = .empty;
    var instances: std.ArrayList(export_kicad.FlatInstance) = .empty;
    var priority: std.ArrayList(u32) = .empty;
    var minx = std.math.inf(f64);
    var miny = std.math.inf(f64);
    var maxx = -std.math.inf(f64);
    var maxy = -std.math.inf(f64);
    for (placement.parts, 0..) |part, old| {
        if (!memberRef(path, part.ref_des)) continue;
        old_to_new[old] = parts.items.len;
        try parts.append(alloc, part);
        if (old < placement.instances.len) try instances.append(alloc, placement.instances[old]);
        if (placement.priority.len > 0)
            try priority.append(alloc, if (old < placement.priority.len) placement.priority[old] else 0);
        const box = optimizer.worldCourtyard(&part);
        minx = @min(minx, box.minx);
        miny = @min(miny, box.miny);
        maxx = @max(maxx, box.minx + box.w);
        maxy = @max(maxy, box.miny + box.h);
    }
    if (parts.items.len == 0) return null;

    var loops: std.ArrayList(optimizer.Loop) = .empty;
    for (placement.loops) |loop| {
        if (loop.cap >= old_to_new.len or loop.hub >= old_to_new.len) continue;
        const cap = old_to_new[loop.cap] orelse continue;
        const hub = old_to_new[loop.hub] orelse continue;
        var local = loop;
        local.cap = cap;
        local.hub = hub;
        try loops.append(alloc, local);
    }

    var stubs: std.ArrayList(optimizer.Stub) = .empty;
    for (placement.stubs) |stub| {
        if (stub.part >= old_to_new.len) continue;
        const part = old_to_new[stub.part] orelse continue;
        var local = stub;
        local.part = part;
        try stubs.append(alloc, local);
    }

    return .{
        .parts = parts.items,
        .links = &.{},
        .loops = loops.items,
        .stubs = stubs.items,
        .instances = if (instances.items.len == parts.items.len) instances.items else &.{},
        .nets = placement.nets,
        .priority = priority.items,
        .score = placement.score,
        .breakdown = placement.breakdown,
        // A local lattice prevents an isolated module from paying for or
        // wandering through the empty span occupied by the rest of the board.
        .minx = minx,
        .miny = miny,
        .maxx = maxx,
        .maxy = maxy,
        .generated = placement.generated,
        .board_rect = placement.board_rect,
        .board_poly = placement.board_poly,
        .board_arcs = placement.board_arcs,
        .rules = placement.rules,
        .diff_pairs = placement.diff_pairs,
        .match_groups = placement.match_groups,
    };
}

fn selectedGuideTracks(
    alloc: std.mem.Allocator,
    values: []const route_policy.GuideTrack,
    selected: []const bool,
) std.mem.Allocator.Error![]const route_policy.GuideTrack {
    var out: std.ArrayList(route_policy.GuideTrack) = .empty;
    for (values) |value| if (value.net >= 0 and @as(usize, @intCast(value.net)) < selected.len and selected[@intCast(value.net)]) {
        try out.append(alloc, value);
    };
    return out.items;
}

fn selectedGuideVias(
    alloc: std.mem.Allocator,
    values: []const route_policy.GuideVia,
    selected: []const bool,
) std.mem.Allocator.Error![]const route_policy.GuideVia {
    var out: std.ArrayList(route_policy.GuideVia) = .empty;
    for (values) |value| if (value.net >= 0 and @as(usize, @intCast(value.net)) < selected.len and selected[@intCast(value.net)]) {
        try out.append(alloc, value);
    };
    return out.items;
}

fn selectedReserved(
    alloc: std.mem.Allocator,
    values: []const route_policy.ReservedLane,
    selected: []const bool,
) std.mem.Allocator.Error![]const route_policy.ReservedLane {
    var out: std.ArrayList(route_policy.ReservedLane) = .empty;
    for (values) |value| if (value.net >= 0 and @as(usize, @intCast(value.net)) < selected.len and selected[@intCast(value.net)]) {
        try out.append(alloc, value);
    };
    return out.items;
}

fn localOptions(
    alloc: std.mem.Allocator,
    base: route_policy.Options,
    selected: []const bool,
) std.mem.Allocator.Error!route_policy.Options {
    var options = base;
    options.selected_nets = selected;
    // Isolation means no saved track, via, pour, keepout, or foreign reserved
    // lane from the assembled board participates in this phase. Authored policy
    // for the selected nets still applies.
    options.existing_tracks = &.{};
    options.existing_vias = &.{};
    options.existing_zones = &.{};
    options.guides = .{
        .tracks = try selectedGuideTracks(alloc, base.guides.tracks, selected),
        .vias = try selectedGuideVias(alloc, base.guides.vias, selected),
        .reserved = try selectedReserved(alloc, base.guides.reserved, selected),
    };
    // The live stream is reserved for the final assembled-board route. Local
    // passes still share cancellation and timing with their caller.
    options.sink = null;
    return options;
}

/// Route every first-level sub-circuit independently and concatenate its
/// parent-indexed copper. No run sees another sub-circuit's parts or copper.
pub fn routeAll(
    alloc: std.mem.Allocator,
    block: *const env.DesignBlock,
    placement: optimizer.Placement,
    params: router.RouteParams,
    base: route_policy.Options,
) std.mem.Allocator.Error!Result {
    var tracks: std.ArrayList(SeedTrack) = .empty;
    var vias: std.ArrayList(SeedVia) = .empty;
    const nets = try alloc.alloc(bool, placement.nets.len);
    @memset(nets, false);

    for (block.sub_blocks) |sub| {
        if (base.stop.cancel) |cancel| if (cancel.load(.monotonic)) break;
        const selected = try selectedNets(alloc, placement, sub.name, base);
        if (!anySelected(selected)) continue;
        const local = (try localPlacement(alloc, placement, sub.name)) orelse continue;
        const routed = try route_plan.routeLowered(alloc, local, params, try localOptions(alloc, base, selected));
        for (routed.tracks) |track| {
            if (track.net < 0) continue;
            const ni: usize = @intCast(track.net);
            if (ni >= nets.len) continue;
            nets[ni] = true;
            try tracks.append(alloc, .{ .net = ni, .copper = .{
                .x1 = track.x1,
                .y1 = track.y1,
                .x2 = track.x2,
                .y2 = track.y2,
                .layer = track.layer,
                .width = track.width,
                .net = track.net,
            } });
        }
        for (routed.vias) |via| {
            if (via.net < 0) continue;
            const ni: usize = @intCast(via.net);
            if (ni >= nets.len) continue;
            nets[ni] = true;
            try vias.append(alloc, .{ .net = ni, .copper = .{
                .x = via.x,
                .y = via.y,
                .dia = via.dia,
                .drill = via.drill,
                .net = via.net,
            } });
        }
    }
    return .{ .tracks = tracks.items, .vias = vias.items, .nets = nets };
}

/// Whether fixed local copper made the completed global route strictly worse
/// in connectivity or fabrication-blocking geometry than a plain global run.
pub fn regressed(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    params: router.RouteParams,
    seeded: router.RouteResult,
    plain: router.RouteResult,
) std.mem.Allocator.Error!bool {
    if (seeded.routed < plain.routed) return true;
    const seeded_errors = drc.errorCount(try drc.check(alloc, placement, seeded, params.clearance));
    const plain_errors = drc.errorCount(try drc.check(alloc, placement, plain, params.clearance));
    return seeded_errors > plain_errors;
}

const testing = std.testing;

// spec: serve/subcircuit-route - a sub-circuit routing view contains only its own components and uses their local bounds
test "isolated sub-circuit view removes every foreign component" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const pads = [_]@import("../placement/geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.5, .h = 0.5 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "amp/U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "amp/R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads, .fallback = false, .x = 4, .y = 0 },
        .{ .ref_des = "other/U2", .kind = .hub, .hw = 6, .hh = 6, .pads = &pads, .fallback = false, .x = 80, .y = 70 },
    };
    const pins = [_]@import("../export_kicad.zig").FlatPin{
        .{ .ref_des = "amp/U1", .pin = "1" },
        .{ .ref_des = "amp/R1", .pin = "1" },
        .{ .ref_des = "other/U2", .pin = "1" },
    };
    const nets = [_]optimizer.FlatNet{.{ .name = "SHARED", .pins = &pins }};
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
        .maxx = 86,
        .maxy = 76,
        .generated = false,
    };

    const local = (try localPlacement(alloc, placement, "amp")) orelse return error.TestExpectedLocalPlacement;
    try testing.expectEqual(@as(usize, 2), local.parts.len);
    try testing.expectEqualStrings("amp/U1", local.parts[0].ref_des);
    try testing.expect(local.maxx < 10 and local.maxy < 10);
    const selected = try selectedNets(alloc, placement, "amp", .{});
    // Boundary nets route their internal island now; the global pass joins the
    // third terminal after the isolated copper is frozen.
    try testing.expect(selected[0]);

    var child = env.DesignBlock{ .name = "amp", .instances = &.{}, .nets = &.{}, .ports = &.{}, .notes = &.{}, .groups = &.{}, .sub_blocks = &.{} };
    const subs = [_]env.SubBlock{.{ .name = "amp", .block = &child }};
    var board = env.DesignBlock{ .name = "board", .instances = &.{}, .nets = &.{}, .ports = &.{}, .notes = &.{}, .groups = &.{}, .sub_blocks = &subs };
    const routed = try routeAll(alloc, &board, placement, .{}, .{});
    try testing.expect(routed.nets[0]);
    try testing.expect(routed.tracks.len > 0);
}

// spec: serve/subcircuit-route - an unselected scoped net is never routed by a sub-circuit phase
test "isolated sub-circuit selection respects the caller's net scope" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const pins = [_]@import("../export_kicad.zig").FlatPin{
        .{ .ref_des = "amp/U1", .pin = "1" },
        .{ .ref_des = "amp/R1", .pin = "1" },
    };
    const nets = [_]optimizer.FlatNet{.{ .name = "LOCAL", .pins = &pins }};
    const scope = [_]bool{false};
    const placement = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 1,
        .maxy = 1,
        .generated = false,
    };
    const selected = try selectedNets(alloc, placement, "amp", .{ .selected_nets = &scope });
    try testing.expect(!selected[0]);
}
