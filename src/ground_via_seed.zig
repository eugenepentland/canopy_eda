//! Add the autorouter's via-in-pad ground candidates to hand-authored copper.
//!
//! The full plane pass also emits fan-out barrels joined by temporary stubs.
//! A hand-routing seed must not silently invent those traces, so this seam
//! keeps only candidates whose complete annulus lands on their own GND pad:
//! exposed-pad thermal fields and ordinary centred ground-pad drops.

const std = @import("std");
const drc = @import("placement/drc.zig");
const optimizer = @import("placement/optimizer.zig");
const pad_shape = @import("placement/pad_shape.zig");
const plane_via = @import("placement/plane_via.zig");
const router = @import("placement/router.zig");

/// Additions returned to the caller, plus why the other eligible candidates
/// were left alone. `vias` never contains copper supplied in `routed`.
const Outcome = struct {
    vias: []const router.Via = &.{},
    candidates: usize = 0,
    duplicates: usize = 0,
    blocked: usize = 0,
};

fn groundNet(placement: optimizer.Placement, via: router.Via) ?usize {
    if (via.net < 0) return null;
    const net_i: usize = @intCast(via.net);
    if (net_i >= placement.nets.len) return null;
    const name = router.shortName(placement.nets[net_i].name);
    return if (optimizer.isGroundName(name)) net_i else null;
}

fn landsOnOwnPad(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    net_i: usize,
    via: router.Via,
) std.mem.Allocator.Error!bool {
    const net = placement.nets[net_i];
    for (net.pins) |pin| {
        for (placement.parts) |part| {
            if (!std.mem.eql(u8, part.ref_des, pin.ref_des)) continue;
            for (part.pads) |pad| {
                if (!std.mem.eql(u8, pad.number, pin.pin)) continue;
                const shape = try pad_shape.worldShape(arena, part, pad);
                if (plane_via.barrelFits(shape, .{ via.x, via.y }, via.dia)) return true;
            }
        }
    }
    return false;
}

fn sameVia(a: router.Via, b: router.Via) bool {
    const eps = 1e-6;
    return a.net == b.net and @abs(a.x - b.x) <= eps and @abs(a.y - b.y) <= eps;
}

/// Generate the same exposed-pad arrays and centred GND-pad barrels as the
/// autorouter's plane pass, without routing any trace or replacing existing
/// copper. Exact existing barrels make the operation idempotent; the shared
/// incremental DRC gate rejects any candidate that would add a fab error.
fn generate(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    params: router.RouteParams,
) std.mem.Allocator.Error!Outcome {
    const proposed = try router.groundVias(arena, placement, params);
    if (proposed.len == 0) return .{};

    var accepted: std.ArrayList(router.Via) = .empty;
    var out = Outcome{};
    var gate = try drc.ViaAdditionGate.build(arena, placement, routed, params.clearance, proposed[0]);

    for (proposed) |candidate| {
        const net_i = groundNet(placement, candidate) orelse continue;
        if (!try landsOnOwnPad(arena, placement, net_i, candidate)) continue;
        out.candidates += 1;

        var duplicate = false;
        for (gate.others.items) |existing| {
            if (!sameVia(existing, candidate)) continue;
            duplicate = true;
            break;
        }
        if (duplicate) {
            out.duplicates += 1;
            continue;
        }
        if (try gate.addsError(arena, candidate)) {
            out.blocked += 1;
            continue;
        }
        try gate.accept(arena, candidate);
        try accepted.append(arena, candidate);
    }
    out.vias = try accepted.toOwnedSlice(arena);
    return out;
}

/// One generated barrel with its stable net name for JSON persistence.
pub const NamedVia = struct {
    x: f64,
    y: f64,
    dia: f64,
    drill: f64,
    net: []const u8,
};

/// Browser-facing seed result. Only `vias` are additions; submitted copper is
/// deliberately absent so the client cannot replace it by applying this reply.
pub const LiveOutcome = struct {
    vias: []const NamedVia,
    candidates: usize,
    duplicates: usize,
    blocked: usize,
};

/// Rebuild the placement at the submitted browser poses, retain its submitted
/// copper, and return named additions ready for the editor. Generic pose and
/// outline inputs keep the serve-layer JSON structs out of this model adapter.
pub fn generateLive(
    arena: std.mem.Allocator,
    project_dir: []const u8,
    input: anytype,
) std.mem.Allocator.Error!LiveOutcome {
    const poses = try arena.alloc(optimizer.RefPose, input.poses.len);
    for (input.poses, 0..) |pose, i| poses[i] = .{
        .ref = pose.ref,
        .x = pose.x,
        .y = pose.y,
        .rot = pose.rot,
        .side = pose.side,
        .locked = pose.locked,
    };
    const outline: optimizer.OutlineSource = if (input.saved_outline) |saved|
        .{ .drawn = .{
            .rect = .{ .minx = saved.x, .miny = saved.y, .w = saved.w, .h = saved.h },
            .poly = saved.derived.poly orelse saved.pts,
            .arcs = saved.derived.arcs,
        } }
    else
        optimizer.outlineOf(&input.fallback);
    const placement = try optimizer.placeFromPoses(arena, input.block, project_dir, .{
        .poses = poses,
        .outline = outline,
    }, input.placement_params);
    var params = placement.rules.design.routeParams();
    if (input.geometry.clearance > 0) params.clearance = input.geometry.clearance;
    if (input.geometry.via_dia > 0) params.via_dia = input.geometry.via_dia;
    if (input.geometry.via_drill > 0) params.via_drill = input.geometry.via_drill;
    const seeded = try generate(arena, placement, input.routed, params);
    const named = try arena.alloc(NamedVia, seeded.vias.len);
    for (seeded.vias, 0..) |via, i| named[i] = .{
        .x = via.x,
        .y = via.y,
        .dia = via.dia,
        .drill = via.drill,
        .net = if (via.net >= 0 and @as(usize, @intCast(via.net)) < placement.nets.len)
            placement.nets[@intCast(via.net)].name
        else
            "",
    };
    return .{
        .vias = named,
        .candidates = seeded.candidates,
        .duplicates = seeded.duplicates,
        .blocked = seeded.blocked,
    };
}

// ── Tests ───────────────────────────────────────────────────────────────────

const geometry = @import("placement/geometry.zig");
const flat_netlist = @import("flat_netlist.zig");
const testing = std.testing;

const fixture = struct {
    const ep_poly = [_][2]f64{ .{ -1.5, -1.5 }, .{ 1.5, -1.5 }, .{ 1.5, 1.5 }, .{ -1.5, 1.5 } };
    var qfn_pads = [_]geometry.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 3, .h = 3, .poly = &ep_poly },
        .{ .number = "2", .x = 2, .y = 0, .w = 0.4, .h = 0.8 },
        .{ .number = "3", .x = -2, .y = 0, .w = 0.4, .h = 0.8 },
    };
    var cap_pads = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.9, .h = 0.95 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 2.5, .hh = 2.5, .pads = &qfn_pads, .fallback = false },
        .{ .ref_des = "C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &cap_pads, .fallback = false, .x = 5 },
    };
    const pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "C1", .pin = "1" },
    };
    const nets = [_]flat_netlist.FlatNet{.{ .name = "GND", .pins = &pins }};
};

fn fixturePlacement() optimizer.Placement {
    return .{
        .parts = &fixture.parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &fixture.nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -4,
        .miny = -4,
        .maxx = 7,
        .maxy = 4,
        .generated = true,
    };
}

const test_params = router.RouteParams{
    .track_width = 0.2,
    .clearance = 0.2,
    .via_dia = 0.8,
    .via_drill = 0.4,
};

// spec: placement/ground-via-seed - hand routing can seed one legal exposed-pad field and one centred GND-pad barrel without replacing existing copper
// spec: placement/ground-via-seed - running the ground-via seed repeatedly adds each eligible barrel at most once
test "ground via seed adds the via-in-pad candidates once" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const empty = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 };

    const first = try generate(arena, fixturePlacement(), empty, test_params);
    try testing.expectEqual(@as(usize, 10), first.candidates);
    try testing.expectEqual(@as(usize, 10), first.vias.len);
    try testing.expectEqual(@as(usize, 0), first.blocked);

    const saved = router.RouteResult{ .tracks = &.{}, .vias = first.vias, .routed = 0, .total = 0 };
    const second = try generate(arena, fixturePlacement(), saved, test_params);
    try testing.expectEqual(@as(usize, 10), second.candidates);
    try testing.expectEqual(@as(usize, 10), second.duplicates);
    try testing.expectEqual(@as(usize, 0), second.vias.len);
}

// spec: placement/ground-via-seed - a candidate that would add a fabrication DRC error is reported as blocked and is not returned
test "ground via seed leaves a DRC-blocked field cell alone" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var p = fixturePlacement();
    const nets = [_]flat_netlist.FlatNet{
        fixture.nets[0],
        .{ .name = "SIGNAL", .pins = &.{} },
    };
    p.nets = &nets;
    const foreign = [_]router.Via{.{ .x = 0, .y = 0, .dia = 0.8, .drill = 0.4, .net = 1 }};
    const routed = router.RouteResult{ .tracks = &.{}, .vias = &foreign, .routed = 0, .total = 0 };

    const result = try generate(arena, p, routed, test_params);
    try testing.expectEqual(@as(usize, 10), result.candidates);
    try testing.expectEqual(@as(usize, 1), result.blocked);
    try testing.expectEqual(@as(usize, 9), result.vias.len);
}
