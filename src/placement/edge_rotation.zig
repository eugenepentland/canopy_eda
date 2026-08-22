//! Default orientation for hardware docked to a physical board edge.

const std = @import("std");
const geometry = @import("geometry.zig");

fn rotate(x: f64, y: f64, rot: u16) [2]f64 {
    return switch (rot) {
        90 => .{ -y, x },
        180 => .{ -x, -y },
        270 => .{ y, -x },
        else => .{ x, y },
    };
}

/// True for a multi-pin plated-through row whose body may face either way
/// without violating an SMD launch direction.
pub fn isThroughRow(pads: []const geometry.Pad) bool {
    if (pads.len < 2) return false;
    for (pads) |pad| if (!pad.thru or pad.npth) return false;

    // A 2xN header, relay, or circular connector is not a row merely because
    // every land is plated through. Find the most separated pair, use it as
    // the prospective row axis, and require every remaining centre to lie on
    // that line. The axis must also be meaningfully horizontal or vertical:
    // quarter-turn docking cannot make a diagonal footprint run along an edge.
    var axis_a: usize = 0;
    var axis_b: usize = 0;
    var axis_sq: f64 = 0;
    for (pads, 0..) |a, i| {
        for (pads[i + 1 ..], i + 1..) |b, j| {
            const dx = b.x - a.x;
            const dy = b.y - a.y;
            const sq = dx * dx + dy * dy;
            if (sq > axis_sq) {
                axis_a = i;
                axis_b = j;
                axis_sq = sq;
            }
        }
    }
    if (axis_sq < 1e-12) return false;
    const dx = pads[axis_b].x - pads[axis_a].x;
    const dy = pads[axis_b].y - pads[axis_a].y;
    const major = @max(@abs(dx), @abs(dy));
    const minor = @min(@abs(dx), @abs(dy));
    if (major < 4 * minor) return false;

    // Footprint coordinates are authored to micron-scale precision. Keep a
    // small tolerance for decimal conversion without admitting a second row.
    const length = @sqrt(axis_sq);
    const collinear_tolerance_mm: f64 = 0.01;
    for (pads) |pad| {
        const px = pad.x - pads[axis_a].x;
        const py = pad.y - pads[axis_a].y;
        const distance = @abs(px * dy - py * dx) / length;
        if (distance > collinear_tolerance_mm) return false;
    }
    return true;
}

/// Pick a quarter-turn for an edge index ordered left/right/top/bottom.
/// Multi-pad through-hole rows lie along the edge to preserve interior depth;
/// directional SMD connectors keep their pad centroid pointed inward.
pub fn choose(pads: []const geometry.Pad, hw: f64, hh: f64, edge: u2) f64 {
    if (pads.len == 0) return 0;
    var cx: f64 = 0;
    var cy: f64 = 0;
    for (pads) |pad| {
        cx += pad.x;
        cy += pad.y;
    }
    if (isThroughRow(pads)) {
        const vertical_edge = edge < 2;
        const already_shallow = if (vertical_edge) hw <= hh else hh <= hw;
        return if (already_shallow) 0 else 90;
    }
    cx /= @as(f64, @floatFromInt(pads.len));
    cy /= @as(f64, @floatFromInt(pads.len));
    if (cx * cx + cy * cy < 0.01) return 0;
    const inward = switch (edge) {
        0 => [2]f64{ 1, 0 },
        1 => [2]f64{ -1, 0 },
        2 => [2]f64{ 0, 1 },
        else => [2]f64{ 0, -1 },
    };
    var best_rot: f64 = 0;
    var best = -std.math.inf(f64);
    for ([_]u16{ 0, 90, 180, 270 }) |rot| {
        const offset = rotate(cx, cy, rot);
        const dot = offset[0] * inward[0] + offset[1] * inward[1];
        if (dot > best + 1e-9) {
            best = dot;
            best_rot = @floatFromInt(rot);
        }
    }
    return best_rot;
}

/// Flip a through-hole row 180° when that puts its signal-pad centroid closer
/// to the legalized attachment target along the board edge.
pub fn faceSignalsToward(
    pads: []const geometry.Pad,
    signal: [2]f64,
    vertical_edge: bool,
    target_delta: f64,
    base_rot: f64,
) f64 {
    if (!isThroughRow(pads) or @abs(target_delta) < 1e-9) return base_rot;
    var cx: f64 = 0;
    var cy: f64 = 0;
    for (pads) |pad| {
        cx += pad.x;
        cy += pad.y;
    }
    cx /= @as(f64, @floatFromInt(pads.len));
    cy /= @as(f64, @floatFromInt(pads.len));
    const quarter: u16 = if (base_rot == 90) 90 else if (base_rot == 180) 180 else if (base_rot == 270) 270 else 0;
    const offset = rotate(signal[0] - cx, signal[1] - cy, quarter);
    const along = if (vertical_edge) offset[1] else offset[0];
    return if (along * target_delta < 0) @mod(base_rot + 180, 360) else base_rot;
}

test "through-hole rows lie along an edge while SMD launches face inward" {
    const row = [_]geometry.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 1, .h = 1, .thru = true },
        .{ .number = "2", .x = 0, .y = 7.62, .w = 1, .h = 1, .thru = true },
    };
    try std.testing.expectEqual(@as(f64, 90), choose(&row, 1, 5, 3));
    try std.testing.expectEqual(@as(f64, 0), choose(&row, 1, 5, 0));
    const launch = [_]geometry.Pad{.{ .number = "1", .x = 0, .y = 1, .w = 1, .h = 1 }};
    try std.testing.expectEqual(@as(f64, 180), choose(&launch, 2, 3, 3));
    try std.testing.expectEqual(@as(f64, 90), faceSignalsToward(&row, .{ 0, 0 }, false, 2, 90));
    try std.testing.expectEqual(@as(f64, 270), faceSignalsToward(&row, .{ 0, 0 }, false, -2, 90));
}

test "nonlinear plated-through arrays retain centroid orientation" {
    const matrix = [_]geometry.Pad{
        .{ .number = "1", .x = 1, .y = 1, .w = 1, .h = 1, .thru = true },
        .{ .number = "2", .x = 3, .y = 1, .w = 1, .h = 1, .thru = true },
        .{ .number = "3", .x = 1, .y = 3, .w = 1, .h = 1, .thru = true },
        .{ .number = "4", .x = 3, .y = 3, .w = 1, .h = 1, .thru = true },
    };
    try std.testing.expect(!isThroughRow(&matrix));
    // The legacy centroid rule points this positively-offset array toward the
    // left-edge interior (+x), irrespective of its rectangular body aspect.
    try std.testing.expectEqual(@as(f64, 0), choose(&matrix, 5, 1, 0));

    const elbow = [_]geometry.Pad{
        .{ .number = "1", .x = 0, .y = 0, .w = 1, .h = 1, .thru = true },
        .{ .number = "2", .x = 0, .y = 2.54, .w = 1, .h = 1, .thru = true },
        .{ .number = "3", .x = 2.54, .y = 2.54, .w = 1, .h = 1, .thru = true },
    };
    try std.testing.expect(!isThroughRow(&elbow));
}
