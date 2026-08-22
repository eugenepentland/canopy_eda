//! Pure route-shape metrics for choosing an initial placement of critical nets.
//!
//! The general placement objective is intentionally broad: it balances every
//! net on a board.  RF launch chains need a narrower ordering.  A candidate
//! with one extra corner must not win merely because it saves a little copper
//! elsewhere, and a wrongly-facing series part must not look good because its
//! component centres are close.  This module supplies that narrower view while
//! staying independent of the optimizer and router:
//!
//!   * `Endpoint` describes an exact world-space pad point and the direction
//!     copper should leave the component through that pad.
//!   * `estimate` gives the obstacle-free octilinear length, a conservative
//!     bend estimate, and continuous facing/axis penalties for an unrouted hop.
//!   * `measurePolyline` measures the same quantities on routed copper.
//!   * `Rank` compares whole candidates lexicographically, with hard failures,
//!     connectivity, vias, and bends ahead of length and generic placement
//!     cost.
//!
//! Every function is deterministic and allocation-free.  Callers resolve pads
//! to world coordinates before entering this module, which avoids an import
//! cycle with `optimizer.zig` and makes the primitives useful to design-level
//! roughing, route experiments, and tests alike.

const std = @import("std");
const octilinear = @import("octilinear.zig");

const Point = [2]f64;
const Vector = [2]f64;

/// An exact pad point and the component-outward axis at that pad.
///
/// `out` need not be normalized.  `{ 0, 0 }` means the caller has no reliable
/// facing information, in which case the endpoint contributes no facing or
/// axis penalty.
pub const Endpoint = struct {
    at: Point,
    out: Vector = .{ 0, 0 },
};

/// Route-shape measurements for one ordered critical hop or path.
///
/// `length_mm` is an obstacle-free estimate for `estimate`, and exact polyline
/// length for `measurePolyline`.  The two penalty fields are dimensionless:
/// zero is ideal, and larger values are worse.
pub const Metrics = struct {
    bends: usize = 0,
    length_mm: f64 = 0,
    facing_penalty: f64 = 0,
    axis_penalty: f64 = 0,
};

const direction_epsilon_mm: f64 = 1e-9;
const collinear_tolerance: f64 = 1e-6;

/// Straight-line lower bound between two world-space points, in millimetres.
fn directLength(a: Point, b: Point) f64 {
    return std.math.hypot(b[0] - a[0], b[1] - a[1]);
}

/// Length of either shortest obstacle-free H/V/45 path between two points.
///
/// A non-octilinear pair is joined by one of `octilinear.elbows`; both elbow
/// choices have this same length.  An already-octilinear pair reduces to its
/// direct Euclidean length.
fn octilinearLength(a: Point, b: Point) f64 {
    const adx = @abs(b[0] - a[0]);
    const ady = @abs(b[1] - a[1]);
    const lo = @min(adx, ady);
    const hi = @max(adx, ady);
    return hi + (std.math.sqrt2 - 1.0) * lo;
}

/// Minimum number of corners in an obstacle-free octilinear point-to-point
/// connection, before pad-facing constraints are considered.
fn pointBendEstimate(a: Point, b: Point) usize {
    if (directLength(a, b) < direction_epsilon_mm) return 0;
    return @intFromBool(!octilinear.isOctilinear(a, b));
}

fn unit(v: Vector) ?Vector {
    const len = std.math.hypot(v[0], v[1]);
    if (len < direction_epsilon_mm) return null;
    return .{ v[0] / len, v[1] / len };
}

fn clampedDot(a: Vector, b: Vector) f64 {
    return std.math.clamp(a[0] * b[0] + a[1] * b[1], -1.0, 1.0);
}

fn endpointFacing(out: Vector, toward: Vector) f64 {
    const axis = unit(out) orelse return 0;
    const travel = unit(toward) orelse return 0;
    // 0 aligned, 1 perpendicular, 2 exactly backwards.
    return 1.0 - clampedDot(axis, travel);
}

fn endpointAxis(out: Vector, toward: Vector) f64 {
    const axis = unit(out) orelse return 0;
    const travel = unit(toward) orelse return 0;
    // Polarity is deliberately ignored here: facing owns that distinction.
    // 0 collinear, 1 perpendicular.
    return 1.0 - @abs(clampedDot(axis, travel));
}

/// Directional penalty for a pair of pads.  Zero means both pad-outward axes
/// point toward the other pad; a pair whose two pads point exactly away from
/// one another scores four.
fn facingPenalty(a: Endpoint, b: Endpoint) f64 {
    const ab = Vector{ b.at[0] - a.at[0], b.at[1] - a.at[1] };
    return endpointFacing(a.out, ab) + endpointFacing(b.out, .{ -ab[0], -ab[1] });
}

/// Collinearity penalty for a pair of pad axes.  This catches a capacitor
/// rotated across its U-to-launch path independently of which capacitor pad is
/// on the U side; `facingPenalty` supplies that polarity distinction.
fn axisPenalty(a: Endpoint, b: Endpoint) f64 {
    const ab = Vector{ b.at[0] - a.at[0], b.at[1] - a.at[1] };
    return endpointAxis(a.out, ab) + endpointAxis(b.out, .{ -ab[0], -ab[1] });
}

/// Extra corners suggested by a pad's declared exit direction.
///
/// A collinear forward exit needs no corner, a non-collinear exit needs one,
/// and a collinear but backwards exit needs two to leave the pad outward and
/// return toward its partner.  It is a placement heuristic, not an obstacle
/// solver; final candidates can replace it with `measurePolyline`.
fn exitBends(out: Vector, toward: Vector) usize {
    const axis = unit(out) orelse return 0;
    const travel = unit(toward) orelse return 0;
    const cross = @abs(axis[0] * travel[1] - axis[1] * travel[0]);
    const dot = clampedDot(axis, travel);
    if (cross <= collinear_tolerance) return if (dot >= 0) 0 else 2;
    return 1;
}

/// Conservative bend estimate for an unrouted hop, including the corners
/// implied by pad exit directions.
fn bendEstimate(a: Endpoint, b: Endpoint) usize {
    const ab = Vector{ b.at[0] - a.at[0], b.at[1] - a.at[1] };
    return pointBendEstimate(a.at, b.at) +
        exitBends(a.out, ab) +
        exitBends(b.out, .{ -ab[0], -ab[1] });
}

/// Obstacle-free RF shape estimate for one pad-to-pad hop.
pub fn estimate(a: Endpoint, b: Endpoint) Metrics {
    return .{
        .bends = bendEstimate(a, b),
        .length_mm = octilinearLength(a.at, b.at),
        .facing_penalty = facingPenalty(a, b),
        .axis_penalty = axisPenalty(a, b),
    };
}

/// Exact length of a polyline.  Consecutive duplicate points contribute zero.
fn polylineLength(points: []const Point) f64 {
    var length: f64 = 0;
    for (1..points.len) |i| length += directLength(points[i - 1], points[i]);
    return length;
}

/// Number of real heading changes in a polyline.
///
/// Duplicate points and collinear subdivisions do not count.  A reversal does
/// count even though its cross product is zero.
fn polylineBends(points: []const Point) usize {
    var bends: usize = 0;
    var previous: ?Vector = null;
    for (1..points.len) |i| {
        const delta = Vector{
            points[i][0] - points[i - 1][0],
            points[i][1] - points[i - 1][1],
        };
        const heading = unit(delta) orelse continue;
        if (previous) |before| {
            const cross = @abs(before[0] * heading[1] - before[1] * heading[0]);
            const dot = clampedDot(before, heading);
            if (cross > collinear_tolerance or dot <= 0) bends += 1;
        }
        previous = heading;
    }
    return bends;
}

fn firstHeading(points: []const Point) ?Vector {
    for (1..points.len) |i| {
        const heading = unit(.{
            points[i][0] - points[i - 1][0],
            points[i][1] - points[i - 1][1],
        });
        if (heading != null) return heading;
    }
    return null;
}

fn lastHeadingTowardPath(points: []const Point) ?Vector {
    if (points.len < 2) return null;
    var i = points.len - 1;
    while (i > 0) : (i -= 1) {
        const heading = unit(.{
            points[i - 1][0] - points[i][0],
            points[i - 1][1] - points[i][1],
        });
        if (heading != null) return heading;
    }
    return null;
}

/// Measure routed copper and its terminal-pad alignment.
///
/// `start_out` and `end_out` are the component-outward axes at the first and
/// last points.  Pass `{0,0}` for either unknown axis.  The path's own first
/// and last non-degenerate segments are used, so a good straight pad escape is
/// credited even when the middle of the route later bends.
fn measurePolyline(points: []const Point, start_out: Vector, end_out: Vector) Metrics {
    const first = firstHeading(points);
    const last = lastHeadingTowardPath(points);
    return .{
        .bends = polylineBends(points),
        .length_mm = polylineLength(points),
        .facing_penalty = (if (first) |h| endpointFacing(start_out, h) else 0) +
            (if (last) |h| endpointFacing(end_out, h) else 0),
        .axis_penalty = (if (first) |h| endpointAxis(start_out, h) else 0) +
            (if (last) |h| endpointAxis(end_out, h) else 0),
    };
}

/// Lexicographic quality vector for a whole placement or routed candidate.
/// Smaller is better in every field.
///
/// The ordering is deliberately not a weighted sum: no finite length saving
/// can purchase an extra RF bend, via, open path, or hard violation.  The
/// caller may use `fallback_cost` for its existing general placement objective
/// after every RF-specific key ties.
const ShapeSummary = struct {
    max_bends: usize = 0,
    total_bends: usize = 0,
    max_length_mm: f64 = 0,
    total_length_mm: f64 = 0,
};

const PenaltySummary = struct {
    facing: f64 = 0,
    axis: f64 = 0,
    crossings: usize = 0,
};

/// Lexicographic whole-candidate quality vector; every field is minimized.
pub const Rank = struct {
    hard_violations: usize = 0,
    unrouted_paths: usize = 0,
    vias: usize = 0,
    shape: ShapeSummary = .{},
    penalty: PenaltySummary = .{},
    fallback_cost: f64 = 0,

    /// Fold one ordered RF path into this whole-candidate rank.
    pub fn addPath(self: *Rank, path: Metrics) void {
        self.shape.max_bends = @max(self.shape.max_bends, path.bends);
        self.shape.total_bends += path.bends;
        self.shape.max_length_mm = @max(self.shape.max_length_mm, path.length_mm);
        self.shape.total_length_mm += path.length_mm;
        self.penalty.facing += path.facing_penalty;
        self.penalty.axis += path.axis_penalty;
    }
};

/// Aggregate a slice of critical-path measurements into a rank whose gate and
/// routing fields retain their zero defaults for the caller to fill.
fn rankPaths(paths: []const Metrics) Rank {
    var rank: Rank = .{};
    for (paths) |path| rank.addPath(path);
    return rank;
}

fn floatOrder(a: f64, b: f64) std.math.Order {
    // Invalid geometry must never accidentally outrank a finite candidate.
    const a_nan = std.math.isNan(a);
    const b_nan = std.math.isNan(b);
    if (a_nan or b_nan) {
        if (a_nan and b_nan) return .eq;
        return if (a_nan) .gt else .lt;
    }
    return std.math.order(a, b);
}

/// Compare two candidate ranks.  `.lt` means `a` is better than `b`.
pub fn compare(a: Rank, b: Rank) std.math.Order {
    var by = std.math.order(a.hard_violations, b.hard_violations);
    if (by != .eq) return by;
    by = std.math.order(a.unrouted_paths, b.unrouted_paths);
    if (by != .eq) return by;
    by = std.math.order(a.vias, b.vias);
    if (by != .eq) return by;
    by = std.math.order(a.shape.max_bends, b.shape.max_bends);
    if (by != .eq) return by;
    by = std.math.order(a.shape.total_bends, b.shape.total_bends);
    if (by != .eq) return by;
    // The orientation of an RF launch is physical correctness, not a cosmetic
    // tie-break. A shorter candidate must never buy a pad that faces away from
    // its partner or a series body whose axis crosses the route. Length only
    // distinguishes candidates after both directional penalties tie.
    by = floatOrder(a.penalty.facing, b.penalty.facing);
    if (by != .eq) return by;
    by = floatOrder(a.penalty.axis, b.penalty.axis);
    if (by != .eq) return by;
    by = floatOrder(a.shape.max_length_mm, b.shape.max_length_mm);
    if (by != .eq) return by;
    by = floatOrder(a.shape.total_length_mm, b.shape.total_length_mm);
    if (by != .eq) return by;
    by = std.math.order(a.penalty.crossings, b.penalty.crossings);
    if (by != .eq) return by;
    return floatOrder(a.fallback_cost, b.fallback_cost);
}

/// Is `candidate` strictly better than `incumbent` under the RF ordering?
pub fn better(candidate: Rank, incumbent: Rank) bool {
    return compare(candidate, incumbent) == .lt;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

test {
    testing.refAllDecls(@This());
}

test "point length and bend estimates follow octilinear geometry" {
    try testing.expectApproxEqAbs(@as(f64, 5), directLength(.{ 0, 0 }, .{ 3, 4 }), 1e-12);
    try testing.expectApproxEqAbs(
        @as(f64, 4) + (std.math.sqrt2 - 1.0) * 3.0,
        octilinearLength(.{ 0, 0 }, .{ 3, 4 }),
        1e-12,
    );
    try testing.expectEqual(@as(usize, 1), pointBendEstimate(.{ 0, 0 }, .{ 3, 4 }));
    try testing.expectEqual(@as(usize, 0), pointBendEstimate(.{ 0, 0 }, .{ 4, 0 }));
    try testing.expectEqual(@as(usize, 0), pointBendEstimate(.{ 0, 0 }, .{ 3, 3 }));
}

test "facing and axis penalties expose series-part orientation" {
    const left = Endpoint{ .at = .{ 0, 0 }, .out = .{ 2, 0 } };
    const right = Endpoint{ .at = .{ 4, 0 }, .out = .{ -3, 0 } };
    try testing.expectApproxEqAbs(@as(f64, 0), facingPenalty(left, right), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), axisPenalty(left, right), 1e-12);
    try testing.expectEqual(@as(usize, 0), bendEstimate(left, right));

    const reversed_left = Endpoint{ .at = left.at, .out = .{ -1, 0 } };
    const reversed_right = Endpoint{ .at = right.at, .out = .{ 1, 0 } };
    try testing.expectApproxEqAbs(
        @as(f64, 4),
        facingPenalty(reversed_left, reversed_right),
        1e-12,
    );
    // Reversal changes polarity, not the physical axis.
    try testing.expectApproxEqAbs(
        @as(f64, 0),
        axisPenalty(reversed_left, reversed_right),
        1e-12,
    );
    try testing.expectEqual(@as(usize, 4), bendEstimate(reversed_left, reversed_right));

    const cross_left = Endpoint{ .at = left.at, .out = .{ 0, 1 } };
    const cross_right = Endpoint{ .at = right.at, .out = .{ 0, -1 } };
    try testing.expectApproxEqAbs(@as(f64, 2), axisPenalty(cross_left, cross_right), 1e-12);
    try testing.expectEqual(@as(usize, 2), bendEstimate(cross_left, cross_right));
}

test "polyline metrics count geometry rather than stored vertices" {
    const path = [_]Point{
        .{ 0, 0 },
        .{ 1, 0 },
        .{ 1, 0 }, // duplicate
        .{ 2, 0 }, // collinear subdivision
        .{ 2, 2 }, // one turn
        .{ 1, 2 }, // second turn
        .{ 2, 2 }, // reversal counts as a third turn
    };
    try testing.expectApproxEqAbs(@as(f64, 6), polylineLength(&path), 1e-12);
    try testing.expectEqual(@as(usize, 3), polylineBends(&path));

    const measured = measurePolyline(&path, .{ 1, 0 }, .{ -1, 0 });
    try testing.expectEqual(@as(usize, 3), measured.bends);
    try testing.expectApproxEqAbs(@as(f64, 6), measured.length_mm, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), measured.facing_penalty, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0), measured.axis_penalty, 1e-12);
}

test "rank keeps RF gates and shape ahead of length" {
    const clean_long = Rank{
        .shape = .{ .max_bends = 1, .total_bends = 2, .max_length_mm = 20, .total_length_mm = 100 },
    };
    var hard_short = Rank{ .hard_violations = 1 };
    try testing.expect(better(clean_long, hard_short));

    var via_short = Rank{ .vias = 1 };
    try testing.expect(better(clean_long, via_short));

    const bent_short = Rank{
        .shape = .{ .max_bends = 2, .total_bends = 2, .max_length_mm = 1, .total_length_mm = 1 },
    };
    try testing.expect(better(clean_long, bent_short));

    hard_short.hard_violations = 0;
    via_short.vias = 0;
    try testing.expectEqual(std.math.Order.eq, compare(hard_short, via_short));
}

test "correct pad orientation outranks a shorter wrong-facing route" {
    const correct_long = Rank{
        .shape = .{ .max_bends = 1, .total_bends = 1, .max_length_mm = 12, .total_length_mm = 12 },
    };
    const wrong_facing_short = Rank{
        .shape = .{ .max_bends = 1, .total_bends = 1, .max_length_mm = 1, .total_length_mm = 1 },
        .penalty = .{ .facing = 0.25 },
    };
    try testing.expect(better(correct_long, wrong_facing_short));

    const cross_axis_short = Rank{
        .shape = .{ .max_bends = 1, .total_bends = 1, .max_length_mm = 1, .total_length_mm = 1 },
        .penalty = .{ .axis = 0.25 },
    };
    try testing.expect(better(correct_long, cross_axis_short));
}

test "path aggregation builds a stable whole-candidate rank" {
    const paths = [_]Metrics{
        .{ .bends = 2, .length_mm = 3, .facing_penalty = 0.25, .axis_penalty = 0.5 },
        .{ .bends = 1, .length_mm = 8, .facing_penalty = 0.75, .axis_penalty = 0.25 },
    };
    const rank = rankPaths(&paths);
    try testing.expectEqual(@as(usize, 2), rank.shape.max_bends);
    try testing.expectEqual(@as(usize, 3), rank.shape.total_bends);
    try testing.expectApproxEqAbs(@as(f64, 8), rank.shape.max_length_mm, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 11), rank.shape.total_length_mm, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 1), rank.penalty.facing, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.75), rank.penalty.axis, 1e-12);

    var invalid = rank;
    invalid.shape.total_length_mm = std.math.nan(f64);
    try testing.expect(better(rank, invalid));
}
