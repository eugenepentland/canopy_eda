//! Fabricated return-path integrity DRC for fast / explicitly-audited nets.
//!
//! Unlike the router's historical "signal via has a GND via nearby" count,
//! this check reads the board's physical stack, the winning net-class policy,
//! and the exact kept fill components already computed for Gerber/topology DRC.
//! It therefore sees a real split, slot, clipped pour, or dropped island.

const std = @import("std");
const drc = @import("drc.zig");
const optimizer = @import("optimizer.zig");
const router = @import("router.zig");
const copper_support = @import("copper_support.zig");
const outline = @import("outline.zig");
const flat_netlist = @import("../flat_netlist.zig");
const net_name = @import("../net_name.zig");
const numeric = @import("../numeric.zig");

pub const default_stitch_radius_mm: f64 = 2.0;
const sample_step_mm: f64 = 0.1;
const contact_eps_mm: f64 = 0.03;

const Reference = struct {
    stack: u8,
    net: []const u8,
    height_mm: f64,
};

fn sameName(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b) or
        std.ascii.eqlIgnoreCase(net_name.leaf(a), net_name.leaf(b));
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1)
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    return false;
}

fn audited(rule: optimizer.NetRule) bool {
    return rule.return_path.declared or rule.rf.max_freq_hz > 0 or
        rule.rf.impedance.ohms > 0 or rule.rf.impedance.diff_ohms > 0;
}

fn separationMm(placement: optimizer.Placement, a: u8, b: u8) f64 {
    const stack = placement.rules.physical.stack;
    const lo = @min(a, b);
    const hi = @max(a, b);
    var h: f64 = 0;
    var i = lo;
    while (i < hi) : (i += 1) {
        h += stack.gapMm(i);
        if (i + 1 < hi) h += stack.foilMm(i + 1);
    }
    return h;
}

fn referenceFor(placement: optimizer.Placement, rule: optimizer.NetRule, signal_layer: u8) ?Reference {
    if (!placement.rules.declaredStackup()) return null;
    const signal_stack = placement.rules.signalStackIndex(signal_layer);
    var best: ?Reference = null;
    var best_h = std.math.inf(f64);
    for (placement.rules.planes.declared) |plane| {
        if (plane.index == signal_stack) continue;
        if (rule.return_path.reference_net.len > 0 and !sameName(plane.net, rule.return_path.reference_net)) continue;
        const h = separationMm(placement, signal_stack, plane.index);
        if (!(h > 0) or h >= best_h) continue;
        best_h = h;
        best = .{ .stack = plane.index, .net = plane.net, .height_mm = h };
    }
    return best;
}

fn zoneContains(zone: copper_support.Zone, x: f64, y: f64) bool {
    if (!outline.contains(zone.poly, x, y)) return false;
    for (zone.holes) |hole| if (outline.contains(hole, x, y)) return false;
    return true;
}

fn referenceCopperAt(zones: []const copper_support.Zone, ref: Reference, x: f64, y: f64) bool {
    for (zones) |zone| {
        if (zone.stack != ref.stack or !sameName(zone.net, ref.net)) continue;
        if (zoneContains(zone, x, y)) return true;
    }
    return false;
}

fn ownViaAperture(routed: router.RouteResult, track: router.Track, x: f64, y: f64, placement: optimizer.Placement) bool {
    for (routed.vias) |via| {
        if (via.net != track.net) continue;
        const gap = placement.rules.design.referencePlaneClearance();
        if (std.math.hypot(x - via.x, y - via.y) <= via.dia / 2 + gap + sample_step_mm) return true;
    }
    return false;
}

const MissingRun = struct { length: f64 = 0, x: f64 = 0, y: f64 = 0 };

/// Longest unsupported run along one routed segment. The signal via's own
/// unavoidable antipad is excluded; its reference handoff is audited by the
/// transition rule below.
fn missingRun(
    placement: optimizer.Placement,
    routed: router.RouteResult,
    zones: []const copper_support.Zone,
    track: router.Track,
    ref: Reference,
) MissingRun {
    const dx = track.x2 - track.x1;
    const dy = track.y2 - track.y1;
    const len = std.math.hypot(dx, dy);
    if (!(len > 0)) return .{};
    const n: usize = @max(1, numeric.toCount(@ceil(len / sample_step_mm)));
    const step = len / @as(f64, @floatFromInt(n));
    var best = MissingRun{};
    var current: f64 = 0;
    var first_t: f64 = 0;
    for (0..n) |i| {
        const t = (@as(f64, @floatFromInt(i)) + 0.5) / @as(f64, @floatFromInt(n));
        const x = track.x1 + dx * t;
        const y = track.y1 + dy * t;
        const supported = ownViaAperture(routed, track, x, y, placement) or referenceCopperAt(zones, ref, x, y);
        if (supported) {
            current = 0;
            continue;
        }
        if (current == 0) first_t = t;
        current += step;
        if (current <= best.length) continue;
        const mid_t = (first_t + t) / 2;
        best = .{ .length = current, .x = track.x1 + dx * mid_t, .y = track.y1 + dy * mid_t };
    }
    return best;
}

fn appendPlaneGaps(
    arena: std.mem.Allocator,
    out: *std.ArrayList(drc.Violation),
    placement: optimizer.Placement,
    routed: router.RouteResult,
    zones: []const copper_support.Zone,
) std.mem.Allocator.Error!void {
    for (routed.tracks, 0..) |track, track_i| {
        if (track.net < 0) continue;
        const ni: usize = @intCast(track.net);
        if (ni >= placement.rules.net.len or !audited(placement.rules.net[ni])) continue;
        const ref = referenceFor(placement, placement.rules.net[ni], track.layer) orelse {
            try out.append(arena, .{
                .x = (track.x1 + track.x2) / 2,
                .y = (track.y1 + track.y2) / 2,
                .gap = std.math.hypot(track.x2 - track.x1, track.y2 - track.y1),
                .clearance = 0,
                .kind = .reference_plane_gap,
                .severity = drc.defaultSeverity(.reference_plane_gap),
                .who = .{ .net_a = track.net, .track_a = drc.partyIndex(track_i) },
                .layer = .of(track.layer),
            });
            continue;
        };
        const missing = missingRun(placement, routed, zones, track, ref);
        if (missing.length <= sample_step_mm / 2) continue;
        try out.append(arena, .{
            .x = missing.x,
            .y = missing.y,
            .gap = missing.length,
            .clearance = 0,
            .kind = .reference_plane_gap,
            .severity = drc.defaultSeverity(.reference_plane_gap),
            .who = .{ .net_a = track.net, .track_a = drc.partyIndex(track_i) },
            .layer = .of(track.layer),
        });
    }
}

fn layerMaskAtVia(routed: router.RouteResult, via: router.Via) u64 {
    var mask: u64 = 0;
    for (routed.tracks) |track| {
        if (track.net != via.net or track.layer >= 64) continue;
        const reach = via.dia / 2 + track.width / 2 + contact_eps_mm;
        const a = std.math.hypot(track.x1 - via.x, track.y1 - via.y);
        const b = std.math.hypot(track.x2 - via.x, track.y2 - via.y);
        if (@min(a, b) <= reach) mask |= @as(u64, 1) << @intCast(track.layer);
    }
    return mask;
}

fn netName(placement: optimizer.Placement, ni: i32) ?[]const u8 {
    if (ni < 0 or @as(usize, @intCast(ni)) >= placement.nets.len) return null;
    return placement.nets[@intCast(ni)].name;
}

fn nearestReferenceVia(placement: optimizer.Placement, routed: router.RouteResult, at: router.Via, reference_net: []const u8) f64 {
    var nearest = std.math.inf(f64);
    for (routed.vias) |via| {
        const name = netName(placement, via.net) orelse continue;
        if (!sameName(name, reference_net)) continue;
        nearest = @min(nearest, std.math.hypot(via.x - at.x, via.y - at.y));
    }
    return nearest;
}

fn partIsCap(placement: optimizer.Placement, part_i: usize) bool {
    const leaf = net_name.leaf(placement.parts[part_i].ref_des);
    if (leaf.len > 0 and (leaf[0] == 'C' or leaf[0] == 'c')) return true;
    if (part_i >= placement.instances.len) return false;
    return containsIgnoreCase(placement.instances[part_i].component, "cap");
}

fn partTouchesNet(placement: optimizer.Placement, ref_des: []const u8, wanted: []const u8) bool {
    for (placement.nets) |net| {
        if (!sameName(net.name, wanted)) continue;
        for (net.pins) |pin| if (std.ascii.eqlIgnoreCase(pin.ref_des, ref_des)) return true;
    }
    return false;
}

fn nearestStitchCap(placement: optimizer.Placement, at: router.Via, a: []const u8, b: []const u8) f64 {
    var nearest = std.math.inf(f64);
    for (placement.parts, 0..) |part, i| {
        if (!partIsCap(placement, i)) continue;
        if (!partTouchesNet(placement, part.ref_des, a) or !partTouchesNet(placement, part.ref_des, b)) continue;
        nearest = @min(nearest, std.math.hypot(part.x - at.x, part.y - at.y));
    }
    return nearest;
}

fn appendTransitions(
    arena: std.mem.Allocator,
    out: *std.ArrayList(drc.Violation),
    placement: optimizer.Placement,
    routed: router.RouteResult,
) std.mem.Allocator.Error!void {
    for (routed.vias) |via| {
        if (via.net < 0) continue;
        const ni: usize = @intCast(via.net);
        if (ni >= placement.rules.net.len or !audited(placement.rules.net[ni])) continue;
        const rule = placement.rules.net[ni];
        const mask = layerMaskAtVia(routed, via);
        if (@popCount(mask) < 2) continue;
        var first: ?Reference = null;
        var changed: ?Reference = null;
        var bits = mask;
        while (bits != 0) {
            const layer: u8 = @intCast(@ctz(bits));
            bits &= bits - 1;
            const ref = referenceFor(placement, rule, layer) orelse continue;
            if (first == null) first = ref else if (first.?.stack != ref.stack) {
                changed = ref;
                break;
            }
        }
        const a = first orelse continue;
        const b = changed orelse continue;
        const radius = if (rule.return_path.stitch_radius_mm > 0) rule.return_path.stitch_radius_mm else default_stitch_radius_mm;
        const nearest = if (sameName(a.net, b.net))
            nearestReferenceVia(placement, routed, via, a.net)
        else
            nearestStitchCap(placement, via, a.net, b.net);
        if (nearest <= radius) continue;
        try out.append(arena, .{
            .x = via.x,
            .y = via.y,
            .gap = if (std.math.isFinite(nearest)) nearest else radius + 0.001,
            .clearance = radius,
            .kind = .reference_transition,
            .severity = drc.defaultSeverity(.reference_transition),
            .who = .{ .net_a = via.net },
        });
    }
}

fn appendLoopAreas(
    arena: std.mem.Allocator,
    out: *std.ArrayList(drc.Violation),
    placement: optimizer.Placement,
    routed: router.RouteResult,
) std.mem.Allocator.Error!void {
    for (placement.rules.net, 0..) |rule, ni| {
        const limit = rule.return_path.max_loop_area_mm2;
        if (!(limit > 0)) continue;
        var area: f64 = 0;
        var longest: ?router.Track = null;
        var longest_len: f64 = 0;
        for (routed.tracks) |track| {
            if (track.net != @as(i32, @intCast(ni))) continue;
            const ref = referenceFor(placement, rule, track.layer) orelse continue;
            const len = std.math.hypot(track.x2 - track.x1, track.y2 - track.y1);
            area += len * ref.height_mm;
            if (len > longest_len) {
                longest_len = len;
                longest = track;
            }
        }
        if (area <= limit or longest == null) continue;
        const track = longest.?;
        try out.append(arena, .{
            .x = (track.x1 + track.x2) / 2,
            .y = (track.y1 + track.y2) / 2,
            .gap = area,
            .clearance = limit,
            .kind = .loop_area,
            .severity = drc.defaultSeverity(.loop_area),
            .who = .{ .net_a = @intCast(ni) },
            .layer = .of(track.layer),
        });
    }
}

/// Append the three return-path rule families. No declared stackup means no
/// trustworthy reference geometry, so legacy boards remain byte-identical.
pub fn check(
    arena: std.mem.Allocator,
    out: *std.ArrayList(drc.Violation),
    placement: optimizer.Placement,
    routed: router.RouteResult,
    zones: []const copper_support.Zone,
) std.mem.Allocator.Error!void {
    if (!placement.rules.declaredStackup() or placement.rules.net.len == 0) return;
    try appendPlaneGaps(arena, out, placement, routed, zones);
    try appendTransitions(arena, out, placement, routed);
    try appendLoopAreas(arena, out, placement, routed);
}

fn testPlacement(rules: []const optimizer.NetRule, planes: []const optimizer.PlaneAt) optimizer.Placement {
    const nets = &[_]optimizer.FlatNet{
        .{ .name = "FAST", .pins = &.{} },
        .{ .name = "GND", .pins = &.{} },
    };
    return .{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 },
        .rules = .{
            .plane_nets = &.{ "GND", "GND" },
            .net = rules,
            .copper_layers = 4,
            .planes = .{ .declared = planes },
            .physical = .{ .stack = .{ .layers = 4, .planes = &.{ 2, 3 }, .board_mm = 1.6 } },
        },
    };
}

fn countKind(list: []const drc.Violation, kind: drc.Kind) usize {
    var count: usize = 0;
    for (list) |v| {
        if (v.kind == kind) count += 1;
    }
    return count;
}

fn firstKind(list: []const drc.Violation, kind: drc.Kind) ?drc.Violation {
    for (list) |v| {
        if (v.kind == kind) return v;
    }
    return null;
}

const full_plane = [_][2]f64{ .{ 0, 0 }, .{ 10, 0 }, .{ 10, 10 }, .{ 0, 10 } };

test "fast trace crossing a reference-plane slot is flagged" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const planes = [_]optimizer.PlaneAt{ .{ .index = 2, .net = "GND" }, .{ .index = 3, .net = "GND" } };
    const rules = [_]optimizer.NetRule{ .{ .rf = .{ .max_freq_hz = 100e6 } }, .{} };
    const placement = testPlacement(&rules, &planes);
    const hole = [_][2]f64{ .{ 4, 0 }, .{ 6, 0 }, .{ 6, 10 }, .{ 4, 10 } };
    const zones = [_]copper_support.Zone{
        .{ .net = "GND", .layer = 0, .stack = 2, .poly = &full_plane, .holes = &.{&hole}, .component = 1, .plane = true },
        .{ .net = "GND", .layer = 0, .stack = 3, .poly = &full_plane, .component = 2, .plane = true },
    };
    const tracks = [_]router.Track{.{ .x1 = 1, .y1 = 5, .x2 = 9, .y2 = 5, .layer = 0, .width = 0.2, .net = 0 }};
    const routed = router.RouteResult{ .tracks = &tracks, .vias = &.{}, .routed = 1, .total = 1 };
    var out: std.ArrayList(drc.Violation) = .empty;
    try check(arena, &out, placement, routed, &zones);
    try std.testing.expectEqual(@as(usize, 1), countKind(out.items, .reference_plane_gap));
    try std.testing.expectEqual(drc.Severity.warn, firstKind(out.items, .reference_plane_gap).?.severity);
}

test "reference-plane change needs a same-net stitching via" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const planes = [_]optimizer.PlaneAt{ .{ .index = 2, .net = "GND" }, .{ .index = 3, .net = "GND" } };
    const rules = [_]optimizer.NetRule{ .{ .return_path = .{ .declared = true, .stitch_radius_mm = 1 } }, .{} };
    const placement = testPlacement(&rules, &planes);
    const zones = [_]copper_support.Zone{
        .{ .net = "GND", .layer = 0, .stack = 2, .poly = &full_plane, .component = 1, .plane = true },
        .{ .net = "GND", .layer = 0, .stack = 3, .poly = &full_plane, .component = 2, .plane = true },
    };
    const tracks = [_]router.Track{
        .{ .x1 = 1, .y1 = 5, .x2 = 5, .y2 = 5, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 5, .y1 = 5, .x2 = 9, .y2 = 5, .layer = 1, .width = 0.2, .net = 0 },
    };
    const bare_vias = [_]router.Via{.{ .x = 5, .y = 5, .dia = 0.4, .drill = 0.2, .net = 0 }};
    const bare = router.RouteResult{ .tracks = &tracks, .vias = &bare_vias, .routed = 1, .total = 1 };
    var missing: std.ArrayList(drc.Violation) = .empty;
    try check(arena, &missing, placement, bare, &zones);
    try std.testing.expectEqual(@as(usize, 1), countKind(missing.items, .reference_transition));
    try std.testing.expectEqual(drc.Severity.warn, firstKind(missing.items, .reference_transition).?.severity);

    const stitched_vias = [_]router.Via{
        .{ .x = 5, .y = 5, .dia = 0.4, .drill = 0.2, .net = 0 },
        .{ .x = 5.5, .y = 5, .dia = 0.4, .drill = 0.2, .net = 1 },
    };
    const stitched = router.RouteResult{ .tracks = &tracks, .vias = &stitched_vias, .routed = 1, .total = 1 };
    var served: std.ArrayList(drc.Violation) = .empty;
    try check(arena, &served, placement, stitched, &zones);
    try std.testing.expectEqual(@as(usize, 0), countKind(served.items, .reference_transition));
}

test "different reference nets need a nearby stitching capacitor" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const planes = [_]optimizer.PlaneAt{ .{ .index = 2, .net = "GND" }, .{ .index = 3, .net = "AGND" } };
    const rules = [_]optimizer.NetRule{ .{ .return_path = .{ .declared = true, .stitch_radius_mm = 1 } }, .{}, .{} };
    var placement = testPlacement(&rules, &planes);
    const gnd_pins = [_]flat_netlist.FlatPin{.{ .ref_des = "C1", .pin = "1" }};
    const agnd_pins = [_]flat_netlist.FlatPin{.{ .ref_des = "C1", .pin = "2" }};
    const nets = [_]optimizer.FlatNet{
        .{ .name = "FAST", .pins = &.{} },
        .{ .name = "GND", .pins = &gnd_pins },
        .{ .name = "AGND", .pins = &agnd_pins },
    };
    placement.nets = &nets;
    const zones = [_]copper_support.Zone{
        .{ .net = "GND", .layer = 0, .stack = 2, .poly = &full_plane, .component = 1, .plane = true },
        .{ .net = "AGND", .layer = 0, .stack = 3, .poly = &full_plane, .component = 2, .plane = true },
    };
    const tracks = [_]router.Track{
        .{ .x1 = 1, .y1 = 5, .x2 = 5, .y2 = 5, .layer = 0, .width = 0.2, .net = 0 },
        .{ .x1 = 5, .y1 = 5, .x2 = 9, .y2 = 5, .layer = 1, .width = 0.2, .net = 0 },
    };
    const vias = [_]router.Via{.{ .x = 5, .y = 5, .dia = 0.4, .drill = 0.2, .net = 0 }};
    const routed = router.RouteResult{ .tracks = &tracks, .vias = &vias, .routed = 1, .total = 1 };
    var missing: std.ArrayList(drc.Violation) = .empty;
    try check(arena, &missing, placement, routed, &zones);
    try std.testing.expectEqual(@as(usize, 1), countKind(missing.items, .reference_transition));

    var caps = [_]optimizer.Part{.{
        .ref_des = "C1",
        .kind = .passive,
        .hw = 0.5,
        .hh = 0.25,
        .pads = &.{},
        .fallback = false,
        .x = 5.5,
        .y = 5,
    }};
    placement.parts = &caps;
    var served: std.ArrayList(drc.Violation) = .empty;
    try check(arena, &served, placement, routed, &zones);
    try std.testing.expectEqual(@as(usize, 0), countKind(served.items, .reference_transition));
}

test "return-path loop area is estimated against the authored budget" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const planes = [_]optimizer.PlaneAt{ .{ .index = 2, .net = "GND" }, .{ .index = 3, .net = "GND" } };
    const rules = [_]optimizer.NetRule{ .{ .return_path = .{ .declared = true, .max_loop_area_mm2 = 0.5 } }, .{} };
    const placement = testPlacement(&rules, &planes);
    const zones = [_]copper_support.Zone{.{ .net = "GND", .layer = 0, .stack = 2, .poly = &full_plane, .component = 1, .plane = true }};
    const tracks = [_]router.Track{.{ .x1 = 1, .y1 = 5, .x2 = 9, .y2 = 5, .layer = 0, .width = 0.2, .net = 0 }};
    const routed = router.RouteResult{ .tracks = &tracks, .vias = &.{}, .routed = 1, .total = 1 };
    var out: std.ArrayList(drc.Violation) = .empty;
    try check(arena, &out, placement, routed, &zones);
    try std.testing.expectEqual(@as(usize, 1), countKind(out.items, .loop_area));
    const area = firstKind(out.items, .loop_area).?;
    try std.testing.expect(area.gap > area.clearance);
    try std.testing.expectEqual(drc.Severity.warn, area.severity);
}
