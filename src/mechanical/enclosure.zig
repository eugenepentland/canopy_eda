//! Semantic two-piece electronics enclosure generator.
//!
//! This layer owns enclosure intent (clearance, wall/floor/height, lid), while
//! `prismatic.zig` owns topology. PCB/system code supplies only the occupied
//! XY envelope, keeping the mechanical kernel independent of the EDA model.

const std = @import("std");
const prismatic = @import("prismatic.zig");

/// User-facing enclosure intent in millimetres.
pub const Parameters = struct {
    occupied_width: f64,
    occupied_depth: f64,
    clearance: f64 = 2,
    wall: f64 = 2.4,
    floor: f64 = 2,
    height: f64 = 24,
    lid_thickness: f64 = 2.4,
};

/// One blind screw boss rising from the inside floor.
pub const Boss = struct {
    x: f64,
    y: f64,
    outer_diameter: f64 = 6,
    hole_diameter: f64 = 2.8,
    height: f64 = 3,
};

/// Optional constructive details applied to a basic enclosure.
pub const Features = struct {
    cutouts: []const prismatic.WallCutout = &.{},
    bosses: []const Boss = &.{},
};

/// Derived clear and exterior dimensions.
pub const Dimensions = struct {
    inner_width: f64,
    inner_depth: f64,
    outer_width: f64,
    outer_depth: f64,
};

/// Owned printable base and lid meshes.
pub const Model = struct {
    dimensions: Dimensions,
    base: prismatic.Mesh,
    lid: prismatic.Mesh,
    bosses: []const prismatic.Mesh,

    /// Release the two generated solid meshes.
    pub fn deinit(self: Model, allocator: std.mem.Allocator) void {
        self.base.deinit(allocator);
        self.lid.deinit(allocator);
        for (self.bosses) |boss| boss.deinit(allocator);
        allocator.free(self.bosses);
    }
};

/// Invalid semantic input or lower-level topology failure.
pub const EnclosureError = prismatic.KernelError || error{InvalidParameters};

/// Resolve the interior and outside dimensions without allocating a mesh.
pub fn dimensions(parameters: Parameters) EnclosureError!Dimensions {
    inline for (.{ parameters.occupied_width, parameters.occupied_depth, parameters.clearance, parameters.wall, parameters.floor, parameters.height, parameters.lid_thickness }) |value| {
        if (!std.math.isFinite(value) or value <= 0 or value > 2000) return error.InvalidParameters;
    }
    if (parameters.floor >= parameters.height) return error.InvalidParameters;
    const inner_width = parameters.occupied_width + 2 * parameters.clearance;
    const inner_depth = parameters.occupied_depth + 2 * parameters.clearance;
    return .{
        .inner_width = inner_width,
        .inner_depth = inner_depth,
        .outer_width = inner_width + 2 * parameters.wall,
        .outer_depth = inner_depth + 2 * parameters.wall,
    };
}

fn validFeatures(parameters: Parameters, dims: Dimensions, features: Features) bool {
    if (features.cutouts.len > 32 or features.bosses.len > 64) return false;
    const ix = dims.inner_width / 2;
    const iy = dims.inner_depth / 2;
    for (features.bosses) |boss| {
        inline for (.{ boss.x, boss.y, boss.outer_diameter, boss.hole_diameter, boss.height }) |value| {
            if (!std.math.isFinite(value)) return false;
        }
        if (boss.outer_diameter <= 0 or boss.hole_diameter <= 0 or boss.hole_diameter >= boss.outer_diameter or boss.height <= 0) return false;
        if (@abs(boss.x) + boss.outer_diameter / 2 > ix or @abs(boss.y) + boss.outer_diameter / 2 > iy) return false;
        if (parameters.floor + boss.height > parameters.height) return false;
    }
    for (features.cutouts) |cutout| {
        inline for (.{ cutout.center, cutout.width, cutout.bottom, cutout.height }) |value| {
            if (!std.math.isFinite(value)) return false;
        }
        if (cutout.width <= 0 or cutout.height <= 0 or cutout.bottom < parameters.floor or cutout.bottom + cutout.height > parameters.height) return false;
        const span = switch (cutout.wall) {
            .front, .back => ix,
            .left, .right => iy,
        };
        if (@abs(cutout.center) + cutout.width / 2 > span) return false;
    }
    return true;
}

/// Validate a full enclosure recipe without allocating geometry.
pub fn validateParameters(parameters: Parameters, features: Features) EnclosureError!Dimensions {
    const dims = try dimensions(parameters);
    if (!validFeatures(parameters, dims, features)) return error.InvalidParameters;
    return dims;
}

fn positionedBoss(allocator: std.mem.Allocator, spec: Boss, floor: f64) !prismatic.Mesh {
    const centered = try prismatic.annularCylinder(
        allocator,
        spec.outer_diameter,
        spec.hole_diameter,
        floor,
        floor + spec.height,
        32,
    );
    errdefer centered.deinit(allocator);
    if (spec.x == 0 and spec.y == 0) return centered;
    const points = try allocator.alloc(prismatic.Point3, centered.points.len);
    errdefer allocator.free(points);
    for (centered.points, points) |point, *out| out.* = .{ point[0] + spec.x, point[1] + spec.y, point[2] };
    allocator.free(centered.points);
    return .{ .points = points, .triangles = centered.triangles };
}

/// Generate a printable open base and closed slab lid.
pub fn generateWithFeatures(allocator: std.mem.Allocator, parameters: Parameters, features: Features) (EnclosureError || std.mem.Allocator.Error)!Model {
    const dims = try validateParameters(parameters, features);
    const base = try prismatic.rectangularShellWithCutouts(
        allocator,
        .{
            .inner_width = dims.inner_width,
            .inner_depth = dims.inner_depth,
            .wall = parameters.wall,
            .floor = parameters.floor,
            .height = parameters.height,
        },
        features.cutouts,
    );
    errdefer base.deinit(allocator);
    const lid = try prismatic.box(
        allocator,
        dims.outer_width,
        dims.outer_depth,
        parameters.height,
        parameters.height + parameters.lid_thickness,
    );
    errdefer lid.deinit(allocator);
    const bosses = try allocator.alloc(prismatic.Mesh, features.bosses.len);
    errdefer allocator.free(bosses);
    var built: usize = 0;
    errdefer for (bosses[0..built]) |boss| boss.deinit(allocator);
    for (features.bosses, 0..) |boss, index| {
        bosses[index] = try positionedBoss(allocator, boss, parameters.floor);
        built += 1;
    }
    return .{ .dimensions = dims, .base = base, .lid = lid, .bosses = bosses };
}

/// Generate the basic enclosure without optional mechanical features.
pub fn generate(allocator: std.mem.Allocator, parameters: Parameters) (EnclosureError || std.mem.Allocator.Error)!Model {
    return generateWithFeatures(allocator, parameters, .{});
}

test "enclosure derives a printable base and mating lid from PCB occupancy" {
    const params: Parameters = .{ .occupied_width = 100, .occupied_depth = 60 };
    const model = try generate(std.testing.allocator, params);
    defer model.deinit(std.testing.allocator);
    try std.testing.expectApproxEqAbs(@as(f64, 104), model.dimensions.inner_width, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 108.8), model.dimensions.outer_width, 1e-9);
    try std.testing.expectEqual(@as(usize, 28), model.base.triangles.len);
    try std.testing.expectEqual(@as(usize, 12), model.lid.triangles.len);
    try std.testing.expectEqual(@as(usize, 0), model.bosses.len);
}

test "enclosure generates wall cutouts and positioned blind bosses" {
    const cutouts = [_]prismatic.WallCutout{.{ .wall = .front, .center = 0, .width = 12, .bottom = 4, .height = 8 }};
    const bosses = [_]Boss{
        .{ .x = -12, .y = -8, .outer_diameter = 6, .hole_diameter = 2.8, .height = 4 },
        .{ .x = 12, .y = 8, .outer_diameter = 6, .hole_diameter = 2.8, .height = 4 },
    };
    const model = try generateWithFeatures(
        std.testing.allocator,
        .{ .occupied_width = 50, .occupied_depth = 35 },
        .{ .cutouts = &cutouts, .bosses = &bosses },
    );
    defer model.deinit(std.testing.allocator);
    try std.testing.expect(model.base.triangles.len > 28);
    try std.testing.expectEqual(@as(usize, 2), model.bosses.len);
    try std.testing.expectApproxEqAbs(@as(f64, -9), model.bosses[0].points[0][0], 1e-9);
}
