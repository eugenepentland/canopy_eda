//! Export-only PCB panel geometry.
//!
//! A panel never mutates the authored placement.  It supplies translated fab
//! frames for the repeated board artwork, a panel profile, and either V-score
//! guide strokes or tab-routed board profiles plus mouse-bite drills.

const std = @import("std");
const export_fab = @import("export_fab.zig");
const optimizer = @import("placement/optimizer.zig");

/// Fabrication process used to separate boards from the panel.
pub const Method = enum { v_score, routed };

/// Mouse-bite drill geometry for routed tabs.
pub const MouseBites = struct {
    diameter_mm: f64 = 0.5,
    pitch_mm: f64 = 0.6,
};

/// User-selectable panel layout and fabrication dimensions.
pub const Options = struct {
    rows: u8 = 2,
    columns: u8 = 2,
    method: Method = .routed,
    /// Board-to-board routing channel. V-score panels require zero gap.
    gap_mm: f64 = 2.0,
    /// Perimeter handling rail on all four sides.
    rail_mm: f64 = 5.0,
    /// Width of each un-routed break in a routed board profile.
    tab_mm: f64 = 3.0,
    mouse_bites: MouseBites = .{},
};

/// One straight fabrication drawing stroke in panel coordinates.
pub const Segment = struct { x1: f64, y1: f64, x2: f64, y2: f64 };
/// One non-plated mouse-bite hit in panel coordinates.
pub const Hole = struct { x: f64, y: f64, diameter: f64 };

/// Source-board facts needed by the export planner, detached from the solver.
pub const Source = struct {
    frame: export_fab.Frame,
    width_mm: f64,
    height_mm: f64,
    rectangular: bool,
};

/// Fully validated, arena-owned geometry consumed by CAM writers.
pub const Plan = struct {
    options: Options,
    frames: []const export_fab.Frame,
    profile: []const Segment,
    scores: []const Segment,
    mouse_bites: []const Hole,
    width_mm: f64,
    height_mm: f64,
};

/// Invalid user input or allocation failure while planning a panel.
pub const Error = std.mem.Allocator.Error || error{
    InvalidPanelCount,
    InvalidPanelDimension,
    VScoreRequiresZeroGap,
    SeparationRequiresRectangularBoard,
    RoutedGapTooSmall,
    InvalidRoutingTab,
    InvalidMouseBite,
};

/// Capture the small source-board view consumed by `plan`.
pub fn sourceFor(placement: optimizer.Placement) Source {
    const rect = export_fab.outlineRect(placement);
    return .{
        .frame = export_fab.frameFor(placement),
        .width_mm = rect.w,
        .height_mm = rect.h,
        .rectangular = rectangular(placement),
    };
}

/// Validate options and derive repeated frames plus separation artwork.
pub fn plan(arena: std.mem.Allocator, source: Source, options: Options) Error!Plan {
    if (options.rows == 0 or options.columns == 0) return error.InvalidPanelCount;
    if (@as(u16, options.rows) * @as(u16, options.columns) > 100) return error.InvalidPanelCount;
    if (!finiteNonNegative(options.rail_mm) or !finiteNonNegative(options.gap_mm))
        return error.InvalidPanelDimension;
    if (!source.rectangular) return error.SeparationRequiresRectangularBoard;
    if (options.method == .v_score and options.gap_mm != 0) return error.VScoreRequiresZeroGap;
    if (options.method == .routed and options.gap_mm < 1.0) return error.RoutedGapTooSmall;
    if (!std.math.isFinite(options.tab_mm) or options.tab_mm < 1.0)
        return error.InvalidRoutingTab;
    const bite = options.mouse_bites;
    if (!std.math.isFinite(bite.diameter_mm) or !std.math.isFinite(bite.pitch_mm)) return error.InvalidMouseBite;
    if (bite.diameter_mm < 0.2 or bite.diameter_mm > 1.0) return error.InvalidMouseBite;
    if (bite.pitch_mm < bite.diameter_mm) return error.InvalidMouseBite;
    if (bite.pitch_mm * 4 > options.tab_mm) return error.InvalidMouseBite;

    if (!(source.width_mm > 0 and source.height_mm > 0)) return error.InvalidPanelDimension;
    if (options.method == .routed and options.tab_mm >= @min(source.width_mm, source.height_mm))
        return error.InvalidRoutingTab;
    const cols: f64 = @floatFromInt(options.columns);
    const rows: f64 = @floatFromInt(options.rows);
    const width = 2 * options.rail_mm + cols * source.width_mm + (cols - 1) * options.gap_mm;
    const height = 2 * options.rail_mm + rows * source.height_mm + (rows - 1) * options.gap_mm;
    if (!std.math.isFinite(width) or !std.math.isFinite(height)) return error.InvalidPanelDimension;
    if (width <= 0 or height <= 0) return error.InvalidPanelDimension;
    if (width > 1000 or height > 1000) return error.InvalidPanelDimension;

    var frames: std.ArrayList(export_fab.Frame) = .empty;
    var row: u8 = 0;
    while (row < options.rows) : (row += 1) {
        var col: u8 = 0;
        while (col < options.columns) : (col += 1) {
            const dx = options.rail_mm + @as(f64, @floatFromInt(col)) * (source.width_mm + options.gap_mm);
            const dy = options.rail_mm + @as(f64, @floatFromInt(row)) * (source.height_mm + options.gap_mm);
            try frames.append(arena, .{ .ox = source.frame.ox - dx, .oy = source.frame.oy + dy });
        }
    }

    var profile: std.ArrayList(Segment) = .empty;
    try appendRect(&profile, arena, 0, 0, width, height);
    var scores: std.ArrayList(Segment) = .empty;
    var bites: std.ArrayList(Hole) = .empty;
    if (options.method == .v_score) {
        // Score every board boundary, including the board/rail boundaries.
        var c: u8 = 0;
        while (c <= options.columns) : (c += 1) {
            const x = options.rail_mm + @as(f64, @floatFromInt(c)) * source.width_mm;
            if (x > 0 and x < width) try scores.append(arena, .{ .x1 = x, .y1 = 0, .x2 = x, .y2 = height });
        }
        var r: u8 = 0;
        while (r <= options.rows) : (r += 1) {
            const y = options.rail_mm + @as(f64, @floatFromInt(r)) * source.height_mm;
            if (y > 0 and y < height) try scores.append(arena, .{ .x1 = 0, .y1 = y, .x2 = width, .y2 = y });
        }
    } else {
        row = 0;
        while (row < options.rows) : (row += 1) {
            var col: u8 = 0;
            while (col < options.columns) : (col += 1) {
                const x = options.rail_mm + @as(f64, @floatFromInt(col)) * (source.width_mm + options.gap_mm);
                const y = options.rail_mm + @as(f64, @floatFromInt(row)) * (source.height_mm + options.gap_mm);
                try appendTabbedRect(&profile, &bites, arena, .{ .x = x, .y = y, .w = source.width_mm, .h = source.height_mm }, options);
            }
        }
    }

    return .{
        .options = options,
        .frames = try frames.toOwnedSlice(arena),
        .profile = try profile.toOwnedSlice(arena),
        .scores = try scores.toOwnedSlice(arena),
        .mouse_bites = try bites.toOwnedSlice(arena),
        .width_mm = width,
        .height_mm = height,
    };
}

fn finiteNonNegative(value: f64) bool {
    return std.math.isFinite(value) and value >= 0;
}

fn rectangular(placement: optimizer.Placement) bool {
    if (placement.board_arcs.len != 0) return false;
    const poly = placement.board_poly orelse return true;
    if (poly.len != 4) return false;
    const r = export_fab.outlineRect(placement);
    var mask: u4 = 0;
    const corner_eps_mm = 0.000001;
    for (poly) |p| {
        const left = @abs(p[0] - r.minx) < corner_eps_mm;
        const right = @abs(p[0] - (r.minx + r.w)) < corner_eps_mm;
        const top = @abs(p[1] - r.miny) < corner_eps_mm;
        const bottom = @abs(p[1] - (r.miny + r.h)) < corner_eps_mm;
        const bit: u4 = if (left and top) 1 else if (right and top) 2 else if (right and bottom) 4 else if (left and bottom) 8 else return false;
        if (mask & bit != 0) return false;
        mask |= bit;
    }
    return mask == 15;
}

fn appendRect(out: *std.ArrayList(Segment), arena: std.mem.Allocator, x: f64, y: f64, w: f64, h: f64) !void {
    try out.appendSlice(arena, &.{
        .{ .x1 = x, .y1 = y, .x2 = x + w, .y2 = y },
        .{ .x1 = x + w, .y1 = y, .x2 = x + w, .y2 = y + h },
        .{ .x1 = x + w, .y1 = y + h, .x2 = x, .y2 = y + h },
        .{ .x1 = x, .y1 = y + h, .x2 = x, .y2 = y },
    });
}

fn appendTabbedRect(
    out: *std.ArrayList(Segment),
    bites: *std.ArrayList(Hole),
    arena: std.mem.Allocator,
    rect: Rect,
    options: Options,
) !void {
    // One centred bridge per side works for small boards as well as large
    // ones. Each profile break is paired with one NPTH mouse-bite row.
    const cx = rect.x + rect.w / 2;
    const cy = rect.y + rect.h / 2;
    const half = options.tab_mm / 2;
    try out.appendSlice(arena, &.{
        .{ .x1 = rect.x, .y1 = rect.y, .x2 = cx - half, .y2 = rect.y },
        .{ .x1 = cx + half, .y1 = rect.y, .x2 = rect.x + rect.w, .y2 = rect.y },
        .{ .x1 = rect.x, .y1 = rect.y + rect.h, .x2 = cx - half, .y2 = rect.y + rect.h },
        .{ .x1 = cx + half, .y1 = rect.y + rect.h, .x2 = rect.x + rect.w, .y2 = rect.y + rect.h },
        .{ .x1 = rect.x, .y1 = rect.y, .x2 = rect.x, .y2 = cy - half },
        .{ .x1 = rect.x, .y1 = cy + half, .x2 = rect.x, .y2 = rect.y + rect.h },
        .{ .x1 = rect.x + rect.w, .y1 = rect.y, .x2 = rect.x + rect.w, .y2 = cy - half },
        .{ .x1 = rect.x + rect.w, .y1 = cy + half, .x2 = rect.x + rect.w, .y2 = rect.y + rect.h },
    });
    try appendBites(bites, arena, cx, rect.y, true, options.mouse_bites);
    try appendBites(bites, arena, cx, rect.y + rect.h, true, options.mouse_bites);
    try appendBites(bites, arena, rect.x, cy, false, options.mouse_bites);
    try appendBites(bites, arena, rect.x + rect.w, cy, false, options.mouse_bites);
}

const Rect = struct { x: f64, y: f64, w: f64, h: f64 };

fn appendBites(out: *std.ArrayList(Hole), arena: std.mem.Allocator, cx: f64, cy: f64, horizontal: bool, options: MouseBites) !void {
    const count: usize = 5;
    const span = options.pitch_mm * @as(f64, @floatFromInt(count - 1));
    var i: usize = 0;
    while (i < count) : (i += 1) {
        const delta = @as(f64, @floatFromInt(i)) * options.pitch_mm - span / 2;
        try out.append(arena, .{
            .x = cx + if (horizontal) delta else 0,
            .y = cy + if (horizontal) 0 else delta,
            .diameter = options.diameter_mm,
        });
    }
}

fn testPlacement() optimizer.Placement {
    return .{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 20,
        .maxy = 10,
        .generated = false,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 20, .h = 10 },
    };
}

test "a routed panel repeats frames inside rails and creates tab mouse-bites" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const p = try plan(arena_state.allocator(), sourceFor(testPlacement()), .{ .rows = 2, .columns = 3 });
    try std.testing.expectEqual(@as(usize, 6), p.frames.len);
    try std.testing.expectApproxEqAbs(@as(f64, 74), p.width_mm, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 32), p.height_mm, 1e-9);
    try std.testing.expect(p.profile.len > 4);
    try std.testing.expectEqual(@as(usize, 6 * 4 * 5), p.mouse_bites.len);
}

test "a V-score panel has zero board gaps and full-span score guides" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const p = try plan(arena_state.allocator(), sourceFor(testPlacement()), .{ .rows = 2, .columns = 2, .method = .v_score, .gap_mm = 0 });
    try std.testing.expectApproxEqAbs(@as(f64, 50), p.width_mm, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 30), p.height_mm, 1e-9);
    try std.testing.expectEqual(@as(usize, 6), p.scores.len);
    try std.testing.expectEqual(@as(usize, 0), p.mouse_bites.len);
}

test "separation rejects a non-rectangular board and unsafe routing settings" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var placement = testPlacement();
    const l_shape = [_][2]f64{ .{ 0, 0 }, .{ 20, 0 }, .{ 20, 5 }, .{ 10, 5 }, .{ 10, 10 }, .{ 0, 10 } };
    placement.board_poly = &l_shape;
    try std.testing.expectError(error.SeparationRequiresRectangularBoard, plan(arena_state.allocator(), sourceFor(placement), .{}));
    try std.testing.expectError(error.RoutedGapTooSmall, plan(arena_state.allocator(), sourceFor(testPlacement()), .{ .gap_mm = 0.5 }));
    try std.testing.expectError(error.VScoreRequiresZeroGap, plan(arena_state.allocator(), sourceFor(testPlacement()), .{ .method = .v_score }));
}
