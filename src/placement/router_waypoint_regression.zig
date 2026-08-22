//! Public waypoint-routing regressions kept outside the size-capped router core.

const std = @import("std");
const router = @import("router.zig");
const optimizer = @import("optimizer.zig");
const flat_netlist = @import("../flat_netlist.zig");
const geometry = @import("geometry.zig");
const route_cleanup = @import("route_cleanup.zig");
const route_policy = @import("route_policy.zig");

const testing = std.testing;

// spec: placement/router - ordered waypoints seed one clearance-aware shared trunk for a multi-terminal net before exact-guide fallback
test "multi-terminal waypoints form one shared guided trunk" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const pads = [_]geometry.Pad{.{
        .number = "1",
        .x = 0,
        .y = 0,
        .w = 0.3,
        .h = 0.3,
    }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "J1", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "U1", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &pads, .fallback = false, .x = 3, .y = -1 },
        .{ .ref_des = "U2", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &pads, .fallback = false, .x = 3, .y = 1 },
    };
    const pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "J1", .pin = "1" },
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "U2", .pin = "1" },
    };
    const nets = [_]flat_netlist.FlatNet{.{ .name = "BUS", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -0.5,
        .miny = -1.5,
        .maxx = 3.5,
        .maxy = 1.5,
        .generated = true,
    };
    const waypoints = [_]route_policy.Waypoint{
        .{ .x = 1, .y = 0, .layer = 0 },
        .{ .x = 2, .y = 0, .layer = 0 },
    };
    const policies = [_]route_policy.NetPolicy{.{ .waypoints = &waypoints }};
    const routed = try router.routeWithOptions(arena, placement, .{}, .{ .net = &policies });
    try testing.expectEqual(@as(usize, 1), routed.routed);
    var touches_first = false;
    var touches_second = false;
    for (routed.tracks) |track| {
        touches_first = touches_first or
            (@abs(track.x1 - 1) < 1e-9 and @abs(track.y1) < 1e-9) or
            (@abs(track.x2 - 1) < 1e-9 and @abs(track.y2) < 1e-9);
        touches_second = touches_second or
            (@abs(track.x1 - 2) < 1e-9 and @abs(track.y1) < 1e-9) or
            (@abs(track.x2 - 2) < 1e-9 and @abs(track.y2) < 1e-9);
    }
    try testing.expect(touches_first);
    try testing.expect(touches_second);
    var parent: []usize = &.{};
    try testing.expectEqual(
        @as(usize, 1),
        try route_cleanup.countCopperIslands(arena, &.{}, routed.tracks, routed.vias, &parent),
    );
}

// spec: placement/router - every leg of a shared guided trunk enters its waypoint chain from the same end, so the trunk is one corridor rather than two opposed ones
test "a shared guided trunk is walked in one direction whichever pad seeds it" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.3, .h = 0.3 }};
    const waypoints = [_]route_policy.Waypoint{
        .{ .x = 1, .y = 0, .layer = 0 },
        .{ .x = 2, .y = 0, .layer = 0 },
    };
    const policies = [_]route_policy.NetPolicy{.{ .waypoints = &waypoints }};

    // `connectOrder` seeds the tree at the CLOSEST PAIR, so the trunk root is
    // whichever two pads sit nearest each other — not the pad the netlist
    // happened to list first. Both arrangements below put the root at a
    // different end of the chain, and each leg's own nearer chain end therefore
    // disagrees with its siblings'. The trunk must still be one corridor.
    const arrangements = [_][3][2]f64{
        // Root on the far side of the chain from the third drop.
        .{ .{ 0, 0 }, .{ 3, -1 }, .{ 3, 1 } },
        // Mirrored: root on the near side.
        .{ .{ 3, 0 }, .{ 0, -1 }, .{ 0, 1 } },
    };
    for (arrangements) |at| {
        var parts = [_]optimizer.Part{
            .{ .ref_des = "J1", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &pads, .fallback = false, .x = at[0][0], .y = at[0][1] },
            .{ .ref_des = "U1", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &pads, .fallback = false, .x = at[1][0], .y = at[1][1] },
            .{ .ref_des = "U2", .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = &pads, .fallback = false, .x = at[2][0], .y = at[2][1] },
        };
        const pins = [_]flat_netlist.FlatPin{
            .{ .ref_des = "J1", .pin = "1" },
            .{ .ref_des = "U1", .pin = "1" },
            .{ .ref_des = "U2", .pin = "1" },
        };
        const nets = [_]flat_netlist.FlatNet{.{ .name = "BUS", .pins = &pins }};
        const placement = optimizer.Placement{
            .parts = &parts,
            .links = &.{},
            .loops = &.{},
            .stubs = &.{},
            .instances = &.{},
            .nets = &nets,
            .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
            .minx = -0.5,
            .miny = -1.5,
            .maxx = 3.5,
            .maxy = 1.5,
            .generated = true,
        };
        const routed = try router.routeWithOptions(arena, placement, .{}, .{ .net = &policies });
        try testing.expectEqual(@as(usize, 1), routed.routed);
        // Exact-guide adherence: a track END lands on each authored point. The
        // grid-snapped maze fallback cannot produce that, so this also proves
        // the tree never fell out of the exact path.
        try testing.expect(endsOnPoint(routed.tracks, 1, 0));
        try testing.expect(endsOnPoint(routed.tracks, 2, 0));
        var parent: []usize = &.{};
        try testing.expectEqual(
            @as(usize, 1),
            try route_cleanup.countCopperIslands(arena, &.{}, routed.tracks, routed.vias, &parent),
        );
    }
}

/// True when some routed track terminates exactly on `(x, y)`.
fn endsOnPoint(tracks: []const router.Track, x: f64, y: f64) bool {
    for (tracks) |track| {
        if (@abs(track.x1 - x) < 1e-9 and @abs(track.y1 - y) < 1e-9) return true;
        if (@abs(track.x2 - x) < 1e-9 and @abs(track.y2 - y) < 1e-9) return true;
    }
    return false;
}
