//! Coordinate-frame alignment when a saved board outline is folded onto a
//! freshly generated placement.

const std = @import("std");
const optimizer = @import("../placement/optimizer.zig");

/// Apply a saved board shape. Fresh poses are translated from the optimizer's
/// generated board frame into the saved frame; loaded poses remain verbatim.
pub fn apply(
    placement: *optimizer.Placement,
    rect: optimizer.BoardRect,
    poly: ?[]const [2]f64,
    arcs: []const optimizer.BoardArc,
) void {
    if (placement.generated) {
        const source_center: ?[2]f64 = if (placement.board_rect) |generated|
            .{ generated.minx + generated.w / 2, generated.miny + generated.h / 2 }
        else if (std.math.isFinite(placement.minx) and std.math.isFinite(placement.miny) and
            std.math.isFinite(placement.maxx) and std.math.isFinite(placement.maxy))
            .{ (placement.minx + placement.maxx) / 2, (placement.miny + placement.maxy) / 2 }
        else
            null;
        if (source_center) |source| {
            const dx = (rect.minx + rect.w / 2) - source[0];
            const dy = (rect.miny + rect.h / 2) - source[1];
            if (@abs(dx) > 1e-9 or @abs(dy) > 1e-9) {
                for (placement.parts) |*part| {
                    part.x += dx;
                    part.y += dy;
                }
                placement.minx += dx;
                placement.miny += dy;
                placement.maxx += dx;
                placement.maxy += dy;
            }
        }
    }
    placement.board_rect = rect;
    placement.board_poly = poly;
    placement.board_arcs = arcs;
}

fn fixture(parts: []optimizer.Part, generated: bool) optimizer.Placement {
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 4,
        .miny = 6,
        .maxx = 6,
        .maxy = 8,
        .generated = generated,
        .board_rect = .{ .minx = -10, .miny = 4, .w = 40, .h = 20 },
    };
}

test "saved outline aligns generated board coordinates but preserves loaded poses" {
    var parts = [_]optimizer.Part{.{
        .ref_des = "U1",
        .kind = .hub,
        .hw = 1,
        .hh = 1,
        .pads = &.{},
        .fallback = false,
        .x = 5,
        .y = 7,
    }};
    var fresh = fixture(&parts, true);
    apply(&fresh, .{ .minx = 0, .miny = 0, .w = 40, .h = 20 }, null, &.{});
    try std.testing.expectEqual(@as(f64, 15), fresh.parts[0].x);
    try std.testing.expectEqual(@as(f64, 3), fresh.parts[0].y);
    try std.testing.expectEqual(@as(f64, 14), fresh.minx);
    try std.testing.expectEqual(@as(f64, 4), fresh.maxy);

    var saved = fixture(&parts, false);
    saved.parts[0].x = 23;
    saved.parts[0].y = 11;
    apply(&saved, .{ .minx = 5, .miny = 6, .w = 40, .h = 20 }, null, &.{});
    try std.testing.expectEqual(@as(f64, 23), saved.parts[0].x);
    try std.testing.expectEqual(@as(f64, 11), saved.parts[0].y);
}

test "drawn-only outline aligns a fresh placement from its generated bounds" {
    var parts = [_]optimizer.Part{.{
        .ref_des = "U1",
        .kind = .hub,
        .hw = 1,
        .hh = 1,
        .pads = &.{},
        .fallback = false,
        .x = 5,
        .y = 7,
    }};
    var fresh = fixture(&parts, true);
    fresh.board_rect = null;
    apply(&fresh, .{ .minx = 0, .miny = 0, .w = 40, .h = 20 }, null, &.{});

    try std.testing.expectEqual(@as(f64, 20), fresh.parts[0].x);
    try std.testing.expectEqual(@as(f64, 10), fresh.parts[0].y);
    try std.testing.expectEqual(@as(f64, 19), fresh.minx);
    try std.testing.expectEqual(@as(f64, 9), fresh.miny);
    try std.testing.expectEqual(@as(f64, 21), fresh.maxx);
    try std.testing.expectEqual(@as(f64, 11), fresh.maxy);
}
