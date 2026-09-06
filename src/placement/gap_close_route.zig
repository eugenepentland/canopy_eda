//! End-to-end tests for the ROUTER's gap-closing pass (`router.closeGaps`) —
//! the finishing pass that bridges a partly-routed net's remaining islands,
//! stitches a stranded pad into its plane, and rips a bounded set of foreign
//! nets when a hop is walled in.
//!
//! They live outside `router.zig` for the reason `keepout_route.zig` gives:
//! that file sits against its hard file-size cap, and a behavioural test is the
//! right shape for this pass. Every claim here is about the copper a real hop
//! produces — it detours the pad sealing the straight line, it welds both pad
//! centres, it reports one event per hop, it keeps its via out of both
//! terminals, it names whose net it ripped, it threads a slot only when the
//! class fits — so the tests drive the public `closeGaps` seam and nothing else.
//!
//! What stays behind in `router.zig` is exactly what cannot be seen from here:
//! the two tests that read the terminal via-ban mask through the private gap
//! context, and the two that call `anyDeclaredResolution` / `netPourCovers`
//! directly.

const std = @import("std");
const optimizer = @import("optimizer.zig");
const router = @import("router.zig");
const route_policy = @import("route_policy.zig");
const geometry = @import("geometry.zig");
const pad_shape = @import("pad_shape.zig");
const flat_netlist = @import("../flat_netlist.zig");
const numeric = @import("../numeric.zig");

/// Endpoint coincidence tolerance in board millimetres: a track end this close
/// to a pad centre counts as touching it.
const endpoint_eps_mm: f64 = 1e-6;

const testing = std.testing;

const Part = optimizer.Part;
const FlatNet = flat_netlist.FlatNet;
const Track = router.Track;
const Gap = router.Gap;
const GapPath = router.GapPath;
const GapEvent = router.GapEvent;
const GapReason = router.GapReason;
const GapJudge = router.GapJudge;
const RouteParams = router.RouteParams;
const rip_tiers = router.rip_tiers;
const clearance_eps = router.clearance_eps;
const closeGaps = router.closeGaps;
const segSegDist = pad_shape.segSegDist;

/// An axis-aligned box the assertions measure a routed track's clearance
/// against (`router.Rect`'s private twin — the router does not export it, and a
/// four-field rectangle is not worth widening its API for).
const Rect = struct { x0: f64, y0: f64, x1: f64, y1: f64 };

/// Distance from a point to an axis-aligned rect (0 if inside).
fn distPointRect(px: f64, py: f64, r: Rect) f64 {
    const dx = @max(@max(r.x0 - px, px - r.x1), 0);
    const dy = @max(@max(r.y0 - py, py - r.y1), 0);
    return @sqrt(dx * dx + dy * dy);
}

/// Three parts on a line: two same-net terminals (`A` / `B`, `2 mm` apart) with
/// a FOREIGN pad parked exactly between them, so the straight route is illegal
/// and a gap bridge has to detour. `b_side` puts the far terminal on the bottom
/// face, which forces a layer change.
fn gapBridgePlacement(arena: std.mem.Allocator, b_side: optimizer.Side) std.mem.Allocator.Error!optimizer.Placement {
    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const blocker = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.8, .h = 0.8, .thru = true }};
    const parts = try arena.alloc(Part, 3);
    parts[0] = .{ .ref_des = "A", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 0, .y = 0 };
    parts[1] = .{ .ref_des = "B", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 2, .y = 0, .side = b_side };
    parts[2] = .{ .ref_des = "X", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = &blocker, .fallback = false, .x = 1, .y = 0 };
    const sig = try arena.alloc(flat_netlist.FlatPin, 2);
    sig[0] = .{ .ref_des = "A", .pin = "1" };
    sig[1] = .{ .ref_des = "B", .pin = "1" };
    const other = try arena.alloc(flat_netlist.FlatPin, 1);
    other[0] = .{ .ref_des = "X", .pin = "1" };
    const nets = try arena.alloc(FlatNet, 2);
    nets[0] = .{ .name = "SIG", .pins = sig };
    nets[1] = .{ .name = "BLOCK", .pins = other };
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1,
        .miny = -2,
        .maxx = 3,
        .maxy = 2,
        .generated = true,
    };
}

/// Does any emitted track have an endpoint exactly at `(x, y)`? A gap bridge
/// welds each terminal's pad CENTRE to whichever grid node it entered through,
/// so both pad centres must appear as endpoints or the copper does not touch
/// the pads it claims to join.
fn touchesPoint(tracks: []const Track, x: f64, y: f64) bool {
    for (tracks) |t| {
        if (@abs(t.x1 - x) < endpoint_eps_mm and @abs(t.y1 - y) < endpoint_eps_mm) return true;
        if (@abs(t.x2 - x) < endpoint_eps_mm and @abs(t.y2 - y) < endpoint_eps_mm) return true;
    }
    return false;
}

/// The closest any emitted track comes to the axis-aligned box `r`, sampled
/// densely enough that a 45° segment's midpoint cannot slip through.
fn minTrackGap(tracks: []const Track, r: Rect) f64 {
    var best = std.math.inf(f64);
    for (tracks) |t| {
        const len = std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
        const steps: usize = @max(1, numeric.toCount(@ceil(len / 0.01)));
        for (0..steps + 1) |s| {
            const f = @as(f64, @floatFromInt(s)) / @as(f64, @floatFromInt(steps));
            best = @min(best, distPointRect(t.x1 + f * (t.x2 - t.x1), t.y1 + f * (t.y2 - t.y1), r));
        }
    }
    return best;
}

// spec: placement/route-deadline - a stopped gap batch keeps completed hops without reporting skipped hops as attempts
test "closeGaps stops reporting attempts after cancellation and keeps completed hops" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const Watch = struct {
        cancel: std.atomic.Value(bool) = .init(false),
        events: usize = 0,

        fn emit(raw: ?*anyopaque, _: GapEvent) void {
            const self: *@This() = @ptrCast(@alignCast(raw.?));
            self.events += 1;
            self.cancel.store(true, .monotonic);
        }
    };
    var watch = Watch{};
    const placement = try gapBridgePlacement(arena, .top);
    const gap = Gap{ .net_i = 0, .from = .{ .x = 0, .y = 0, .layer = 0 }, .to = .{ .x = 2, .y = 0, .layer = 0 } };
    const paths = try closeGaps(arena, placement, .{}, .{}, &.{ gap, gap }, .{
        .raster = .{ .stop = .{ .cancel = &watch.cancel } },
        .sink = .{ .ctx = &watch, .emit = Watch.emit },
    });
    try testing.expect(paths[0] != null);
    try testing.expect(paths[1] == null);
    try testing.expectEqual(@as(usize, 1), watch.events);
}

// spec: placement/router - closeGaps bridges two same-net pads around foreign pad copper and welds both pad centres into the new track chain
test "closeGaps detours a bridge around the foreign pad sealing the straight line" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const placement = try gapBridgePlacement(arena, .top);
    const params = RouteParams{};
    const gaps = [_]Gap{.{
        .net_i = 0,
        .from = .{ .x = 0, .y = 0, .layer = 0 },
        .to = .{ .x = 2, .y = 0, .layer = 0 },
    }};
    const paths = try closeGaps(arena, placement, params, .{}, &gaps, .{});
    const path = paths[0] orelse return error.GapNotClosed;

    // The copper physically reaches both pads it claims to join.
    try testing.expect(touchesPoint(path.tracks, 0, 0));
    try testing.expect(touchesPoint(path.tracks, 2, 0));
    // …and it keeps full clearance from the foreign pad standing between them,
    // which is only possible by going around: the straight line runs through it.
    const blocker = Rect{ .x0 = 0.6, .y0 = -0.4, .x1 = 1.4, .y1 = 0.4 };
    try testing.expect(minTrackGap(path.tracks, blocker) >= params.track_width / 2 + params.clearance - clearance_eps);
}

// spec: placement/router - gap closing refuses an opposite-face bridge when the net has no new-via allowance
test "closeGaps honors a zero-via policy on an opposite-face bridge" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const placement = try gapBridgePlacement(arena, .bottom);
    const gaps = [_]Gap{.{
        .net_i = 0,
        .from = .{ .x = 0, .y = 0, .layer = 0 },
        .to = .{ .x = 2, .y = 0, .layer = 1 },
    }};
    const free = try closeGaps(arena, placement, .{}, .{}, &gaps, .{ .ripup = false });
    try testing.expect(free[0] != null);
    try testing.expect(free[0].?.vias.len > 0);
    const constrained = try closeGaps(arena, placement, .{}, .{}, &gaps, .{
        .ripup = false,
        .constraints = .{ .net = &.{.{ .max_vias = 0 }} },
    });
    try testing.expect(constrained[0] == null);
}

// spec: placement/router - gap closing honors authored layer restrictions and new-via limits before accepting or absorbing copper
test "gap policy refuses a forbidden layer detour and a two-via path over budget" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const placement = try walledPlacement(arena);
    const wall = wallTracks();
    // Only the top face is walled; going around on the bottom needs two vias.
    const board = router.GapBoard{ .tracks = wall[0..1] };
    const gaps = [_]Gap{walledGap()};
    const free = try closeGaps(arena, placement, .{}, board, &gaps, .{ .ripup = false });
    try testing.expect(free[0] != null);
    try testing.expect(free[0].?.vias.len >= 2);
    const surface = try closeGaps(arena, placement, .{}, board, &gaps, .{
        .ripup = false,
        .constraints = .{ .net = &.{.{ .allowed_layers = 1 }} },
    });
    try testing.expect(surface[0] == null);
    var log = GapEventLog{};
    const limited = try closeGaps(arena, placement, .{}, board, &gaps, .{
        .ripup = false,
        .constraints = .{ .net = &.{.{ .max_vias = 1 }} },
        .sink = .{ .ctx = &log, .emit = GapEventLog.emit },
    });
    try testing.expect(limited[0] == null);
    try testing.expectEqual(GapReason.policy, log.seen[0].why);
}

/// The top wall forces an early layer change; the bottom wall can be crossed
/// either with two more vias or by a longer detour around its northern end.
fn viaBudgetDetourPlacement(arena: std.mem.Allocator) std.mem.Allocator.Error!optimizer.Placement {
    var placement = try walledPlacement(arena);
    placement.parts[1].side = .bottom;
    placement.board_rect = .{ .minx = -1, .miny = -4, .w = 12, .h = 10 };
    return placement;
}

fn viaBudgetDetourWalls() [2]Track {
    return .{
        .{ .x1 = 2, .y1 = -10, .x2 = 2, .y2 = 10, .layer = 0, .width = 0.2, .net = 1 },
        .{ .x1 = 5, .y1 = -10, .x2 = 5, .y2 = 4, .layer = 1, .width = 0.2, .net = 1 },
    };
}

// spec: placement/router - a via-limited gap retries a longer legal path with a nonzero via allowance instead of rejecting the cheaper excessive-via path
test "gap via budget finds the longer one-via detour" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = try viaBudgetDetourPlacement(arena);
    const walls = viaBudgetDetourWalls();
    var gap = walledGap();
    gap.to.?.layer = 1;
    const board = router.GapBoard{ .tracks = &walls };
    const ordinary = try closeGaps(arena, placement, .{}, board, &.{gap}, .{ .ripup = false, .shape = .off });
    try testing.expect(ordinary[0] != null);
    try testing.expectEqual(@as(usize, 3), ordinary[0].?.vias.len);
    const limited = try closeGaps(arena, placement, .{}, board, &.{gap}, .{
        .ripup = false,
        .shape = .off,
        .constraints = .{ .net = &.{.{ .max_vias = 1 }} },
    });
    try testing.expect(limited[0] != null);
    const path = limited[0].?;
    try testing.expectEqual(@as(usize, 1), path.vias.len);
    try testing.expectEqual(@as(usize, 0), path.ripped.len);
    try testing.expect(touchesPoint(path.tracks, 0, 0));
    try testing.expect(touchesPoint(path.tracks, 10, 0));
    var checked_tracks: std.ArrayList(Track) = .empty;
    try checked_tracks.appendSlice(arena, &walls);
    try checked_tracks.appendSlice(arena, path.tracks);
    const drc = @import("drc.zig");
    const findings = try drc.checkForNet(arena, placement, .{
        .tracks = checked_tracks.items,
        .vias = path.vias,
        .routed = 1,
        .total = 1,
    }, 0.127, 0);
    // The fixture's foreign walls deliberately extend beyond the outline.
    // Every error involving the new SIG copper must still be absent.
    for (findings) |finding| try testing.expect(finding.severity != .err or
        (finding.who.net_a == 1 and finding.who.net_b != 0));

    const retained = [_]route_policy.ExistingTrack{
        .{ .x1 = 2, .y1 = -10, .x2 = 2, .y2 = 10, .layer = 0, .width = 0.2, .net = 1 },
        .{ .x1 = 5, .y1 = -10, .x2 = 5, .y2 = 4, .layer = 1, .width = 0.2, .net = 1 },
    };
    const whole = try router.routeWithOptions(arena, placement, .{}, .{
        .net = &.{ .{ .max_vias = 1 }, .{} },
        .selected_nets = &.{ true, false },
        .existing_tracks = &retained,
        .effort = .one_shot,
        .grid_scale = 1,
    });
    try testing.expectEqual(@as(usize, 0), whole.failed.len);
    try testing.expectEqual(@as(usize, 1), whole.vias.len);
}

// spec: placement/router - a gap batch spends via allowance only on accepted hops and does not reset it for later requests
test "gap policy shares the batch via allowance and refunds vetoed hops" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    var placement = try gapBridgePlacement(arena, .bottom);
    const parts = try arena.alloc(Part, 6);
    @memcpy(parts[0..3], placement.parts);
    @memcpy(parts[3..], placement.parts);
    parts[3].ref_des = "A2";
    parts[4].ref_des = "B2";
    parts[5].ref_des = "X2";
    for (parts[3..]) |*part| part.y += 4;
    placement.parts = parts;
    placement.maxy = 6;
    const nets = try arena.dupe(FlatNet, placement.nets);
    nets[0].pins = &.{
        .{ .ref_des = "A", .pin = "1" },  .{ .ref_des = "B", .pin = "1" },
        .{ .ref_des = "A2", .pin = "1" }, .{ .ref_des = "B2", .pin = "1" },
    };
    nets[1].pins = &.{ .{ .ref_des = "X", .pin = "1" }, .{ .ref_des = "X2", .pin = "1" } };
    placement.nets = nets;
    const gaps = [_]Gap{
        .{ .net_i = 0, .from = .{ .x = 0, .y = 0, .layer = 0 }, .to = .{ .x = 2, .y = 0, .layer = 1 } },
        .{ .net_i = 0, .from = .{ .x = 0, .y = 4, .layer = 0 }, .to = .{ .x = 2, .y = 4, .layer = 1 } },
    };
    const free = try closeGaps(arena, placement, .{}, .{}, &gaps, .{ .ripup = false });
    try testing.expect(free[0] != null);
    try testing.expect(free[1] != null);
    var opts = router.GapOptions{ .ripup = false, .constraints = .{ .net = &.{.{ .max_vias = 1 }} } };
    const limited = try closeGaps(arena, placement, .{}, .{}, &gaps, opts);
    try testing.expectEqual(@as(usize, 1), limited[0].?.vias.len);
    try testing.expect(limited[1] == null);
    var veto = VetoFirstHop{};
    opts.judge = .{ .ctx = &veto, .keep = VetoFirstHop.keep };
    const judged = try closeGaps(arena, placement, .{}, .{}, &gaps, opts);
    try testing.expect(judged[0] != null);
    try testing.expect(judged[1] != null);
    try testing.expectEqual(@as(usize, 2), veto.asked);
}

/// Records every `GapEvent` a pass emits, so a test can assert the report is
/// complete and in request order. Fixed capacity: a sink must not allocate.
const GapEventLog = struct {
    seen: [8]GapEvent = @splat(.{ .index = 0, .landed = false, .ripped = 0 }),
    n: usize = 0,

    fn emit(ctx: ?*anyopaque, ev: GapEvent) void {
        const self: *GapEventLog = @ptrCast(@alignCast(ctx.?));
        if (self.n >= self.seen.len) return;
        self.seen[self.n] = ev;
        self.n += 1;
    }
};

// spec: placement/router - a gap pass reports one progress event per requested hop, in order, saying whether it landed and carrying that hop's own reason
test "closeGaps reports one progress event per hop, in request order" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const placement = try gapBridgePlacement(arena, .top);
    // Hop 0 is the routable A↔B bridge; hop 1 names a net index off the end of
    // the netlist, which the pass skips — the report must still cover it, or a
    // caller cannot line events up with the gaps it asked for.
    const gaps = [_]Gap{
        .{ .net_i = 0, .from = .{ .x = 0, .y = 0, .layer = 0 }, .to = .{ .x = 2, .y = 0, .layer = 0 } },
        .{ .net_i = 99, .from = .{ .x = 0, .y = 0, .layer = 0 }, .to = .{ .x = 2, .y = 0, .layer = 0 } },
    };
    var log = GapEventLog{};
    const paths = try closeGaps(arena, placement, .{}, .{}, &gaps, .{
        .sink = .{ .ctx = &log, .emit = GapEventLog.emit },
    });

    try testing.expectEqual(gaps.len, log.n);
    for (log.seen[0..log.n], 0..) |ev, i| {
        try testing.expectEqual(i, ev.index);
        try testing.expectEqual(paths[i] != null, ev.landed);
    }
    try testing.expect(log.seen[0].landed);
    try testing.expect(!log.seen[1].landed);
    // …and each event's REASON is its own. The skipped hop used to inherit
    // whatever diagnosis the previous hop left behind — here `routed`, from the
    // bridge that landed — so an agent reading `why` saw a hop that produced no
    // copper reporting success against another net's route.
    try testing.expectEqual(GapReason.routed, log.seen[0].why);
    try testing.expectEqual(GapReason.no_such_net, log.seen[1].why);
}

// spec: placement/router - a gap bridge that changes layer never drops its via inside a terminal pad
test "closeGaps keeps its layer-change via out of both terminal pads" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // The far terminal is on the BOTTOM face, so the bridge must change layer.
    const placement = try gapBridgePlacement(arena, .bottom);
    const params = RouteParams{};
    const gaps = [_]Gap{.{
        .net_i = 0,
        .from = .{ .x = 0, .y = 0, .layer = 0 },
        .to = .{ .x = 2, .y = 0, .layer = 1 },
    }};
    const paths = try closeGaps(arena, placement, params, .{}, &gaps, .{});
    const path = paths[0] orelse return error.GapNotClosed;
    try testing.expect(path.vias.len >= 1);
    try testing.expect(touchesPoint(path.tracks, 0, 0));
    try testing.expect(touchesPoint(path.tracks, 2, 0));

    // No barrel may land in either terminal pad: arriving by drilling into the
    // destination is not arriving. Both pads are 0.4 mm square about their part
    // centre, and a via needs its own radius plus clearance beyond that.
    const need = params.via_dia / 2 + params.clearance;
    for (path.vias) |v| {
        try testing.expect(distPointRect(v.x, v.y, .{ .x0 = -0.2, .y0 = -0.2, .x1 = 0.2, .y1 = 0.2 }) >= need - clearance_eps);
        try testing.expect(distPointRect(v.x, v.y, .{ .x0 = 1.8, .y0 = -0.2, .x1 = 2.2, .y1 = 0.2 }) >= need - clearance_eps);
    }
}

/// A board whose two same-net pads are separated by a full-height wall of
/// FOREIGN copper: one track per signal layer at x = 5, running past the top and
/// bottom of the routable area. Nothing can cross it without ripping, and the
/// wall stands 5 mm from either terminal — well outside `ripup_reach_mm` — so
/// only a rip-up tier that reasons about the PATH can find it.
fn walledPlacement(arena: std.mem.Allocator) std.mem.Allocator.Error!optimizer.Placement {
    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const parts = try arena.alloc(Part, 3);
    parts[0] = .{ .ref_des = "A", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 0, .y = 0 };
    parts[1] = .{ .ref_des = "B", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 10, .y = 0 };
    // The wall's owner needs a pad of its own so it is a real net, but park it
    // out of the corridor so it is the WALL, not this pad, that blocks.
    parts[2] = .{ .ref_des = "W", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 5, .y = 5 };
    const sig = try arena.alloc(flat_netlist.FlatPin, 2);
    sig[0] = .{ .ref_des = "A", .pin = "1" };
    sig[1] = .{ .ref_des = "B", .pin = "1" };
    const wall = try arena.alloc(flat_netlist.FlatPin, 1);
    wall[0] = .{ .ref_des = "W", .pin = "1" };
    const nets = try arena.alloc(FlatNet, 2);
    nets[0] = .{ .name = "SIG", .pins = sig };
    nets[1] = .{ .name = "WALL", .pins = wall };
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1,
        .miny = -4,
        .maxx = 11,
        .maxy = 6,
        .generated = true,
    };
}

/// The wall itself: one segment per signal layer, spanning the whole routable
/// height at x = 5. Net index 1 = `WALL`.
fn wallTracks() [2]Track {
    return .{
        .{ .x1 = 5, .y1 = -6, .x2 = 5, .y2 = 8, .layer = 0, .width = 0.2, .net = 1 },
        .{ .x1 = 5, .y1 = -6, .x2 = 5, .y2 = 8, .layer = 1, .width = 0.2, .net = 1 },
    };
}

/// The gap request that must cross the wall.
fn walledGap() Gap {
    return .{
        .net_i = 0,
        .from = .{ .x = 0, .y = 0, .layer = 0 },
        .to = .{ .x = 10, .y = 0, .layer = 0 },
    };
}

// spec: placement/router - a gap pass that cannot reach the far pad reports a blocked channel rather than a sealed terminal
test "closeGaps reports a walled-off bridge as blocked, not sealed" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const placement = try walledPlacement(arena);
    const wall = wallTracks();
    const gaps = [_]Gap{walledGap()};
    var log = GapEventLog{};
    // Rip-up off: the wall stays, so the hop must fail — and the diagnosis must
    // name the CHANNEL, since both pads escape their own footprints fine.
    const paths = try closeGaps(arena, placement, .{}, .{ .tracks = &wall }, &gaps, .{
        .ripup = false,
        .sink = .{ .ctx = &log, .emit = GapEventLog.emit },
    });
    try testing.expect(paths[0] == null);
    try testing.expectEqual(@as(usize, 1), log.n);
    try testing.expectEqual(GapReason.blocked, log.seen[0].why);
}

/// The same wall as `wallTracks`, expressed as an authored lane RESERVATION
/// owned by `net` instead of as copper: a corridor at x = 5 spanning the whole
/// routable height on both signal layers.
fn wallLanes(net: i32) [2]route_policy.ReservedLane {
    return .{
        .{ .x1 = 5, .y1 = -6, .x2 = 5, .y2 = 8, .layer = 0, .net = net, .width = 0.2 },
        .{ .x1 = 5, .y1 = -6, .x2 = 5, .y2 = 8, .layer = 1, .net = net, .width = 0.2 },
    };
}

// spec: placement/reserved-lanes - a finishing hop is refused a lane reserved for another net, and the same hop lands when nothing is reserved
test "a gap hop obeys a foreign net's reserved lane" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const placement = try walledPlacement(arena);
    const gaps = [_]Gap{walledGap()};

    // Control: no copper and no reservation — the corridor is open and the hop
    // lands, so the refusal below is the reservation and nothing else.
    const open = try closeGaps(arena, placement, .{}, .{}, &gaps, .{ .ripup = false });
    try testing.expect(open[0] != null);

    // The wall is now policy rather than metal: net 1 owns x = 5 on both faces.
    // A hop for net 0 has to be refused it — and no rip can win it back, since
    // there is no copper to rip.
    const lanes = wallLanes(1);
    var log = GapEventLog{};
    const walled = try closeGaps(arena, placement, .{}, .{ .reserved_lanes = &lanes }, &gaps, .{
        .ripup = false,
        .sink = .{ .ctx = &log, .emit = GapEventLog.emit },
    });
    try testing.expect(walled[0] == null);
    try testing.expectEqual(GapReason.blocked, log.seen[0].why);
}

// spec: placement/reserved-lanes - a net routes through its OWN reserved lane freely, so a reservation costs its owner nothing
test "a gap hop passes through its own reserved lane" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const placement = try walledPlacement(arena);
    const gaps = [_]Gap{walledGap()};
    // Same geometry as the test above; only the OWNER changes. Net 0 is the net
    // hopping, so the corridor is its own and it walks straight through.
    const lanes = wallLanes(0);
    const paths = try closeGaps(arena, placement, .{}, .{ .reserved_lanes = &lanes }, &gaps, .{ .ripup = false });
    const path = paths[0] orelse return error.GapNotClosed;
    try testing.expect(touchesPoint(path.tracks, 0, 0));
    try testing.expect(touchesPoint(path.tracks, 10, 0));
    try testing.expectEqual(@as(usize, 0), path.ripped.len);
}

// spec: placement/router - a blocked gap bridge rips a foreign net walling its path, not only copper crowding a terminal
test "closeGaps rips the net walling a bridge's path 5 mm from either pad" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const placement = try walledPlacement(arena);
    const wall = wallTracks();
    const gaps = [_]Gap{walledGap()};
    const paths = try closeGaps(arena, placement, .{}, .{ .tracks = &wall }, &gaps, .{});
    const path = paths[0] orelse return error.GapNotClosed;

    // It got through, and it says exactly whose copper it had to take out — the
    // wall's net, which no terminal-local search could have reached.
    try testing.expect(path.ripped.len > 0);
    try testing.expectEqualSlices(i32, &.{1}, path.ripped_nets);
    try testing.expect(touchesPoint(path.tracks, 0, 0));
    try testing.expect(touchesPoint(path.tracks, 10, 0));
}

/// A rip filter that refuses exactly one net.
const OneBannedNet = struct {
    net: i32,

    fn rippable(ctx: ?*anyopaque, net: i32, routing: i32) bool {
        _ = routing;
        const self: *OneBannedNet = @ptrCast(@alignCast(ctx.?));
        return net != self.net;
    }
};

// spec: placement/router - a gap pass's rip-up skips the nets its caller refuses, so its candidate budget is spent on aggressors it may actually move
test "closeGaps never rips a net its caller's filter refuses" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const placement = try walledPlacement(arena);
    const wall = wallTracks();
    const gaps = [_]Gap{walledGap()};

    // Unfiltered, the hop gets through by taking the wall's net (net 1).
    const open = try closeGaps(arena, placement, .{}, .{ .tracks = &wall }, &gaps, .{});
    try testing.expectEqualSlices(i32, &.{1}, (open[0] orelse return error.GapNotClosed).ripped_nets);

    // With that net off limits there is nothing else to move, so the hop fails
    // rather than ripping it anyway.
    var ban = OneBannedNet{ .net = 1 };
    const filtered = try closeGaps(arena, placement, .{}, .{ .tracks = &wall }, &gaps, .{
        .rip_filter = .{ .ctx = &ban, .rippable = OneBannedNet.rippable },
    });
    try testing.expect(filtered[0] == null);
}

/// The same board as `walledPlacement`, with a SECOND foreign net standing its
/// own full-height wall further down the corridor. Ripping either one alone
/// still leaves the other across every path.
fn twiceWalledPlacement(arena: std.mem.Allocator) std.mem.Allocator.Error!optimizer.Placement {
    var placement = try walledPlacement(arena);
    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const parts = try arena.alloc(Part, 4);
    @memcpy(parts[0..3], placement.parts);
    parts[3] = .{ .ref_des = "W2", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 7, .y = 5 };
    const wall2 = try arena.alloc(flat_netlist.FlatPin, 1);
    wall2[0] = .{ .ref_des = "W2", .pin = "1" };
    const nets = try arena.alloc(FlatNet, 3);
    @memcpy(nets[0..2], placement.nets);
    nets[2] = .{ .name = "WALL2", .pins = wall2 };
    placement.parts = parts;
    placement.nets = nets;
    return placement;
}

/// Two walls owned by two different nets: net 1 at x = 3, net 2 at x = 7.
fn twoWallTracks() [4]Track {
    return .{
        .{ .x1 = 3, .y1 = -6, .x2 = 3, .y2 = 8, .layer = 0, .width = 0.2, .net = 1 },
        .{ .x1 = 3, .y1 = -6, .x2 = 3, .y2 = 8, .layer = 1, .width = 0.2, .net = 1 },
        .{ .x1 = 7, .y1 = -6, .x2 = 7, .y2 = 8, .layer = 0, .width = 0.2, .net = 2 },
        .{ .x1 = 7, .y1 = -6, .x2 = 7, .y2 = 8, .layer = 1, .width = 0.2, .net = 2 },
    };
}

// spec: placement/router - an escalated gap bridge walled by several nets at once clears them together once no single rip opens the channel, and names every net it took
test "closeGaps clears two walls together when neither alone opens the channel" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const placement = try twiceWalledPlacement(arena);
    const walls = twoWallTracks();
    const gaps = [_]Gap{walledGap()};

    // The first attempt stays cheap: single-net rips only, and neither wall
    // alone opens the corridor, so the hop finds nothing.
    const first = try closeGaps(arena, placement, .{}, .{ .tracks = &walls }, &gaps, .{});
    try testing.expect(first[0] == null);

    // Escalated, the same hop clears both walls at once.
    const paths = try closeGaps(arena, placement, .{}, .{ .tracks = &walls }, &gaps, .{ .rip_from = 1 });
    const path = paths[0] orelse return error.GapNotClosed;

    // Both walls came out — a rip that took only one of them would have left
    // the other across the finished route.
    try testing.expectEqual(@as(usize, 4), path.ripped.len);
    try testing.expectEqual(@as(usize, 2), path.ripped_nets.len);
    try testing.expect(std.mem.indexOfScalar(i32, path.ripped_nets, 1) != null);
    try testing.expect(std.mem.indexOfScalar(i32, path.ripped_nets, 2) != null);
    try testing.expect(touchesPoint(path.tracks, 0, 0));
    try testing.expect(touchesPoint(path.tracks, 10, 0));

    // …and the copper it drew is genuinely clear of the walls it did NOT get to
    // keep: nothing crosses either wall line except through the gap it made.
    for (path.tracks) |t| {
        try testing.expect(t.net == 0);
    }
}

// spec: placement/router - a gap pass started higher on the rip ladder clears the whole aggressor net instead of a terminal subset
test "closeGaps at the top rip tier clears the whole aggressor net" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const placement = try walledPlacement(arena);
    // Here the wall stands 1.5 mm from pad A — inside `ripup_reach_mm`, so the
    // terminal-local tier can see it — and the same net also owns a stub parked
    // far away at (8,3). The narrow tier takes only the two segments actually in
    // the way; the top rung skips the terminal-local tier entirely and clears
    // every net walling the path, so it takes this net whole, stub included.
    const copper = [_]Track{
        .{ .x1 = 1.5, .y1 = -6, .x2 = 1.5, .y2 = 8, .layer = 0, .width = 0.2, .net = 1 },
        .{ .x1 = 1.5, .y1 = -6, .x2 = 1.5, .y2 = 8, .layer = 1, .width = 0.2, .net = 1 },
        .{ .x1 = 8, .y1 = 3, .x2 = 9, .y2 = 3, .layer = 0, .width = 0.2, .net = 1 },
    };
    const gaps = [_]Gap{walledGap()};

    const narrow = try closeGaps(arena, placement, .{}, .{ .tracks = &copper }, &gaps, .{});
    const wide = try closeGaps(arena, placement, .{}, .{ .tracks = &copper }, &gaps, .{ .rip_from = rip_tiers - 1 });
    const narrow_path = narrow[0] orelse return error.GapNotClosed;
    const wide_path = wide[0] orelse return error.GapNotClosed;
    try testing.expectEqual(copper.len, wide_path.ripped.len);
    try testing.expect(narrow_path.ripped.len < wide_path.ripped.len);
}

/// A board with a THIN signal net and a WIDE net class, separated by a wall of
/// foreign copper with a `half_gap`-tall slot at y = 0. The grid pitch is sized
/// to the wide class (`maxRouteParams`), so this is the fixture that separates
/// "what the routing net physically needs" from "what the board's widest class
/// makes the raster charge".
///
/// Laid out so `x = 5` (the wall) and `y = 0` (the slot centre) both land on gap
/// grid nodes: `ox = minx - 1 = -2`, `oy = miny - 1 = -4.9`, pitch
/// `0.5 + 0.2 = 0.7` halved to `0.35` for the gap pass.
///
/// `sig_wide` gives the SIGNAL net the wide class too — same board, same pitch,
/// only the routed net's own geometry changes.
fn channelPlacement(arena: std.mem.Allocator, sig_wide: bool) std.mem.Allocator.Error!optimizer.Placement {
    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const parts = try arena.alloc(Part, 5);
    const at = struct {
        fn p(ref: []const u8, x: f64, y: f64, pads: []const geometry.Pad) Part {
            return .{ .ref_des = ref, .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = pads, .fallback = false, .x = x, .y = y };
        }
    };
    parts[0] = at.p("A", 0, 0, &pad);
    parts[1] = at.p("B", 10, 0, &pad);
    parts[2] = at.p("W", 5, 5, &pad); // the wall net needs a pad to be a real net
    parts[3] = at.p("C", 0, 2, &pad);
    parts[4] = at.p("D", 10, 2, &pad);
    const nets = try arena.alloc(FlatNet, 3);
    nets[0] = .{ .name = "SIG", .pins = try twoPins(arena, "A", "B") };
    nets[1] = .{ .name = "WALL", .pins = try twoPins(arena, "W", "W") };
    nets[2] = .{ .name = "FAT", .pins = try twoPins(arena, "C", "D") };
    const wide = optimizer.NetRule{ .width = 0.5, .clearance = 0.2 };
    const rules = try arena.alloc(optimizer.NetRule, 3);
    rules[0] = if (sig_wide) wide else .{};
    rules[1] = .{};
    rules[2] = wide;
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .rules = .{ .net = rules },
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1,
        .miny = -3.9,
        .maxx = 11,
        .maxy = 6,
        .generated = true,
    };
}

fn twoPins(arena: std.mem.Allocator, a: []const u8, b: []const u8) std.mem.Allocator.Error![]flat_netlist.FlatPin {
    const pins = try arena.alloc(flat_netlist.FlatPin, 2);
    pins[0] = .{ .ref_des = a, .pin = "1" };
    pins[1] = .{ .ref_des = b, .pin = "1" };
    return pins;
}

/// The wall with a slot: one pair of segments per signal layer at x = 5, leaving
/// `half_gap` of clear board either side of y = 0.
fn slottedWall(arena: std.mem.Allocator, half_gap: f64) std.mem.Allocator.Error![]const Track {
    const out = try arena.alloc(Track, 4);
    for (0..2) |layer| {
        const l: u8 = @intCast(layer);
        out[layer * 2] = .{ .x1 = 5, .y1 = -6, .x2 = 5, .y2 = -half_gap, .layer = l, .width = 0.127, .net = 1 };
        out[layer * 2 + 1] = .{ .x1 = 5, .y1 = half_gap, .x2 = 5, .y2 = 8, .layer = l, .width = 0.127, .net = 1 };
    }
    return out;
}

/// A wall with exactly ONE way through the whole board: a 0.7 mm slot on the
/// TOP face, and solid copper on the bottom. Two hops therefore cannot each
/// take a different face — they genuinely contend for the same channel.
fn singleSlotWall(arena: std.mem.Allocator) std.mem.Allocator.Error![]const Track {
    const out = try arena.alloc(Track, 3);
    out[0] = .{ .x1 = 5, .y1 = -6, .x2 = 5, .y2 = -0.35, .layer = 0, .width = 0.127, .net = 1 };
    out[1] = .{ .x1 = 5, .y1 = 0.35, .x2 = 5, .y2 = 8, .layer = 0, .width = 0.127, .net = 1 };
    out[2] = .{ .x1 = 5, .y1 = -6, .x2 = 5, .y2 = 8, .layer = 1, .width = 0.127, .net = 1 };
    return out;
}

/// A `GapJudge` that refuses hop 0 and keeps every later hop, counting how many
/// times the pass asked.
const VetoFirstHop = struct {
    asked: usize = 0,

    fn keep(ctx: ?*anyopaque, index: usize, path: GapPath) bool {
        _ = path;
        const self: *VetoFirstHop = @ptrCast(@alignCast(ctx orelse return true));
        self.asked += 1;
        return index != 0;
    }
};

// spec: placement/router - a gap pass puts only the copper its caller keeps onto the board the rest of the batch routes against
test "closeGaps leaves a vetoed hop's copper off the board the next hop routes against" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Two thin nets that both have to cross the wall, and one slot between them.
    // The second signal net is re-ruled thin so the contention is the CHANNEL,
    // not a width mismatch.
    var placement = try channelPlacement(arena, false);
    const thin = try arena.alloc(optimizer.NetRule, 3);
    @memset(thin, .{});
    placement.rules.net = thin;
    const wall = try singleSlotWall(arena);
    const gaps = [_]Gap{
        slotGap(),
        .{ .net_i = 2, .from = .{ .x = 0, .y = 2, .layer = 0 }, .to = .{ .x = 10, .y = 2, .layer = 0 } },
    };

    // Kept: hop 0's copper fills the only slot, so hop 1 has nowhere left to go.
    const kept = try closeGaps(arena, placement, .{}, .{ .tracks = wall }, &gaps, .{ .ripup = false });
    try testing.expect(kept[0] != null);
    try testing.expect(kept[1] == null);

    // Vetoed: hop 0 is still routed and still reported — a rejected hop must
    // stay distinguishable from one that found no path — but its copper never
    // lands, so the slot is still free when hop 1 asks for it.
    var veto = VetoFirstHop{};
    const judged = try closeGaps(arena, placement, .{}, .{ .tracks = wall }, &gaps, .{
        .ripup = false,
        .judge = .{ .ctx = &veto, .keep = VetoFirstHop.keep },
    });
    try testing.expect(judged[0] != null);
    try testing.expect(judged[1] != null);
    try testing.expectEqual(@as(usize, 2), veto.asked);
}

/// The SIG bridge across the slot.
fn slotGap() Gap {
    return .{ .net_i = 0, .from = .{ .x = 0, .y = 0, .layer = 0 }, .to = .{ .x = 10, .y = 0, .layer = 0 } };
}

/// Route the SIG bridge through a `half_gap` slot with rip-up OFF, so the only
/// way through is to fit.
fn threadSlot(
    arena: std.mem.Allocator,
    half_gap: f64,
    sig_wide: bool,
) std.mem.Allocator.Error!?GapPath {
    const placement = try channelPlacement(arena, sig_wide);
    const wall = try slottedWall(arena, half_gap);
    const gaps = [_]Gap{slotGap()};
    const paths = try closeGaps(arena, placement, .{}, .{ .tracks = wall }, &gaps, .{ .ripup = false });
    return paths[0];
}

// spec: placement/router - a gap bridge threads a channel sized for its own net class, not for the board's widest
test "closeGaps threads a slot its own class fits and the widest class does not" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // 0.35 mm of clear board either side of centre. The 0.127 mm signal net
    // needs 0.0635 + 0.1905 = 0.254 mm centre-to-centre and fits; the 0.5 mm
    // wide class needs 0.0635 + 0.45 = 0.5135 mm and does not. Both are routed
    // on the SAME board at the SAME grid pitch (sized to the wide class), so the
    // difference is the routed net's own geometry and nothing else.
    try testing.expect((try threadSlot(arena, 0.35, false)) != null);
    try testing.expect((try threadSlot(arena, 0.35, true)) == null);
}

// spec: placement/router - gap copper keeps its own net's real clearance from the foreign copper it threads past
test "closeGaps refuses a slot narrower than its clearance and clears the one it takes" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Below the real requirement (0.254 mm) there is no legal centreline at all.
    try testing.expect((try threadSlot(arena, 0.15, false)) == null);

    // And the copper it does lay through a slot it fits stays outside every
    // wall segment's clearance — the exact rule, measured segment to segment.
    const path = (try threadSlot(arena, 0.35, false)) orelse return error.GapNotClosed;
    const wall = try slottedWall(arena, 0.35);
    const need: f64 = 0.127 / 2.0 + 0.127 / 2.0 + 0.127;
    for (path.tracks) |t| {
        for (wall) |w| {
            if (w.layer != t.layer) continue;
            const d = segSegDist(.{ t.x1, t.y1 }, .{ t.x2, t.y2 }, .{ w.x1, w.y1 }, .{ w.x2, w.y2 });
            try testing.expect(d >= need - clearance_eps);
        }
    }
}

/// The wall with its slot pushed OFF the divisor-2 lattice: clear board from
/// y = -0.3005 to y = 0.2795, centred on -0.0105 — a divisor-4 lattice line
/// only (the gap pass rasters this board at the BASE pitch 0.254 halved, so
/// its divisor-2 lanes from oy = -4.9 land at y = -0.074 and y = 0.053). The
/// 0.58 mm opening physically fits the 0.127 mm signal net with 0.036 mm to
/// spare, but both divisor-2 nodes sit 0.2265 mm from a wall tip — inside the
/// 0.254 mm the exact clearance test demands — and every diagonal between
/// them passes at 0.239 mm or closer, so no legal crossing is representable
/// at the standard gap pitch. This is board-a's J1 contention in miniature:
/// the corridor is real, the lattice just has no lane in it.
fn offLatticeSlotWall(arena: std.mem.Allocator) std.mem.Allocator.Error![]const Track {
    const out = try arena.alloc(Track, 4);
    for (0..2) |layer| {
        const l: u8 = @intCast(layer);
        out[layer * 2] = .{ .x1 = 5, .y1 = -6, .x2 = 5, .y2 = -0.3005, .layer = l, .width = 0.127, .net = 1 };
        out[layer * 2 + 1] = .{ .x1 = 5, .y1 = 0.2795, .x2 = 5, .y2 = 8, .layer = l, .width = 0.127, .net = 1 };
    }
    return out;
}

// spec: placement/router - a gap pass re-asked on a finer grid divisor threads a corridor whose only legal lane is invisible at the standard gap pitch
test "closeGaps threads an off-lattice slot only when the caller raises grid_divisor" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const placement = try channelPlacement(arena, false);
    const wall = try offLatticeSlotWall(arena);
    const gaps = [_]Gap{slotGap()};

    // Raster only, standard divisor: the slot is real but no lane through it is
    // on the grid. `shape = false` is what makes this a statement about the
    // MAZE — the gridless tier exists precisely to draw this corridor, so with
    // it in play the question "can the lattice see this lane" cannot be asked.
    const coarse = try closeGaps(arena, placement, .{}, .{ .tracks = wall }, &gaps, .{
        .ripup = false,
        .shape = .off,
    });
    try testing.expect(coarse[0] == null);

    // Same board, same request, divisor 4: the lane exists and the hop lands.
    const fine = try closeGaps(arena, placement, .{}, .{ .tracks = wall }, &gaps, .{
        .ripup = false,
        .shape = .off,
        .raster = .{ .divisor = 4 },
    });
    try testing.expect(fine[0] != null);

    // And the point of the other tier: the SAME coarse request lands anyway
    // once the gridless router is allowed to answer it. "The corridor is real,
    // the lattice just has no lane in it" is a description of this fixture, so
    // a mesh with no lattice is expected to thread it without the finer raster.
    const shaped = try closeGaps(arena, placement, .{}, .{ .tracks = wall }, &gaps, .{ .ripup = false });
    try testing.expect(shaped[0] != null);
    try testing.expectEqual(@as(usize, 0), shaped[0].?.ripped.len);
}

/// A board with one SIG pad sitting over two fully-overlapping bottom-layer
/// pours: SIG's own, and a foreign PLANE pour. Which of the two actually has
/// copper under the pad is decided entirely by their priorities.
fn clippedPourPlacement(arena: std.mem.Allocator) std.mem.Allocator.Error!optimizer.Placement {
    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const parts = try arena.alloc(Part, 2);
    parts[0] = .{ .ref_des = "A", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 0, .y = 0 };
    parts[1] = .{ .ref_des = "P", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 4, .y = 4 };
    const nets = try arena.alloc(FlatNet, 2);
    nets[0] = .{ .name = "SIG", .pins = try twoPins(arena, "A", "A") };
    nets[1] = .{ .name = "PLANE", .pins = try twoPins(arena, "P", "P") };
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -2,
        .miny = -2,
        .maxx = 6,
        .maxy = 6,
        .generated = true,
    };
}

/// Stitch the SIG pad to its own pour when the foreign pour over it ranks
/// `foreign_priority` and SIG's ranks 1.
fn stitchUnderPours(arena: std.mem.Allocator, foreign_priority: i64) std.mem.Allocator.Error!?GapPath {
    const placement = try clippedPourPlacement(arena);
    const square = try arena.alloc([2]f64, 4);
    square[0] = .{ -2, -2 };
    square[1] = .{ 3, -2 };
    square[2] = .{ 3, 3 };
    square[3] = .{ -2, 3 };
    const zones = try arena.alloc(route_policy.ExistingZone, 2);
    zones[0] = .{ .polygon = square, .layer = 1, .net = 0, .priority = 1 };
    zones[1] = .{ .polygon = square, .layer = 1, .net = 1, .priority = foreign_priority };
    const gaps = [_]Gap{.{ .net_i = 0, .from = .{ .x = 0, .y = 0, .layer = 0 } }};
    const paths = try closeGaps(arena, placement, .{}, .{ .zones = zones }, &gaps, .{ .ripup = false });
    return paths[0];
}

// spec: placement/router - a plane stitch lands only where its own pour's copper survives a higher-priority overlap
test "closeGaps refuses a plane stitch into a pour a higher-priority pour clipped away" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Foreign pour outranks SIG's: SIG's fill is knocked back everywhere the two
    // overlap, so there is no copper for a via to land on and the stitch must
    // find no site rather than drill into the clearance gap.
    try testing.expect((try stitchUnderPours(arena, 2)) == null);

    // Outranked by SIG's own pour, the same board stitches: the copper is there.
    const path = (try stitchUnderPours(arena, 0)) orelse return error.GapNotClosed;
    try testing.expect(path.vias.len > 0);
}

// spec: placement/reserved-lanes - a supply stitch cannot cross a foreign reserved lane to reach an otherwise legal via site in its own pour
test "a supply stitch respects reservations along its stub as well as at its via" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();
    const placement = try clippedPourPlacement(arena);
    // The only carrier starts beyond x=1.2. A via can land there, but its
    // surface stub must cross x=0.7 to get from the pad at the origin.
    const polygon = [_][2]f64{ .{ 1.2, -1 }, .{ 3, -1 }, .{ 3, 1 }, .{ 1.2, 1 } };
    const zones = [_]route_policy.ExistingZone{.{ .polygon = &polygon, .layer = 1, .net = 0 }};
    const gaps = [_]Gap{.{ .net_i = 0, .from = .{ .x = 0, .y = 0, .layer = 0 } }};
    const options = router.GapOptions{
        .ripup = false,
        .constraints = .{ .net = &.{.{ .allowed_layers = 1, .max_vias = 1 }} },
    };
    const open = try closeGaps(arena, placement, .{}, .{ .zones = &zones }, &gaps, options);
    const direct = open[0] orelse return error.GapNotClosed;
    try testing.expect(direct.tracks.len > 0);
    try testing.expectEqual(@as(usize, 1), direct.vias.len);
    var lanes = [_]route_policy.ReservedLane{.{ .net = 1, .x1 = 0.7, .y1 = -10, .x2 = 0.7, .y2 = 10, .layer = 0, .width = 0.3 }};
    const blocked = try closeGaps(arena, placement, .{}, .{ .zones = &zones, .reserved_lanes = &lanes }, &gaps, options);
    try testing.expect(blocked[0] == null);
    lanes[0].net = 0;
    const owned = try closeGaps(arena, placement, .{}, .{ .zones = &zones, .reserved_lanes = &lanes }, &gaps, options);
    try testing.expect(owned[0] != null);
}

/// Two same-net terminals `A`/`B` with a FOREIGN VIA already on the board.
///
/// A via is board copper and nothing else: it is in no pad table, so the only
/// thing that can hold a hop off it is the routing pass's own clearance probe.
/// `A`'s pad centre sits OFF the raster deliberately — its nearest grid node is
/// somewhere else — so the hop must draw a real terminal stub from that centre
/// to whichever node the maze entered through, which is the one piece of a maze
/// hop no lattice move ever validates.
///
/// The base params are the widest class on the board while `SIG` itself is a
/// thin 0.127 mm net, which is what a real board looks like (the raster pitch
/// is sized by the widest class) and what makes the stub longer than the thin
/// net's own clearance.
fn viaWalledPlacement(arena: std.mem.Allocator) std.mem.Allocator.Error!optimizer.Placement {
    const pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
    const parts = try arena.alloc(Part, 2);
    parts[0] = .{ .ref_des = "A", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 0.2, .y = 0.1 };
    parts[1] = .{ .ref_des = "B", .kind = .passive, .hw = 0.3, .hh = 0.3, .pads = &pad, .fallback = false, .x = 2, .y = 0 };
    const sig = try arena.alloc(flat_netlist.FlatPin, 2);
    sig[0] = .{ .ref_des = "A", .pin = "1" };
    sig[1] = .{ .ref_des = "B", .pin = "1" };
    const nets = try arena.alloc(FlatNet, 2);
    nets[0] = .{ .name = "SIG", .pins = sig };
    nets[1] = .{ .name = "BLOCK", .pins = &.{} };
    const rules = try arena.alloc(optimizer.NetRule, 2);
    rules[0] = .{ .width = 0.127, .clearance = 0.127 };
    rules[1] = .{};
    var placement = optimizer.Placement{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1,
        .miny = -2,
        .maxx = 3,
        .maxy = 2,
        .generated = true,
    };
    placement.rules.net = rules;
    return placement;
}

/// The closest any emitted track's centreline comes to `(x, y)`.
fn minTrackPointGap(tracks: []const Track, x: f64, y: f64) f64 {
    var best = std.math.inf(f64);
    for (tracks) |t| best = @min(best, pad_shape.segPointDist(t.x1, t.y1, t.x2, t.y2, x, y));
    return best;
}

// spec: placement/router - a gap hop's terminal stub is probed against the live board copper, so it cannot be drawn through a via the maze itself routed around
test "closeGaps draws its terminal stub against the board's own vias" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    const placement = try viaWalledPlacement(arena);
    // Widest-class base geometry; SIG routes at its own declared 0.127 mm.
    const params = RouteParams{ .track_width = 0.5, .clearance = 0.4 };
    const vias = [_]router.Via{.{ .x = 0.75, .y = 0.15, .dia = 0.4, .drill = 0.2, .net = 1 }};
    const gaps = [_]Gap{.{
        .net_i = 0,
        .from = .{ .x = 0.2, .y = 0.1, .layer = 0 },
        .to = .{ .x = 2, .y = 0, .layer = 0 },
    }};
    const paths = try closeGaps(arena, placement, params, .{ .vias = &vias }, &gaps, .{});
    const path = paths[0] orelse return error.GapNotClosed;

    // The hop still joins both pads…
    try testing.expect(touchesPoint(path.tracks, 0.2, 0.1));
    try testing.expect(touchesPoint(path.tracks, 2, 0));
    // …and every millimetre of it clears the foreign barrel. The maze's own
    // moves always did; the terminal stub used to be measured against the hop's
    // own (empty) copper list, so it was drawn straight through the via —
    // 0.106 mm centre-to-centre where this net needs 0.391.
    const sig_width: f64 = 0.127;
    const sig_clearance: f64 = 0.127;
    const need = vias[0].dia / 2 + sig_width / 2 + sig_clearance;
    try testing.expect(minTrackPointGap(path.tracks, vias[0].x, vias[0].y) >= need - clearance_eps);
}
