//! Export-only PCB panel geometry.
//!
//! A panel never mutates the authored placement.  It supplies translated fab
//! frames for the repeated board artwork, a panel profile, and either V-score
//! guide strokes or tab-routed board profiles plus mouse-bite drills.

const std = @import("std");
const export_fab = @import("export_fab.zig");
const optimizer = @import("placement/optimizer.zig");
const outline = @import("placement/outline.zig");

/// Fabrication process used to separate boards from the panel.
pub const Method = enum { v_score, routed };

/// Mouse-bite drill geometry for routed tabs.
pub const MouseBites = struct {
    diameter_mm: f64 = 0.6,
    /// Centre pitch: JLCPCB's 0.35 mm recommended edge gap plus the hole.
    pitch_mm: f64 = 0.95,
};

/// One independently configurable panel rail. A zero width disables the rail;
/// selected tooling holes and fiducials are paired near both rail ends.
pub const RailSide = struct {
    width_mm: f64 = 5.0,
    tooling_hole: bool = false,
    fiducial: bool = false,
};

/// Per-side rails and the shared dimensions of their generated features.
pub const Rails = struct {
    top: RailSide = .{},
    right: RailSide = .{},
    bottom: RailSide = .{},
    left: RailSide = .{},
    tooling_diameter_mm: f64 = 2.0,
    fiducial_diameter_mm: f64 = 1.0,
    fiducial_mask_diameter_mm: f64 = 2.0,
};

/// User-selectable panel layout and fabrication dimensions.
pub const Options = struct {
    rows: u8 = 2,
    columns: u8 = 2,
    method: Method = .routed,
    /// Board-to-board routing channel. V-score panels require zero gap.
    gap_mm: f64 = 2.0,
    /// Independently sized and populated perimeter handling rails.
    rails: Rails = .{},
    /// Width of each un-routed break in a routed board profile.
    tab_mm: f64 = 5.0,
    mouse_bites: MouseBites = .{},
};

/// One fabrication drawing stroke in panel coordinates. A midpoint makes the
/// stroke a native circular arc; null keeps the usual straight segment.
pub const Segment = struct {
    x1: f64,
    y1: f64,
    x2: f64,
    y2: f64,
    midpoint: ?[2]f64 = null,
};
/// One non-plated mouse-bite hit in panel coordinates.
pub const Hole = struct { x: f64, y: f64, diameter: f64 };
/// One bare-copper global fiducial centre in panel coordinates.
pub const Fiducial = struct { x: f64, y: f64 };

/// Panel-only geometry added outside the repeated source-board artwork.
pub const Features = struct {
    npth_holes: []const Hole,
    fiducials: []const Fiducial,
};

/// Source-board facts needed by the export planner, detached from the solver.
pub const Source = struct {
    frame: export_fab.Frame,
    width_mm: f64,
    height_mm: f64,
    /// True for a square- or rounded-corner axis-aligned rectangle.
    rectangular: bool,
    /// Exact common corner radius; zero means square corners.
    corner_radius_mm: f64,
    /// Effective finished thickness and copper-edge rule used for JLCPCB DFM.
    board_thickness_mm: f64 = 1.6,
    copper_edge_clearance_mm: f64 = 0.4,
};

/// Fully validated, arena-owned geometry consumed by CAM writers.
pub const Plan = struct {
    options: Options,
    frames: []const export_fab.Frame,
    profile: []const Segment,
    scores: []const Segment,
    features: Features,
    width_mm: f64,
    height_mm: f64,
};

/// Invalid user input or allocation failure while planning a panel.
pub const Error = std.mem.Allocator.Error || error{
    InvalidPanelCount,
    InvalidPanelDimension,
    BoardTooSmall,
    PanelTooLarge,
    VScoreRequiresZeroGap,
    VScoreRequiresSquareCorners,
    VScorePanelTooSmall,
    VScoreLineLimit,
    VScoreBoardTooThin,
    VScoreCopperClearanceTooSmall,
    SeparationRequiresRectangularBoard,
    RoutedGapTooSmall,
    RoutedCopperClearanceTooSmall,
    InvalidRoutingTab,
    InvalidMouseBite,
    InvalidRailFeature,
};

/// Capture the small source-board view consumed by `plan`.
pub fn sourceFor(placement: optimizer.Placement) Source {
    const rect = export_fab.outlineRect(placement);
    const corner_radius = rectangleCornerRadius(placement);
    return .{
        .frame = export_fab.frameFor(placement),
        .width_mm = rect.w,
        .height_mm = rect.h,
        .rectangular = corner_radius != null,
        .corner_radius_mm = corner_radius orelse 0,
        .board_thickness_mm = boardThicknessMm(placement),
        .copper_edge_clearance_mm = placement.rules.design.edgeClearance(),
    };
}

fn boardThicknessMm(placement: optimizer.Placement) f64 {
    if (placement.rules.physical.board_thickness > 0) return placement.rules.physical.board_thickness;
    if (placement.rules.physical.stack.board_mm > 0) return placement.rules.physical.stack.board_mm;
    return 1.6;
}

/// Validate options and derive repeated frames plus separation artwork.
pub fn plan(arena: std.mem.Allocator, source: Source, options: Options) Error!Plan {
    if (options.rows == 0 or options.columns == 0) return error.InvalidPanelCount;
    if (@as(u16, options.rows) * @as(u16, options.columns) > 100) return error.InvalidPanelCount;
    if (!finiteNonNegative(options.gap_mm)) return error.InvalidPanelDimension;
    try validateRails(options.rails);
    try validateSeparation(source, options);
    try validateRoutedFeatures(options);

    if (!(source.width_mm > 0 and source.height_mm > 0)) return error.InvalidPanelDimension;
    if (!std.math.isFinite(source.board_thickness_mm) or !(source.board_thickness_mm > 0)) return error.InvalidPanelDimension;
    if (!std.math.isFinite(source.copper_edge_clearance_mm) or source.copper_edge_clearance_mm < 0) return error.InvalidPanelDimension;
    const minimum_board_mm: f64 = if (source.board_thickness_mm < 0.8) 5 else 3;
    if (source.width_mm < minimum_board_mm or source.height_mm < minimum_board_mm) return error.BoardTooSmall;
    const shortest_straight = @min(source.width_mm, source.height_mm) - 2 * source.corner_radius_mm;
    if (options.method == .routed and options.tab_mm >= shortest_straight)
        return error.InvalidRoutingTab;
    const cols: f64 = @floatFromInt(options.columns);
    const rows: f64 = @floatFromInt(options.rows);
    const rails = options.rails;
    const width = rails.left.width_mm + rails.right.width_mm + cols * source.width_mm + (cols - 1) * options.gap_mm;
    const height = rails.bottom.width_mm + rails.top.width_mm + rows * source.height_mm + (rows - 1) * options.gap_mm;
    if (!std.math.isFinite(width) or !std.math.isFinite(height)) return error.InvalidPanelDimension;
    if (width <= 0 or height <= 0) return error.InvalidPanelDimension;
    if (width > 475 or height > 475) return error.PanelTooLarge;
    try validateJlcpcbProcess(source, options, width, height);
    try validateRailFeatureSpan(rails, width, height);

    var frames: std.ArrayList(export_fab.Frame) = .empty;
    var row: u8 = 0;
    while (row < options.rows) : (row += 1) {
        var col: u8 = 0;
        while (col < options.columns) : (col += 1) {
            const dx = rails.left.width_mm + @as(f64, @floatFromInt(col)) * (source.width_mm + options.gap_mm);
            const dy = rails.bottom.width_mm + @as(f64, @floatFromInt(row)) * (source.height_mm + options.gap_mm);
            try frames.append(arena, .{ .ox = source.frame.ox - dx, .oy = source.frame.oy + dy });
        }
    }

    var profile: std.ArrayList(Segment) = .empty;
    try appendRect(&profile, arena, 0, 0, width, height);
    var scores: std.ArrayList(Segment) = .empty;
    var npth_holes: std.ArrayList(Hole) = .empty;
    var fiducials: std.ArrayList(Fiducial) = .empty;
    if (options.method == .v_score) {
        // Score every board boundary, including the board/rail boundaries.
        var c: u8 = 0;
        while (c <= options.columns) : (c += 1) {
            const x = rails.left.width_mm + @as(f64, @floatFromInt(c)) * source.width_mm;
            if (x > 0 and x < width) try scores.append(arena, .{ .x1 = x, .y1 = 0, .x2 = x, .y2 = height });
        }
        var r: u8 = 0;
        while (r <= options.rows) : (r += 1) {
            const y = rails.bottom.width_mm + @as(f64, @floatFromInt(r)) * source.height_mm;
            if (y > 0 and y < height) try scores.append(arena, .{ .x1 = 0, .y1 = y, .x2 = width, .y2 = y });
        }
    } else {
        row = 0;
        while (row < options.rows) : (row += 1) {
            var col: u8 = 0;
            while (col < options.columns) : (col += 1) {
                const x = rails.left.width_mm + @as(f64, @floatFromInt(col)) * (source.width_mm + options.gap_mm);
                const y = rails.bottom.width_mm + @as(f64, @floatFromInt(row)) * (source.height_mm + options.gap_mm);
                try appendTabbedRect(&profile, &npth_holes, arena, .{ .x = x, .y = y, .w = source.width_mm, .h = source.height_mm }, source.corner_radius_mm, options);
            }
        }
    }
    try appendRailFeatures(&npth_holes, &fiducials, arena, rails, width, height);

    return .{
        .options = options,
        .frames = try frames.toOwnedSlice(arena),
        .profile = try profile.toOwnedSlice(arena),
        .scores = try scores.toOwnedSlice(arena),
        .features = .{
            .npth_holes = try npth_holes.toOwnedSlice(arena),
            .fiducials = try fiducials.toOwnedSlice(arena),
        },
        .width_mm = width,
        .height_mm = height,
    };
}

fn finiteNonNegative(value: f64) bool {
    return std.math.isFinite(value) and value >= 0;
}

fn validateRoutedFeatures(options: Options) Error!void {
    if (options.method != .routed) return;
    if (!std.math.isFinite(options.tab_mm) or options.tab_mm < 5.0) return error.InvalidRoutingTab;
    const bite = options.mouse_bites;
    if (!std.math.isFinite(bite.diameter_mm) or !std.math.isFinite(bite.pitch_mm)) return error.InvalidMouseBite;
    if (bite.diameter_mm < 0.5 or bite.diameter_mm > 0.8) return error.InvalidMouseBite;
    const bite_edge_gap = bite.pitch_mm - bite.diameter_mm;
    if (bite_edge_gap < 0.3 or bite_edge_gap > 0.4) return error.InvalidMouseBite;
    if (bite.pitch_mm * 4 + bite.diameter_mm > options.tab_mm) return error.InvalidMouseBite;
}

const rail_feature_edge_clearance_mm = 0.5;
const rail_feature_spacing_mm = 1.0;
const jlcpcb_rail_width_mm = 5.0;
const jlcpcb_feature_edge_offset_mm = 3.85;

fn validateRails(rails: Rails) Error!void {
    const sides = [_]RailSide{ rails.top, rails.right, rails.bottom, rails.left };
    var has_tooling = false;
    var has_fiducial = false;
    for (sides) |side| {
        if (!finiteNonNegative(side.width_mm)) return error.InvalidPanelDimension;
        if (side.width_mm > 0 and side.width_mm < jlcpcb_rail_width_mm) return error.InvalidRailFeature;
        if ((side.tooling_hole or side.fiducial) and !(side.width_mm > 0)) return error.InvalidRailFeature;
        has_tooling = has_tooling or side.tooling_hole;
        has_fiducial = has_fiducial or side.fiducial;
        if (side.tooling_hole and side.width_mm < rails.tooling_diameter_mm + 2 * rail_feature_edge_clearance_mm)
            return error.InvalidRailFeature;
        if (side.fiducial and side.width_mm < rails.fiducial_mask_diameter_mm + 2 * rail_feature_edge_clearance_mm)
            return error.InvalidRailFeature;
    }
    if (!std.math.isFinite(rails.tooling_diameter_mm) or rails.tooling_diameter_mm < 1 or rails.tooling_diameter_mm > 6)
        return error.InvalidRailFeature;
    if (!std.math.isFinite(rails.fiducial_diameter_mm) or rails.fiducial_diameter_mm < 0.5 or rails.fiducial_diameter_mm > 3)
        return error.InvalidRailFeature;
    if (!std.math.isFinite(rails.fiducial_mask_diameter_mm) or rails.fiducial_mask_diameter_mm < 2 * rails.fiducial_diameter_mm or rails.fiducial_mask_diameter_mm > 5)
        return error.InvalidRailFeature;
    if (has_tooling and rails.tooling_diameter_mm != 2) return error.InvalidRailFeature;
    if (has_fiducial and (rails.fiducial_diameter_mm != 1 or rails.fiducial_mask_diameter_mm != 2)) return error.InvalidRailFeature;
}

fn validateRailFeatureSpan(rails: Rails, width: f64, height: f64) Error!void {
    try validateSideSpan(rails.top, width, rails);
    try validateSideSpan(rails.bottom, width, rails);
    try validateSideSpan(rails.left, height, rails);
    try validateSideSpan(rails.right, height, rails);
}

fn validateSideSpan(side: RailSide, span: f64, rails: Rails) Error!void {
    const slot = span / 8;
    if (side.tooling_hole and slot < @max(jlcpcb_feature_edge_offset_mm, rails.tooling_diameter_mm / 2 + rail_feature_edge_clearance_mm))
        return error.InvalidRailFeature;
    if (side.fiducial and 2 * slot < @max(jlcpcb_feature_edge_offset_mm, rails.fiducial_mask_diameter_mm / 2 + rail_feature_edge_clearance_mm))
        return error.InvalidRailFeature;
    if (side.tooling_hole and side.fiducial and slot < (rails.tooling_diameter_mm + rails.fiducial_mask_diameter_mm) / 2 + rail_feature_spacing_mm)
        return error.InvalidRailFeature;
}

fn validateSeparation(source: Source, options: Options) Error!void {
    if (!source.rectangular) return error.SeparationRequiresRectangularBoard;
    if (options.method == .v_score and options.gap_mm != 0) return error.VScoreRequiresZeroGap;
    if (options.method == .v_score and source.corner_radius_mm > 0) return error.VScoreRequiresSquareCorners;
    if (options.method == .routed and options.gap_mm < 1.2) return error.RoutedGapTooSmall;
}

fn validateJlcpcbProcess(source: Source, options: Options, width: f64, height: f64) Error!void {
    switch (options.method) {
        .v_score => {
            if (width < 70 or height < 70) return error.VScorePanelTooSmall;
            if (source.board_thickness_mm < 0.6) return error.VScoreBoardTooThin;
            if (source.copper_edge_clearance_mm < 0.4) return error.VScoreCopperClearanceTooSmall;
            const vertical_lines = @as(u16, options.columns - 1) + @intFromBool(options.rails.left.width_mm > 0) + @intFromBool(options.rails.right.width_mm > 0);
            const horizontal_lines = @as(u16, options.rows - 1) + @intFromBool(options.rails.bottom.width_mm > 0) + @intFromBool(options.rails.top.width_mm > 0);
            if (vertical_lines > 25 or horizontal_lines > 25) return error.VScoreLineLimit;
        },
        .routed => if (source.copper_edge_clearance_mm < 0.2) return error.RoutedCopperClearanceTooSmall,
    }
}

/// Return the common radius for a square/rounded axis-aligned rectangle, or
/// null for every other outline. Rounded rectangles are recognized from their
/// exact native quarter arcs rather than the tessellated fallback polygon.
fn rectangleCornerRadius(placement: optimizer.Placement) ?f64 {
    if (placement.board_arcs.len == 0) return if (squareRectangle(placement)) 0 else null;
    if (placement.board_arcs.len != 4 or placement.board_poly == null) return null;
    const r = export_fab.outlineRect(placement);
    const eps_mm = 0.000001;
    const angle_eps = 0.000001;
    var radius: ?f64 = null;
    var mask: u4 = 0;
    for (placement.board_arcs) |arc| {
        const circle = outline.arcCircle(arc) orelse return null;
        if (!(circle.radius > eps_mm) or @abs(@abs(circle.sweep) - std.math.pi / 2.0) > angle_eps) return null;
        if (radius) |expected| {
            if (@abs(circle.radius - expected) > eps_mm) return null;
        } else {
            radius = circle.radius;
        }
        const left = @abs(circle.cx - (r.minx + circle.radius)) < eps_mm;
        const right = @abs(circle.cx - (r.minx + r.w - circle.radius)) < eps_mm;
        const top = @abs(circle.cy - (r.miny + circle.radius)) < eps_mm;
        const bottom = @abs(circle.cy - (r.miny + r.h - circle.radius)) < eps_mm;
        const bit: u4 = if (left and top) 1 else if (right and top) 2 else if (right and bottom) 4 else if (left and bottom) 8 else return null;
        if (mask & bit != 0) return null;
        mask |= bit;
    }
    return if (mask == 15) radius else null;
}

fn squareRectangle(placement: optimizer.Placement) bool {
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
    radius: f64,
    options: Options,
) !void {
    // One centred bridge per side works for small boards as well as large
    // ones. Each profile break is paired with one NPTH mouse-bite row.
    const cx = rect.x + rect.w / 2;
    const cy = rect.y + rect.h / 2;
    const half = options.tab_mm / 2;
    try out.appendSlice(arena, &.{
        .{ .x1 = rect.x + radius, .y1 = rect.y, .x2 = cx - half, .y2 = rect.y },
        .{ .x1 = cx + half, .y1 = rect.y, .x2 = rect.x + rect.w - radius, .y2 = rect.y },
        .{ .x1 = rect.x + radius, .y1 = rect.y + rect.h, .x2 = cx - half, .y2 = rect.y + rect.h },
        .{ .x1 = cx + half, .y1 = rect.y + rect.h, .x2 = rect.x + rect.w - radius, .y2 = rect.y + rect.h },
        .{ .x1 = rect.x, .y1 = rect.y + radius, .x2 = rect.x, .y2 = cy - half },
        .{ .x1 = rect.x, .y1 = cy + half, .x2 = rect.x, .y2 = rect.y + rect.h - radius },
        .{ .x1 = rect.x + rect.w, .y1 = rect.y + radius, .x2 = rect.x + rect.w, .y2 = cy - half },
        .{ .x1 = rect.x + rect.w, .y1 = cy + half, .x2 = rect.x + rect.w, .y2 = rect.y + rect.h - radius },
    });
    if (radius > 0) try appendRoundedCorners(out, arena, rect, radius);
    try appendBites(bites, arena, cx, rect.y, true, options.mouse_bites);
    try appendBites(bites, arena, cx, rect.y + rect.h, true, options.mouse_bites);
    try appendBites(bites, arena, rect.x, cy, false, options.mouse_bites);
    try appendBites(bites, arena, rect.x + rect.w, cy, false, options.mouse_bites);
}

fn appendRoundedCorners(out: *std.ArrayList(Segment), arena: std.mem.Allocator, rect: Rect, radius: f64) !void {
    const diagonal = radius / std.math.sqrt(2.0);
    try out.appendSlice(arena, &.{
        .{ .x1 = rect.x + radius, .y1 = rect.y, .x2 = rect.x, .y2 = rect.y + radius, .midpoint = .{ rect.x + radius - diagonal, rect.y + radius - diagonal } },
        .{ .x1 = rect.x + rect.w, .y1 = rect.y + radius, .x2 = rect.x + rect.w - radius, .y2 = rect.y, .midpoint = .{ rect.x + rect.w - radius + diagonal, rect.y + radius - diagonal } },
        .{ .x1 = rect.x + rect.w - radius, .y1 = rect.y + rect.h, .x2 = rect.x + rect.w, .y2 = rect.y + rect.h - radius, .midpoint = .{ rect.x + rect.w - radius + diagonal, rect.y + rect.h - radius + diagonal } },
        .{ .x1 = rect.x, .y1 = rect.y + rect.h - radius, .x2 = rect.x + radius, .y2 = rect.y + rect.h, .midpoint = .{ rect.x + radius - diagonal, rect.y + rect.h - radius + diagonal } },
    });
}

const RailAnchors = struct {
    tooling: [2][2]f64,
    fiducial: [2][2]f64,
};

fn appendRailFeatures(
    holes: *std.ArrayList(Hole),
    fiducials: *std.ArrayList(Fiducial),
    arena: std.mem.Allocator,
    rails: Rails,
    width: f64,
    height: f64,
) !void {
    try appendRailSide(holes, fiducials, arena, rails.bottom, rails.tooling_diameter_mm, .{
        .tooling = .{ .{ width / 8, jlcpcb_feature_edge_offset_mm }, .{ 7 * width / 8, jlcpcb_feature_edge_offset_mm } },
        .fiducial = .{ .{ width / 4, jlcpcb_feature_edge_offset_mm }, .{ 3 * width / 4, jlcpcb_feature_edge_offset_mm } },
    });
    try appendRailSide(holes, fiducials, arena, rails.top, rails.tooling_diameter_mm, .{
        .tooling = .{ .{ width / 8, height - jlcpcb_feature_edge_offset_mm }, .{ 7 * width / 8, height - jlcpcb_feature_edge_offset_mm } },
        .fiducial = .{ .{ width / 4, height - jlcpcb_feature_edge_offset_mm }, .{ 3 * width / 4, height - jlcpcb_feature_edge_offset_mm } },
    });
    try appendRailSide(holes, fiducials, arena, rails.left, rails.tooling_diameter_mm, .{
        .tooling = .{ .{ jlcpcb_feature_edge_offset_mm, height / 8 }, .{ jlcpcb_feature_edge_offset_mm, 7 * height / 8 } },
        .fiducial = .{ .{ jlcpcb_feature_edge_offset_mm, height / 4 }, .{ jlcpcb_feature_edge_offset_mm, 3 * height / 4 } },
    });
    try appendRailSide(holes, fiducials, arena, rails.right, rails.tooling_diameter_mm, .{
        .tooling = .{ .{ width - jlcpcb_feature_edge_offset_mm, height / 8 }, .{ width - jlcpcb_feature_edge_offset_mm, 7 * height / 8 } },
        .fiducial = .{ .{ width - jlcpcb_feature_edge_offset_mm, height / 4 }, .{ width - jlcpcb_feature_edge_offset_mm, 3 * height / 4 } },
    });
}

fn appendRailSide(
    holes: *std.ArrayList(Hole),
    fiducials: *std.ArrayList(Fiducial),
    arena: std.mem.Allocator,
    side: RailSide,
    tooling_diameter_mm: f64,
    anchors: RailAnchors,
) !void {
    if (side.tooling_hole) for (anchors.tooling) |point| try holes.append(arena, .{
        .x = point[0],
        .y = point[1],
        .diameter = tooling_diameter_mm,
    });
    if (side.fiducial) for (anchors.fiducial) |point| try fiducials.append(arena, .{
        .x = point[0],
        .y = point[1],
    });
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

fn arcCount(profile: []const Segment) usize {
    var count: usize = 0;
    for (profile) |stroke| {
        if (stroke.midpoint != null) count += 1;
    }
    return count;
}

fn holeCountOfDiameter(holes: []const Hole, diameter: f64) usize {
    var count: usize = 0;
    for (holes) |hole| if (hole.diameter == diameter) {
        count += 1;
    };
    return count;
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
        .rules = .{ .design = .{ .edge = .{ .copper = 0.4, .component = 0.2 } } },
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
    try std.testing.expectEqual(@as(usize, 6 * 4 * 5), p.features.npth_holes.len);
}

test "a V-score panel has zero board gaps and full-span score guides" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const p = try plan(arena_state.allocator(), sourceFor(testPlacement()), .{ .rows = 6, .columns = 3, .method = .v_score, .gap_mm = 0 });
    try std.testing.expectApproxEqAbs(@as(f64, 70), p.width_mm, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 70), p.height_mm, 1e-9);
    try std.testing.expectEqual(@as(usize, 11), p.scores.len);
    try std.testing.expectEqual(@as(usize, 0), p.features.npth_holes.len);
}

test "asymmetric rails place paired tooling holes and fiducials only on selected sides" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const p = try plan(arena_state.allocator(), sourceFor(testPlacement()), .{
        .rows = 1,
        .columns = 2,
        .method = .routed,
        .gap_mm = 2,
        .rails = .{
            .top = .{ .width_mm = 5, .fiducial = true },
            .right = .{ .width_mm = 0 },
            .bottom = .{ .width_mm = 5, .tooling_hole = true },
            .left = .{ .width_mm = 0 },
        },
    });
    try std.testing.expectApproxEqAbs(@as(f64, 42), p.width_mm, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 20), p.height_mm, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 15), p.frames[0].oy, 1e-9);
    try std.testing.expectEqual(@as(usize, 2), holeCountOfDiameter(p.features.npth_holes, 2));
    const first_tooling = p.features.npth_holes[p.features.npth_holes.len - 2];
    const second_tooling = p.features.npth_holes[p.features.npth_holes.len - 1];
    try std.testing.expectApproxEqAbs(@as(f64, 3.85), first_tooling.y, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 5.25), first_tooling.x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 36.75), second_tooling.x, 1e-9);
    try std.testing.expectEqual(@as(usize, 2), p.features.fiducials.len);
    try std.testing.expectApproxEqAbs(@as(f64, 16.15), p.features.fiducials[0].y, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 10.5), p.features.fiducials[0].x, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 31.5), p.features.fiducials[1].x, 1e-9);
}

test "opposite rail selections create four or eight tooling holes and fiducials" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const horizontal = try plan(arena, sourceFor(testPlacement()), .{
        .rows = 1,
        .columns = 2,
        .method = .routed,
        .gap_mm = 2,
        .rails = .{
            .top = .{ .tooling_hole = true, .fiducial = true },
            .right = .{ .width_mm = 0 },
            .bottom = .{ .tooling_hole = true, .fiducial = true },
            .left = .{ .width_mm = 0 },
        },
    });
    try std.testing.expectEqual(@as(usize, 4), holeCountOfDiameter(horizontal.features.npth_holes, 2));
    try std.testing.expectEqual(@as(usize, 4), horizontal.features.fiducials.len);

    const all_sides = RailSide{ .tooling_hole = true, .fiducial = true };
    const all = try plan(arena, sourceFor(testPlacement()), .{
        .rows = 2,
        .columns = 2,
        .method = .routed,
        .gap_mm = 2,
        .rails = .{ .top = all_sides, .right = all_sides, .bottom = all_sides, .left = all_sides },
    });
    try std.testing.expectEqual(@as(usize, 8), holeCountOfDiameter(all.features.npth_holes, 2));
    try std.testing.expectEqual(@as(usize, 8), all.features.fiducials.len);
}

test "a routed rounded-rectangle panel retains native corner arcs" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var placement = testPlacement();
    const square = [_][2]f64{ .{ 0, 0 }, .{ 20, 0 }, .{ 20, 10 }, .{ 0, 10 } };
    const radii = [_]f64{ 2, 2, 2, 2 };
    const fillet = try outline.filletPath(arena, &square, &radii, 0.01);
    placement.board_poly = fillet.poly;
    placement.board_arcs = fillet.arcs;

    const source = sourceFor(placement);
    try std.testing.expect(source.rectangular);
    try std.testing.expectApproxEqAbs(@as(f64, 2), source.corner_radius_mm, 1e-9);
    const p = try plan(arena, source, .{ .rows = 1, .columns = 2 });
    try std.testing.expectEqual(@as(usize, 8), arcCount(p.profile));
    try std.testing.expectError(error.VScoreRequiresSquareCorners, plan(arena, source, .{ .method = .v_score, .gap_mm = 0 }));
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
    try std.testing.expectError(error.InvalidRailFeature, plan(arena_state.allocator(), sourceFor(testPlacement()), .{ .rails = .{ .top = .{ .width_mm = 2, .tooling_hole = true } } }));
}

// spec: export_gerber - JLCPCB-safe panel planning enforces rigid-FR4 board and panel sizes, routed copper/gap/tab/mouse-bite limits, V-score size/thickness/copper/line limits, 5 mm rails, 2 mm tooling holes, and 1 mm fiducials with 2 mm mask openings 3.85 mm from the panel edge
test "JLCPCB panel constraints reject out-of-capability fabrication geometry" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const base = Source{ .frame = .{ .ox = 0, .oy = 30 }, .width_mm = 30, .height_mm = 30, .rectangular = true, .corner_radius_mm = 0 };

    const compliant = try plan(arena, base, .{ .rows = 2, .columns = 2, .method = .v_score, .gap_mm = 0 });
    try std.testing.expectApproxEqAbs(@as(f64, 70), compliant.width_mm, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 70), compliant.height_mm, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2), compliant.options.rails.tooling_diameter_mm, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 1), compliant.options.rails.fiducial_diameter_mm, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2), compliant.options.rails.fiducial_mask_diameter_mm, 1e-9);

    var changed = base;
    changed.width_mm = 2.9;
    try std.testing.expectError(error.BoardTooSmall, plan(arena, changed, .{}));
    changed = base;
    changed.board_thickness_mm = 0.4;
    try std.testing.expectError(error.VScoreBoardTooThin, plan(arena, changed, .{ .rows = 2, .columns = 2, .method = .v_score, .gap_mm = 0 }));
    changed = base;
    changed.copper_edge_clearance_mm = 0.39;
    try std.testing.expectError(error.VScoreCopperClearanceTooSmall, plan(arena, changed, .{ .rows = 2, .columns = 2, .method = .v_score, .gap_mm = 0 }));
    changed.copper_edge_clearance_mm = 0.19;
    try std.testing.expectError(error.RoutedCopperClearanceTooSmall, plan(arena, changed, .{}));
    try std.testing.expectError(error.RoutedGapTooSmall, plan(arena, base, .{ .gap_mm = 1.19 }));
    try std.testing.expectError(error.InvalidRoutingTab, plan(arena, base, .{ .tab_mm = 4.9 }));
    try std.testing.expectError(error.InvalidMouseBite, plan(arena, base, .{ .mouse_bites = .{ .diameter_mm = 0.6, .pitch_mm = 0.89 } }));
    try std.testing.expectError(error.InvalidRailFeature, plan(arena, base, .{ .rails = .{ .top = .{ .width_mm = 4.9 } } }));
    try std.testing.expectError(error.InvalidRailFeature, plan(arena, base, .{ .rails = .{ .top = .{ .tooling_hole = true }, .tooling_diameter_mm = 3 } }));
    try std.testing.expectError(error.InvalidRailFeature, plan(arena, base, .{ .rails = .{ .top = .{ .fiducial = true }, .fiducial_diameter_mm = 1.2, .fiducial_mask_diameter_mm = 2.4 } }));
    try std.testing.expectError(error.VScorePanelTooSmall, plan(arena, base, .{ .rows = 1, .columns = 1, .method = .v_score, .gap_mm = 0 }));

    const tall = Source{ .frame = .{ .ox = 0, .oy = 70 }, .width_mm = 3, .height_mm = 70, .rectangular = true, .corner_radius_mm = 0 };
    const no_rails = Rails{ .top = .{ .width_mm = 0 }, .right = .{ .width_mm = 0 }, .bottom = .{ .width_mm = 0 }, .left = .{ .width_mm = 0 } };
    try std.testing.expectError(error.VScoreLineLimit, plan(arena, tall, .{ .rows = 1, .columns = 27, .method = .v_score, .gap_mm = 0, .rails = no_rails }));
    try std.testing.expectError(error.PanelTooLarge, plan(arena, base, .{ .rows = 1, .columns = 16 }));
}
