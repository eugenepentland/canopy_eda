//! Whole-board router determinism regression (`docs/archive/autorouter-audit-round-two.md` §3f).
//!
//! The router uses no RNG and is deterministic today, but it is *adjacent* to
//! nondeterminism: a few `AutoHashMap` iteration sites ride in the routing
//! paths and `optimizer.zig` already carries thread-local mutable statics for
//! background solves. This module pins the claim "routing the same placement
//! twice is byte-identical" as a fact a regression test enforces, on a fixture
//! that exercises the maze, the direct synthesis, the rip ladder and the
//! finisher (same-layer 45° jog + cross-face via hops + a 3-terminal tree).
//!
//! Kept out of `router.zig` deliberately: that file is already past Guardian's
//! code-line hard cap, so a new test belongs in a small module of its own (the
//! monolith-decomposition point of the same audit).

const std = @import("std");
const router = @import("router.zig");
const optimizer = @import("optimizer.zig");
const flat_netlist = @import("../flat_netlist.zig");
const geometry = @import("geometry.zig");
const octilinear = @import("octilinear.zig");
const pad_escape = @import("pad_escape.zig");

const testing = std.testing;

/// Compare two full route outputs copper-for-copper. All loops live HERE so a
/// test body stays linear (Guardian's `test-no-conditional` rule).
fn expectCopperIdentical(a: router.RouteResult, b: router.RouteResult) !void {
    try testing.expectEqual(a.routed, b.routed);
    try testing.expectEqual(a.total, b.total);
    try testing.expectEqual(a.tracks.len, b.tracks.len);
    try testing.expectEqual(a.vias.len, b.vias.len);
    for (a.tracks, b.tracks) |x, y| {
        try testing.expectApproxEqAbs(x.x1, y.x1, 1e-9);
        try testing.expectApproxEqAbs(x.y1, y.y1, 1e-9);
        try testing.expectApproxEqAbs(x.x2, y.x2, 1e-9);
        try testing.expectApproxEqAbs(x.y2, y.y2, 1e-9);
        try testing.expectEqual(x.layer, y.layer);
        try testing.expectApproxEqAbs(x.width, y.width, 1e-9);
        try testing.expectEqual(x.net, y.net);
    }
    for (a.vias, b.vias) |x, y| {
        try testing.expectApproxEqAbs(x.x, y.x, 1e-9);
        try testing.expectApproxEqAbs(x.y, y.y, 1e-9);
        try testing.expectApproxEqAbs(x.dia, y.dia, 1e-9);
        try testing.expectApproxEqAbs(x.drill, y.drill, 1e-9);
        try testing.expectEqual(x.net, y.net);
    }
}

/// Assert the copper terminating on the pad `half`-sized about `center` obeys
/// the pad-escape rule: the track endpoint sits on the pad's own CENTRE, and
/// the segment leaving it is on a 45° compass heading and runs straight until
/// it is `pad_escape.pad_escape_clear_mm` past the land's edge ON THAT HEADING
/// (see `placement/pad_escape`).
///
/// The heading is any of the eight, not just the axis: which one a pad leaves
/// on is chosen for the connection it draws, so a terminal whose partner lies
/// diagonally away leaves diagonally — that is the whole point of the choice.
/// What is asserted is the rule itself, which is heading-agnostic, plus the one
/// directional property the choice preserves: the fan spans ±90° of the way the
/// route already left, so an escape may run perpendicular to `outward_x` but
/// never BACK past the pad.
fn expectPadEscape(
    tracks: []const router.Track,
    center: [2]f64,
    half: [2]f64,
    outward_x: f64,
) !void {
    var saw = false;
    for (tracks) |track| {
        var end: ?[2]f64 = null;
        var out: [2]f64 = .{ 0, 0 };
        if (onPad(track.x1, track.y1, center, half)) {
            end = .{ track.x1, track.y1 };
            out = .{ track.x2, track.y2 };
        }
        if (onPad(track.x2, track.y2, center, half)) {
            end = .{ track.x2, track.y2 };
            out = .{ track.x1, track.y1 };
        }
        const at = end orelse continue;
        saw = true;
        try testing.expectApproxEqAbs(center[0], at[0], 1e-9); // at the pad's own centre
        try testing.expectApproxEqAbs(center[1], at[1], 1e-9);
        try testing.expect(octilinear.isOctilinear(at, out));
        try testing.expect((out[0] - at[0]) * outward_x >= -1e-9);
        try testing.expect(runLength(at, out) + 1e-9 >= escapeReach(half, at, out));
    }
    try testing.expect(saw);
}

fn runLength(at: [2]f64, out: [2]f64) f64 {
    return std.math.hypot(out[0] - at[0], out[1] - at[1]);
}

/// How far the escape must run from the centre of a `half`-sized land on the
/// heading `at`→`out`: out to the box edge on that heading, plus the clearance
/// (`pad_escape.escapeReach`'s own arithmetic, restated for the assertion).
fn escapeReach(half: [2]f64, at: [2]f64, out: [2]f64) f64 {
    const len = runLength(at, out);
    const ux = @abs(out[0] - at[0]) / len;
    const uy = @abs(out[1] - at[1]) / len;
    var reach = std.math.inf(f64);
    if (ux > 1e-9) reach = @min(reach, half[0] / ux);
    if (uy > 1e-9) reach = @min(reach, half[1] / uy);
    return reach + pad_escape.pad_escape_clear_mm;
}

fn onPad(x: f64, y: f64, center: [2]f64, half: [2]f64) bool {
    return @abs(x - center[0]) <= half[0] + 1e-9 and @abs(y - center[1]) <= half[1] + 1e-9;
}

// spec: placement/router - routing the same placement twice is byte-identical
test "routing the same placement twice is byte-identical" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // A mixed corpus in miniature: a same-layer hop with a 45° jog, two
    // cross-face hops that must take vias, and a 4-terminal tree — exercising
    // the maze, the direct synthesis, the rip ladder and the finisher together.
    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 4, .y = 1.5 },
        .{ .ref_des = "R3", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 3, .y = 0, .side = .bottom },
        .{ .ref_des = "R4", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 7, .y = 0, .side = .bottom },
        .{ .ref_des = "R5", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 1, .y = 3.5 },
        .{ .ref_des = "R6", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 5.5, .y = 3.9 },
        .{ .ref_des = "R7", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 2.5, .y = 5.5, .side = .bottom },
        .{ .ref_des = "R8", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pad, .fallback = false, .x = 8, .y = 5.0 },
    };
    const pins_sig = [_]flat_netlist.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };
    const pins_x = [_]flat_netlist.FlatPin{ .{ .ref_des = "R3", .pin = "1" }, .{ .ref_des = "R4", .pin = "1" } };
    const pins_tree = [_]flat_netlist.FlatPin{
        .{ .ref_des = "R5", .pin = "1" },
        .{ .ref_des = "R6", .pin = "1" },
        .{ .ref_des = "R7", .pin = "1" },
        .{ .ref_des = "R8", .pin = "1" },
    };
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "SIG", .pins = &pins_sig },
        .{ .name = "X", .pins = &pins_x },
        .{ .name = "TREE", .pins = &pins_tree },
    };
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
        .maxy = 6,
        .generated = true,
    };

    const run1 = try router.route(arena, placement, .{});
    const run2 = try router.route(arena, placement, .{});
    try expectCopperIdentical(run1, run2);
    // The fixture must actually exercise the engine rather than route nothing:
    // at least one net routed and the cross-layer hops prove vias were taken,
    // so the copper-for-copper comparison above is not trivially vacuous. We do
    // NOT require every net to connect (routed == total) — the determinism
    // guarantee is about identical input → identical output, and a tree that
    // does not fully close would still be deterministic.
    try testing.expect(run1.routed >= 1);
    try testing.expect(run1.vias.len >= 1);
    try testing.expect(run1.tracks.len > 5);
}

// spec: placement/router - routed copper stays on the octilinear headings when the pad span is off-axis
test "an off-axis pad span still routes as H/V/45 copper" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 4, .y = 0.19 },
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
        .minx = -1,
        .miny = -1,
        .maxx = 5,
        .maxy = 1.5,
        .generated = true,
    };
    const routed = try router.route(arena, placement, .{});
    try testing.expectEqual(@as(usize, 1), routed.routed);
    try testing.expect(routed.tracks.len > 0);
    for (routed.tracks) |track|
        try testing.expect(octilinear.isOctilinear(.{ track.x1, track.y1 }, .{ track.x2, track.y2 }));
}

// spec: placement/router - ordinary QFN pads enter and exit at the pad centre on a 45 degree heading that never points back past the land, straight until they are clear of it
test "QFN terminals leave the pad centre on a forward compass heading" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const qfn_pad = [_]geometry.Pad{.{ .number = "1", .x = -1, .y = 0, .w = 0.6, .h = 0.25 }};
    const target_pad = [_]geometry.Pad{.{ .number = "1", .x = 0.4, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1.2, .hh = 1.2, .pads = &qfn_pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.6, .hh = 0.3, .pads = &target_pad, .fallback = false, .x = -4.4, .y = 1 },
    };
    const pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "R1", .pin = "1" } };
    const nets = [_]flat_netlist.FlatNet{.{ .name = "SIG", .pins = &pins }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -5.2,
        .miny = -1.5,
        .maxx = 1.5,
        .maxy = 2,
        .generated = true,
    };
    const routed = try router.route(arena, placement, .{});
    try testing.expectEqual(@as(usize, 1), routed.routed);
    try expectPadEscape(routed.tracks, .{ -1, 0 }, .{ 0.3, 0.125 }, -1);
    try expectPadEscape(routed.tracks, .{ -4, 1 }, .{ 0.2, 0.2 }, 1);
}
