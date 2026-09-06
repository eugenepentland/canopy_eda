//! End-to-end electrical-budget fixtures independent of board-library data.
const std = @import("std");
const pi = @import("power_integrity.zig");
const optimizer = @import("optimizer.zig");
const router = @import("router.zig");
const drc = @import("drc.zig");
const report = @import("drc_power_voltage.zig").report;
const testing = std.testing;
const Pad = @import("geometry.zig").Pad;
const pads = [_]Pad{
    .{ .number = "1", .x = 0, .y = 0, .w = 0.2, .h = 0.2, .thru = true },
    .{ .number = "2", .x = 0, .y = 2, .w = 0.2, .h = 0.2, .thru = true },
};
const parts = [_]optimizer.Part{
    .{ .ref_des = "src/U1", .kind = .hub, .hw = 0.1, .hh = 0.1, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
    .{ .ref_des = "U2", .kind = .hub, .hw = 0.1, .hh = 0.1, .pads = &pads, .fallback = false, .x = 100, .y = 0 },
};
const consumers = [_]@import("../eval/power_budget.zig").RailConsumer{
    .{ .ref_des = "U2", .net = "VDD", .pins = &.{"1"}, .i_typ = 0.05, .i_max = 0.1 },
};
const rails = [_]@import("../eval/power_budget.zig").Rail{.{
    .net = "VDD",
    .source_terminals = &.{"src/VOUT"},
    .load_typ_a = 0.05,
    .load_max_a = 0.1,
    .any_typ_load = true,
    .any_max_load = true,
    .status = .no_source,
    .consumers = &consumers,
}};
const net_rules = [_]optimizer.NetRule{ .{ .voltage_drop = .{ .limit_v = 0.05 } }, .{} };
const nets = [_]optimizer.FlatNet{
    .{ .name = "VDD", .pins = &.{ .{ .ref_des = "src/U1", .pin = "1" }, .{ .ref_des = "U2", .pin = "1" } } },
    .{ .name = "GND", .pins = &.{ .{ .ref_des = "src/U1", .pin = "2" }, .{ .ref_des = "U2", .pin = "2" } } },
};
const base = optimizer.Placement{
    .parts = &.{},
    .links = &.{},
    .loops = &.{},
    .stubs = &.{},
    .instances = &.{},
    .nets = &nets,
    .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
    .minx = -1,
    .miny = -1,
    .maxx = 101,
    .maxy = 3,
    .generated = true,
    .rules = .{ .plane_nets = &.{}, .net = &net_rules, .copper_layers = 2, .physical = .{ .stack = .{ .layers = 2 }, .rails = &rails } },
};
fn fixture(a: std.mem.Allocator) !optimizer.Placement {
    var board = base;
    board.parts = try a.dupe(optimizer.Part, &parts);
    return board;
}

const tracks = [_]router.Track{
    .{ .x1 = 0, .y1 = 0, .x2 = 50, .y2 = 0, .layer = 0, .width = 0.127, .net = 0 },
    .{ .x1 = 50, .y1 = 0, .x2 = 100, .y2 = 0, .layer = 0, .width = 0.127, .net = 0 },
    .{ .x1 = 0, .y1 = 2, .x2 = 100, .y2 = 2, .layer = 1, .width = 0.127, .net = 1 },
};
const routed = router.RouteResult{ .tracks = &tracks, .vias = &.{}, .routed = 2, .total = 2 };

// spec: placement/power-routing - a voltage budget measures the complete maximum-current supply and return path, so individually acceptable series segments can fail together and wider copper can pass
test "voltage budget measures supply plus return and final widened geometry" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const placement = try fixture(a);
    const result = try pi.routedPowerRequirements(a, placement, routed);
    try testing.expectEqual(@as(usize, 1), result.voltage.len);
    const v = result.voltage[0];
    try testing.expectEqualStrings("", v.reason);
    try testing.expect(v.supply_drop_v.? < v.budget.limit_v);
    try testing.expect(v.return_drop_v.? < v.budget.limit_v);
    try testing.expect(v.exceeded());
    const expected = 1.724e-8 * 1000 * 100 / (0.127 * 0.035) * 0.1 * (1 + 0.00393 * 15);
    try testing.expectApproxEqAbs(expected, v.supply_drop_v.?, 1e-5);
    try testing.expectApproxEqAbs(expected, v.return_drop_v.?, 1e-5);
    var findings: std.ArrayList(drc.Violation) = .empty;
    try report(a, &findings, placement, result.voltage);
    try testing.expectEqual(@as(usize, 1), findings.items.len);
    try testing.expectEqual(drc.Kind.power_voltage_drop, findings.items[0].kind);
    var wider = tracks;
    for (&wider) |*track| track.width *= v.scale();
    var new_route = routed;
    new_route.tracks = &wider;
    const repaired = try pi.routedPowerRequirements(a, placement, new_route);
    try testing.expect(!repaired.voltage[0].exceeded());
    try testing.expectEqualStrings("", repaired.voltage[0].reason);
}

// spec: placement/power-routing - missing maximum current, missing source terminals, disconnected return copper and unmodeled sheets produce an unverified voltage budget instead of a pass
test "voltage budget refuses missing inputs and disconnected returns" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const placement = try fixture(a);
    var board = placement;
    var missing = rails;
    missing[0].any_max_load = false;
    board.rules.physical.rails = &missing;
    var result = try pi.routedPowerRequirements(a, board, routed);
    try testing.expectEqualStrings("missing-maximum-load-current", result.voltage[0].reason);
    missing[0].any_typ_load = false;
    result = try pi.routedPowerRequirements(a, board, routed);
    try testing.expectEqualStrings("missing-maximum-load-current", result.voltage[0].reason);
    const unknown_widths = result.tracks;
    // An explicitly zero envelope also leaves unresolved copper unsized;
    // never publish a partially initialized optional width record.
    missing[0].any_max_load = true;
    missing[0].load_max_a = 0;
    result = try pi.routedPowerRequirements(a, board, routed);
    for (result.tracks, unknown_widths) |zero, unknown| {
        try testing.expect(zero == null);
        try testing.expect(unknown == null);
    }
    missing = rails;
    missing[0].source_terminals = &.{"missing/VOUT"};
    result = try pi.routedPowerRequirements(a, board, routed);
    try testing.expectEqualStrings("incomplete-source-terminals", result.voltage[0].reason);
    var broken = routed;
    broken.tracks = tracks[0..2];
    result = try pi.routedPowerRequirements(a, placement, broken);
    try testing.expect(result.voltage[0].return_drop_v == null);
    try testing.expect(result.voltage[0].reason.len > 0);
    var findings: std.ArrayList(drc.Violation) = .empty;
    try report(a, &findings, placement, result.voltage);
    try testing.expectEqual(drc.Kind.power_voltage_unverified, findings.items[0].kind);
    const zones = [_]@import("pour.zig").UserZone{.{
        .net = "GND",
        .layer = 1,
        .poly = &.{ .{ -0.5, 1 }, .{ 100.5, 1 }, .{ 100.5, 2.5 }, .{ -0.5, 2.5 } },
    }};
    result = try pi.routedPowerRequirementsMemoZones(a, placement, routed, null, &zones);
    try testing.expectEqualStrings("return-sheet-resistance-unmodeled", result.voltage[0].reason);
    // An unknown return does not erase the independently solved supply loss.
    try testing.expect(result.voltage[0].supply_drop_v != null);
}

// spec: placement/power-routing - voltage loss uses the actual foil on each routed layer and refuses shared returns whose other rail currents were not modeled
test "voltage budget uses physical foil and refuses a shared return" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const placement = try fixture(a);
    var board = placement;
    board.rules.physical.stack.foils = &.{ .{ .index = 1, .thickness_mm = 0.035 }, .{ .index = 2, .thickness_mm = 0.0175 } };
    var result = try pi.routedPowerRequirements(a, board, routed);
    try testing.expectApproxEqAbs(result.voltage[0].supply_drop_v.? * 2, result.voltage[0].return_drop_v.?, 1e-5);
    var shared = [_]@import("../eval/power_budget.zig").Rail{ rails[0], rails[0] };
    shared[1].net = "OTHER";
    board.rules.physical.rails = &shared;
    result = try pi.routedPowerRequirements(a, board, routed);
    try testing.expectEqualStrings("shared-return-current-unmodeled", result.voltage[0].reason);
}

// spec: placement/power-routing - the voltage budget scales copper resistance to its declared conductor temperature without taking credit for cold copper
test "voltage budget accounts for hot copper" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var placement = try fixture(a);
    var rules = net_rules;
    rules[0].voltage_drop.copper_temperature_c = 95;
    placement.rules.net = &rules;
    const hot = try pi.routedPowerRequirements(a, placement, routed);
    rules[0].voltage_drop.copper_temperature_c = 20;
    const room = try pi.routedPowerRequirements(a, placement, routed);
    try testing.expectApproxEqAbs(room.voltage[0].knownDrop() * 1.29475, hot.voltage[0].knownDrop(), 1e-8);
    rules[0].voltage_drop.copper_temperature_c = -20;
    const cold = try pi.routedPowerRequirements(a, placement, routed);
    try testing.expectApproxEqAbs(room.voltage[0].knownDrop(), cold.voltage[0].knownDrop(), 1e-8);
}

// spec: placement/power-routing - the autorouter widens a thermally adequate supply and return loop until the final copper meets its voltage budget
test "voltage budget drives the actual autorouter finisher" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var placement = try fixture(a);
    var rules = net_rules;
    rules[0].width = 0.127;
    rules[1].width = 0.127;
    placement.rules.net = &rules;
    placement.rules.design.track_width = 0.127;
    const result = try router.route(a, placement, .{ .track_width = 0.127 });
    try testing.expectEqual(result.total, result.routed);
    const measured = try pi.routedPowerRequirements(a, placement, result);
    try testing.expectEqual(@as(usize, 1), measured.voltage.len);
    try testing.expectEqualStrings("", measured.voltage[0].reason);
    try testing.expect(!measured.voltage[0].exceeded());
    var widest: f64 = 0;
    for (result.tracks) |track| widest = @max(widest, track.width);
    try testing.expect(widest > 0.128);
}
