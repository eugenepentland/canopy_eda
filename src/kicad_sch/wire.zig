//! Orthogonal wire routing for the `.kicad_sch` exporter.
//!
//! Most connections on an exported sheet are made by a global label at the end
//! of each pin's stub. That is correct by construction and the only way to join
//! pins living on different sheets — but a decoupling cap beside the pad it
//! serves, a resistor in series between two parts, or a two-pin net wholly
//! inside one cluster all read far better as a **drawn wire**, the way a
//! hand-drawn schematic does.
//!
//! This module is the geometry half of that. Given two stub ends and everything
//! already on the sheet it returns the tidiest orthogonal polyline joining
//! them — or nothing at all. "Nothing" is a perfectly good answer: the caller
//! then keeps today's label pair, so a wire is drawn only where a clean route
//! exists. There is deliberately no maze search here; a connection that needs
//! one is a connection a label expresses better.
//!
//! Three KiCad 10.0.1 facts, all measured (`scratchpad/p5probe`), shape every
//! rule below:
//!
//!   * Wires join only where their **endpoints** coincide. Two wires may cross
//!     freely — a crossing is not a connection. But a wire END on another
//!     wire's interior stays *unconnected* and reports
//!     `unconnected_wire_endpoint`, and two collinear wires overlapping do the
//!     same, so both are rejected here.
//!   * A pin lying in a wire's **interior** does not connect either: KiCad
//!     reports `pin_not_connected` for it. A wire drawn through a pin is
//!     therefore a drawing that lies about the netlist, and is rejected.
//!   * Three or more wire ends at one point connect with or without a junction
//!     dot. The dot is what a reader looks for, so `junctions` names every such
//!     point and the emitter draws one.

const std = @import("std");
const shape_mod = @import("shape.zig");

/// KiCad's connection grid, in hundredths of a millimetre. Every wire point is
/// a multiple of it — an off-grid endpoint is an ERC warning and a point the
/// user's cursor cannot snap to.
pub const grid: i32 = shape_mod.grid;

/// The longest Manhattan span a connection is drawn across (50.8 mm). Past
/// this a wire is harder to follow across the page than the label pair it
/// would replace.
pub const max_span: i32 = 12700;

/// Half the coordinate range `pointKey` can pack, in hundredths of a
/// millimetre — comfortably beyond the largest page KiCad will load.
const key_offset: i64 = 1 << 20;

/// A point in sheet coordinates: hundredths of a millimetre, y growing down.
pub const Point = struct { x: i32, y: i32 };

/// One drawn wire segment. Always axis-aligned and never zero length.
pub const Seg = struct { a: Point, b: Point };

/// A placed symbol's body rectangle, in sheet coordinates.
pub const Box = struct { x0: i32, y0: i32, x1: i32, y1: i32 };

/// One end of a connection: the stub end a wire is routed between, and the
/// symbol edge its pin leaves from — which is also the direction the stub
/// already runs, and so the direction a route can extend it in for free.
pub const End = struct {
    at: Point,
    side: shape_mod.Side,
};

/// A routed connection: the polyline joining two stub ends, plus the stable key
/// its segments' uuids are derived from.
pub const Path = struct {
    key: []const u8,
    pts: []const Point,
};

/// Everything already on the sheet that a new wire must respect.
pub const Field = struct {
    /// Connection points — pin endpoints, stub ends, power-symbol origins. A
    /// wire may coincide with one only at its own two ends.
    stops: []const Point = &.{},
    /// Symbol bodies. A wire through one draws over the part.
    bodies: []const Box = &.{},
    /// Wire segments already drawn: the per-pin stubs and every earlier route.
    segs: []const Seg = &.{},
};

/// True when two points are the same point.
pub fn samePoint(a: Point, b: Point) bool {
    return a.x == b.x and a.y == b.y;
}

/// Manhattan distance between two points — the length of the shortest
/// orthogonal route joining them.
pub fn span(a: Point, b: Point) i32 {
    return @intCast(@abs(a.x - b.x) + @abs(a.y - b.y));
}

/// The tidiest orthogonal polyline from `a` to `b` that touches nothing it must
/// not, or null when no candidate is clean. Candidates are tried in reading
/// order — straight, one bend, two bends, then progressively wider escape
/// lanes — so the wire that gets drawn is the simplest one that fits.
pub fn route(
    arena: std.mem.Allocator,
    a: End,
    b: End,
    field: Field,
    key: []const u8,
) std.mem.Allocator.Error!?Path {
    if (span(a.at, b.at) > max_span) return null;
    if (span(a.at, b.at) == 0) return null;
    var buf: [6]Point = undefined;
    for (0..candidate_count) |i| {
        const pts = compact(candidate(i, a, b, &buf));
        if (!clean(pts, a.at, b.at, field)) continue;
        return Path{ .key = key, .pts = try arena.dupe(Point, pts) };
    }
    return null;
}

/// Points where three or more wire ends meet, sorted so the emitted document is
/// byte-stable. KiCad connects such a point with or without the dot; the dot is
/// the reading convention.
pub fn junctions(
    arena: std.mem.Allocator,
    segs: []const Seg,
) std.mem.Allocator.Error![]const Point {
    var counts: std.array_hash_map.Auto(i64, u32) = .empty;
    defer counts.deinit(arena);
    for (segs) |s| {
        try bump(arena, &counts, s.a);
        try bump(arena, &counts, s.b);
    }
    var out: std.ArrayList(Point) = .empty;
    for (counts.keys(), counts.values()) |k, n| {
        if (n < 3) continue;
        try out.append(arena, unkey(k));
    }
    std.mem.sort(Point, out.items, {}, lessPoint);
    return out.items;
}

/// Append one polyline's segments to a running list of drawn wire.
pub fn appendSegs(
    arena: std.mem.Allocator,
    out: *std.ArrayList(Seg),
    pts: []const Point,
) std.mem.Allocator.Error!void {
    for (pts[0 .. pts.len - 1], pts[1..]) |a, b| {
        try out.append(arena, .{ .a = a, .b = b });
    }
}

// ── Candidate shapes ───────────────────────────────────────────────────

/// Straight, the two single-bend L routes, then the two double-bend jogs.
const base_shapes: usize = 5;

/// How far, in grid units, an escape route pushes each end out along its own
/// stub before crossing to the other. A dense IC edge is a wall of stub ends
/// and net labels, so the only clear lane between two of its pins runs OUTSIDE
/// that ring — which is exactly how the connection would be drawn by hand.
/// Several widths are offered so two runs along one edge can take
/// different lanes instead of the second being refused for overlapping the
/// first.
const escape_steps = [_]i32{ 2, 4, 6, 8, 12 };

/// How the two escaped ends are joined: straight across, an L turning at either
/// end's lane, or a dogleg through the corridor halfway between them — which is
/// the only shape that gets from one symbol's edge to another's when both ends
/// face outward in different directions.
const joins: usize = 5;

const candidate_count: usize = base_shapes + escape_steps.len * joins;

fn candidate(i: usize, a: End, b: End, buf: *[6]Point) []Point {
    if (i < base_shapes) return basic(i, a.at, b.at, buf);
    const k = i - base_shapes;
    return escaped(k % joins, a, b, escape_steps[k / joins] * grid, buf);
}

/// A route that first extends each stub outward by `step`, joins the two lanes,
/// and comes back in. The outward legs are collinear with the stubs they
/// continue, so they read as longer pins rather than as detours.
fn escaped(join: usize, a: End, b: End, step: i32, buf: *[6]Point) []Point {
    const a2 = outward(a, step);
    const b2 = outward(b, step);
    buf[0] = a.at;
    buf[1] = a2;
    const n = joinLane(join, a2, b2, buf[2..5]);
    buf[2 + n] = b2;
    buf[3 + n] = b.at;
    return buf[0 .. 4 + n];
}

/// The corner points that carry one escape lane over to the other, written into
/// `out`; returns how many there are.
fn joinLane(join: usize, a2: Point, b2: Point, out: []Point) usize {
    switch (join) {
        0 => return 0,
        1 => out[0] = .{ .x = b2.x, .y = a2.y },
        2 => out[0] = .{ .x = a2.x, .y = b2.y },
        3 => {
            const m = mid(a2.x, b2.x);
            out[0] = .{ .x = m, .y = a2.y };
            out[1] = .{ .x = m, .y = b2.y };
            return 2;
        },
        else => {
            const m = mid(a2.y, b2.y);
            out[0] = .{ .x = a2.x, .y = m };
            out[1] = .{ .x = b2.x, .y = m };
            return 2;
        },
    }
    return 1;
}

/// One end pushed `step` further along the direction its own stub already runs.
fn outward(e: End, step: i32) Point {
    return switch (e.side) {
        .left => .{ .x = e.at.x - step, .y = e.at.y },
        .right => .{ .x = e.at.x + step, .y = e.at.y },
        .top => .{ .x = e.at.x, .y = e.at.y - step },
        .bottom => .{ .x = e.at.x, .y = e.at.y + step },
    };
}

fn basic(i: usize, a: Point, b: Point, buf: *[6]Point) []Point {
    buf[0] = a;
    switch (i) {
        0 => buf[1] = b,
        1 => {
            buf[1] = .{ .x = b.x, .y = a.y };
            buf[2] = b;
        },
        2 => {
            buf[1] = .{ .x = a.x, .y = b.y };
            buf[2] = b;
        },
        3 => {
            const m = mid(a.x, b.x);
            buf[1] = .{ .x = m, .y = a.y };
            buf[2] = .{ .x = m, .y = b.y };
            buf[3] = b;
        },
        else => {
            const m = mid(a.y, b.y);
            buf[1] = .{ .x = a.x, .y = m };
            buf[2] = .{ .x = b.x, .y = m };
            buf[3] = b;
        },
    }
    return buf[0..pointCount(i)];
}

fn pointCount(i: usize) usize {
    return switch (i) {
        0 => 2,
        1, 2 => 3,
        else => 4,
    };
}

/// The grid point halfway between two coordinates. Rounded down so the same
/// pair always yields the same jog, whatever order it is asked in.
fn mid(u: i32, v: i32) i32 {
    return @divFloor(@divFloor(u + v, 2), grid) * grid;
}

/// Drop repeated points in place: a "bend" whose corner coincides with an end
/// is really the straight route, and a zero-length segment is not drawable.
fn compact(pts: []Point) []Point {
    var n: usize = 1;
    for (pts[1..]) |p| {
        if (samePoint(pts[n - 1], p)) continue;
        pts[n] = p;
        n += 1;
    }
    return pts[0..n];
}

// ── Validation ─────────────────────────────────────────────────────────

fn clean(pts: []const Point, a: Point, b: Point, field: Field) bool {
    if (pts.len < 2) return false;
    for (pts[0 .. pts.len - 1], pts[1..]) |p, q| {
        const s = Seg{ .a = p, .b = q };
        if (!legal(s)) return false;
        if (hitsStop(s, field.stops, a, b)) return false;
        if (hitsBody(s, field.bodies)) return false;
        if (hitsWire(s, field.segs, a, b)) return false;
    }
    return true;
}

/// A drawable segment: axis-aligned, positive length, both ends on the grid.
fn legal(s: Seg) bool {
    if (samePoint(s.a, s.b)) return false;
    if (!horizontal(s) and !vertical(s)) return false;
    if (!onGrid(s.a)) return false;
    return onGrid(s.b);
}

fn horizontal(s: Seg) bool {
    return s.a.y == s.b.y;
}

fn vertical(s: Seg) bool {
    return s.a.x == s.b.x;
}

fn onGrid(p: Point) bool {
    if (@rem(p.x, grid) != 0) return false;
    return @rem(p.y, grid) == 0;
}

/// A wire may coincide with a connection point only at its own two ends —
/// anywhere else it either merges a foreign net or draws through a pin that
/// KiCad then reports as unconnected.
fn hitsStop(s: Seg, stops: []const Point, a: Point, b: Point) bool {
    for (stops) |p| {
        if (samePoint(p, a)) continue;
        if (samePoint(p, b)) continue;
        if (onSeg(p, s)) return true;
    }
    return false;
}

/// True when `p` lies on the closed, axis-aligned segment `s`.
fn onSeg(p: Point, s: Seg) bool {
    if (!within(p.x, s.a.x, s.b.x)) return false;
    return within(p.y, s.a.y, s.b.y);
}

fn within(v: i32, lo: i32, hi: i32) bool {
    if (v < @min(lo, hi)) return false;
    return v <= @max(lo, hi);
}

/// True when the segment runs through a body's open interior. Touching an edge
/// is tolerated — a pin endpoint can legitimately sit on the boundary of the
/// symbol it belongs to — but any run *inside* would draw across the part.
fn hitsBody(s: Seg, bodies: []const Box) bool {
    for (bodies) |box| {
        if (entersBox(s, box)) return true;
    }
    return false;
}

fn entersBox(s: Seg, box: Box) bool {
    if (horizontal(s)) return strictly(s.a.y, box.y0, box.y1) and crossesX(s, box);
    return strictly(s.a.x, box.x0, box.x1) and crossesY(s, box);
}

fn crossesX(s: Seg, box: Box) bool {
    const lo = @max(@min(s.a.x, s.b.x), box.x0);
    const hi = @min(@max(s.a.x, s.b.x), box.x1);
    return lo < hi;
}

fn crossesY(s: Seg, box: Box) bool {
    const lo = @max(@min(s.a.y, s.b.y), box.y0);
    const hi = @min(@max(s.a.y, s.b.y), box.y1);
    return lo < hi;
}

fn strictly(v: i32, lo: i32, hi: i32) bool {
    if (v <= lo) return false;
    return v < hi;
}

/// True when this segment would interact with an existing one anywhere other
/// than at one of the route's own two ends, where its stub already meets it.
fn hitsWire(s: Seg, segs: []const Seg, a: Point, b: Point) bool {
    for (segs) |o| {
        if (conflict(s, o, a, b)) return true;
    }
    return false;
}

fn conflict(s: Seg, o: Seg, a: Point, b: Point) bool {
    if (collinear(s, o)) return overlaps(s, o, a, b);
    return touches(s, o, a, b);
}

fn collinear(s: Seg, o: Seg) bool {
    if (horizontal(s) and horizontal(o)) return s.a.y == o.a.y;
    if (vertical(s) and vertical(o)) return s.a.x == o.a.x;
    return false;
}

/// Two segments on the same line may share at most one of the route's own ends:
/// a run of common length merges the two wires outright, and a bare touch
/// anywhere else either leaves an end dangling or joins a net this route is not
/// on.
fn overlaps(s: Seg, o: Seg, a: Point, b: Point) bool {
    const es = axisSpan(s);
    const eo = axisSpan(o);
    const lo = @max(es[0], eo[0]);
    const hi = @min(es[1], eo[1]);
    if (lo > hi) return false;
    if (lo < hi) return true;
    return !sharedEnd(s, o, pointAt(s, lo), a, b);
}

/// The sorted extent of a segment along the axis it varies on.
fn axisSpan(s: Seg) [2]i32 {
    if (horizontal(s)) return .{ @min(s.a.x, s.b.x), @max(s.a.x, s.b.x) };
    return .{ @min(s.a.y, s.b.y), @max(s.a.y, s.b.y) };
}

/// The point on `s` at coordinate `v` along the axis it varies on.
fn pointAt(s: Seg, v: i32) Point {
    if (horizontal(s)) return .{ .x = v, .y = s.a.y };
    return .{ .x = s.a.x, .y = v };
}

/// A crossing is fine — KiCad joins wires only end to end. Anything else is
/// not: an end on another wire's interior dangles, and an end meeting a foreign
/// wire's end would silently join that wire's net.
fn touches(s: Seg, o: Seg, a: Point, b: Point) bool {
    const p = crossPoint(s, o) orelse return false;
    if (!isEnd(s, p) and !isEnd(o, p)) return false;
    return !sharedEnd(s, o, p, a, b);
}

/// The one point a route may legitimately share with existing wire: an end of
/// both, at one of the route's own two endpoints.
fn sharedEnd(s: Seg, o: Seg, p: Point, a: Point, b: Point) bool {
    if (!samePoint(p, a) and !samePoint(p, b)) return false;
    if (!isEnd(s, p)) return false;
    return isEnd(o, p);
}

/// The single point two axis-aligned, non-collinear segments share, if any.
fn crossPoint(s: Seg, o: Seg) ?Point {
    const p = meet(s, o) orelse return null;
    if (!onSeg(p, s)) return null;
    if (!onSeg(p, o)) return null;
    return p;
}

fn meet(s: Seg, o: Seg) ?Point {
    if (horizontal(s) and vertical(o)) return .{ .x = o.a.x, .y = s.a.y };
    if (vertical(s) and horizontal(o)) return .{ .x = s.a.x, .y = o.a.y };
    return null;
}

fn isEnd(s: Seg, p: Point) bool {
    if (samePoint(p, s.a)) return true;
    return samePoint(p, s.b);
}

// ── Junction bookkeeping ───────────────────────────────────────────────

fn bump(
    arena: std.mem.Allocator,
    counts: *std.array_hash_map.Auto(i64, u32),
    p: Point,
) std.mem.Allocator.Error!void {
    const gop = try counts.getOrPut(arena, pointKey(p));
    gop.value_ptr.* = if (gop.found_existing) gop.value_ptr.* + 1 else 1;
}

/// A collision-free key for a sheet point. Coordinates are bounded by the
/// clamped page, well inside `key_offset`, so shifting both onto a
/// non-negative range and packing them in base `2 * key_offset` is exact.
fn pointKey(p: Point) i64 {
    const x: i64 = @as(i64, p.x) + key_offset;
    const y: i64 = @as(i64, p.y) + key_offset;
    return x * (2 * key_offset) + y;
}

fn unkey(k: i64) Point {
    const y = @mod(k, 2 * key_offset) - key_offset;
    const x = @divFloor(k, 2 * key_offset) - key_offset;
    return .{ .x = @intCast(x), .y = @intCast(y) };
}

fn lessPoint(_: void, a: Point, b: Point) bool {
    if (a.x != b.x) return a.x < b.x;
    return a.y < b.y;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

const g: i32 = grid;

/// A stub end whose pin leaves the right edge, so its escape lane runs +x.
fn rightward(x: i32, y: i32) End {
    return .{ .at = .{ .x = x, .y = y }, .side = .right };
}

/// A stub end whose pin leaves the left edge, so its escape lane runs -x.
fn leftward(x: i32, y: i32) End {
    return .{ .at = .{ .x = x, .y = y }, .side = .left };
}

// spec: export_kicad_sch - A clear run between two stub ends routes straight, and an offset pair takes a single bend
test "kicad-sch: route prefers the straight run, then one bend" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const straight = (try route(a, rightward(0, 0), leftward(10 * g, 0), .{}, "k")).?;
    try testing.expectEqual(@as(usize, 2), straight.pts.len);
    try testing.expectEqualStrings("k", straight.key);

    const bent = (try route(a, rightward(0, 0), leftward(10 * g, 4 * g), .{}, "k")).?;
    try testing.expectEqual(@as(usize, 3), bent.pts.len);
    // Horizontal first: the corner shares the destination's x.
    try testing.expectEqual(@as(i32, 10 * g), bent.pts[1].x);
    try testing.expectEqual(@as(i32, 0), bent.pts[1].y);
    for (bent.pts) |p| {
        try testing.expectEqual(@as(i32, 0), @rem(p.x, g));
        try testing.expectEqual(@as(i32, 0), @rem(p.y, g));
    }
}

// spec: export_kicad_sch - A route is refused when every candidate would touch a foreign connection point
test "kicad-sch: route refuses a path that would run over a pin" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Both stubs run horizontally toward each other, so every candidate —
    // escape lanes included — stays on the line between them.
    const from = rightward(0, 0);
    const to = leftward(10 * g, 0);
    // A pin sitting in the middle of the only straight run.
    const stops = [_]Point{.{ .x = 5 * g, .y = 0 }};
    try testing.expect((try route(a, from, to, .{ .stops = &stops }, "k")) == null);

    // The endpoints themselves are exempt — they ARE the pins being joined.
    const ends = [_]Point{ from.at, to.at };
    try testing.expect((try route(a, from, to, .{ .stops = &ends }, "k")) != null);
}

// spec: export_kicad_sch - A route may cross an existing wire but never tee onto one, overlap it, or enter a symbol body
test "kicad-sch: route crosses foreign wire but avoids tees, overlaps, and bodies" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const from = rightward(0, 0);
    const to = leftward(10 * g, 0);

    // A wire crossing the straight run perpendicularly is not a connection.
    const crossing = [_]Seg{.{ .a = .{ .x = 5 * g, .y = -2 * g }, .b = .{ .x = 5 * g, .y = 2 * g } }};
    const over = (try route(a, from, to, .{ .segs = &crossing }, "k")).?;
    try testing.expectEqual(@as(usize, 2), over.pts.len);

    // A wire ENDING on the run would leave that end dangling, and a jog whose
    // corner landed on that end would silently join its net instead. Every
    // candidate between these two points lies on y = 0, so none survives.
    const tee = [_]Seg{.{ .a = .{ .x = 5 * g, .y = 0 }, .b = .{ .x = 5 * g, .y = 2 * g } }};
    try testing.expect((try route(a, from, to, .{ .segs = &tee }, "k")) == null);

    // A collinear wire sharing part of the run merges two nets.
    const along = [_]Seg{.{ .a = .{ .x = 3 * g, .y = 0 }, .b = .{ .x = 7 * g, .y = 0 } }};
    try testing.expect((try route(a, from, to, .{ .segs = &along }, "k")) == null);

    // A body straddling the run blocks it; the same body touched edge-on does not.
    const across = [_]Box{.{ .x0 = 4 * g, .y0 = -g, .x1 = 6 * g, .y1 = g }};
    try testing.expect((try route(a, from, to, .{ .bodies = &across }, "k")) == null);
    const edge = [_]Box{.{ .x0 = 4 * g, .y0 = 0, .x1 = 6 * g, .y1 = 2 * g }};
    try testing.expect((try route(a, from, to, .{ .bodies = &edge }, "k")) != null);
}

// spec: export_kicad_sch - A connection further apart than the wiring span keeps its label pair
test "kicad-sch: route gives up beyond the maximum span" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const far = leftward(max_span + grid, 0);
    try testing.expect((try route(a, rightward(0, 0), far, .{}, "k")) == null);
    try testing.expect((try route(a, rightward(0, 0), leftward(0, 0), .{}, "k")) == null);
}

// spec: export_kicad_sch - A junction is reported exactly where three or more wire ends meet
test "kicad-sch: junctions names the three-way meeting points only" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const hub = Point{ .x = 4 * g, .y = 4 * g };
    const segs = [_]Seg{
        .{ .a = .{ .x = 0, .y = 4 * g }, .b = hub },
        .{ .a = .{ .x = 8 * g, .y = 4 * g }, .b = hub },
        .{ .a = .{ .x = 4 * g, .y = 0 }, .b = hub },
        // A plain corner elsewhere: two ends, no dot.
        .{ .a = .{ .x = 0, .y = 0 }, .b = .{ .x = 0, .y = -2 * g } },
        .{ .a = .{ .x = 0, .y = -2 * g }, .b = .{ .x = 2 * g, .y = -2 * g } },
    };
    const dots = try junctions(a, &segs);
    try testing.expectEqual(@as(usize, 1), dots.len);
    try testing.expectEqual(hub.x, dots[0].x);
    try testing.expectEqual(hub.y, dots[0].y);
    try testing.expectEqual(@as(usize, 0), (try junctions(a, &.{})).len);
}

// spec: export_kicad_sch - A negative sheet coordinate survives the junction point key intact
test "kicad-sch: the junction point key round-trips both signs" {
    const pts = [_]Point{
        .{ .x = 0, .y = 0 },
        .{ .x = 12700, .y = -6350 },
        .{ .x = -6350, .y = 279400 },
    };
    for (pts) |p| {
        const back = unkey(pointKey(p));
        try testing.expectEqual(p.x, back.x);
        try testing.expectEqual(p.y, back.y);
    }
}
