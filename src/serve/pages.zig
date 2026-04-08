const std = @import("std");
const httpz = @import("httpz");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const render_svg = @import("../render_svg.zig");
const env_mod = @import("../eval/env.zig");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;
const bom_html = @import("bom_html.zig");
const assets_css = @import("assets_css.zig");
const assets_js = @import("assets_js.zig");
const library = @import("library.zig");

pub fn indexPage(ctx: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(ctx.allocator);

    try w.writeAll("<!DOCTYPE html><html><head><title>EDA Designs</title><link rel=\"stylesheet\" href=\"/style.css\"><style>");
    try w.writeAll(assets_css.NAVBAR_CSS);
    try w.writeAll("</style></head><body>");
    try assets_css.writeNavbar(w, "designs");
    try w.writeAll("<div style=\"max-width:960px;margin:0 auto;padding:2rem;\"><h1>Designs</h1><ul class=\"design-list\">");

    const src_path = try std.fmt.allocPrint(ctx.allocator, "{s}/src", .{ctx.project_dir});
    defer ctx.allocator.free(src_path);
    var dir = try std.fs.cwd().openDir(src_path, .{ .iterate = true });
    defer dir.close();
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".sexp")) {
            const design_name = entry.name[0 .. entry.name.len - 5];
            if (std.mem.eql(u8, design_name, "board")) continue;
            try w.print("<li><a href=\"/schematics/{s}\">{s}</a> <a href=\"/pcb/{s}\" style=\"color:#888;font-size:12px;margin-left:8px\">[PCB]</a></li>", .{ design_name, design_name, design_name });
        }
    }

    try w.writeAll("</ul></div></body></html>");
    res.body = buf.items;
    res.content_type = .HTML;
}

pub fn cssPage(_: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .CSS;
    res.body = assets_css.INDEX_CSS;
}

pub fn designPage(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
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

    var sym_cache = try bom_html.buildSymbolPinCache(ctx.allocator, ctx.project_dir);

    const svg = render_svg.renderSchematic(ctx.allocator, block) catch "";
    // Seed live cache
    serve_root.live_mutex.lock();
    serve_root.live_svg = svg;
    serve_root.live_mutex.unlock();

    // Build HTML
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(ctx.allocator);

    // Head with embedded CSS
    try w.print("<!DOCTYPE html><html><head><title>{s}</title><style>", .{block.name});
    try w.writeAll(assets_css.NAVBAR_CSS);
    try w.writeAll(assets_css.DESIGN_CSS);
    try w.writeAll("</style></head><body>");
    try assets_css.writeNavbar(w, "designs");

    // Page container
    try w.writeAll("<div class=\"page\" id=\"page\">");
    try w.print("<h1>{s} <a href=\"/canvas/{s}\" style=\"font-size:14px;color:#58a6ff;margin-left:12px\">Canvas View</a></h1>", .{ block.name, name });

    // Schematic
    try w.writeAll("<div class=\"schematic\"><div class=\"schematic-canvas\" id=\"schematic-canvas\">");
    try w.writeAll("<div class=\"canvas-controls\">");
    try w.writeAll("<div class=\"search-container\">");
    try w.writeAll("<input type=\"text\" id=\"search-input\" class=\"search-input\" placeholder=\"Search...\" autocomplete=\"off\">");
    try w.writeAll("<div class=\"search-results\" id=\"search-results\"></div>");
    try w.writeAll("</div>");
    try w.writeAll("<button class=\"canvas-btn\" id=\"edit-toggle\">Edit</button>");
    try w.writeAll("<button class=\"canvas-btn\" id=\"canvas-reset\">Reset</button>");
    try w.writeAll("<button class=\"canvas-btn\" id=\"nodes-toggle\">Nodes</button>");
    try w.writeAll("<button class=\"canvas-btn\" id=\"rebuild-btn\">Rebuild</button>");
    try w.writeAll("<button class=\"canvas-btn\" id=\"block-diagram-btn\">Block Diagram</button>");
    try w.writeAll("<button class=\"canvas-btn\" id=\"update-pcb\">Update PCB</button>");
    try w.writeAll("<label class=\"canvas-toggle\"><input type=\"checkbox\" id=\"short-nets-cb\"><span>Short nets</span></label>");
    try w.writeAll("</div>");
    try w.writeAll(svg);
    try w.writeAll("</div></div>");

    // Assertions
    if (eval.assertions.items.len > 0) {
        try w.writeAll("<div class=\"assertions\">");
        for (eval.assertions.items) |a| {
            if (a.passed) {
                try w.print("<div class=\"pass\">PASS: {s}</div>", .{a.message});
            } else {
                try w.print("<div class=\"fail\">FAIL: {s}</div>", .{a.message});
            }
        }
        try w.writeAll("</div>");
    }

    // Library warnings: missing footprints and 3D models
    {
        var missing_fp: std.ArrayListUnmanaged([]const u8) = .empty;
        var missing_model: std.ArrayListUnmanaged([]const u8) = .empty;
        var checked_fp = std.StringHashMap(void).init(ctx.allocator);
        var checked_model = std.StringHashMap(void).init(ctx.allocator);
        try bom_html.collectMissing(ctx.allocator, block, ctx.project_dir, &missing_fp, &missing_model, &checked_fp, &checked_model);
        if (missing_fp.items.len > 0 or missing_model.items.len > 0) {
            try w.writeAll("<div class=\"assertions\">");
            for (missing_fp.items) |fp| {
                try w.print("<div class=\"fail\">Missing footprint: {s}</div>", .{fp});
            }
            for (missing_model.items) |comp| {
                try w.print("<div class=\"warn\">Missing 3D model: {s}</div>", .{comp});
            }
            try w.writeAll("</div>");
        }
    }

    // BOM table
    try bom_html.writeBomHtml(w, block);

    // Close page div
    try w.writeAll("</div>");

    // Sidebar
    try w.writeAll("<div class=\"sidebar\" id=\"sidebar\">");
    try w.writeAll("<button class=\"sidebar-close\" id=\"sidebar-close\">&times;</button>");
    try w.writeAll("<div id=\"sidebar-content\"></div>");
    try w.writeAll("</div>");

    // Generate COMPONENTS JSON
    try w.print("<script>var SCHEMATIC_SLUG='{s}';var COMPONENTS={{", .{name});
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

    // Interaction JS
    try w.writeAll("<script>");
    try w.writeAll(assets_js.INTERACTION_JS_PART1);
    // Inject design name for live updates
    try w.print("var DESIGN_NAME='{s}';", .{name});
    try w.writeAll(assets_js.INTERACTION_JS_PART2);
    try w.writeAll("</script>");

    try w.writeAll("</body></html>");
    res.body = buf.items;
    res.content_type = .HTML;
}
