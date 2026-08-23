//! End-to-end router regression for the plane-carried decoupling loop: a bound
//! bypass cap and the hub pad it decouples come out joined by SURFACE copper
//! with ONE via between them, not by two vias and a detour through the plane.

const std = @import("std");
const router = @import("router.zig");
const optimizer = @import("optimizer.zig");
const flat_netlist = @import("../flat_netlist.zig");
const geometry = @import("geometry.zig");
const route_policy = @import("route_policy.zig");
const bypass_open = @import("bypass_open.zig");
const pin_roles = @import("pin_roles.zig");

const testing = std.testing;

/// Does any of `net`'s copper cross the gap between the two lands, inside the x
/// band both of them contain? Sampling is enough — a segment is straight, so a
/// run through the gap registers on every sample inside it.
fn crossesGap(tracks: []const router.Track, net: i32, gap: [2]f64, band: [2]f64) bool {
    const steps: usize = 200;
    for (tracks) |t| {
        if (t.net != net) continue;
        for (0..steps + 1) |i| {
            const f = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
            const y = t.y1 + f * (t.y2 - t.y1);
            if (y < gap[0] or y > gap[1]) continue;
            const x = t.x1 + f * (t.x2 - t.x1);
            if (x >= band[0] - 1e-6 and x <= band[1] + 1e-6) return true;
        }
    }
    return false;
}

fn viasOn(vias: []const router.Via, net: i32) usize {
    var n: usize = 0;
    for (vias) |v| {
        if (v.net == net) n += 1;
    }
    return n;
}

/// Do the two angled fixture pads share one surface-copper island? Hoisted out
/// of the test body so fixture filtering cannot hide assertions in branches.
fn angledPadsConnected(arena: std.mem.Allocator, routed: router.RouteResult) std.mem.Allocator.Error!bool {
    const pads = [_]router.PadObs{
        .{ .x0 = -0.15, .y0 = -0.425, .x1 = 0.15, .y1 = 0.425, .net = 0, .layer = 0 },
        .{ .x0 = -1.8, .y0 = -0.92, .x1 = -1.2, .y1 = -0.38, .net = 0, .layer = 0 },
    };
    var rail_tracks: std.ArrayList(router.Track) = .empty;
    var rail_vias: std.ArrayList(router.Via) = .empty;
    for (routed.tracks) |t| if (t.net == 0) try rail_tracks.append(arena, t);
    for (routed.vias) |v| if (v.net == 0) try rail_vias.append(arena, v);
    var parent: []usize = &.{};
    _ = try @import("route_cleanup.zig").countCopperIslands(arena, &pads, rail_tracks.items, rail_vias.items, &parent);
    return root(parent, 0) == root(parent, 1);
}

fn root(parent: []const usize, start: usize) usize {
    var at = start;
    while (parent[at] != at) at = parent[at];
    return at;
}

fn firstEvent(events: []const router.RouteEvent, kind: router.RouteEventKind, net: usize) ?usize {
    for (events, 0..) |event, i| {
        if (event.kind == kind and event.net == net) return i;
    }
    return null;
}

/// A QFN edge pad on the rail with its ground neighbour, and a 0402 bypass cap
/// 2 mm below presenting its rail land straight at that pad — the shape every
/// `(decouples "IC" PIN)` binding produces.
const hub_pads = [_]geometry.Pad{
    .{ .number = "1", .x = 0, .y = 0, .w = 0.3, .h = 0.85 },
    .{ .number = "2", .x = 0.5, .y = 0, .w = 0.3, .h = 0.85 },
};
/// A 0402's two lands, presented rail-land-first at the hub: 0.6 mm of bare
/// laminate between them, as the real footprint has (the earlier fixture had
/// them touching, which is geometry no via could legally stand in).
const cap_pads = [_]geometry.Pad{
    .{ .number = "1", .x = 0, .y = -0.5, .w = 0.54, .h = 0.6 },
    .{ .number = "2", .x = 0, .y = 0.5, .w = 0.54, .h = 0.6 },
};
/// The same 0402 turned broadside to the package. Its rail land is offset from
/// the QFN pin in both axes, matching straps-synth-lmx2595's C_VCCDIG → U1.7
/// geometry that the compact land-aware hookup declines.
const side_cap_pads = [_]geometry.Pad{
    .{ .number = "1", .x = 0.5, .y = 0, .w = 0.6, .h = 0.54 },
    .{ .number = "2", .x = -0.5, .y = 0, .w = 0.6, .h = 0.54 },
};
/// A foreign land spanning the whole board in the gap, for the blocked case.
/// It seals every continuous fallback as well as the compact hookup.
const wall_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 6, .h = 0.2 }};

const rail_pins = [_]flat_netlist.FlatPin{
    .{ .ref_des = "U1", .pin = "1" },
    .{ .ref_des = "C1", .pin = "1" },
};
const gnd_pins = [_]flat_netlist.FlatPin{
    .{ .ref_des = "U1", .pin = "2" },
    .{ .ref_des = "C1", .pin = "2" },
};
const sig_pins = [_]flat_netlist.FlatPin{.{ .ref_des = "X1", .pin = "1" }};

const cap_pwr = optimizer.PadRect{ .x = 0, .y = -0.5, .w = 0.54, .h = 0.6 };
const cap_gnd = optimizer.PadRect{ .x = 0, .y = 0.5, .w = 0.54, .h = 0.6 };
const side_cap_pwr = optimizer.PadRect{ .x = 0.5, .y = 0, .w = 0.6, .h = 0.54 };
const side_cap_gnd = optimizer.PadRect{ .x = -0.5, .y = 0, .w = 0.6, .h = 0.54 };
const hub_pwr = optimizer.PadRect{ .x = 0, .y = 0, .w = 0.3, .h = 0.85 };
const hub_gnd = optimizer.PadRect{ .x = 0.5, .y = 0, .w = 0.3, .h = 0.85 };

/// The fixture board. `wall` parks a foreign land in the middle of the gap, so
/// the same pair's run is refused by the ordinary clearance probe; `params`
/// carries the fab geometry (a via too fat to place anywhere is how the
/// stitch-nothing case is built).
fn bench(arena: std.mem.Allocator, wall: bool, angled: bool, params: router.RouteParams) std.mem.Allocator.Error!router.RouteResult {
    const parts = try arena.alloc(optimizer.Part, if (wall) 3 else 2);
    parts[0] = .{ .ref_des = "U1", .kind = .hub, .hw = 0.9, .hh = 0.9, .pads = &hub_pads, .fallback = false, .x = 0, .y = 0 };
    parts[1] = if (angled)
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.9, .hh = 0.5, .pads = &side_cap_pads, .fallback = false, .x = -2, .y = -0.65 }
    else
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.9, .pads = &cap_pads, .fallback = false, .x = 0, .y = 2 };
    if (wall) parts[2] = .{ .ref_des = "X1", .kind = .passive, .hw = 3, .hh = 0.1, .pads = &wall_pads, .fallback = false, .x = 0, .y = 1 };
    const nets = try arena.alloc(flat_netlist.FlatNet, if (wall) 3 else 2);
    nets[0] = .{ .name = "V_3V3", .pins = &rail_pins };
    nets[1] = .{ .name = "GND", .pins = &gnd_pins };
    if (wall) nets[2] = .{ .name = "SIG", .pins = &sig_pins };
    const loops = try arena.alloc(optimizer.Loop, 1);
    loops[0] = .{
        .cap = 1,
        .hub = 0,
        .cap_pwr = if (angled) side_cap_pwr else cap_pwr,
        .cap_gnd = if (angled) side_cap_gnd else cap_gnd,
        .hub_pwr = &.{},
        .hub_pwr_pin = hub_pwr,
        .hub_gnd = &.{},
        .hub_gnd_pin = hub_gnd,
    };
    return router.routeWithOptions(arena, .{
        .parts = parts,
        .links = &.{},
        .loops = loops,
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = -2,
        .maxx = 3,
        .maxy = 4,
        .generated = true,
        // The legacy implicit model with a rail plane on In2 — no `(stackup …)`.
        .rules = .{ .planes = .{ .implicit_rail = "V_3V3" } },
        // A real board edge, so a via has somewhere it may NOT go.
        .board_rect = .{ .minx = -2, .miny = -2, .w = 5, .h = 6 },
    }, params, .{});
}

// spec: placement/plane-stitch - a plane-carried net draws its bound cap's surface run to the hub pad before it stitches, and one via then serves both pads
test "a bound bypass pair is joined on the surface and stitched once" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const routed = try bench(arena_inst.allocator(), false, false, .{});
    // U1 pad 1's land runs y -0.425..0.425, C1 pad 1's 1.2..1.8; both contain
    // x -0.15..0.15. The copper has to cross that gap inside that band.
    try testing.expect(crossesGap(routed.tracks, 0, .{ 0.5, 1.3 }, .{ -0.15, 0.15 }));
    // …and the pair is stitched ONCE: two independent vias is what this replaced.
    try testing.expectEqual(@as(usize, 1), viasOn(routed.vias, 0));
}

// spec: placement/plane-stitch - the shared via of a DRAWN bond stands on the bypass cap's own land centre, so no copper is spent reaching the drop
test "the shared via is centred on the bonded cap's land" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const routed = try bench(arena_inst.allocator(), false, false, .{});
    try testing.expectEqual(@as(usize, 1), viasOn(routed.vias, 0));
    for (routed.vias) |v| {
        if (v.net != 0) continue;
        // C1 sits at (0, 2) and its rail land at (0, -0.5) local ⇒ (0, 1.5).
        try testing.expectApproxEqAbs(@as(f64, 0), v.x, 1e-9);
        try testing.expectApproxEqAbs(@as(f64, 1.5), v.y, 1e-9);
    }
}

// spec: placement/plane-stitch - a bond with every DRC-clean surface path blocked is not drawn, and its pads keep the independent stitch via each of them had
test "a blocked bond keeps both stitch vias" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const routed = try bench(arena_inst.allocator(), true, false, .{});
    try testing.expect(!crossesGap(routed.tracks, 0, .{ 0.5, 1.3 }, .{ -0.15, 0.15 }));
    try testing.expectEqual(@as(usize, 2), viasOn(routed.vias, 0));
}

// spec: placement/plane-stitch - a plane-carried net that reaches its plane nowhere keeps no bond copper, so a pass that stitches nothing leaves the board as it found it
test "a net that cannot be stitched keeps no bond copper" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    // A 4 mm via needs its radius plus clearance from the board edge AND from
    // every foreign pad, and this 5 x 6 mm board with the hub in the middle
    // has no such point — while a 0.15 mm track between the two lands is still
    // legal. The bond is drawn, no via drops, and the copper is rolled back.
    const routed = try bench(arena_inst.allocator(), false, false, .{ .track_width = 0.15, .clearance = 0.2, .via_dia = 4.0, .via_drill = 2.0 });
    try testing.expectEqual(@as(usize, 0), viasOn(routed.vias, 0));
    try testing.expect(!crossesGap(routed.tracks, 0, .{ 0.5, 1.3 }, .{ -0.15, 0.15 }));
}

// spec: placement/plane-stitch - a diagonal bound decoupling leg that the compact land hookup declines falls back to the continuous direct search instead of becoming two unrelated plane drops
test "an angled bound bypass pair stays one surface-connected stitch island" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const routed = try bench(arena, false, true, .{});
    try testing.expectEqual(@as(usize, 1), viasOn(routed.vias, 0));

    // The net-open connectivity model must see the hub pad and cap land on one
    // surface island; a trace merely drawn toward an independent via fails.
    try testing.expect(try angledPadsConnected(arena, routed));
}

// spec: placement/plane-stitch - final fill-blind copper cleanup preserves exact-target bypass surface paths even when a rail plane makes their trace sections connectivity-redundant
// spec: placement/plane-stitch - a same-target capacitor bank extends a far exact-target leg through bounded local cap-to-cap hops while the path-length gate still places another via when needed
// spec: placement/plane-stitch - an HMC-style grounded tie-off ring surface-bonds to the exposed ground pad and adds no per-tie-off barrels while the thermal array and capacitor returns remain
test "two three-cap bypass banks remain surface-connected to their exact IC pins" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const qfn_pads = [_]geometry.Pad{
        .{ .number = "1", .x = -1.55, .y = -0.75, .w = 0.70, .h = 0.30 },
        .{ .number = "2", .x = -1.55, .y = -0.25, .w = 0.70, .h = 0.30 },
        .{ .number = "3", .x = -1.55, .y = 0.25, .w = 0.70, .h = 0.30 },
        .{ .number = "4", .x = -1.55, .y = 0.75, .w = 0.70, .h = 0.30 },
        .{ .number = "5", .x = -0.75, .y = 1.55, .w = 0.30, .h = 0.70 },
        .{ .number = "6", .x = -0.25, .y = 1.55, .w = 0.30, .h = 0.70 },
        .{ .number = "7", .x = 0.25, .y = 1.55, .w = 0.30, .h = 0.70 },
        .{ .number = "8", .x = 0.75, .y = 1.55, .w = 0.30, .h = 0.70 },
        .{ .number = "9", .x = 1.55, .y = 0.75, .w = 0.70, .h = 0.30 },
        .{ .number = "10", .x = 1.55, .y = 0.25, .w = 0.70, .h = 0.30 },
        .{ .number = "11", .x = 1.55, .y = -0.25, .w = 0.70, .h = 0.30 },
        .{ .number = "12", .x = 1.55, .y = -0.75, .w = 0.70, .h = 0.30 },
        .{ .number = "13", .x = 0.75, .y = -1.55, .w = 0.30, .h = 0.70 },
        .{ .number = "14", .x = 0.25, .y = -1.55, .w = 0.30, .h = 0.70 },
        .{ .number = "15", .x = -0.25, .y = -1.55, .w = 0.30, .h = 0.70 },
        .{ .number = "16", .x = -0.75, .y = -1.55, .w = 0.30, .h = 0.70 },
        .{ .number = "17", .x = 0, .y = 0, .w = 1.95, .h = 1.95 },
    };
    const real_0402_pads = [_]geometry.Pad{
        .{ .number = "1", .x = -0.48, .y = 0, .w = 0.56, .h = 0.62, .shape = "roundrect" },
        .{ .number = "2", .x = 0.48, .y = 0, .w = 0.56, .h = 0.62, .shape = "roundrect" },
    };
    const real_0603_pads = [_]geometry.Pad{
        .{ .number = "1", .x = -0.78, .y = 0, .w = 0.90, .h = 0.95, .shape = "roundrect" },
        .{ .number = "2", .x = 0.78, .y = 0, .w = 0.90, .h = 0.95, .shape = "roundrect" },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2.125, .hh = 2.125, .pads = &qfn_pads, .fallback = false },
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.85, .hh = 0.35, .pads = &real_0402_pads, .fallback = false, .x = -0.70, .y = -2.80, .rot = 180 },
        .{ .ref_des = "C2", .kind = .passive, .hw = 0.85, .hh = 0.35, .pads = &real_0402_pads, .fallback = false, .x = -0.70, .y = -3.80, .rot = 180 },
        .{ .ref_des = "C3", .kind = .passive, .hw = 1.25, .hh = 0.55, .pads = &real_0603_pads, .fallback = false, .x = -1.10, .y = -5.00, .rot = 180 },
        .{ .ref_des = "C4", .kind = .passive, .hw = 0.85, .hh = 0.35, .pads = &real_0402_pads, .fallback = false, .x = 1.30, .y = -2.80 },
        .{ .ref_des = "C5", .kind = .passive, .hw = 0.85, .hh = 0.35, .pads = &real_0402_pads, .fallback = false, .x = 1.30, .y = -3.80 },
        .{ .ref_des = "C6", .kind = .passive, .hw = 1.25, .hh = 0.55, .pads = &real_0603_pads, .fallback = false, .x = 1.70, .y = -5.00 },
    };
    const rail_pins_bank = [_]flat_netlist.FlatPin{
        .{ .ref_des = "U1", .pin = "15" },
        .{ .ref_des = "C1", .pin = "1" },
        .{ .ref_des = "C2", .pin = "1" },
        .{ .ref_des = "C3", .pin = "1" },
        .{ .ref_des = "U1", .pin = "13" },
        .{ .ref_des = "C4", .pin = "1" },
        .{ .ref_des = "C5", .pin = "1" },
        .{ .ref_des = "C6", .pin = "1" },
    };
    const ground_pins_bank = [_]flat_netlist.FlatPin{
        .{ .ref_des = "U1", .pin = "14" },
        .{ .ref_des = "U1", .pin = "16" },
        .{ .ref_des = "U1", .pin = "17" },
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "U1", .pin = "2" },
        .{ .ref_des = "U1", .pin = "4" },
        .{ .ref_des = "U1", .pin = "5" },
        .{ .ref_des = "U1", .pin = "6" },
        .{ .ref_des = "U1", .pin = "7" },
        .{ .ref_des = "U1", .pin = "8" },
        .{ .ref_des = "U1", .pin = "9" },
        .{ .ref_des = "U1", .pin = "11" },
        .{ .ref_des = "U1", .pin = "12" },
        .{ .ref_des = "C1", .pin = "2" },
        .{ .ref_des = "C2", .pin = "2" },
        .{ .ref_des = "C3", .pin = "2" },
        .{ .ref_des = "C4", .pin = "2" },
        .{ .ref_des = "C5", .pin = "2" },
        .{ .ref_des = "C6", .pin = "2" },
    };
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "GND", .pins = &ground_pins_bank },
        .{ .name = "VCC", .pins = &rail_pins_bank },
    };
    const cap_power = optimizer.PadRect{ .x = -0.48, .y = 0, .w = 0.56, .h = 0.62 };
    const cap_ground = optimizer.PadRect{ .x = 0.48, .y = 0, .w = 0.56, .h = 0.62 };
    const bulk_power = optimizer.PadRect{ .x = -0.78, .y = 0, .w = 0.90, .h = 0.95 };
    const bulk_ground = optimizer.PadRect{ .x = 0.78, .y = 0, .w = 0.90, .h = 0.95 };
    const pin_15 = optimizer.PadRect{ .x = -0.25, .y = -1.55, .w = 0.30, .h = 0.70 };
    const pin_13 = optimizer.PadRect{ .x = 0.75, .y = -1.55, .w = 0.30, .h = 0.70 };
    const exposed_ground = optimizer.PadRect{ .x = 0, .y = 0, .w = 1.95, .h = 1.95 };
    const loops = [_]optimizer.Loop{
        .{ .cap = 1, .hub = 0, .cap_pwr = cap_power, .cap_gnd = cap_ground, .hub_pwr = &.{}, .hub_pwr_pin = pin_15, .hub_gnd = &.{}, .hub_gnd_pin = exposed_ground, .pwr_net = 1, .explicit_pin = "15" },
        .{ .cap = 2, .hub = 0, .cap_pwr = cap_power, .cap_gnd = cap_ground, .hub_pwr = &.{}, .hub_pwr_pin = pin_15, .hub_gnd = &.{}, .hub_gnd_pin = exposed_ground, .pwr_net = 1, .explicit_pin = "15" },
        .{ .cap = 3, .hub = 0, .cap_pwr = bulk_power, .cap_gnd = bulk_ground, .hub_pwr = &.{}, .hub_pwr_pin = pin_15, .hub_gnd = &.{}, .hub_gnd_pin = exposed_ground, .pwr_net = 1, .explicit_pin = "15" },
        .{ .cap = 4, .hub = 0, .cap_pwr = cap_power, .cap_gnd = cap_ground, .hub_pwr = &.{}, .hub_pwr_pin = pin_13, .hub_gnd = &.{}, .hub_gnd_pin = exposed_ground, .pwr_net = 1, .explicit_pin = "13" },
        .{ .cap = 5, .hub = 0, .cap_pwr = cap_power, .cap_gnd = cap_ground, .hub_pwr = &.{}, .hub_pwr_pin = pin_13, .hub_gnd = &.{}, .hub_gnd_pin = exposed_ground, .pwr_net = 1, .explicit_pin = "13" },
        .{ .cap = 6, .hub = 0, .cap_pwr = bulk_power, .cap_gnd = bulk_ground, .hub_pwr = &.{}, .hub_pwr_pin = pin_13, .hub_gnd = &.{}, .hub_gnd_pin = exposed_ground, .pwr_net = 1, .explicit_pin = "13" },
    };
    var ic_roles = pin_roles.PartRoles{};
    try ic_roles.map.put(arena, "17", .ground);
    const tie_roles = [_]struct { pin: []const u8, class: pin_roles.PinClass }{
        .{ .pin = "1", .class = .strap },
        .{ .pin = "2", .class = .strap },
        .{ .pin = "4", .class = .strap },
        .{ .pin = "5", .class = .strap },
        .{ .pin = "6", .class = .strap },
        .{ .pin = "7", .class = .strap },
        .{ .pin = "8", .class = .strap },
        .{ .pin = "9", .class = .optional_nc },
        .{ .pin = "11", .class = .optional_nc },
        .{ .pin = "12", .class = .optional_nc },
        .{ .pin = "14", .class = .optional_nc },
        .{ .pin = "16", .class = .optional_nc },
    };
    for (tie_roles) |role| try ic_roles.map.put(arena, role.pin, role.class);
    var roles = [_]pin_roles.PartRoles{ ic_roles, .{}, .{}, .{}, .{}, .{}, .{} };
    var placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &loops,
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2.35,
        .miny = -5.15,
        .maxx = 2.95,
        .maxy = 2.125,
        .generated = true,
        .rules = .{ .planes = .{ .implicit_rail = "VCC" } },
        .board_rect = .{ .minx = -2.5, .miny = -5.7, .w = 5.6, .h = 8.0 },
    };
    placement.pin_roles = &roles;
    const selected = [_]bool{ false, true };
    const routed = try router.routeWithOptions(arena, placement, .{
        .track_width = 0.127,
        .clearance = 0.127,
        .via_dia = 0.4,
        .via_drill = 0.2,
    }, .{ .selected_nets = &selected });
    const opens = try bypass_open.check(arena, placement, routed.tracks);
    try testing.expectEqual(@as(usize, 0), opens.len);
    // The isolated router keeps four candidate stitches; the shared outer
    // topology prune proves and removes the two redundant ones before a routed
    // board is returned.
    try testing.expectEqual(@as(usize, 4), viasOn(routed.vias, 1));

    const ground_selected = [_]bool{ true, false };
    const grounded = try router.routeWithOptions(arena, placement, .{
        .track_width = 0.127,
        .clearance = 0.127,
        .via_dia = 0.4,
        .via_drill = 0.2,
    }, .{ .selected_nets = &ground_selected });
    // Nine exposed-pad thermal barrels plus one direct return for each of the
    // six bypass capacitors; none of the seven grounded input straps or five
    // optional lands drills a via.
    try testing.expectEqual(@as(usize, 15), viasOn(grounded.vias, 0));
}

// spec: placement/router - signal nets in an explicit authored route wave claim their copper before plane stitching, while the rest wave still follows the plane pass
test "an authored signal wave routes before plane stitching" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.4, .hh = 0.4, .pads = &pad, .fallback = false, .x = -1, .y = -1 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.4, .hh = 0.4, .pads = &pad, .fallback = false, .x = 1, .y = -1 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.4, .hh = 0.4, .pads = &pad, .fallback = false, .x = -1, .y = 1 },
        .{ .ref_des = "C2", .kind = .passive, .hw = 0.4, .hh = 0.4, .pads = &pad, .fallback = false, .x = 1, .y = 1 },
    };
    const signal_pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "R1", .pin = "1" },
        .{ .ref_des = "R2", .pin = "1" },
    };
    const plane_pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "C1", .pin = "1" },
        .{ .ref_des = "C2", .pin = "1" },
    };
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "VTUNE", .pins = &signal_pins },
        .{ .name = "GND", .pins = &plane_pins },
    };
    const plane_names = [_][]const u8{"GND"};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = -2,
        .maxx = 2,
        .maxy = 2,
        .generated = true,
        .rules = .{ .plane_nets = &plane_names, .copper_layers = 4 },
    };
    const policies = [_]route_policy.NetPolicy{
        .{ .wave = .{ .priority = 2, .before_planes = 1 } },
        .{ .wave = .{ .priority = 1 } },
    };
    const run = try router.routeWithTimeline(arena, placement, .{}, .{ .net = &policies });

    const signal_event = firstEvent(run.timeline, .net_routed, 0);
    const plane_event = firstEvent(run.timeline, .plane_routed, 1);
    try testing.expect(signal_event != null);
    try testing.expect(plane_event != null);
    try testing.expect(signal_event.? < plane_event.?);
}

// spec: placement/router - large and tightly packed exposed-pad thermal arrays reserve their field before authored before-plane signal waves, while preferred-pitch 3x3 arrays and ordinary plane stitching retain their later order
test "a large exposed-pad array reserves before an authored early signal wave" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const thermal_pads = [_]geometry.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 4.6, .h = 4.6 },
        .{ .number = "2", .x = 0, .y = -2.7, .w = 0.3, .h = 0.3 },
        .{ .number = "3", .x = 0, .y = 2.7, .w = 0.3, .h = 0.3 },
    };
    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2.7, .hh = 2.7, .pads = &thermal_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 0, .y = 3.5 },
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = -3.5, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 3.5, .y = 0 },
    };
    const plane_pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "C1", .pin = "1" },
    };
    const signal_pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "R1", .pin = "1" },
        .{ .ref_des = "R2", .pin = "1" },
    };
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "GND", .pins = &plane_pins },
        .{ .name = "SIG", .pins = &signal_pins },
    };
    const plane_names = [_][]const u8{"GND"};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -4,
        .miny = -4,
        .maxx = 4,
        .maxy = 4,
        .generated = true,
        .rules = .{ .plane_nets = &plane_names, .copper_layers = 4 },
    };
    const policies = [_]route_policy.NetPolicy{
        .{},
        .{ .wave = .{ .priority = 2, .before_planes = 1 } },
    };
    const run = try router.routeWithTimeline(arena, placement, .{
        .clearance = 0.127,
        .via_dia = 0.4,
        .via_drill = 0.2,
    }, .{ .net = &policies });

    var under_pad: usize = 0;
    for (run.routed.vias) |via| {
        if (via.net != 0) continue;
        if (@abs(via.x) > 2.3 or @abs(via.y) > 2.3) continue;
        under_pad += 1;
    }
    try testing.expectEqual(@as(usize, 16), under_pad);
}
