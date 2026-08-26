//! Add the autorouter's ground-via candidates to hand-authored copper.
//!
//! The full plane pass also emits fan-out barrels joined by temporary stubs.
//! A hand-routing seed must not silently invent those traces, so this seam
//! first keeps candidates whose complete annulus lands on their own GND pad:
//! exposed-pad thermal fields and ordinary centred ground-pad drops. It then
//! applies the router's final ground-distance pass, which searches for the
//! nearest legal site beside every still-unserved pad and adds the short join
//! needed when that face has no same-net pour. Ordinary in-pad drops prefer the
//! pad's exact world centre before the incremental DRC gate; this removes
//! routing-grid offsets introduced by flattened subcircuits.

const std = @import("std");
const drc = @import("placement/drc.zig");
const geometry = @import("placement/geometry.zig");
const optimizer = @import("placement/optimizer.zig");
const pad_shape = @import("placement/pad_shape.zig");
const plane_via = @import("placement/plane_via.zig");
const router = @import("placement/router.zig");

/// Additions returned to the caller, plus why the other eligible candidates
/// were left alone. `vias` never contains copper supplied in `routed`.
const Outcome = struct {
    vias: []const router.Via = &.{},
    tracks: []const router.Track = &.{},
    candidates: usize = 0,
    duplicates: usize = 0,
    blocked: usize = 0,
    nearby: usize = 0,
};

fn groundNet(placement: optimizer.Placement, via: router.Via) ?usize {
    if (via.net < 0) return null;
    const net_i: usize = @intCast(via.net);
    if (net_i >= placement.nets.len) return null;
    const name = router.shortName(placement.nets[net_i].name);
    return if (optimizer.isGroundName(name)) net_i else null;
}

const OwnPad = struct {
    shape: pad_shape.Shape,
    centre: [2]f64,
    thermal: bool,
};

fn exposedPad(part: optimizer.Part, own: geometry.Pad) bool {
    const own_area = own.w * own.h;
    var other_area: f64 = 0;
    for (part.pads) |pad| {
        if (std.mem.eql(u8, pad.number, own.number) or pad.thru) continue;
        other_area = @max(other_area, pad.w * pad.h);
    }
    return own_area >= 1.0 and own_area >= 2.0 * other_area;
}

fn ownPadAt(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    net_i: usize,
    via: router.Via,
) std.mem.Allocator.Error!?OwnPad {
    const net = placement.nets[net_i];
    for (net.pins) |pin| {
        for (placement.parts) |part| {
            if (!std.mem.eql(u8, part.ref_des, pin.ref_des)) continue;
            for (part.pads) |pad| {
                if (!std.mem.eql(u8, pad.number, pin.pin)) continue;
                const shape = try pad_shape.worldShape(arena, part, pad);
                if (!plane_via.barrelFits(shape, .{ via.x, via.y }, via.dia)) continue;
                return .{
                    .shape = shape,
                    .centre = optimizer.worldPadCenter(&part, pad.x, pad.y),
                    .thermal = exposedPad(part, pad),
                };
            }
        }
    }
    return null;
}

fn sameVia(a: router.Via, b: router.Via) bool {
    const eps = 1e-6;
    return a.net == b.net and @abs(a.x - b.x) <= eps and @abs(a.y - b.y) <= eps;
}

fn hasSameVia(vias: []const router.Via, candidate: router.Via) bool {
    for (vias) |via| if (sameVia(via, candidate)) return true;
    return false;
}

/// Generate the same exposed-pad arrays, ordinary GND-pad barrels, and final
/// ground-distance stitches as the autorouter, without replacing existing
/// copper. An ordinary barrel is offered at its pad's exact world centre first,
/// then falls back to the router's nearest legal site if the submitted board
/// blocks it. Thermal-array cells retain their regular field. Exact existing
/// barrels make the operation idempotent; the shared incremental DRC gate
/// rejects any via-in-pad candidate that would add a fab error.
fn generate(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    routed: router.RouteResult,
    params: router.RouteParams,
) std.mem.Allocator.Error!Outcome {
    const proposed = try router.groundVias(arena, placement, params);

    var accepted: std.ArrayList(router.Via) = .empty;
    var out = Outcome{};
    if (proposed.len > 0) {
        var gate = try drc.ViaAdditionGate.build(arena, placement, routed, params.clearance, proposed[0]);

        for (proposed) |proposed_candidate| {
            const net_i = groundNet(placement, proposed_candidate) orelse continue;
            const own_pad = try ownPadAt(arena, placement, net_i, proposed_candidate) orelse continue;
            out.candidates += 1;

            var candidate = proposed_candidate;
            if (!own_pad.thermal and plane_via.barrelFits(own_pad.shape, own_pad.centre, candidate.dia)) {
                candidate.x = own_pad.centre[0];
                candidate.y = own_pad.centre[1];
            }

            if (hasSameVia(gate.others.items, candidate)) {
                out.duplicates += 1;
                continue;
            }
            if (try gate.addsError(arena, candidate)) {
                if (sameVia(candidate, proposed_candidate)) {
                    out.blocked += 1;
                    continue;
                }
                candidate = proposed_candidate;
                if (hasSameVia(gate.others.items, candidate)) {
                    out.duplicates += 1;
                    continue;
                }
                if (try gate.addsError(arena, candidate)) {
                    out.blocked += 1;
                    continue;
                }
            }
            try gate.accept(arena, candidate);
            try accepted.append(arena, candidate);
        }
    }

    // Keep the button's existing exposed-pad arrays and exact via-in-pad
    // drops, then run the autorouter's final ground-reference pass over the
    // resulting live copper. That second pass is what searches outward from
    // every pad still failing `(ground-via-max MM)` and uses the closest
    // legal site it can find (plus a short surface join when there is no
    // same-face pour).
    var seeded_vias = std.ArrayList(router.Via).fromOwnedSlice(try arena.dupe(router.Via, routed.vias));
    try seeded_vias.appendSlice(arena, accepted.items);
    var seeded = routed;
    seeded.vias = try seeded_vias.toOwnedSlice(arena);
    var stitch_placement = placement;
    stitch_placement.rules.design.track_width = params.track_width;
    stitch_placement.rules.design.clearance = params.clearance;
    stitch_placement.rules.design.via_dia = params.via_dia;
    stitch_placement.rules.design.via_drill = params.via_drill;
    const stitched = try router.addGroundPadStitches(arena, stitch_placement, seeded);
    out.nearby = stitched.vias.len - seeded.vias.len;
    out.vias = stitched.vias[routed.vias.len..];
    out.tracks = stitched.tracks[routed.tracks.len..];
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

/// One generated surface join with its stable net name for JSON persistence.
const NamedTrack = struct {
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
    layer: u8,
    width: f64,
    net: []const u8,
};

/// Browser-facing seed result. Only `vias` and short `tracks` are additions;
/// submitted copper is deliberately absent so the client cannot replace it by
/// applying this reply.
pub const LiveOutcome = struct {
    vias: []const NamedVia,
    tracks: []const NamedTrack,
    candidates: usize,
    duplicates: usize,
    blocked: usize,
    nearby: usize,
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
    const named_tracks = try arena.alloc(NamedTrack, seeded.tracks.len);
    for (seeded.tracks, 0..) |track, i| named_tracks[i] = .{
        .x1 = track.x1,
        .y1 = track.y1,
        .x2 = track.x2,
        .y2 = track.y2,
        .layer = track.layer,
        .width = track.width,
        .net = if (track.net >= 0 and @as(usize, @intCast(track.net)) < placement.nets.len)
            placement.nets[@intCast(track.net)].name
        else
            "",
    };
    return .{
        .vias = named,
        .tracks = named_tracks,
        .candidates = seeded.candidates,
        .duplicates = seeded.duplicates,
        .blocked = seeded.blocked,
        .nearby = seeded.nearby,
    };
}

// ── Tests ───────────────────────────────────────────────────────────────────

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
        // Deliberately off the router lattice, as a flattened subcircuit pad
        // commonly is after its parent transform. The land is wide enough for
        // both its true centre and the nearby snapped point to hold the barrel.
        .{
            .ref_des = "C1",
            .kind = .passive,
            .hw = 0.5,
            .hh = 0.5,
            .pads = &cap_pads,
            .fallback = false,
            .x = 5.03,
            .y = 0.18,
        },
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

// spec: placement/ground-via-seed - hand routing can seed one legal exposed-pad field and one centred GND-pad barrel without replacing existing copper, preserving the exact centre of an off-grid transformed subcircuit pad when it is legal
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
    var centred = false;
    for (first.vias) |via| {
        if (@abs(via.x - fixture.parts[1].x) <= 1e-9 and @abs(via.y - fixture.parts[1].y) <= 1e-9) {
            centred = true;
            break;
        }
    }
    try testing.expect(centred);

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

// spec: placement/ground-via-seed - after via-in-pad seeding, hand routing places the nearest legal barrel within the authored ground-via maximum beside every still-unserved ground pad and adds its surface join when that face has no same-net pour
test "ground via seed clears a distance warning at the nearest legal off-pad site" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const ground_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.3, .h = 0.3 }};
    const foreign_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.2, .h = 0.2 }};
    var parts = [_]optimizer.Part{
        .{
            .ref_des = "C1",
            .kind = .passive,
            .hw = 0.3,
            .hh = 0.3,
            .pads = &ground_pad,
            .fallback = false,
        },
        // Its land starts at x=0.3: far enough to clear C1's 0.15-mm land
        // edge, but close enough to block a 0.4-mm via centred on C1.
        .{
            .ref_des = "R1",
            .kind = .passive,
            .hw = 0.2,
            .hh = 0.2,
            .pads = &foreign_pad,
            .fallback = false,
            .x = 0.4,
        },
    };
    const ground_pins = [_]flat_netlist.FlatPin{.{ .ref_des = "C1", .pin = "1" }};
    const signal_pins = [_]flat_netlist.FlatPin{.{ .ref_des = "R1", .pin = "1" }};
    const nets = [_]flat_netlist.FlatNet{
        .{ .name = "GND", .pins = &ground_pins },
        .{ .name = "SIG", .pins = &signal_pins },
    };
    const plane_nets = [_][]const u8{"GND"};
    const planes = [_]optimizer.PlaneAt{.{ .index = 1, .net = "GND" }};
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
        .rules = .{
            .plane_nets = &plane_nets,
            .copper_layers = 4,
            .planes = .{ .declared = &planes },
            .design = .{ .pour = .{ .ground_via_max = 1.0 } },
        },
    };
    const params = placement.rules.design.routeParams();
    const empty = router.RouteResult{ .tracks = &.{}, .vias = &.{}, .routed = 0, .total = 0 };
    try testing.expectEqual(@as(usize, 1), drc.countKind(try drc.check(arena, placement, empty, params.clearance), .ground_via_distance));

    const result = try generate(arena, placement, empty, params);
    try testing.expectEqual(@as(usize, 1), result.nearby);
    try testing.expectEqual(@as(usize, 1), result.vias.len);
    const distance = std.math.hypot(result.vias[0].x, result.vias[0].y);
    try testing.expect(distance > 1e-6);
    try testing.expect(distance <= 1.0 + 1e-9);
    const stitched = router.RouteResult{ .tracks = result.tracks, .vias = result.vias, .routed = 0, .total = 0 };
    try testing.expectEqual(@as(usize, 0), drc.countKind(try drc.check(arena, placement, stitched, params.clearance), .ground_via_distance));

    const again = try generate(arena, placement, stitched, params);
    try testing.expectEqual(@as(usize, 0), again.vias.len);
    try testing.expectEqual(@as(usize, 0), again.tracks.len);
}
