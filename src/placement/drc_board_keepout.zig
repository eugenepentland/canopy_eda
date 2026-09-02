//! Post-route checks for the authored regions of `(board … (keepout "NAME" …))`.
//!
//! The perimeter twin (`drc_perimeter_keepout.zig`) measures a band derived
//! from the outline; this one measures rectangles an author stated outright,
//! and adds the axis that band has no use for — a FACE. A heatsink plate on the
//! bottom reserves the bottom assembly face and the bottom copper; the top of
//! the same rectangle stays ordinary board.
//!
//! Vias are the deliberate exception to per-face reasoning: a through barrel
//! crosses the whole stack, so it protrudes through BOTH outer faces and is
//! measured against every region whatever face that region names.

const std = @import("std");
const board_keepout = @import("board_keepout.zig");
const drc = @import("drc.zig");
const optimizer = @import("optimizer.zig");
const pad_shape = @import("pad_shape.zig");
const pose_math = @import("pose_math.zig");
const router = @import("router.zig");
const numeric = @import("../numeric.zig");

/// Millimetres between samples when walking a track across a region — the same
/// step `drc_perimeter_keepout` walks its band with.
const track_step_mm: f64 = 0.1;

fn append(
    arena: std.mem.Allocator,
    out: *std.ArrayList(drc.Violation),
    at: [2]f64,
    depth: f64,
    who: drc.Parties,
) std.mem.Allocator.Error!void {
    try out.append(arena, .{
        .x = at[0],
        .y = at[1],
        // A region is a hard exclusion, not a spacing rule: the clearance it
        // demands is "none of you", so the gap is reported as the depth the
        // offender reaches INSIDE it, negated to keep the file's
        // gap-below-clearance convention.
        .gap = -depth,
        .clearance = 0,
        .kind = .board_keepout,
        .severity = drc.defaultSeverity(.board_keepout),
        .who = who,
    });
}

fn checkComponents(
    arena: std.mem.Allocator,
    out: *std.ArrayList(drc.Violation),
    placement: optimizer.Placement,
    region: board_keepout.Region,
) std.mem.Allocator.Error!void {
    for (placement.parts, 0..) |part, i| {
        if (!region.coversSide(part.side)) continue;
        const corners = pad_shape.worldCourtyardCorners(part);
        const hit = pose_math.obbPenetration(corners, region.corners()) orelse continue;
        try append(arena, out, .{ hit.x, hit.y }, hit.depth, .{ .part_a = drc.partyIndex(i) });
    }
}

/// Deepest point of a track's centreline inside `region`, or null when the
/// copper (centreline plus half its width) never reaches in.
fn trackDepth(region: board_keepout.Region, track: router.Track) ?struct { at: [2]f64, depth: f64 } {
    const length = std.math.hypot(track.x2 - track.x1, track.y2 - track.y1);
    const steps = @max(1, numeric.checkedInt(usize, @ceil(length / track_step_mm)) orelse return null);
    var best = -std.math.inf(f64);
    var at: [2]f64 = .{ track.x1, track.y1 };
    for (0..steps + 1) |i| {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
        const x = track.x1 + (track.x2 - track.x1) * t;
        const y = track.y1 + (track.y2 - track.y1) * t;
        const inset = region.insetAt(x, y);
        if (inset > best) {
            best = inset;
            at = .{ x, y };
        }
    }
    const depth = best + track.width / 2;
    return if (depth > 0) .{ .at = at, .depth = depth } else null;
}

fn checkTracks(
    arena: std.mem.Allocator,
    out: *std.ArrayList(drc.Violation),
    placement: optimizer.Placement,
    tracks: []const router.Track,
    region: board_keepout.Region,
) std.mem.Allocator.Error!void {
    for (tracks) |track| {
        if (!region.coversLayer(track.layer)) continue;
        if (allowsNet(placement, region, track.net)) continue;
        const hit = trackDepth(region, track) orelse continue;
        try append(arena, out, hit.at, hit.depth, .{ .net_a = track.net });
    }
}

fn checkVias(
    arena: std.mem.Allocator,
    out: *std.ArrayList(drc.Violation),
    placement: optimizer.Placement,
    vias: []const router.Via,
    region: board_keepout.Region,
) std.mem.Allocator.Error!void {
    for (vias) |via| {
        if (allowsNet(placement, region, via.net)) continue;
        const depth = region.insetAt(via.x, via.y) + via.dia / 2;
        if (!(depth > 0)) continue;
        try append(arena, out, .{ via.x, via.y }, depth, .{ .net_a = via.net });
    }
}

fn allowsNet(placement: optimizer.Placement, region: board_keepout.Region, net: i32) bool {
    if (net < 0 or @as(usize, @intCast(net)) >= placement.nets.len) return false;
    return region.allowsNet(placement.nets[@intCast(net)].name);
}

/// Append every authored-region finding. A board that declares none — every
/// board today — takes the constant-time early return.
pub fn check(
    arena: std.mem.Allocator,
    out: *std.ArrayList(drc.Violation),
    placement: optimizer.Placement,
    tracks: []const router.Track,
    vias: []const router.Via,
) std.mem.Allocator.Error!void {
    if (!board_keepout.anyDeclared(placement)) return;
    for (try board_keepout.regionsOf(arena, placement)) |region| {
        if (region.spec.blocks.components) try checkComponents(arena, out, placement, region);
        if (region.spec.blocks.tracks) try checkTracks(arena, out, placement, tracks, region);
        if (region.spec.blocks.vias) try checkVias(arena, out, placement, vias, region);
    }
}

const testing = std.testing;
const env = @import("../eval/env.zig");
const flat_netlist = @import("../flat_netlist.zig");

const fixture_nets = [_]flat_netlist.FlatNet{
    .{ .name = "GND", .pins = &.{} },
    .{ .name = "SIG", .pins = &.{} },
};

/// A 10 x 10 mm board whose parts and rules the caller supplies. The board's
/// top-left is the world origin, so a region's board-local rectangle and its
/// world rectangle read the same in these tests.
fn fixture(parts: []optimizer.Part, specs: []const env.BoardKeepoutSpec) optimizer.Placement {
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &fixture_nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .generated = true,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 },
        .rules = .{ .board_keepouts = specs },
    };
}

// spec: placement/drc - an authored board keepout flags the courtyards, tracks and vias inside it on the face it reserves, admits its allowed nets, and leaves the opposite face alone
test "an authored board keepout reports its intruders and honours its exemptions" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    // The right half of the BOTTOM face is reserved for a heatsink plate that
    // is bonded to ground, so GND copper is admitted through it.
    const specs = [_]env.BoardKeepoutSpec{.{
        .name = "plate",
        .rect = .{ .x = 5, .y = 0, .w = 5, .h = 10 },
        .side = .bottom,
        .allow_nets = &.{"GND"},
    }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "Q2", .kind = .passive, .x = 7, .y = 5, .hw = 0.5, .hh = 0.5, .pads = &.{}, .fallback = false, .side = .bottom },
        .{ .ref_des = "U1", .kind = .hub, .x = 7, .y = 5, .hw = 0.5, .hh = 0.5, .pads = &.{}, .fallback = false, .side = .top },
        .{ .ref_des = "R9", .kind = .passive, .x = 2, .y = 5, .hw = 0.5, .hh = 0.5, .pads = &.{}, .fallback = false, .side = .bottom },
    };
    const tracks = [_]router.Track{
        .{ .x1 = 6, .y1 = 2, .x2 = 8, .y2 = 2, .layer = 1, .width = 0.2, .net = 1 }, // bottom, SIG
        .{ .x1 = 6, .y1 = 3, .x2 = 8, .y2 = 3, .layer = 1, .width = 0.2, .net = 0 }, // bottom, GND — admitted
        .{ .x1 = 6, .y1 = 4, .x2 = 8, .y2 = 4, .layer = 0, .width = 0.2, .net = 1 }, // TOP face — not this region's
        .{ .x1 = 1, .y1 = 5, .x2 = 3, .y2 = 5, .layer = 1, .width = 0.2, .net = 1 }, // bottom, clear of it
    };
    const vias = [_]router.Via{
        .{ .x = 7, .y = 7, .dia = 0.4, .drill = 0.2, .net = 1 },
        .{ .x = 7, .y = 8, .dia = 0.4, .drill = 0.2, .net = 0 }, // GND — admitted
        .{ .x = 2, .y = 7, .dia = 0.4, .drill = 0.2, .net = 1 },
    };

    var hits: std.ArrayList(drc.Violation) = .empty;
    try check(arena, &hits, fixture(&parts, &specs), &tracks, &vias);
    try testing.expectEqual(@as(usize, 3), hits.items.len);
    for (hits.items) |hit| {
        try testing.expectEqual(drc.Kind.board_keepout, hit.kind);
        try testing.expectEqual(drc.Severity.err, hit.severity);
        try testing.expect(hit.gap < 0); // reported as depth INSIDE the region
    }
    try testing.expectEqual(@as(i32, 0), hits.items[0].who.part_a); // the bottom-side part
    try testing.expectEqual(@as(i32, 1), hits.items[1].who.net_a); // the bottom SIG track
    try testing.expectEqual(@as(i32, 1), hits.items[2].who.net_a); // the SIG via
}

// spec: placement/drc - an authored board keepout blocking only some families ignores the others, and a both-sides region also reserves the inner copper layers
test "an authored board keepout blocks only the families it names" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const specs = [_]env.BoardKeepoutSpec{.{
        .name = "shield can",
        .rect = .{ .x = 5, .y = 0, .w = 5, .h = 10 },
        .side = .both,
        .blocks = .{ .tracks = true },
    }};
    var parts = [_]optimizer.Part{
        .{ .ref_des = "Q2", .kind = .passive, .x = 7, .y = 5, .hw = 0.5, .hh = 0.5, .pads = &.{}, .fallback = false, .side = .bottom },
    };
    const tracks = [_]router.Track{
        .{ .x1 = 6, .y1 = 2, .x2 = 8, .y2 = 2, .layer = 2, .width = 0.2, .net = 1 }, // an INNER layer
    };
    const vias = [_]router.Via{.{ .x = 7, .y = 7, .dia = 0.4, .drill = 0.2, .net = 1 }};

    var hits: std.ArrayList(drc.Violation) = .empty;
    try check(arena, &hits, fixture(&parts, &specs), &tracks, &vias);
    // Only the inner-layer track: components and vias are not blocked here, and
    // `both` is the one side selection an inner layer can belong to.
    try testing.expectEqual(@as(usize, 1), hits.items.len);
    try testing.expectEqual(@as(i32, 1), hits.items[0].who.net_a);
}

// spec: placement/drc - a board declaring no authored keepout region runs no region geometry at all
test "a board with no authored keepout region is untouched" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    var parts = [_]optimizer.Part{
        .{ .ref_des = "Q2", .kind = .passive, .x = 7, .y = 5, .hw = 0.5, .hh = 0.5, .pads = &.{}, .fallback = false, .side = .bottom },
    };
    var hits: std.ArrayList(drc.Violation) = .empty;
    try check(arena_state.allocator(), &hits, fixture(&parts, &.{}), &.{}, &.{});
    try testing.expectEqual(@as(usize, 0), hits.items.len);
}
