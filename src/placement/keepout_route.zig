//! End-to-end tests for the ROUTER's half of the RF trace-protection rules —
//! `(net-class … (keepout MM))`'s same-layer halo, its NET-GATED escape
//! exemption, and the all-layer crossing shadow a `(keepout …)`/`(fence …)`
//! class casts (`rf_shadow`) — driven entirely through the public
//! `router.route` / `routeWithOptions` seam.
//!
//! They live outside `router.zig` because that file sits against its hard
//! file-size cap, and because a behavioural test is the right shape for this
//! rule: the interesting claims are about the copper a full solve produces —
//! foreign copper leaves the halo on the keepout net's own layer, the other layer
//! stays free, a ground net is never held off, and a halo carried by RETAINED
//! copper still holds. Each is asserted against a baseline run of the same board
//! with no keepout declared, so no test can pass vacuously.
//!
//! The predicate-level tests for the shared semantics are in `keepout.zig`, and
//! the post-route check's are in `drc_keepout.zig`.

const std = @import("std");
const optimizer = @import("optimizer.zig");
const router = @import("router.zig");
const rf_shadow = @import("rf_shadow.zig");
const via_fence = @import("via_fence.zig");
const route_policy = @import("route_policy.zig");
const geometry = @import("geometry.zig");
const pad_shape = @import("pad_shape.zig");
const flat_netlist = @import("../flat_netlist.zig");

const testing = std.testing;

/// The halo the fenced runs declare — 0.5 mm, the value a real RF class uses.
const halo_mm: f64 = 0.5;
/// Default routed track width (mm), so a centreline gap can be turned into the
/// edge-to-edge distance the keepout rule is actually stated in.
const track_w: f64 = 0.127;
/// The y of the RF trace every assertion measures against.
const rf_y: f64 = 5;

/// Net indices on the boards below.
const rf_net: i32 = 0;
const other_net: i32 = 1;

/// A four-part board: an RF net running straight along `rf_y` from x = 0 to
/// x = 12 (routed first via `(priority 7)`), and a second net whose two pads sit
/// 0.5 mm above it at x = 2 and x = 10 — close enough that the shortest route
/// hugs the RF trace for its whole length unless a halo pushes it off.
///
/// `other` names the second net, so the same geometry can be a signal net (an
/// aggressor) or a ground net (exempt).
const Board = struct {
    parts: [4]optimizer.Part,
    rules: [2]optimizer.NetRule,
    nets: [2]optimizer.FlatNet,
    layers: usize,

    fn placement(self: *Board) optimizer.Placement {
        return .{
            .parts = &self.parts,
            .links = &.{},
            .loops = &.{},
            .stubs = &.{},
            .instances = &.{},
            .nets = &self.nets,
            .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
            .minx = -1,
            .miny = 1,
            .maxx = 13,
            .maxy = 9,
            .generated = true,
            // A declared 2-layer stackup with no plane: ground is ordinary
            // routed copper here, which is what lets the ground-exemption test
            // watch a GND net route through the halo instead of being skipped as
            // plane-carried.
            .rules = .{ .net = &self.rules, .plane_nets = &.{}, .copper_layers = 2 },
        };
    }
};

const one_pad = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }};
const rf_pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "J1", .pin = "1" }, .{ .ref_des = "J2", .pin = "1" } };
const other_pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };

/// `halo` mm of `(keepout …)` on the RF class (0 = none declared), with the
/// second net named `other`.
fn board(halo: f64, other: []const u8) Board {
    return .{
        .parts = .{
            part1("J1", 0, rf_y),
            part1("J2", 12, rf_y),
            part1("R1", 2, rf_y + 0.5),
            part1("R2", 10, rf_y + 0.5),
        },
        .rules = .{ .{ .priority = 7, .rf = .{ .keepout_mm = halo } }, .{} },
        .nets = .{
            .{ .name = "RF_IN", .pins = &rf_pins },
            .{ .name = other, .pins = &other_pins },
        },
        .layers = 2,
    };
}

/// The same board with the second net's two parts mounted on the BOTTOM face, so
/// its whole route lives on the far copper layer and needs no via at all.
fn bottomBoard(halo: f64) Board {
    var b = board(halo, "SPI_SCK");
    b.parts[2].side = .bottom;
    b.parts[3].side = .bottom;
    return b;
}

/// A one-pad part at (x, y).
fn part1(ref: []const u8, x: f64, y: f64) optimizer.Part {
    return .{
        .ref_des = ref,
        .kind = .passive,
        .hw = 0.3,
        .hh = 0.3,
        .pads = &one_pad,
        .fallback = false,
        .x = x,
        .y = y,
    };
}

/// Closest approach (mm) of `net`'s copper on `layer` to the RF trace, measured
/// only in the x-window [4, 8] — the middle of the RF run, clear of both of the
/// other net's pads, whose own landings the halo deliberately leaves open (a pad
/// is never an offender, and a pad its own net cannot escape would be a
/// contradiction). `inf` when the net laid no copper there at all, which is a
/// pass: the route either detoured out of the window or changed layer.
fn midSpanGap(tracks: []const router.Track, net: i32, layer: u8) f64 {
    var best = std.math.inf(f64);
    for (tracks) |t| {
        if (t.net != net or t.layer != layer) continue;
        for (0..21) |s| {
            const f = @as(f64, @floatFromInt(s)) / 20.0;
            const x = t.x1 + f * (t.x2 - t.x1);
            if (x < 4 or x > 8) continue;
            best = @min(best, @abs(t.y1 + f * (t.y2 - t.y1) - rf_y));
        }
    }
    return best;
}

/// The same measurement as an EDGE-TO-EDGE gap, which is how the keepout rule is
/// stated: two default-width tracks a centreline distance `c` apart leave
/// `c - track_w` of bare laminate between their copper.
fn midSpanEdgeGap(tracks: []const router.Track, net: i32, layer: u8) f64 {
    return midSpanGap(tracks, net, layer) - track_w;
}

/// Closest approach (mm) of `net`'s vias to the RF trace inside the same window.
fn midSpanViaGap(vias: []const router.Via, net: i32) f64 {
    var best = std.math.inf(f64);
    for (vias) |v| {
        if (v.net != net or v.x < 4 or v.x > 8) continue;
        best = @min(best, @abs(v.y - rf_y));
    }
    return best;
}

const guard_smd = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 1, .h = 1 }};
const guard_thru = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 0, .w = 1, .h = 1, .thru = true, .drill = 0.3 }};
const guard_pin = [_]flat_netlist.FlatPin{.{ .ref_des = "U1", .pin = "1" }};
const crossing_pins = [_]flat_netlist.FlatPin{ .{ .ref_des = "R1", .pin = "1" }, .{ .ref_des = "R2", .pin = "1" } };

/// One guarded RF pad with a signal run 0.2 mm beyond its copper edge: legal by
/// ordinary clearance, but inside `halo_mm`. `bottom` moves both signal pads to
/// B.Cu; `thru` decides whether the RF pad reaches that face.
fn padBoard(halo: f64, thru: bool, bottom: bool) Board {
    var b = board(halo, "SPI_SCK");
    b.parts[0] = .{ .ref_des = "U1", .kind = .hub, .hw = 0.5, .hh = 0.5, .pads = if (thru) &guard_thru else &guard_smd, .fallback = false, .x = 6, .y = rf_y };
    b.parts[1] = part1("R1", 2, rf_y + 0.7);
    b.parts[2] = part1("R2", 10, rf_y + 0.7);
    b.parts[3] = part1("NC", 12.5, 8.5);
    b.parts[1].side = if (bottom) .bottom else .top;
    b.parts[2].side = if (bottom) .bottom else .top;
    b.nets = .{
        .{ .name = "RF_PAD", .pins = &guard_pin },
        .{ .name = "SPI_SCK", .pins = &crossing_pins },
    };
    return b;
}

/// Closest edge-to-edge approach of the signal net's track/via copper to the
/// guarded 1 mm square pad at (6, `rf_y`).
fn guardPadGap(r: router.RouteResult, layer: u8) f64 {
    const shape = pad_shape.Shape{ .x0 = 5.5, .y0 = rf_y - 0.5, .x1 = 6.5, .y1 = rf_y + 0.5 };
    var best = std.math.inf(f64);
    for (r.tracks) |t| {
        if (t.net != other_net or t.layer != layer) continue;
        best = @min(best, pad_shape.segmentDist(shape, .{ t.x1, t.y1 }, .{ t.x2, t.y2 }, 2) - t.width / 2);
    }
    for (r.vias) |v| {
        if (v.net != other_net) continue;
        best = @min(best, pad_shape.pointDist(shape.x0, shape.y0, shape.x1, shape.y1, shape.poly, v.x, v.y, 2) - v.dia / 2);
    }
    return best;
}

// spec: placement/router - a declared keepout halo pushes a later net's copper and vias off the keepout net's own layer
test "a keepout halo detours a neighbour that otherwise hugs the RF trace" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Baseline: no keepout. Clearance alone lets the signal run 0.5 mm off the
    // RF trace for its whole length — which is what makes this board a test.
    var plain = board(0, "SPI_SCK");
    const before = try router.route(arena, plain.placement(), .{});
    try testing.expectEqual(@as(usize, 2), before.routed);
    try testing.expect(midSpanEdgeGap(before.tracks, other_net, 0) < halo_mm);

    // With the halo declared, the signal may no longer occupy that band on the
    // RF net's own layer — nor may it drop a via there, since a through barrel
    // reaches the RF layer whatever layer the track changed from. Both nets
    // still route: the halo redirects copper, it does not wall the board off.
    var fenced = board(halo_mm, "SPI_SCK");
    const after = try router.route(arena, fenced.placement(), .{});
    try testing.expectEqual(@as(usize, 2), after.routed);
    try testing.expect(midSpanEdgeGap(after.tracks, other_net, 0) >= halo_mm);
    try testing.expect(midSpanViaGap(after.vias, other_net) >= halo_mm);
    // The keepout net routes through its own halo, unaffected.
    try testing.expect(midSpanGap(after.tracks, rf_net, 0) < 0.2);
}

// spec: placement/router - a keepout net's component pad stamps its exact halo on the SMD face and every signal layer when through-hole
test "a keepout component pad detours foreign routing around its copper" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Without the rule, ordinary clearance permits the top signal 0.2 mm from
    // the RF pad edge. With it, the same board still routes but leaves 0.5 mm.
    var plain = padBoard(0, false, false);
    const before = try router.route(arena, plain.placement(), .{});
    try testing.expectEqual(@as(usize, 1), before.routed);
    try testing.expect(guardPadGap(before, 0) < halo_mm);
    var smd = padBoard(halo_mm, false, false);
    const top = try router.route(arena, smd.placement(), .{});
    try testing.expectEqual(@as(usize, 1), top.routed);
    try testing.expect(guardPadGap(top, 0) >= halo_mm - 1e-6);

    // An SMD pad does not impose a hard keepout on the far face. Make it a
    // through pad and the identical B.Cu route must leave the halo there too.
    var far_smd = padBoard(halo_mm, false, true);
    const legal_under = try router.route(arena, far_smd.placement(), .{});
    try testing.expect(guardPadGap(legal_under, 1) < halo_mm);
    var thru = padBoard(halo_mm, true, true);
    const bottom = try router.route(arena, thru.placement(), .{});
    try testing.expectEqual(@as(usize, 1), bottom.routed);
    try testing.expect(guardPadGap(bottom, 1) >= halo_mm - 1e-6);
}

// spec: placement/router - the far copper layer under an RF trace stays passable, but a run parallel to the trace there pays the corridor shadow
test "a parallel run on the far copper layer is pushed out of the RF corridor" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // The second net's parts are mounted on the BOTTOM face, so its entire route
    // is B.Cu copper directly beneath the RF trace. The HALO still does not reach
    // there — the board is the shield, and a crossing underneath stays legal (see
    // the crossing test below). What this board is, though, is the case the halo
    // alone never covered: an 8 mm run ALONGSIDE the trace, one layer down,
    // sitting in the fence corridor for its whole length and blocking every
    // through-hole fence site on it. The shadow prices that out.
    var plain = bottomBoard(0);
    const before = try router.route(arena, plain.placement(), .{});
    try testing.expectEqual(@as(usize, 2), before.routed);
    // Baseline: it hugs the trace at its pads' own 0.5 mm offset.
    try testing.expect(midSpanGap(before.tracks, other_net, 1) <= 0.51);

    var fenced = bottomBoard(halo_mm);
    const after = try router.route(arena, fenced.placement(), .{});
    // Still routed — the shadow is a cost, never a wall.
    try testing.expectEqual(@as(usize, 2), after.routed);
    // …and the mid-span run has left the corridor (0.5 mm from the trace's copper
    // edge; `inf` if it vacated the window altogether, which also passes).
    try testing.expect(midSpanGap(after.tracks, other_net, 1) > halo_mm + track_w / 2);
}

/// A board whose second net MUST cross the RF trace, and whose cheapest crossing
/// without a shadow is the worst one: its first bottom-side pad sits 1 mm clear of
/// the trace on one side, its second 0.4 mm from it on the other and 8 mm along —
/// so the shortest route dives across at once and then runs the whole span INSIDE
/// the corridor to reach it. `other` names the second net so ground can take the
/// same route and prove it pays nothing.
fn crossBoard(halo: f64, other: []const u8) Board {
    var b = board(halo, other);
    b.parts[2] = part1("R1", 2, rf_y + 1.0);
    b.parts[3] = part1("R2", 10, rf_y - 0.4);
    b.parts[2].side = .bottom;
    b.parts[3].side = .bottom;
    return b;
}

/// Length (mm) of `net`'s copper on `layer` lying inside the RF corridor band
/// |y − rf_y| <= `band` — how much of a crossing is spent under the trace. A
/// square crossing spends about one band width; a shallow one, many.
fn shadowSpan(tracks: []const router.Track, net: i32, layer: u8, band: f64) f64 {
    var total: f64 = 0;
    for (tracks) |t| {
        if (t.net != net or t.layer != layer) continue;
        const len = std.math.hypot(t.x2 - t.x1, t.y2 - t.y1);
        const steps: usize = 200;
        for (0..steps) |s| {
            const f = (@as(f64, @floatFromInt(s)) + 0.5) / @as(f64, @floatFromInt(steps));
            if (@abs(t.y1 + f * (t.y2 - t.y1) - rf_y) <= band) total += len / @as(f64, @floatFromInt(steps));
        }
    }
    return total;
}

/// The corridor half-width (mm) the shadow bands a default-width RF trace with
/// under `halo_mm` of keepout: its own half-width plus the corridor.
const corridor_band: f64 = track_w / 2 + halo_mm;

// spec: placement/router - a foreign net crossing a shadowed RF corridor crosses it roughly square instead of running along it
test "a forced crossing crosses the RF corridor about square" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // The pad-axis terminal rule already steers the unconstrained route into a
    // short crossing rather than letting it leave the first pad diagonally and
    // shadow the protected trace for the whole span.
    var plain = crossBoard(0, "SPI_SCK");
    const before = try router.route(arena, plain.placement(), .{});
    try testing.expectEqual(@as(usize, 2), before.routed);
    const loose = shadowSpan(before.tracks, other_net, 1, corridor_band);

    // Pricing the corridor must keep that square crossing and never turn the
    // preferred terminal escape back into a long in-shadow run.
    var fenced = crossBoard(halo_mm, "SPI_SCK");
    const after = try router.route(arena, fenced.placement(), .{});
    try testing.expectEqual(@as(usize, 2), after.routed);
    const tight = shadowSpan(after.tracks, other_net, 1, corridor_band);
    // A square crossing of a 2·band corridor is 2·band of copper; allow the 45°
    // lattice its √2, plus the stretch out of the pad that starts inside the band.
    try testing.expect(loose < 2 * corridor_band * 2.0);
    try testing.expect(tight < 2 * corridor_band * 2.0);
    try testing.expect(tight <= loose + 0.1);
}

// spec: placement/router - ground copper crosses an RF corridor without paying the shadow, so a return path may still follow the trace
test "a ground net crosses and follows the RF corridor untouched" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Ground is the wanted shield on every layer, not an aggressor, so declaring
    // the keepout must leave its copper exactly where it was.
    var plain = crossBoard(0, "GND");
    const before = try router.route(arena, plain.placement(), .{});
    try testing.expectEqual(@as(usize, 2), before.routed);
    var fenced = crossBoard(halo_mm, "GND");
    const after = try router.route(arena, fenced.placement(), .{});
    try testing.expectEqual(@as(usize, 2), after.routed);
    try testing.expectApproxEqAbs(
        shadowSpan(before.tracks, other_net, 1, corridor_band),
        shadowSpan(after.tracks, other_net, 1, corridor_band),
        1e-9,
    );
    // And the parallel-run board too: a coplanar return may hug the trace.
    var pplain = bottomBoard(0);
    pplain.nets[1].name = "GND";
    const p_before = try router.route(arena, pplain.placement(), .{});
    var pfenced = bottomBoard(halo_mm);
    pfenced.nets[1].name = "GND";
    const p_after = try router.route(arena, pfenced.placement(), .{});
    try testing.expectApproxEqAbs(
        midSpanGap(p_before.tracks, other_net, 1),
        midSpanGap(p_after.tracks, other_net, 1),
        1e-9,
    );
}

/// The filter case: the RF net's two pads only 2 mm apart, so a `(keepout …
/// (escape 1.5))` puts BOTH escape zones over the whole span between them — and
/// ungated, that reads as an open corridor straight between the two RF pads.
/// `neighbour` gives the second net a pad inside the first zone (the breakout the
/// exemption is for) instead of parking both its pads off the ends.
fn filterBoard(halo: f64, escape: f64, neighbour: bool) Board {
    var b = board(halo, "SPI_SCK");
    b.parts[0] = part1("J1", 5, rf_y);
    b.parts[1] = part1("J2", 7, rf_y);
    b.parts[2] = part1("R1", if (neighbour) 5.6 else 1, rf_y + 0.4);
    b.parts[3] = part1("R2", 11, rf_y + 0.4);
    b.rules[0].rf.keepout_escape_mm = escape;
    return b;
}

/// Closest approach (mm) of `net`'s top-layer copper to the RF trace strictly
/// BETWEEN the two RF pads of `filterBoard` — the corridor the ungated escape
/// exemption opened.
fn betweenPadsGap(tracks: []const router.Track, net: i32) f64 {
    var best = std.math.inf(f64);
    for (tracks) |t| {
        if (t.net != net or t.layer != 0) continue;
        for (0..41) |s| {
            const f = @as(f64, @floatFromInt(s)) / 40.0;
            const x = t.x1 + f * (t.x2 - t.x1);
            if (x < 5.3 or x > 6.7) continue;
            best = @min(best, @abs(t.y1 + f * (t.y2 - t.y1) - rf_y));
        }
    }
    return best;
}

// spec: placement/router - a keepout escape zone lets out the neighbour pin that owns a pad in it and refuses a net merely passing between two RF pads
test "the escape exemption is net-gated, so no passer-by threads between two RF pads" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Baseline with no keepout: the neighbour runs straight down the corridor
    // between the two RF pads, 0.4 mm off the trace.
    var plain = filterBoard(0, 0, false);
    const before = try router.route(arena, plain.placement(), .{});
    try testing.expectEqual(@as(usize, 2), before.routed);
    try testing.expect(betweenPadsGap(before.tracks, other_net) <= 0.45);

    // Declared halo with an escape radius wide enough to cover the WHOLE span
    // between the pads. Ungated that opening cancelled the halo along the very
    // stretch it was protecting; gated, this net owns no pad in either zone and
    // is pushed out.
    var fenced = filterBoard(halo_mm, 1.5, false);
    const after = try router.route(arena, fenced.placement(), .{});
    try testing.expectEqual(@as(usize, 2), after.routed);
    try testing.expect(betweenPadsGap(after.tracks, other_net) >= halo_mm + track_w);

    // The neighbour-pin case the exemption exists for still gets out: give the
    // second net a pad of its own inside the first zone and its copper is allowed
    // right beside the RF pad again.
    var admitted = filterBoard(halo_mm, 1.5, true);
    const out = try router.route(arena, admitted.placement(), .{});
    try testing.expectEqual(@as(usize, 2), out.routed);
    try testing.expect(betweenPadsGap(out.tracks, other_net) < halo_mm);
}

// spec: placement/router - the router's fence-corridor width agrees with the via-fence generator's own gap and via resolution
test "the shadow corridor equals via_fence's resolved gap plus its fence via" {
    const design = optimizer.DesignRules{ .clearance = 0.15, .via_dia = 0.45, .via_drill = 0.25 };
    const cases = [_]optimizer.NetRule{
        .{ .rf = .{ .fence = .{ .declared = true } } }, // derive gap and via
        .{ .rf = .{ .fence = .{ .declared = true, .offset_mm = 0.3 } } }, // authored gap
        .{ .rf = .{ .fence = .{ .declared = true, .via_dia = 0.8 } } }, // authored fence via
        .{ .clearance = 0.25, .via_dia = 0.6, .rf = .{ .fence = .{ .declared = true } } }, // class fallbacks
        .{ .rf = .{ .max_freq_hz = 12e9 } }, // derived fence target, no authored fence
    };
    for (cases) |rule| {
        var b = board(0, "SPI_SCK");
        b.rules[0] = rule;
        // `via_fence` is the source of truth; `rf_shadow` replicates the two
        // formulas because it sits BELOW the router that `via_fence` reads. This
        // is the pin that keeps the copy honest.
        const want = via_fence.resolvedGapMm(rule, design) + via_fence.resolvedFenceVia(rule, design).dia;
        var p = b.placement();
        p.rules = .{ .net = &b.rules, .design = design };
        try testing.expectApproxEqAbs(want, rf_shadow.widthOf(p, 0), 1e-12);
    }

    // The fence corridor is a floor, not a replacement: a wider authored
    // keepout remains the protected width.
    var b = board(0, "SPI_SCK");
    b.rules[0] = .{ .rf = .{ .max_freq_hz = 12e9, .keepout_mm = 1.1 } };
    var p = b.placement();
    p.rules = .{ .net = &b.rules, .design = design };
    try testing.expectApproxEqAbs(@as(f64, 1.1), rf_shadow.widthOf(p, 0), 1e-12);
}

// spec: placement/router - a ground net is never held off by a keepout halo, so a stitching return may hug the RF trace
test "a ground net routes through the keepout halo untouched" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // Identical geometry, second net renamed GND. Ground is the wanted fence, so
    // its copper must land exactly where the signal was pushed out of.
    var plain = board(0, "GND");
    const before = try router.route(arena, plain.placement(), .{});
    try testing.expectEqual(@as(usize, 2), before.routed);
    const baseline = midSpanGap(before.tracks, other_net, 0);

    var fenced = board(halo_mm, "GND");
    const after = try router.route(arena, fenced.placement(), .{});
    try testing.expectEqual(@as(usize, 2), after.routed);
    // Same route as with no keepout at all — the exemption, not a detour.
    try testing.expectApproxEqAbs(baseline, midSpanGap(after.tracks, other_net, 0), 1e-9);
    try testing.expect(midSpanEdgeGap(after.tracks, other_net, 0) < halo_mm);
}

/// `board`'s parallel run with both nets put in authored classes: the RF net in
/// `rf`, the neighbour in `other_class`. Only the RF class declares the halo —
/// giving the neighbour one too would say nothing about class IDENTITY and would
/// reorder the route (a keepout net routes ahead of the queue), which is a
/// different mechanism.
///
/// The deliberately hair-thin `(fence …)` is a regression fixture: it must NOT
/// collapse the protected corridor below the wider 0.5 mm authored halo. The
/// hard same-layer halo remains class-exempt, while the soft all-layer fence
/// corridor is deliberately not — it can only cost a detour, never a net.
fn classedBoard(other_class: []const u8) Board {
    var b = board(halo_mm, "SPI_SCK");
    b.rules[0].class = .{ .name = "rf" };
    b.rules[0].rf.fence = .{ .declared = true, .offset_mm = 0.001, .via_dia = 0.001 };
    b.rules[1].class = .{ .name = other_class };
    return b;
}

// spec: placement/router - a full RF fence corridor remains a routing cost between same-class nets, so a tiny authored fence cannot collapse a wider keepout halo
test "a tiny fence cannot collapse the RF corridor between same-class nets" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // A DIFFERENT class is ordinary foreign traffic: pushed off the RF net's own
    // layer exactly as the unclassed neighbour above is.
    var apart = classedBoard("clk");
    const held = try router.route(arena, apart.placement(), .{});
    try testing.expectEqual(@as(usize, 2), held.routed);
    try testing.expect(midSpanEdgeGap(held.tracks, other_net, 0) >= halo_mm);

    // The SAME class waives the hard same-layer halo, but not the soft fence
    // corridor. Even though this fixture authors a 1 um fence gap and via, the
    // wider 0.5 mm halo remains the floor and the parallel route detours around
    // that complete protected band.
    var same = classedBoard("rf");
    const admitted = try router.route(arena, same.placement(), .{});
    try testing.expectEqual(@as(usize, 2), admitted.routed);
    try testing.expect(midSpanEdgeGap(admitted.tracks, other_net, 0) >= halo_mm);
    // Their ordinary clearance (the board default, 0.127 mm — neither class
    // overrides it) is what still holds them apart, untouched by the exemption.
    try testing.expect(midSpanEdgeGap(admitted.tracks, other_net, 0) >= 0.127 - 1e-9);
}

// spec: placement/router - a keepout halo carried by retained copper holds off a net routed on its own
test "retained RF copper keeps its halo when a neighbour is routed alone" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const arena = arena_inst.allocator();

    // The RF trace arrives as EXISTING copper and only the neighbour is routed —
    // the scoped-route shape. `emitSeg` haloes nothing here, so this exercises
    // the retained-copper path instead.
    const existing = [_]route_policy.ExistingTrack{
        .{ .x1 = 0, .y1 = rf_y, .x2 = 12, .y2 = rf_y, .layer = 0, .width = 0.127, .net = rf_net },
    };
    const only_other = [_]bool{ false, true };
    const opts = route_policy.Options{ .existing_tracks = &existing, .selected_nets = &only_other };

    var plain = board(0, "SPI_SCK");
    const before = try router.routeWithOptions(arena, plain.placement(), .{}, opts);
    try testing.expect(midSpanEdgeGap(before.tracks, other_net, 0) < halo_mm);

    var fenced = board(halo_mm, "SPI_SCK");
    const after = try router.routeWithOptions(arena, fenced.placement(), .{}, opts);
    try testing.expectEqual(@as(usize, 1), after.routed);
    try testing.expect(midSpanEdgeGap(after.tracks, other_net, 0) >= halo_mm);
}
