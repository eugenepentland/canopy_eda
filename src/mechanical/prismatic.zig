//! Small, deterministic prismatic solid kernel used by mechanical CAD.
//!
//! Coordinates are millimetres in a right-handed, Z-up frame. Meshes are
//! indexed and outward-wound so one representation can feed the browser,
//! STL, and the existing AP242 faceted-body writer.

const std = @import("std");

/// Two-dimensional millimetre coordinate.
pub const Point2 = [2]f64;
/// Three-dimensional millimetre coordinate.
pub const Point3 = [3]f64;
/// Counter-clockwise indexed triangle.
pub const Triangle = [3]usize;

/// Owned indexed boundary mesh.
pub const Mesh = struct {
    points: []const Point3,
    triangles: []const Triangle,

    /// Release both owned index and vertex buffers.
    pub fn deinit(self: Mesh, allocator: std.mem.Allocator) void {
        allocator.free(self.points);
        allocator.free(self.triangles);
    }
};

/// Geometry rejected before a mesh can be produced.
pub const KernelError = error{
    InvalidDimensions,
    InvalidProfile,
};

fn finitePositive(value: f64) bool {
    return std.math.isFinite(value) and value > 0;
}

fn signedArea(profile: []const Point2) f64 {
    var area: f64 = 0;
    for (profile, 0..) |point, i| {
        const next = profile[(i + 1) % profile.len];
        area += point[0] * next[1] - next[0] * point[1];
    }
    return area * 0.5;
}

fn finitePoint2(point: Point2) bool {
    return std.math.isFinite(point[0]) and std.math.isFinite(point[1]);
}

fn validExtrusion(profile: []const Point2, z_min: f64, z_max: f64) bool {
    if (profile.len < 3) return false;
    if (!std.math.isFinite(z_min) or !std.math.isFinite(z_max)) return false;
    return z_max > z_min;
}

/// Extrude a simple convex CCW profile between two Z planes. This deliberately
/// starts with the mechanically useful, predictable subset; concave profiles,
/// holes, arcs, and boolean operations remain explicit future kernel layers.
pub fn extrudeConvex(
    allocator: std.mem.Allocator,
    profile: []const Point2,
    z_min: f64,
    z_max: f64,
) (KernelError || std.mem.Allocator.Error)!Mesh {
    if (!validExtrusion(profile, z_min, z_max)) return error.InvalidProfile;
    if (!(signedArea(profile) > 0)) return error.InvalidProfile;
    for (profile) |point| if (!finitePoint2(point)) return error.InvalidProfile;

    const points = try allocator.alloc(Point3, profile.len * 2);
    errdefer allocator.free(points);
    for (profile, 0..) |point, i| {
        points[i] = .{ point[0], point[1], z_min };
        points[profile.len + i] = .{ point[0], point[1], z_max };
    }

    var triangles: std.ArrayList(Triangle) = .empty;
    errdefer triangles.deinit(allocator);
    try triangles.ensureTotalCapacity(allocator, profile.len * 4 - 4);
    for (1..profile.len - 1) |i| {
        try triangles.append(allocator, .{ 0, i + 1, i });
        try triangles.append(allocator, .{ profile.len, profile.len + i, profile.len + i + 1 });
    }
    for (profile, 0..) |_, i| {
        const next = (i + 1) % profile.len;
        try triangles.append(allocator, .{ i, next, profile.len + next });
        try triangles.append(allocator, .{ i, profile.len + next, profile.len + i });
    }
    return .{ .points = points, .triangles = try triangles.toOwnedSlice(allocator) };
}

/// A rectangular open-top shell with a solid floor. Unlike a pile of
/// overlapping boxes, this is one watertight boundary with no internal faces.
pub fn rectangularShell(
    allocator: std.mem.Allocator,
    inner_width: f64,
    inner_depth: f64,
    wall: f64,
    floor: f64,
    height: f64,
) (KernelError || std.mem.Allocator.Error)!Mesh {
    const primary_valid = finitePositive(inner_width) and finitePositive(inner_depth);
    const construction_valid = finitePositive(wall) and finitePositive(floor) and finitePositive(height);
    if (!primary_valid) return error.InvalidDimensions;
    if (!construction_valid) return error.InvalidDimensions;
    if (floor >= height) return error.InvalidDimensions;

    const ix = inner_width / 2;
    const iy = inner_depth / 2;
    const ox = ix + wall;
    const oy = iy + wall;
    const points = try allocator.dupe(Point3, &.{
        .{ -ox, -oy, 0 },      .{ ox, -oy, 0 },      .{ ox, oy, 0 },      .{ -ox, oy, 0 },
        .{ -ox, -oy, height }, .{ ox, -oy, height }, .{ ox, oy, height }, .{ -ox, oy, height },
        .{ -ix, -iy, height }, .{ ix, -iy, height }, .{ ix, iy, height }, .{ -ix, iy, height },
        .{ -ix, -iy, floor },  .{ ix, -iy, floor },  .{ ix, iy, floor },  .{ -ix, iy, floor },
    });
    errdefer allocator.free(points);
    const triangles = try allocator.alloc(Triangle, 28);
    var cursor: usize = 0;
    const quads = [_][4]usize{
        // Bottom, outer walls, top rim, inner walls, cavity floor.
        .{ 0, 3, 2, 1 },
        .{ 0, 1, 5, 4 },
        .{ 1, 2, 6, 5 },
        .{ 2, 3, 7, 6 },
        .{ 3, 0, 4, 7 },
        .{ 4, 5, 9, 8 },
        .{ 5, 6, 10, 9 },
        .{ 6, 7, 11, 10 },
        .{ 7, 4, 8, 11 },
        .{ 12, 8, 9, 13 },
        .{ 13, 9, 10, 14 },
        .{ 14, 10, 11, 15 },
        .{ 15, 11, 8, 12 },
        .{ 12, 13, 14, 15 },
    };
    for (quads) |quad| {
        triangles[cursor] = .{ quad[0], quad[1], quad[2] };
        triangles[cursor + 1] = .{ quad[0], quad[2], quad[3] };
        cursor += 2;
    }
    return .{ .points = points, .triangles = triangles };
}

/// Build a centred rectangular prism.
pub fn box(
    allocator: std.mem.Allocator,
    width: f64,
    depth: f64,
    z_min: f64,
    z_max: f64,
) (KernelError || std.mem.Allocator.Error)!Mesh {
    if (!finitePositive(width) or !finitePositive(depth)) return error.InvalidDimensions;
    const hx = width / 2;
    const hy = depth / 2;
    return extrudeConvex(allocator, &.{ .{ -hx, -hy }, .{ hx, -hy }, .{ hx, hy }, .{ -hx, hy } }, z_min, z_max);
}

fn signedVolume(mesh: Mesh) f64 {
    var volume: f64 = 0;
    for (mesh.triangles) |tri| {
        const a = mesh.points[tri[0]];
        const b = mesh.points[tri[1]];
        const c = mesh.points[tri[2]];
        volume += (a[0] * (b[1] * c[2] - b[2] * c[1]) -
            a[1] * (b[0] * c[2] - b[2] * c[0]) +
            a[2] * (b[0] * c[1] - b[1] * c[0])) / 6;
    }
    return volume;
}

fn hasPairedDirectedEdges(allocator: std.mem.Allocator, mesh: Mesh) !bool {
    var directed: std.AutoHashMapUnmanaged([2]usize, usize) = .empty;
    defer directed.deinit(allocator);
    for (mesh.triangles) |tri| for (0..3) |i| {
        try directed.put(allocator, .{ tri[i], tri[(i + 1) % 3] }, 1);
    };
    for (mesh.triangles) |tri| for (0..3) |i| {
        if (!directed.contains(.{ tri[(i + 1) % 3], tri[i] })) return false;
    };
    return true;
}

test "convex extrusion is closed and has the expected volume" {
    const mesh = try box(std.testing.allocator, 10, 8, 2, 5);
    defer mesh.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 8), mesh.points.len);
    try std.testing.expectEqual(@as(usize, 12), mesh.triangles.len);
    try std.testing.expectApproxEqAbs(@as(f64, 240), signedVolume(mesh), 1e-9);
}

test "rectangular shell is one outward watertight boundary" {
    const mesh = try rectangularShell(std.testing.allocator, 10, 8, 2, 1, 6);
    defer mesh.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 16), mesh.points.len);
    try std.testing.expectEqual(@as(usize, 28), mesh.triangles.len);
    const expected = 14.0 * 12.0 * 6.0 - 10.0 * 8.0 * 5.0;
    try std.testing.expectApproxEqAbs(expected, signedVolume(mesh), 1e-9);

    try std.testing.expect(try hasPairedDirectedEdges(std.testing.allocator, mesh));
}

test "kernel rejects inside-out profiles and impossible shells" {
    try std.testing.expectError(error.InvalidProfile, extrudeConvex(
        std.testing.allocator,
        &.{ .{ 0, 0 }, .{ 0, 1 }, .{ 1, 0 } },
        0,
        1,
    ));
    try std.testing.expectError(error.InvalidDimensions, rectangularShell(std.testing.allocator, 10, 8, 1, 3, 2));
}
