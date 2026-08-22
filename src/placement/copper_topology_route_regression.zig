//! End-to-end router regression for topology-artifact cleanup.

const std = @import("std");
const router = @import("router.zig");
const optimizer = @import("optimizer.zig");
const route_policy = @import("route_policy.zig");
const flat_netlist = @import("../flat_netlist.zig");
const geometry = @import("geometry.zig");

// spec: placement/router - finished autorouter copper removes dangling trace leaves and vias used on fewer than two layers
test "finished route prunes seeded stubs and one-layer vias" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.5, .h = 0.5 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pads, .fallback = false, .x = 4, .y = 0 },
    };
    const pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const nets = [_]flat_netlist.FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -0.5,
        .miny = -0.5,
        .maxx = 4.5,
        .maxy = 2,
        .generated = true,
        .rules = .{ .plane_nets = &.{}, .copper_layers = 2 },
    };
    const selected = [_]bool{true};
    const tracks = [_]route_policy.ExistingTrack{
        .{ .x1 = 0, .y1 = 0, .x2 = 4, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 2, .y1 = 0, .x2 = 2, .y2 = 1.5, .layer = 0, .width = 0.2, .net = 0 },
    };
    const vias = [_]route_policy.ExistingVia{.{ .x = 3, .y = 0, .dia = 0.4, .drill = 0.2, .net = 0 }};
    const routed = try router.routeWithOptions(arena, placement, .{}, .{
        .selected_nets = &selected,
        .existing_tracks = &tracks,
        .existing_vias = &vias,
    });
    try std.testing.expectEqual(@as(usize, 0), routed.vias.len);
    for (routed.tracks) |track| {
        try std.testing.expect(std.math.hypot(track.x1 - 2, track.y1 - 1.5) > 1e-6);
        try std.testing.expect(std.math.hypot(track.x2 - 2, track.y2 - 1.5) > 1e-6);
    }
}

// spec: placement/router - removes a single-pin breakout's unfinished stub and one-layer via from finished copper
test "finished route removes a single-pin breakout artifact" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 0.6, .hh = 0.6, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
    };
    const pins = [_]flat_netlist.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
    const nets = [_]flat_netlist.FlatNet{.{ .name = "EN", .pins = &pins }};
    const stubs = [_]optimizer.Stub{.{ .part = 0, .ax = 0, .ay = 0, .bx = 2, .by = 0, .net = 0 }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &stubs,
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1,
        .miny = -1,
        .maxx = 3,
        .maxy = 1,
        .generated = true,
    };

    const routed = try router.route(arena, placement, .{});
    try std.testing.expectEqual(@as(usize, 0), routed.vias.len);
    try std.testing.expectEqual(@as(usize, 0), routed.tracks.len);
    const violations = try @import("drc.zig").check(arena, placement, routed, 0.127);
    try std.testing.expectEqual(@as(usize, 0), violations.len);
}

// spec: placement/router - final cleanup removes an unfinished escape stub without disturbing routed foreign copper
test "finished route removes an escape stub beside routed copper" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 0.6, .hh = 0.6, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 0.5, .y = -3 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 0.5, .y = 3 },
    };
    const en_pins = [_]flat_netlist.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
    const sig_pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const nets = [_]flat_netlist.FlatNet{ .{ .name = "EN", .pins = &en_pins }, .{ .name = "SIG", .pins = &sig_pins } };
    const stubs = [_]optimizer.Stub{.{ .part = 0, .ax = 0, .ay = 0, .bx = 2, .by = 0, .net = 0 }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &stubs,
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = -3.5,
        .maxx = 3,
        .maxy = 3.5,
        .generated = true,
    };
    const routed = try router.route(arena, placement, .{});

    var saw_sig = false;
    for (routed.tracks) |track| {
        try std.testing.expect(track.net != 0);
        if (track.net == 1) saw_sig = true;
    }
    try std.testing.expect(saw_sig);
}

// spec: placement/router - a finished route offered two paths between the same lands keeps one of them and reports no dangling copper
test "finished route removes a seeded parallel path and reports no dangling copper" {
    var arena_inst = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.5, .h = 0.5 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pads, .fallback = false, .x = 4, .y = 0 },
    };
    const pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const nets = [_]flat_netlist.FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -0.5,
        .miny = -0.5,
        .maxx = 4.5,
        .maxy = 2.5,
        .generated = true,
        .rules = .{ .plane_nets = &.{}, .copper_layers = 2 },
    };
    const selected = [_]bool{true};
    // A direct pad-to-pad run AND a two-section detour between the same two
    // lands. Every end lands on same-net copper, so the leaf reading finds
    // nothing loose and the finish used to hand this straight to DRC as two
    // `dangling_copper` warnings.
    const tracks = [_]route_policy.ExistingTrack{
        .{ .x1 = 0, .y1 = 0, .x2 = 4, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 1.5, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 2, .y1 = 1.5, .x2 = 4, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 },
    };
    const routed = try router.routeWithOptions(arena, placement, .{}, .{
        .selected_nets = &selected,
        .existing_tracks = &tracks,
    });
    const drc = @import("drc.zig");
    const violations = try drc.check(arena, placement, routed, 0.127);
    try std.testing.expectEqual(@as(usize, 0), drc.countKind(violations, .dangling_copper));
    // The net keeps exactly one path: no loose end appears where the deleted
    // detour used to hang, and the surviving copper still spans both lands.
    try std.testing.expectEqual(@as(usize, 0), drc.countKind(violations, .copper_stub));
    var length: f64 = 0;
    for (routed.tracks) |track| length += std.math.hypot(track.x2 - track.x1, track.y2 - track.y1);
    try std.testing.expect(length >= 3.9);
    try std.testing.expect(length < 6);
}
