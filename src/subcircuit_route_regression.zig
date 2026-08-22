//! End-to-end regressions for deterministic local-then-global routing.

const std = @import("std");
const env = @import("eval/env.zig");
const flat_netlist = @import("flat_netlist.zig");
const geometry = @import("placement/geometry.zig");
const optimizer = @import("placement/optimizer.zig");
const route_policy = @import("placement/route_policy.zig");
const pcb_layout_page = @import("serve/pcb_layout_page.zig");
const subcircuit_route = @import("serve/subcircuit_route.zig");

// spec: Web Server - Accepted local plane drops are immutable same-net sources in the single global pass, so the global plane phase does not duplicate their barrels
test "accepted local plane drops survive the global pass exactly once" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.7, .h = 0.7 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "power/C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "power/U1", .kind = .hub, .hw = 0.5, .hh = 0.5, .pads = &pads, .fallback = false, .x = 4, .y = 0 },
    };
    const pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "power/C1", .pin = "1" },
        .{ .ref_des = "power/U1", .pin = "1" },
    };
    const nets = [_]flat_netlist.FlatNet{.{ .name = "GND", .pins = &pins }};
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
        .maxy = 1,
        .generated = false,
        .rules = .{ .plane_nets = &.{"GND"}, .copper_layers = 4 },
    };
    var child = env.DesignBlock{ .name = "power", .instances = &.{}, .nets = &.{}, .ports = &.{}, .notes = &.{}, .groups = &.{}, .sub_blocks = &.{} };
    const subs = [_]env.SubBlock{.{ .name = "power", .block = &child }};
    var board = env.DesignBlock{ .name = "board", .instances = &.{}, .nets = &.{}, .ports = &.{}, .notes = &.{}, .groups = &.{}, .sub_blocks = &subs };
    const routed = try pcb_layout_page.routeWithSubcircuitSeeds(alloc, "/no/saved/layout", &board, placement, .{}, .{});
    try std.testing.expect(!routed.seeds.fallback);
    try std.testing.expect(routed.seeds.phase.accepted_carrier_drops >= 2);
    try std.testing.expectEqual(routed.seeds.phase.accepted_carrier_drops, routed.result.vias.len);
    for (routed.result.vias, 0..) |via, i| {
        for (routed.result.vias[i + 1 ..]) |other| {
            try std.testing.expect(std.math.hypot(via.x - other.x, via.y - other.y) > 1e-6);
        }
    }
}

test "a retained pour serves only covered supply pads and leaves the net global" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.8, .h = 0.8 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "power/A", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "power/B", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads, .fallback = false, .x = 8, .y = 0 },
    };
    const pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "power/A", .pin = "1" },
        .{ .ref_des = "power/B", .pin = "1" },
    };
    const nets = [_]flat_netlist.FlatNet{.{ .name = "VCC", .pins = &pins }};
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
        .maxx = 9,
        .maxy = 1,
        .generated = false,
        .rules = .{ .plane_nets = &.{}, .copper_layers = 2 },
    };
    var child = env.DesignBlock{ .name = "power", .instances = &.{}, .nets = &.{}, .ports = &.{}, .notes = &.{}, .groups = &.{}, .sub_blocks = &.{} };
    const subs = [_]env.SubBlock{.{ .name = "power", .block = &child }};
    var board = env.DesignBlock{ .name = "board", .instances = &.{}, .nets = &.{}, .ports = &.{}, .notes = &.{}, .groups = &.{}, .sub_blocks = &subs };
    const pour_poly = [_][2]f64{ .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ -1, 1 } };
    const zones = [_]route_policy.ExistingZone{.{ .polygon = &pour_poly, .layer = 1, .net = 0 }};
    var options = route_policy.Options{ .existing_zones = &zones };
    const stats = try pcb_layout_page.addSubcircuitRouteSeeds(alloc, "/no/saved/layout", &board, placement, .{}, &options);
    try std.testing.expectEqual(@as(usize, 1), stats.phase.accepted_carrier_drops);
    try std.testing.expectEqual(@as(usize, 1), options.existing_vias.len);
    try std.testing.expect(options.selected_nets[0]);
    try std.testing.expectEqual(@as(usize, 1), stats.phase.deferred_supply_nets);
}

test "local plane drops preserve an exposed thermal via array" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const hub_pads = [_]geometry.Pad{
        .{ .number = "0", .x = 0, .y = 0, .w = 3.0, .h = 3.0 },
        .{ .number = "1", .x = -2, .y = 0, .w = 0.5, .h = 0.5 },
        .{ .number = "2", .x = 2, .y = 0, .w = 0.5, .h = 0.5 },
    };
    const small_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.7, .h = 0.7 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "power/U1", .kind = .hub, .hw = 2.5, .hh = 2.5, .pads = &hub_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "power/C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &small_pad, .fallback = false, .x = 6, .y = 0 },
    };
    const pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "power/U1", .pin = "0" },
        .{ .ref_des = "power/C1", .pin = "1" },
    };
    const nets = [_]flat_netlist.FlatNet{.{ .name = "GND", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -3,
        .miny = -3,
        .maxx = 7,
        .maxy = 3,
        .generated = false,
        .rules = .{ .plane_nets = &.{"GND"}, .copper_layers = 4 },
    };
    var child = env.DesignBlock{ .name = "power", .instances = &.{}, .nets = &.{}, .ports = &.{}, .notes = &.{}, .groups = &.{}, .sub_blocks = &.{} };
    const subs = [_]env.SubBlock{.{ .name = "power", .block = &child }};
    var board = env.DesignBlock{ .name = "board", .instances = &.{}, .nets = &.{}, .ports = &.{}, .notes = &.{}, .groups = &.{}, .sub_blocks = &subs };
    const local = try subcircuit_route.routeAllClassified(alloc, &board, placement, .{}, .{}, &.{true});
    try std.testing.expect(local.complete_planes[0]);
    try std.testing.expect(local.vias.len >= 4);

    const policies = [_]route_policy.NetPolicy{.{ .max_vias = 1 }};
    var bounded = route_policy.Options{ .net = &policies };
    const stats = try pcb_layout_page.addSubcircuitRouteSeeds(alloc, "/no/saved/layout", &board, placement, .{}, &bounded);
    try std.testing.expectEqual(@as(usize, 1), stats.copper.rejected_nets);
    try std.testing.expectEqual(@as(usize, 0), bounded.existing_vias.len);
    try std.testing.expect(bounded.selected_nets[0]);
    try std.testing.expectEqual(@as(usize, 1), stats.phase.deferred_supply_nets);
}
