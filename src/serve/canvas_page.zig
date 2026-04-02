const std = @import("std");
const httpz = @import("httpz");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const render_json = @import("../render_json.zig");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;
const assets_css = @import("assets_css.zig");
const bom_html = @import("bom_html.zig");
const library = @import("library.zig");

pub fn canvasPage(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
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

    const block = switch (result) {
        .design_block => |b| b,
        else => {
            res.status = 500;
            return;
        },
    };

    // Generate scene graph and seed live cache
    const layout_json = render_json.renderSceneGraph(ctx.allocator, block) catch null;
    serve_root.live_mutex.lock();
    serve_root.live_layout_json = layout_json;
    serve_root.live_mutex.unlock();

    var sym_cache = try bom_html.buildSymbolPinCache(ctx.allocator, ctx.project_dir);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(ctx.allocator);

    try w.print("<!DOCTYPE html><html><head><title>{s} — Canvas</title>", .{block.name});
    try w.writeAll("<style>");
    try w.writeAll(assets_css.NAVBAR_CSS);
    try w.writeAll(CANVAS_CSS);
    try w.writeAll("</style></head><body>");
    try assets_css.writeNavbar(w, "designs");

    try w.writeAll("<div class=\"page\" id=\"page\">");
    try w.print("<h1>{s} <a href=\"/schematics/{s}\" style=\"font-size:14px;color:#58a6ff;margin-left:12px\">SVG View</a></h1>", .{ block.name, name });

    // Canvas container
    try w.writeAll("<div class=\"schematic\"><div class=\"schematic-canvas\" id=\"schematic-canvas\">");
    try w.writeAll("<div class=\"canvas-controls\">");
    try w.writeAll("<div class=\"search-container\">");
    try w.writeAll("<input type=\"text\" id=\"search-input\" class=\"search-input\" placeholder=\"Search...\" autocomplete=\"off\">");
    try w.writeAll("<div class=\"search-results\" id=\"search-results\"></div>");
    try w.writeAll("</div>");
    try w.writeAll("<button class=\"canvas-btn\" id=\"canvas-reset\">Reset</button>");
    try w.writeAll("<button class=\"canvas-btn\" id=\"rebuild-btn\">Rebuild</button>");
    try w.writeAll("</div>");
    try w.writeAll("<div id=\"pixi-container\" style=\"width:100%;height:70vh;background:#0d1117\"></div>");
    try w.writeAll("</div></div>");

    // Sidebar
    try w.writeAll("<div class=\"sidebar\" id=\"sidebar\">");
    try w.writeAll("<button class=\"sidebar-close\" id=\"sidebar-close\">&times;</button>");
    try w.writeAll("<div id=\"sidebar-content\"></div>");
    try w.writeAll("</div>");

    // Inject data globals
    try w.print("<script>var SCHEMATIC_SLUG='{s}';var DESIGN_NAME='{s}';var COMPONENTS={{", .{ name, name });
    _ = try bom_html.writeComponentsJson(w, block, "", &sym_cache, ctx.allocator, ctx.project_dir);
    try w.writeAll("};var NETS={");
    _ = try bom_html.writeNetsJson(w, block, "");
    try w.writeAll("};var SECTIONS=[");
    for (block.sections, 0..) |sec, si| {
        if (si > 0) try w.writeAll(",");
        try w.print("\"{s}\"", .{sec.name});
    }
    try w.writeAll("];var FAMILIES={");
    try library.writeFamiliesJson(w, ctx.allocator, ctx.project_dir);
    try w.writeAll("};</script>");

    // Pixi.js from CDN
    try w.writeAll("<script src=\"https://cdn.jsdelivr.net/npm/pixi.js@8.6.6/dist/pixi.min.js\"></script>");

    // Canvas viewer JS
    try w.writeAll("<script>");
    try w.writeAll(CANVAS_VIEWER_JS);
    try w.writeAll("</script>");

    try w.writeAll("</div></body></html>");
    res.body = buf.items;
    res.content_type = .HTML;
}

const CANVAS_CSS =
    \\body{margin:0;background:#0d1117;color:#e0e0e0;font-family:system-ui,sans-serif}
    \\.page{max-width:1800px;margin:0 auto;padding:1rem 2rem}
    \\.page h1{font-size:20px;color:#e0e0e0;margin-bottom:12px}
    \\.schematic{position:relative}
    \\.schematic-canvas{position:relative;border:1px solid #21262d;border-radius:8px;overflow:hidden}
    \\.canvas-controls{display:flex;gap:8px;padding:8px 12px;background:#161b22;border-bottom:1px solid #21262d;align-items:center;flex-wrap:wrap}
    \\.canvas-btn{padding:4px 12px;border:1px solid #30363d;background:#21262d;color:#c9d1d9;border-radius:4px;cursor:pointer;font-size:12px}
    \\.canvas-btn:hover{background:#30363d;border-color:#58a6ff}
    \\.search-container{position:relative}
    \\.search-input{padding:4px 8px;border:1px solid #30363d;background:#0d1117;color:#c9d1d9;border-radius:4px;font-size:12px;width:180px}
    \\.search-results{position:absolute;top:100%;left:0;background:#161b22;border:1px solid #30363d;border-radius:4px;max-height:200px;overflow-y:auto;display:none;z-index:100;min-width:250px}
    \\.search-results div{padding:6px 10px;cursor:pointer;font-size:12px;color:#c9d1d9}
    \\.search-results div:hover,.search-results div.active{background:#30363d}
    \\.sidebar{position:fixed;right:0;top:0;width:320px;height:100%;background:#161b22;border-left:1px solid #30363d;transform:translateX(100%);transition:transform .2s;z-index:200;padding:16px;overflow-y:auto}
    \\.sidebar.open{transform:translateX(0)}
    \\.sidebar-close{position:absolute;top:8px;right:8px;background:none;border:none;color:#8b949e;font-size:20px;cursor:pointer}
    \\#pixi-container canvas{display:block}
;

const CANVAS_VIEWER_JS = @import("canvas_viewer_js.zig").CANVAS_VIEWER_JS;
