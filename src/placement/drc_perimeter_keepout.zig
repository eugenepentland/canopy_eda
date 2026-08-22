//! Post-route checks for the typed keepout band declared by a board perimeter
//! fence. The band begins at the fence via's inward copper edge and extends by
//! the authored clearance. Components, tracks, and vias are independently
//! selectable; named nets and the generated fence sites are admitted.

const std = @import("std");
const drc = @import("drc.zig");
const optimizer = @import("optimizer.zig");
const outline = @import("outline.zig");
const pad_shape = @import("pad_shape.zig");
const perimeter_fence = @import("perimeter_fence.zig");
const router = @import("router.zig");
const numeric = @import("../numeric.zig");

const eps = 1e-6;

fn signedInset(p: optimizer.Placement, x: f64, y: f64) f64 {
    if (p.board_poly) |poly| return outline.signedInset(poly, x, y);
    const r = p.board_rect orelse return -std.math.inf(f64);
    return @min(@min(x - r.minx, r.minx + r.w - x), @min(y - r.miny, r.miny + r.h - y));
}

fn appendCopper(
    arena: std.mem.Allocator,
    out: *std.ArrayList(drc.Violation),
    net: i32,
    at: [2]f64,
    gap: f64,
    limit: f64,
) std.mem.Allocator.Error!void {
    if (!(gap < limit - eps)) return;
    try out.append(arena, .{
        .x = at[0],
        .y = at[1],
        .gap = gap,
        .clearance = limit,
        .kind = .perimeter_keepout,
        .severity = drc.defaultSeverity(.perimeter_keepout),
        .who = .{ .net_a = net },
    });
}

fn checkTracks(
    arena: std.mem.Allocator,
    out: *std.ArrayList(drc.Violation),
    placement: optimizer.Placement,
    tracks: []const router.Track,
    limit: f64,
) std.mem.Allocator.Error!void {
    for (tracks) |track| {
        if (perimeter_fence.keepoutAllowsNet(placement, track.net)) continue;
        const length = std.math.hypot(track.x2 - track.x1, track.y2 - track.y1);
        const steps = @max(1, numeric.checkedInt(usize, @ceil(length / 0.1)) orelse continue);
        var worst = std.math.inf(f64);
        var wx = track.x1;
        var wy = track.y1;
        for (0..steps + 1) |i| {
            const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
            const x = track.x1 + (track.x2 - track.x1) * t;
            const y = track.y1 + (track.y2 - track.y1) * t;
            const inset = signedInset(placement, x, y);
            if (inset < worst) {
                worst = inset;
                wx = x;
                wy = y;
            }
        }
        try appendCopper(arena, out, track.net, .{ wx, wy }, worst - track.width / 2, limit);
    }
}

fn checkVias(
    arena: std.mem.Allocator,
    out: *std.ArrayList(drc.Violation),
    placement: optimizer.Placement,
    vias: []const router.Via,
    limit: f64,
) std.mem.Allocator.Error!void {
    for (vias) |via| {
        if (perimeter_fence.isGenerated(placement, via) or
            perimeter_fence.keepoutAllowsNet(placement, via.net)) continue;
        try appendCopper(
            arena,
            out,
            via.net,
            .{ via.x, via.y },
            signedInset(placement, via.x, via.y) - via.dia / 2,
            limit,
        );
    }
}

fn checkComponents(
    arena: std.mem.Allocator,
    out: *std.ArrayList(drc.Violation),
    placement: optimizer.Placement,
    limit: f64,
) std.mem.Allocator.Error!void {
    const board = placement.board_rect orelse return;
    for (placement.parts, 0..) |part, i| {
        // Loose parts parked outside the board are a placement workflow state,
        // not occupants of its perimeter band.
        if (part.x < board.minx or part.y < board.miny or
            part.x > board.minx + board.w or part.y > board.miny + board.h) continue;
        // The courtyard's OWN corners, not its bounding box's: off a quarter
        // turn a box corner is a point no part of the component occupies, so
        // measuring it puts a component in the band that never entered it.
        const corners = pad_shape.worldCourtyardCorners(part);
        var worst = std.math.inf(f64);
        var at = corners[0];
        for (corners) |corner| {
            const inset = signedInset(placement, corner[0], corner[1]);
            if (inset < worst) {
                worst = inset;
                at = corner;
            }
        }
        if (worst >= limit - eps) continue;
        try out.append(arena, .{
            .x = at[0],
            .y = at[1],
            .gap = worst,
            .clearance = limit,
            .kind = .perimeter_keepout,
            .severity = drc.defaultSeverity(.perimeter_keepout),
            .who = .{ .part_a = drc.partyIndex(i) },
        });
    }
}

/// Append every perimeter-band finding. Boards without a typed perimeter
/// keepout take the constant-time early return.
pub fn check(
    arena: std.mem.Allocator,
    out: *std.ArrayList(drc.Violation),
    placement: optimizer.Placement,
    tracks: []const router.Track,
    vias: []const router.Via,
) std.mem.Allocator.Error!void {
    const limit = perimeter_fence.keepoutLimit(placement);
    if (!(limit > 0)) return;
    const blocks = placement.rules.perimeter_fence.keepout.blocks;
    if (blocks.tracks) try checkTracks(arena, out, placement, tracks, limit);
    if (blocks.vias) try checkVias(arena, out, placement, vias, limit);
    if (blocks.components) try checkComponents(arena, out, placement, limit);
}

const testing = std.testing;
const flat_netlist = @import("../flat_netlist.zig");

// spec: placement/drc - a typed perimeter keepout flags only its blocked feature families, admits named nets, and exempts generated fence vias
test "perimeter keepout checks components tracks and vias with declared exceptions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "GND", .pins = &.{} },
        .{ .name = "SIG", .pins = &.{} },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .x = 0.9, .y = 5, .hw = 0.2, .hh = 0.2, .pads = &.{}, .fallback = false },
        .{ .ref_des = "U2", .kind = .hub, .x = 5, .y = 5, .hw = 0.2, .hh = 0.2, .pads = &.{}, .fallback = false },
    };
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .generated = true,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 },
        .rules = .{ .perimeter_fence = .{
            .via_dia = 0.4,
            .via_drill = 0.2,
            .spacing = 1,
            .edge_offset = 0.5,
            .keepout = .{
                .clearance = 0.3,
                .blocks = .{ .components = true, .tracks = true, .vias = true },
                .allow_nets = &.{"GND"},
            },
        } },
    };
    const tracks = [_]router.Track{
        .{ .x1 = 0.8, .y1 = 2, .x2 = 0.8, .y2 = 8, .layer = 0, .width = 0.2, .net = 1 },
        .{ .x1 = 0.8, .y1 = 2, .x2 = 0.8, .y2 = 8, .layer = 0, .width = 0.2, .net = 0 },
    };
    const vias = [_]router.Via{
        .{ .x = 0.9, .y = 4, .dia = 0.4, .drill = 0.2, .net = 1 },
        .{ .x = 0.5, .y = 4, .dia = 0.4, .drill = 0.2, .net = 0 },
    };
    var hits: std.ArrayList(drc.Violation) = .empty;
    try check(arena, &hits, placement, &tracks, &vias);
    try testing.expectEqual(@as(usize, 3), hits.items.len);
    try testing.expectEqual(@as(i32, 1), hits.items[0].who.net_a);
    try testing.expectEqual(@as(i32, 1), hits.items[1].who.net_a);
    try testing.expectEqual(@as(i32, 0), hits.items[2].who.part_a);
    for (hits.items) |hit| try testing.expectEqual(drc.Severity.err, hit.severity);
}

// spec: placement/drc - a component's perimeter-band inset is measured at its rotated courtyard corners
test "a rotated component's band inset is read at the corners it has" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const nets = [_]flat_netlist.FlatNet{.{ .name = "GND", .pins = &.{} }};
    // A 10 mm board chamfered off along x + y = 3, and a 4 × 1 mm part turned
    // 45° so its long axis runs PARALLEL to that cut. The part clears the band;
    // only its bounding box's inner corner — a point it does not occupy —
    // reaches in.
    const poly = [_][2]f64{ .{ 3, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 }, .{ 0, 3 } };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "J1", .kind = .hub, .x = 4.1, .y = 4.1, .hw = 2, .hh = 0.5, .pads = &.{}, .fallback = false, .rot = 45 },
    };
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .generated = true,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 },
        .board_poly = &poly,
        .rules = .{ .perimeter_fence = .{
            .via_dia = 0.4,
            .via_drill = 0.2,
            .spacing = 1,
            .edge_offset = 0.5,
            .keepout = .{ .clearance = 0.7, .blocks = .{ .components = true } },
        } },
    };
    const limit = perimeter_fence.keepoutLimit(placement);
    const box = optimizer.worldCourtyard(&parts[0]);
    try testing.expect(signedInset(placement, box.minx, box.miny) < limit);
    for (pad_shape.worldCourtyardCorners(parts[0])) |corner| {
        try testing.expect(signedInset(placement, corner[0], corner[1]) > limit);
    }
    var hits: std.ArrayList(drc.Violation) = .empty;
    try check(arena, &hits, placement, &.{}, &.{});
    try testing.expectEqual(@as(usize, 0), hits.items.len);
}
