//! Parametric board-outline sketch model.
//!
//! The layout sidecar persists authoring intent (stable points/curves and
//! constraints), while every existing physical-board consumer continues to
//! receive the compiled closed polygon plus exact three-point circular arcs.
//! Keeping that boundary here prevents the browser editor, DRC, Gerber and 3D
//! paths from growing competing interpretations of a sketch.

const std = @import("std");
const numeric = @import("numeric.zig");
const optimizer = @import("placement/optimizer.zig");
const outline = @import("placement/outline.zig");

/// Sidecar schema version understood by this compiler.
pub const current_version: u8 = 1;
/// Defensive ceiling for points or curves in one interactive outline.
pub const max_entities: usize = 512;
/// Defensive ceiling for persisted relationships in one outline.
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

/// Physical and construction curves supported by the outline sketch.
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

/// Versioned parametric authoring state persisted with a layout outline.
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

/// Compile the ordered, non-construction curves into the physical board loop.
/// Physical curves must form exactly one closed chain in their stored order;
/// construction entities may appear anywhere and never enter the profile.
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

    const pts = try alloc.alloc([2]f64, profile_count);
    errdefer alloc.free(pts);
    var poly: std.ArrayList([2]f64) = .empty;
    errdefer poly.deinit(alloc);
    var arcs: std.ArrayList(optimizer.BoardArc) = .empty;
    errdefer arcs.deinit(alloc);

    var first_a: ?u32 = null;
    var previous_b: ?u32 = null;
    var out_i: usize = 0;
    for (sketch.curves) |curve| {
        if (curve.construction) continue;
        if (previous_b) |want| if (curve.a != want) return error.OpenProfile;
        const a = pointOf(sketch.points, curve.a) orelse return error.MissingPoint;
        const b = pointOf(sketch.points, curve.b) orelse return error.MissingPoint;
        if (!std.math.isFinite(a[0]) or !std.math.isFinite(a[1])) return error.DegenerateCurve;
        if (!std.math.isFinite(b[0]) or !std.math.isFinite(b[1])) return error.DegenerateCurve;
        if (std.math.hypot(a[0] - b[0], a[1] - b[1]) <= 1e-9) return error.DegenerateCurve;
        pts[out_i] = a;
        out_i += 1;
        if (first_a == null) first_a = curve.a;
        previous_b = curve.b;
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
    if (previous_b.? != first_a.?) return error.OpenProfile;

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

test "outline sketch rejects open and duplicate-id profiles" {
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
