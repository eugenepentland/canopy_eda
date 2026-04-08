const std = @import("std");
const httpz = @import("httpz");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const render_pcb_json = @import("../render_pcb_json.zig");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;
const assets_css = @import("assets_css.zig");
const bom = @import("../bom.zig");
const env_mod = @import("../eval/env.zig");
const pcb_viewer_js = @import("pcb_viewer_js.zig");

pub fn pcbPage(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
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
        .design_block => |db| block = db,
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
    bom.resolveIdentities(ctx.allocator, block, ids_path, ctx.project_dir) catch {};

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

    try w.print("<!DOCTYPE html><html><head><title>{s} — PCB</title>", .{name});
    try w.writeAll("<style>");
    try w.writeAll(assets_css.NAVBAR_CSS);
    try w.writeAll(PCB_CSS);
    try w.writeAll("</style></head><body>");
    try assets_css.writeNavbar(w, "designs");

    // Toolbar
    try w.writeAll("<div class=\"toolbar\">");
    try w.print("<span class=\"toolbar-title\">{s} — PCB Layout</span>", .{name});
    try w.writeAll("<div class=\"layer-toggles\">");
    try w.writeAll("<button class=\"layer-toggle\" data-layer=\"fcu\" style=\"border-color:#CC3333\">F.Cu</button>");
    try w.writeAll("<button class=\"layer-toggle\" data-layer=\"bcu\" style=\"border-color:#3333CC\">B.Cu</button>");
    try w.writeAll("<button class=\"layer-toggle\" data-layer=\"silk\" style=\"border-color:#C8C8C8\">Silk</button>");
    try w.writeAll("<button class=\"layer-toggle\" data-layer=\"courtyard\" style=\"border-color:#FF00FF\">Courtyard</button>");
    try w.writeAll("<button class=\"layer-toggle\" data-layer=\"traces_fcu\" style=\"border-color:#CC3333\">Traces F</button>");
    try w.writeAll("<button class=\"layer-toggle\" data-layer=\"traces_bcu\" style=\"border-color:#3333CC\">Traces B</button>");
    try w.writeAll("<button class=\"layer-toggle\" data-layer=\"vias\" style=\"border-color:#C0C0C0\">Vias</button>");
    try w.writeAll("<button class=\"layer-toggle\" data-layer=\"zones\" style=\"border-color:#44AA44\">Zones</button>");
    try w.writeAll("<button class=\"layer-toggle\" data-layer=\"ratsnest\" style=\"border-color:#555555\">Ratsnest</button>");
    try w.writeAll("<button class=\"layer-toggle\" data-layer=\"refs\" style=\"border-color:#88CC88\">Refs</button>");
    try w.writeAll("</div>");
    try w.writeAll("<div class=\"select-toggle\"><button class=\"canvas-btn active\" id=\"sel-comp\">Components</button><button class=\"canvas-btn\" id=\"sel-net\">Nets</button><button class=\"canvas-btn\" id=\"sel-sec\">Sections</button><button class=\"canvas-btn\" id=\"sel-trace\">Traces</button><button class=\"canvas-btn\" id=\"sel-route\">Route</button></div>");
    try w.writeAll("<button class=\"canvas-btn\" id=\"grid-snap\">Grid: 0.5mm</button>");
    try w.writeAll("<button class=\"canvas-btn\" id=\"zone-fill-btn\">Fill Zones</button>");
    try w.writeAll("<button class=\"canvas-btn\" id=\"drc-btn\">Run DRC</button>");
    try w.writeAll("<button class=\"canvas-btn\" id=\"pcb-reset\">Reset View</button>");
    try w.print("<a class=\"canvas-btn\" href=\"/api/export-gerber/{s}\" download>Export Fab</a>", .{name});
    try w.print("<a class=\"canvas-btn\" href=\"/schematics/{s}\">Schematic</a>", .{name});
    try w.writeAll("</div>");

    // Main area
    try w.writeAll("<div class=\"main-area\">");
    try w.writeAll("<div id=\"pixi-container\" class=\"canvas-fill\"></div>");
    try w.writeAll("<div class=\"sidebar\" id=\"sidebar\"><div id=\"sidebar-content\"></div></div>");
    try w.writeAll("</div>");

    // Tooltip
    try w.writeAll("<div id=\"tooltip\" style=\"display:none;position:fixed;background:#1c2128;color:#c9d1d9;padding:4px 8px;border-radius:4px;font-size:11px;pointer-events:none;z-index:100;border:1px solid #30363d\"></div>");

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

const PCB_CSS =
    \\* { margin: 0; padding: 0; box-sizing: border-box; }
    \\body { background: #0d1117; color: #c9d1d9; font-family: system-ui, sans-serif; overflow: hidden; }
    \\.toolbar { display: flex; align-items: center; gap: 8px; padding: 8px 16px; background: #161b22; border-bottom: 1px solid #30363d; height: 44px; }
    \\.toolbar-title { color: #fff; font-weight: 600; font-size: 14px; margin-right: auto; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    \\.canvas-btn { background: #21262d; color: #c9d1d9; border: 1px solid #30363d; border-radius: 6px; padding: 4px 12px; cursor: pointer; font-size: 12px; text-decoration: none; }
    \\.canvas-btn:hover { background: #30363d; }
    \\.layer-toggles { display: flex; gap: 4px; }
    \\.layer-toggle { background: transparent; color: #c9d1d9; border: 2px solid #555; border-radius: 4px; padding: 2px 8px; cursor: pointer; font-size: 11px; font-weight: 600; }
    \\.layer-toggle:hover { background: #21262d; }
    \\.layer-toggle.off { opacity: 0.3; }
    \\.select-toggle { display: flex; gap: 0; }
    \\.select-toggle .canvas-btn { border-radius: 0; border-right-width: 0; }
    \\.select-toggle .canvas-btn:first-child { border-radius: 4px 0 0 4px; }
    \\.select-toggle .canvas-btn:last-child { border-radius: 0 4px 4px 0; border-right-width: 1px; }
    \\.select-toggle .canvas-btn.active { background: #58a6ff; color: #0d1117; border-color: #58a6ff; }
    \\.main-area { display: flex; height: calc(100vh - 44px - 40px); }
    \\.canvas-fill { flex: 1; position: relative; }
    \\.sidebar { width: 280px; background: #161b22; border-left: 1px solid #30363d; overflow-y: auto; padding: 16px; font-size: 13px; color: #c9d1d9; }
    \\.sec-item { padding: 6px 8px; border-radius: 4px; margin-bottom: 2px; font-size: 12px; }
    \\.sec-item:hover { background: #21262d; }
;
