const std = @import("std");
const httpz = @import("httpz");
const Evaluator = @import("eval/evaluator.zig").Evaluator;
const emit = @import("emit.zig");
const render_svg = @import("render_svg.zig");
const render_block = @import("render_block.zig");
const env_mod = @import("eval/env.zig");
const export_kicad = @import("export_kicad.zig");
const bom = @import("bom.zig");

// ── Global live state ──────────────────────────────────────────────────

var live_mutex: std.Thread.Mutex = .{};
var live_version: u32 = 0;
var live_svg: ?[]const u8 = null;

// ── Layout storage (in-memory) ─────────────────────────────────────────

var layout_mutex: std.Thread.Mutex = .{};
var layout_data: ?[]const u8 = null;

// ── Server ─────────────────────────────────────────────────────────────

const Handler = struct {
    allocator: std.mem.Allocator,
    project_dir: []const u8,

    pub fn notFound(_: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
        res.status = 404;
        res.body = "Not found";
    }
};

pub fn serve(allocator: std.mem.Allocator, port: u16, project_dir: []const u8) !void {
    var handler = Handler{ .allocator = allocator, .project_dir = project_dir };
    var server = try httpz.Server(*Handler).init(allocator, .{
        .address = .all(port),
        .request = .{
            .max_body_size = 10 * 1024 * 1024,
            .buffer_size = 256 * 1024,
            .max_header_count = 64,
        },
        .response = .{ .max_header_count = 32 },
        .workers = .{
            .large_buffer_size = 10 * 1024 * 1024,
        },
    }, &handler);
    const router = try server.router(.{});

    router.get("/", indexPage, .{});
    router.get("/style.css", cssPage, .{});
    router.get("/schematics/:name", designPage, .{});
    router.post("/api/push/:name", pushApi, .{});
    router.get("/api/version/:name", versionApi, .{});
    router.get("/api/svg/:name", svgApi, .{});
    router.get("/schematics/:name/layout", layoutGetApi, .{});
    router.post("/schematics/:name/layout", layoutPostApi, .{});
    router.post("/api/edit-value/:name", editValueApi, .{});
    router.post("/api/edit-footprint/:name", editFootprintApi, .{});
    router.get("/library", libraryPage, .{});
    router.post("/api/upload-package", uploadPackageApi, .{});
    router.get("/api/footprint/:name", footprintSvgApi, .{});
    router.post("/api/upload-zip", uploadZipApi, .{});
    router.get("/api/export-kicad/:name", exportKicadApi, .{});
    router.get("/api/export-netlist/:name", exportNetlistApi, .{});
    router.get("/api/block-diagram/:name", blockDiagramApi, .{});

    std.debug.print("Listening on http://localhost:{d}\n", .{port});
    std.debug.print("Project: {s}\n", .{project_dir});
    try server.listen();
}

// ── Routes ─────────────────────────────────────────────────────────────

fn indexPage(ctx: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(ctx.allocator);

    try w.writeAll("<!DOCTYPE html><html><head><title>EDA Designs</title><link rel=\"stylesheet\" href=\"/style.css\"></head><body><h1>Designs</h1><p><a href=\"/library\" style=\"color:#4a9;\">\xe2\x86\x92 Component Library (upload KiCad files)</a></p><ul class=\"design-list\">");

    const src_path = try std.fmt.allocPrint(ctx.allocator, "{s}/src", .{ctx.project_dir});
    defer ctx.allocator.free(src_path);
    var dir = try std.fs.cwd().openDir(src_path, .{ .iterate = true });
    defer dir.close();
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".sexp")) {
            const design_name = entry.name[0 .. entry.name.len - 5];
            if (std.mem.eql(u8, design_name, "board")) continue;
            try w.print("<li><a href=\"/schematics/{s}\">{s}</a></li>", .{ design_name, design_name });
        }
    }

    try w.writeAll("</ul></body></html>");
    res.body = buf.items;
    res.content_type = .HTML;
}

fn cssPage(_: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    res.content_type = .CSS;
    res.body = INDEX_CSS;
}

fn designPage(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
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

    var sym_cache = try buildSymbolPinCache(ctx.allocator, ctx.project_dir);

    const svg = render_svg.renderSchematic(ctx.allocator, block) catch "";
    // Seed live cache
    live_mutex.lock();
    live_svg = svg;
    live_mutex.unlock();

    // Build HTML
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(ctx.allocator);

    // Head with embedded CSS
    try w.print("<!DOCTYPE html><html><head><title>{s}</title><style>", .{block.name});
    try w.writeAll(DESIGN_CSS);
    try w.writeAll("</style></head><body>");

    // Page container
    try w.writeAll("<div class=\"page\" id=\"page\">");
    try w.print("<nav><a href=\"/\">&larr; All designs</a></nav>", .{});
    try w.print("<h1>{s}</h1>", .{block.name});

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
    try w.writeAll("<button class=\"canvas-btn\" id=\"export-kicad\">Export KiCad</button>");
    try w.writeAll("<button class=\"canvas-btn\" id=\"export-netlist\">Netlist</button>");
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
        try collectMissing(ctx.allocator, block, ctx.project_dir, &missing_fp, &missing_model, &checked_fp, &checked_model);
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
    try writeBomHtml(w, block);

    // Close page div
    try w.writeAll("</div>");

    // Sidebar
    try w.writeAll("<div class=\"sidebar\" id=\"sidebar\">");
    try w.writeAll("<button class=\"sidebar-close\" id=\"sidebar-close\">&times;</button>");
    try w.writeAll("<div id=\"sidebar-content\"></div>");
    try w.writeAll("</div>");

    // Generate COMPONENTS JSON
    try w.print("<script>var SCHEMATIC_SLUG='{s}';var COMPONENTS={{", .{name});
    _ = try writeComponentsJson(w, block, "", &sym_cache, ctx.allocator, ctx.project_dir);
    try w.writeAll("};var NETS={");
    _ = try writeNetsJson(w, block, "");
    try w.writeAll("};var SECTIONS=[");
    for (block.sections, 0..) |sec, si| {
        if (si > 0) try w.writeAll(",");
        try w.print("\"{s}\"", .{sec.name});
    }
    try w.writeAll("];var FAMILIES={");
    try writeFamiliesJson(w, ctx.allocator, ctx.project_dir);
    try w.writeAll("};</script>");

    // Interaction JS
    try w.writeAll("<script>");
    try w.writeAll(INTERACTION_JS_PART1);
    // Inject design name for live updates
    try w.print("var DESIGN_NAME='{s}';", .{name});
    try w.writeAll(INTERACTION_JS_PART2);
    try w.writeAll("</script>");

    try w.writeAll("</body></html>");
    res.body = buf.items;
    res.content_type = .HTML;
}

fn pushApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
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

    const new_svg = render_svg.renderSchematic(ctx.allocator, block) catch {
        res.status = 500;
        res.body = "Render error";
        return;
    };

    live_mutex.lock();
    live_svg = new_svg;
    live_version += 1;
    const v = live_version;
    live_mutex.unlock();

    std.debug.print("Pushed {s} (v{d})\n", .{ name, v });
    res.body = "ok";
}

fn versionApi(_: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    live_mutex.lock();
    const v = live_version;
    live_mutex.unlock();

    res.content_type = .JSON;
    res.header("access-control-allow-origin", "*");
    const w = res.writer();
    try w.print("{{\"version\":{d}}}", .{v});
}

fn svgApi(_: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    live_mutex.lock();
    const new_svg = live_svg;
    live_mutex.unlock();

    res.content_type = .SVG;
    res.header("access-control-allow-origin", "*");
    res.body = new_svg orelse "<!-- no svg -->";
}

fn blockDiagramApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
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

    const svg = render_block.renderBlockDiagram(ctx.allocator, block) catch {
        res.status = 500;
        res.body = "Render error";
        return;
    };

    res.content_type = .SVG;
    res.header("access-control-allow-origin", "*");
    res.body = svg;
}

fn layoutGetApi(_: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    layout_mutex.lock();
    const data = layout_data;
    layout_mutex.unlock();

    res.content_type = .JSON;
    res.header("access-control-allow-origin", "*");
    res.body = data orelse "{}";
}

fn layoutPostApi(_: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const body = req.body() orelse "{}";

    layout_mutex.lock();
    layout_data = body;
    layout_mutex.unlock();

    res.content_type = .JSON;
    res.header("access-control-allow-origin", "*");
    res.body = "{\"ok\":true}";
}

fn exportKicadApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
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

    bom.applyBomUuids(ctx.allocator, block, ctx.project_dir, name) catch {};

    const zip_data = export_kicad.exportKicadZip(ctx.allocator, block, ctx.project_dir, name) catch {
        res.status = 500;
        res.body = "Export error";
        return;
    };

    const disposition = std.fmt.allocPrint(ctx.allocator, "attachment; filename=\"{s}-kicad.zip\"", .{name}) catch {
        res.status = 500;
        return;
    };
    // Don't defer free — httpz needs the strings alive until response is sent

    res.header("Content-Type", "application/zip");
    res.header("Content-Disposition", disposition);
    res.body = zip_data;
}

fn exportNetlistApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
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

    // UUIDs come from .bom file — run `eda build --push <name>` first to populate
    bom.applyBomUuids(ctx.allocator, block, ctx.project_dir, name) catch {};

    const netlist = export_kicad.exportNetlistOnly(ctx.allocator, block, ctx.project_dir, name) catch {
        res.status = 500;
        res.body = "Export error";
        return;
    };

    const disposition = std.fmt.allocPrint(ctx.allocator, "attachment; filename=\"{s}.net\"", .{name}) catch {
        res.status = 500;
        return;
    };

    res.header("Content-Type", "text/plain");
    res.header("Content-Disposition", disposition);
    res.body = netlist;
}

fn editValueApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const body = req.body() orelse {
        res.status = 400;
        res.body = "no body";
        return;
    };

    // Parse JSON: {"ref": "C3", "value": "0.5pF"}
    const ref_start = std.mem.indexOf(u8, body, "\"ref\":\"") orelse {
        res.status = 400;
        res.body = "missing ref";
        return;
    };
    const ref_val_start = ref_start + 7; // length of "ref":"
    const ref_end = std.mem.indexOfPos(u8, body, ref_val_start, "\"") orelse {
        res.status = 400;
        return;
    };
    const ref_des = body[ref_val_start..ref_end];

    const val_start_marker = std.mem.indexOf(u8, body, "\"value\":\"") orelse {
        res.status = 400;
        res.body = "missing value";
        return;
    };
    const val_start = val_start_marker + 9;
    const val_end = std.mem.indexOfPos(u8, body, val_start, "\"") orelse {
        res.status = 400;
        return;
    };
    const new_value = body[val_start..val_end];

    // Read the .sexp file
    const file_path = std.fmt.allocPrint(ctx.allocator, "{s}/src/{s}.sexp", .{ ctx.project_dir, name }) catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(file_path);

    const source = std.fs.cwd().readFileAlloc(ctx.allocator, file_path, 10 * 1024 * 1024) catch {
        res.status = 500;
        res.body = "cannot read file";
        return;
    };
    defer ctx.allocator.free(source);

    // Find the instance line and replace the value
    // Look for: (instance "REF" (family "OLD_VALUE")  or  (instance "REF" (family "OLD_VALUE")
    const needle = std.fmt.allocPrint(ctx.allocator, "(instance \"{s}\" (", .{ref_des}) catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(needle);

    const inst_pos = std.mem.indexOf(u8, source, needle) orelse {
        res.status = 404;
        res.body = "instance not found";
        return;
    };

    // Find the value string: the quoted string after the family name
    // Pattern: (instance "REF" (family-name "VALUE")
    // Find the opening quote of the value after the family name
    const after_inst = inst_pos + needle.len;
    // Skip the family name atom (non-space, non-quote chars)
    var pos = after_inst;
    while (pos < source.len and source[pos] != '"' and source[pos] != ')') : (pos += 1) {}

    if (pos >= source.len or source[pos] != '"') {
        res.status = 400;
        res.body = "cannot find value in instance";
        return;
    }

    // pos is at opening quote of value
    const old_val_start = pos + 1;
    const old_val_end_pos = std.mem.indexOfPos(u8, source, old_val_start, "\"") orelse {
        res.status = 400;
        return;
    };

    // Build new source: before + new_value + after
    var new_source: std.ArrayListUnmanaged(u8) = .empty;
    const nw = new_source.writer(ctx.allocator);
    try nw.writeAll(source[0..old_val_start]);
    try nw.writeAll(new_value);
    try nw.writeAll(source[old_val_end_pos..]);

    // Write back
    const file = std.fs.cwd().createFile(file_path, .{}) catch {
        res.status = 500;
        res.body = "cannot write file";
        return;
    };
    defer file.close();
    file.writeAll(new_source.items) catch {
        res.status = 500;
        return;
    };

    std.debug.print("Edited {s} {s} -> \"{s}\"\n", .{ name, ref_des, new_value });

    // Rebuild and push live update
    const board_path = std.fmt.allocPrint(ctx.allocator, "{s}/src/{s}.sexp", .{ ctx.project_dir, name }) catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(board_path);

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();
    const result = eval.evalFile(board_path) catch {
        res.status = 500;
        res.body = "rebuild failed";
        return;
    };
    const block = switch (result) {
        .design_block => |b| b,
        else => {
            res.status = 500;
            return;
        },
    };
    const svg = render_svg.renderSchematic(ctx.allocator, block) catch {
        res.status = 500;
        return;
    };

    live_mutex.lock();
    live_svg = svg;
    live_version += 1;
    live_mutex.unlock();

    res.header("access-control-allow-origin", "*");
    res.content_type = .JSON;
    res.body = "{\"ok\":true}";
}

fn editFootprintApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const body = req.body() orelse {
        res.status = 400;
        res.body = "no body";
        return;
    };

    // Parse JSON: {"ref": "C3", "component": "cap-0603", "oldComponent": "cap-0805", "srcOff": 1234}
    const comp_start_marker = std.mem.indexOf(u8, body, "\"component\":\"") orelse {
        res.status = 400;
        res.body = "missing component";
        return;
    };
    const comp_start = comp_start_marker + 13;
    const comp_end = std.mem.indexOfPos(u8, body, comp_start, "\"") orelse {
        res.status = 400;
        return;
    };
    const new_component = body[comp_start..comp_end];

    const old_comp_marker = std.mem.indexOf(u8, body, "\"oldComponent\":\"") orelse {
        res.status = 400;
        res.body = "missing oldComponent";
        return;
    };
    const old_comp_start = old_comp_marker + 16;
    const old_comp_end = std.mem.indexOfPos(u8, body, old_comp_start, "\"") orelse {
        res.status = 400;
        return;
    };
    const old_component = body[old_comp_start..old_comp_end];

    const src_off_marker = std.mem.indexOf(u8, body, "\"srcOff\":") orelse {
        res.status = 400;
        res.body = "missing srcOff";
        return;
    };
    const src_off_num_start = src_off_marker + 9;
    var src_off_num_end = src_off_num_start;
    while (src_off_num_end < body.len and body[src_off_num_end] >= '0' and body[src_off_num_end] <= '9') : (src_off_num_end += 1) {}
    const source_offset = std.fmt.parseInt(usize, body[src_off_num_start..src_off_num_end], 10) catch {
        res.status = 400;
        res.body = "invalid srcOff";
        return;
    };

    // Verify the new component family exists
    const comp_path = std.fmt.allocPrint(ctx.allocator, "{s}/lib/components/{s}.sexp", .{ ctx.project_dir, new_component }) catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(comp_path);
    std.fs.cwd().access(comp_path, .{}) catch {
        res.status = 400;
        res.body = "component family not found";
        return;
    };

    // Read the .sexp file
    const file_path = std.fmt.allocPrint(ctx.allocator, "{s}/src/{s}.sexp", .{ ctx.project_dir, name }) catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(file_path);

    const source = std.fs.cwd().readFileAlloc(ctx.allocator, file_path, 10 * 1024 * 1024) catch {
        res.status = 500;
        res.body = "cannot read file";
        return;
    };
    defer ctx.allocator.free(source);

    // Verify the old component name is at the expected source offset
    if (source_offset + old_component.len > source.len or
        !std.mem.eql(u8, source[source_offset .. source_offset + old_component.len], old_component))
    {
        res.status = 400;
        res.body = "source offset mismatch — file may have changed";
        return;
    }

    // Build new source: replace family name at the exact offset
    var new_source: std.ArrayListUnmanaged(u8) = .empty;
    const nw = new_source.writer(ctx.allocator);
    try nw.writeAll(source[0..source_offset]);
    try nw.writeAll(new_component);
    try nw.writeAll(source[source_offset + old_component.len ..]);

    // Ensure new component is in the import statement
    var final_source = new_source.items;
    if (std.mem.indexOf(u8, final_source, "(import ")) |import_start| {
        // Find matching closing paren for the import
        var depth: u32 = 0;
        var import_end: usize = import_start;
        for (final_source[import_start..], 0..) |ch, i| {
            if (ch == '(') depth += 1;
            if (ch == ')') {
                depth -= 1;
                if (depth == 0) {
                    import_end = import_start + i;
                    break;
                }
            }
        }
        const import_section = final_source[import_start..import_end];
        // Check if new_component appears as a whole word in the import
        const found_in_import = blk: {
            var search_from: usize = 0;
            while (std.mem.indexOfPos(u8, import_section, search_from, new_component)) |pos| {
                const before_ok = pos == 0 or import_section[pos - 1] == ' ' or import_section[pos - 1] == '\n';
                const after_pos = pos + new_component.len;
                const after_ok = after_pos >= import_section.len or import_section[after_pos] == ' ' or import_section[after_pos] == '\n' or import_section[after_pos] == ')';
                if (before_ok and after_ok) break :blk true;
                search_from = pos + 1;
            }
            break :blk false;
        };
        if (!found_in_import) {
            // Insert new component before the closing paren of import
            var new_final: std.ArrayListUnmanaged(u8) = .empty;
            const nfw = new_final.writer(ctx.allocator);
            try nfw.writeAll(final_source[0..import_end]);
            try nfw.writeAll(" ");
            try nfw.writeAll(new_component);
            try nfw.writeAll(final_source[import_end..]);
            final_source = new_final.items;
        }
    }

    // Write back
    const file = std.fs.cwd().createFile(file_path, .{}) catch {
        res.status = 500;
        res.body = "cannot write file";
        return;
    };
    defer file.close();
    file.writeAll(final_source) catch {
        res.status = 500;
        return;
    };

    std.debug.print("Edited footprint {s} {s} -> \"{s}\"\n", .{ name, old_component, new_component });

    // Rebuild and push live update
    const board_path = std.fmt.allocPrint(ctx.allocator, "{s}/src/{s}.sexp", .{ ctx.project_dir, name }) catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(board_path);

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();
    const result = eval.evalFile(board_path) catch {
        res.status = 500;
        res.body = "rebuild failed";
        return;
    };
    const block = switch (result) {
        .design_block => |b| b,
        else => {
            res.status = 500;
            return;
        },
    };
    var svg_sym_cache = try buildSymbolPinCache(ctx.allocator, ctx.project_dir);

    const svg = render_svg.renderSchematic(ctx.allocator, block) catch {
        res.status = 500;
        return;
    };

    live_mutex.lock();
    live_svg = svg;
    live_version += 1;
    live_mutex.unlock();

    // Return updated COMPONENTS so the client can refresh srcOff values
    var comp_json: std.ArrayListUnmanaged(u8) = .empty;
    const cw = comp_json.writer(ctx.allocator);
    try cw.writeAll("{\"ok\":true,\"components\":{");
    _ = try writeComponentsJson(cw, block, "", &svg_sym_cache, ctx.allocator, ctx.project_dir);
    try cw.writeAll("}}");

    res.header("access-control-allow-origin", "*");
    res.content_type = .JSON;
    res.body = comp_json.items;
}

/// Scan lib/components/ for passive families and write a JSON object
/// mapping type prefixes (cap, res, ind, led) to arrays of family names.
fn writeFamiliesJson(w: anytype, allocator: std.mem.Allocator, project_dir: []const u8) !void {
    const comp_dir_path = try std.fmt.allocPrint(allocator, "{s}/lib/components", .{project_dir});
    defer allocator.free(comp_dir_path);

    var dir = std.fs.cwd().openDir(comp_dir_path, .{ .iterate = true }) catch return;
    defer dir.close();

    // Collect families by prefix
    const prefixes = [_][]const u8{ "cap", "res", "ind", "led" };
    var lists: [4]std.ArrayListUnmanaged([]const u8) = .{ .empty, .empty, .empty, .empty };

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        const fname = entry.name;
        if (!std.mem.endsWith(u8, fname, ".sexp")) continue;
        const base = fname[0 .. fname.len - 5]; // strip .sexp
        for (prefixes, 0..) |pfx, pi| {
            if (std.mem.startsWith(u8, base, pfx) and base.len > pfx.len and base[pfx.len] == '-') {
                try lists[pi].append(allocator, try allocator.dupe(u8, base));
                break;
            }
        }
    }

    var first_prefix = true;
    for (prefixes, 0..) |pfx, pi| {
        if (lists[pi].items.len == 0) continue;
        if (!first_prefix) try w.writeAll(",");
        first_prefix = false;
        try w.writeAll("\"");
        try w.writeAll(pfx);
        try w.writeAll("\":[");
        // Sort for consistent UI ordering
        std.mem.sort([]const u8, lists[pi].items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.order(u8, a, b) == .lt;
            }
        }.lessThan);
        for (lists[pi].items, 0..) |fam, fi| {
            if (fi > 0) try w.writeAll(",");
            try w.writeAll("\"");
            try w.writeAll(fam);
            try w.writeAll("\"");
        }
        try w.writeAll("]");
    }
}

fn libraryPage(ctx: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(ctx.allocator);

    try w.writeAll(
        \\<!DOCTYPE html><html><head><title>Component Library</title><style>
        \\body { font-family: system-ui, sans-serif; margin: 0; padding: 2rem; color: #e0e0e0; background: #121212; max-width: 900px; margin: 0 auto; }
        \\h1,h2,h3 { color: #fff; }
        \\a { color: #58a6ff; text-decoration: none; }
        \\.upload-box { background: #1a1a2e; border: 2px dashed #333; border-radius: 8px; padding: 2rem; margin: 1rem 0; text-align: center; }
        \\.upload-box.dragover { border-color: #4a9eff; background: #16213e; }
        \\.upload-box input[type=file] { display: none; }
        \\.upload-btn { background: #2a4a2a; color: #4a9; border: 1px solid #4a9; border-radius: 4px; padding: 0.5rem 1.5rem; font-size: 0.9rem; cursor: pointer; }
        \\.upload-btn:hover { background: #3a5a3a; }
        \\.result { margin: 1rem 0; padding: 1rem; border-radius: 6px; font-family: monospace; font-size: 0.85rem; white-space: pre-wrap; overflow-x: auto; }
        \\.result.ok { background: #1a2e1a; border: 1px solid #3fb950; color: #3fb950; }
        \\.result.err { background: #2e1a1a; border: 1px solid #f85149; color: #f85149; }
        \\.lib-list { list-style: none; padding: 0; }
        \\.lib-list li { padding: 0.4rem 0.75rem; border-bottom: 1px solid #21262d; font-family: monospace; font-size: 0.9rem; }
        \\table { width: 100%; border-collapse: collapse; margin: 1rem 0; }
        \\th,td { text-align: left; padding: 0.4rem 0.75rem; border-bottom: 1px solid #21262d; }
        \\th { background: #1a1a2e; color: #888; font-size: 0.85rem; text-transform: uppercase; }
        \\td { font-family: monospace; font-size: 0.9rem; }
        \\</style></head><body>
        \\<p><a href="/">&larr; Designs</a></p>
        \\<h1>Component Library</h1>
    );

    // Upload section
    try w.writeAll(
        \\<h2>Create Package</h2>
        \\<div class="upload-box" id="zip-drop" style="margin-bottom:1rem;">
        \\<p style="font-size:0.85rem;">Drop a component .zip (auto-extracts KiCad symbol, footprint, and 3D model)</p>
        \\<label class="upload-btn">Choose .zip<input type="file" id="zip-file" accept=".zip"></label>
        \\<div id="zip-name" style="color:#4a9;font-size:0.8rem;margin-top:0.5rem;"></div>
        \\</div>
        \\<div id="zip-result"></div>
        \\<details style="margin-bottom:1rem;"><summary style="color:#666;font-size:0.85rem;cursor:pointer;">Or upload files individually</summary>
        \\<div style="display:flex;gap:1rem;margin:1rem 0;">
        \\<div class="upload-box" id="sym-drop" style="flex:1;">
        \\<p style="font-size:0.85rem;">Symbol (.kicad_sym)</p>
        \\<label class="upload-btn">Choose file<input type="file" id="sym-file" accept=".kicad_sym"></label>
        \\<div id="sym-name" style="color:#4a9;font-size:0.8rem;margin-top:0.5rem;"></div>
        \\</div>
        \\<div class="upload-box" id="fp-drop" style="flex:1;">
        \\<p style="font-size:0.85rem;">Footprint (.kicad_mod)</p>
        \\<label class="upload-btn">Choose file<input type="file" id="fp-file" accept=".kicad_mod"></label>
        \\<div id="fp-name" style="color:#4a9;font-size:0.8rem;margin-top:0.5rem;"></div>
        \\</div>
        \\<div class="upload-box" id="step-drop" style="flex:1;">
        \\<p style="font-size:0.85rem;">3D Model (.step) <span style="color:#666;">optional</span></p>
        \\<label class="upload-btn">Choose file<input type="file" id="step-file" accept=".step,.stp"></label>
        \\<div id="step-name" style="color:#4a9;font-size:0.8rem;margin-top:0.5rem;"></div>
        \\</div>
        \\</div>
        \\<div style="margin-bottom:1rem;">
        \\<button id="pkg-submit" class="upload-btn" disabled style="opacity:0.5;">Create Package</button>
        \\</div>
        \\<div id="pkg-result"></div>
        \\</details>
    );

    // List existing pinouts
    try w.writeAll("<h2>Pinouts</h2><table><tr><th>Name</th><th>Pins</th></tr>");
    {
        const pinout_path = try std.fmt.allocPrint(ctx.allocator, "{s}/lib/pinouts", .{ctx.project_dir});
        defer ctx.allocator.free(pinout_path);
        var dir = std.fs.cwd().openDir(pinout_path, .{ .iterate = true }) catch {
            try w.writeAll("<tr><td colspan=\"2\">No pinouts yet</td></tr>");
            try w.writeAll("</table>");
            try listFootprints(w, ctx);
            try w.writeAll("</body></html>");
            res.body = buf.items;
            res.content_type = .HTML;
            return;
        };
        defer dir.close();
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".sexp")) {
                const lname = entry.name[0 .. entry.name.len - 5];
                const content = dir.readFileAlloc(ctx.allocator, entry.name, 256 * 1024) catch continue;
                var pin_count: usize = 0;
                var pos: usize = 0;
                while (std.mem.indexOfPos(u8, content, pos, "(pin ")) |idx| {
                    pin_count += 1;
                    pos = idx + 5;
                }
                try w.print("<tr><td>{s}</td><td>{d}</td></tr>", .{ lname, pin_count });
            }
        }
    }
    try w.writeAll("</table>");
    try listFootprints(w, ctx);

    // Upload JS — combined symbol + footprint → package
    try w.writeAll(
        \\<script>
        \\var symData=null,fpData=null,stepData=null,symFilename='',fpFilename='',stepFilename='';
        \\function setupDrop(dropId,fileId,nameId,ext,onFile){
        \\  var drop=document.getElementById(dropId),fi=document.getElementById(fileId),nd=document.getElementById(nameId);
        \\  drop.addEventListener('dragover',function(e){e.preventDefault();drop.classList.add('dragover');});
        \\  drop.addEventListener('dragleave',function(){drop.classList.remove('dragover');});
        \\  drop.addEventListener('drop',function(e){e.preventDefault();drop.classList.remove('dragover');if(e.dataTransfer.files.length>0)loadFile(e.dataTransfer.files[0]);});
        \\  fi.addEventListener('change',function(){if(this.files.length>0)loadFile(this.files[0]);});
        \\  function loadFile(f){
        \\    nd.textContent=f.name;
        \\    var r=new FileReader();r.onload=function(){onFile(f.name,r.result);checkReady();};r.readAsArrayBuffer(f);
        \\  }
        \\}
        \\setupDrop('sym-drop','sym-file','sym-name','.kicad_sym',function(n,d){symFilename=n;symData=d;});
        \\setupDrop('fp-drop','fp-file','fp-name','.kicad_mod',function(n,d){fpFilename=n;fpData=d;});
        \\setupDrop('step-drop','step-file','step-name','.step',function(n,d){stepFilename=n;stepData=d;});
        \\var submitBtn=document.getElementById('pkg-submit'),pkgResult=document.getElementById('pkg-result');
        \\function checkReady(){
        \\  var ready=symData&&fpData;
        \\  submitBtn.disabled=!ready;submitBtn.style.opacity=ready?'1':'0.5';
        \\}
        \\submitBtn.addEventListener('click',function(){
        \\  if(!symData||!fpData)return;
        \\  submitBtn.disabled=true;submitBtn.textContent='Creating...';
        \\  pkgResult.className='result';pkgResult.textContent='Uploading and converting...';
        \\  var formData=new FormData();
        \\  formData.append('symbol',new Blob([symData]),symFilename);
        \\  formData.append('footprint',new Blob([fpData]),fpFilename);
        \\  if(stepData)formData.append('step',new Blob([stepData]),stepFilename);
        \\  fetch('/api/upload-package',{method:'POST',body:formData})
        \\    .then(function(r){return r.text().then(function(t){return{ok:r.ok,text:t};});})
        \\    .then(function(d){pkgResult.className=d.ok?'result ok':'result err';pkgResult.textContent=d.text;submitBtn.textContent='Create Package';submitBtn.disabled=false;if(d.ok)setTimeout(function(){location.reload();},1000);})
        \\    .catch(function(e){pkgResult.className='result err';pkgResult.textContent='Error: '+e;submitBtn.textContent='Create Package';submitBtn.disabled=false;});
        \\});
        \\/* Zip upload */
        \\var zipDrop=document.getElementById('zip-drop'),zipFile=document.getElementById('zip-file'),zipName=document.getElementById('zip-name'),zipResult=document.getElementById('zip-result');
        \\zipDrop.addEventListener('dragover',function(e){e.preventDefault();zipDrop.classList.add('dragover');});
        \\zipDrop.addEventListener('dragleave',function(){zipDrop.classList.remove('dragover');});
        \\zipDrop.addEventListener('drop',function(e){e.preventDefault();zipDrop.classList.remove('dragover');if(e.dataTransfer.files.length>0)uploadZip(e.dataTransfer.files[0]);});
        \\zipFile.addEventListener('change',function(){if(this.files.length>0)uploadZip(this.files[0]);});
        \\function uploadZip(file){
        \\  zipName.textContent=file.name;
        \\  zipResult.className='result';zipResult.textContent='Extracting and converting '+file.name+'...';
        \\  var r=new FileReader();r.onload=function(){
        \\    fetch('/api/upload-zip',{method:'POST',headers:{'Content-Type':'application/octet-stream','X-Filename':file.name},body:r.result})
        \\      .then(function(r){return r.text().then(function(t){return{ok:r.ok,text:t};});})
        \\      .then(function(d){zipResult.className=d.ok?'result ok':'result err';zipResult.textContent=d.text;if(d.ok)setTimeout(function(){location.reload();},1500);})
        \\      .catch(function(e){zipResult.className='result err';zipResult.textContent='Error: '+e;});
        \\  };r.readAsArrayBuffer(file);
        \\}
        \\</script>
    );

    try w.writeAll("</body></html>");
    res.body = buf.items;
    res.content_type = .HTML;
}

fn uploadZipApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const body = req.body() orelse {
        res.status = 400;
        res.body = "No data";
        return;
    };
    const filename = req.header("x-filename") orelse "upload.zip";

    // Save zip to temp location
    const tmp_zip = std.fmt.allocPrint(ctx.allocator, "/tmp/eda-upload-{s}", .{filename}) catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(tmp_zip);
    {
        const f = std.fs.cwd().createFile(tmp_zip, .{}) catch {
            res.status = 500;
            res.body = "Cannot write temp file";
            return;
        };
        defer f.close();
        f.writeAll(body) catch {
            res.status = 500;
            return;
        };
    }

    // Extract to temp dir
    const tmp_dir = std.fmt.allocPrint(ctx.allocator, "/tmp/eda-extract-{d}", .{std.time.milliTimestamp()}) catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(tmp_dir);

    // Run unzip
    const unzip_result = std.process.Child.run(.{
        .allocator = ctx.allocator,
        .argv = &.{ "unzip", "-o", "-q", tmp_zip, "-d", tmp_dir },
    }) catch {
        res.status = 500;
        res.body = "Failed to extract zip (is unzip installed?)";
        return;
    };
    if (unzip_result.term.Exited != 0) {
        res.status = 500;
        res.body = "Zip extraction failed";
        return;
    }

    // Recursively find .kicad_sym, .kicad_mod, .stp/.step files
    var sym_path: ?[]const u8 = null;
    var fp_path: ?[]const u8 = null;
    var step_path: ?[]const u8 = null;

    // Use find command to locate files
    const find_result = std.process.Child.run(.{
        .allocator = ctx.allocator,
        .argv = &.{ "find", tmp_dir, "-type", "f" },
    }) catch {
        res.status = 500;
        res.body = "Failed to scan extracted files";
        return;
    };

    var line_iter = std.mem.splitScalar(u8, find_result.stdout, '\n');
    while (line_iter.next()) |line| {
        if (line.len == 0) continue;
        if (std.mem.endsWith(u8, line, ".kicad_sym")) sym_path = line;
        if (std.mem.endsWith(u8, line, ".kicad_mod")) fp_path = line;
        if (std.mem.endsWith(u8, line, ".stp") or std.mem.endsWith(u8, line, ".step")) step_path = line;
    }

    if (sym_path == null or fp_path == null) {
        res.status = 400;
        const msg = std.fmt.allocPrint(ctx.allocator, "Zip must contain a .kicad_sym and .kicad_mod file (found sym={s}, fp={s})", .{
            if (sym_path) |s| s else "none",
            if (fp_path) |f| f else "none",
        }) catch "Missing KiCad files in zip";
        res.body = msg;
        return;
    }

    // Read the files
    const sym_data = std.fs.cwd().readFileAlloc(ctx.allocator, sym_path.?, 10 * 1024 * 1024) catch {
        res.status = 500;
        res.body = "Cannot read symbol from zip";
        return;
    };
    const fp_data = std.fs.cwd().readFileAlloc(ctx.allocator, fp_path.?, 10 * 1024 * 1024) catch {
        res.status = 500;
        res.body = "Cannot read footprint from zip";
        return;
    };
    const step_data: ?[]const u8 = if (step_path) |sp|
        (std.fs.cwd().readFileAlloc(ctx.allocator, sp, 50 * 1024 * 1024) catch null)
    else
        null;

    // Get filenames for saving sources
    const sym_basename = std.fs.path.basename(sym_path.?);
    const fp_basename = std.fs.path.basename(fp_path.?);

    // Extract package name from symbol
    const pkg_name = blk: {
        var search_pos: usize = 0;
        if (std.mem.indexOf(u8, sym_data, "(kicad_symbol_lib")) |_| {
            if (std.mem.indexOf(u8, sym_data, "\n  (symbol \"")) |idx| {
                search_pos = idx;
            }
        }
        if (std.mem.indexOfPos(u8, sym_data, search_pos, "(symbol \"")) |idx| {
            const name_start = idx + 9;
            if (std.mem.indexOfPos(u8, sym_data, name_start, "\"")) |name_end| {
                break :blk sym_data[name_start..name_end];
            }
        }
        break :blk "package";
    };

    // Save sources
    saveSourceFile(ctx.allocator, ctx.project_dir, sym_basename, sym_data);
    saveSourceFile(ctx.allocator, ctx.project_dir, fp_basename, fp_data);
    if (step_data != null and step_path != null) {
        saveSourceFile(ctx.allocator, ctx.project_dir, std.fs.path.basename(step_path.?), step_data.?);
    }

    // Generate pinout
    const symbol_conv = @import("convert/symbol.zig");
    const pinout = symbol_conv.generatePinout(ctx.allocator, sym_data, null) catch {
        res.status = 500;
        res.body = "Pinout generation failed";
        return;
    };

    // Generate footprint
    const footprint_conv = @import("convert/footprint.zig");
    const footprint = footprint_conv.convertFootprint(ctx.allocator, fp_data) catch {
        res.status = 500;
        res.body = "Footprint conversion failed";
        return;
    };

    // Sanitize name
    var safe_name: std.ArrayListUnmanaged(u8) = .empty;
    for (pkg_name) |c| {
        const sc: u8 = switch (c) {
            'A'...'Z' => c + 32,
            ' ', '.', '_' => '-',
            else => c,
        };
        safe_name.append(ctx.allocator, sc) catch continue;
    }

    // Write pinout
    {
        const dir = std.fmt.allocPrint(ctx.allocator, "{s}/lib/pinouts", .{ctx.project_dir}) catch { res.status = 500; return; };
        std.fs.cwd().makePath(dir) catch {};
        const path = std.fmt.allocPrint(ctx.allocator, "{s}/{s}.sexp", .{ dir, safe_name.items }) catch { res.status = 500; return; };
        const f = std.fs.cwd().createFile(path, .{}) catch { res.status = 500; return; };
        defer f.close();
        f.writeAll(pinout) catch {};
    }

    // Write footprint
    {
        var fp_safe: std.ArrayListUnmanaged(u8) = .empty;
        if (std.mem.indexOf(u8, footprint, "(footprint \"")) |idx| {
            const ns = idx + 12;
            if (std.mem.indexOfPos(u8, footprint, ns, "\"")) |ne| {
                for (footprint[ns..ne]) |fc| {
                    const fsc: u8 = switch (fc) { 'A'...'Z' => fc + 32, ' ', '.', '_' => '-', else => fc };
                    fp_safe.append(ctx.allocator, fsc) catch continue;
                }
            }
        }
        const fp_name = if (fp_safe.items.len > 0) fp_safe.items else safe_name.items;
        const dir = std.fmt.allocPrint(ctx.allocator, "{s}/lib/footprints", .{ctx.project_dir}) catch { res.status = 500; return; };
        std.fs.cwd().makePath(dir) catch {};
        const path = std.fmt.allocPrint(ctx.allocator, "{s}/{s}.sexp", .{ dir, fp_name }) catch { res.status = 500; return; };
        const f = std.fs.cwd().createFile(path, .{}) catch { res.status = 500; return; };
        defer f.close();
        f.writeAll(footprint) catch {};
    }

    // Write STEP model
    if (step_data) |sd| {
        const dir = std.fmt.allocPrint(ctx.allocator, "{s}/lib/models", .{ctx.project_dir}) catch "";
        if (dir.len > 0) {
            std.fs.cwd().makePath(dir) catch {};
            const path = std.fmt.allocPrint(ctx.allocator, "{s}/{s}.step", .{ dir, safe_name.items }) catch "";
            if (path.len > 0) {
                const f = std.fs.cwd().createFile(path, .{}) catch null;
                if (f) |file| { defer file.close(); file.writeAll(sd) catch {}; }
            }
        }
    }

    // Clean up temp files
    std.fs.cwd().deleteFile(tmp_zip) catch {};
    _ = std.process.Child.run(.{
        .allocator = ctx.allocator,
        .argv = &.{ "rm", "-rf", tmp_dir },
    }) catch {};

    const step_msg: []const u8 = if (step_data != null) " + 3D model" else "";
    const msg = std.fmt.allocPrint(ctx.allocator, "Created pinout + footprint{s} for \"{s}\" (sources saved)", .{ step_msg, pkg_name }) catch {
        res.body = "OK";
        return;
    };
    std.debug.print("Zip upload: {s}\n", .{msg});
    res.body = msg;
}

fn footprintSvgApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };

    // Try to load footprint file
    const fp_path = std.fmt.allocPrint(ctx.allocator, "{s}/lib/footprints/{s}.sexp", .{ ctx.project_dir, name }) catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(fp_path);
    const content = std.fs.cwd().readFileAlloc(ctx.allocator, fp_path, 256 * 1024) catch {
        res.status = 404;
        res.body = "Footprint not found";
        return;
    };

    // Parse the footprint sexp
    const nodes = parser_mod.parse(ctx.allocator, content) catch {
        res.status = 500;
        res.body = "Parse error";
        return;
    };
    if (nodes.len == 0) {
        res.status = 500;
        return;
    }
    const top = nodes[0].asList() orelse {
        res.status = 500;
        return;
    };

    // Collect pads and silkscreen
    const Pad = struct { id: []const u8, x: f64, y: f64, w: f64, h: f64, shape: []const u8 };
    const Line = struct { x1: f64, y1: f64, x2: f64, y2: f64 };
    const Circle = struct { cx: f64, cy: f64, r: f64 };

    var pads: std.ArrayListUnmanaged(Pad) = .empty;
    var silk_lines: std.ArrayListUnmanaged(Line) = .empty;
    var silk_circles: std.ArrayListUnmanaged(Circle) = .empty;

    for (top[1..]) |child| {
        if (child.isForm("pad")) {
            const cl = child.asList() orelse continue;
            if (cl.len < 4) continue;
            const pid: ?[]const u8 = cl[1].asAtom() orelse if (cl[1].asNumber()) |n| (std.fmt.allocPrint(ctx.allocator, "{d}", .{@as(i64, @intFromFloat(n))}) catch null) else null;
            if (pid == null) continue;
            const pid_val = pid.?;
            var px: f64 = 0;
            var py: f64 = 0;
            var pw: f64 = 0;
            var ph: f64 = 0;
            const shape: []const u8 = cl[3].asAtom() orelse "rect";
            for (cl[4..]) |sub| {
                if (sub.isForm("pos")) {
                    const sl = sub.asList().?;
                    if (sl.len >= 3) { px = sl[1].asNumber() orelse 0; py = sl[2].asNumber() orelse 0; }
                }
                if (sub.isForm("size")) {
                    const sl = sub.asList().?;
                    if (sl.len >= 3) { pw = sl[1].asNumber() orelse 0; ph = sl[2].asNumber() orelse 0; }
                }
            }
            pads.append(ctx.allocator, .{ .id = pid_val, .x = px, .y = py, .w = pw, .h = ph, .shape = shape }) catch {};
        }
        if (child.isForm("silkscreen")) {
            const cl = child.asList() orelse continue;
            for (cl[1..]) |sub| {
                if (sub.isForm("line")) {
                    const sl = sub.asList() orelse continue;
                    if (sl.len >= 3) {
                        const p1 = sl[1].asList() orelse continue;
                        const p2 = sl[2].asList() orelse continue;
                        if (p1.len >= 2 and p2.len >= 2) {
                            silk_lines.append(ctx.allocator, .{
                                .x1 = p1[0].asNumber() orelse 0,
                                .y1 = p1[1].asNumber() orelse 0,
                                .x2 = p2[0].asNumber() orelse 0,
                                .y2 = p2[1].asNumber() orelse 0,
                            }) catch {};
                        }
                    }
                }
                if (sub.isForm("circle")) {
                    const sl = sub.asList() orelse continue;
                    if (sl.len >= 3) {
                        const center = sl[1].asList() orelse continue;
                        const radius = sl[2].asNumber() orelse 0;
                        if (center.len >= 2) {
                            silk_circles.append(ctx.allocator, .{
                                .cx = center[0].asNumber() orelse 0,
                                .cy = center[1].asNumber() orelse 0,
                                .r = radius,
                            }) catch {};
                        }
                    }
                }
            }
        }
    }

    // Compute bounding box
    var min_x: f64 = 999;
    var min_y: f64 = 999;
    var max_x: f64 = -999;
    var max_y: f64 = -999;
    for (pads.items) |p| {
        const lx = p.x - p.w / 2;
        const ly = p.y - p.h / 2;
        const rx = p.x + p.w / 2;
        const ry = p.y + p.h / 2;
        if (lx < min_x) min_x = lx;
        if (ly < min_y) min_y = ly;
        if (rx > max_x) max_x = rx;
        if (ry > max_y) max_y = ry;
    }
    for (silk_lines.items) |l| {
        if (l.x1 < min_x) min_x = l.x1;
        if (l.y1 < min_y) min_y = l.y1;
        if (l.x2 < min_x) min_x = l.x2;
        if (l.y2 < min_y) min_y = l.y2;
        if (l.x1 > max_x) max_x = l.x1;
        if (l.y1 > max_y) max_y = l.y1;
        if (l.x2 > max_x) max_x = l.x2;
        if (l.y2 > max_y) max_y = l.y2;
    }
    if (pads.items.len == 0 and silk_lines.items.len == 0) {
        res.status = 404;
        res.body = "Empty footprint";
        return;
    }

    const pad_f: f64 = 0.5;
    min_x -= pad_f;
    min_y -= pad_f;
    max_x += pad_f;
    max_y += pad_f;
    const vw = max_x - min_x;
    const vh = max_y - min_y;

    // Render SVG
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(ctx.allocator);

    try w.print("<svg xmlns=\"http://www.w3.org/2000/svg\" viewBox=\"{d:.2} {d:.2} {d:.2} {d:.2}\" style=\"background:#161b22;border-radius:4px;\">", .{ min_x, min_y, vw, vh });

    // Silkscreen lines
    for (silk_lines.items) |l| {
        try w.print("<line x1=\"{d:.3}\" y1=\"{d:.3}\" x2=\"{d:.3}\" y2=\"{d:.3}\" stroke=\"#555\" stroke-width=\"0.08\" stroke-linecap=\"round\"/>", .{ l.x1, l.y1, l.x2, l.y2 });
    }
    for (silk_circles.items) |c| {
        try w.print("<circle cx=\"{d:.3}\" cy=\"{d:.3}\" r=\"{d:.3}\" fill=\"none\" stroke=\"#555\" stroke-width=\"0.08\"/>", .{ c.cx, c.cy, c.r });
    }

    // Pads
    for (pads.items) |p| {
        if (std.mem.eql(u8, p.shape, "circle")) {
            const r = @min(p.w, p.h) / 2;
            try w.print("<circle cx=\"{d:.3}\" cy=\"{d:.3}\" r=\"{d:.3}\" fill=\"#c4a000\"/>", .{ p.x, p.y, r });
        } else if (std.mem.eql(u8, p.shape, "oval")) {
            const rx = p.w / 2;
            const ry = p.h / 2;
            try w.print("<rect x=\"{d:.3}\" y=\"{d:.3}\" width=\"{d:.3}\" height=\"{d:.3}\" rx=\"{d:.3}\" fill=\"#c4a000\"/>", .{ p.x - rx, p.y - ry, p.w, p.h, @min(rx, ry) });
        } else {
            // rect / roundrect
            try w.print("<rect x=\"{d:.3}\" y=\"{d:.3}\" width=\"{d:.3}\" height=\"{d:.3}\" rx=\"0.03\" fill=\"#c4a000\"/>", .{ p.x - p.w / 2, p.y - p.h / 2, p.w, p.h });
        }
    }

    try w.writeAll("</svg>");

    res.body = buf.toOwnedSlice(ctx.allocator) catch "";
    res.content_type = .HTML;
}

fn listFootprints(w: anytype, ctx: *Handler) !void {
    try w.writeAll("<h2>Footprints</h2><table><tr><th>Name</th><th>Size (mm)</th></tr>");
    const fp_path = try std.fmt.allocPrint(ctx.allocator, "{s}/lib/footprints", .{ctx.project_dir});
    defer ctx.allocator.free(fp_path);
    var dir = std.fs.cwd().openDir(fp_path, .{ .iterate = true }) catch {
        try w.writeAll("<tr><td colspan=\"2\">No footprints yet</td></tr></table>");
        return;
    };
    defer dir.close();
    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".sexp")) {
            const name = entry.name[0 .. entry.name.len - 5];
            const file_path = std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ fp_path, entry.name }) catch continue;
            defer ctx.allocator.free(file_path);
            const content = std.fs.cwd().readFileAlloc(ctx.allocator, file_path, 256 * 1024) catch {
                try w.print("<tr><td>{s}</td><td>-</td></tr>", .{name});
                continue;
            };
            const dims = footprintPadBounds(ctx.allocator, content);
            if (dims) |d| {
                try w.print("<tr><td>{s}</td><td>{d:.2} x {d:.2}</td></tr>", .{ name, d.w, d.h });
            } else {
                try w.print("<tr><td>{s}</td><td>-</td></tr>", .{name});
            }
        }
    }
    try w.writeAll("</table>");
}

fn footprintPadBounds(allocator: std.mem.Allocator, content: []const u8) ?struct { w: f64, h: f64 } {
    const nodes = parser_mod.parse(allocator, content) catch return null;
    if (nodes.len == 0) return null;
    const top = nodes[0].asList() orelse return null;
    var min_x: f64 = 999;
    var min_y: f64 = 999;
    var max_x: f64 = -999;
    var max_y: f64 = -999;
    var found = false;
    for (top[1..]) |child| {
        if (child.isForm("pad")) {
            const cl = child.asList() orelse continue;
            if (cl.len < 4) continue;
            var px: f64 = 0;
            var py: f64 = 0;
            var pw: f64 = 0;
            var ph: f64 = 0;
            for (cl[4..]) |sub| {
                if (sub.isForm("pos")) {
                    const sl = sub.asList().?;
                    if (sl.len >= 3) { px = sl[1].asNumber() orelse 0; py = sl[2].asNumber() orelse 0; }
                }
                if (sub.isForm("size")) {
                    const sl = sub.asList().?;
                    if (sl.len >= 3) { pw = sl[1].asNumber() orelse 0; ph = sl[2].asNumber() orelse 0; }
                }
            }
            const lx = px - pw / 2;
            const ly = py - ph / 2;
            const rx = px + pw / 2;
            const ry = py + ph / 2;
            if (lx < min_x) min_x = lx;
            if (ly < min_y) min_y = ly;
            if (rx > max_x) max_x = rx;
            if (ry > max_y) max_y = ry;
            found = true;
        }
    }
    if (!found) return null;
    return .{ .w = max_x - min_x, .h = max_y - min_y };
}

/// Save raw source file to lib/sources/ for future re-parsing.
fn saveSourceFile(allocator: std.mem.Allocator, project_dir: []const u8, filename: []const u8, body: []const u8) void {
    const dir_path = std.fmt.allocPrint(allocator, "{s}/lib/sources", .{project_dir}) catch return;
    defer allocator.free(dir_path);
    std.fs.cwd().makePath(dir_path) catch {};

    const out_path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, filename }) catch return;
    defer allocator.free(out_path);

    const file = std.fs.cwd().createFile(out_path, .{}) catch return;
    defer file.close();
    file.writeAll(body) catch {};
    std.debug.print("Saved source: lib/sources/{s}\n", .{filename});
}

fn uploadPackageApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const body = req.body() orelse {
        res.status = 400;
        res.body = "No data";
        return;
    };

    // Parse multipart form data
    const content_type = req.header("content-type") orelse "";
    const boundary = blk: {
        if (std.mem.indexOf(u8, content_type, "boundary=")) |idx| {
            break :blk content_type[idx + 9 ..];
        }
        res.status = 400;
        res.body = "Missing multipart boundary";
        return;
    };

    var sym_data: ?[]const u8 = null;
    var sym_filename: []const u8 = "unknown.kicad_sym";
    var fp_data: ?[]const u8 = null;
    var fp_filename: []const u8 = "unknown.kicad_mod";
    var step_data: ?[]const u8 = null;
    var step_filename: []const u8 = "unknown.step";

    // Simple multipart parser
    const delim = std.fmt.allocPrint(ctx.allocator, "--{s}", .{boundary}) catch {
        res.status = 500;
        return;
    };

    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, body, pos, delim)) |start| {
        const part_start = start + delim.len;
        if (part_start >= body.len) break;
        // Skip \r\n after boundary
        var hdr_start = part_start;
        if (hdr_start < body.len and body[hdr_start] == '\r') hdr_start += 1;
        if (hdr_start < body.len and body[hdr_start] == '\n') hdr_start += 1;

        // Find end of headers (double newline)
        const hdr_end = std.mem.indexOf(u8, body[hdr_start..], "\r\n\r\n") orelse break;
        const headers = body[hdr_start .. hdr_start + hdr_end];
        const data_start = hdr_start + hdr_end + 4;

        // Find next boundary for data end
        const next_boundary = std.mem.indexOfPos(u8, body, data_start, delim) orelse body.len;
        var data_end = next_boundary;
        if (data_end >= 2 and body[data_end - 1] == '\n' and body[data_end - 2] == '\r') data_end -= 2;
        const data = body[data_start..data_end];

        // Parse headers to find field name and filename
        const headers_lower = std.ascii.allocLowerString(ctx.allocator, headers) catch continue;
        if (std.mem.indexOf(u8, headers_lower, "name=\"symbol\"")) |_| {
            sym_data = data;
            if (std.mem.indexOf(u8, headers, "filename=\"")) |fi| {
                const fn_start = fi + 10;
                if (std.mem.indexOfPos(u8, headers, fn_start, "\"")) |fn_end| {
                    sym_filename = headers[fn_start..fn_end];
                }
            }
        } else if (std.mem.indexOf(u8, headers_lower, "name=\"footprint\"")) |_| {
            fp_data = data;
            if (std.mem.indexOf(u8, headers, "filename=\"")) |fi| {
                const fn_start = fi + 10;
                if (std.mem.indexOfPos(u8, headers, fn_start, "\"")) |fn_end| {
                    fp_filename = headers[fn_start..fn_end];
                }
            }
        } else if (std.mem.indexOf(u8, headers_lower, "name=\"step\"")) |_| {
            step_data = data;
            if (std.mem.indexOf(u8, headers, "filename=\"")) |fi| {
                const fn_start = fi + 10;
                if (std.mem.indexOfPos(u8, headers, fn_start, "\"")) |fn_end| {
                    step_filename = headers[fn_start..fn_end];
                }
            }
        }

        pos = next_boundary;
    }

    if (sym_data == null or fp_data == null) {
        res.status = 400;
        res.body = "Both symbol and footprint files are required";
        return;
    }

    // Extract package name from symbol content
    // Look for (symbol "NAME" inside a kicad_symbol_lib, or top-level (symbol "NAME"
    const pkg_name = blk: {
        const sym = sym_data.?;
        // Try (symbol "NAME" — skip the kicad_symbol_lib wrapper's own (symbol if present
        var search_pos: usize = 0;
        // If it's a library file, skip past the opening (kicad_symbol_lib ... to find the actual symbol
        if (std.mem.indexOf(u8, sym, "(kicad_symbol_lib")) |_| {
            // Find the first (symbol " after the library header
            if (std.mem.indexOf(u8, sym, "\n  (symbol \"")) |idx| {
                search_pos = idx;
            }
        }
        if (std.mem.indexOfPos(u8, sym, search_pos, "(symbol \"")) |idx| {
            const name_start = idx + 9; // len of `(symbol "`
            if (std.mem.indexOfPos(u8, sym, name_start, "\"")) |name_end| {
                break :blk sym[name_start..name_end];
            }
        }
        break :blk "package";
    };

    // Save raw source files
    saveSourceFile(ctx.allocator, ctx.project_dir, sym_filename, sym_data.?);
    saveSourceFile(ctx.allocator, ctx.project_dir, fp_filename, fp_data.?);
    if (step_data) |sd| {
        saveSourceFile(ctx.allocator, ctx.project_dir, step_filename, sd);
    }

    // Sanitize name
    var safe_name: std.ArrayListUnmanaged(u8) = .empty;
    for (pkg_name) |c| {
        const sc: u8 = switch (c) {
            'A'...'Z' => c + 32,
            ' ', '.', '_' => '-',
            else => c,
        };
        safe_name.append(ctx.allocator, sc) catch continue;
    }

    // Generate pinout from symbol
    const symbol_conv = @import("convert/symbol.zig");
    const pinout = symbol_conv.generatePinout(ctx.allocator, sym_data.?, null) catch {
        res.status = 500;
        res.body = "Pinout generation failed — check symbol file format";
        return;
    };
    if (pinout.len == 0) {
        res.status = 400;
        res.body = "No pins found in symbol file";
        return;
    }

    // Generate footprint
    const footprint_conv = @import("convert/footprint.zig");
    const footprint = footprint_conv.convertFootprint(ctx.allocator, fp_data.?) catch {
        res.status = 500;
        res.body = "Footprint conversion failed — check footprint file format";
        return;
    };

    // Write pinout to lib/pinouts/
    {
        const dir = std.fmt.allocPrint(ctx.allocator, "{s}/lib/pinouts", .{ctx.project_dir}) catch { res.status = 500; return; };
        defer ctx.allocator.free(dir);
        std.fs.cwd().makePath(dir) catch {};
        const path = std.fmt.allocPrint(ctx.allocator, "{s}/{s}.sexp", .{ dir, safe_name.items }) catch { res.status = 500; return; };
        defer ctx.allocator.free(path);
        const f = std.fs.cwd().createFile(path, .{}) catch { res.status = 500; res.body = "Cannot write pinout"; return; };
        defer f.close();
        f.writeAll(pinout) catch { res.status = 500; return; };
    }

    // Write footprint to lib/footprints/
    {
        // Extract footprint name from the converted output for the filename
        var fp_name: []const u8 = safe_name.items;
        if (std.mem.indexOf(u8, footprint, "(footprint \"")) |idx| {
            const ns = idx + 12;
            if (std.mem.indexOfPos(u8, footprint, ns, "\"")) |ne| {
                // Sanitize footprint name
                var fp_safe: std.ArrayListUnmanaged(u8) = .empty;
                for (footprint[ns..ne]) |fc| {
                    const fsc: u8 = switch (fc) {
                        'A'...'Z' => fc + 32,
                        ' ', '.', '_' => '-',
                        else => fc,
                    };
                    fp_safe.append(ctx.allocator, fsc) catch continue;
                }
                if (fp_safe.items.len > 0) fp_name = fp_safe.items;
            }
        }
        const dir = std.fmt.allocPrint(ctx.allocator, "{s}/lib/footprints", .{ctx.project_dir}) catch { res.status = 500; return; };
        defer ctx.allocator.free(dir);
        std.fs.cwd().makePath(dir) catch {};
        const path = std.fmt.allocPrint(ctx.allocator, "{s}/{s}.sexp", .{ dir, fp_name }) catch { res.status = 500; return; };
        defer ctx.allocator.free(path);
        const f = std.fs.cwd().createFile(path, .{}) catch { res.status = 500; res.body = "Cannot write footprint"; return; };
        defer f.close();
        f.writeAll(footprint) catch { res.status = 500; return; };
    }

    // Save STEP model to lib/models/ if provided
    if (step_data) |sd| {
        const model_dir = std.fmt.allocPrint(ctx.allocator, "{s}/lib/models", .{ctx.project_dir}) catch "";
        if (model_dir.len > 0) {
            std.fs.cwd().makePath(model_dir) catch {};
            const model_path = std.fmt.allocPrint(ctx.allocator, "{s}/{s}.step", .{ model_dir, safe_name.items }) catch "";
            if (model_path.len > 0) {
                const mf = std.fs.cwd().createFile(model_path, .{}) catch null;
                if (mf) |f| {
                    defer f.close();
                    f.writeAll(sd) catch {};
                }
            }
        }
    }

    const msg = std.fmt.allocPrint(ctx.allocator, "Created lib/pinouts/{s}.sexp + lib/footprints/... (sources saved to lib/sources/)", .{safe_name.items}) catch {
        res.body = "OK";
        return;
    };
    std.debug.print("Upload: {s}\n", .{msg});
    res.body = msg;
}

// Legacy upload endpoints (kept for backwards compatibility)
fn uploadSymbolApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const body = req.body() orelse {
        res.status = 400;
        res.body = "No file data";
        return;
    };

    // Get filename from header
    const filename = req.header("x-filename") orelse "unknown.kicad_sym";

    // Save raw KiCad source
    saveSourceFile(ctx.allocator, ctx.project_dir, filename, body);

    // Convert using the symbol converter
    const symbol_conv = @import("convert/symbol.zig");
    const converted = symbol_conv.convertSymbol(ctx.allocator, body, null) catch {
        res.status = 500;
        res.body = "Conversion failed — check file format";
        return;
    };

    if (converted.len == 0) {
        res.status = 400;
        res.body = "No symbols found in file";
        return;
    }

    // Derive output name from filename
    const basename = blk: {
        var name = filename;
        if (std.mem.lastIndexOfScalar(u8, name, '/')) |i| name = name[i + 1 ..];
        if (std.mem.lastIndexOfScalar(u8, name, '\\')) |i| name = name[i + 1 ..];
        if (std.mem.endsWith(u8, name, ".kicad_sym")) name = name[0 .. name.len - 10];
        break :blk name;
    };

    // Sanitize: lowercase, replace spaces/dots with hyphens
    var safe_name: std.ArrayListUnmanaged(u8) = .empty;
    for (basename) |c| {
        const sc: u8 = switch (c) {
            'A'...'Z' => c + 32,
            ' ', '.', '_' => '-',
            else => c,
        };
        safe_name.append(ctx.allocator, sc) catch continue;
    }

    // Write to lib/pinouts/
    const dir_path = std.fmt.allocPrint(ctx.allocator, "{s}/lib/pinouts", .{ctx.project_dir}) catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(dir_path);
    std.fs.cwd().makePath(dir_path) catch {};

    const out_path = std.fmt.allocPrint(ctx.allocator, "{s}/{s}.sexp", .{ dir_path, safe_name.items }) catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(out_path);

    const file = std.fs.cwd().createFile(out_path, .{}) catch {
        res.status = 500;
        res.body = "Cannot write file";
        return;
    };
    defer file.close();
    file.writeAll(converted) catch {
        res.status = 500;
        return;
    };

    const msg = std.fmt.allocPrint(ctx.allocator, "Converted {s} -> lib/pinouts/{s}.sexp", .{ filename, safe_name.items }) catch {
        res.body = "OK";
        return;
    };
    std.debug.print("Upload: {s}\n", .{msg});
    res.body = msg;
}

fn uploadFootprintApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const body = req.body() orelse {
        res.status = 400;
        res.body = "No file data";
        return;
    };

    const filename = req.header("x-filename") orelse "unknown.kicad_mod";

    // Save raw KiCad source
    saveSourceFile(ctx.allocator, ctx.project_dir, filename, body);

    const footprint_conv = @import("convert/footprint.zig");
    const converted = footprint_conv.convertFootprint(ctx.allocator, body) catch {
        res.status = 500;
        res.body = "Conversion failed — check file format";
        return;
    };

    const basename = blk: {
        var name = filename;
        if (std.mem.lastIndexOfScalar(u8, name, '/')) |i| name = name[i + 1 ..];
        if (std.mem.lastIndexOfScalar(u8, name, '\\')) |i| name = name[i + 1 ..];
        if (std.mem.endsWith(u8, name, ".kicad_mod")) name = name[0 .. name.len - 10];
        break :blk name;
    };

    var safe_name: std.ArrayListUnmanaged(u8) = .empty;
    for (basename) |c| {
        const sc: u8 = switch (c) {
            'A'...'Z' => c + 32,
            ' ', '.', '_' => '-',
            else => c,
        };
        safe_name.append(ctx.allocator, sc) catch continue;
    }

    const dir_path = std.fmt.allocPrint(ctx.allocator, "{s}/lib/footprints", .{ctx.project_dir}) catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(dir_path);
    std.fs.cwd().makePath(dir_path) catch {};

    const out_path = std.fmt.allocPrint(ctx.allocator, "{s}/{s}.sexp", .{ dir_path, safe_name.items }) catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(out_path);

    const file = std.fs.cwd().createFile(out_path, .{}) catch {
        res.status = 500;
        res.body = "Cannot write file";
        return;
    };
    defer file.close();
    file.writeAll(converted) catch {
        res.status = 500;
        return;
    };

    const msg = std.fmt.allocPrint(ctx.allocator, "Converted {s} -> lib/footprints/{s}.sexp", .{ filename, safe_name.items }) catch {
        res.body = "OK";
        return;
    };
    std.debug.print("Upload: {s}\n", .{msg});
    res.body = msg;
}

// ── HTML helpers ───────────────────────────────────────────────────────

fn writeInstances(w: anytype, block: *const env_mod.DesignBlock, prefix: []const u8) !void {
    for (block.instances) |inst| {
        try w.writeAll("<tr><td>");
        if (prefix.len > 0) try w.print("{s}/", .{prefix});
        try w.print("{s}</td><td>{s}</td><td>{s}</td></tr>", .{ inst.ref_des, inst.component, inst.value });
    }
    for (block.sub_blocks) |sb| {
        try writeInstances(w, sb.block, sb.name);
    }
}

fn writeNets(w: anytype, block: *const env_mod.DesignBlock, prefix: []const u8) !void {
    for (block.nets) |net| {
        try w.writeAll("<tr><td>");
        if (prefix.len > 0) try w.print("{s}/", .{prefix});
        try w.print("{s}</td><td>", .{net.name});
        for (net.pins, 0..) |pin, i| {
            if (i > 0) try w.writeAll(", ");
            if (prefix.len > 0) try w.print("{s}/", .{prefix});
            try w.print("{s}.{s}", .{ pin.ref_des, pin.pin });
        }
        try w.writeAll("</td></tr>");
    }
    for (block.sub_blocks) |sb| {
        try writeNets(w, sb.block, sb.name);
    }
}

// ── Symbol pin cache ──────────────────────────────────────────────────

const parser_mod = @import("sexpr/parser.zig");

const SymbolPin = struct {
    num: []const u8,
    name: []const u8,
};

const SymbolPinCache = std.StringHashMapUnmanaged([]const SymbolPin);

fn collectMissing(
    allocator: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    project_dir: []const u8,
    missing_fp: *std.ArrayListUnmanaged([]const u8),
    missing_model: *std.ArrayListUnmanaged([]const u8),
    checked_fp: *std.StringHashMap(void),
    checked_model: *std.StringHashMap(void),
) !void {
    for (block.instances) |inst| {
        // Check footprint
        if (inst.footprint.len > 0 and !checked_fp.contains(inst.footprint)) {
            try checked_fp.put(inst.footprint, {});
            const fp_path = try std.fmt.allocPrint(allocator, "{s}/lib/footprints/{s}.sexp", .{ project_dir, inst.footprint });
            defer allocator.free(fp_path);
            std.fs.cwd().access(fp_path, .{}) catch {
                try missing_fp.append(allocator, inst.footprint);
            };
        }
        // Check 3D model
        if (inst.component.len > 0 and !checked_model.contains(inst.component)) {
            try checked_model.put(inst.component, {});
            var found = false;
            // Try exact footprint name, then component name
            const names_to_try = [_][]const u8{ inst.footprint, inst.component };
            for (names_to_try) |try_name| {
                if (try_name.len == 0) continue;
                const m = try std.fmt.allocPrint(allocator, "{s}/lib/models/{s}.step", .{ project_dir, try_name });
                defer allocator.free(m);
                if (std.fs.cwd().access(m, .{})) |_| {
                    found = true;
                    break;
                } else |_| {}
            }
            // Fuzzy scan: check if any model filename contains/is contained by footprint or component name
            if (!found) {
                const models_path = try std.fmt.allocPrint(allocator, "{s}/lib/models", .{project_dir});
                defer allocator.free(models_path);
                var dir = std.fs.cwd().openDir(models_path, .{ .iterate = true }) catch null;
                if (dir) |*d| {
                    defer d.close();
                    var iter = d.iterate();
                    while (iter.next() catch null) |entry| {
                        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".step")) continue;
                        const basename = entry.name[0 .. entry.name.len - 5];
                        if ((inst.footprint.len > 0 and (std.mem.indexOf(u8, inst.footprint, basename) != null or std.mem.indexOf(u8, basename, inst.footprint) != null)) or
                            (std.mem.indexOf(u8, inst.component, basename) != null or std.mem.indexOf(u8, basename, inst.component) != null))
                        {
                            found = true;
                            break;
                        }
                    }
                }
            }
            if (!found) {
                try missing_model.append(allocator, inst.component);
            }
        }
    }
    for (block.sub_blocks) |sb| {
        try collectMissing(allocator, sb.block, project_dir, missing_fp, missing_model, checked_fp, checked_model);
    }
}

fn writeBomHtml(wr: anytype, block: *const env_mod.DesignBlock) !void {
    const Instance = env_mod.Instance;
    var all: std.ArrayListUnmanaged(Instance) = .empty;
    try bomCollectInstances(block, &all);
    if (all.items.len == 0) return;

    const BomLine = struct {
        component: []const u8,
        value: []const u8,
        footprint: []const u8,
        attrs: []const []const u8,
        properties: []const env_mod.Property,
        count: u32,
        refs: std.ArrayListUnmanaged([]const u8),
        source_offsets: std.ArrayListUnmanaged(u32),
    };

    var lines: std.ArrayListUnmanaged(BomLine) = .empty;

    for (all.items) |inst| {
        var found = false;
        for (lines.items) |*line| {
            if (std.mem.eql(u8, line.component, inst.component) and
                std.mem.eql(u8, line.value, inst.value) and
                std.mem.eql(u8, line.footprint, inst.footprint) and
                attrsEqual(line.attrs, inst.attrs))
            {
                line.count += 1;
                line.refs.append(std.heap.page_allocator, inst.ref_des) catch {};
                line.source_offsets.append(std.heap.page_allocator, inst.source_offset) catch {};
                found = true;
                break;
            }
        }
        if (!found) {
            var refs: std.ArrayListUnmanaged([]const u8) = .empty;
            refs.append(std.heap.page_allocator, inst.ref_des) catch {};
            var offsets: std.ArrayListUnmanaged(u32) = .empty;
            offsets.append(std.heap.page_allocator, inst.source_offset) catch {};
            lines.append(std.heap.page_allocator, .{
                .component = inst.component,
                .value = inst.value,
                .footprint = inst.footprint,
                .attrs = inst.attrs,
                .properties = inst.properties,
                .count = 1,
                .refs = refs,
                .source_offsets = offsets,
            }) catch {};
        }
    }

    std.mem.sortUnstable(BomLine, lines.items, {}, struct {
        fn lt(_: void, a: BomLine, b: BomLine) bool {
            if (a.count != b.count) return a.count > b.count;
            const c = std.mem.order(u8, a.component, b.component);
            if (c == .lt) return true;
            if (c == .gt) return false;
            return std.mem.order(u8, a.value, b.value) == .lt;
        }
    }.lt);

    try wr.writeAll("<div class=\"bom-section\"><h2>Bill of Materials</h2>");
    try wr.writeAll("<table class=\"bom-table\"><thead><tr>");
    try wr.writeAll("<th>Qty</th><th>Ref Des</th><th>Component</th><th>Value</th><th>Package</th><th>Attributes</th>");
    try wr.writeAll("</tr></thead><tbody>");

    var total: u32 = 0;
    for (lines.items, 0..) |line, li| {
        total += line.count;
        try wr.writeAll("<tr>");
        try wr.print("<td>{d}</td>", .{line.count});

        // Refs
        try wr.writeAll("<td class=\"bom-refs\" title=\"");
        for (line.refs.items, 0..) |r, i| {
            if (i > 0) try wr.writeAll(", ");
            try wr.writeAll(r);
        }
        try wr.writeAll("\">");
        for (line.refs.items, 0..) |r, i| {
            if (i > 0) try wr.writeAll(", ");
            try wr.writeAll(r);
        }
        try wr.writeAll("</td>");

        // Component
        try wr.print("<td class=\"bom-pkg\">{s}</td>", .{line.component});

        // Value
        try wr.print("<td>{s}</td>", .{line.value});

        // Package — editable dropdown for passive families
        try wr.writeAll("<td class=\"bom-pkg\">");
        const fp_prefix = getPassivePrefix(line.component);
        if (fp_prefix.len > 0) {
            // Editable select
            try wr.print("<select class=\"bom-fp-select\" data-row=\"{d}\" data-component=\"{s}\" data-refs=\"", .{ li, line.component });
            for (line.refs.items, 0..) |r, i| {
                if (i > 0) try wr.writeAll(",");
                try wr.writeAll(r);
            }
            try wr.writeAll("\" data-srcoffs=\"");
            for (line.source_offsets.items, 0..) |off, i| {
                if (i > 0) try wr.writeAll(",");
                try wr.print("{d}", .{off});
            }
            try wr.writeAll("\">");
            // Options will be populated by JS from FAMILIES
            try wr.print("<option value=\"{s}\" selected>{s}</option>", .{ line.component, line.component });
            try wr.writeAll("</select>");
        } else {
            try wr.writeAll(line.footprint);
        }
        try wr.writeAll("</td>");

        // Attributes — combined column: attrs + properties
        try wr.writeAll("<td class=\"bom-attrs\">");
        var attr_written = false;
        for (line.attrs) |attr| {
            if (attr_written) try wr.writeAll(" ");
            try wr.print("<span class=\"bom-tag bom-tag-attr\">{s}</span>", .{attr});
            attr_written = true;
        }
        for (line.properties) |prop| {
            if (attr_written) try wr.writeAll(" ");
            try wr.print("<span class=\"bom-tag bom-tag-prop\">{s}: {s}</span>", .{ prop.key, prop.value });
            attr_written = true;
        }
        try wr.writeAll("</td>");

        try wr.writeAll("</tr>");
    }

    try wr.writeAll("</tbody></table>");
    try wr.print("<div class=\"bom-total\">{d} unique lines, {d} total parts</div>", .{ lines.items.len, total });

    // JS for BOM footprint editing
    try wr.writeAll(
        \\<script>document.addEventListener('DOMContentLoaded',function(){
        \\var selects=document.querySelectorAll('.bom-fp-select');
        \\selects.forEach(function(sel){
        \\  var comp=sel.getAttribute('data-component');
        \\  var prefix=(comp.match(/^(cap|res|ind|led)-/)||[])[1];
        \\  if(prefix&&FAMILIES[prefix]){
        \\    var current=sel.value;
        \\    sel.innerHTML='';
        \\    FAMILIES[prefix].forEach(function(f){
        \\      var opt=document.createElement('option');
        \\      opt.value=f;opt.textContent=f;
        \\      if(f===current)opt.selected=true;
        \\      sel.appendChild(opt);
        \\    });
        \\  }
        \\  sel.addEventListener('change',function(){
        \\    var newComp=sel.value;
        \\    var oldComp=sel.getAttribute('data-component');
        \\    var refs=sel.getAttribute('data-refs').split(',');
        \\    var srcoffs=sel.getAttribute('data-srcoffs').split(',').map(Number);
        \\    function editNext(i){
        \\      if(i>=refs.length){sel.setAttribute('data-component',newComp);location.reload();return;}
        \\      fetch('/api/edit-footprint/'+SCHEMATIC_SLUG,{
        \\        method:'POST',
        \\        headers:{'Content-Type':'application/json'},
        \\        body:JSON.stringify({ref:refs[i],component:newComp,oldComponent:oldComp,srcOff:srcoffs[i]})
        \\      }).then(function(r){return r.json();}).then(function(d){
        \\        if(d.components){for(var k in d.components){var c=d.components[k];if(c.srcOff!==undefined){
        \\          var idx=refs.indexOf(k);if(idx>=0)srcoffs[idx]=c.srcOff;
        \\        }}}
        \\        editNext(i+1);
        \\      });
        \\    }
        \\    editNext(0);
        \\  });
        \\});
        \\});</script>
    );

    try wr.writeAll("</div>");
}

fn getPassivePrefix(component: []const u8) []const u8 {
    const prefixes = [_][]const u8{ "cap", "res", "ind", "led" };
    for (prefixes) |pfx| {
        if (std.mem.startsWith(u8, component, pfx) and component.len > pfx.len and component[pfx.len] == '-') return pfx;
    }
    return "";
}

fn bomCollectInstances(block: *const env_mod.DesignBlock, out: *std.ArrayListUnmanaged(env_mod.Instance)) !void {
    for (block.instances) |inst| {
        try out.append(std.heap.page_allocator, inst);
    }
    for (block.sub_blocks) |sb| {
        try bomCollectInstances(sb.block, out);
    }
}

fn attrsEqual(a: []const []const u8, b: []const []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (!std.mem.eql(u8, x, y)) return false;
    }
    return true;
}

fn buildSymbolPinCache(allocator: std.mem.Allocator, project_dir: []const u8) !SymbolPinCache {
    var cache: SymbolPinCache = .empty;
    const dirs = [_]struct { path: []const u8, form: []const u8 }{
        .{ .path = "lib/pinouts", .form = "pinout" },
    };
    for (dirs) |d| {
        const dir_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_dir, d.path });
        defer allocator.free(dir_path);
        var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch continue;
        defer dir.close();
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".sexp")) {
                const content = dir.readFileAlloc(allocator, entry.name, 1024 * 256) catch continue;
                const nodes = parser_mod.parse(allocator, content) catch continue;
                if (nodes.len == 0) continue;
                const top = nodes[0].asList() orelse continue;
                if (top.len < 2) continue;
                const head = top[0].asAtom() orelse continue;
                if (!std.mem.eql(u8, head, d.form)) continue;
                const item_name = top[1].asString() orelse (top[1].asAtom() orelse continue);
                if (cache.contains(item_name)) continue; // package takes priority

                var pins: std.ArrayListUnmanaged(SymbolPin) = .empty;
                for (top[2..]) |child| {
                    const cl = child.asList() orelse continue;
                    if (cl.len < 3) continue;
                    const ch = cl[0].asAtom() orelse continue;
                    if (!std.mem.eql(u8, ch, "pin")) continue;
                    const pin_id = blk: {
                        if (cl[1].asNumber()) |n| {
                            const i: i64 = @intFromFloat(n);
                            break :blk std.fmt.allocPrint(allocator, "{d}", .{i}) catch continue;
                        }
                        break :blk cl[1].asAtom() orelse continue;
                    };
                    const pin_name = cl[2].asString() orelse (cl[2].asAtom() orelse continue);
                    try pins.append(allocator, .{ .num = pin_id, .name = pin_name });
                }
                if (pins.items.len > 0) {
                    try cache.put(allocator, item_name, try pins.toOwnedSlice(allocator));
                }
            }
        }
    }
    return cache;
}

/// Augment instances with an "Unconnected" part for symbol pins not in any part.
fn augmentUnconnectedPins(allocator: std.mem.Allocator, block: *env_mod.DesignBlock, sym_cache: *const SymbolPinCache) !void {
    for (block.instances, 0..) |inst, inst_idx| {
        // Only add Unconnected to multi-part components (like the STM32)
        // Single-part hubs use their own grid position and shouldn't get parts added
        if (inst.parts.len == 0) continue;

        // Try symbol name, then component name as cache key
        const sym_pins = sym_cache.get(inst.symbol) orelse
            sym_cache.get(inst.component) orelse continue;
        if (sym_pins.len == 0) continue;

        // Collect all pin IDs already assigned to parts
        var used: std.StringHashMapUnmanaged(void) = .empty;
        defer used.deinit(allocator);
        for (inst.parts) |part| {
            for (part.pins) |pp| {
                try used.put(allocator, pp.pin, {});
            }
        }

        // Find unconnected symbol pins
        var nc_pins: std.ArrayListUnmanaged(env_mod.PartPin) = .empty;
        for (sym_pins) |sp| {
            if (!used.contains(sp.num)) {
                try nc_pins.append(allocator, .{ .pin = sp.num, .net = "" });
            }
        }

        if (nc_pins.items.len == 0) continue;

        // Append "Unconnected" part
        var new_parts = try allocator.alloc(env_mod.Part, inst.parts.len + 1);
        @memcpy(new_parts[0..inst.parts.len], inst.parts);
        new_parts[inst.parts.len] = .{
            .name = "Unconnected",
            .pins = try nc_pins.toOwnedSlice(allocator),
        };

        // Update the instance (need mutable access)
        var mutable_instances = @constCast(block.instances);
        mutable_instances[inst_idx].parts = new_parts;
    }

    // Recurse into sub-blocks
    for (block.sub_blocks) |sb| {
        try augmentUnconnectedPins(allocator, sb.block, sym_cache);
    }
}

// ── JSON helpers ───────────────────────────────────────────────────────

/// Write COMPONENTS JSON object contents. Returns true if any items were written.
fn footprintHasPads(allocator: std.mem.Allocator, project_dir: []const u8, footprint: []const u8) bool {
    if (footprint.len == 0) return false;
    const fp_path = std.fmt.allocPrint(allocator, "{s}/lib/footprints/{s}.sexp", .{ project_dir, footprint }) catch return false;
    defer allocator.free(fp_path);
    const content = std.fs.cwd().readFileAlloc(allocator, fp_path, 256 * 1024) catch return false;
    defer allocator.free(content);
    return std.mem.indexOf(u8, content, "(pad ") != null;
}

fn writeComponentsJson(w: anytype, block: *const env_mod.DesignBlock, prefix: []const u8, sym_cache: *const SymbolPinCache, allocator: std.mem.Allocator, project_dir: []const u8) !bool {
    var written = false;
    for (block.instances) |inst| {
        if (written) try w.writeAll(",");
        try w.writeAll("\"");
        if (prefix.len > 0) try w.print("{s}/", .{prefix});
        const fp_ok = footprintHasPads(allocator, project_dir, inst.footprint);
        try w.print("{s}\":{{\"symbol\":\"{s}\",\"footprint\":\"{s}\",\"fpOk\":{s},\"value\":\"{s}\",\"component\":\"{s}\",\"srcOff\":{d},\"note\":\"", .{
            inst.ref_des,
            inst.symbol,
            inst.footprint,
            if (fp_ok) "true" else "false",
            inst.value,
            inst.component,
            inst.source_offset,
        });
        // Find note for this instance
        for (block.notes) |note| {
            if (std.mem.eql(u8, note.ref_des, inst.ref_des)) {
                try writeJsonEscaped(w, note.text);
                break;
            }
        }
        // Include part pin data if available
        try w.writeAll("\",\"pins\":[");
        var pin_written = false;
        for (inst.parts) |part| {
            for (part.pins) |pp| {
                if (pin_written) try w.writeAll(",");
                try w.print("{{\"num\":\"{s}\",\"net\":\"", .{pp.pin});
                try writeJsonEscaped(w, pp.net);
                try w.writeAll("\",\"pinName\":\"");
                try writeJsonEscaped(w, pp.pin_name);
                try w.writeAll("\",\"part\":\"");
                try writeJsonEscaped(w, part.name);
                try w.writeAll("\"}");
                pin_written = true;
            }
        }
        try w.writeAll("],\"symbolPins\":[");
        // Include all pins from the symbol definition
        if (sym_cache.get(inst.symbol) orelse sym_cache.get(inst.component)) |sym_pins| {
            for (sym_pins, 0..) |sp, si| {
                if (si > 0) try w.writeAll(",");
                try w.print("{{\"num\":\"{s}\",\"name\":\"", .{sp.num});
                try writeJsonEscaped(w, sp.name);
                try w.writeAll("\"}");
            }
        }
        try w.writeAll("],\"properties\":{");
        for (inst.properties, 0..) |prop, pi| {
            if (pi > 0) try w.writeAll(",");
            try w.writeAll("\"");
            try writeJsonEscaped(w, prop.key);
            try w.writeAll("\":\"");
            try writeJsonEscaped(w, prop.value);
            try w.writeAll("\"");
        }
        try w.writeAll("}}");
        written = true;
    }
    for (block.sub_blocks) |sb| {
        if (written) try w.writeAll(",");
        const sub_written = try writeComponentsJson(w, sb.block, sb.name, sym_cache, allocator, project_dir);
        if (sub_written) written = true;
    }
    return written;
}

/// Write NETS JSON object contents. Returns true if any items were written.
fn writeNetsJson(w: anytype, block: *const env_mod.DesignBlock, prefix: []const u8) !bool {
    var written = false;
    for (block.nets) |net| {
        if (written) try w.writeAll(",");
        try w.writeAll("\"");
        if (prefix.len > 0) try w.print("{s}/", .{prefix});
        try w.print("{s}\":[", .{net.name});
        for (net.pins, 0..) |pin, pi| {
            if (pi > 0) try w.writeAll(",");
            try w.writeAll("\"");
            if (prefix.len > 0) try w.print("{s}/", .{prefix});
            try w.print("{s}.{s}\"", .{ pin.ref_des, pin.pin });
        }
        try w.writeAll("]");
        written = true;
    }
    for (block.sub_blocks) |sb| {
        if (written) try w.writeAll(",");
        const sub_written = try writeNetsJson(w, sb.block, sb.name);
        if (sub_written) written = true;
    }
    return written;
}

fn writeJsonEscaped(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
        }
    }
}

// ── CSS for index page ────────────────────────────────────────────────

const INDEX_CSS =
    \\* { margin: 0; padding: 0; box-sizing: border-box; }
    \\body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    \\  max-width: 960px; margin: 0 auto; padding: 2rem; background: #0d1117; color: #c9d1d9; }
    \\a { color: #58a6ff; text-decoration: none; }
    \\a:hover { text-decoration: underline; }
    \\h1 { margin-bottom: 1rem; color: #f0f6fc; }
    \\h2 { margin: 1.5rem 0 0.5rem; color: #f0f6fc; border-bottom: 1px solid #21262d; padding-bottom: 0.3rem; }
    \\.design-list { list-style: none; }
    \\.design-list li { padding: 0.75rem 1rem; border: 1px solid #21262d; border-radius: 6px;
    \\  margin-bottom: 0.5rem; background: #161b22; }
    \\.design-list li:hover { border-color: #58a6ff; }
    \\.design-list a { font-size: 1.1rem; display: block; }
    \\table { width: 100%; border-collapse: collapse; margin-bottom: 1rem; }
    \\th, td { text-align: left; padding: 0.4rem 0.75rem; border-bottom: 1px solid #21262d; }
    \\th { background: #161b22; color: #8b949e; font-weight: 600; font-size: 0.85rem; text-transform: uppercase; }
    \\td { font-family: "SF Mono", "Fira Code", monospace; font-size: 0.9rem; }
    \\.assertions { margin: 1rem 0; }
    \\.pass { color: #3fb950; font-family: monospace; }
    \\.fail { color: #f85149; font-family: monospace; font-weight: bold; }
    \\.warn { color: #d29922; font-family: monospace; }
    \\.schematic { margin: 1rem 0; border: 1px solid #21262d; border-radius: 8px; overflow: hidden; }
    \\.schematic svg { display: block; }
    \\details { margin: 0.5rem 0; }
    \\summary { cursor: pointer; color: #58a6ff; }
    \\pre { background: #161b22; padding: 1rem; border-radius: 6px; overflow-x: auto;
    \\  font-size: 0.85rem; line-height: 1.5; margin-top: 0.5rem; }
;

// ── CSS for design page (embedded in <style>) ─────────────────────────

const DESIGN_CSS =
    \\body { font-family: system-ui, sans-serif; margin: 0; padding: 0; color: #e0e0e0; background: #121212; }
    \\.page { max-width: 900px; margin: 2rem auto; padding: 0 1rem; transition: margin-right 0.2s; }
    \\.page.sidebar-open { margin-right: 340px; }
    \\nav { margin-bottom: 2rem; }
    \\nav a { margin-right: 1rem; color: #6699ff; text-decoration: none; }
    \\h1, h2, h3 { color: #fff; }
    \\.schematic-canvas { margin: 1rem 0; border: 1px solid #2a2a4a; border-radius: 8px; overflow: hidden; height: 70vh; position: relative; background: #1a1a2e; }
    \\.schematic-canvas svg { width: 100%; height: 100%; cursor: grab; display: block; }
    \\.schematic-canvas svg:active { cursor: grabbing; }
    \\.edit-mode .hub-group > .component { cursor: move !important; }
    \\.hub-group.dragging { opacity: 0.8; }
    \\.canvas-controls { position: absolute; top: 0.5rem; right: 0.5rem; display: flex; gap: 0.3rem; z-index: 10; }
    \\.canvas-btn { background: #2a2a4a; color: #888; border: 1px solid #444; border-radius: 4px; padding: 0.2rem 0.5rem; font-size: 0.75rem; cursor: pointer; }
    \\.canvas-btn:hover { color: #fff; border-color: #888; }
    \\.canvas-btn.active { color: #4a9eff; border-color: #4a9eff; }
    \\#nodes-toggle.active { color: #e55; border-color: #e55; }
    \\.sidebar { position: fixed; top: 0; right: -320px; width: 320px; height: 100vh; background: #1a1a2e; border-left: 1px solid #333; padding: 1.5rem; overflow-y: auto; transition: right 0.2s; z-index: 100; box-sizing: border-box; }
    \\.sidebar.open { right: 0; }
    \\.sidebar-close { position: absolute; top: 0.8rem; right: 0.8rem; background: none; border: none; color: #888; font-size: 1.2rem; cursor: pointer; }
    \\.sidebar-close:hover { color: #fff; }
    \\.sidebar h3 { margin-top: 0; color: #4a9eff; }
    \\.sidebar-section { margin-bottom: 1.2rem; }
    \\.sidebar-label { color: #888; font-size: 0.75rem; text-transform: uppercase; letter-spacing: 0.05em; margin-bottom: 0.3rem; }
    \\.sidebar-value { color: #e0e0e0; font-family: monospace; font-size: 0.85rem; }
    \\.sidebar-pins { list-style: none; padding: 0; margin: 0; }
    \\.sidebar-pins .pin-header { display: flex; padding: 0.3rem 0; border-bottom: 1px solid #444; font-size: 0.7rem; color: #666; text-transform: uppercase; letter-spacing: 0.05em; }
    \\.sidebar-pins .pin-header span:first-child { min-width: 3.5rem; }
    \\.sidebar-pins li { display: flex; align-items: baseline; padding: 0.25rem 0; border-bottom: 1px solid #2a2a4a; font-size: 0.8rem; font-family: monospace; }
    \\.sidebar-pins li.part-header { display: block; }
    \\.sidebar-pins .pin-num { color: #888; min-width: 3.5rem; flex-shrink: 0; }
    \\.sidebar-pins .pin-name { color: #e0e0e0; }
    \\.sidebar-pins .pin-type { color: #6a6; margin-left: 0.5rem; font-size: 0.75rem; }
    \\.sidebar-pins .pin-net { color: #e8c547; }
    \\.sidebar-note { color: #bbb; font-size: 0.8rem; line-height: 1.5; background: #16213e; padding: 0.6rem; border-radius: 4px; }
    \\.search-input { background: #1a1a2e; border: 1px solid #444; border-radius: 4px; color: #e0e0e0; padding: 0.3rem 0.6rem; font-size: 0.8rem; font-family: monospace; width: 200px; outline: none; }
    \\.search-input:focus { border-color: #4a9eff; }
    \\.search-input::placeholder { color: #555; }
    \\.search-results { display: none; position: absolute; top: 100%; left: 0; width: 260px; max-height: 300px; overflow-y: auto; background: #1a1a2e; border: 1px solid #444; border-radius: 0 0 4px 4px; z-index: 200; }
    \\.search-results.open { display: block; }
    \\.search-result { padding: 0.4rem 0.6rem; cursor: pointer; font-size: 0.8rem; font-family: monospace; color: #e0e0e0; border-bottom: 1px solid #2a2a4a; display: flex; justify-content: space-between; }
    \\.search-result:hover,.search-result.selected { background: #2a2a4a; }
    \\.search-result-type { font-size: 0.7rem; color: #888; text-transform: uppercase; }
    \\.search-result-type.net { color: #e8c547; }
    \\.search-result-type.comp { color: #4a9eff; }
    \\.search-result-type.section { color: #3fb950; }
    \\.search-result-type.pin { color: #c084fc; }
    \\table { width: 100%; border-collapse: collapse; margin-bottom: 1rem; }
    \\th,td { text-align: left; padding: 0.4rem 0.75rem; border-bottom: 1px solid #333; }
    \\th { background: #1a1a2e; color: #888; font-size: 0.85rem; text-transform: uppercase; }
    \\td { font-family: monospace; font-size: 0.9rem; }
    \\details { margin: 0.5rem 0; }
    \\summary { cursor: pointer; color: #6699ff; }
    \\pre { background: #1e1e1e; padding: 1rem; border-radius: 6px; overflow-x: auto; font-size: 0.85rem; }
    \\.assertions { margin: 1rem 0; }
    \\.pass { color: #3fb950; font-family: monospace; }
    \\.fail { color: #f85149; font-family: monospace; font-weight: bold; }
    \\.warn { color: #d29922; font-family: monospace; }
    \\svg .component:hover rect:not(.hit-area),svg .component:hover line,svg .component:hover path { filter: brightness(1.3); }
    \\svg .component.comp-active rect:not(.hit-area) { stroke: #e55 !important; }
    \\svg .component.comp-active line { stroke: #e55 !important; }
    \\svg .component.comp-active path { stroke: #e55 !important; }
    \\svg .component.comp-active polyline { stroke: #e55 !important; }
    \\svg .component.comp-active text { fill: #e55 !important; }
    \\.bom-section { margin: 2rem 0; }
    \\.bom-section h2 { font-size: 1.1rem; margin-bottom: 0.5rem; }
    \\.bom-table { width: 100%; border-collapse: collapse; font-size: 0.8rem; }
    \\.bom-table th { background: #161b22; color: #8b949e; font-size: 0.7rem; text-transform: uppercase; letter-spacing: 0.05em; padding: 0.5rem 0.6rem; text-align: left; border-bottom: 2px solid #30363d; white-space: nowrap; }
    \\.bom-table td { padding: 0.35rem 0.6rem; border-bottom: 1px solid #21262d; font-family: monospace; font-size: 0.8rem; color: #e0e0e0; }
    \\.bom-table tr:hover td { background: #161b22; }
    \\.bom-table .bom-refs { color: #79c0ff; max-width: 300px; overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
    \\.bom-table .bom-attrs { max-width: 400px; }
    \\.bom-table .bom-pkg { color: #8b949e; }
    \\.bom-tag { display: inline-block; padding: 0.1rem 0.4rem; border-radius: 3px; font-size: 0.7rem; margin: 1px 2px; white-space: nowrap; }
    \\.bom-tag-attr { background: #2d1b69; color: #d2a8ff; }
    \\.bom-tag-prop { background: #1b2d3d; color: #79c0ff; }
    \\.bom-fp-select { background: #161b22; border: 1px solid #30363d; border-radius: 4px; color: #8b949e; padding: 0.2rem 0.4rem; font-family: monospace; font-size: 0.75rem; cursor: pointer; outline: none; }
    \\.bom-fp-select:hover { border-color: #4a9eff; color: #e0e0e0; }
    \\.bom-total { color: #6e7681; font-size: 0.8rem; margin-top: 0.5rem; }
    \\svg .net:hover { filter: brightness(1.5); }
    \\svg .net.net-active line:not(.hit-area),svg .net.net-active polyline:not(.hit-area) { stroke: #e55 !important; }
    \\svg .net.net-active text { fill: #e55 !important; }
;

// ── Interaction JavaScript ─────────────────────────────────────────────
// Split into two parts so we can inject the design name between them.

const INTERACTION_JS_PART1 =
    \\(function(){try{
    \\
;

const INTERACTION_JS_PART2 =
    \\var canvas=document.getElementById('schematic-canvas');
    \\var sidebar=document.getElementById('sidebar');
    \\var sidebarContent=document.getElementById('sidebar-content');
    \\var sidebarClose=document.getElementById('sidebar-close');
    \\var page=document.getElementById('page');
    \\var editToggle=document.getElementById('edit-toggle');
    \\var resetBtn=document.getElementById('canvas-reset');
    \\var nodesToggle=document.getElementById('nodes-toggle');
    \\var searchInput=document.getElementById('search-input');
    \\var searchResults=document.getElementById('search-results');
    \\
    \\function getSvg(){return canvas.querySelector('svg');}
    \\function getVb(){var s=getSvg();return s?s.viewBox.baseVal:null;}
    \\
    \\/* Pan/Zoom state */
    \\var initVb=getVb();
    \\var origVB=initVb?{x:initVb.x,y:initVb.y,w:initVb.width,h:initVb.height}:{x:0,y:0,w:850,h:600};
    \\var isPanning=false,panStart={x:0,y:0},vbStart={x:0,y:0},didPan=false;
    \\var editMode=false;
    \\/* Pan */
    \\canvas.addEventListener('mousedown',function(e){
    \\  if(editMode&&e.target.closest('.hub-group'))return;
    \\  var vb=getVb();if(!vb)return;
    \\  isPanning=true;didPan=false;panStart={x:e.clientX,y:e.clientY};
    \\  vbStart={x:vb.x,y:vb.y};
    \\});
    \\function screenToSvgDelta(dx,dy){var svg=getSvg();if(!svg)return{x:dx,y:dy};var ctm=svg.getScreenCTM();if(!ctm)return{x:dx,y:dy};return{x:dx/ctm.a,y:dy/ctm.d};}
    \\window.addEventListener('mousemove',function(e){
    \\  if(!isPanning)return;var vb=getVb();if(!vb)return;
    \\  var d=screenToSvgDelta(e.clientX-panStart.x,e.clientY-panStart.y);
    \\  var dx=d.x,dy=d.y;
    \\  if(Math.abs(e.clientX-panStart.x)>3||Math.abs(e.clientY-panStart.y)>3)didPan=true;
    \\  vb.x=vbStart.x-dx;vb.y=vbStart.y-dy;
    \\});
    \\window.addEventListener('mouseup',function(){isPanning=false;});
    \\
    \\/* Zoom */
    \\canvas.addEventListener('wheel',function(e){
    \\  e.preventDefault();var vb=getVb();if(!vb)return;
    \\  var scale=e.deltaY>0?1.1:0.9;
    \\  var rect=canvas.getBoundingClientRect();
    \\  var mx=(e.clientX-rect.left)/rect.width;
    \\  var my=(e.clientY-rect.top)/rect.height;
    \\  var px=vb.x+mx*vb.width;
    \\  var py=vb.y+my*vb.height;
    \\  var nw=vb.width*scale,nh=vb.height*scale;
    \\  vb.x=px-mx*nw;vb.y=py-my*nh;
    \\  vb.width=nw;vb.height=nh;
    \\},{passive:false});
    \\
    \\/* Reset */
    \\resetBtn.addEventListener('click',function(){
    \\  var vb=getVb();if(!vb)return;
    \\  vb.x=origVB.x;vb.y=origVB.y;vb.width=origVB.w;vb.height=origVB.h;
    \\});
    \\
    \\/* Clear active highlights */
    \\function clearActive(){
    \\  var s=getSvg();if(!s)return;
    \\  s.querySelectorAll('.comp-active').forEach(function(el){el.classList.remove('comp-active');});
    \\  s.querySelectorAll('.net-active').forEach(function(el){el.classList.remove('net-active');});
    \\}
    \\
    \\/* Sidebar open/close */
    \\function openSidebar(html){
    \\  sidebarContent.innerHTML=html;sidebar.classList.add('open');page.classList.add('sidebar-open');
    \\}
    \\function closeSidebar(){
    \\  sidebar.classList.remove('open');page.classList.remove('sidebar-open');clearActive();
    \\}
    \\sidebarClose.addEventListener('click',closeSidebar);
    \\
    \\/* Component/net click (on canvas so it survives SVG replacement) */
    \\canvas.addEventListener('click',function(e){
    \\  if(didPan){didPan=false;return;}
    \\  var comp=e.target.closest('.component');
    \\  if(comp){
    \\    var ref=comp.getAttribute('data-ref');if(!ref)return;
    \\    var clickedPart=comp.getAttribute('data-part')||null;
    \\    clearActive();var s=getSvg();
    \\    if(s)s.querySelectorAll('.component[data-ref="'+ref+'"]').forEach(function(el){el.classList.add('comp-active');});
    \\    var info=COMPONENTS[ref]||{};
    \\    var html='<h3>'+ref+(clickedPart?' — '+clickedPart:'')+'</h3>';
    \\    html+='<div class="sidebar-section"><div class="sidebar-label">Symbol</div><div class="sidebar-value">'+(info.symbol||'-')+'</div></div>';
    \\    var fpPrefix=info.component?(info.component.match(/^(cap|res|ind|led)-/)||[])[1]:null;
    \\    if(fpPrefix&&FAMILIES[fpPrefix]){
    \\      html+='<div class="sidebar-section"><div class="sidebar-label">Footprint</div><div style="display:flex;gap:0.5rem;align-items:center;"><select id="fp-edit" style="background:#161b22;border:1px solid #444;border-radius:4px;color:#e0e0e0;padding:0.3rem 0.5rem;font-family:monospace;font-size:0.85rem;outline:none;">';
    \\      FAMILIES[fpPrefix].forEach(function(f){html+='<option value="'+f+'"'+(f===info.component?' selected':'')+'>'+f+'</option>';});
    \\      html+='</select><button id="fp-save" style="background:#2a4a2a;color:#4a9;border:1px solid #4a9;border-radius:4px;padding:0.3rem 0.6rem;font-size:0.75rem;cursor:pointer;">Save</button></div><div id="fp-preview" style="margin-top:0.5rem;height:150px;"></div></div>';
    \\    }else{
    \\      html+='<div class="sidebar-section"><div class="sidebar-label">Footprint</div><div class="sidebar-value">'+(info.footprint||'-')+'</div><div id="fp-preview" style="margin-top:0.5rem;height:150px;"></div></div>';
    \\    }
    \\    if(info.value){html+='<div class="sidebar-section"><div class="sidebar-label">Value</div><div style="display:flex;gap:0.5rem;align-items:center;"><input id="value-edit" type="text" value="'+info.value+'" style="background:#161b22;border:1px solid #444;border-radius:4px;color:#e0e0e0;padding:0.3rem 0.5rem;font-family:monospace;font-size:0.85rem;width:120px;outline:none;" /><button id="value-save" style="background:#2a4a2a;color:#4a9;border:1px solid #4a9;border-radius:4px;padding:0.3rem 0.6rem;font-size:0.75rem;cursor:pointer;">Save</button></div></div>';}else{html+='<div class="sidebar-section"><div class="sidebar-label">Value</div><div class="sidebar-value">-</div></div>';}
    \\    if(info.note)html+='<div class="sidebar-section"><div class="sidebar-label">Note</div><div class="sidebar-note">'+info.note+'</div></div>';
    \\    if(info.properties){var pkeys=Object.keys(info.properties);if(pkeys.length>0){html+='<div class="sidebar-section"><div class="sidebar-label">Properties</div><table style="width:100%;font-size:0.8rem;font-family:monospace;">';pkeys.forEach(function(k){html+='<tr><td style="color:#888;padding:0.15rem 0.5rem 0.15rem 0;">'+k+'</td><td style="color:#e0e0e0;padding:0.15rem 0;">'+info.properties[k]+'</td></tr>';});html+='</table></div>';}}
    \\    /* Build pin-to-net map for this component */
    \\    var pinNets={};
    \\    for(var net in NETS){var members=NETS[net];for(var i=0;i<members.length;i++){var m=members[i];if(m.indexOf(ref+'.')===0){var pn=m.substring(ref.length+1);if(!pinNets[pn])pinNets[pn]=[];pinNets[pn].push(net);}}}
    \\    /* Build pin-to-part map from component data */
    \\    var pinParts={};
    \\    if(info.pins)info.pins.forEach(function(p){pinParts[p.num]={net:p.net,part:p.part};});
    \\    /* Build symbol pin name map */
    \\    var symPinNames={};
    \\    if(info.symbolPins)info.symbolPins.forEach(function(sp){symPinNames[sp.num]=sp.name;});
    \\    /* Filter pins by clicked part if applicable */
    \\    var partPinSet=null;
    \\    if(clickedPart){
    \\      partPinSet={};
    \\      if(info.pins)info.pins.forEach(function(p){if(p.part===clickedPart)partPinSet[p.num]=true;});
    \\    }
    \\    /* Group pins by (part, net) */
    \\    var pinList=Object.keys(pinNets).sort(function(a,b){var na=parseInt(a),nb=parseInt(b);if(!isNaN(na)&&!isNaN(nb))return na-nb;return a.localeCompare(b);});
    \\    if(partPinSet)pinList=pinList.filter(function(pn){return partPinSet[pn];});
    \\    var hasAnyPins=pinList.length>0||(!partPinSet&&Object.keys(symPinNames).length>0);
    \\    if(hasAnyPins){
    \\      var groups=[];var gmap={};
    \\      pinList.forEach(function(pn){
    \\        var net=pinNets[pn].join(',');
    \\        var pp=pinParts[pn];
    \\        var part=pp?pp.part:'';
    \\        var key=part+'|'+net;
    \\        if(!gmap[key]){gmap[key]={part:part,nets:pinNets[pn],pins:[]};groups.push(gmap[key]);}
    \\        gmap[key].pins.push(pn);
    \\      });
    \\      html+='<div class="sidebar-section"><div class="sidebar-label">Pins</div><ul class="sidebar-pins">';
    \\      html+='<li class="pin-header"><span>Pin</span><span>Net</span></li>';
    \\      var lastPart='';
    \\      groups.forEach(function(g){
    \\        if(!clickedPart&&g.part&&g.part!==lastPart){lastPart=g.part;html+='<li class="part-header" style="color:#58a6ff;font-weight:bold;border-bottom:1px solid #333;padding-top:0.5rem;">'+g.part+'</li>';}
    \\        html+='<li><span class="pin-num">'+g.pins.join(', ')+'</span><span class="pin-net">';
    \\        g.nets.forEach(function(n,i){
    \\          if(i>0)html+=', ';
    \\          html+='<a href="#" class="net-link" data-net="'+n+'" style="color:#e8c547;text-decoration:none;cursor:pointer;">'+n+'</a>';
    \\        });
    \\        html+='</span></li>';
    \\      });
    \\      /* Unconnected pins from symbol (only in all-pins view) */
    \\      if(!partPinSet){
    \\        var connectedNums={};pinList.forEach(function(pn){connectedNums[pn]=true;});
    \\        var unconnected=[];
    \\        if(info.symbolPins)info.symbolPins.forEach(function(sp){if(!connectedNums[sp.num])unconnected.push(sp);});
    \\        if(unconnected.length>0){
    \\          html+='<li class="part-header" style="color:#666;font-weight:bold;border-bottom:1px solid #333;padding-top:0.5rem;">Unconnected</li>';
    \\          unconnected.forEach(function(sp){
    \\            html+='<li><span class="pin-num">'+sp.num+'</span><span class="pin-net" style="color:#555;">'+sp.name+' (NC)</span></li>';
    \\          });
    \\        }
    \\      }
    \\      html+='</ul></div>';
    \\      /* Show all pins / show part pins toggle */
    \\      if(clickedPart){
    \\        html+='<button id="show-all-pins" style="background:#2a2a4a;color:#4a9eff;border:1px solid #4a9eff;border-radius:4px;padding:0.4rem 0.8rem;font-size:0.75rem;cursor:pointer;width:100%;margin-top:0.5rem;">Show All '+ref+' Pins</button>';
    \\      }
    \\    }
    \\    openSidebar(html);
    \\    if(info.footprint){var fpEl=document.getElementById('fp-preview');if(fpEl){fetch('/api/footprint/'+info.footprint).then(function(r){if(r.ok)return r.text();throw '';}).then(function(svg){fpEl.innerHTML=svg;var s=fpEl.querySelector('svg');if(s){s.style.width='100%';s.style.height='100%';}}).catch(function(){fpEl.innerHTML=info.fpOk?'<span style="color:#555;font-size:0.75rem;">No preview</span>':'<div style="display:flex;align-items:center;gap:0.5rem;padding:0.5rem;background:#451a03;border:1px solid #f59e0b;border-radius:4px;margin-top:0.25rem;"><span style="color:#f59e0b;font-size:1.2rem;font-weight:bold;">&#9888;</span><span style="color:#fbbf24;font-size:0.8rem;">Footprint has no pad data — may be AI-generated or incomplete</span></div>';});}}
    \\    var saveBtn=document.getElementById('value-save');
    \\    if(saveBtn){
    \\      var input=document.getElementById('value-edit');
    \\      saveBtn.addEventListener('click',function(){
    \\        var newVal=input.value.trim();if(!newVal)return;
    \\        saveBtn.textContent='...';saveBtn.disabled=true;
    \\        fetch('/api/edit-value/'+SCHEMATIC_SLUG,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ref:ref,value:newVal})})
    \\          .then(function(r){return r.json();})
    \\          .then(function(d){if(d.ok){saveBtn.textContent='Saved';saveBtn.style.color='#3fb950';COMPONENTS[ref].value=newVal;}else{saveBtn.textContent='Error';saveBtn.style.color='#f85149';}})
    \\          .catch(function(){saveBtn.textContent='Error';saveBtn.style.color='#f85149';});
    \\      });
    \\      input.addEventListener('keydown',function(ev){if(ev.key==='Enter'){ev.preventDefault();saveBtn.click();}});
    \\    }
    \\    var fpSaveBtn=document.getElementById('fp-save');
    \\    if(fpSaveBtn){
    \\      var fpSelect=document.getElementById('fp-edit');
    \\      fpSaveBtn.addEventListener('click',function(){
    \\        var newComp=fpSelect.value;if(!newComp)return;
    \\        fpSaveBtn.textContent='...';fpSaveBtn.disabled=true;
    \\        fetch('/api/edit-footprint/'+SCHEMATIC_SLUG,{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify({ref:ref,component:newComp,oldComponent:info.component,srcOff:info.srcOff})})
    \\          .then(function(r){return r.json();})
    \\          .then(function(d){if(d.ok){fpSaveBtn.textContent='Saved';fpSaveBtn.style.color='#3fb950';if(d.components){for(var k in d.components)COMPONENTS[k]=d.components[k];}}else{fpSaveBtn.textContent='Error';fpSaveBtn.style.color='#f85149';}})
    \\          .catch(function(){fpSaveBtn.textContent='Error';fpSaveBtn.style.color='#f85149';});
    \\      });
    \\    }
    \\    var allPinsBtn=document.getElementById('show-all-pins');
    \\    if(allPinsBtn){
    \\      allPinsBtn.addEventListener('click',function(){
    \\        var fakeComp=getSvg().querySelector('.component[data-ref="'+ref+'"]');
    \\        if(!fakeComp)return;
    \\        var clone=fakeComp.cloneNode(false);
    \\        clone.removeAttribute('data-part');
    \\        var fakeEv={target:clone,stopPropagation:function(){},closest:function(s){return s==='.component'?clone:null;}};
    \\        clone.getAttribute=function(a){if(a==='data-ref')return ref;if(a==='data-part')return null;return null;};
    \\        /* Re-trigger sidebar without part filter by simulating click on component without data-part */
    \\        clearActive();
    \\        getSvg().querySelectorAll('.component[data-ref="'+ref+'"]').forEach(function(el){el.classList.add('comp-active');});
    \\        var info2=COMPONENTS[ref]||{};
    \\        var h2='<h3>'+ref+' — All Pins</h3>';
    \\        h2+='<div class="sidebar-section"><div class="sidebar-label">Symbol</div><div class="sidebar-value">'+(info2.symbol||'-')+'</div></div>';
    \\        h2+='<div class="sidebar-section"><div class="sidebar-label">Footprint</div><div class="sidebar-value">'+(info2.footprint||'-')+'</div></div>';
    \\        var pn2={};for(var n2 in NETS){var mm=NETS[n2];for(var j=0;j<mm.length;j++){var m2=mm[j];if(m2.indexOf(ref+'.')===0){var pk=m2.substring(ref.length+1);if(!pn2[pk])pn2[pk]=[];pn2[pk].push(n2);}}}
    \\        var pp2={};if(info2.pins)info2.pins.forEach(function(p){pp2[p.num]={net:p.net,part:p.part};});
    \\        var pl2=Object.keys(pn2).sort(function(a,b){var na=parseInt(a),nb=parseInt(b);if(!isNaN(na)&&!isNaN(nb))return na-nb;return a.localeCompare(b);});
    \\        if(pl2.length>0){
    \\          var gr2=[];var gm2={};
    \\          pl2.forEach(function(pn){var net=pn2[pn].join(',');var pp=pp2[pn];var part=pp?pp.part:'';var key=part+'|'+net;if(!gm2[key]){gm2[key]={part:part,nets:pn2[pn],pins:[]};gr2.push(gm2[key]);}gm2[key].pins.push(pn);});
    \\          h2+='<div class="sidebar-section"><div class="sidebar-label">Pins</div><ul class="sidebar-pins">';
    \\          h2+='<li class="pin-header"><span>Pin</span><span>Net</span></li>';
    \\          var lp2='';gr2.forEach(function(g){if(g.part&&g.part!==lp2){lp2=g.part;h2+='<li class="part-header" style="color:#58a6ff;font-weight:bold;border-bottom:1px solid #333;padding-top:0.5rem;">'+g.part+'</li>';}h2+='<li><span class="pin-num">'+g.pins.join(', ')+'</span><span class="pin-net">';g.nets.forEach(function(n,i){if(i>0)h2+=', ';h2+='<a href="#" class="net-link" data-net="'+n+'" style="color:#e8c547;text-decoration:none;cursor:pointer;">'+n+'</a>';});h2+='</span></li>';});
    \\          var cn2={};pl2.forEach(function(pn){cn2[pn]=true;});var uc2=[];
    \\          if(info2.symbolPins)info2.symbolPins.forEach(function(sp){if(!cn2[sp.num])uc2.push(sp);});
    \\          if(uc2.length>0){h2+='<li class="part-header" style="color:#666;font-weight:bold;border-bottom:1px solid #333;padding-top:0.5rem;">Unconnected</li>';uc2.forEach(function(sp){h2+='<li><span class="pin-num">'+sp.num+'</span><span class="pin-net" style="color:#555;">'+sp.name+' (NC)</span></li>';});}
    \\          h2+='</ul></div>';
    \\        }
    \\        openSidebar(h2);
    \\      });
    \\    }
    \\    document.querySelectorAll('.net-link').forEach(function(link){
    \\      link.addEventListener('click',function(ev){
    \\        ev.preventDefault();
    \\        var netName=this.getAttribute('data-net');
    \\        clearActive();
    \\        getSvg().querySelectorAll('.net[data-net="'+netName+'"]').forEach(function(el){el.classList.add('net-active');});
    \\        var pins=NETS[netName]||[];
    \\        var h='<h3>Net: '+netName+'</h3>';
    \\        h+='<div class="sidebar-section"><div class="sidebar-label">Connected Pins</div><ul class="sidebar-pins">';
    \\        pins.forEach(function(p){var r=p.split('.')[0];h+='<li><a href="#" class="pin-link" data-ref="'+r+'" style="color:#4a9eff;text-decoration:none;cursor:pointer;">'+p+'</a></li>';});
    \\        h+='</ul></div>';
    \\        openSidebar(h);
    \\        document.querySelectorAll('.pin-link').forEach(function(l){
    \\          l.addEventListener('click',function(ev2){
    \\            ev2.preventDefault();
    \\            var r2=this.getAttribute('data-ref');
    \\            var c2=getSvg().querySelector('.component[data-ref="'+r2+'"]');
    \\            if(c2){c2.dispatchEvent(new MouseEvent('click',{bubbles:true}));}
    \\          });
    \\        });
    \\      });
    \\    });
    \\    e.stopPropagation();return;
    \\  }
    \\  var net=e.target.closest('.net');
    \\  if(net){
    \\    var netName=net.getAttribute('data-net');if(!netName)return;
    \\    clearActive();
    \\    getSvg().querySelectorAll('.net[data-net="'+netName+'"]').forEach(function(el){el.classList.add('net-active');});
    \\    var pins=NETS[netName]||[];
    \\    var html='<h3>Net: '+netName+'</h3>';
    \\    html+='<div class="sidebar-section"><div class="sidebar-label">Connected Pins</div><ul class="sidebar-pins">';
    \\    pins.forEach(function(p){var ref=p.split('.')[0];html+='<li><a href="#" class="pin-link" data-ref="'+ref+'" style="color:#4a9eff;text-decoration:none;cursor:pointer;">'+p+'</a></li>';});
    \\    html+='</ul></div>';
    \\    openSidebar(html);
    \\    document.querySelectorAll('.pin-link').forEach(function(link){
    \\      link.addEventListener('click',function(ev){
    \\        ev.preventDefault();
    \\        var ref=this.getAttribute('data-ref');
    \\        var comp=getSvg().querySelector('.component[data-ref="'+ref+'"]');
    \\        if(comp){comp.dispatchEvent(new MouseEvent('click',{bubbles:true}));}
    \\      });
    \\    });
    \\    e.stopPropagation();return;
    \\  }
    \\});
    \\
    \\/* Nodes toggle */
    \\nodesToggle.addEventListener('click',function(){
    \\  this.classList.toggle('active');
    \\  var show=this.classList.contains('active');
    \\  getSvg().querySelectorAll('.debug-pin').forEach(function(el){el.style.display=show?'':'none';});
    \\});
    \\
    \\/* Edit mode toggle */
    \\editToggle.addEventListener('click',function(){
    \\  editMode=!editMode;
    \\  this.classList.toggle('active',editMode);
    \\  canvas.classList.toggle('edit-mode',editMode);
    \\});
    \\
    \\/* Rebuild */
    \\var rebuildBtn=document.getElementById('rebuild-btn');
    \\rebuildBtn.addEventListener('click',function(){
    \\  rebuildBtn.textContent='Building...';rebuildBtn.disabled=true;
    \\  fetch('/api/push/'+SCHEMATIC_SLUG,{method:'POST'}).then(function(r){
    \\    if(!r.ok)throw new Error('Build failed');
    \\    rebuildBtn.textContent='Rebuild';rebuildBtn.disabled=false;
    \\  }).catch(function(e){
    \\    rebuildBtn.textContent='Rebuild';rebuildBtn.disabled=false;
    \\    alert('Build failed: '+e.message);
    \\  });
    \\});
    \\
    \\/* Export KiCad */
    \\var exportBtn=document.getElementById('export-kicad');
    \\var netlistBtn=document.getElementById('export-netlist');
    \\netlistBtn.addEventListener('click',function(){
    \\  netlistBtn.textContent='Exporting...';netlistBtn.disabled=true;
    \\  fetch('/api/export-netlist/'+SCHEMATIC_SLUG).then(function(r){
    \\    if(!r.ok)throw new Error('Export failed');
    \\    return r.blob();
    \\  }).then(function(blob){
    \\    var a=document.createElement('a');a.href=URL.createObjectURL(blob);
    \\    a.download=SCHEMATIC_SLUG+'.net';a.click();
    \\    URL.revokeObjectURL(a.href);
    \\    netlistBtn.textContent='Netlist';netlistBtn.disabled=false;
    \\  }).catch(function(e){
    \\    alert('Export failed: '+e.message);
    \\    netlistBtn.textContent='Netlist';netlistBtn.disabled=false;
    \\  });
    \\});
    \\exportBtn.addEventListener('click',function(){
    \\  exportBtn.textContent='Exporting...';exportBtn.disabled=true;
    \\  fetch('/api/export-kicad/'+SCHEMATIC_SLUG).then(function(r){
    \\    if(!r.ok)throw new Error('Export failed');
    \\    return r.blob();
    \\  }).then(function(blob){
    \\    var a=document.createElement('a');a.href=URL.createObjectURL(blob);
    \\    a.download=SCHEMATIC_SLUG+'-kicad.zip';a.click();
    \\    URL.revokeObjectURL(a.href);
    \\    exportBtn.textContent='Export KiCad';exportBtn.disabled=false;
    \\  }).catch(function(e){
    \\    alert('Export failed: '+e.message);
    \\    exportBtn.textContent='Export KiCad';exportBtn.disabled=false;
    \\  });
    \\});
    \\
    \\/* Hub dragging in edit mode */
    \\var dragHub=null,dragStart={x:0,y:0},hubOrigTx=0,hubOrigTy=0;
    \\canvas.addEventListener('mousedown',function(e){
    \\  if(!editMode)return;var svg=getSvg();if(!svg)return;
    \\  var hub=e.target.closest('.hub-group');
    \\  if(!hub||hub===svg.querySelector('.hub-group'))return;
    \\  dragHub=hub;hub.classList.add('dragging');
    \\  var t=hub.transform.baseVal;
    \\  if(t.numberOfItems===0){var s=svg.createSVGTransform();s.setTranslate(0,0);t.appendItem(s);}
    \\  hubOrigTx=t.getItem(0).matrix.e;hubOrigTy=t.getItem(0).matrix.f;
    \\  var pt=svg.createSVGPoint();pt.x=e.clientX;pt.y=e.clientY;
    \\  var svgP=pt.matrixTransform(svg.getScreenCTM().inverse());
    \\  dragStart={x:svgP.x,y:svgP.y};
    \\  isPanning=false;e.stopPropagation();e.preventDefault();
    \\});
    \\window.addEventListener('mousemove',function(e){
    \\  if(!dragHub)return;var svg=getSvg();if(!svg)return;
    \\  var pt=svg.createSVGPoint();pt.x=e.clientX;pt.y=e.clientY;
    \\  var svgP=pt.matrixTransform(svg.getScreenCTM().inverse());
    \\  var dx=svgP.x-dragStart.x,dy=svgP.y-dragStart.y;
    \\  var snap=10;
    \\  var nx=Math.round((hubOrigTx+dx)/snap)*snap;
    \\  var ny=Math.round((hubOrigTy+dy)/snap)*snap;
    \\  dragHub.transform.baseVal.getItem(0).setTranslate(nx,ny);
    \\});
    \\window.addEventListener('mouseup',function(){
    \\  if(dragHub){dragHub.classList.remove('dragging');dragHub=null;}
    \\});
    \\
    \\/* Build pin name search index: pinName → [{ref, pin_num}] */
    \\var PIN_NAMES={};
    \\for(var ref in COMPONENTS){var info=COMPONENTS[ref];if(info.pins)info.pins.forEach(function(p){
    \\  if(p.pinName){var pn=p.pinName;if(!PIN_NAMES[pn])PIN_NAMES[pn]=[];PIN_NAMES[pn].push({ref:ref,pin:p.num});}
    \\});}
    \\
    \\/* Search */
    \\var searchIdx=-1,searchItems=[];
    \\searchInput.addEventListener('input',function(){
    \\  var q=this.value.toLowerCase().trim();
    \\  searchResults.innerHTML='';searchIdx=-1;searchItems=[];
    \\  if(!q){searchResults.classList.remove('open');return;}
    \\  var results=[];
    \\  SECTIONS.forEach(function(s){if(s.toLowerCase().indexOf(q)>=0)results.push({name:s,type:'section'});});
    \\  for(var ref in COMPONENTS){if(ref.toLowerCase().indexOf(q)>=0)results.push({name:ref,type:'comp'});}
    \\  for(var pname in PIN_NAMES){if(pname.toLowerCase().indexOf(q)>=0){var pp=PIN_NAMES[pname];results.push({name:pp[0].ref+'.'+pp[0].pin+' ('+pname+')',type:'pin',ref:pp[0].ref,pin:pp[0].pin});}}
    \\  for(var net in NETS){if(net.toLowerCase().indexOf(q)>=0)results.push({name:net,type:'net'});}
    \\  results=results.slice(0,20);
    \\  if(results.length===0){searchResults.classList.remove('open');return;}
    \\  searchResults.classList.add('open');
    \\  results.forEach(function(r,i){
    \\    var div=document.createElement('div');div.className='search-result';
    \\    div.innerHTML='<span>'+r.name+'</span><span class="search-result-type '+r.type+'">'+r.type+'</span>';
    \\    div.addEventListener('click',function(){selectSearchResult(r);});
    \\    searchResults.appendChild(div);searchItems.push(div);
    \\  });
    \\  searchItems._data=results;
    \\});
    \\searchInput.addEventListener('keydown',function(e){
    \\  if(e.key==='ArrowDown'){e.preventDefault();searchIdx=Math.min(searchIdx+1,searchItems.length-1);updateSearchSel();}
    \\  else if(e.key==='ArrowUp'){e.preventDefault();searchIdx=Math.max(searchIdx-1,0);updateSearchSel();}
    \\  else if(e.key==='Enter'&&searchIdx>=0){e.preventDefault();selectSearchResult(searchItems._data[searchIdx]);}
    \\  else if(e.key==='Escape'){searchResults.classList.remove('open');searchInput.blur();}
    \\});
    \\function updateSearchSel(){searchItems.forEach(function(el,i){el.classList.toggle('selected',i===searchIdx);});}
    \\function zoomToElement(el){
    \\  var svg=getSvg();if(!svg||!el)return;
    \\  var vb=getVb();if(!vb)return;
    \\  var bb=el.getBBox();if(!bb||bb.width===0)return;
    \\  var pad=80;
    \\  var cx=bb.x+bb.width/2,cy=bb.y+bb.height/2;
    \\  var nw=bb.width+pad*2,nh=bb.height+pad*2;
    \\  var canvasR=canvas.clientWidth/canvas.clientHeight;
    \\  var bbR=nw/nh;
    \\  if(bbR>canvasR){nh=nw/canvasR;}else{nw=nh*canvasR;}
    \\  vb.x=cx-nw/2;vb.y=cy-nh/2;vb.width=nw;vb.height=nh;
    \\}
    \\function selectSearchResult(r){
    \\  searchResults.classList.remove('open');searchInput.value='';clearActive();
    \\  var svg=getSvg();if(!svg)return;
    \\  if(r.type==='section'){
    \\    var el=svg.querySelector('.section[data-section="'+r.name+'"]');
    \\    if(el)zoomToElement(el);
    \\  }else if(r.type==='comp'){
    \\    var el=svg.querySelector('.component[data-ref="'+r.name+'"]');
    \\    if(el){el.classList.add('comp-active');zoomToElement(el);el.dispatchEvent(new MouseEvent('click',{bubbles:true}));}
    \\  }else if(r.type==='pin'){
    \\    var el=svg.querySelector('.component[data-ref="'+r.ref+'"]');
    \\    if(el){el.classList.add('comp-active');zoomToElement(el);el.dispatchEvent(new MouseEvent('click',{bubbles:true}));}
    \\  }else{
    \\    svg.querySelectorAll('.net[data-net="'+r.name+'"]').forEach(function(el){el.classList.add('net-active');});
    \\    var first=svg.querySelector('.net[data-net="'+r.name+'"]');
    \\    if(first){zoomToElement(first);first.dispatchEvent(new MouseEvent('click',{bubbles:true}));}
    \\  }
    \\}
    \\searchInput.addEventListener('blur',function(){setTimeout(function(){searchResults.classList.remove('open');},200);});
    \\document.addEventListener('keydown',function(e){if((e.ctrlKey||e.metaKey)&&e.key==='f'){e.preventDefault();searchInput.focus();searchInput.select();}});
    \\
    \\/* Footprint warnings */
    \\function addFpWarnings(){
    \\  var svg=getSvg();if(!svg)return;
    \\  svg.querySelectorAll('.fp-warn').forEach(function(el){el.remove();});
    \\  for(var ref in COMPONENTS){
    \\    var info=COMPONENTS[ref];
    \\    if(info.fpOk)continue;
    \\    var els=svg.querySelectorAll('.component[data-ref="'+ref+'"]');
    \\    els.forEach(function(el){
    \\      var bb=el.getBBox();if(!bb||bb.width===0)return;
    \\      var g=document.createElementNS('http://www.w3.org/2000/svg','g');
    \\      g.setAttribute('class','fp-warn');
    \\      var tx=bb.x+bb.width-4,ty=bb.y+2;
    \\      g.setAttribute('transform','translate('+tx+','+ty+')');
    \\      var tri=document.createElementNS('http://www.w3.org/2000/svg','polygon');
    \\      tri.setAttribute('points','6,0 12,10 0,10');
    \\      tri.setAttribute('fill','#f59e0b');tri.setAttribute('stroke','#92400e');tri.setAttribute('stroke-width','0.5');
    \\      var txt=document.createElementNS('http://www.w3.org/2000/svg','text');
    \\      txt.setAttribute('x','6');txt.setAttribute('y','9.5');
    \\      txt.setAttribute('text-anchor','middle');txt.setAttribute('font-size','8');
    \\      txt.setAttribute('font-weight','bold');txt.setAttribute('fill','#451a03');
    \\      txt.textContent='!';
    \\      var title=document.createElementNS('http://www.w3.org/2000/svg','title');
    \\      title.textContent='Footprint "'+info.footprint+'" has no pad data';
    \\      g.appendChild(title);g.appendChild(tri);g.appendChild(txt);
    \\      el.appendChild(g);
    \\    });
    \\  }
    \\}
    \\addFpWarnings();
    \\
    \\/* Live update polling */
    \\var liveV=0;
    \\setInterval(function(){
    \\  fetch('/api/version/'+DESIGN_NAME).then(function(r){return r.json();}).then(function(d){
    \\    if(d.version>liveV){liveV=d.version;
    \\      fetch('/api/svg/'+DESIGN_NAME).then(function(r){return r.text();}).then(function(s){
    \\        var oldSvg=getSvg();
    \\        var tmp=document.createElement('div');tmp.innerHTML=s;
    \\        var newSvg=tmp.querySelector('svg');
    \\        if(newSvg&&oldSvg){
    \\          var oldVb=oldSvg.viewBox.baseVal;
    \\          var saved={x:oldVb.x,y:oldVb.y,w:oldVb.width,h:oldVb.height};
    \\          oldSvg.parentNode.replaceChild(newSvg,oldSvg);
    \\          var vb=newSvg.viewBox.baseVal;vb.x=saved.x;vb.y=saved.y;vb.width=saved.w;vb.height=saved.h;
    \\          addFpWarnings();
    \\        }
    \\      });
    \\    }
    \\  }).catch(function(){});
    \\},500);
    \\
    \\/* Block Diagram toggle */
    \\var blockBtn=document.getElementById('block-diagram-btn');
    \\var blockMode=false;var savedSvg=null;
    \\if(blockBtn)blockBtn.addEventListener('click',function(){
    \\  if(blockMode){
    \\    blockMode=false;blockBtn.textContent='Block Diagram';
    \\    if(savedSvg){var c=document.getElementById('schematic-canvas');
    \\    var old=c.querySelector('svg');if(old)c.removeChild(old);
    \\    c.insertAdjacentHTML('beforeend',savedSvg);savedSvg=null;}
    \\  }else{
    \\    blockBtn.textContent='Loading...';blockBtn.disabled=true;
    \\    fetch('/api/block-diagram/'+DESIGN_NAME).then(function(r){return r.text();}).then(function(svg){
    \\      var c=document.getElementById('schematic-canvas');
    \\      var old=c.querySelector('svg');
    \\      if(old){savedSvg=old.outerHTML;c.removeChild(old);}
    \\      c.insertAdjacentHTML('beforeend',svg);
    \\      blockMode=true;blockBtn.textContent='Schematic';blockBtn.disabled=false;
    \\    }).catch(function(e){
    \\      alert('Block diagram failed: '+e.message);
    \\      blockBtn.textContent='Block Diagram';blockBtn.disabled=false;
    \\    });
    \\  }
    \\});
    \\
    \\}catch(err){console.error('EDA JS error:',err);document.title='JS ERROR: '+err.message;}})();
    \\
;
