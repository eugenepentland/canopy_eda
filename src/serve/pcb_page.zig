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
        std.debug.print("warning: resolveIdentities {s} failed: {s}\n", .{ name, @errorName(e) });
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

    try w.print("<!DOCTYPE html><html><head><meta name=\"viewport\" content=\"width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no\"><title>{s} — PCB</title>", .{name});
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
    try w.writeAll("<button class=\"tool-btn active\" id=\"sel-comp\" title=\"Select (S)\"><svg width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\"><path d=\"M2 2l5 12 2-5 5-2z\"/><path d=\"M7 7l4 4\"/></svg></button>");
    try w.writeAll("<button class=\"tool-btn\" id=\"sel-route\" title=\"Route Traces (R)\"><svg width=\"16\" height=\"16\" viewBox=\"0 0 16 16\" fill=\"none\" stroke=\"currentColor\" stroke-width=\"1.5\"><path d=\"M3 13V8h10V3\" stroke-linecap=\"round\"/><circle cx=\"3\" cy=\"13\" r=\"1.5\" fill=\"currentColor\"/><circle cx=\"13\" cy=\"3\" r=\"1.5\" fill=\"currentColor\"/></svg></button>");
    try w.writeAll("</div>");
    // Selection filter — what objects are selectable
    try w.writeAll("<div class=\"tool-divider\"></div>");
    try w.writeAll("<div class=\"tool-section filter-section\">");
    try w.writeAll("<div class=\"filter-heading\">Filter</div>");
    try w.writeAll("<label class=\"filter-row\" title=\"Components\"><input type=\"checkbox\" class=\"sel-filter\" data-filter=\"component\" checked><span>Comp</span></label>");
    try w.writeAll("<label class=\"filter-row\" title=\"Traces\"><input type=\"checkbox\" class=\"sel-filter\" data-filter=\"trace\" checked><span>Trace</span></label>");
    try w.writeAll("<label class=\"filter-row\" title=\"Vias\"><input type=\"checkbox\" class=\"sel-filter\" data-filter=\"via\" checked><span>Via</span></label>");
    try w.writeAll("<label class=\"filter-row\" title=\"Nets\"><input type=\"checkbox\" class=\"sel-filter\" data-filter=\"net\"><span>Net</span></label>");
    try w.writeAll("<label class=\"filter-row\" title=\"Sections\"><input type=\"checkbox\" class=\"sel-filter\" data-filter=\"section\"><span>Sect</span></label>");
    try w.writeAll("<div class=\"filter-actions\"><button class=\"filter-all\" id=\"filter-all\" title=\"Select All\">All</button><button class=\"filter-all\" id=\"filter-none\" title=\"Select None\">None</button></div>");
    try w.writeAll("</div>");
    try w.writeAll("</div>");

    // Canvas
    try w.writeAll("<div id=\"pixi-container\" class=\"canvas-fill\"></div>");

    // Right panel: layer manager + sidebar
    try w.writeAll("<div class=\"right-panel\">");
    try w.writeAll("<div class=\"layer-manager\">");
    try w.writeAll("<div class=\"layer-header\"><span class=\"layer-heading\">Layers</span><div class=\"layer-presets\"><button class=\"layer-preset active\" data-preset=\"all\">All</button><button class=\"layer-preset\" data-preset=\"front\">Front</button><button class=\"layer-preset\" data-preset=\"back\">Back</button></div></div>");
    // Layer rows — each with color swatch, name, and visibility toggle
    try w.writeAll("<div class=\"layer-row\"><span class=\"layer-color\" style=\"background:#CC3333\"></span><span class=\"layer-name\">F.Cu</span><button class=\"layer-toggle\" data-layer=\"fcu\" title=\"Toggle visibility\"><svg width=\"14\" height=\"14\" viewBox=\"0 0 14 14\" fill=\"currentColor\"><path d=\"M7 3C3.5 3 1 7 1 7s2.5 4 6 4 6-4 6-4-2.5-4-6-4zm0 6.5a2.5 2.5 0 110-5 2.5 2.5 0 010 5z\"/></svg></button></div>");
    try w.writeAll("<div class=\"layer-row\"><span class=\"layer-color\" style=\"background:#3333CC\"></span><span class=\"layer-name\">B.Cu</span><button class=\"layer-toggle\" data-layer=\"bcu\" title=\"Toggle visibility\"><svg width=\"14\" height=\"14\" viewBox=\"0 0 14 14\" fill=\"currentColor\"><path d=\"M7 3C3.5 3 1 7 1 7s2.5 4 6 4 6-4 6-4-2.5-4-6-4zm0 6.5a2.5 2.5 0 110-5 2.5 2.5 0 010 5z\"/></svg></button></div>");
    try w.writeAll("<div class=\"layer-row\"><span class=\"layer-color\" style=\"background:#C8C8C8\"></span><span class=\"layer-name\">Silk</span><button class=\"layer-toggle\" data-layer=\"silk\" title=\"Toggle visibility\"><svg width=\"14\" height=\"14\" viewBox=\"0 0 14 14\" fill=\"currentColor\"><path d=\"M7 3C3.5 3 1 7 1 7s2.5 4 6 4 6-4 6-4-2.5-4-6-4zm0 6.5a2.5 2.5 0 110-5 2.5 2.5 0 010 5z\"/></svg></button></div>");
    try w.writeAll("<div class=\"layer-row\"><span class=\"layer-color\" style=\"background:#FF00FF\"></span><span class=\"layer-name\">Courtyard</span><button class=\"layer-toggle\" data-layer=\"courtyard\" title=\"Toggle visibility\"><svg width=\"14\" height=\"14\" viewBox=\"0 0 14 14\" fill=\"currentColor\"><path d=\"M7 3C3.5 3 1 7 1 7s2.5 4 6 4 6-4 6-4-2.5-4-6-4zm0 6.5a2.5 2.5 0 110-5 2.5 2.5 0 010 5z\"/></svg></button></div>");
    try w.writeAll("<div class=\"layer-row\"><span class=\"layer-color\" style=\"background:#CC3333\"></span><span class=\"layer-name\">Traces F</span><button class=\"layer-toggle\" data-layer=\"traces_fcu\" title=\"Toggle visibility\"><svg width=\"14\" height=\"14\" viewBox=\"0 0 14 14\" fill=\"currentColor\"><path d=\"M7 3C3.5 3 1 7 1 7s2.5 4 6 4 6-4 6-4-2.5-4-6-4zm0 6.5a2.5 2.5 0 110-5 2.5 2.5 0 010 5z\"/></svg></button></div>");
    try w.writeAll("<div class=\"layer-row\"><span class=\"layer-color\" style=\"background:#3333CC\"></span><span class=\"layer-name\">Traces B</span><button class=\"layer-toggle\" data-layer=\"traces_bcu\" title=\"Toggle visibility\"><svg width=\"14\" height=\"14\" viewBox=\"0 0 14 14\" fill=\"currentColor\"><path d=\"M7 3C3.5 3 1 7 1 7s2.5 4 6 4 6-4 6-4-2.5-4-6-4zm0 6.5a2.5 2.5 0 110-5 2.5 2.5 0 010 5z\"/></svg></button></div>");
    try w.writeAll("<div class=\"layer-row\"><span class=\"layer-color\" style=\"background:#C0C0C0\"></span><span class=\"layer-name\">Vias</span><button class=\"layer-toggle\" data-layer=\"vias\" title=\"Toggle visibility\"><svg width=\"14\" height=\"14\" viewBox=\"0 0 14 14\" fill=\"currentColor\"><path d=\"M7 3C3.5 3 1 7 1 7s2.5 4 6 4 6-4 6-4-2.5-4-6-4zm0 6.5a2.5 2.5 0 110-5 2.5 2.5 0 010 5z\"/></svg></button></div>");
    try w.writeAll("<div class=\"layer-row\"><span class=\"layer-color\" style=\"background:#44AA44\"></span><span class=\"layer-name\">Zones</span><button class=\"layer-toggle\" data-layer=\"zones\" title=\"Toggle visibility\"><svg width=\"14\" height=\"14\" viewBox=\"0 0 14 14\" fill=\"currentColor\"><path d=\"M7 3C3.5 3 1 7 1 7s2.5 4 6 4 6-4 6-4-2.5-4-6-4zm0 6.5a2.5 2.5 0 110-5 2.5 2.5 0 010 5z\"/></svg></button></div>");
    try w.writeAll("<div class=\"layer-row\"><span class=\"layer-color\" style=\"background:#555555\"></span><span class=\"layer-name\">Ratsnest</span><button class=\"layer-toggle\" data-layer=\"ratsnest\" title=\"Toggle visibility\"><svg width=\"14\" height=\"14\" viewBox=\"0 0 14 14\" fill=\"currentColor\"><path d=\"M7 3C3.5 3 1 7 1 7s2.5 4 6 4 6-4 6-4-2.5-4-6-4zm0 6.5a2.5 2.5 0 110-5 2.5 2.5 0 010 5z\"/></svg></button></div>");
    try w.writeAll("<div class=\"layer-row\"><span class=\"layer-color\" style=\"background:#88CC88\"></span><span class=\"layer-name\">Refs</span><button class=\"layer-toggle\" data-layer=\"refs\" title=\"Toggle visibility\"><svg width=\"14\" height=\"14\" viewBox=\"0 0 14 14\" fill=\"currentColor\"><path d=\"M7 3C3.5 3 1 7 1 7s2.5 4 6 4 6-4 6-4-2.5-4-6-4zm0 6.5a2.5 2.5 0 110-5 2.5 2.5 0 010 5z\"/></svg></button></div>");
    try w.writeAll("</div>");
    try w.writeAll("<div class=\"sidebar\" id=\"sidebar\"><div id=\"sidebar-content\"></div></div>");
    try w.writeAll("</div>");

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
    \\body { background: #0d1117; color: #c9d1d9; font-family: system-ui, sans-serif; overflow: hidden; touch-action: none; }
    \\.toolbar { display: flex; align-items: center; gap: 8px; padding: 6px 16px; background: #161b22; border-bottom: 1px solid #30363d; height: 40px; }
    \\.toolbar-title { color: #fff; font-weight: 600; font-size: 14px; margin-right: auto; white-space: nowrap; overflow: hidden; text-overflow: ellipsis; }
    \\.canvas-btn { background: #21262d; color: #c9d1d9; border: 1px solid #30363d; border-radius: 6px; padding: 4px 12px; cursor: pointer; font-size: 12px; text-decoration: none; white-space: nowrap; }
    \\.canvas-btn:hover { background: #30363d; }
    \\.main-area { display: flex; height: calc(100vh - 40px - 42px); }
    \\.canvas-fill { flex: 1; position: relative; }
    \\.tool-palette { display: flex; flex-direction: column; width: 72px; background: #161b22; border-right: 1px solid #30363d; padding: 4px 0; align-items: center; }
    \\.tool-section { display: flex; flex-direction: column; align-items: center; gap: 2px; width: 100%; }
    \\.tool-btn { width: 38px; height: 34px; background: transparent; border: none; color: #8b949e; cursor: pointer; border-radius: 6px; display: flex; align-items: center; justify-content: center; border-left: 2px solid transparent; }
    \\.tool-btn:hover { background: #21262d; color: #c9d1d9; }
    \\.tool-btn.active { color: #58a6ff; background: #1a2332; border-left-color: #58a6ff; }
    \\.tool-divider { width: 28px; height: 1px; background: #30363d; margin: 6px 0; }
    \\.filter-section { padding: 0 4px; }
    \\.filter-heading { font-size: 9px; font-weight: 600; color: #8b949e; text-transform: uppercase; letter-spacing: 0.5px; text-align: center; margin-bottom: 4px; }
    \\.filter-row { display: flex; align-items: center; gap: 4px; font-size: 10px; color: #8b949e; cursor: pointer; padding: 2px 4px; border-radius: 3px; }
    \\.filter-row:hover { background: #21262d; color: #c9d1d9; }
    \\.filter-row input { width: 12px; height: 12px; margin: 0; accent-color: #58a6ff; }
    \\.filter-row span { white-space: nowrap; }
    \\.filter-actions { display: flex; gap: 2px; margin-top: 4px; }
    \\.filter-all { flex: 1; background: #21262d; color: #8b949e; border: 1px solid #30363d; border-radius: 3px; padding: 2px 0; cursor: pointer; font-size: 9px; }
    \\.filter-all:hover { background: #30363d; color: #c9d1d9; }
    \\.right-panel { width: 260px; display: flex; flex-direction: column; background: #161b22; border-left: 1px solid #30363d; }
    \\.layer-manager { border-bottom: 1px solid #30363d; padding: 0; flex-shrink: 0; }
    \\.layer-header { display: flex; align-items: center; justify-content: space-between; padding: 6px 12px 4px; }
    \\.layer-heading { font-size: 11px; font-weight: 600; color: #8b949e; text-transform: uppercase; letter-spacing: 0.5px; }
    \\.layer-presets { display: flex; gap: 2px; }
    \\.layer-preset { background: #21262d; color: #8b949e; border: 1px solid #30363d; border-radius: 3px; padding: 1px 6px; cursor: pointer; font-size: 10px; }
    \\.layer-preset:hover { background: #30363d; color: #c9d1d9; }
    \\.layer-preset.active { background: #1a2332; color: #58a6ff; border-color: #58a6ff; }
    \\.layer-row { display: flex; align-items: center; gap: 8px; padding: 3px 12px; height: 26px; cursor: default; font-size: 12px; }
    \\.layer-row:hover { background: #1c2128; }
    \\.layer-color { width: 10px; height: 10px; border-radius: 2px; flex-shrink: 0; }
    \\.layer-name { flex: 1; color: #c9d1d9; font-size: 12px; }
    \\.layer-toggle { background: none; border: none; color: #8b949e; cursor: pointer; padding: 2px; display: flex; align-items: center; border-radius: 3px; }
    \\.layer-toggle:hover { color: #c9d1d9; background: #21262d; }
    \\.layer-toggle.off { opacity: 0.25; }
    \\.sidebar { flex: 1; overflow-y: auto; padding: 12px; font-size: 13px; color: #c9d1d9; }
    \\.sec-item { padding: 6px 8px; border-radius: 4px; margin-bottom: 2px; font-size: 12px; }
    \\.sec-item:hover { background: #21262d; }
;
