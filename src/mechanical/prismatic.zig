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

/// Which outside wall an axis-aligned rectangular opening pierces.
pub const Wall = enum { front, back, left, right };

/// Rectangular wall opening. `center` is measured along the selected wall
/// from the enclosure centre; `bottom` and `height` are absolute Z values.
pub const WallCutout = struct {
    wall: Wall,
    center: f64,
    width: f64,
    bottom: f64,
    height: f64,
};

/// Dimensions of an open-top rectangular shell.
pub const ShellSpec = struct {
    inner_width: f64,
    inner_depth: f64,
    wall: f64,
    floor: f64,
    height: f64,
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

fn appendUnique(values: *std.ArrayList(f64), allocator: std.mem.Allocator, value: f64) std.mem.Allocator.Error!void {
    for (values.items) |existing| if (@abs(existing - value) < 1e-9) return;
    try values.append(allocator, value);
}

fn gridPointIndex(ix: usize, iy: usize, iz: usize, ny: usize, nz: usize) usize {
    return (ix * ny + iy) * nz + iz;
}

fn cellIndex(ix: usize, iy: usize, iz: usize, cy: usize, cz: usize) usize {
    return (ix * cy + iy) * cz + iz;
}

fn appendQuad(triangles: *std.ArrayList(Triangle), allocator: std.mem.Allocator, quad: [4]usize) std.mem.Allocator.Error!void {
    try triangles.append(allocator, .{ quad[0], quad[1], quad[2] });
    try triangles.append(allocator, .{ quad[0], quad[2], quad[3] });
}

const ShellBounds = struct { ix: f64, iy: f64, ox: f64, oy: f64 };
const GridAxes = struct { xs: []const f64, ys: []const f64, zs: []const f64 };

fn cutoutContains(cutout: WallCutout, point: Point3, bounds: ShellBounds) bool {
    const x = point[0];
    const y = point[1];
    const z = point[2];
    if (z < cutout.bottom or z > cutout.bottom + cutout.height) return false;
    const half = cutout.width / 2;
    return switch (cutout.wall) {
        .front => x >= cutout.center - half and x <= cutout.center + half and y >= -bounds.oy and y <= -bounds.iy,
        .back => x >= cutout.center - half and x <= cutout.center + half and y >= bounds.iy and y <= bounds.oy,
        .left => y >= cutout.center - half and y <= cutout.center + half and x >= -bounds.ox and x <= -bounds.ix,
        .right => y >= cutout.center - half and y <= cutout.center + half and x >= bounds.ix and x <= bounds.ox,
    };
}

fn gridPoints(allocator: std.mem.Allocator, xs: []const f64, ys: []const f64, zs: []const f64) ![]Point3 {
    const points = try allocator.alloc(Point3, xs.len * ys.len * zs.len);
    for (xs, 0..) |x, x_index| for (ys, 0..) |y, y_index| for (zs, 0..) |z, z_index| {
        points[gridPointIndex(x_index, y_index, z_index, ys.len, zs.len)] = .{ x, y, z };
    };
    return points;
}

fn classifiedCells(
    allocator: std.mem.Allocator,
    axes: GridAxes,
    spec: ShellSpec,
    bounds: ShellBounds,
    cutouts: []const WallCutout,
) ![]bool {
    const xs = axes.xs;
    const ys = axes.ys;
    const zs = axes.zs;
    const cx = xs.len - 1;
    const cy = ys.len - 1;
    const cz = zs.len - 1;
    const solid = try allocator.alloc(bool, cx * cy * cz);
    for (0..cx) |x_index| for (0..cy) |y_index| for (0..cz) |z_index| {
        const x = (xs[x_index] + xs[x_index + 1]) / 2;
        const y = (ys[y_index] + ys[y_index + 1]) / 2;
        const z = (zs[z_index] + zs[z_index + 1]) / 2;
        var occupied = z < spec.floor or @abs(x) >= bounds.ix or @abs(y) >= bounds.iy;
        if (occupied and z >= spec.floor) for (cutouts) |cutout| {
            if (cutoutContains(cutout, .{ x, y, z }, bounds)) {
                occupied = false;
                break;
            }
        };
        solid[cellIndex(x_index, y_index, z_index, cy, cz)] = occupied;
    };
    return solid;
}

fn boundaryTriangles(allocator: std.mem.Allocator, nx: usize, ny: usize, nz: usize, solid: []const bool) ![]Triangle {
    const cx = nx - 1;
    const cy = ny - 1;
    const cz = nz - 1;
    var triangles: std.ArrayList(Triangle) = .empty;
    errdefer triangles.deinit(allocator);
    for (0..cx) |x_index| for (0..cy) |y_index| for (0..cz) |z_index| {
        if (!solid[cellIndex(x_index, y_index, z_index, cy, cz)]) continue;
        const p000 = gridPointIndex(x_index, y_index, z_index, ny, nz);
        const p001 = gridPointIndex(x_index, y_index, z_index + 1, ny, nz);
        const p010 = gridPointIndex(x_index, y_index + 1, z_index, ny, nz);
        const p011 = gridPointIndex(x_index, y_index + 1, z_index + 1, ny, nz);
        const p100 = gridPointIndex(x_index + 1, y_index, z_index, ny, nz);
        const p101 = gridPointIndex(x_index + 1, y_index, z_index + 1, ny, nz);
        const p110 = gridPointIndex(x_index + 1, y_index + 1, z_index, ny, nz);
        const p111 = gridPointIndex(x_index + 1, y_index + 1, z_index + 1, ny, nz);
        if (x_index == 0 or !solid[cellIndex(x_index - 1, y_index, z_index, cy, cz)]) try appendQuad(&triangles, allocator, .{ p000, p001, p011, p010 });
        if (x_index + 1 == cx or !solid[cellIndex(x_index + 1, y_index, z_index, cy, cz)]) try appendQuad(&triangles, allocator, .{ p100, p110, p111, p101 });
        if (y_index == 0 or !solid[cellIndex(x_index, y_index - 1, z_index, cy, cz)]) try appendQuad(&triangles, allocator, .{ p000, p100, p101, p001 });
        if (y_index + 1 == cy or !solid[cellIndex(x_index, y_index + 1, z_index, cy, cz)]) try appendQuad(&triangles, allocator, .{ p010, p011, p111, p110 });
        if (z_index == 0 or !solid[cellIndex(x_index, y_index, z_index - 1, cy, cz)]) try appendQuad(&triangles, allocator, .{ p000, p010, p110, p100 });
        if (z_index + 1 == cz or !solid[cellIndex(x_index, y_index, z_index + 1, cy, cz)]) try appendQuad(&triangles, allocator, .{ p001, p101, p111, p011 });
    };
    return triangles.toOwnedSlice(allocator);
}

/// Build the same one-piece shell as `rectangularShell`, with true rectangular
/// tunnels through its walls. A shared XYZ grid classifies solid cells and
/// emits only their exposed faces, so intersecting/adjacent cutouts still
/// produce one indexed watertight boundary without a general-purpose CSG
/// dependency.
pub fn rectangularShellWithCutouts(
    allocator: std.mem.Allocator,
    spec: ShellSpec,
    cutouts: []const WallCutout,
) (KernelError || std.mem.Allocator.Error)!Mesh {
    if (cutouts.len == 0) return rectangularShell(allocator, spec.inner_width, spec.inner_depth, spec.wall, spec.floor, spec.height);
    const primary_valid = finitePositive(spec.inner_width) and finitePositive(spec.inner_depth);
    const construction_valid = finitePositive(spec.wall) and finitePositive(spec.floor) and finitePositive(spec.height);
    if (!primary_valid or !construction_valid) return error.InvalidDimensions;
    if (spec.floor >= spec.height) return error.InvalidDimensions;

    const ix = spec.inner_width / 2;
    const iy = spec.inner_depth / 2;
    const ox = ix + spec.wall;
    const oy = iy + spec.wall;
    const bounds = ShellBounds{ .ix = ix, .iy = iy, .ox = ox, .oy = oy };
    var xs: std.ArrayList(f64) = .empty;
    defer xs.deinit(allocator);
    var ys: std.ArrayList(f64) = .empty;
    defer ys.deinit(allocator);
    var zs: std.ArrayList(f64) = .empty;
    defer zs.deinit(allocator);
    for ([_]f64{ -ox, -ix, ix, ox }) |value| try appendUnique(&xs, allocator, value);
    for ([_]f64{ -oy, -iy, iy, oy }) |value| try appendUnique(&ys, allocator, value);
    for ([_]f64{ 0, spec.floor, spec.height }) |value| try appendUnique(&zs, allocator, value);
    for (cutouts) |cutout| {
        const finite = std.math.isFinite(cutout.center) and finitePositive(cutout.width) and
            std.math.isFinite(cutout.bottom) and finitePositive(cutout.height);
        if (!finite) return error.InvalidDimensions;
        if (cutout.bottom < spec.floor or cutout.bottom + cutout.height > spec.height) return error.InvalidDimensions;
        const half = cutout.width / 2;
        switch (cutout.wall) {
            .front, .back => {
                if (cutout.center - half < -ix or cutout.center + half > ix) return error.InvalidDimensions;
                try appendUnique(&xs, allocator, cutout.center - half);
                try appendUnique(&xs, allocator, cutout.center + half);
            },
            .left, .right => {
                if (cutout.center - half < -iy or cutout.center + half > iy) return error.InvalidDimensions;
                try appendUnique(&ys, allocator, cutout.center - half);
                try appendUnique(&ys, allocator, cutout.center + half);
            },
        }
        try appendUnique(&zs, allocator, cutout.bottom);
        try appendUnique(&zs, allocator, cutout.bottom + cutout.height);
    }
    std.mem.sort(f64, xs.items, {}, std.sort.asc(f64));
    std.mem.sort(f64, ys.items, {}, std.sort.asc(f64));
    std.mem.sort(f64, zs.items, {}, std.sort.asc(f64));

    const points = try gridPoints(allocator, xs.items, ys.items, zs.items);
    errdefer allocator.free(points);
    const solid = try classifiedCells(allocator, .{ .xs = xs.items, .ys = ys.items, .zs = zs.items }, spec, bounds, cutouts);
    defer allocator.free(solid);
    return .{ .points = points, .triangles = try boundaryTriangles(allocator, xs.items.len, ys.items.len, zs.items.len, solid) };
}

/// Build a vertical annular cylinder for a screw boss or spacer.
pub fn annularCylinder(
    allocator: std.mem.Allocator,
    outer_diameter: f64,
    hole_diameter: f64,
    z_min: f64,
    z_max: f64,
    segments: usize,
) (KernelError || std.mem.Allocator.Error)!Mesh {
    if (!finitePositive(outer_diameter) or !finitePositive(hole_diameter)) return error.InvalidDimensions;
    if (hole_diameter >= outer_diameter) return error.InvalidDimensions;
    if (!std.math.isFinite(z_min) or !std.math.isFinite(z_max)) return error.InvalidDimensions;
    if (z_max <= z_min) return error.InvalidDimensions;
    if (segments < 8 or segments > 256) return error.InvalidDimensions;
    const points = try allocator.alloc(Point3, segments * 4);
    errdefer allocator.free(points);
    const outer_radius = outer_diameter / 2;
    const inner_radius = hole_diameter / 2;
    for (0..segments) |index| {
        const angle = 2 * std.math.pi * @as(f64, @floatFromInt(index)) / @as(f64, @floatFromInt(segments));
        const c = @cos(angle);
        const s = @sin(angle);
        points[index] = .{ outer_radius * c, outer_radius * s, z_min };
        points[segments + index] = .{ outer_radius * c, outer_radius * s, z_max };
        points[2 * segments + index] = .{ inner_radius * c, inner_radius * s, z_min };
        points[3 * segments + index] = .{ inner_radius * c, inner_radius * s, z_max };
    }
    var triangles: std.ArrayList(Triangle) = .empty;
    errdefer triangles.deinit(allocator);
    try triangles.ensureTotalCapacity(allocator, segments * 8);
    for (0..segments) |index| {
        const next = (index + 1) % segments;
        try appendQuad(&triangles, allocator, .{ index, next, segments + next, segments + index });
        try appendQuad(&triangles, allocator, .{ 2 * segments + index, 3 * segments + index, 3 * segments + next, 2 * segments + next });
        try appendQuad(&triangles, allocator, .{ segments + index, segments + next, 3 * segments + next, 3 * segments + index });
        try appendQuad(&triangles, allocator, .{ index, 2 * segments + index, 2 * segments + next, next });
    }
    return .{ .points = points, .triangles = try triangles.toOwnedSlice(allocator) };
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

test "rectangular wall cutouts preserve one watertight shell boundary" {
    const cutouts = [_]WallCutout{
        .{ .wall = .front, .center = -1, .width = 4, .bottom = 2, .height = 3 },
        .{ .wall = .right, .center = 1, .width = 2, .bottom = 3, .height = 2 },
    };
    const mesh = try rectangularShellWithCutouts(std.testing.allocator, .{ .inner_width = 12, .inner_depth = 10, .wall = 2, .floor = 1, .height = 8 }, &cutouts);
    defer mesh.deinit(std.testing.allocator);
    try std.testing.expect(mesh.triangles.len > 28);
    try std.testing.expect(signedVolume(mesh) > 0);
    try std.testing.expect(try hasPairedDirectedEdges(std.testing.allocator, mesh));
}

test "annular cylinder is an outward watertight screw boss" {
    const mesh = try annularCylinder(std.testing.allocator, 6, 2.8, 2, 7, 24);
    defer mesh.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 96), mesh.points.len);
    try std.testing.expectEqual(@as(usize, 192), mesh.triangles.len);
    // The mesh is a 24-sided annular prism, so compare against the exact
    // polygonal volume rather than the ideal circular-cylinder volume.
    const sides: f64 = 24;
    const expected = 0.5 * sides * @sin(2 * std.math.pi / sides) * (9 - 1.96) * 5;
    try std.testing.expectApproxEqAbs(expected, signedVolume(mesh), 0.0001);
    try std.testing.expect(try hasPairedDirectedEdges(std.testing.allocator, mesh));
}
