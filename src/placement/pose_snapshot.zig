//! Generic placement-pose snapshots shared by optimizer candidate arbiters.

const std = @import("std");

/// Position and quarter-turn pose independent of optimizer part metadata.
pub const Pose = struct { x: f64, y: f64, rot: f64 };

/// Capture the pose fields of structurally compatible placement parts.
pub fn capture(comptime Part: type, arena: std.mem.Allocator, parts: []const Part) std.mem.Allocator.Error![]Pose {
    const out = try arena.alloc(Pose, parts.len);
    for (parts, out) |part, *pose| pose.* = .{ .x = part.x, .y = part.y, .rot = part.rot };
    return out;
}

/// Restore captured pose fields without changing part metadata or locks.
pub fn restore(comptime Part: type, parts: []Part, poses: []const Pose) void {
    for (parts, poses) |*part, pose| {
        part.x = pose.x;
        part.y = pose.y;
        part.rot = pose.rot;
    }
}

test "pose snapshots restore geometry without changing metadata" {
    const Part = struct { x: f64, y: f64, rot: f64, tag: u8 };
    var parts = [_]Part{.{ .x = 1, .y = 2, .rot = 90, .tag = 7 }};
    const saved = try capture(Part, std.testing.allocator, &parts);
    defer std.testing.allocator.free(saved);
    parts[0] = .{ .x = 9, .y = 8, .rot = 0, .tag = 3 };
    restore(Part, &parts, saved);
    try std.testing.expectEqual(@as(f64, 1), parts[0].x);
    try std.testing.expectEqual(@as(u8, 3), parts[0].tag);
}
