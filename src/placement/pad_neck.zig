//! Pad-local width-transition shaping for generated copper.
//!
//! A net class may keep a wide nominal trunk while authorizing a short narrow
//! escape at SMD lands. A single-ended controlled-impedance class instead
//! transitions from every actual SMD launch span, whether wider or narrower,
//! to its nominal line. The router searches the centreline with its nominal
//! class geometry. At the final output boundary this pass subdivides pad-ended
//! straight segments into fabrication-real constant-width slices.
//!
//! Constant-width slices are intentional. They are understood identically by
//! the route viewer, DRC, Gerber writer, KiCad writer, and saved-layout schema;
//! a 25 um slice pitch makes the union visually smooth without adding a second
//! copper primitive whose clearance and persistence could drift.

const std = @import("std");
const flat_netlist = @import("../flat_netlist.zig");
const pad_neck_profile = @import("../pad_neck_profile.zig");
const optimizer = @import("optimizer.zig");
const pose_math = @import("pose_math.zig");
const router = @import("router.zig");

const eps: f64 = 1e-9;
const taper_step_mm: f64 = 0.025;
const default_neck_length_mm: f64 = 0.75;
const default_taper_length_mm: f64 = 0.35;
const rf_taper_widths: f64 = 1.2;

const Pad = struct {
    at: [2]f64,
    layer: u8,
    half_w: f64,
    half_h: f64,
    axis_x: [2]f64,
};

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

fn unit(v: [2]f64) ?[2]f64 {
    const len = std.math.hypot(v[0], v[1]);
    if (len <= eps) return null;
    return .{ v[0] / len, v[1] / len };
}

fn localComponents(pad: Pad, direction: [2]f64) [2]f64 {
    const axis_y = [2]f64{ -pad.axis_x[1], pad.axis_x[0] };
    return .{
        direction[0] * pad.axis_x[0] + direction[1] * pad.axis_x[1],
        direction[0] * axis_y[0] + direction[1] * axis_y[1],
    };
}

fn boxRayHalfExtent(pad: Pad, direction: [2]f64) f64 {
    const local = localComponents(pad, direction);
    var extent = std.math.inf(f64);
    if (@abs(local[0]) > eps) extent = @min(extent, pad.half_w / @abs(local[0]));
    if (@abs(local[1]) > eps) extent = @min(extent, pad.half_h / @abs(local[1]));
    return if (std.math.isFinite(extent)) extent else 0;
}

/// Width of pad copper at the actual exit, perpendicular to this launch.
/// A centre cross-section is wrong for diagonal entries: on a square land it
/// grows by sqrt(2) at 45 degrees, then protrudes beyond the pad as a false
/// flare. The boundary chord shrinks naturally toward a corner while leaving
/// horizontal and vertical face entries unchanged.
fn launchSpan(pad: Pad, direction: [2]f64) f64 {
    const local = localComponents(pad, direction);
    const land = boxRayHalfExtent(pad, direction);
    const point = [2]f64{ local[0] * land, local[1] * land };
    const normal = [2]f64{ -local[1], local[0] };
    var lo = -std.math.inf(f64);
    var hi = std.math.inf(f64);
    for (point, normal, [2]f64{ pad.half_w, pad.half_h }) |p, n, half| {
        if (@abs(n) <= eps) {
            if (@abs(p) > half + eps) return 0;
            continue;
        }
        var a = (-half - p) / n;
        var b = (half - p) / n;
        if (a > b) std.mem.swap(f64, &a, &b);
        lo = @max(lo, a);
        hi = @min(hi, b);
        if (hi < lo - eps) return 0;
    }
    return @max(0, hi - lo);
}

fn needsNeck(profile: pad_neck_profile.Profile, nominal: f64, pad: Pad, direction: [2]f64) bool {
    return profile.width > 0 and
        profile.width < nominal - eps and
        launchSpan(pad, direction) < nominal - eps;
}

fn endpointNeedsNeck(
    pads: []const Pad,
    point: [2]f64,
    layer: u8,
    profile: pad_neck_profile.Profile,
    nominal: f64,
    direction: [2]f64,
) bool {
    var found = false;
    for (pads) |pad| {
        if (pad.layer != layer or !samePoint(pad.at, point)) continue;
        found = true;
        // Coincident same-net lands act as their copper union. If any one can
        // carry the trunk, narrowing the connection is unnecessary.
        if (!needsNeck(profile, nominal, pad, direction)) return false;
    }
    return found;
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
                    .half_w = pad.w / 2,
                    .half_h = pad.h / 2,
                    .axis_x = blk: {
                        var local = pose_math.rotate(1, 0, pad.rot);
                        if (part.side == .bottom) local[0] = -local[0];
                        break :blk pose_math.rotate(local[0], local[1], part.rot);
                    },
                });
            }
        }
    }
    return out.items;
}

/// Whether an under-nominal segment is exactly inside this net class's pad
/// transition envelope: an authored pad neck when present, otherwise the
/// pad-size taper used by single-ended controlled-impedance routes.
/// DRC uses geometry instead of trusting provenance, so generated, restored,
/// and hand-routed copper all earn the exception by satisfying the same width
/// and pad-distance profile.
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
    const rule = placement.rules.net[ni];
    const profile = rule.pad_neck;
    const neck = @max(profile.width, fab_min_width);
    const authored = profile.width > 0 and neck < nominal - eps and track.width >= neck - eps;
    const no_authored_neck = profile.width <= 0;
    const controlled_impedance = no_authored_neck and rule.rf.impedance.ohms > 0 and
        rule.rf.impedance.diff_ohms <= 0;
    if (!authored and !controlled_impedance) return false;
    const neck_len = if (profile.max_length > 0) profile.max_length else default_neck_length_mm;
    const taper_len = if (profile.taper_length > 0) profile.taper_length else default_taper_length_mm;
    const a = [2]f64{ track.x1, track.y1 };
    const b = [2]f64{ track.x2, track.y2 };
    const direction = unit(.{ b[0] - a[0], b[1] - a[1] }) orelse return false;
    for (try netPads(arena, placement, track.net)) |pad| {
        if (pad.layer != track.layer) continue;
        const da = dist(pad.at, a);
        const db = dist(pad.at, b);
        if (authored) {
            if (!needsNeck(profile, nominal, pad, direction)) continue;
            const total = neck_len + taper_len;
            if (da > total + taper_step_mm + eps or db > total + taper_step_mm + eps) continue;
            const required = profileWidth(@max(da, db), neck, nominal, neck_len, taper_len);
            if (track.width + eps >= required) return true;
        } else {
            const across = launchSpan(pad, direction);
            if (!(across > 0) or across >= nominal - eps) continue;
            const land = boxRayHalfExtent(pad, direction);
            const rf_taper = nominal * rf_taper_widths;
            if (@min(da, db) > land + rf_taper + eps) continue;
            const required = profileWidth(@max(da, db), across, nominal, land, rf_taper);
            if (track.width + eps >= required) return true;
        }
    }
    return false;
}

const Profile = struct {
    width: f64,
    land: f64,
    taper: f64,
};

const Shape = struct {
    track: router.Track,
    nominal: f64,
    start: ?Profile = null,
    end: ?Profile = null,
};

fn localWidth(s: f64, len: f64, shape: Shape) f64 {
    const start_active = if (shape.start) |p| s < p.land + p.taper else false;
    const end_active = if (shape.end) |p| len - s < p.land + p.taper else false;
    const start_width = if (shape.start) |p| profileWidth(s, p.width, shape.nominal, p.land, p.taper) else shape.nominal;
    const end_width = if (shape.end) |p| profileWidth(len - s, p.width, shape.nominal, p.land, p.taper) else shape.nominal;
    if (start_active and end_active) {
        if (start_width <= shape.nominal and end_width <= shape.nominal) return @min(start_width, end_width);
        if (start_width >= shape.nominal and end_width >= shape.nominal) return @max(start_width, end_width);
        const f = if (len > eps) std.math.clamp(s / len, 0, 1) else 0;
        return start_width + (end_width - start_width) * f;
    }
    if (start_active) return start_width;
    if (end_active) return end_width;
    return shape.nominal;
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
    var cuts: std.ArrayList(f64) = .empty;
    try cuts.append(arena, 0);
    try cuts.append(arena, len);
    for ([_]?Profile{ shape.start, shape.end }, 0..) |maybe_profile, end| {
        const profile = maybe_profile orelse continue;
        const shaped_span = profile.land + profile.taper;
        const origin: f64 = if (end == 0) 0 else len;
        const sign: f64 = if (end == 0) 1 else -1;
        const neck_cut = origin + sign * @min(profile.land, len);
        if (neck_cut > eps and neck_cut < len - eps) try cuts.append(arena, neck_cut);
        var d = profile.land + taper_step_mm;
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

fn rfEndpointProfile(
    pads: []const Pad,
    point: [2]f64,
    layer: u8,
    nominal: f64,
    direction: [2]f64,
) ?Profile {
    var found = false;
    var width: f64 = 0;
    var land: f64 = 0;
    for (pads) |pad| {
        if (pad.layer != layer or !samePoint(pad.at, point)) continue;
        const span = launchSpan(pad, direction);
        if (!(span > 0)) continue;
        found = true;
        width = @max(width, span);
        land = @max(land, boxRayHalfExtent(pad, direction));
    }
    if (!found or @abs(width - nominal) <= eps) return null;
    return .{ .width = width, .land = land, .taper = nominal * rf_taper_widths };
}

/// Shape every selected generated net that declares a pad-local neck or a
/// single-ended controlled-impedance target. Controlled-impedance shaping is
/// local to each SMD endpoint, so vias and branches elsewhere on the net do
/// not suppress an otherwise valid launch transition.
///
/// This is the copper-only seam used by scoped route replay before its output
/// is offered to the assembled-board gate. Normal complete-board routing uses
/// `passBoard` below, which also reports the compaction to the route context.
pub fn shapeGeneratedTracks(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    selected_nets: []const bool,
    tracks: *std.ArrayList(router.Track),
) std.mem.Allocator.Error!bool {
    var out: std.ArrayList(router.Track) = .empty;
    const pads_by_net = try arena.alloc([]const Pad, placement.nets.len);
    const pads_known = try arena.alloc(bool, placement.nets.len);
    @memset(pads_known, false);
    var changed = false;
    for (tracks.items) |track| {
        if (track.net < 0 or @as(usize, @intCast(track.net)) >= placement.nets.len) {
            try out.append(arena, track);
            continue;
        }
        const ni: usize = @intCast(track.net);
        if (selected_nets.len > 0 and (ni >= selected_nets.len or !selected_nets[ni])) {
            try out.append(arena, track);
            continue;
        }
        const rule = if (ni < placement.rules.net.len) placement.rules.net[ni] else optimizer.NetRule{};
        const nominal = routedNominal(placement, ni, track.width) orelse {
            try out.append(arena, track);
            continue;
        };
        const neck = @max(rule.pad_neck.width, placement.rules.design.min_width);
        const authored = rule.pad_neck.width > 0 and neck < nominal - eps;
        const controlled_impedance = rule.rf.impedance.ohms > 0 and rule.rf.impedance.diff_ohms <= 0;
        if (!authored and !controlled_impedance) {
            try out.append(arena, track);
            continue;
        }
        if (!pads_known[ni]) {
            pads_by_net[ni] = try netPads(arena, placement, track.net);
            pads_known[ni] = true;
        }
        const pads = pads_by_net[ni];
        const direction = unit(.{ track.x2 - track.x1, track.y2 - track.y1 }) orelse {
            try out.append(arena, track);
            continue;
        };
        const neck_len = if (rule.pad_neck.max_length > 0) rule.pad_neck.max_length else default_neck_length_mm;
        const taper_len = if (rule.pad_neck.taper_length > 0) rule.pad_neck.taper_length else default_taper_length_mm;
        const start: ?Profile = if (authored and endpointNeedsNeck(
            pads,
            .{ track.x1, track.y1 },
            track.layer,
            rule.pad_neck,
            nominal,
            direction,
        ))
            .{ .width = neck, .land = neck_len, .taper = taper_len }
        else if (controlled_impedance)
            rfEndpointProfile(pads, .{ track.x1, track.y1 }, track.layer, nominal, direction)
        else
            null;
        const end: ?Profile = if (authored and endpointNeedsNeck(
            pads,
            .{ track.x2, track.y2 },
            track.layer,
            rule.pad_neck,
            nominal,
            direction,
        ))
            .{ .width = neck, .land = neck_len, .taper = taper_len }
        else if (controlled_impedance)
            rfEndpointProfile(pads, .{ track.x2, track.y2 }, track.layer, nominal, direction)
        else
            null;
        if (start == null and end == null) {
            try out.append(arena, track);
            continue;
        }
        try shapeTrack(arena, &out, .{
            .track = track,
            .nominal = nominal,
            .start = start,
            .end = end,
        });
        changed = true;
    }
    if (!changed) return false;
    tracks.clearRetainingCapacity();
    try tracks.appendSlice(arena, out.items);
    return true;
}

/// Shape a complete router board and notify its cleanup context when the track
/// list changes.
pub fn passBoard(board: router.CleanupBoard) std.mem.Allocator.Error!void {
    if (!try shapeGeneratedTracks(board.ctx.arena, board.placement, board.ctx.selected_nets, board.tracks)) return;
    router.copperCompacted(board.ctx);
}

const testing = std.testing;

test "pad neck slices form a monotonic taper without exceeding nominal width" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(router.Track) = .empty;
    const track = router.Track{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.2532, .net = 0 };
    try shapeTrack(arena, &out, .{
        .track = track,
        .nominal = 0.2532,
        .start = .{ .width = 0.1524, .land = 0.75, .taper = 0.35 },
    });
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
    try shapeTrack(arena, &out, .{
        .track = track,
        .nominal = 0.2532,
        .start = .{ .width = 0.1524, .land = 0.75, .taper = 0.35 },
        .end = .{ .width = 0.1524, .land = 0.75, .taper = 0.35 },
    });
    for (out.items) |slice| try testing.expectApproxEqAbs(@as(f64, 0.1524), slice.width, eps);
}

test "DRC allowance accepts only neck-profile copper beside its own undersized SMD pad" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pads = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.25 }};
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

// spec: placement/rf-port-frame-routing - every single-ended controlled-impedance SMD launch tapers between the pad-boundary chord available at its actual path crossing and nominal width, including wider lands, bends inside the pad, full flat-face collars on rectangular and oval pads, and via-fed or branched nets, without diagonal centre-chord flares
test "pad launch span and edge distance follow a diagonal entry" {
    const root = @sqrt(0.5);
    const pad = Pad{
        .at = .{ 0, 0 },
        .layer = 0,
        .half_w = 0.4,
        .half_h = 0.1,
        .axis_x = .{ 1, 0 },
    };
    try testing.expectApproxEqAbs(@as(f64, 0.2 * @sqrt(2.0)), launchSpan(pad, .{ root, root }), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.1 * @sqrt(2.0)), boxRayHalfExtent(pad, .{ root, root }), 1e-12);

    const square = Pad{
        .at = .{ 0, 0 },
        .layer = 0,
        .half_w = 0.25,
        .half_h = 0.25,
        .axis_x = .{ 1, 0 },
    };
    try testing.expectApproxEqAbs(@as(f64, 0), launchSpan(square, .{ root, root }), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.5), launchSpan(square, .{ 1, 0 }), 1e-12);
}

test "generated controlled-impedance launch tapers both wider and narrower lands on a branched net" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const G = @import("geometry.zig");
    const wide_pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.8, .h = 0.6 }};
    const narrow_pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.2 }};
    const branch_pad = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "J1", .kind = .hub, .hw = 1, .hh = 1, .pads = &wide_pad, .fallback = false },
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &narrow_pad, .fallback = false, .x = 3 },
        .{ .ref_des = "TP1", .kind = .hub, .hw = 1, .hh = 1, .pads = &branch_pad, .fallback = false, .x = 8 },
    };
    const pins = [_]flat_netlist.FlatPin{
        .{ .ref_des = "J1", .pin = "1" },
        .{ .ref_des = "U1", .pin = "1" },
        .{ .ref_des = "TP1", .pin = "1" },
    };
    const nets = [_]flat_netlist.FlatNet{.{ .name = "RF", .pins = &pins }};
    const rules = [_]optimizer.NetRule{.{
        .width = 0.4,
        // No max-freq is required for the local impedance transition.
        .rf = .{ .impedance = .{ .ohms = 50 } },
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
        .minx = -1,
        .miny = -1,
        .maxx = 9,
        .maxy = 1,
        .generated = true,
    };
    var tracks: std.ArrayList(router.Track) = .empty;
    try tracks.append(arena, .{ .x1 = 0, .y1 = 0, .x2 = 3, .y2 = 0, .layer = 0, .width = 0.4, .net = 0 });
    try testing.expect(try shapeGeneratedTracks(arena, placement, &.{true}, &tracks));
    try testing.expectApproxEqAbs(@as(f64, 0.6), tracks.items[0].width, eps);
    try testing.expectApproxEqAbs(@as(f64, 0.2), tracks.items[tracks.items.len - 1].width, eps);
    var saw_nominal = false;
    for (tracks.items) |track| saw_nominal = saw_nominal or @abs(track.width - 0.4) <= eps;
    try testing.expect(saw_nominal);
}

test "generated track keeps nominal width at a land that can carry its launch" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const G = @import("geometry.zig");
    const fine_pads = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.80, .h = 0.20 }};
    const roomy_pads = [_]G.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.54, .h = 0.64 }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "U1", .kind = .hub, .hw = 1, .hh = 1, .pads = &fine_pads, .fallback = false },
        .{ .ref_des = "C1", .kind = .passive, .hw = 1, .hh = 1, .pads = &roomy_pads, .fallback = false, .x = 2 },
    };
    const pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "U1", .pin = "1" }, .{ .ref_des = "C1", .pin = "1" } };
    const nets = [_]flat_netlist.FlatNet{.{ .name = "VDD", .pins = &pins }};
    const rules = [_]optimizer.NetRule{.{
        .width = 0.35,
        .pad_neck = .{ .width = 0.20, .max_length = 0.50, .taper_length = 0.25 },
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
        .minx = -1,
        .miny = -1,
        .maxx = 3,
        .maxy = 1,
        .generated = true,
    };
    var tracks: std.ArrayList(router.Track) = .empty;
    try tracks.append(arena, .{ .x1 = 0, .y1 = 0, .x2 = 2, .y2 = 0, .layer = 0, .width = 0.35, .net = 0 });
    try testing.expect(try shapeGeneratedTracks(arena, placement, &.{true}, &tracks));
    try testing.expectEqual(@as(f64, 0.20), tracks.items[0].width);
    try testing.expectEqual(@as(f64, 0.35), tracks.items[tracks.items.len - 1].width);
    try testing.expect(!try allowsTrack(arena, placement, .{
        .x1 = 1.7,
        .y1 = 0,
        .x2 = 2,
        .y2 = 0,
        .layer = 0,
        .width = 0.20,
        .net = 0,
    }, 0.35, 0.127));
}

test "DRC allowance recognizes the controlled-impedance land taper profile" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const pads = [_]@import("geometry.zig").Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.2 }};
    var parts = [_]optimizer.Part{.{
        .ref_des = "U1",
        .kind = .hub,
        .hw = 1,
        .hh = 1,
        .pads = &pads,
        .fallback = false,
    }};
    const pins = [_]flat_netlist.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
    const nets = [_]flat_netlist.FlatNet{.{ .name = "RF", .pins = &pins }};
    const rules = [_]optimizer.NetRule{.{
        .class = .{ .name = "rf" },
        .width = 0.4,
        .rf = .{ .max_freq_hz = 12e9, .impedance = .{ .ohms = 50 } },
    }};
    const placement = optimizer.Placement{
        .parts = &parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &nets,
        .rules = .{ .net = &rules },
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 5,
        .maxy = 5,
        .generated = true,
    };
    const land = router.Track{ .x1 = 0, .y1 = 0, .x2 = 0.3, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 };
    const taper = router.Track{ .x1 = 0.3, .y1 = 0, .x2 = 0.38, .y2 = 0, .layer = 0, .width = 0.234, .net = 0 };
    const too_thin = router.Track{ .x1 = 0.3, .y1 = 0, .x2 = 0.7, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 };
    const far = router.Track{ .x1 = 2, .y1 = 0, .x2 = 2.1, .y2 = 0, .layer = 0, .width = 0.2, .net = 0 };
    try testing.expect(try allowsTrack(arena, placement, land, 0.4, 0.127));
    try testing.expect(try allowsTrack(arena, placement, taper, 0.4, 0.127));
    try testing.expect(!try allowsTrack(arena, placement, too_thin, 0.4, 0.127));
    try testing.expect(!try allowsTrack(arena, placement, far, 0.4, 0.127));
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
