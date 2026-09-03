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

    /// Release the two generated solid meshes.
    pub fn deinit(self: Model, allocator: std.mem.Allocator) void {
        self.base.deinit(allocator);
        self.lid.deinit(allocator);
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

/// Generate a printable open base and closed slab lid.
pub fn generate(allocator: std.mem.Allocator, parameters: Parameters) (EnclosureError || std.mem.Allocator.Error)!Model {
    const dims = try dimensions(parameters);
    const base = try prismatic.rectangularShell(
        allocator,
        dims.inner_width,
        dims.inner_depth,
        parameters.wall,
        parameters.floor,
        parameters.height,
    );
    errdefer base.deinit(allocator);
    const lid = try prismatic.box(
        allocator,
        dims.outer_width,
        dims.outer_depth,
        parameters.height,
        parameters.height + parameters.lid_thickness,
    );
    return .{ .dimensions = dims, .base = base, .lid = lid };
}

test "enclosure derives a printable base and mating lid from PCB occupancy" {
    const params: Parameters = .{ .occupied_width = 100, .occupied_depth = 60 };
    const model = try generate(std.testing.allocator, params);
    defer model.deinit(std.testing.allocator);
    try std.testing.expectApproxEqAbs(@as(f64, 104), model.dimensions.inner_width, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 108.8), model.dimensions.outer_width, 1e-9);
    try std.testing.expectEqual(@as(usize, 28), model.base.triangles.len);
    try std.testing.expectEqual(@as(usize, 12), model.lid.triangles.len);
}
