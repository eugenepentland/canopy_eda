//! Parametric closed-shape sketch model for board outlines and copper pours.
//!
//! The layout sidecar persists authoring intent (stable points/curves and
//! constraints), while physical-board and copper-fill consumers continue to
//! receive the compiled closed polygon plus exact three-point circular arcs.
//! Keeping that boundary here prevents the browser editor, DRC, Gerber and 3D
//! paths from growing competing interpretations of a sketch.

const std = @import("std");
const numeric = @import("numeric.zig");
const optimizer = @import("placement/optimizer.zig");
const outline = @import("placement/outline.zig");

/// Sidecar schema version understood by this compiler.
pub const current_version: u8 = 1;
/// Defensive ceiling for points or curves in one interactive shape.
pub const max_entities: usize = 512;
/// Defensive ceiling for persisted relationships in one shape.
pub const max_constraints: usize = 1024;
/// Maximum chord deviation used by physical polygon consumers.
pub const default_sagitta_mm: f64 = 0.01;

/// One stable sketch point in world millimetres.
pub const Point = struct {
    id: u32,
    x: f64,
    y: f64,
    construction: bool = false,
};

/// Physical and construction curves supported by the shape sketch.
pub const CurveKind = enum { line, arc };

/// A curve references stable point IDs. Arc `mid` selects the exact directed
/// circular span between its endpoints; a line must leave `mid` null.
pub const Curve = struct {
    id: u32,
    kind: CurveKind,
    a: u32,
    b: u32,
    mid: ?[2]f64 = null,
    construction: bool = false,
};

/// Persisted geometric relationships and numeric dimensions.
pub const ConstraintKind = enum {
    coincident,
    horizontal,
    vertical,
    parallel,
    perpendicular,
    tangent,
    equal,
    midpoint,
    symmetric,
    fixed,
    distance_x,
    distance_y,
    distance,
    length,
    angle,
    radius,
    diameter,
};

/// Whether a relationship drives geometry, only reports it, or is disabled.
pub const ConstraintMode = enum { driving, reference, disabled };

/// `a` and `b` address stable point or curve IDs according to `kind`. Numeric
/// dimensions carry `value`; reference-only dimensions set `driving=false`.
pub const Constraint = struct {
    id: u32,
    kind: ConstraintKind,
    a: u32,
    b: ?u32 = null,
    c: ?u32 = null,
    value: ?f64 = null,
    mode: ConstraintMode = .driving,
};

/// Versioned parametric authoring state persisted with a layout shape.
pub const Sketch = struct {
    version: u8 = current_version,
    points: []const Point,
    curves: []const Curve,
    constraints: []const Constraint = &.{},
};

/// Physical contour derived from the authoring sketch.
pub const Compiled = struct {
    /// Nominal profile vertices: one start point per ordered physical curve.
    pts: []const [2]f64,
    /// Fine chord fallback for point-in-polygon, raster and clearance math.
    poly: []const [2]f64,
    /// Exact physical circular curves for SVG, KiCad and Gerber.
    arcs: []const optimizer.BoardArc,
    rect: optimizer.BoardRect,
};

/// Structural or geometric reasons a sketch cannot become a board profile.
pub const CompileError = error{
    UnsupportedVersion,
    TooManyEntities,
    TooManyConstraints,
    DuplicateId,
    MissingPoint,
    OpenProfile,
    DegenerateCurve,
    InvalidArc,
    InvalidProfile,
} || std.mem.Allocator.Error;

fn pointIndex(points: []const Point, id: u32) ?usize {
    for (points, 0..) |p, i| if (p.id == id) return i;
    return null;
}

fn pointOf(points: []const Point, id: u32) ?[2]f64 {
    const i = pointIndex(points, id) orelse return null;
    return .{ points[i].x, points[i].y };
}

fn idsUnique(sketch: Sketch) bool {
    for (sketch.points, 0..) |p, i| {
        for (sketch.points[i + 1 ..]) |q| if (p.id == q.id) return false;
        for (sketch.curves) |curve| if (p.id == curve.id) return false;
        for (sketch.constraints) |constraint| if (p.id == constraint.id) return false;
    }
    for (sketch.curves, 0..) |curve, i| {
        for (sketch.curves[i + 1 ..]) |other| if (curve.id == other.id) return false;
        for (sketch.constraints) |constraint| if (curve.id == constraint.id) return false;
    }
    for (sketch.constraints, 0..) |constraint, i|
        for (sketch.constraints[i + 1 ..]) |other|
            if (constraint.id == other.id) return false;
    return true;
}

fn curveExists(sketch: Sketch, id: u32) bool {
    for (sketch.curves) |curve| if (curve.id == id) return true;
    return false;
}

fn pointExists(sketch: Sketch, id: u32) bool {
    return pointIndex(sketch.points, id) != null;
}

fn dimensionValid(constraint: Constraint) bool {
    const value = constraint.value orelse return false;
    if (!std.math.isFinite(value)) return false;
    return switch (constraint.kind) {
        .angle, .distance_x, .distance_y => true,
        else => value > 0,
    };
}

fn constraintsValid(sketch: Sketch) bool {
    for (sketch.constraints) |constraint| switch (constraint.kind) {
        .horizontal, .vertical => if (!curveExists(sketch, constraint.a)) return false,
        .length, .angle, .radius, .diameter => {
            if (!curveExists(sketch, constraint.a)) return false;
            if (!dimensionValid(constraint)) return false;
        },
        .parallel, .perpendicular, .tangent, .equal => {
            if (!curveExists(sketch, constraint.a)) return false;
            if (!curveExists(sketch, constraint.b orelse return false)) return false;
        },
        .coincident => {
            if (!pointExists(sketch, constraint.a)) return false;
            if (!pointExists(sketch, constraint.b orelse return false)) return false;
        },
        .distance_x, .distance_y, .distance => {
            if (!pointExists(sketch, constraint.a)) return false;
            if (!pointExists(sketch, constraint.b orelse return false)) return false;
            if (!dimensionValid(constraint)) return false;
        },
        .midpoint => {
            if (!pointExists(sketch, constraint.a)) return false;
            if (!curveExists(sketch, constraint.b orelse return false)) return false;
        },
        .symmetric => {
            if (!pointExists(sketch, constraint.a)) return false;
            if (!pointExists(sketch, constraint.b orelse return false)) return false;
            if (!curveExists(sketch, constraint.c orelse return false)) return false;
        },
        .fixed => if (!pointExists(sketch, constraint.a)) return false,
    };
    return true;
}

fn appendUnique(list: *std.ArrayList([2]f64), alloc: std.mem.Allocator, p: [2]f64) std.mem.Allocator.Error!void {
    if (list.items.len > 0) {
        const q = list.items[list.items.len - 1];
        if (std.math.hypot(q[0] - p[0], q[1] - p[1]) <= 1e-9) return;
    }
    try list.append(alloc, p);
}

fn appendArcFallback(
    list: *std.ArrayList([2]f64),
    alloc: std.mem.Allocator,
    arc: optimizer.BoardArc,
    max_sagitta: f64,
) CompileError!void {
    const circle = outline.arcCircle(arc) orelse return error.InvalidArc;
    if (!(circle.radius > 1e-9)) return error.InvalidArc;
    if (!std.math.isFinite(circle.radius)) return error.InvalidArc;
    if (!std.math.isFinite(circle.sweep)) return error.InvalidArc;
    if (@abs(circle.sweep) < 1e-9) return error.InvalidArc;
    const sag = @max(1e-4, max_sagitta);
    const step = if (circle.radius <= sag)
        @abs(circle.sweep)
    else
        2 * std.math.acos(std.math.clamp(1 - sag / circle.radius, -1, 1));
    const raw = @ceil(@abs(circle.sweep) / @max(step, 1e-3));
    const count = numeric.checkedInt(usize, std.math.clamp(raw, 1, 256)) orelse 1;
    var k: usize = 0;
    while (k < count) : (k += 1) {
        const frac = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(count));
        const angle = circle.start_angle + circle.sweep * frac;
        try appendUnique(list, alloc, .{
            circle.cx + circle.radius * @cos(angle),
            circle.cy + circle.radius * @sin(angle),
        });
    }
}

const ProfileStep = struct {
    curve_index: usize,
    reverse: bool,
};

/// Traverse the physical curves as one closed, non-branching contour. Sketch
/// editors keep stable entity IDs, so a repaired edge may sit at the end of the
/// array or face against its neighbours even though the geometry is a valid
/// loop. Curve storage order is authoring history, not fabrication geometry.
fn profileOrder(alloc: std.mem.Allocator, sketch: Sketch, profile_count: usize) CompileError![]ProfileStep {
    const order = try alloc.alloc(ProfileStep, profile_count);
    errdefer alloc.free(order);
    const used = try alloc.alloc(bool, sketch.curves.len);
    defer alloc.free(used);
    @memset(used, false);

    var first_index: ?usize = null;
    for (sketch.curves, 0..) |curve, i| if (!curve.construction) {
        first_index = i;
        break;
    };
    const start_i = first_index orelse return error.OpenProfile;
    const start = sketch.curves[start_i];
    order[0] = .{ .curve_index = start_i, .reverse = false };
    used[start_i] = true;
    const first_point = start.a;
    var at = start.b;

    for (1..profile_count) |out_i| {
        var match: ?usize = null;
        for (sketch.curves, 0..) |curve, curve_i| {
            if (curve.construction or used[curve_i]) continue;
            if (curve.a != at and curve.b != at) continue;
            // More than one unused continuation is a branch, not one closed
            // contour. Preserve the established open-profile classification.
            if (match != null) return error.OpenProfile;
            match = curve_i;
        }
        const curve_i = match orelse return error.OpenProfile;
        const curve = sketch.curves[curve_i];
        const reverse = curve.b == at;
        order[out_i] = .{ .curve_index = curve_i, .reverse = reverse };
        used[curve_i] = true;
        at = if (reverse) curve.a else curve.b;
    }
    if (at != first_point) return error.OpenProfile;
    return order;
}

/// Compile the non-construction curves into the physical board loop.
/// Curves must form exactly one closed chain, but may be stored in any order or
/// direction; construction entities may appear anywhere and never enter it.
pub fn compile(alloc: std.mem.Allocator, sketch: Sketch, max_sagitta: f64) CompileError!Compiled {
    if (sketch.version != current_version) return error.UnsupportedVersion;
    if (sketch.points.len > max_entities or sketch.curves.len > max_entities) return error.TooManyEntities;
    if (sketch.constraints.len > max_constraints) return error.TooManyConstraints;
    if (!idsUnique(sketch)) return error.DuplicateId;
    if (!constraintsValid(sketch)) return error.InvalidProfile;

    var profile_count: usize = 0;
    for (sketch.curves) |curve| if (!curve.construction) {
        profile_count += 1;
    };
    if (profile_count < 2) return error.OpenProfile;
    const order = try profileOrder(alloc, sketch, profile_count);
    defer alloc.free(order);

    const pts = try alloc.alloc([2]f64, profile_count);
    errdefer alloc.free(pts);
    var poly: std.ArrayList([2]f64) = .empty;
    errdefer poly.deinit(alloc);
    var arcs: std.ArrayList(optimizer.BoardArc) = .empty;
    errdefer arcs.deinit(alloc);

    var out_i: usize = 0;
    for (order) |step| {
        const curve = sketch.curves[step.curve_index];
        const a_id = if (step.reverse) curve.b else curve.a;
        const b_id = if (step.reverse) curve.a else curve.b;
        const a = pointOf(sketch.points, a_id) orelse return error.MissingPoint;
        const b = pointOf(sketch.points, b_id) orelse return error.MissingPoint;
        if (!std.math.isFinite(a[0]) or !std.math.isFinite(a[1])) return error.DegenerateCurve;
        if (!std.math.isFinite(b[0]) or !std.math.isFinite(b[1])) return error.DegenerateCurve;
        if (std.math.hypot(a[0] - b[0], a[1] - b[1]) <= 1e-9) return error.DegenerateCurve;
        pts[out_i] = a;
        out_i += 1;
        switch (curve.kind) {
            .line => {
                if (curve.mid != null) return error.InvalidArc;
                try appendUnique(&poly, alloc, a);
            },
            .arc => {
                const mid = curve.mid orelse return error.InvalidArc;
                if (!std.math.isFinite(mid[0]) or !std.math.isFinite(mid[1])) return error.InvalidArc;
                const arc: optimizer.BoardArc = .{ .p1 = a, .pm = mid, .p2 = b };
                try appendArcFallback(&poly, alloc, arc, max_sagitta);
                try arcs.append(alloc, arc);
            },
        }
    }

    const poly_slice = try poly.toOwnedSlice(alloc);
    errdefer alloc.free(poly_slice);
    if (!outline.valid(poly_slice)) return error.InvalidProfile;
    return .{
        .pts = pts,
        .poly = poly_slice,
        .arcs = try arcs.toOwnedSlice(alloc),
        .rect = outline.bboxRect(poly_slice),
    };
}

/// Add the only unambiguous missing line when the physical curves are one
/// connected open chain. The candidate must compile as a valid closed profile;
/// branches, disconnected contours, crossings and degenerate geometry are
/// deliberately left for the caller to reject.
pub fn closeSingleGap(alloc: std.mem.Allocator, sketch: Sketch) CompileError!?Sketch {
    if (sketch.version != current_version) return null;
    if (sketch.points.len > max_entities or sketch.curves.len >= max_entities) return null;
    if (sketch.constraints.len > max_constraints) return null;
    if (!idsUnique(sketch) or !constraintsValid(sketch)) return null;

    const degrees = try alloc.alloc(u8, sketch.points.len);
    defer alloc.free(degrees);
    @memset(degrees, 0);

    var profile_count: usize = 0;
    for (sketch.curves) |curve| {
        if (curve.construction) continue;
        profile_count += 1;
        const a = pointIndex(sketch.points, curve.a) orelse return null;
        const b = pointIndex(sketch.points, curve.b) orelse return null;
        if (a == b or degrees[a] >= 2 or degrees[b] >= 2) return null;
        degrees[a] += 1;
        degrees[b] += 1;
    }
    if (profile_count < 2) return null;

    var endpoints: [2]u32 = undefined;
    var endpoint_count: usize = 0;
    for (degrees, 0..) |degree, point_i| switch (degree) {
        0 => {
            const point = sketch.points[point_i];
            var construction_only = point.construction;
            for (sketch.curves) |curve| if (curve.construction and (curve.a == point.id or curve.b == point.id)) {
                construction_only = true;
                break;
            };
            if (!construction_only) return null;
        },
        2 => {},
        1 => {
            if (endpoint_count == endpoints.len) return null;
            endpoints[endpoint_count] = sketch.points[point_i].id;
            endpoint_count += 1;
        },
        else => return null,
    };
    if (endpoint_count != endpoints.len) return null;

    var max_id: u32 = 0;
    for (sketch.points) |point| max_id = @max(max_id, point.id);
    for (sketch.curves) |curve| max_id = @max(max_id, curve.id);
    for (sketch.constraints) |constraint| max_id = @max(max_id, constraint.id);
    if (max_id == std.math.maxInt(u32)) return null;

    const curves = try alloc.alloc(Curve, sketch.curves.len + 1);
    errdefer alloc.free(curves);
    @memcpy(curves[0..sketch.curves.len], sketch.curves);
    curves[sketch.curves.len] = .{
        .id = max_id + 1,
        .kind = .line,
        .a = endpoints[0],
        .b = endpoints[1],
    };
    const repaired: Sketch = .{
        .version = sketch.version,
        .points = sketch.points,
        .curves = curves,
        .constraints = sketch.constraints,
    };
    const compiled = compile(alloc, repaired, default_sagitta_mm) catch |err| switch (err) {
        error.OutOfMemory => return err,
        else => {
            alloc.free(curves);
            return null;
        },
    };
    alloc.free(compiled.pts);
    alloc.free(compiled.poly);
    alloc.free(compiled.arcs);
    return repaired;
}

/// Rebuild a clean, line-only authoring sketch from the exact polygon visible
/// to fill, DRC and export consumers. This is a recovery boundary for invalid
/// hidden authoring topology: only an already-valid physical polygon qualifies.
pub fn fromPolygon(alloc: std.mem.Allocator, poly: []const [2]f64) CompileError!?Sketch {
    if (poly.len < 3 or poly.len > max_entities or !outline.valid(poly)) return null;
    for (poly, 0..) |p, i| {
        const q = poly[(i + 1) % poly.len];
        if (!std.math.isFinite(p[0]) or !std.math.isFinite(p[1])) return null;
        if (std.math.hypot(q[0] - p[0], q[1] - p[1]) <= 1e-9) return null;
    }

    const points = try alloc.alloc(Point, poly.len);
    errdefer alloc.free(points);
    const curves = try alloc.alloc(Curve, poly.len);
    errdefer alloc.free(curves);
    for (poly, 0..) |p, i| {
        const point_id: u32 = @intCast(i + 1);
        const next_id: u32 = @intCast((i + 1) % poly.len + 1);
        points[i] = .{ .id = point_id, .x = p[0], .y = p[1] };
        curves[i] = .{
            .id = @intCast(max_entities + i + 1),
            .kind = .line,
            .a = point_id,
            .b = next_id,
        };
    }
    return .{ .points = points, .curves = curves };
}

fn rectSketch() Sketch {
    return .{
        .points = @constCast(&[_]Point{
            .{ .id = 1, .x = 0, .y = 0 },
            .{ .id = 2, .x = 20, .y = 0 },
            .{ .id = 3, .x = 20, .y = 10 },
            .{ .id = 4, .x = 0, .y = 10 },
        }),
        .curves = @constCast(&[_]Curve{
            .{ .id = 11, .kind = .line, .a = 1, .b = 2 },
            .{ .id = 12, .kind = .line, .a = 2, .b = 3 },
            .{ .id = 13, .kind = .line, .a = 3, .b = 4 },
            .{ .id = 14, .kind = .line, .a = 4, .b = 1 },
        }),
    };
}

test "outline sketch compiles an ordered line profile" {
    const got = try compile(std.testing.allocator, rectSketch(), default_sagitta_mm);
    defer std.testing.allocator.free(got.pts);
    defer std.testing.allocator.free(got.poly);
    defer std.testing.allocator.free(got.arcs);
    try std.testing.expectEqual(@as(usize, 4), got.pts.len);
    try std.testing.expectEqual(@as(usize, 4), got.poly.len);
    try std.testing.expectEqual(@as(f64, 20), got.rect.w);
    try std.testing.expectEqual(@as(f64, 10), got.rect.h);
}

test "outline sketch compiles a closed profile stored out of order and direction" {
    var sketch = rectSketch();
    sketch.curves = @constCast(&[_]Curve{
        .{ .id = 11, .kind = .line, .a = 1, .b = 2 },
        .{ .id = 13, .kind = .line, .a = 4, .b = 3 },
        .{ .id = 12, .kind = .line, .a = 2, .b = 3 },
        .{ .id = 14, .kind = .line, .a = 4, .b = 1 },
    });
    const compiled = try compile(std.testing.allocator, sketch, default_sagitta_mm);
    defer std.testing.allocator.free(compiled.pts);
    defer std.testing.allocator.free(compiled.poly);
    defer std.testing.allocator.free(compiled.arcs);
    const expected = [_][2]f64{ .{ 0, 0 }, .{ 20, 0 }, .{ 20, 10 }, .{ 0, 10 } };
    try std.testing.expectEqualSlices([2]f64, &expected, compiled.pts);
}

test "outline sketch preserves a reversed native arc while traversing the contour" {
    var sketch = rectSketch();
    sketch.curves = @constCast(&[_]Curve{
        .{ .id = 11, .kind = .line, .a = 1, .b = 2 },
        .{ .id = 13, .kind = .line, .a = 3, .b = 4 },
        .{ .id = 12, .kind = .arc, .a = 3, .b = 2, .mid = .{ 25, 5 } },
        .{ .id = 14, .kind = .line, .a = 4, .b = 1 },
    });
    const compiled = try compile(std.testing.allocator, sketch, default_sagitta_mm);
    defer std.testing.allocator.free(compiled.pts);
    defer std.testing.allocator.free(compiled.poly);
    defer std.testing.allocator.free(compiled.arcs);
    try std.testing.expectEqual(@as(usize, 1), compiled.arcs.len);
    try std.testing.expectEqual([2]f64{ 20, 0 }, compiled.arcs[0].p1);
    try std.testing.expectEqual([2]f64{ 20, 10 }, compiled.arcs[0].p2);
}

test "outline sketch retains a native circular edge and bounded fallback" {
    const points = [_]Point{
        .{ .id = 1, .x = 0, .y = 0 },
        .{ .id = 2, .x = 10, .y = 0 },
        .{ .id = 3, .x = 10, .y = 10 },
        .{ .id = 4, .x = 0, .y = 10 },
    };
    const curves = [_]Curve{
        .{ .id = 11, .kind = .arc, .a = 1, .b = 2, .mid = .{ 5, -2 } },
        .{ .id = 12, .kind = .line, .a = 2, .b = 3 },
        .{ .id = 13, .kind = .line, .a = 3, .b = 4 },
        .{ .id = 14, .kind = .line, .a = 4, .b = 1 },
    };
    const got = try compile(std.testing.allocator, .{ .points = &points, .curves = &curves }, default_sagitta_mm);
    defer std.testing.allocator.free(got.pts);
    defer std.testing.allocator.free(got.poly);
    defer std.testing.allocator.free(got.arcs);
    try std.testing.expectEqual(@as(usize, 1), got.arcs.len);
    try std.testing.expect(got.poly.len > got.pts.len);
    try std.testing.expect(got.rect.miny < 0);
}

test "outline sketch rejects a branched open profile and duplicate ids" {
    var open_curves = [_]Curve{
        .{ .id = 11, .kind = .line, .a = 1, .b = 2 },
        .{ .id = 12, .kind = .line, .a = 2, .b = 3 },
        .{ .id = 13, .kind = .line, .a = 3, .b = 4 },
        .{ .id = 14, .kind = .line, .a = 4, .b = 2 },
    };
    var open = rectSketch();
    open.curves = &open_curves;
    try std.testing.expectError(error.OpenProfile, compile(std.testing.allocator, open, default_sagitta_mm));

    var duplicate_curves = open_curves;
    duplicate_curves[3] = .{ .id = 1, .kind = .line, .a = 4, .b = 1 };
    var duplicate = rectSketch();
    duplicate.curves = &duplicate_curves;
    try std.testing.expectError(error.DuplicateId, compile(std.testing.allocator, duplicate, default_sagitta_mm));
}

test "outline sketch closes one unambiguous gap but refuses branches" {
    var open = rectSketch();
    open.curves = open.curves[0..3];
    const repaired = (try closeSingleGap(std.testing.allocator, open)) orelse
        return error.TestUnexpectedResult;
    defer std.testing.allocator.free(repaired.curves);
    try std.testing.expectEqual(@as(usize, 4), repaired.curves.len);
    const closing = repaired.curves[3];
    try std.testing.expect(
        (closing.a == 1 and closing.b == 4) or
            (closing.a == 4 and closing.b == 1),
    );

    const compiled = try compile(std.testing.allocator, repaired, default_sagitta_mm);
    defer std.testing.allocator.free(compiled.pts);
    defer std.testing.allocator.free(compiled.poly);
    defer std.testing.allocator.free(compiled.arcs);
    try std.testing.expectEqual(@as(usize, 4), compiled.pts.len);

    var branched = rectSketch();
    branched.curves = @constCast(&[_]Curve{
        .{ .id = 11, .kind = .line, .a = 1, .b = 2 },
        .{ .id = 12, .kind = .line, .a = 2, .b = 3 },
        .{ .id = 13, .kind = .line, .a = 2, .b = 4 },
    });
    try std.testing.expect((try closeSingleGap(std.testing.allocator, branched)) == null);

    var unused = rectSketch();
    unused.curves = unused.curves[0..2];
    try std.testing.expect((try closeSingleGap(std.testing.allocator, unused)) == null);
}

test "outline sketch rebuilds a valid visible polygon but rejects malformed backing" {
    const poly = [_][2]f64{ .{ 0, 0 }, .{ 6, 0 }, .{ 6, 4 }, .{ 0, 4 } };
    const rebuilt = (try fromPolygon(std.testing.allocator, &poly)) orelse
        return error.TestUnexpectedResult;
    defer std.testing.allocator.free(rebuilt.points);
    defer std.testing.allocator.free(rebuilt.curves);
    const compiled = try compile(std.testing.allocator, rebuilt, default_sagitta_mm);
    defer std.testing.allocator.free(compiled.pts);
    defer std.testing.allocator.free(compiled.poly);
    defer std.testing.allocator.free(compiled.arcs);
    try std.testing.expectEqualSlices([2]f64, &poly, compiled.pts);

    const bow_tie = [_][2]f64{ .{ 0, 0 }, .{ 4, 4 }, .{ 0, 4 }, .{ 4, 0 } };
    try std.testing.expect((try fromPolygon(std.testing.allocator, &bow_tie)) == null);
    const repeated = [_][2]f64{ .{ 0, 0 }, .{ 4, 0 }, .{ 4, 0 }, .{ 0, 4 } };
    try std.testing.expect((try fromPolygon(std.testing.allocator, &repeated)) == null);
}
