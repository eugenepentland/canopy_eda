//! Where a multi-pad net's own copper MEETS itself — pad-terminated joins.
//!
//! A net with three or more pads is routed as a small tree: each edge joins two
//! pads, and a pad that takes two edges becomes the tree's branch point. What a
//! hand router draws there is a CHAIN — the copper runs from one pad to the
//! next and the branch point IS a pad, because a pad is solid metal and joining
//! on it costs nothing. What this router drew instead was a TRUNK: both edges
//! left the shared pad through its outward escape point (`octilinear.padPair`
//! exits BOTH terminals along their component-outward axis before joining), so
//! the branch point landed a hair OUTSIDE the land — one trace half-width off
//! the pad edge — and the run to the next pad went with it, straight down the
//! escape lane in front of the pad faces, tapping each land sideways with a
//! stub. Measured on board-d-synth-lmx2595 (2026-08-11): `LMX_RFOUTAM`'s two
//! edges both left R6 pad 2 westward at x = 3.8565 (its escape point, 0.063 mm
//! off the land) and ran the full height of R6's and R7's west faces.
//!
//! The outward escape is right for a pad reaching open board — it is what keeps
//! copper out of a neighbour's escape lane, and it is why `padPair` is written
//! that way. It is wrong for the one case this module names: two pads whose
//! LANDS face each other across open board, where the straight run between them
//! is shorter than any escape route, needs no bend at all, and terminates on
//! solid copper at both ends.
//!
//! `landRun` builds exactly that run and nothing else:
//!
//!   * it travels on the axis the two pad centres are farther apart on, so it
//!     is the connection, not a jog;
//!   * it sits on a line BOTH lands contain, inset by a trace half-width, so
//!     the copper it ends with is inside each land rather than tangent to it —
//!     which is what the connectivity oracle, KiCad and a photoplotter all read
//!     as "this track is on that pad";
//!   * it prefers a pad's own centre line when the other land admits it, so the
//!     common case (two pads sharing a centre line — a stacked pair, a passive
//!     under an IC pin) is ONE straight segment with no jog anywhere;
//!   * it is refused unless the two lands are clear of each other along the run
//!     axis (overlapping lands are not "a run apart"), and unless every leg
//!     CLEARS — the same DRC-grade probe the escape join uses, so a run through
//!     a foreign pad, a foreign trace or a keepout is never drawn, it just falls
//!     back to the escape.
//!
//! Out of scope by construction: escape-ruled (`(max-freq …)`) nets and coupled
//! diff-pair legs never set `Options.land_join`, so their copper is byte for
//! byte what it was — an RF pad's straight reserve is measured from its outward
//! axis, and leaving through a side face would spend it.

const std = @import("std");
const octilinear = @import("octilinear.zig");
const pad_exit = @import("pad_exit.zig");

const testing = std.testing;

/// The geometry the escape join already takes, plus whether this leg may take
/// a land-to-land run at all. `land_join` is off by default so every caller
/// that has not thought about it keeps the outward-axis escape.
pub const Options = struct {
    pad: octilinear.PadOptions,
    land_join: bool = false,
};

/// Longest land-to-land run this takes (mm), measured between the two pad
/// centres along the run axis.
///
/// The trade: a land run leaves its pad through whichever face points at the
/// target, not through the component-outward face the escape rule reserves. Over
/// a short hop between neighbouring parts that is exactly what a hand router
/// draws and there is nothing else in the gap to disturb. Over a long one the
/// polite outward escape is the better default — a run that far is crossing
/// somebody's board, and the clearance probe alone (which only refuses copper it
/// would actually violate) is a weaker argument than "leave your own pad the way
/// the rest of the board expects". 3 mm is a judgement, not an optimum: it is
/// comfortably past the pitch of two neighbouring 0402s (1.0–1.3 mm here) and
/// well inside `direct_span_mm`, the 6 mm span past which the whole direct path
/// is skipped for a plain net anyway.
pub const land_run_max_mm: f64 = 3.0;

/// Float slack for the geometry tests. Well below fab resolution, so it only
/// absorbs coordinates that have been through a world→grid→world round trip.
const eps: f64 = 1e-9;

/// The two axes of a run: `along` is the one it travels, `perp` the one it sits
/// on. 0 = x, 1 = y.
const Axis = struct { along: usize, perp: usize };

fn boxLo(box: octilinear.PadBox, axis: usize) f64 {
    return if (axis == 0) box.x0 else box.y0;
}

fn boxHi(box: octilinear.PadBox, axis: usize) f64 {
    return if (axis == 0) box.x1 else box.y1;
}

/// A point from its two axis coordinates, given which axis `perp` names.
fn point(perp: usize, perp_at: f64, along_at: f64) [2]f64 {
    return if (perp == 0) .{ perp_at, along_at } else .{ along_at, perp_at };
}

/// Which axis the run travels: the one the two centres are farther apart on.
/// Null for coincident terminals, which are no run at all.
fn runAxis(a: octilinear.PadTerm, b: octilinear.PadTerm) ?Axis {
    const dx = @abs(b.at[0] - a.at[0]);
    const dy = @abs(b.at[1] - a.at[1]);
    if (@max(dx, dy) < eps) return null;
    return if (dx >= dy) .{ .along = 0, .perp = 1 } else .{ .along = 1, .perp = 0 };
}

/// The band on the perpendicular axis a run may sit on: the overlap of the two
/// lands, inset by a trace half-width at each edge so the copper lies INSIDE
/// both. Null when the lands share less than a trace width there.
fn band(a: octilinear.PadTerm, b: octilinear.PadTerm, perp: usize, half_width: f64) ?[2]f64 {
    const lo = @max(boxLo(a.box, perp), boxLo(b.box, perp)) + half_width;
    const hi = @min(boxHi(a.box, perp), boxHi(b.box, perp)) - half_width;
    return if (hi < lo - eps) null else .{ lo, hi };
}

/// Where the run sits on the perpendicular axis. A pad's OWN centre line wins
/// when the other land admits it — that end then needs no jog, and two pads
/// sharing a centre line come out as one straight segment. Otherwise the two
/// centre lines' midpoint, pulled into the band.
fn runCoord(a: octilinear.PadTerm, b: octilinear.PadTerm, perp: usize, in: [2]f64) f64 {
    const ac = a.at[perp];
    const bc = b.at[perp];
    if (ac >= in[0] - eps and ac <= in[1] + eps) return ac;
    if (bc >= in[0] - eps and bc <= in[1] + eps) return bc;
    return std.math.clamp((ac + bc) / 2, in[0], in[1]);
}

/// Are the two lands clear of each other along the run axis? Lands that overlap
/// there are not a run apart: the "run" would be a stub inside the overlap, and
/// the pads' own escape rule describes such a pair better.
fn separated(a: octilinear.PadTerm, b: octilinear.PadTerm, along: usize) bool {
    return boxHi(a.box, along) < boxLo(b.box, along) - eps or
        boxHi(b.box, along) < boxLo(a.box, along) - eps;
}

/// A leg is clear when it is degenerate (nothing to draw) or the caller's probe
/// says so.
fn legClear(
    comptime Context: type,
    context: Context,
    comptime clear: fn (Context, [2]f64, [2]f64) bool,
    from: [2]f64,
    to: [2]f64,
) bool {
    if (std.math.hypot(to[0] - from[0], to[1] - from[1]) < eps) return true;
    return clear(context, from, to);
}

/// The straight run joining two pads' LANDS, as the bend list `emitDogleg`
/// draws between the two pad centres, or null when this pair cannot take one.
pub fn landRun(
    comptime Context: type,
    a: octilinear.PadTerm,
    b: octilinear.PadTerm,
    opt: Options,
    context: Context,
    comptime clear: fn (Context, [2]f64, [2]f64) bool,
) ?octilinear.PadPath {
    if (!opt.land_join) return null;
    const axis = runAxis(a, b) orelse return null;
    if (!separated(a, b, axis.along)) return null;
    if (@abs(b.at[axis.along] - a.at[axis.along]) > land_run_max_mm) return null;
    const in = band(a, b, axis.perp, opt.pad.half_width) orelse return null;
    const at = runCoord(a, b, axis.perp, in);
    const head = point(axis.perp, at, a.at[axis.along]);
    const tail = point(axis.perp, at, b.at[axis.along]);
    if (!legClear(Context, context, clear, a.at, head)) return null;
    if (!legClear(Context, context, clear, head, tail)) return null;
    if (!legClear(Context, context, clear, tail, b.at)) return null;
    return .{ .count = 2, .bends = .{ head, tail, .{ 0, 0 } } };
}

/// Order a net's terminals for connection: the two CLOSEST terminals first,
/// then repeatedly whichever unplaced terminal is nearest anything already in
/// the tree. That is a nearest-neighbour (Prim) walk over the pads, so the
/// route grows as a chain of neighbourly hops instead of fanning out from an
/// arbitrary first pad — which is what makes each leg's natural terminus the
/// pad next door. Two or fewer terminals have only one order; the slice is
/// then returned as it came.
pub fn connectOrder(
    arena: std.mem.Allocator,
    pts: []const pad_exit.NetPt,
) std.mem.Allocator.Error![]const pad_exit.NetPt {
    if (pts.len <= 2) return pts;
    const out = try arena.alloc(pad_exit.NetPt, pts.len);
    const used = try arena.alloc(bool, pts.len);
    @memset(used, false);
    var first: usize = 0;
    var second: usize = 1;
    var best = std.math.inf(f64);
    for (pts, 0..) |a, ai| for (pts[ai + 1 ..], ai + 1..) |b, bi| {
        const distance = std.math.hypot(b.x - a.x, b.y - a.y);
        if (distance >= best) continue;
        first = ai;
        second = bi;
        best = distance;
    };
    out[0] = pts[first];
    out[1] = pts[second];
    used[first] = true;
    used[second] = true;
    for (2..pts.len) |next_out| {
        var next: usize = 0;
        best = std.math.inf(f64);
        for (pts, 0..) |candidate, candidate_i| {
            if (used[candidate_i]) continue;
            for (pts, used) |tree_point, in_tree| {
                if (!in_tree) continue;
                const distance = std.math.hypot(candidate.x - tree_point.x, candidate.y - tree_point.y);
                if (distance >= best) continue;
                next = candidate_i;
                best = distance;
            }
        }
        out[next_out] = pts[next];
        used[next] = true;
    }
    return out;
}

/// One of the routing net's own pad lands, as a maze leg reads it when pricing
/// the copper it is allowed to join: the land's world box.
pub const Land = struct { x0: f64, y0: f64, x1: f64, y1: f64 };

/// Path length (mm) a maze leg must SAVE to join its net mid-span on a trace
/// instead of on one of the net's own pads.
///
/// A maze leg seeds from every node its net's copper already owns and stops at
/// the first one it reaches, so a leg that passes a trace on its way to a pad
/// stops at the trace — the join lands wherever the earlier leg happened to
/// run, which near a pad means a fraction of a millimetre in FRONT of the land
/// it is serving. Pad-terminated is the better default (it is what a hand
/// router draws, and a pad is solid metal, so joining there costs no copper at
/// all), but it must not be absolute: a free-space junction where two legs
/// genuinely meet mid-air because that is the shorter tree is correct copper,
/// and hand routes here carry them. So this is a MARGIN, not a ban — a mid-span
/// join is still taken, it just has to be at least this much shorter.
///
/// 0.5 mm is the distance from a typical land's centre to the escape point just
/// outside it (an 0402 pad here: 0.27 + half a trace = 0.33 mm; a 0.5 mm-pitch
/// QFN land: 0.45 + 0.06 = 0.51 mm), which is exactly the offset that produced
/// the trunk-in-front-of-the-pad picture. It also BOUNDS the change: the
/// penalty is the most any leg's path can lengthen because of this preference,
/// about two route-grid pitches. With no pad among a net's sources every source
/// pays it equally — a constant shift, which changes nothing.
pub const midspan_join_penalty_mm: f64 = 0.5;

/// What a maze leg pays to START at one of its net's already-owned nodes:
/// nothing on the net's own pad copper, `midspan_join_penalty_mm` anywhere
/// else. With no lands supplied every source is free, exactly as before.
pub fn sourceCost(lands: []const Land, x: f64, y: f64) f64 {
    if (lands.len == 0) return 0;
    for (lands) |land| {
        if (x >= land.x0 - eps and x <= land.x1 + eps and
            y >= land.y0 - eps and y <= land.y1 + eps) return 0;
    }
    return midspan_join_penalty_mm;
}

/// Join two of one net's pads: the land-to-land run when this pair can take
/// one, else the outward-axis escape join (`octilinear.padPair`) unchanged.
pub fn padJoin(
    comptime Context: type,
    a: octilinear.PadTerm,
    b: octilinear.PadTerm,
    opt: Options,
    context: Context,
    comptime clear: fn (Context, [2]f64, [2]f64) bool,
) ?octilinear.PadPath {
    if (landRun(Context, a, b, opt, context, clear)) |run| return run;
    return octilinear.padPair(Context, a, b, opt.pad, context, clear);
}

// ── Tests ───────────────────────────────────────────────────────────────────

/// A test board: axis-aligned boxes a segment may not touch.
const Board = struct {
    walls: []const octilinear.PadBox = &.{},
};

fn hits(wall: octilinear.PadBox, from: [2]f64, to: [2]f64) bool {
    const steps: usize = 200;
    var i: usize = 0;
    while (i <= steps) : (i += 1) {
        const t = @as(f64, @floatFromInt(i)) / @as(f64, @floatFromInt(steps));
        const x = from[0] + t * (to[0] - from[0]);
        const y = from[1] + t * (to[1] - from[1]);
        if (x >= wall.x0 and x <= wall.x1 and y >= wall.y0 and y <= wall.y1) return true;
    }
    return false;
}

fn boardClear(board: Board, from: [2]f64, to: [2]f64) bool {
    for (board.walls) |wall| if (hits(wall, from, to)) return false;
    return true;
}

fn term(cx: f64, cy: f64, hw: f64, hh: f64, out: [2]f64) octilinear.PadTerm {
    return .{
        .at = .{ cx, cy },
        .out = out,
        .box = .{ .x0 = cx - hw, .y0 = cy - hh, .x1 = cx + hw, .y1 = cy + hh },
    };
}

const chain_opt = Options{
    .pad = .{ .step = 0.254, .half_width = 0.0635, .rings = 6 },
    .land_join = true,
};
const escape_opt = Options{ .pad = chain_opt.pad, .land_join = false };

// spec: placement/net-topology - two same-net pads whose lands face each other across open board join with one straight run terminating inside both, not through their outward escape points
test "stacked pads sharing a centre line join pad to pad" {
    // board-d-synth-lmx2595's R6 pad 2 and R7 pad 1: same centre x, both facing
    // west, 1.1 mm apart. The escape join ran west out of both and up the lane
    // in front of their faces; the land run is the vertical between them.
    const a = term(4.190, 2.400, 0.270, 0.320, .{ -1, 0 });
    const b = term(4.190, 3.500, 0.270, 0.320, .{ -1, 0 });
    const path = padJoin(Board, a, b, chain_opt, .{}, boardClear) orelse return error.NoPath;
    try testing.expectEqual(@as(u2, 2), path.count);
    try testing.expectApproxEqAbs(@as(f64, 4.190), path.bends[0][0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 2.400), path.bends[0][1], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 4.190), path.bends[1][0], 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 3.500), path.bends[1][1], 1e-9);
}

// spec: placement/net-topology - a land run offset from both centres sits on a line inside both lands, so each end still terminates on solid pad copper
test "offset lands run on a line both of them contain" {
    // C20 pad 2 and R5 pad 1: centres 0.03 mm apart in x, lands overlapping.
    const a = term(4.220, 1.300, 0.280, 0.310, .{ -1, 0 });
    const b = term(4.190, 0.200, 0.270, 0.320, .{ -1, 0 });
    const path = padJoin(Board, a, b, chain_opt, .{}, boardClear) orelse return error.NoPath;
    try testing.expectEqual(@as(u2, 2), path.count);
    const at = path.bends[0][0];
    try testing.expectApproxEqAbs(at, path.bends[1][0], 1e-9);
    // inside BOTH lands by at least a trace half-width
    try testing.expect(at >= a.box.x0 + chain_opt.pad.half_width - 1e-9);
    try testing.expect(at <= a.box.x1 - chain_opt.pad.half_width + 1e-9);
    try testing.expect(at >= b.box.x0 + chain_opt.pad.half_width - 1e-9);
    try testing.expect(at <= b.box.x1 - chain_opt.pad.half_width + 1e-9);
}

// spec: placement/net-topology - a land run blocked by foreign copper falls back to the outward-axis escape join rather than being drawn through it
test "a blocked land run falls back to the escape join" {
    const a = term(4.190, 2.400, 0.270, 0.320, .{ -1, 0 });
    const b = term(4.190, 3.500, 0.270, 0.320, .{ -1, 0 });
    const walls = [_]octilinear.PadBox{.{ .x0 = 4.10, .y0 = 2.90, .x1 = 4.30, .y1 = 3.00 }};
    const path = padJoin(Board, a, b, chain_opt, .{ .walls = &walls }, boardClear) orelse
        return error.NoPath;
    // The escape join leaves both pads westward, so its first bend is off the land.
    try testing.expect(path.bends[0][0] < a.box.x0);
}

// spec: placement/net-topology - an escape-ruled or coupled leg never takes a land run, so RF and diff-pair copper is unchanged
test "land_join off keeps the escape join" {
    const a = term(4.190, 2.400, 0.270, 0.320, .{ -1, 0 });
    const b = term(4.190, 3.500, 0.270, 0.320, .{ -1, 0 });
    try testing.expect(landRun(Board, a, b, escape_opt, .{}, boardClear) == null);
    const path = padJoin(Board, a, b, escape_opt, .{}, boardClear) orelse return error.NoPath;
    try testing.expect(path.bends[0][0] < a.box.x0);
}

// spec: placement/net-topology - two lands sharing less than a trace width across the run keep the escape join, so a run is never drawn tangent to the copper it ends on
test "lands that barely overlap take the escape join" {
    const a = term(4.190, 2.400, 0.270, 0.320, .{ -1, 0 });
    // shifted east so only 0.03 mm of x is shared — under one trace width
    const b = term(4.190 + 0.510, 3.500, 0.270, 0.320, .{ 1, 0 });
    try testing.expect(landRun(Board, a, b, chain_opt, .{}, boardClear) == null);
}

// spec: placement/net-topology - a land run longer than land_run_max_mm keeps the outward-axis escape, so only a neighbourly hop leaves a pad through a side face
test "a run past the length cap keeps the escape join" {
    const a = term(4.190, 2.400, 0.270, 0.320, .{ -1, 0 });
    const b = term(4.190, 2.400 + land_run_max_mm + 0.5, 0.270, 0.320, .{ -1, 0 });
    try testing.expect(landRun(Board, a, b, chain_opt, .{}, boardClear) == null);
}

// spec: placement/net-topology - overlapping lands are not a run apart and keep the escape join
test "lands overlapping along the run axis take the escape join" {
    const a = term(4.190, 2.400, 0.270, 0.320, .{ -1, 0 });
    const b = term(4.190, 2.700, 0.270, 0.320, .{ -1, 0 });
    try testing.expect(landRun(Board, a, b, chain_opt, .{}, boardClear) == null);
}

// spec: placement/net-topology - a maze leg starts free on its net's own pad copper and pays the mid-span margin to start anywhere else, so a join standing in front of a pad lands on it instead
test "a source on the net's own land is free and copper elsewhere pays the margin" {
    const lands = [_]Land{.{ .x0 = 3.920, .y0 = 2.080, .x1 = 4.460, .y1 = 2.720 }};
    try testing.expectEqual(@as(f64, 0), sourceCost(&lands, 4.190, 2.400));
    try testing.expectEqual(@as(f64, 0), sourceCost(&lands, 3.920, 2.080)); // land edge
    // the escape point 0.063 mm in front of the west face — the trunk join
    try testing.expectEqual(midspan_join_penalty_mm, sourceCost(&lands, 3.857, 2.400));
}

// spec: placement/net-topology - a leg whose net offers no pad land prices every source at zero, leaving that search byte-identical
test "no lands prices every source at zero" {
    try testing.expectEqual(@as(f64, 0), sourceCost(&.{}, 3.857, 2.400));
    try testing.expectEqual(@as(f64, 0), sourceCost(&.{}, 0, 0));
}

// spec: placement/net-topology - a net's terminals are connected closest pair first and then nearest to the tree, so the route grows as a chain of neighbourly hops
test "connect order starts at the closest pair and grows to the nearest terminal" {
    var arena_inst = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_inst.deinit();
    const pts = [_]pad_exit.NetPt{
        .{ .x = 0, .y = 0, .layer = 0, .ref_des = "U1" },
        .{ .x = 9, .y = 0, .layer = 0, .ref_des = "R2" },
        .{ .x = 10, .y = 0, .layer = 0, .ref_des = "R3" },
        .{ .x = 4, .y = 0, .layer = 0, .ref_des = "R1" },
    };
    const order = try connectOrder(arena_inst.allocator(), &pts);
    try testing.expectEqual(@as(usize, 4), order.len);
    try testing.expectEqualStrings("R2", order[0].ref_des);
    try testing.expectEqualStrings("R3", order[1].ref_des);
    try testing.expectEqualStrings("R1", order[2].ref_des);
    try testing.expectEqualStrings("U1", order[3].ref_des);
    // two terminals have only one order, and the slice comes back as it came
    const pair = try connectOrder(arena_inst.allocator(), pts[0..2]);
    try testing.expectEqualStrings("U1", pair[0].ref_des);
}
