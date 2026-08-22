//! Exact-target bypass connectivity DRC.
//!
//! Whole-net connectivity is not enough for a high-frequency decoupler. A cap
//! and its IC can both reach a rail plane through separate vias and therefore
//! belong to one electrical net while the local surface leg the decoupling
//! loop requires is absent. This pass checks the relationship the placement
//! model already resolved: cap rail land -> exact IC supply land, on their
//! shared outer face, through continuous routed copper. It deliberately ignores
//! vias and pours; those are the remote path this rule exists to distinguish.

const std = @import("std");
const copper_contact = @import("copper_contact.zig");
const drc = @import("drc.zig");
const optimizer = @import("optimizer.zig");
const pad_shape = @import("pad_shape.zig");
const router = @import("router.zig");

const touch_slack_mm: f64 = 0.02;

/// Warn once for every authored, non-reservoir decoupling loop whose capacitor
/// rail pad has no direct same-face copper path to its exact target IC supply
/// pad. Optimizer-inferred proximity loops are not electrical bypass intent.
pub fn check(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    tracks: []const router.Track,
) std.mem.Allocator.Error![]drc.Violation {
    var out: std.ArrayList(drc.Violation) = .empty;
    for (placement.loops) |loop| {
        if (loop.explicit_pin.len == 0 or loop.rail_optout or loop.pwr_net < 0) continue;
        if (loop.cap >= placement.parts.len or loop.hub >= placement.parts.len) continue;
        const net_i: usize = @intCast(loop.pwr_net);
        if (net_i >= placement.nets.len) continue;

        const cap = placement.parts[loop.cap];
        const hub = placement.parts[loop.hub];
        // A direct outer-face leg cannot cross sides. Report it below rather
        // than silently accepting a via/plane detour.
        const layer: u8 = if (cap.side == .top) 0 else 1;
        const cap_pad = padAt(cap, loop.cap_pwr) orelse continue;
        const hub_pad = padAt(hub, loop.hub_pwr_pin) orelse continue;
        const cap_shape = try pad_shape.worldShape(arena, cap, cap_pad);
        const hub_shape = try pad_shape.worldShape(arena, hub, hub_pad);
        if (cap.side == hub.side and try surfaceConnected(
            arena,
            tracks,
            loop.pwr_net,
            layer,
            cap_shape,
            hub_shape,
        )) continue;

        const a = center(cap_shape);
        const b = center(hub_shape);
        try out.append(arena, .{
            .x = (a[0] + b[0]) / 2,
            .y = (a[1] + b[1]) / 2,
            .gap = pad_shape.shapeGap(cap_shape, hub_shape, 0),
            .clearance = 0,
            .kind = .bypass_open,
            .severity = drc.defaultSeverity(.bypass_open),
            .who = .{
                .net_a = loop.pwr_net,
                .part_a = drc.partyIndex(loop.cap),
                .pad_a = cap_pad.number,
                .part_b = drc.partyIndex(loop.hub),
                .pad_b = hub_pad.number,
            },
            .layer = if (cap.side == hub.side) @fromBackingInt(@intCast(layer)) else null,
        });
    }
    return out.toOwnedSlice(arena);
}

fn padAt(part: optimizer.Part, rect: optimizer.PadRect) ?@import("geometry.zig").Pad {
    if (!(rect.w > 0 and rect.h > 0)) return null;
    for (part.pads) |pad| {
        if (@abs(pad.x - rect.x) <= 1e-7 and @abs(pad.y - rect.y) <= 1e-7) return pad;
    }
    return null;
}

fn center(shape: pad_shape.Shape) [2]f64 {
    return .{ (shape.x0 + shape.x1) / 2, (shape.y0 + shape.y1) / 2 };
}

fn root(parent: []const usize, start: usize) usize {
    var at = start;
    while (parent[at] != at) at = parent[at];
    return at;
}

fn unite(parent: []usize, a: usize, b: usize) void {
    const ar = root(parent, a);
    const br = root(parent, b);
    if (ar != br) parent[@max(ar, br)] = @min(ar, br);
}

fn trackTouchesShape(track: router.Track, shape: pad_shape.Shape) bool {
    return copper_contact.padTrackConnects(shape, .{ track.x1, track.y1 }, .{ track.x2, track.y2 }, track.width);
}

fn tracksTouch(a: router.Track, b: router.Track) bool {
    return copper_contact.trackTrackConnects(
        .{ .a = .{ a.x1, a.y1 }, .b = .{ a.x2, a.y2 }, .width = a.width },
        .{ .a = .{ b.x1, b.y1 }, .b = .{ b.x2, b.y2 }, .width = b.width },
    );
}

/// Connectivity over only the local routed copper on `layer`: pad nodes plus
/// the same-net track capsules. Vias and pours are intentionally absent.
fn surfaceConnected(
    arena: std.mem.Allocator,
    all_tracks: []const router.Track,
    net: i32,
    layer: u8,
    cap: pad_shape.Shape,
    hub: pad_shape.Shape,
) std.mem.Allocator.Error!bool {
    var tracks: std.ArrayList(router.Track) = .empty;
    for (all_tracks) |track| {
        if (track.net == net and track.layer == layer) try tracks.append(arena, track);
    }
    // Node 0 = cap pad, node 1 = hub pad, remainder = filtered tracks.
    const parent = try arena.alloc(usize, tracks.items.len + 2);
    for (parent, 0..) |*slot, i| slot.* = i;
    if (pad_shape.shapeGap(cap, hub, touch_slack_mm) <= touch_slack_mm) unite(parent, 0, 1);
    for (tracks.items, 0..) |track, i| {
        const node = i + 2;
        if (trackTouchesShape(track, cap)) unite(parent, 0, node);
        if (trackTouchesShape(track, hub)) unite(parent, 1, node);
        for (tracks.items[0..i], 0..) |before, j| {
            if (tracksTouch(track, before)) unite(parent, node, j + 2);
        }
    }
    return root(parent, 0) == root(parent, 1);
}

// spec: placement/bypass-open - A decoupling capacitor must have continuous same-face copper to the exact IC supply pad its loop targets
// spec: placement/bypass-open - Vias and remote pours do not substitute for a bypass capacitor's local surface leg
// spec: placement/bypass-open - rail-level reservoir capacitors explicitly marked `(decouples rail)` are outside the exact-pad rule
// spec: placement/bypass-open - optimizer-inferred proximity loops are outside the authored exact-pad rule
test "a bypass routed to the wrong QFN supply pad warns until its exact target is joined" {
    var arena_i = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();
    const G = @import("geometry.zig");
    const hub_pads = [_]G.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 0.5, .h = 0.5 },
        .{ .number = "2", .x = 1, .y = 0, .w = 0.5, .h = 0.5 },
    };
    const cap_pads = [_]G.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 0.5, .h = 0.5 },
        .{ .number = "2", .x = 0, .y = 1, .w = 0.5, .h = 0.5 },
    };
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &hub_pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &cap_pads, .fallback = false, .x = 4, .y = 0 },
    };
    const pins = [_]@import("../flat_netlist.zig").FlatPin{
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "U1", .pin = "2" },
        .{ .ref_des = "C1", .pin = "1" },
    };
    const nets = [_]optimizer.FlatNet{.{ .name = "VDD", .pins = &pins }};
    const loops = [_]optimizer.Loop{.{
        .cap = 1,
        .hub = 0,
        .cap_pwr = .{ .x = 0, .y = 0, .w = 0.5, .h = 0.5 },
        .cap_gnd = .{ .x = 0, .y = 1, .w = 0.5, .h = 0.5 },
        .hub_pwr = &.{},
        .hub_pwr_pin = .{ .x = 0, .y = 0, .w = 0.5, .h = 0.5 },
        .hub_gnd = &.{},
        .pwr_net = 0,
        .explicit_pin = "1",
    }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &loops,
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1,
        .miny = -1,
        .maxx = 5,
        .maxy = 2,
        .generated = true,
    };

    // With no surface copper, even hypothetical independent plane drops at
    // both lands cannot satisfy the local bypass leg.
    const missing = try check(arena, placement, &.{});
    try std.testing.expectEqual(@as(usize, 1), missing.len);

    const to_wrong = [_]router.Track{.{ .x1 = 4, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 }};
    const wrong = try check(arena, placement, &to_wrong);
    try std.testing.expectEqual(@as(usize, 1), wrong.len);
    try std.testing.expectEqual(drc.Kind.bypass_open, wrong[0].kind);
    try std.testing.expectEqual(drc.Severity.warn, wrong[0].severity);
    try std.testing.expectEqualStrings("1", wrong[0].who.pad_b);

    const to_target = [_]router.Track{.{ .x1 = 4, .y1 = 0, .x2 = 0, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 }};
    const closed = try check(arena, placement, &to_target);
    try std.testing.expectEqual(@as(usize, 0), closed.len);

    var reservoir_loop = loops;
    reservoir_loop[0].rail_optout = true;
    var reservoir = placement;
    reservoir.loops = &reservoir_loop;
    const exempt = try check(arena, reservoir, &.{});
    try std.testing.expectEqual(@as(usize, 0), exempt.len);

    var inferred_loop = loops;
    inferred_loop[0].explicit_pin = "";
    var inferred = placement;
    inferred.loops = &inferred_loop;
    const not_authored = try check(arena, inferred, &.{});
    try std.testing.expectEqual(@as(usize, 0), not_authored.len);
}
