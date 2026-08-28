//! The claim the sub-window fill update rests on, exercised until it breaks.
//!
//! `pour` will UPDATE a fill whose content key moved — copy the previous
//! generation's margin field, throw away only the windows the changed obstacles
//! can write in, and raster those again — instead of pouring the fill from
//! nothing. The entire justification for doing that is that the result is
//! BIT-IDENTICAL to the cold pour: labels, component count, traced contours,
//! holes, `coarsened`, `integrity_ok`. A patched fill that differed anywhere
//! would be a silently wrong DRC verdict, not a slow one.
//!
//! So this file does not test the update's internals. It runs seeded random
//! EDIT SCRIPTS — tracks and vias added, moved and deleted, per layer, on a
//! board with an outline, an outer face, an inner plane and a hand-drawn zone —
//! and after every single step compares the patched fill against a cold
//! `compute` of the identical state, field by field. It also drives the cases
//! the update must DECLINE (the lattice moved, a rule moved, no previous
//! generation exists) and checks that those come back cold and still equal.
//!
//! The memo here is deliberately not `fill_cache`: it never answers `get`, so
//! every step really rebuilds, and it records whether `pour` took the patch —
//! otherwise a regression that silently stopped patching would leave every
//! assertion in this file passing.

const std = @import("std");
const content_key = @import("content_key.zig");
const flat_netlist = @import("../flat_netlist.zig");
const geometry = @import("geometry.zig");
const optimizer = @import("optimizer.zig");
const pour = @import("pour.zig");
const router = @import("router.zig");

const testing = std.testing;

/// A memo that retains PATCH BASES and nothing else.
///
/// `get` always misses, so `pour` rebuilds the fill on every call and the
/// comparison below is always between two freshly built rasters rather than
/// between a raster and a borrow of itself. `base`/`put_base` are real, so the
/// rebuild takes the update whenever one is available.
const BaseOnlyMemo = struct {
    arena: std.mem.Allocator,
    entries: std.ArrayList(Entry) = .empty,
    /// How many times a stored base was handed out — the non-vacuity counter.
    served: usize = 0,

    const Entry = struct { id: content_key.Key, snapshot: pour.Snapshot };

    fn memo(self: *BaseOnlyMemo) pour.FillMemo {
        return .{ .ctx = @ptrCast(self), .get = get, .put = put, .base = base, .put_base = putBase };
    }

    fn get(_: *anyopaque, _: content_key.Key) ?pour.Fill {
        return null;
    }

    fn put(_: *anyopaque, _: content_key.Key, _: pour.Fill) ?pour.Fill {
        return null;
    }

    fn base(ctx: *anyopaque, id: content_key.Key) ?pour.Snapshot {
        const self: *BaseOnlyMemo = @ptrCast(@alignCast(ctx));
        for (self.entries.items) |entry| {
            if (!content_key.Key.eql(entry.id, id)) continue;
            self.served += 1;
            return entry.snapshot;
        }
        return null;
    }

    fn putBase(ctx: *anyopaque, id: content_key.Key, snap: pour.Snapshot) void {
        const self: *BaseOnlyMemo = @ptrCast(@alignCast(ctx));
        const kept: pour.Snapshot = .{
            .margin = self.arena.dupe(f32, snap.margin) catch return,
            .features = self.arena.dupe(pour.FeatureRecord, snap.features) catch return,
        };
        for (self.entries.items) |*entry| {
            if (!content_key.Key.eql(entry.id, id)) continue;
            entry.snapshot = kept;
            return;
        }
        self.entries.append(self.arena, .{ .id = id, .snapshot = kept }) catch return;
    }
};

/// Every field of a `Fill`, compared exactly. `expectEqual` on floats rather
/// than `expectApproxEqAbs` on purpose: the claim is bit-identity, and a
/// contour vertex that moved by one ULP is a different Gerber.
fn expectSameFill(want: pour.Fill, got: pour.Fill) !void {
    try testing.expectEqual(want.frame.minx, got.frame.minx);
    try testing.expectEqual(want.frame.miny, got.frame.miny);
    try testing.expectEqual(want.frame.pitch, got.frame.pitch);
    try testing.expectEqual(want.frame.nx, got.frame.nx);
    try testing.expectEqual(want.frame.ny, got.frame.ny);
    try testing.expectEqual(want.coarsened, got.coarsened);
    try testing.expectEqual(want.integrity_ok, got.integrity_ok);
    try testing.expectEqual(want.n_comp, got.n_comp);
    try testing.expectEqualSlices(i32, want.labels, got.labels);
    try testing.expectEqual(want.contours.len, got.contours.len);
    for (want.contours, got.contours) |a, b| try testing.expectEqualSlices([2]f64, a, b);
    try testing.expectEqual(want.holes.len, got.holes.len);
    for (want.holes, got.holes) |a, b| {
        try testing.expectEqual(a.len, b.len);
        for (a, b) |ah, bh| try testing.expectEqualSlices([2]f64, ah, bh);
    }
}

/// The board every script runs on: a non-rectangular outline (so the base field
/// is a real polygon walk rather than a rectangle), two nets, pads on both
/// faces, and a through pad the inner plane has to carve.
fn scriptPlacement(parts: []optimizer.Part, nets: []const flat_netlist.FlatNet, rules: optimizer.BoardRules) optimizer.Placement {
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 24,
        .maxy = 24,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 24, .h = 24 },
        .rules = rules,
    };
}

const gnd_pads = [_]geometry.Pad{
    .{ .number = "1", .x = 0, .y = 0, .w = 0.8, .h = 0.8, .thru = true, .drill = 0.4 },
};
const sig_pads = [_]geometry.Pad{
    .{ .number = "1", .x = -0.6, .y = 0, .w = 0.7, .h = 0.7 },
    .{ .number = "2", .x = 0.6, .y = 0, .w = 0.7, .h = 0.7 },
};

fn scriptParts() [3]optimizer.Part {
    return .{
        .{ .ref_des = "J1", .kind = .hub, .hw = 1, .hh = 1, .pads = &gnd_pads, .fallback = false, .x = 5, .y = 5 },
        .{ .ref_des = "R1", .kind = .passive, .hw = 1, .hh = 0.6, .pads = &sig_pads, .fallback = false, .x = 12, .y = 9 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 1, .hh = 0.6, .pads = &sig_pads, .fallback = false, .x = 8, .y = 16, .side = .bottom },
    };
}

const gnd_pins = [_]flat_netlist.FlatPin{.{ .ref_des = "J1", .pin = "1" }};
const sig_pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "2" } };
const script_nets = [_]flat_netlist.FlatNet{
    .{ .name = "GND", .pins = &gnd_pins },
    .{ .name = "SIG", .pins = &sig_pins },
};
const board_outline = [_][2]f64{ .{ 0, 0 }, .{ 24, 0 }, .{ 24, 8 }, .{ 14, 8 }, .{ 14, 24 }, .{ 0, 24 } };
const zone_outline = [_][2]f64{ .{ 1, 1 }, .{ 13, 1 }, .{ 13, 22 }, .{ 1, 22 } };

/// The three shapes a real page asks for: an outer face that carves this
/// layer's tracks, an inner plane that carves only drilled copper (so a track
/// edit must never reach it), and a hand-drawn zone whose clip is what the
/// via/seed cull is defined against.
fn scriptSpecs() [3]pour.LayerSpec {
    return .{
        .{ .net = .{ .named = "GND" }, .side = .top, .track_layer = 0 },
        .{ .net = .ground, .keep_unseeded = false },
        pour.zoneLayerSpec("GND", .bottom, 1, &zone_outline),
    };
}

/// The script's own deterministic generator. Small and local on purpose: an
/// edit script is a FIXTURE, and a fixture that changed when the standard
/// library's default generator changed would silently stop testing the cases it
/// was written for.
const Rng = struct {
    state: u64,

    fn next(self: *Rng) u64 {
        self.state = self.state *% 6364136223846793005 +% 1442695040888963407;
        return self.state >> 11;
    }

    /// A value in [0, 1).
    fn unit(self: *Rng) f64 {
        const scale = @as(f64, @floatFromInt(@as(u64, 1) << 53));
        return @as(f64, @floatFromInt(self.next() % (1 << 53))) / scale;
    }

    fn below(self: *Rng, n: usize) usize {
        return self.next() % n;
    }
};

/// One seeded edit script's copper: a growable track and via list the script
/// mutates in place, exactly as an editing session does.
const Copper = struct {
    tracks: std.ArrayList(router.Track) = .empty,
    vias: std.ArrayList(router.Via) = .empty,

    fn value(self: Copper) pour.Copper {
        return .{ .tracks = self.tracks.items, .vias = self.vias.items };
    }
};

/// Apply one pseudo-random edit. Deliberately covers all six shapes an editor
/// produces — add / move / delete, for both a track and a via — because they
/// reach the update differently: an addition is a pure `min` into the field, a
/// deletion forces the window to be rebuilt from the base, and a move is both.
fn applyEdit(arena: std.mem.Allocator, rng: *Rng, copper: *Copper) std.mem.Allocator.Error!void {
    const r = rng;
    const x = 1 + r.unit() * 21;
    const y = 1 + r.unit() * 21;
    switch (r.below(6)) {
        0 => try copper.tracks.append(arena, .{
            .x1 = x,
            .y1 = y,
            .x2 = x + (r.unit() - 0.5) * 8,
            .y2 = y + (r.unit() - 0.5) * 8,
            .layer = @intCast(r.below(2)),
            .width = 0.2 + r.unit() * 0.3,
            .net = @intCast(r.below(2)),
        }),
        1 => if (copper.tracks.items.len > 0) {
            const i = r.below(copper.tracks.items.len);
            copper.tracks.items[i].x1 += (r.unit() - 0.5) * 2;
            copper.tracks.items[i].y1 += (r.unit() - 0.5) * 2;
        },
        2 => if (copper.tracks.items.len > 0) {
            _ = copper.tracks.orderedRemove(r.below(copper.tracks.items.len));
        },
        3 => try copper.vias.append(arena, .{
            .x = x,
            .y = y,
            .dia = 0.6,
            .drill = 0.3,
            .net = @intCast(r.below(2)),
        }),
        4 => if (copper.vias.items.len > 0) {
            const i = r.below(copper.vias.items.len);
            copper.vias.items[i].x += (r.unit() - 0.5) * 3;
            copper.vias.items[i].y += (r.unit() - 0.5) * 3;
        },
        else => if (copper.vias.items.len > 0) {
            _ = copper.vias.orderedRemove(r.below(copper.vias.items.len));
        },
    }
}

/// What one script proved: how many fills were compared, and how many of those
/// comparisons were against a fill the update actually produced.
const Score = struct { compared: usize = 0, patched: usize = 0 };

/// Run one seeded script: warm the board with copper, then edit and compare
/// every spec's patched fill against a cold pour of the identical state.
fn runScript(
    arena: std.mem.Allocator,
    placement: optimizer.Placement,
    memo: pour.FillMemo,
    seed: u64,
    score: *Score,
) !void {
    var rng: Rng = .{ .state = seed };
    var copper: Copper = .{};
    const specs = scriptSpecs();
    var step: usize = 0;
    while (step < 18) : (step += 1) {
        try applyEdit(arena, &rng, &copper);
        // The first few edits only populate the board: comparing an empty
        // raster against an empty raster proves nothing.
        if (step < 6) continue;
        for (specs) |spec| {
            const cold = try pour.compute(arena, placement, copper.value(), spec);
            const keyed = try pour.computeMemoKeyed(arena, placement, copper.value(), spec, null, memo);
            try expectSameFill(cold, keyed.fill);
            score.compared += 1;
            if (keyed.patched) score.patched += 1;
        }
    }
}

// spec: placement/pour - a fill updated from the previous generation's raster is bit-identical to the same fill poured cold, across a seeded script of track and via additions, moves and deletions on every carrying layer
test "a patched fill is bit-identical to a cold pour across a random edit script" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    var parts = scriptParts();
    const gnd_names = [_][]const u8{"GND"};
    var placement = scriptPlacement(&parts, &script_nets, .{ .plane_nets = &gnd_names, .copper_layers = 4 });
    placement.board_poly = &board_outline;

    var memo_state: BaseOnlyMemo = .{ .arena = arena };
    const memo = memo_state.memo();
    var score: Score = .{};
    for ([_]u64{ 0x5EED_0001, 0x5EED_0002, 0x5EED_0003, 0x5EED_0004 }) |seed| {
        try runScript(arena, placement, memo, seed, &score);
    }

    // Non-vacuity: the comparison above passes trivially if nothing ever took
    // the update. Most steps must have.
    try testing.expect(score.compared >= 144);
    try testing.expect(score.patched * 2 > score.compared);
    try testing.expect(memo_state.served > 0);
}

// spec: placement/pour - a fill whose seed set alone moved is still updated from the previous raster, because a seed lowers no margin, and still matches the cold pour exactly
test "a same-net via edit changes the seeds without disturbing the patched field" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    var parts = scriptParts();
    const gnd_names = [_][]const u8{"GND"};
    var placement = scriptPlacement(&parts, &script_nets, .{ .plane_nets = &gnd_names, .copper_layers = 4 });
    placement.board_poly = &board_outline;
    const spec = pour.zoneLayerSpec("GND", .bottom, 1, &zone_outline);

    var memo_state: BaseOnlyMemo = .{ .arena = arena };
    const memo = memo_state.memo();

    // A wall that splits the zone into two components, plus a GND via seeding
    // only the left one. Removing the via drops a component; a patched fill has
    // to drop exactly the same one.
    const wall = [_]router.Track{.{ .x1 = 7, .y1 = -1, .x2 = 7, .y2 = 25, .layer = 1, .width = 0.6, .net = 1 }};
    const seeded = [_]router.Via{ .{ .x = 4, .y = 4, .dia = 0.6, .drill = 0.3, .net = 0 }, .{ .x = 10, .y = 18, .dia = 0.6, .drill = 0.3, .net = 0 } };

    const first = try pour.computeMemoKeyed(arena, placement, .{ .tracks = &wall, .vias = &seeded }, spec, null, memo);
    try testing.expect(!first.patched);
    try testing.expect(first.fill.n_comp >= 2);

    const fewer = try pour.computeMemoKeyed(arena, placement, .{ .tracks = &wall, .vias = seeded[0..1] }, spec, null, memo);
    try testing.expect(fewer.patched);
    try expectSameFill(try pour.compute(arena, placement, .{ .tracks = &wall, .vias = seeded[0..1] }, spec), fewer.fill);
    try testing.expect(fewer.fill.n_comp < first.fill.n_comp);
}

// spec: placement/pour - a fill update is declined and the fill poured cold when the lattice or a pour rule moved under it, because the retained raster no longer describes the same fill
test "the fill update declines a moved lattice and a moved rule" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    var parts = scriptParts();
    const gnd_names = [_][]const u8{"GND"};
    const tracks = [_]router.Track{.{ .x1 = 3, .y1 = 12, .x2 = 12, .y2 = 12, .layer = 0, .width = 0.3, .net = 1 }};
    const copper: pour.Copper = .{ .tracks = &tracks };
    const spec: pour.LayerSpec = .{ .net = .{ .named = "GND" }, .side = .top, .track_layer = 0 };

    var memo_state: BaseOnlyMemo = .{ .arena = arena };
    const memo = memo_state.memo();

    var base_rules = optimizer.BoardRules{ .plane_nets = &gnd_names, .copper_layers = 4 };
    var placement = scriptPlacement(&parts, &script_nets, base_rules);
    placement.board_poly = &board_outline;
    _ = try pour.computeMemoKeyed(arena, placement, copper, spec, null, memo);

    // Same board, one more track: the update is available and taken.
    const grown = [_]router.Track{ tracks[0], .{ .x1 = 3, .y1 = 15, .x2 = 12, .y2 = 15, .layer = 0, .width = 0.3, .net = 1 } };
    const warm = try pour.computeMemoKeyed(arena, placement, .{ .tracks = &grown }, spec, null, memo);
    try testing.expect(warm.patched);

    // A pour rule that reshapes the raster: the retained field describes a fill
    // this board no longer pours, so the identity misses and the pour is cold.
    base_rules.design.pour.corner_radius = 0.5;
    var reruled = scriptPlacement(&parts, &script_nets, base_rules);
    reruled.board_poly = &board_outline;
    const after_rule = try pour.computeMemoKeyed(arena, reruled, .{ .tracks = &grown }, spec, null, memo);
    try testing.expect(!after_rule.patched);
    try expectSameFill(try pour.compute(arena, reruled, .{ .tracks = &grown }, spec), after_rule.fill);

    // …and so does a board whose outline moved: a different lattice is a
    // different field, and the co-sizing check refuses it rather than reading it.
    var resized = scriptPlacement(&parts, &script_nets, .{ .plane_nets = &gnd_names, .copper_layers = 4 });
    resized.maxx = 30;
    resized.board_rect = .{ .minx = 0, .miny = 0, .w = 30, .h = 24 };
    const after_resize = try pour.computeMemoKeyed(arena, resized, .{ .tracks = &grown }, spec, null, memo);
    try testing.expect(!after_resize.patched);
    try expectSameFill(try pour.compute(arena, resized, .{ .tracks = &grown }, spec), after_resize.fill);
}

// spec: placement/pour - a memo that offers no patch base pours every fill cold and still answers with the same raster, so the update is an optional seam rather than a required one
test "a memo without a patch base still answers exactly" {
    var arena_i = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_i.deinit();
    const arena = arena_i.allocator();

    var parts = scriptParts();
    const gnd_names = [_][]const u8{"GND"};
    var placement = scriptPlacement(&parts, &script_nets, .{ .plane_nets = &gnd_names, .copper_layers = 4 });
    placement.board_poly = &board_outline;
    const vias = [_]router.Via{.{ .x = 6, .y = 11, .dia = 0.6, .drill = 0.3, .net = 1 }};
    const copper: pour.Copper = .{ .vias = &vias };

    for (scriptSpecs()) |spec| {
        const unmemoised = try pour.computeMemoKeyed(arena, placement, copper, spec, null, null);
        try testing.expect(!unmemoised.patched);
        try expectSameFill(try pour.compute(arena, placement, copper, spec), unmemoised.fill);
    }
}
