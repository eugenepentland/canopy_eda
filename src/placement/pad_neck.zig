//! Pad-local neck-down and taper shaping for generated copper.
//!
//! A net class may keep a wide nominal trunk while authorizing a short narrow
//! escape at SMD lands. The router searches the centreline with its nominal
//! class geometry. At the final output boundary this pass subdivides
//! pad-ended straight segments into
//! fabrication-real constant-width slices: a narrow run, then a monotonic
//! approximation of the authored linear taper, then the untouched trunk.
//!
//! Constant-width slices are intentional. They are understood identically by
//! the route viewer, DRC, Gerber writer, KiCad writer, and saved-layout schema;
//! a 25 um slice pitch makes the union visually smooth without adding a second
//! copper primitive whose clearance and persistence could drift.

const std = @import("std");
const flat_netlist = @import("../flat_netlist.zig");
const optimizer = @import("optimizer.zig");
const router = @import("router.zig");

const eps: f64 = 1e-9;
const taper_step_mm: f64 = 0.025;
const default_neck_length_mm: f64 = 0.75;
const default_taper_length_mm: f64 = 0.35;

const Pad = struct { at: [2]f64, layer: u8 };

fn dist(a: [2]f64, b: [2]f64) f64 {
    return std.math.hypot(b[0] - a[0], b[1] - a[1]);
}

fn samePoint(a: [2]f64, b: [2]f64) bool {
    return dist(a, b) <= router.clearance_eps;
}

fn profileWidth(distance: f64, neck: f64, nominal: f64, neck_len: f64, taper_len: f64) f64 {
    if (distance <= neck_len or taper_len <= eps) return neck;
    if (distance >= neck_len + taper_len) return nominal;
    const f = (distance - neck_len) / taper_len;
    return neck + (nominal - neck) * std.math.clamp(f, 0, 1);
}

fn endpointPad(pads: []const Pad, point: [2]f64, layer: u8) bool {
    for (pads) |pad| if (pad.layer == layer and samePoint(pad.at, point)) return true;
    return false;
}

fn netPads(arena: std.mem.Allocator, placement: optimizer.Placement, net: i32) std.mem.Allocator.Error![]const Pad {
    var out: std.ArrayList(Pad) = .empty;
    for (placement.nets[@intCast(net)].pins) |pin| {
        for (placement.parts) |part| {
            if (!std.mem.eql(u8, part.ref_des, pin.ref_des)) continue;
            for (part.pads) |pad| {
                if (!std.mem.eql(u8, pad.number, pin.pin) or pad.thru) continue;
                try out.append(arena, .{
                    .at = optimizer.worldPadCenter(&part, pad.x, pad.y),
                    .layer = if (part.side == .bottom) 1 else 0,
                });
            }
        }
    }
    return out.items;
}

/// Whether an under-nominal segment is exactly inside this net class's
/// authored pad-neck envelope. DRC uses this instead of trusting provenance:
/// restored and hand-authored copper earns the exception only by satisfying
/// the same width and pad-distance profile the generator emits.
pub fn allowsTrack(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    track: router.Track,
    nominal: f64,
    fab_min_width: f64,
) std.mem.Allocator.Error!bool {
    if (track.net < 0) return false;
    const ni: usize = @intCast(track.net);
    if (ni >= placement.nets.len or ni >= placement.rules.net.len) return false;
    const profile = placement.rules.net[ni].pad_neck;
    const neck = @max(profile.width, fab_min_width);
    if (!(profile.width > 0) or neck >= nominal - eps or track.width < neck - eps) return false;
    const neck_len = if (profile.max_length > 0) profile.max_length else default_neck_length_mm;
    const taper_len = if (profile.taper_length > 0) profile.taper_length else default_taper_length_mm;
    const total = neck_len + taper_len;
    const a = [2]f64{ track.x1, track.y1 };
    const b = [2]f64{ track.x2, track.y2 };
    for (try netPads(arena, placement, track.net)) |pad| {
        if (pad.layer != track.layer) continue;
        const da = dist(pad.at, a);
        const db = dist(pad.at, b);
        if (da > total + taper_step_mm + eps or db > total + taper_step_mm + eps) continue;
        const required = profileWidth(@max(da, db), neck, nominal, neck_len, taper_len);
        if (track.width + eps >= required) return true;
    }
    return false;
}

const Shape = struct {
    track: router.Track,
    at_start: bool,
    at_end: bool,
    nominal: f64,
    neck: f64,
    neck_len: f64,
    taper_len: f64,
};

fn localWidth(s: f64, len: f64, shape: Shape) f64 {
    var width = shape.nominal;
    if (shape.at_start) width = @min(width, profileWidth(s, shape.neck, shape.nominal, shape.neck_len, shape.taper_len));
    if (shape.at_end) width = @min(width, profileWidth(len - s, shape.neck, shape.nominal, shape.neck_len, shape.taper_len));
    return width;
}

fn routedNominal(placement: optimizer.Placement, ni: usize, track_width: f64) ?f64 {
    const rule = if (ni < placement.rules.net.len) placement.rules.net[ni] else optimizer.NetRule{};
    const authored = if (rule.width > 0) rule.width else placement.rules.design.track_width;
    if (@abs(track_width - authored) <= router.clearance_eps) return authored;
    const widened = @max(authored, placement.rules.powerWidthForNet(placement.nets[ni].name) orelse 0);
    return if (@abs(track_width - widened) <= router.clearance_eps) widened else null;
}

fn appendSlice(arena: std.mem.Allocator, out: *std.ArrayList(router.Track), shape: Shape, s0: f64, s1: f64, len: f64) std.mem.Allocator.Error!void {
    if (s1 - s0 <= eps) return;
    const t = shape.track;
    const ux = (t.x2 - t.x1) / len;
    const uy = (t.y2 - t.y1) / len;
    // The wider endpoint makes each capsule a conservative outer approximation
    // of the linear taper, still bounded by the nominal cleared envelope.
    const width = @max(localWidth(s0, len, shape), localWidth(s1, len, shape));
    try out.append(arena, .{
        .x1 = t.x1 + ux * s0,
        .y1 = t.y1 + uy * s0,
        .x2 = t.x1 + ux * s1,
        .y2 = t.y1 + uy * s1,
        .layer = t.layer,
        .width = width,
        .net = t.net,
    });
}

fn shapeTrack(arena: std.mem.Allocator, out: *std.ArrayList(router.Track), shape: Shape) std.mem.Allocator.Error!void {
    const t = shape.track;
    const len = std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
    if (len <= eps) return;
    const shaped_span = shape.neck_len + shape.taper_len;
    var cuts: std.ArrayList(f64) = .empty;
    try cuts.append(arena, 0);
    try cuts.append(arena, len);
    for ([_]bool{ shape.at_start, shape.at_end }, 0..) |active, end| {
        if (!active) continue;
        const origin: f64 = if (end == 0) 0 else len;
        const sign: f64 = if (end == 0) 1 else -1;
        const neck_cut = origin + sign * @min(shape.neck_len, len);
        if (neck_cut > eps and neck_cut < len - eps) try cuts.append(arena, neck_cut);
        var d = shape.neck_len + taper_step_mm;
        while (d < shaped_span - eps and d < len - eps) : (d += taper_step_mm) {
            const cut = origin + sign * d;
            if (cut > eps and cut < len - eps) try cuts.append(arena, cut);
        }
        const end_cut = origin + sign * @min(shaped_span, len);
        if (end_cut > eps and end_cut < len - eps) try cuts.append(arena, end_cut);
    }
    std.mem.sort(f64, cuts.items, {}, std.sort.asc(f64));
    var prior = cuts.items[0];
    for (cuts.items[1..]) |cut| {
        if (cut - prior <= eps) continue;
        try appendSlice(arena, out, shape, prior, cut, len);
        prior = cut;
    }
}

/// Shape every selected generated net that declares a pad-local neck.
pub fn passBoard(board: router.CleanupBoard) std.mem.Allocator.Error!void {
    const arena = board.ctx.arena;
    var out: std.ArrayList(router.Track) = .empty;
    const pads_by_net = try arena.alloc([]const Pad, board.placement.nets.len);
    const pads_known = try arena.alloc(bool, board.placement.nets.len);
    @memset(pads_known, false);
    var changed = false;
    for (board.tracks.items) |track| {
        if (track.net < 0 or @as(usize, @intCast(track.net)) >= board.placement.nets.len) {
            try out.append(arena, track);
            continue;
        }
        const ni: usize = @intCast(track.net);
        if (board.ctx.selected_nets.len > 0 and (ni >= board.ctx.selected_nets.len or !board.ctx.selected_nets[ni])) {
            try out.append(arena, track);
            continue;
        }
        const rule = if (ni < board.placement.rules.net.len) board.placement.rules.net[ni] else optimizer.NetRule{};
        const nominal = routedNominal(board.placement, ni, track.width) orelse {
            try out.append(arena, track);
            continue;
        };
        const neck = @max(rule.pad_neck.width, board.placement.rules.design.min_width);
        if (!(rule.pad_neck.width > 0) or neck >= nominal - eps) {
            try out.append(arena, track);
            continue;
        }
        if (!pads_known[ni]) {
            pads_by_net[ni] = try netPads(arena, board.placement, track.net);
            pads_known[ni] = true;
        }
        const pads = pads_by_net[ni];
        const at_start = endpointPad(pads, .{ track.x1, track.y1 }, track.layer);
        const at_end = endpointPad(pads, .{ track.x2, track.y2 }, track.layer);
        if (!at_start and !at_end) {
            try out.append(arena, track);
            continue;
        }
        try shapeTrack(arena, &out, .{
            .track = track,
            .at_start = at_start,
            .at_end = at_end,
            .nominal = nominal,
            .neck = neck,
            .neck_len = if (rule.pad_neck.max_length > 0) rule.pad_neck.max_length else default_neck_length_mm,
            .taper_len = if (rule.pad_neck.taper_length > 0) rule.pad_neck.taper_length else default_taper_length_mm,
        });
        changed = true;
    }
    if (!changed) return;
    board.tracks.clearRetainingCapacity();
    try board.tracks.appendSlice(arena, out.items);
    router.copperCompacted(board.ctx);
}

const testing = std.testing;

test "pad neck slices form a monotonic taper without exceeding nominal width" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(router.Track) = .empty;
    const track = router.Track{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.2532, .net = 0 };
    try shapeTrack(arena, &out, .{ .track = track, .at_start = true, .at_end = false, .nominal = 0.2532, .neck = 0.1524, .neck_len = 0.75, .taper_len = 0.35 });
    try testing.expect(out.items.len > 10);
    try testing.expectEqual(@as(f64, 0.1524), out.items[0].width);
    var prior = out.items[0].width;
    for (out.items) |slice| {
        try testing.expect(slice.width + eps >= prior);
        try testing.expect(slice.width <= 0.2532 + eps);
        prior = slice.width;
    }
    try testing.expectApproxEqAbs(@as(f64, 0.2532), out.items[out.items.len - 1].width, eps);
}

test "overlapping endpoint profiles keep a short pad to pad hop narrow" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(router.Track) = .empty;
    const track = router.Track{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .layer = 0, .width = 0.2532, .net = 0 };
    try shapeTrack(arena, &out, .{ .track = track, .at_start = true, .at_end = true, .nominal = 0.2532, .neck = 0.1524, .neck_len = 0.75, .taper_len = 0.35 });
    for (out.items) |slice| try testing.expectApproxEqAbs(@as(f64, 0.1524), slice.width, eps);
}

test "DRC allowance accepts only neck-profile copper beside its own SMD pad" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pads = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.25, .h = 0.6 }};
    var parts = [_]optimizer.Part{.{
        .ref_des = "U1",
        .kind = .hub,
        .hw = 1,
        .hh = 1,
        .pads = &pads,
        .fallback = false,
    }};
    const pins = [_]flat_netlist.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
    const nets = [_]flat_netlist.FlatNet{.{ .name = "VDD", .pins = &pins }};
    const rules = [_]optimizer.NetRule{.{
        .width = 0.2532,
        .pad_neck = .{ .width = 0.1524, .max_length = 0.75, .taper_length = 0.35 },
    }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .rules = .{ .net = &rules, .design = .{ .track_width = 0.127, .min_width = 0.127 } },
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = -2,
        .maxx = 2,
        .maxy = 2,
        .generated = true,
    };
    const near = router.Track{ .x1 = 0, .y1 = 0, .x2 = 0.5, .y2 = 0, .layer = 0, .width = 0.1524, .net = 0 };
    const far = router.Track{ .x1 = 1.5, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.1524, .net = 0 };
    try testing.expect(try allowsTrack(arena, placement, near, 0.2532, 0.127));
    try testing.expect(!try allowsTrack(arena, placement, far, 0.2532, 0.127));
}

test "pad neck recognizes a power-capacity widened routed trunk" {
    const foils = [_]@import("impedance.zig").Foil{
        .{ .index = 1, .thickness_mm = 0.035 },
        .{ .index = 2, .thickness_mm = 0.0152 },
        .{ .index = 3, .thickness_mm = 0.0152 },
        .{ .index = 4, .thickness_mm = 0.035 },
    };
    const rails = [_]@import("../eval/power_budget.zig").Rail{.{
        .net = "VDD",
        .load_max_a = 0.34,
        .any_max_load = true,
        .status = .no_source,
    }};
    const nets = [_]flat_netlist.FlatNet{.{ .name = "VDD", .pins = &.{} }};
    const rules = [_]optimizer.NetRule{.{
        .width = 0.2532,
        .pad_neck = .{ .width = 0.1524, .max_length = 0.75, .taper_length = 0.35 },
    }};
    const placement = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .rules = .{ .net = &rules, .physical = .{ .stack = .{ .layers = 4, .foils = &foils }, .rails = &rails } },
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 1,
        .maxy = 1,
        .generated = true,
    };
    const widened = placement.rules.powerWidthForNet("VDD").?;
    try testing.expect(widened > rules[0].width);
    try testing.expectApproxEqAbs(widened, routedNominal(placement, 0, widened).?, eps);
    try testing.expectApproxEqAbs(rules[0].width, routedNominal(placement, 0, rules[0].width).?, eps);
}
