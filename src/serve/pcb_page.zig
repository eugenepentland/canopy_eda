const std = @import("std");
const httpz = @import("httpz");
const log = @import("../infra/log.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const render_pcb_json = @import("../render_pcb_json.zig");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;
const assets_css = @import("assets_css.zig");
const bom = @import("../bom.zig");
const env_mod = @import("../eval/env.zig");
const pcb_viewer_js = @import("pcb_viewer_js.zig");

/// Error set for HTTP handlers in this module.
pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error;

/// GET /pcb/:name — render the Pixi.js PCB layout editor for a design.
/// Evaluates `<name>.sexp` (and the optional `<name>-board.sexp` companion
/// for outline/stackup/rules), then ships the page JS and initial state.
pub fn pcbPage(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };

    const board_path = try std.fmt.allocPrint(ctx.allocator, "{s}/src/{s}.sexp", .{ ctx.project_dir, name });
    defer ctx.allocator.free(board_path);

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();

    const result = eval.evalFile(board_path) catch {
        res.status = 500;
        res.body = "Build error";
        return;
    };

    // Extract design block and optional board def
    var block: *env_mod.DesignBlock = undefined;
    var board_def: ?*env_mod.Board = null;
    switch (result) {
        .design_block => |db| {
            block = db;
            // Try loading a companion board definition (<name>-board.sexp)
            const bd_path = std.fmt.allocPrint(ctx.allocator, "{s}/src/{s}-board.sexp", .{ ctx.project_dir, name }) catch null;
            if (bd_path) |bp| {
                defer ctx.allocator.free(bp);
                var eval2 = Evaluator.init(ctx.allocator, ctx.project_dir);
                defer eval2.deinit();
                if (eval2.evalFile(bp)) |bd_result| {
                    switch (bd_result) {
                        .board => |b| board_def = b,
                        else => {},
                    }
                } else |_| {}
            }
        },
        .board => |b| {
            block = b.design;
            board_def = b;
        },
        else => {
            res.status = 500;
            res.body = "Not a design block";
            return;
        },
    }

    // Resolve BOM identities
    const ids_path = try std.fmt.allocPrint(ctx.allocator, "{s}/src/{s}.bom", .{ ctx.project_dir, name });
    defer ctx.allocator.free(ids_path);
    bom.resolveIdentities(ctx.allocator, block, ids_path, ctx.project_dir) catch |e| {
        log.warn("resolveIdentities {s} failed: {s}", .{ name, @errorName(e) });
    };

    // Layout path (.layout) and fallback PCB path
    const layout_path = try std.fmt.allocPrint(ctx.allocator, "{s}/src/{s}.layout", .{ ctx.project_dir, name });
    defer ctx.allocator.free(layout_path);
    const pcb_path = try std.fmt.allocPrint(ctx.allocator, "{s}/out/{s}.kicad_pcb", .{ ctx.project_dir, name });
    defer ctx.allocator.free(pcb_path);

    // Generate PCB JSON
    const pcb_json = render_pcb_json.renderPcbJson(ctx.allocator, block, ctx.project_dir, name, board_def, pcb_path, layout_path) catch {
        res.status = 500;
        res.body = "PCB JSON render error";
        return;
    };

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(ctx.allocator);

    try w.print(
        "<!DOCTYPE html><html><head>" ++
            "<meta name=\"viewport\" " ++
            "content=\"width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no\">" ++
            "<title>{s} — PCB</title>",
        .{name},
    );
    try w.writeAll("<style>");
    try w.writeAll(assets_css.NAVBAR_CSS);
    try w.writeAll(PCB_CSS);
    try w.writeAll("</style></head><body>");
    try assets_css.writeNavbar(w, "designs");

    // Toolbar — slim, action buttons only
    try w.writeAll("<div class=\"toolbar\">");
    try w.print("<span class=\"toolbar-title\">{s} — PCB Layout</span>", .{name});
    try w.writeAll("<button class=\"canvas-btn\" id=\"grid-snap\">Grid: 0.5mm</button>");
    try w.writeAll("<button class=\"canvas-btn\" id=\"zone-fill-btn\">Fill Zones</button>");
    try w.writeAll("<button class=\"canvas-btn\" id=\"drc-btn\">Run DRC</button>");
    try w.writeAll("<button class=\"canvas-btn\" id=\"pcb-reset\">Reset View</button>");
    try w.print("<a class=\"canvas-btn\" href=\"/api/export-gerber/{s}\" download>Export Fab</a>", .{name});
    try w.print("<a class=\"canvas-btn\" href=\"/schematics/{s}\">Schematic</a>", .{name});
    try w.writeAll("</div>");

    // Main area: tool palette | canvas | right panel (layers + sidebar)
    try w.writeAll("<div class=\"main-area\">");

    // Left tool palette — tools + selection filter
    try w.writeAll("<div class=\"tool-palette\">");
    // Tools
    try w.writeAll("<div class=\"tool-section\">");
    try w.writeAll(SEL_COMP_BTN);
    try w.writeAll(SEL_ROUTE_BTN);
    try w.writeAll("</div>");
    // Selection filter — what objects are selectable
    try w.writeAll("<div class=\"tool-divider\"></div>");
    try w.writeAll("<div class=\"tool-section filter-section\">");
    try w.writeAll("<div class=\"filter-heading\">Filter</div>");
    try writeFilterRow(w, "Components", "component", "Comp", true);
    try writeFilterRow(w, "Traces", "trace", "Trace", true);
    try writeFilterRow(w, "Vias", "via", "Via", true);
    try writeFilterRow(w, "Nets", "net", "Net", false);
    try writeFilterRow(w, "Sections", "section", "Sect", false);
    try w.writeAll(FILTER_ACTIONS);
    try w.writeAll("</div>");
    try w.writeAll("</div>");

    // Canvas
    try w.writeAll("<div id=\"pixi-container\" class=\"canvas-fill\"></div>");

    // Right panel: layer manager + sidebar
    try w.writeAll("<div class=\"right-panel\">");
    try w.writeAll("<div class=\"layer-manager\">");
    try w.writeAll(LAYER_HEADER);
    // Layer rows — each with color swatch, name, and visibility toggle
    try writeLayerRow(w, "#CC3333", "F.Cu", "fcu");
    try writeLayerRow(w, "#3333CC", "B.Cu", "bcu");
    try writeLayerRow(w, "#C8C8C8", "Silk", "silk");
    try writeLayerRow(w, "#FF00FF", "Courtyard", "courtyard");
    try writeLayerRow(w, "#CC3333", "Traces F", "traces_fcu");
    try writeLayerRow(w, "#3333CC", "Traces B", "traces_bcu");
    try writeLayerRow(w, "#C0C0C0", "Vias", "vias");
    try writeLayerRow(w, "#44AA44", "Zones", "zones");
    try writeLayerRow(w, "#555555", "Ratsnest", "ratsnest");
    try writeLayerRow(w, "#88CC88", "Refs", "refs");
    try w.writeAll("</div>");
    try w.writeAll("<div class=\"sidebar\" id=\"sidebar\"><div id=\"sidebar-content\"></div></div>");
    try w.writeAll("</div>");

    try w.writeAll("</div>");

    // Tooltip
    try w.writeAll(TOOLTIP_DIV);

    // Data injection
    try w.print("<script>var DESIGN_NAME='{s}';var PCB_DATA=", .{name});
    try w.writeAll(pcb_json);
    try w.writeAll(";</script>");

    // Pixi.js
    try w.writeAll("<script src=\"https://cdn.jsdelivr.net/npm/pixi.js@8.6.6/dist/pixi.min.js\"></script>");

    // Viewer JS
    try w.writeAll("<script>");
    try w.writeAll(pcb_viewer_js.PCB_VIEWER_JS);
    try w.writeAll("</script>");

    try w.writeAll("</body></html>");

    res.body = buf.items;
    res.content_type = .HTML;
    res.header("connection", "close");
}

const PCB_CSS = @embedFile("assets/pcb_page.css");

const EYE_SVG_14 =
    "<svg width=\"14\" height=\"14\" viewBox=\"0 0 14 14\" fill=\"currentColor\">" ++
    "<path d=\"M7 3C3.5 3 1 7 1 7s2.5 4 6 4 6-4 6-4-2.5-4-6-4zm0 6.5a2.5 2.5 0 110-5 2.5 2.5 0 010 5z\"/>" ++
    "</svg>";

const SEL_COMP_BTN =
    "<button class=\"tool-btn active\" id=\"sel-comp\" title=\"Select (S)\">" ++
    "<svg width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\">" ++
    "<path d=\"M2 2l5 12 2-5 5-2z\"/><path d=\"M7 7l4 4\"/></svg></button>";

const SEL_ROUTE_BTN =
    "<button class=\"tool-btn\" id=\"sel-route\" title=\"Route Traces (R)\">" ++
    "<svg width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\">" ++
    "<path d=\"M3 13V8h10V3\" stroke-linecap=\"round\"/>" ++
    "<circle cx=\"3\" cy=\"13\" r=\"1.5\" fill=\"currentColor\"/>" ++
    "<circle cx=\"13\" cy=\"3\" r=\"1.5\" fill=\"currentColor\"/></svg></button>";

const FILTER_ACTIONS =
    "<div class=\"filter-actions\">" ++
    "<button class=\"filter-all\" id=\"filter-all\" title=\"Select All\">All</button>" ++
    "<button class=\"filter-all\" id=\"filter-none\" title=\"Select None\">None</button>" ++
    "</div>";

const LAYER_HEADER =
    "<div class=\"layer-header\">" ++
    "<span class=\"layer-heading\">Layers</span>" ++
    "<div class=\"layer-presets\">" ++
    "<button class=\"layer-preset active\" data-preset=\"all\">All</button>" ++
    "<button class=\"layer-preset\" data-preset=\"front\">Front</button>" ++
    "<button class=\"layer-preset\" data-preset=\"back\">Back</button>" ++
    "</div></div>";

const TOOLTIP_DIV =
    "<div id=\"tooltip\" style=\"display:none;position:fixed;" ++
    "background:#1c2128;color:#c9d1d9;padding:4px 8px;border-radius:4px;" ++
    "font-size:11px;pointer-events:none;z-index:100;border:1px solid #30363d\"></div>";

fn writeFilterRow(w: anytype, title: []const u8, filter_id: []const u8, label: []const u8, checked: bool) !void {
    try w.print(
        "<label class=\"filter-row\" title=\"{s}\">" ++
            "<input type=\"checkbox\" class=\"sel-filter\" data-filter=\"{s}\"{s}>" ++
            "<span>{s}</span></label>",
        .{ title, filter_id, if (checked) " checked" else "", label },
    );
}

fn writeLayerRow(w: anytype, color: []const u8, name: []const u8, layer_id: []const u8) !void {
    try w.print(
        "<div class=\"layer-row\">" ++
            "<span class=\"layer-color\" style=\"background:{s}\"></span>" ++
            "<span class=\"layer-name\">{s}</span>" ++
            "<button class=\"layer-toggle\" data-layer=\"{s}\" title=\"Toggle visibility\">" ++
            EYE_SVG_14 ++
            "</button></div>",
        .{ color, name, layer_id },
    );
}
