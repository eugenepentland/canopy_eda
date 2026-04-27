const std = @import("std");
const httpz = @import("httpz");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const render_json = @import("../render_json.zig");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;
const assets_css = @import("assets_css.zig");
const bom_html = @import("bom_html.zig");
const library = @import("library.zig");

// ── Constants ─────────────────────────────────────────────────────
const SCRIPT_CLOSE_TAG = "</script>";

/// Error set for HTTP handlers in this module.
pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error ||
    std.fs.Dir.Iterator.Error || library.HandlerError || bom_html.BomError;

/// GET /schematics/:name — render the Pixi.js schematic viewer page for a
/// design. Evaluates the source, seeds the live scene-graph cache so the
/// initial paint and subsequent `/api/version/:name` polls stay in sync,
/// and inlines the BOM table and toolbar markup into the HTML response.
pub fn canvasPage(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
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
    const layout_json = render_json.renderSceneGraph(ctx.allocator, block, ctx.project_dir) catch null;
    serve_root.setLiveLayoutJson(layout_json);

    var sym_cache = try bom_html.buildSymbolPinCache(ctx.allocator, ctx.project_dir);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(ctx.allocator);

    try w.print(
        "<!DOCTYPE html><html><head>" ++
            "<meta name=\"viewport\" " ++
            "content=\"width=device-width,initial-scale=1,maximum-scale=1,user-scalable=no\">" ++
            "<title>{s} — Canvas</title>",
        .{block.name},
    );
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
    try w.writeAll("<button class=\"canvas-btn\" id=\"source-btn\">Source</button>");
    try w.print("<a class=\"canvas-btn\" href=\"/pcb/{s}\">PCB</a>", .{name});
    try w.print("<a class=\"canvas-btn\" href=\"/review/{s}\">Review</a>", .{name});
    try w.print("<button class=\"canvas-btn\" onclick=\"window.location='/api/export-bom/{s}'\">Export BOM</button>", .{name});
    try w.writeAll("<div class=\"kicad-menu\">");
    try w.writeAll("<button class=\"canvas-btn\" id=\"kicad-btn\">KiCad \u{25BE}</button>");
    try w.writeAll("<div class=\"kicad-panel\" id=\"kicad-panel\">");
    try w.print("<button class=\"kicad-row-btn\" onclick=\"window.location='/api/export-netlist/{s}'\">Download Netlist (.net)</button>", .{name});
    try w.print("<button class=\"kicad-row-btn\" onclick=\"window.location='/api/export-kicad/{s}'\">Download Netlist + Footprints (.zip)</button>", .{name});
    try w.writeAll("<div class=\"kicad-sep\"></div>");
    try w.writeAll("<label class=\"kicad-label\">Output directory</label>");
    try w.writeAll("<input type=\"text\" class=\"kicad-input\" id=\"kicad-path\" placeholder=\"/path/to/kicad/project\" />");
    try w.writeAll("<label class=\"kicad-label\">.kicad_pcb file (optional)</label>");
    try w.writeAll("<input type=\"text\" class=\"kicad-input\" id=\"kicad-pcb-file\" placeholder=\"defaults to {output_dir}/{name}.kicad_pcb\" />");
    try w.writeAll("<button class=\"kicad-row-btn\" id=\"kicad-save-path\">Save settings</button>");
    try w.writeAll("<div class=\"kicad-sep\"></div>");
    try w.writeAll("<button class=\"kicad-row-btn\" id=\"kicad-write-netlist\">Write netlist to path</button>");
    try w.writeAll("<button class=\"kicad-row-btn\" id=\"kicad-write-kicad\">Write netlist + footprints to path</button>");
    try w.writeAll("<label class=\"kicad-check\"><input type=\"checkbox\" id=\"kicad-short-nets\" /> Shorten net names (.kicad_pcb update)</label>");
    try w.writeAll("<button class=\"kicad-row-btn kicad-primary\" id=\"kicad-update-pcb\">Update KiCad PCB (pcb_update.py)</button>");
    try w.writeAll("<div class=\"kicad-status\" id=\"kicad-status\"></div>");
    try w.writeAll("</div></div>");
    try w.writeAll("</div>");

    // Main area: canvas + sidebar
    try w.writeAll("<div class=\"main-area\">");
    try w.writeAll("<div id=\"pixi-container\" class=\"canvas-fill\"></div>");
    try w.writeAll("<div class=\"sidebar\" id=\"sidebar\">");
    try w.writeAll("<div id=\"sidebar-content\"><div class=\"sidebar-empty\">Click a component or net to inspect</div></div>");
    try w.writeAll("</div>");
    try w.writeAll("</div>");

    // Source editor modal — must come before any script that wires it
    try w.writeAll("<div id=\"source-modal\" class=\"source-modal\" style=\"display:none\">");
    try w.writeAll("<div class=\"source-modal-box\">");
    try w.print(
        "<div class=\"source-modal-head\"><span>Source: {s}.sexp</span>" ++
            "<button class=\"canvas-btn\" id=\"source-close\">\u{2715}</button></div>",
        .{name},
    );
    try w.writeAll("<div class=\"source-modal-err\" id=\"source-err\" style=\"display:none\"></div>");
    try w.writeAll("<textarea id=\"source-textarea\" spellcheck=\"false\" autocomplete=\"off\"></textarea>");
    try w.writeAll("<div class=\"source-modal-foot\">");
    try w.writeAll("<span class=\"source-modal-hint\">Cmd/Ctrl+S to save, Esc to cancel</span>");
    try w.writeAll("<button class=\"canvas-btn\" id=\"source-cancel\">Cancel</button>");
    try w.writeAll("<button class=\"canvas-btn source-save\" id=\"source-save\">Save &amp; Rebuild</button>");
    try w.writeAll("</div></div></div>");

    // Inject data globals
    try w.print("<script>var SCHEMATIC_SLUG='{s}';var DESIGN_NAME='{s}';var COMPONENTS={{", .{ name, name });
    _ = try bom_html.writeComponentsJson(w, block, "", &sym_cache, ctx.allocator, ctx.project_dir);
    try w.writeAll("};var NETS={");
    _ = try bom_html.writeNetsJson(w, block, "");
    try w.writeAll("};var SECTIONS=[");
    var sec_written = false;
    var concept_count: usize = 0;
    var total_sections: usize = 0;
    for (block.sections) |sec| {
        if (sec_written) try w.writeAll(",");
        try w.print("{{\"name\":\"{s}\",\"status\":\"{s}\"}}", .{ sec.name, @tagName(sec.status) });
        sec_written = true;
        total_sections += 1;
        if (sec.status == .concept) concept_count += 1;
    }
    for (block.sub_blocks) |sb| {
        if (sec_written) try w.writeAll(",");
        try w.writeAll("{\"name\":\"");
        try bom_html.writeJsonEscaped(w, sb.block.name);
        try w.writeAll("\",\"status\":\"implemented\"}");
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
    try w.writeAll("};");
    // Default to block diagram view if majority of sections are concept
    const is_concept_mode = total_sections > 0 and concept_count * 2 > total_sections;
    try w.print("var CONCEPT_MODE={s};", .{if (is_concept_mode) "true" else "false"});
    try w.writeAll(SCRIPT_CLOSE_TAG);

    // KiCad sync menu wiring
    try w.writeAll("<script>");
    try w.writeAll(KICAD_MENU_JS);
    try w.writeAll(SCRIPT_CLOSE_TAG);

    // Pixi.js from CDN
    try w.writeAll("<script src=\"https://cdn.jsdelivr.net/npm/pixi.js@8.6.6/dist/pixi.min.js\"></script>");

    // Canvas viewer JS
    try w.writeAll("<script>");
    try w.writeAll(CANVAS_VIEWER_JS);
    try w.writeAll(SCRIPT_CLOSE_TAG);

    try w.writeAll("</body></html>");
    res.body = buf.items;
    res.content_type = .HTML;
    res.header("connection", "close");
}

const CANVAS_CSS = @embedFile("assets/canvas_page.css");

const CANVAS_VIEWER_JS = @import("canvas_viewer_js.zig").CANVAS_VIEWER_JS;

const KICAD_MENU_JS = @embedFile("assets/kicad_menu.js");
