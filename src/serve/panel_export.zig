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
    const options = panelize.Options{
        .rows = count(req, "panel_rows", 2) orelse return error.InvalidPanelCount,
        .columns = count(req, "panel_columns", 2) orelse return error.InvalidPanelCount,
        .method = method,
        .gap_mm = number(req, "panel_gap", if (method == .v_score) 0 else 2) orelse return error.InvalidPanelDimension,
        .rail_mm = number(req, "panel_rail", 5) orelse return error.InvalidPanelDimension,
        .tab_mm = number(req, "panel_tab", 3) orelse return error.InvalidRoutingTab,
        .mouse_bites = .{ .diameter_mm = number(req, "panel_bite", 0.5) orelse return error.InvalidMouseBite },
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
        error.InvalidPanelDimension => "{\"ok\":false,\"error\":\"panel dimensions must be finite, non-negative, and no larger than 1000 mm\"}",
        error.VScoreRequiresZeroGap => "{\"ok\":false,\"error\":\"V-score panels require a 0 mm board gap\"}",
        error.SeparationRequiresRectangularBoard => "{\"ok\":false,\"error\":\"V-score and tab-route panelization currently require a rectangular board outline without rounded corners\"}",
        error.RoutedGapTooSmall => "{\"ok\":false,\"error\":\"routed panels require at least a 1 mm board gap\"}",
        error.InvalidRoutingTab => "{\"ok\":false,\"error\":\"routing tabs must be at least 1 mm and smaller than the board's short side\"}",
        error.InvalidMouseBite => "{\"ok\":false,\"error\":\"mouse-bite diameter must be 0.2-1.0 mm with a pitch at least as large as the hole\"}",
        error.OutOfMemory => "{\"ok\":false,\"error\":\"not enough memory to construct the requested panel\"}",
    };
}
