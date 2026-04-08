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

    // Toolbar below navbar
    try w.writeAll("<div class=\"toolbar\">");
    try w.print("<span class=\"toolbar-title\">{s}</span>", .{block.name});
    try w.writeAll("<button class=\"canvas-btn\" id=\"block-diagram-btn\">Block Diagram</button>");
    try w.writeAll("<button class=\"canvas-btn\" id=\"erc-btn\">ERC</button>");
    try w.writeAll("<div class=\"search-container\">");
    try w.writeAll("<input type=\"text\" id=\"search-input\" class=\"search-input\" placeholder=\"Search...\" autocomplete=\"off\">");
    try w.writeAll("<div class=\"search-results\" id=\"search-results\"></div>");
    try w.writeAll("</div>");
    try w.writeAll("<button class=\"canvas-btn\" id=\"canvas-reset\">Reset</button>");
    try w.writeAll("<button class=\"canvas-btn\" id=\"rebuild-btn\">Rebuild</button>");
    try w.print("<a class=\"canvas-btn\" href=\"/pcb/{s}\">PCB</a>", .{name});
    try w.print("<button class=\"canvas-btn\" onclick=\"window.location='/api/export-bom/{s}'\">Export BOM</button>", .{name});
    try w.writeAll("</div>");

    // Main area: canvas + sidebar
    try w.writeAll("<div class=\"main-area\">");
    try w.writeAll("<div id=\"pixi-container\" class=\"canvas-fill\"></div>");
    try w.writeAll("<div class=\"sidebar\" id=\"sidebar\">");
    try w.writeAll("<div id=\"sidebar-content\"><div class=\"sidebar-empty\">Click a component or net to inspect</div></div>");
    try w.writeAll("</div>");
    try w.writeAll("</div>");

    // Inject data globals
    try w.print("<script>var SCHEMATIC_SLUG='{s}';var DESIGN_NAME='{s}';var COMPONENTS={{", .{ name, name });
    _ = try bom_html.writeComponentsJson(w, block, "", &sym_cache, ctx.allocator, ctx.project_dir);
    try w.writeAll("};var NETS={");
    _ = try bom_html.writeNetsJson(w, block, "");
    try w.writeAll("};var SECTIONS=[");
    var sec_written = false;
    for (block.sections) |sec| {
        if (sec_written) try w.writeAll(",");
        try w.print("\"{s}\"", .{sec.name});
        sec_written = true;
    }
    for (block.sub_blocks) |sb| {
        if (sec_written) try w.writeAll(",");
        try w.writeAll("\"");
        try bom_html.writeJsonEscaped(w, sb.block.name);
        try w.writeAll("\"");
        sec_written = true;
    }
    try w.writeAll("];var ASSERTIONS=[");
    for (eval.assertions.items, 0..) |a, ai| {
        if (ai > 0) try w.writeAll(",");
        try w.writeAll("{\"passed\":");
        try w.writeAll(if (a.passed) "true" else "false");
        try w.writeAll(",\"message\":\"");
        try bom_html.writeJsonEscaped(w, a.message);
        try w.writeAll("\",\"isWarning\":");
        try w.writeAll(if (a.is_warning) "true" else "false");
        try w.writeAll("}");
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

    try w.writeAll("</body></html>");
    res.body = buf.items;
    res.content_type = .HTML;
    res.header("connection", "close");
}

const CANVAS_CSS =
    \\html,body{margin:0;padding:0;height:100%;overflow:hidden;background:#0d1117;color:#e0e0e0;font-family:system-ui,sans-serif}
    \\.toolbar{display:flex;gap:8px;padding:6px 12px;background:#161b22;border-bottom:1px solid #21262d;align-items:center}
    \\.toolbar-title{font-size:15px;font-weight:600;color:#e0e0e0;margin-right:8px}
    \\.canvas-btn{padding:4px 12px;border:1px solid #30363d;background:#21262d;color:#c9d1d9;border-radius:4px;cursor:pointer;font-size:12px;text-decoration:none}
    \\.canvas-btn:hover{background:#30363d;border-color:#58a6ff}
    \\.search-container{position:relative;margin-left:auto}
    \\.search-input{padding:4px 8px;border:1px solid #30363d;background:#0d1117;color:#c9d1d9;border-radius:4px;font-size:12px;width:220px}
    \\.search-input:focus{border-color:#4a9eff}
    \\.search-input::placeholder{color:#555}
    \\.search-results{position:absolute;top:100%;left:0;background:#161b22;border:1px solid #30363d;border-radius:0 0 4px 4px;max-height:300px;overflow-y:auto;display:none;z-index:100;min-width:260px}
    \\.search-results.open{display:block}
    \\.search-result{padding:6px 10px;cursor:pointer;font-size:12px;font-family:monospace;color:#c9d1d9;border-bottom:1px solid #21262d;display:flex;justify-content:space-between}
    \\.search-result:hover,.search-result.selected{background:#30363d}
    \\.search-result-type{font-size:11px;color:#888;text-transform:uppercase}
    \\.search-result-type.net{color:#e8c547}
    \\.search-result-type.comp{color:#4a9eff}
    \\.search-result-type.section{color:#3fb950}
    \\.search-result-type.pin{color:#c084fc}
    \\.main-area{display:flex;height:calc(100vh - 42px - 37px);overflow:hidden}
    \\.canvas-fill{flex:1;min-width:0;background:#0d1117}
    \\.sidebar{width:320px;min-width:320px;height:100%;background:#161b22;border-left:1px solid #30363d;padding:16px;overflow-y:auto;overflow-x:hidden;box-sizing:border-box}
    \\.sidebar::-webkit-scrollbar{width:6px}
    \\.sidebar::-webkit-scrollbar-track{background:#0d1117}
    \\.sidebar::-webkit-scrollbar-thumb{background:#30363d;border-radius:3px}
    \\.sidebar::-webkit-scrollbar-thumb:hover{background:#484f58}
    \\.sidebar-empty{color:#555;font-size:13px;font-style:italic;padding-top:8px}
    \\.sec-item{padding:8px 10px;border-bottom:1px solid #21262d;cursor:pointer;border-radius:4px;margin-bottom:2px}
    \\.sec-item:hover{background:#1a2e1a}
    \\.sec-item-name{font-size:13px;color:#3fb950;font-weight:500}
    \\.sec-item-desc{font-size:11px;color:#6e7681;margin-top:2px;font-style:italic}
    \\#pixi-container canvas{display:block}
;

const CANVAS_VIEWER_JS = @import("canvas_viewer_js.zig").CANVAS_VIEWER_JS;
