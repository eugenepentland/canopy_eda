//! Rastering a world-space DISC onto the routing lattice — the one loop four
//! halo writers were each carrying their own copy of.
//!
//! Every halo the router lays is a disc swept along a centreline: the maze's
//! copper reservation (`router.reserveDisc`), the RF same-layer keepout
//! (`router.keepDisc`), the channel-lane reservation (`lane_reserve.claimDisc`)
//! and the RF cost shadow (`rf_shadow.State.disc`). All four asked the same
//! question — which grid nodes lie within `dist` mm of this point — and all four
//! answered it with the same nested `dy`/`dx` sweep, the same bounds test, the
//! same `hypot` cull and the same flat-index arithmetic, hand-copied. Only what
//! they DID with a covered node differed, and that is the part each keeps.
//!
//! Getting the sweep wrong is quiet: a radius rounded down, a bounds test off by
//! one, a node index computed from the wrong stride, and a halo simply stops a
//! row short. Nothing fails; the router just emits copper the DRC then flags.
//! One implementation, one place to be right.
//!
//! `claim` is a comptime function so the per-node body inlines exactly as the
//! hand-written loops did — this raster runs for millions of nodes per
//! board-wide re-stamp and cannot afford an indirect call.

const std = @import("std");
const route_grid = @import("route_grid.zig");
const numeric = @import("../numeric.zig");

/// The empty-node sentinel, shared with `router.empty_cell` and
/// `rf_shadow.empty`: every lane this module writes encodes "unclaimed" as -1,
/// so one raster serves the occupancy, reservation, keepout and shadow lanes.
const empty: i32 = -1;

/// One grid node a disc covers: its flat index into a per-layer lane, and the
/// world point that node sits at (the halo gates read it, so it is handed over
/// rather than recomputed).
pub const Node = struct {
    at: usize,
    x: f64,
    y: f64,
};

/// Visit every grid node whose world position lies within `dist` mm of
/// `centre`. Nodes off the lattice are skipped, and a non-finite or absurd
/// radius visits nothing rather than looping on a garbage bound.
///
/// A `dist` of zero still reaches the node `centre` snaps ONTO when the snap is
/// exact — every halo writer this replaces behaved that way, and a via stamped
/// with no halo still has to claim its own cell. A negative one reaches nothing.
pub fn forEach(
    grid: route_grid.Grid,
    centre: [2]f64,
    dist: f64,
    ctx: anytype,
    comptime claim: fn (@TypeOf(ctx), Node) void,
) void {
    const radius: i64 = numeric.checkedInt(i64, @ceil(dist / grid.g)) orelse return;
    const middle = grid.nearest(centre[0], centre[1]);
    var dy: i64 = -radius;
    while (dy <= radius) : (dy += 1) {
        var dx: i64 = -radius;
        while (dx <= radius) : (dx += 1) {
            const ix = @as(i64, @intCast(middle[0])) + dx;
            const iy = @as(i64, @intCast(middle[1])) + dy;
            if (ix < 0 or iy < 0 or ix >= grid.nx or iy >= grid.ny) continue;
            const wx = grid.worldX(@intCast(ix));
            const wy = grid.worldY(@intCast(iy));
            if (std.math.hypot(wx - centre[0], wy - centre[1]) > dist) continue;
            claim(ctx, .{ .at = grid.node(@intCast(ix), @intCast(iy)), .x = wx, .y = wy });
        }
    }
}

/// Claim every FREE node of `lane` within `dist` of `centre` for `net`.
///
/// First writer owns the node: where two halos overlap the second reads the
/// cell as foreign, which is the safe direction (it pays the cost or takes the
/// detour), and each net still moves freely through the part it owns.
pub fn claimFree(grid: route_grid.Grid, lane: []i32, centre: [2]f64, dist: f64, net: i32) void {
    const Claim = struct {
        lane: []i32,
        net: i32,

        fn stamp(self: @This(), node: Node) void {
            if (self.lane[node.at] == empty) self.lane[node.at] = self.net;
        }
    };
    forEach(grid, centre, dist, Claim{ .lane = lane, .net = net }, Claim.stamp);
}

/// Sample a segment at half-grid steps — the pitch every halo writer sweeps a
/// centreline at, dense enough that consecutive discs overlap on any lattice.
/// Returns the number of INTERVALS, so a caller walks `0..steps + 1` samples.
pub fn segSteps(grid: route_grid.Grid, a: [2]f64, b: [2]f64) usize {
    const len = std.math.hypot(b[0] - a[0], b[1] - a[1]);
    return @max(1, numeric.toCount(@ceil(len / (grid.g * 0.5))));
}

// ── Tests ────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// A 1 mm-pitch 5x5 lattice with its origin at (0, 0).
const unit_grid = route_grid.Grid{ .ox = 0, .oy = 0, .g = 1, .nx = 5, .ny = 5 };

// spec: placement/router - one shared raster stamps every routing halo disc, covering exactly the lattice nodes within its radius
test "a disc covers the nodes inside its radius and stops at the lattice edge" {
    var lane: [25]i32 = @splat(empty);

    // A unit radius at (0,0) — the lattice CORNER — reaches the origin and its
    // two in-bounds neighbours. The two off-lattice ones are simply skipped,
    // and the diagonal at 1.414 mm is outside the radius.
    claimFree(unit_grid, &lane, .{ 0, 0 }, 1.0, 7);
    try testing.expectEqual(@as(i32, 7), lane[0]); // (0,0)
    try testing.expectEqual(@as(i32, 7), lane[1]); // (1,0)
    try testing.expectEqual(@as(i32, 7), lane[5]); // (0,1)
    try testing.expectEqual(empty, lane[6]); // (1,1) is 1.414 mm away

    // First writer owns the node: a second net's overlapping disc takes only
    // what is still free.
    claimFree(unit_grid, &lane, .{ 1, 0 }, 1.0, 9);
    try testing.expectEqual(@as(i32, 7), lane[1]); // still the first claimant
    try testing.expectEqual(@as(i32, 9), lane[2]); // (2,0), newly claimed

    // A zero radius still claims the node the centre lands on — a halo-less
    // stamp owns its own cell — and nothing else.
    claimFree(unit_grid, &lane, .{ 3, 3 }, 0, 4);
    try testing.expectEqual(@as(i32, 4), lane[18]); // (3,3)
    try testing.expectEqual(empty, lane[17]); // (2,3)

    // A NaN radius reaches nothing: the conversion refuses it rather than
    // looping on a garbage bound.
    const before = lane;
    claimFree(unit_grid, &lane, .{ 1, 3 }, std.math.nan(f64), 4);
    try testing.expectEqualSlices(i32, &before, &lane);
}

// spec: placement/router - a halo swept along a segment samples it at half-grid steps, so consecutive discs always overlap
test "segment sweep steps are at most half a grid pitch apart" {
    // 2 mm on a 1 mm lattice is four half-steps.
    try testing.expectEqual(@as(usize, 4), segSteps(unit_grid, .{ 0, 0 }, .{ 2, 0 }));
    // A degenerate segment still samples its single point once.
    try testing.expectEqual(@as(usize, 1), segSteps(unit_grid, .{ 1, 1 }, .{ 1, 1 }));
    // And a sub-step segment is never split into zero intervals.
    try testing.expectEqual(@as(usize, 1), segSteps(unit_grid, .{ 0, 0 }, .{ 0.1, 0 }));
}
