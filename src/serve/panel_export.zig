//! HTTP query adapter for export-only PCB panelization.

const std = @import("std");
const httpz = @import("httpz");
const panelize = @import("../panelize.zig");
const pcb_query = @import("pcb_query.zig");

fn number(req: *httpz.Request, key: []const u8, fallback: f64) ?f64 {
    const text = pcb_query.opt(req, key) orelse return fallback;
    const value = std.fmt.parseFloat(f64, text) catch return null;
    return if (std.math.isFinite(value)) value else null;
}

fn count(req: *httpz.Request, key: []const u8, fallback: u8) ?u8 {
    const text = pcb_query.opt(req, key) orelse return fallback;
    return std.fmt.parseInt(u8, text, 10) catch null;
}

/// Parse, validate, and allocate the requested panel; null means normal export.
pub fn requested(arena: std.mem.Allocator, req: *httpz.Request, source: panelize.Source) panelize.Error!?*const panelize.Plan {
    if (!pcb_query.flag(req, "panel")) return null;
    const method_text = pcb_query.opt(req, "panel_method") orelse "routed";
    const method: panelize.Method = if (std.mem.eql(u8, method_text, "v_score"))
        .v_score
    else if (std.mem.eql(u8, method_text, "routed"))
        .routed
    else
        return error.InvalidPanelDimension;
    const legacy_rail = number(req, "panel_rail", 5) orelse return error.InvalidPanelDimension;
    const bite_diameter = number(req, "panel_bite", 0.6) orelse return error.InvalidMouseBite;
    const bite_edge_gap = number(req, "panel_bite_gap", 0.35) orelse return error.InvalidMouseBite;
    const options = panelize.Options{
        .rows = count(req, "panel_rows", 2) orelse return error.InvalidPanelCount,
        .columns = count(req, "panel_columns", 2) orelse return error.InvalidPanelCount,
        .method = method,
        .gap_mm = number(req, "panel_gap", if (method == .v_score) 0 else 2) orelse return error.InvalidPanelDimension,
        .rails = .{
            .top = .{
                .width_mm = number(req, "panel_rail_top", legacy_rail) orelse return error.InvalidPanelDimension,
                .tooling_hole = pcb_query.flag(req, "panel_tooling_top"),
                .fiducial = pcb_query.flag(req, "panel_fiducial_top"),
            },
            .right = .{
                .width_mm = number(req, "panel_rail_right", legacy_rail) orelse return error.InvalidPanelDimension,
                .tooling_hole = pcb_query.flag(req, "panel_tooling_right"),
                .fiducial = pcb_query.flag(req, "panel_fiducial_right"),
            },
            .bottom = .{
                .width_mm = number(req, "panel_rail_bottom", legacy_rail) orelse return error.InvalidPanelDimension,
                .tooling_hole = pcb_query.flag(req, "panel_tooling_bottom"),
                .fiducial = pcb_query.flag(req, "panel_fiducial_bottom"),
            },
            .left = .{
                .width_mm = number(req, "panel_rail_left", legacy_rail) orelse return error.InvalidPanelDimension,
                .tooling_hole = pcb_query.flag(req, "panel_tooling_left"),
                .fiducial = pcb_query.flag(req, "panel_fiducial_left"),
            },
            .tooling_diameter_mm = number(req, "panel_tooling_diameter", 2) orelse return error.InvalidRailFeature,
            .fiducial_diameter_mm = number(req, "panel_fiducial_diameter", 1) orelse return error.InvalidRailFeature,
            .fiducial_mask_diameter_mm = number(req, "panel_fiducial_mask", 2) orelse return error.InvalidRailFeature,
        },
        .tab_mm = number(req, "panel_tab", 5) orelse return error.InvalidRoutingTab,
        .mouse_bites = .{ .diameter_mm = bite_diameter, .pitch_mm = bite_diameter + bite_edge_gap },
    };
    const result = try arena.create(panelize.Plan);
    result.* = try panelize.plan(arena, source, options);
    return result;
}

/// Render a stable HTTP 400 explanation for invalid panel geometry.
pub fn writeError(res: *httpz.Response, err: panelize.Error) void {
    res.status = 400;
    res.content_type = .JSON;
    res.body = switch (err) {
        error.InvalidPanelCount => "{\"ok\":false,\"error\":\"panel rows and columns must be positive, with at most 100 boards\"}",
        error.InvalidPanelDimension => "{\"ok\":false,\"error\":\"panel dimensions, board thickness, and copper-edge clearance must be finite and valid\"}",
        error.BoardTooSmall => "{\"ok\":false,\"error\":\"JLCPCB FR-4 boards must be at least 3 x 3 mm, or 5 x 5 mm below 0.8 mm thickness\"}",
        error.PanelTooLarge => "{\"ok\":false,\"error\":\"this JLCPCB-safe panel profile limits finished panels to 475 x 475 mm\"}",
        error.VScoreRequiresZeroGap => "{\"ok\":false,\"error\":\"V-score panels require a 0 mm board gap\"}",
        error.VScoreRequiresSquareCorners => "{\"ok\":false,\"error\":\"V-score panels require a rectangular board with square corners; use routed tabs for rounded corners\"}",
        error.VScorePanelTooSmall => "{\"ok\":false,\"error\":\"JLCPCB V-score panels must be at least 70 x 70 mm; add rows, columns, or rails\"}",
        error.VScoreLineLimit => "{\"ok\":false,\"error\":\"JLCPCB permits at most 25 V-score lines in either panel direction\"}",
        error.VScoreBoardTooThin => "{\"ok\":false,\"error\":\"JLCPCB V-score requires a finished board thickness of at least 0.6 mm\"}",
        error.VScoreCopperClearanceTooSmall => "{\"ok\":false,\"error\":\"JLCPCB V-score requires the board copper-edge rule to be at least 0.4 mm\"}",
        error.SeparationRequiresRectangularBoard => "{\"ok\":false,\"error\":\"panelization currently requires a rectangular or rounded-rectangle board outline\"}",
        error.RoutedGapTooSmall => "{\"ok\":false,\"error\":\"JLCPCB routed panels require at least a 1.2 mm board gap; 1.6 or 2 mm is recommended\"}",
        error.RoutedCopperClearanceTooSmall => "{\"ok\":false,\"error\":\"JLCPCB routed edges require the board copper-edge rule to be at least 0.2 mm\"}",
        error.InvalidRoutingTab => "{\"ok\":false,\"error\":\"JLCPCB mouse-bite tabs must be at least 5 mm and fit the straight section of every board side\"}",
        error.InvalidMouseBite => "{\"ok\":false,\"error\":\"JLCPCB mouse bites require 0.5-0.8 mm holes, 0.3-0.4 mm edge spacing, five holes per set, and a tab wide enough for the set\"}",
        error.InvalidRailFeature => "{\"ok\":false,\"error\":\"JLCPCB standard-assembly rails must be at least 5 mm and use 2 mm tooling holes plus 1 mm fiducials with 2 mm mask openings; every selected feature must fit\"}",
        error.OutOfMemory => "{\"ok\":false,\"error\":\"not enough memory to construct the requested panel\"}",
    };
}

test "panel query parses independent rail sides and their selected features" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var http = httpz.testing.init(.{});
    defer http.deinit();
    http.query("panel", "1");
    http.query("panel_rows", "1");
    http.query("panel_columns", "1");
    http.query("panel_rail_top", "6");
    http.query("panel_rail_right", "0");
    http.query("panel_rail_bottom", "5");
    http.query("panel_rail_left", "0");
    http.query("panel_tooling_top", "1");
    http.query("panel_fiducial_bottom", "1");
    const source = panelize.Source{
        .frame = .{ .ox = 0, .oy = 10 },
        .width_mm = 32,
        .height_mm = 10,
        .rectangular = true,
        .corner_radius_mm = 0,
    };
    const result = (try requested(arena_state.allocator(), http.req, source)) orelse return error.TestExpectedPanel;
    try std.testing.expectApproxEqAbs(@as(f64, 6), result.options.rails.top.width_mm, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0), result.options.rails.right.width_mm, 1e-9);
    try std.testing.expect(result.options.rails.top.tooling_hole);
    try std.testing.expect(result.options.rails.bottom.fiducial);
    try std.testing.expectEqual(@as(usize, 2 + 4 * 5), result.features.npth_holes.len);
    try std.testing.expectEqual(@as(usize, 2), result.features.fiducials.len);
}
