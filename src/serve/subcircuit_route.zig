//! Hierarchical autorouting's local phase.
//!
//! Each first-level sub-circuit is routed against a placement view containing
//! only that sub-circuit's parts. The view keeps the board outline and routing
//! rules, but drops every other component and all pre-existing board copper.
//! Its copper is returned in the parent placement's net-index namespace so the
//! caller can validate and freeze it before starting the global route.

const std = @import("std");
const env = @import("../eval/env.zig");
const export_kicad = @import("../export_kicad.zig");
const optimizer = @import("../placement/optimizer.zig");
const route_policy = @import("../placement/route_policy.zig");
const router = @import("../placement/router.zig");
const route_plan = @import("route_plan.zig");
const clock = @import("../infra/clock.zig");
const drc = @import("../placement/drc.zig");

/// One parent-indexed track produced by an isolated sub-circuit pass.
pub const SeedTrack = struct { copper: route_policy.ExistingTrack, net: usize };

/// One parent-indexed via produced by an isolated sub-circuit pass.
pub const SeedVia = struct { copper: route_policy.ExistingVia, net: usize };

/// Copper produced by all isolated sub-circuit passes, plus a parent-net mask
/// identifying which nets should supersede saved module-snapshot seeds.
pub const Result = struct {
    tracks: []const SeedTrack = &.{},
    vias: []const SeedVia = &.{},
    nets: []const bool = &.{},
    complete_planes: []const bool = &.{},
    phase: struct {
        attempted_subcircuits: usize = 0,
        completed_subcircuits: usize = 0,
        timed_out_subcircuits: usize = 0,
        deferred_supply_nets: usize = 0,
        carrier_drop_vias: usize = 0,
    } = .{},
};

fn memberRef(path: []const u8, ref_des: []const u8) bool {
    return ref_des.len > path.len and std.mem.startsWith(u8, ref_des, path) and ref_des[path.len] == '/';
}

fn enabled(options: route_policy.Options, net: usize) bool {
    return options.selected_nets.len == 0 or
        (net < options.selected_nets.len and options.selected_nets[net]);
}

fn selectedNets(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    path: []const u8,
    base: route_policy.Options,
    supply: []const bool,
    want_supply: bool,
) std.mem.Allocator.Error![]bool {
    const selected = try alloc.alloc(bool, placement.nets.len);
    @memset(selected, false);
    for (placement.nets, 0..) |net, ni| {
        if (!enabled(base, ni)) continue;
        var local_terminals: usize = 0;
        for (net.pins) |pin| if (memberRef(path, pin.ref_des)) {
            local_terminals += 1;
        };
        if (ni >= supply.len or supply[ni] != want_supply) continue;
        // Signals need a real local tree. Supply terminals are independent:
        // even one boundary pad may own a vertical drop into a carrier.
        const minimum: usize = if (want_supply) 1 else 2;
        selected[ni] = local_terminals >= minimum;
    }
    return selected;
}

fn anySelected(selected: []const bool) bool {
    for (selected) |yes| if (yes) return true;
    return false;
}

fn localPlacement(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    path: []const u8,
) std.mem.Allocator.Error!?optimizer.Placement {
    const old_to_new = try alloc.alloc(?usize, placement.parts.len);
    @memset(old_to_new, null);

    var parts: std.ArrayList(optimizer.Part) = .empty;
    var instances: std.ArrayList(export_kicad.FlatInstance) = .empty;
    var priority: std.ArrayList(u32) = .empty;
    var minx = std.math.inf(f64);
    var miny = std.math.inf(f64);
    var maxx = -std.math.inf(f64);
    var maxy = -std.math.inf(f64);
    for (placement.parts, 0..) |part, old| {
        if (!memberRef(path, part.ref_des)) continue;
        old_to_new[old] = parts.items.len;
        try parts.append(alloc, part);
        if (old < placement.instances.len) try instances.append(alloc, placement.instances[old]);
        if (placement.priority.len > 0)
            try priority.append(alloc, if (old < placement.priority.len) placement.priority[old] else 0);
        const box = optimizer.worldCourtyard(&part);
        minx = @min(minx, box.minx);
        miny = @min(miny, box.miny);
        maxx = @max(maxx, box.minx + box.w);
        maxy = @max(maxy, box.miny + box.h);
    }
    if (parts.items.len == 0) return null;

    var loops: std.ArrayList(optimizer.Loop) = .empty;
    for (placement.loops) |loop| {
        if (loop.cap >= old_to_new.len or loop.hub >= old_to_new.len) continue;
        const cap = old_to_new[loop.cap] orelse continue;
        const hub = old_to_new[loop.hub] orelse continue;
        var local = loop;
        local.cap = cap;
        local.hub = hub;
        try loops.append(alloc, local);
    }

    var stubs: std.ArrayList(optimizer.Stub) = .empty;
    for (placement.stubs) |stub| {
        if (stub.part >= old_to_new.len) continue;
        const part = old_to_new[stub.part] orelse continue;
        var local = stub;
        local.part = part;
        try stubs.append(alloc, local);
    }

    return .{
        .parts = parts.items,
        .links = &.{},
        .loops = loops.items,
        .stubs = stubs.items,
        .instances = if (instances.items.len == parts.items.len) instances.items else &.{},
        .nets = placement.nets,
        .priority = priority.items,
        .score = placement.score,
        .breakdown = placement.breakdown,
        // A local lattice prevents an isolated module from paying for or
        // wandering through the empty span occupied by the rest of the board.
        .minx = minx,
        .miny = miny,
        .maxx = maxx,
        .maxy = maxy,
        .generated = placement.generated,
        .board_rect = placement.board_rect,
        .board_poly = placement.board_poly,
        .board_arcs = placement.board_arcs,
        .rules = placement.rules,
        .diff_pairs = placement.diff_pairs,
        .match_groups = placement.match_groups,
    };
}

fn selectedGuideTracks(
    alloc: std.mem.Allocator,
    values: []const route_policy.GuideTrack,
    selected: []const bool,
) std.mem.Allocator.Error![]const route_policy.GuideTrack {
    var out: std.ArrayList(route_policy.GuideTrack) = .empty;
    for (values) |value| if (value.net >= 0 and @as(usize, @intCast(value.net)) < selected.len and selected[@intCast(value.net)]) {
        try out.append(alloc, value);
    };
    return out.items;
}

fn selectedGuideVias(
    alloc: std.mem.Allocator,
    values: []const route_policy.GuideVia,
    selected: []const bool,
) std.mem.Allocator.Error![]const route_policy.GuideVia {
    var out: std.ArrayList(route_policy.GuideVia) = .empty;
    for (values) |value| if (value.net >= 0 and @as(usize, @intCast(value.net)) < selected.len and selected[@intCast(value.net)]) {
        try out.append(alloc, value);
    };
    return out.items;
}

fn selectedReserved(
    alloc: std.mem.Allocator,
    values: []const route_policy.ReservedLane,
    selected: []const bool,
) std.mem.Allocator.Error![]const route_policy.ReservedLane {
    var out: std.ArrayList(route_policy.ReservedLane) = .empty;
    for (values) |value| if (value.net >= 0 and @as(usize, @intCast(value.net)) < selected.len and selected[@intCast(value.net)]) {
        try out.append(alloc, value);
    };
    return out.items;
}

fn localOptions(
    alloc: std.mem.Allocator,
    base: route_policy.Options,
    selected: []const bool,
) std.mem.Allocator.Error!route_policy.Options {
    var options = base;
    options.selected_nets = selected;
    options.effort = .one_shot;
    // Isolation means no saved track, via, pour, keepout, or foreign reserved
    // lane from the assembled board participates in this phase. Authored policy
    // for the selected nets still applies.
    options.existing_tracks = &.{};
    options.existing_vias = &.{};
    // Pours and keepouts are board geometry, not reusable module copper. Keep
    // them so supply drops can prove a live landing and signal routes cannot
    // cross an authored exclusion. Tracks/vias remain isolated.
    options.existing_zones = base.existing_zones;
    options.guides = .{
        .tracks = try selectedGuideTracks(alloc, base.guides.tracks, selected),
        .vias = try selectedGuideVias(alloc, base.guides.vias, selected),
        .reserved = try selectedReserved(alloc, base.guides.reserved, selected),
    };
    // The live stream is reserved for the final assembled-board route. Local
    // passes still share cancellation and timing with their caller.
    options.sink = null;
    return options;
}

fn stopped(options: route_policy.Options) bool {
    if (options.stop.cancel) |cancel| if (cancel.load(.monotonic)) return true;
    return options.stop.deadline_ns != 0 and clock.nanoTimestamp() >= options.stop.deadline_ns;
}

fn localPhaseDeadline(base: route_policy.Options) i128 {
    if (base.stop.deadline_ns == 0) return 0;
    const now = clock.nanoTimestamp();
    if (base.stop.deadline_ns <= now) return now;
    return now + @divTrunc(base.stop.deadline_ns - now, 4);
}

fn sliceDeadline(phase_deadline: i128, remaining: usize) i128 {
    if (phase_deadline == 0 or remaining == 0) return phase_deadline;
    const now = clock.nanoTimestamp();
    if (phase_deadline <= now) return now;
    return now + @divTrunc(phase_deadline - now, @as(i128, @intCast(remaining)));
}

fn failed(routed: router.RouteResult, placement: optimizer.Placement, net_i: usize) bool {
    if (net_i >= placement.nets.len) return true;
    for (routed.failed) |name| if (std.mem.eql(u8, name, placement.nets[net_i].name)) return true;
    return false;
}

fn appendTrack(alloc: std.mem.Allocator, out: *std.ArrayList(SeedTrack), track: router.Track) std.mem.Allocator.Error!void {
    if (track.net < 0) return;
    try out.append(alloc, .{ .net = @intCast(track.net), .copper = .{
        .x1 = track.x1,
        .y1 = track.y1,
        .x2 = track.x2,
        .y2 = track.y2,
        .layer = track.layer,
        .width = track.width,
        .net = track.net,
    } });
}

fn appendVia(alloc: std.mem.Allocator, out: *std.ArrayList(SeedVia), via: router.Via) std.mem.Allocator.Error!void {
    if (via.net < 0) return;
    try out.append(alloc, .{ .net = @intCast(via.net), .copper = .{
        .x = via.x,
        .y = via.y,
        .dia = via.dia,
        .drill = via.drill,
        .net = via.net,
    } });
}

fn polygonContains(poly: []const [2]f64, x: f64, y: f64) bool {
    if (poly.len < 3) return false;
    var inside = false;
    var j = poly.len - 1;
    for (poly, 0..) |p, i| {
        const q = poly[j];
        if ((p[1] > y) != (q[1] > y)) {
            const cross = (q[0] - p[0]) * (y - p[1]) / (q[1] - p[1]) + p[0];
            if (x < cross) inside = !inside;
        }
        j = i;
    }
    return inside;
}

fn livePourAt(zones: []const route_policy.ExistingZone, net: i32, layer: u8, x: f64, y: f64) bool {
    for (zones) |zone| {
        if (!zone.copper or zone.net != net or zone.layer != layer) continue;
        if (!polygonContains(zone.polygon, x, y)) continue;
        var clipped = false;
        for (zones) |higher| {
            if (!higher.copper or higher.layer != layer or higher.net == net) continue;
            if (higher.priority <= zone.priority) continue;
            if (polygonContains(higher.polygon, x, y)) {
                clipped = true;
                break;
            }
        }
        if (!clipped) return true;
    }
    return false;
}

/// Supply terminals are independent carrier requests. Declared planes use the
/// ordinary plane pass with local loop bonds removed (which retains exposed-pad
/// arrays); one-pad plane nets and pour-backed pads use the public stitch hop.
/// Neither path can create a pad-to-pad power trace.
const DropContext = struct {
    alloc: std.mem.Allocator,
    local: optimizer.Placement,
    params: router.RouteParams,
    base: route_policy.Options,
    tracks: *std.ArrayList(SeedTrack),
    vias: *std.ArrayList(SeedVia),
    plane_ok: []bool,
};

fn surfacePins(
    alloc: std.mem.Allocator,
    net: optimizer.FlatNet,
    pts: []const router.NetPt,
) std.mem.Allocator.Error![]const export_kicad.FlatPin {
    var out: std.ArrayList(export_kicad.FlatPin) = .empty;
    for (net.pins) |pin| {
        for (pts) |pt| {
            if (!std.mem.eql(u8, pt.ref_des, pin.ref_des) or !std.mem.eql(u8, pt.pin, pin.pin)) continue;
            if (!pt.thru) try out.append(alloc, pin);
            break;
        }
    }
    return out.items;
}

fn carrierDrops(ctx: DropContext, selected: []const bool) std.mem.Allocator.Error!usize {
    const alloc = ctx.alloc;
    const local_in = ctx.local;
    const params = ctx.params;
    const base = ctx.base;
    var dropped: usize = 0;
    var idx_of = std.StringHashMapUnmanaged(usize).empty;
    for (local_in.parts, 0..) |part, i| try idx_of.put(alloc, part.ref_des, i);

    for (local_in.nets, 0..) |net, ni| {
        if (ni >= selected.len or !selected[ni]) continue;
        const pts = try router.netPoints(alloc, local_in, &idx_of, net);
        if (pts.len == 0) continue;
        if (router.netHasPlane(local_in, net.name) and pts.len != net.pins.len) ctx.plane_ok[ni] = false;
        const smd_pins = try surfacePins(alloc, net, pts);
        if (router.netHasPlane(local_in, net.name) and smd_pins.len >= 2) {
            var local = local_in;
            local.loops = &.{};
            const local_nets = try alloc.dupe(optimizer.FlatNet, local.nets);
            local_nets[ni].pins = smd_pins;
            local.nets = local_nets;
            const only = try alloc.alloc(bool, local.nets.len);
            @memset(only, false);
            only[ni] = true;
            const routed = try router.routeWithOptions(alloc, local, params, try localOptions(alloc, base, only));
            if (failed(routed, local, ni)) ctx.plane_ok[ni] = false;
            for (routed.tracks) |track| if (track.net == @as(i32, @intCast(ni))) try appendTrack(alloc, ctx.tracks, track);
            for (routed.vias) |via| if (via.net == @as(i32, @intCast(ni))) {
                try appendVia(alloc, ctx.vias, via);
                dropped += 1;
            };
            continue;
        }

        var gaps: std.ArrayList(router.Gap) = .empty;
        const face_pours = router.netPourLayers(local_in, net.name);
        for (pts) |pt| {
            // A through-hole is already a barrel. If no relevant carrier
            // crosses it, the global phase handles the net without drilling a
            // redundant local via beside it.
            if (pt.thru) continue;
            if (face_pours[pt.layer] or livePourAt(base.existing_zones, @intCast(ni), pt.layer, pt.x, pt.y)) continue;
            try gaps.append(alloc, .{ .net_i = ni, .from = pt });
        }
        if (gaps.items.len == 0) continue;
        // A stitch without a retained pour assumes a plane target, so never ask
        // it for an unplaned supply net unless an actual same-net pour exists.
        var has_pour = false;
        for (base.existing_zones) |zone| if (zone.copper and zone.net == @as(i32, @intCast(ni))) {
            has_pour = true;
            break;
        };
        if (!router.netHasPlane(local_in, net.name) and !has_pour) continue;
        const paths = try router.closeGaps(
            alloc,
            local_in,
            params,
            .{ .zones = base.existing_zones },
            gaps.items,
            .{ .ripup = false, .terminal_via = .smd_ok, .raster = .{ .stop = base.stop } },
        );
        for (paths) |maybe| {
            const path = maybe orelse {
                if (router.netHasPlane(local_in, net.name)) ctx.plane_ok[ni] = false;
                continue;
            };
            for (path.tracks) |track| try appendTrack(alloc, ctx.tracks, track);
            for (path.vias) |via| {
                try appendVia(alloc, ctx.vias, via);
                dropped += 1;
            }
        }
    }
    return dropped;
}

/// Route every first-level sub-circuit independently and concatenate its
/// parent-indexed copper. No run sees another sub-circuit's parts or copper.
pub fn routeAllClassified(
    alloc: std.mem.Allocator,
    block: *const env.DesignBlock,
    placement: optimizer.Placement,
    params: router.RouteParams,
    base: route_policy.Options,
    supply: []const bool,
) std.mem.Allocator.Error!Result {
    var tracks: std.ArrayList(SeedTrack) = .empty;
    var vias: std.ArrayList(SeedVia) = .empty;
    const nets = try alloc.alloc(bool, placement.nets.len);
    @memset(nets, false);
    const complete_planes = try alloc.alloc(bool, placement.nets.len);
    for (complete_planes, 0..) |*yes, ni| {
        yes.* = ni < supply.len and supply[ni] and router.netHasPlane(placement, placement.nets[ni].name);
    }

    var attempted: usize = 0;
    var completed: usize = 0;
    var timed_out: usize = 0;
    var carrier_drop_vias: usize = 0;
    const phase_deadline = localPhaseDeadline(base);

    for (block.sub_blocks, 0..) |sub, sub_i| {
        if (base.stop.cancel) |cancel| if (cancel.load(.monotonic)) break;
        attempted += 1;
        var sub_base = base;
        sub_base.stop.deadline_ns = sliceDeadline(phase_deadline, block.sub_blocks.len - sub_i);
        const local = (try localPlacement(alloc, placement, sub.name)) orelse {
            completed += 1;
            continue;
        };
        const selected = try selectedNets(alloc, placement, sub.name, sub_base, supply, false);
        if (!anySelected(selected)) {
            if (stopped(sub_base) and phase_deadline != 0) timed_out += 1 else completed += 1;
            continue;
        }
        const routed = try route_plan.routeLowered(alloc, local, params, try localOptions(alloc, sub_base, selected));
        if (routed.cancelled and stopped(sub_base)) {
            timed_out += 1;
            continue;
        }
        for (routed.tracks) |track| {
            if (track.net < 0) continue;
            const ni: usize = @intCast(track.net);
            if (ni >= nets.len or !selected[ni] or failed(routed, placement, ni)) continue;
            nets[ni] = true;
            try appendTrack(alloc, &tracks, track);
        }
        for (routed.vias) |via| {
            if (via.net < 0) continue;
            const ni: usize = @intCast(via.net);
            if (ni >= nets.len or !selected[ni] or failed(routed, placement, ni)) continue;
            nets[ni] = true;
            try appendVia(alloc, &vias, via);
        }
        completed += 1;
    }

    const selected_supply = try alloc.alloc(bool, placement.nets.len);
    for (selected_supply, 0..) |*yes, ni| {
        yes.* = ni < supply.len and supply[ni] and enabled(base, ni);
    }
    if (anySelected(selected_supply)) {
        var carrier_base = base;
        carrier_base.stop.deadline_ns = phase_deadline;
        const track_start = tracks.items.len;
        const via_start = vias.items.len;
        carrier_drop_vias += try carrierDrops(.{
            .alloc = alloc,
            .local = placement,
            .params = params,
            .base = carrier_base,
            .tracks = &tracks,
            .vias = &vias,
            .plane_ok = complete_planes,
        }, selected_supply);
        for (tracks.items[track_start..]) |track| {
            if (track.net < nets.len) nets[track.net] = true;
        }
        for (vias.items[via_start..]) |via| {
            if (via.net < nets.len) nets[via.net] = true;
        }
    }

    var deferred_supply: usize = 0;
    for (supply, complete_planes, 0..) |is_supply, complete, ni| {
        if (is_supply and enabled(base, ni) and !complete) deferred_supply += 1;
    }
    return .{
        .tracks = tracks.items,
        .vias = vias.items,
        .nets = nets,
        .complete_planes = complete_planes,
        .phase = .{
            .attempted_subcircuits = attempted,
            .completed_subcircuits = completed,
            .timed_out_subcircuits = timed_out,
            .deferred_supply_nets = deferred_supply,
            .carrier_drop_vias = carrier_drop_vias,
        },
    };
}

/// Compatibility spelling for callers that have not supplied the canonical
/// supply classification. It preserves the former all-signal local behavior;
/// authoritative board routing calls `routeAllClassified` instead.
pub fn routeAll(
    alloc: std.mem.Allocator,
    block: *const env.DesignBlock,
    placement: optimizer.Placement,
    params: router.RouteParams,
    base: route_policy.Options,
) std.mem.Allocator.Error!Result {
    const supply = try alloc.alloc(bool, placement.nets.len);
    @memset(supply, false);
    return routeAllClassified(alloc, block, placement, params, base, supply);
}

/// Compatibility helper retained for API stability. The authoritative route
/// pipeline no longer calls it or compares a second whole-board candidate.
pub fn regressed(
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
    params: router.RouteParams,
    seeded: router.RouteResult,
    plain: router.RouteResult,
) std.mem.Allocator.Error!bool {
    if (seeded.routed < plain.routed) return true;
    const seeded_errors = drc.errorCount(try drc.check(alloc, placement, seeded, params.clearance));
    const plain_errors = drc.errorCount(try drc.check(alloc, placement, plain, params.clearance));
    return seeded_errors > plain_errors;
}

const testing = std.testing;

// spec: serve/subcircuit-route - a sub-circuit routing view contains only its own components and uses their local bounds
test "isolated sub-circuit view removes every foreign component" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const Pad = std.meta.Child(@FieldType(optimizer.Part, "pads"));
    const pads = [_]Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.5, .h = 0.5 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "amp/U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "amp/R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads, .fallback = false, .x = 4, .y = 0 },
        .{ .ref_des = "other/U2", .kind = .hub, .hw = 6, .hh = 6, .pads = &pads, .fallback = false, .x = 80, .y = 70 },
    };
    const pins = [_]@import("../export_kicad.zig").FlatPin{
        .{ .ref_des = "amp/U1", .pin = "1" },
        .{ .ref_des = "amp/R1", .pin = "1" },
        .{ .ref_des = "other/U2", .pin = "1" },
    };
    const nets = [_]optimizer.FlatNet{.{ .name = "SHARED", .pins = &pins }};
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
        .maxx = 86,
        .maxy = 76,
        .generated = false,
    };

    const local = (try localPlacement(alloc, placement, "amp")) orelse return error.TestExpectedLocalPlacement;
    try testing.expectEqual(@as(usize, 2), local.parts.len);
    try testing.expectEqualStrings("amp/U1", local.parts[0].ref_des);
    try testing.expect(local.maxx < 10 and local.maxy < 10);
    const selected = try selectedNets(alloc, placement, "amp", .{}, &.{false}, false);
    // Boundary nets route their internal island now; the global pass joins the
    // third terminal after the isolated copper is frozen.
    try testing.expect(selected[0]);

    var child = env.DesignBlock{ .name = "amp", .instances = &.{}, .nets = &.{}, .ports = &.{}, .notes = &.{}, .groups = &.{}, .sub_blocks = &.{} };
    const subs = [_]env.SubBlock{.{ .name = "amp", .block = &child }};
    var board = env.DesignBlock{ .name = "board", .instances = &.{}, .nets = &.{}, .ports = &.{}, .notes = &.{}, .groups = &.{}, .sub_blocks = &subs };
    const routed = try routeAll(alloc, &board, placement, .{}, .{});
    try testing.expect(routed.nets[0]);
    try testing.expect(routed.tracks.len > 0);
}

// spec: serve/subcircuit-route - an unselected scoped net is never routed by a sub-circuit phase
test "isolated sub-circuit selection respects the caller's net scope" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const pins = [_]@import("../export_kicad.zig").FlatPin{
        .{ .ref_des = "amp/U1", .pin = "1" },
        .{ .ref_des = "amp/R1", .pin = "1" },
    };
    const nets = [_]optimizer.FlatNet{.{ .name = "LOCAL", .pins = &pins }};
    const scope = [_]bool{false};
    const placement = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 1,
        .maxy = 1,
        .generated = false,
    };
    const selected = try selectedNets(alloc, placement, "amp", .{ .selected_nets = &scope }, &.{false}, false);
    try testing.expect(!selected[0]);
}

// spec: Web Server - A hard route deadline gives all one-shot local sub-circuit attempts at most one quarter of the initially remaining time and preserves the original absolute deadline for the global phase
test "local phase cutoff reserves three quarters of a board deadline" {
    const now = clock.nanoTimestamp();
    const board_deadline = now + 400 * clock.ns_per_ms;
    const cutoff = localPhaseDeadline(.{ .stop = .{ .deadline_ns = board_deadline } });
    try testing.expect(cutoff > now);
    try testing.expect(cutoff <= now + 110 * clock.ns_per_ms);
    try testing.expect(board_deadline - cutoff >= 290 * clock.ns_per_ms);
}

// spec: Web Server - Supply-like ground, power, and input-rail nets never receive local pad-to-pad traces: declared planes and live retained pours receive independent terminal drops, while uncovered terminals remain for the global route
test "supply nets drop to a plane and unplaned supply waits for global routing" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const Pad = std.meta.Child(@FieldType(optimizer.Part, "pads"));
    const pads = [_]Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.7, .h = 0.7 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "power/C1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "power/U1", .kind = .hub, .hw = 0.5, .hh = 0.5, .pads = &pads, .fallback = false, .x = 4, .y = 0 },
    };
    const pins = [_]export_kicad.FlatPin{
        .{ .ref_des = "power/C1", .pin = "1" },
        .{ .ref_des = "power/U1", .pin = "1" },
    };
    const nets = [_]optimizer.FlatNet{.{ .name = "VCC", .pins = &pins }};
    var child = env.DesignBlock{ .name = "power", .instances = &.{}, .nets = &.{}, .ports = &.{}, .notes = &.{}, .groups = &.{}, .sub_blocks = &.{} };
    const subs = [_]env.SubBlock{.{ .name = "power", .block = &child }};
    var board = env.DesignBlock{ .name = "board", .instances = &.{}, .nets = &.{}, .ports = &.{}, .notes = &.{}, .groups = &.{}, .sub_blocks = &subs };
    var placement = optimizer.Placement{
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
        .rules = .{ .plane_nets = &.{"VCC"}, .copper_layers = 4 },
    };
    const planed = try routeAllClassified(alloc, &board, placement, .{}, .{}, &.{true});
    try testing.expect(planed.vias.len >= 2);
    try testing.expect(planed.complete_planes[0]);
    try testing.expectEqual(@as(usize, 0), planed.phase.deferred_supply_nets);
    for (planed.tracks) |track| {
        try testing.expect(std.math.hypot(track.copper.x2 - track.copper.x1, track.copper.y2 - track.copper.y1) < 2.0);
    }

    const thru_pads = [_]Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.7, .h = 0.7, .thru = true, .drill = 0.3 }};
    parts[0].pads = &thru_pads;
    parts[1].pads = &thru_pads;
    const thru = try routeAllClassified(alloc, &board, placement, .{}, .{}, &.{true});
    try testing.expectEqual(@as(usize, 0), thru.vias.len);
    try testing.expect(thru.complete_planes[0]);

    placement.rules = .{ .plane_nets = &.{}, .copper_layers = 2 };
    const deferred = try routeAllClassified(alloc, &board, placement, .{}, .{}, &.{true});
    try testing.expectEqual(@as(usize, 0), deferred.tracks.len);
    try testing.expectEqual(@as(usize, 0), deferred.vias.len);
    try testing.expect(!deferred.complete_planes[0]);
    try testing.expectEqual(@as(usize, 1), deferred.phase.deferred_supply_nets);
}

test "saved pour contact requires same-net copper that survives priority clipping" {
    const box = [_][2]f64{ .{ 0, 0 }, .{ 2, 0 }, .{ 2, 2 }, .{ 0, 2 } };
    const own = route_policy.ExistingZone{ .polygon = &box, .layer = 0, .net = 0, .priority = 1 };
    try testing.expect(livePourAt(&.{own}, 0, 0, 1, 1));
    const higher = route_policy.ExistingZone{ .polygon = &box, .layer = 0, .net = 1, .priority = 2 };
    try testing.expect(!livePourAt(&.{ own, higher }, 0, 0, 1, 1));
    const lower = route_policy.ExistingZone{ .polygon = &box, .layer = 0, .net = 1, .priority = 0 };
    try testing.expect(livePourAt(&.{ own, lower }, 0, 0, 1, 1));
}

// spec: Web Server - Hierarchical routing processes first-level sub-circuits in authored order, freezes each accepted DRC-clean local signal tree, and then runs exactly one assembled-board global candidate
test "local signal candidates preserve authored sub-circuit order" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const Pad = std.meta.Child(@FieldType(optimizer.Part, "pads"));
    const pads = [_]Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.5, .h = 0.5 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "first/A", .kind = .passive, .hw = 0.4, .hh = 0.4, .pads = &pads, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "first/B", .kind = .passive, .hw = 0.4, .hh = 0.4, .pads = &pads, .fallback = false, .x = 2, .y = 0 },
        .{ .ref_des = "second/A", .kind = .passive, .hw = 0.4, .hh = 0.4, .pads = &pads, .fallback = false, .x = 20, .y = 0 },
        .{ .ref_des = "second/B", .kind = .passive, .hw = 0.4, .hh = 0.4, .pads = &pads, .fallback = false, .x = 22, .y = 0 },
    };
    const second_pins = [_]export_kicad.FlatPin{
        .{ .ref_des = "second/A", .pin = "1" },
        .{ .ref_des = "second/B", .pin = "1" },
    };
    const first_pins = [_]export_kicad.FlatPin{
        .{ .ref_des = "first/A", .pin = "1" },
        .{ .ref_des = "first/B", .pin = "1" },
    };
    const nets = [_]optimizer.FlatNet{
        .{ .name = "SECOND", .pins = &second_pins },
        .{ .name = "FIRST", .pins = &first_pins },
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
        .maxx = 23,
        .maxy = 1,
        .generated = false,
        .rules = .{ .plane_nets = &.{}, .copper_layers = 2 },
    };
    var first = env.DesignBlock{ .name = "first", .instances = &.{}, .nets = &.{}, .ports = &.{}, .notes = &.{}, .groups = &.{}, .sub_blocks = &.{} };
    var second = env.DesignBlock{ .name = "second", .instances = &.{}, .nets = &.{}, .ports = &.{}, .notes = &.{}, .groups = &.{}, .sub_blocks = &.{} };
    const subs = [_]env.SubBlock{
        .{ .name = "first", .block = &first },
        .{ .name = "second", .block = &second },
    };
    var board = env.DesignBlock{ .name = "board", .instances = &.{}, .nets = &.{}, .ports = &.{}, .notes = &.{}, .groups = &.{}, .sub_blocks = &subs };
    const routed = try routeAllClassified(alloc, &board, placement, .{}, .{}, &.{ false, false });
    try testing.expectEqual(@as(usize, 2), routed.phase.attempted_subcircuits);
    try testing.expectEqual(@as(usize, 2), routed.phase.completed_subcircuits);
    try testing.expect(routed.tracks.len > 0);
    try testing.expectEqual(@as(usize, 1), routed.tracks[0].net);
}
