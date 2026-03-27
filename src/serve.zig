const std = @import("std");
const httpz = @import("httpz");
const Evaluator = @import("eval/evaluator.zig").Evaluator;
const emit = @import("emit.zig");
const render_svg = @import("render_svg.zig");
const env_mod = @import("eval/env.zig");

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
            .max_body_size = 1024 * 1024,
            .buffer_size = 64 * 1024,
            .max_header_count = 64,
        },
        .response = .{ .max_header_count = 32 },
        .workers = .{
            .large_buffer_size = 512 * 1024,
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
    router.get("/library", libraryPage, .{});
    router.post("/api/upload-symbol", uploadSymbolApi, .{});
    router.post("/api/upload-footprint", uploadFootprintApi, .{});

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

    const svg = render_svg.renderSchematic(ctx.allocator, block) catch "";
    const resolved = emit.emitResolved(ctx.allocator, block) catch "";

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

    // Instance table
    try w.writeAll("<h2>Instances</h2><table><tr><th>Ref</th><th>Component</th><th>Value</th></tr>");
    try writeInstances(w, block, "");
    try w.writeAll("</table>");

    // Nets table
    try w.writeAll("<h2>Nets</h2><table><tr><th>Net</th><th>Pins</th></tr>");
    try writeNets(w, block, "");
    try w.writeAll("</table>");

    // Resolved
    try w.writeAll("<h2>Resolved</h2><details><summary>Show .sexp</summary><pre>");
    for (resolved) |c| switch (c) {
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '&' => try w.writeAll("&amp;"),
        else => try w.writeByte(c),
    };
    try w.writeAll("</pre></details>");

    // Close page div
    try w.writeAll("</div>");

    // Sidebar
    try w.writeAll("<div class=\"sidebar\" id=\"sidebar\">");
    try w.writeAll("<button class=\"sidebar-close\" id=\"sidebar-close\">&times;</button>");
    try w.writeAll("<div id=\"sidebar-content\"></div>");
    try w.writeAll("</div>");

    // Generate COMPONENTS JSON
    try w.print("<script>var SCHEMATIC_SLUG='{s}';var COMPONENTS={{", .{name});
    _ = try writeComponentsJson(w, block, "");
    try w.writeAll("};var NETS={");
    _ = try writeNetsJson(w, block, "");
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

    // Upload sections
    try w.writeAll(
        \\<h2>Upload KiCad Symbol (.kicad_sym)</h2>
        \\<div class="upload-box" id="sym-drop">
        \\<p>Drag & drop .kicad_sym file here, or</p>
        \\<label class="upload-btn">Choose file<input type="file" id="sym-file" accept=".kicad_sym"></label>
        \\</div>
        \\<div id="sym-result"></div>
        \\
        \\<h2>Upload KiCad Footprint (.kicad_mod)</h2>
        \\<div class="upload-box" id="fp-drop">
        \\<p>Drag & drop .kicad_mod file here, or</p>
        \\<label class="upload-btn">Choose file<input type="file" id="fp-file" accept=".kicad_mod"></label>
        \\</div>
        \\<div id="fp-result"></div>
    );

    // List existing symbols
    try w.writeAll("<h2>Symbols</h2><table><tr><th>Name</th></tr>");
    {
        const sym_path = try std.fmt.allocPrint(ctx.allocator, "{s}/lib/symbols", .{ctx.project_dir});
        defer ctx.allocator.free(sym_path);
        var dir = std.fs.cwd().openDir(sym_path, .{ .iterate = true }) catch {
            try w.writeAll("<tr><td>No symbols directory</td></tr>");
            try w.writeAll("</table>");
            // skip to footprints
            try w.writeAll("<h2>Footprints</h2><table><tr><th>Name</th></tr>");
            try w.writeAll("</table></body></html>");
            res.body = buf.items;
            res.content_type = .HTML;
            return;
        };
        defer dir.close();
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".sexp")) {
                const name = entry.name[0 .. entry.name.len - 5];
                try w.print("<tr><td>{s}</td></tr>", .{name});
            }
        }
    }
    try w.writeAll("</table>");

    // List existing footprints
    try w.writeAll("<h2>Footprints</h2><table><tr><th>Name</th></tr>");
    {
        const fp_path = try std.fmt.allocPrint(ctx.allocator, "{s}/lib/footprints", .{ctx.project_dir});
        defer ctx.allocator.free(fp_path);
        var dir = std.fs.cwd().openDir(fp_path, .{ .iterate = true }) catch {
            try w.writeAll("<tr><td>No footprints directory</td></tr>");
            try w.writeAll("</table>");
            try w.writeAll("</body></html>");
            res.body = buf.items;
            res.content_type = .HTML;
            return;
        };
        defer dir.close();
        var iter = dir.iterate();
        while (try iter.next()) |entry| {
            if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".sexp")) {
                const name = entry.name[0 .. entry.name.len - 5];
                try w.print("<tr><td>{s}</td></tr>", .{name});
            }
        }
    }
    try w.writeAll("</table>");

    // Upload JS
    try w.writeAll(
        \\<script>
        \\function setupUpload(dropId, fileId, resultId, endpoint) {
        \\  var drop = document.getElementById(dropId);
        \\  var fileInput = document.getElementById(fileId);
        \\  var result = document.getElementById(resultId);
        \\  drop.addEventListener('dragover', function(e) { e.preventDefault(); drop.classList.add('dragover'); });
        \\  drop.addEventListener('dragleave', function() { drop.classList.remove('dragover'); });
        \\  drop.addEventListener('drop', function(e) {
        \\    e.preventDefault(); drop.classList.remove('dragover');
        \\    if (e.dataTransfer.files.length > 0) uploadFile(e.dataTransfer.files[0]);
        \\  });
        \\  fileInput.addEventListener('change', function() { if (this.files.length > 0) uploadFile(this.files[0]); });
        \\  function uploadFile(file) {
        \\    result.className = 'result'; result.textContent = 'Converting ' + file.name + '...';
        \\    var reader = new FileReader();
        \\    reader.onload = function() {
        \\      fetch(endpoint, { method: 'POST', headers: { 'Content-Type': 'application/octet-stream', 'X-Filename': file.name }, body: reader.result })
        \\        .then(function(r) { return r.text().then(function(t) { return { ok: r.ok, text: t }; }); })
        \\        .then(function(d) { result.className = d.ok ? 'result ok' : 'result err'; result.textContent = d.text; if (d.ok) setTimeout(function() { location.reload(); }, 1000); })
        \\        .catch(function(e) { result.className = 'result err'; result.textContent = 'Error: ' + e; });
        \\    };
        \\    reader.readAsArrayBuffer(file);
        \\  }
        \\}
        \\setupUpload('sym-drop', 'sym-file', 'sym-result', '/api/upload-symbol');
        \\setupUpload('fp-drop', 'fp-file', 'fp-result', '/api/upload-footprint');
        \\</script>
    );

    try w.writeAll("</body></html>");
    res.body = buf.items;
    res.content_type = .HTML;
}

fn uploadSymbolApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const body = req.body() orelse {
        res.status = 400;
        res.body = "No file data";
        return;
    };

    // Get filename from header
    const filename = req.header("x-filename") orelse "unknown.kicad_sym";

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

    // Write to lib/symbols/
    const dir_path = std.fmt.allocPrint(ctx.allocator, "{s}/lib/symbols", .{ctx.project_dir}) catch {
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

    const msg = std.fmt.allocPrint(ctx.allocator, "Converted {s} -> lib/symbols/{s}.sexp", .{ filename, safe_name.items }) catch {
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
            try w.print("{s}.{d}", .{ pin.ref_des, pin.pin });
        }
        try w.writeAll("</td></tr>");
    }
    for (block.sub_blocks) |sb| {
        try writeNets(w, sb.block, sb.name);
    }
}

// ── JSON helpers ───────────────────────────────────────────────────────

/// Write COMPONENTS JSON object contents. Returns true if any items were written.
fn writeComponentsJson(w: anytype, block: *const env_mod.DesignBlock, prefix: []const u8) !bool {
    var written = false;
    for (block.instances) |inst| {
        if (written) try w.writeAll(",");
        try w.writeAll("\"");
        if (prefix.len > 0) try w.print("{s}/", .{prefix});
        try w.print("{s}\":{{\"symbol\":\"{s}\",\"footprint\":\"{s}\",\"value\":\"{s}\",\"note\":\"", .{
            inst.ref_des,
            inst.symbol,
            inst.footprint,
            inst.value,
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
                try w.print("{{\"num\":{d},\"net\":\"", .{pp.pin});
                try writeJsonEscaped(w, pp.net);
                try w.writeAll("\",\"part\":\"");
                try writeJsonEscaped(w, part.name);
                try w.writeAll("\"}");
                pin_written = true;
            }
        }
        try w.writeAll("]}");
        written = true;
    }
    for (block.sub_blocks) |sb| {
        if (written) try w.writeAll(",");
        const sub_written = try writeComponentsJson(w, sb.block, sb.name);
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
            try w.print("{s}.{d}\"", .{ pin.ref_des, pin.pin });
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
    \\.sidebar-pins li { padding: 0.25rem 0; border-bottom: 1px solid #2a2a4a; font-size: 0.8rem; font-family: monospace; }
    \\.sidebar-pins .pin-num { color: #888; margin-right: 0.5rem; }
    \\.sidebar-pins .pin-name { color: #e0e0e0; }
    \\.sidebar-pins .pin-type { color: #6a6; margin-left: 0.5rem; font-size: 0.75rem; }
    \\.sidebar-pins .pin-net { display: block; color: #e8c547; font-size: 0.75rem; margin-left: 1.5rem; }
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
    \\svg .component:hover rect:not(.hit-area),svg .component:hover line,svg .component:hover path { filter: brightness(1.3); }
    \\svg .component.comp-active rect:not(.hit-area) { stroke: #e55 !important; }
    \\svg .component.comp-active line { stroke: #e55 !important; }
    \\svg .component.comp-active path { stroke: #e55 !important; }
    \\svg .component.comp-active polyline { stroke: #e55 !important; }
    \\svg .component.comp-active text { fill: #e55 !important; }
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
    \\var isPanning=false,panStart={x:0,y:0},vbStart={x:0,y:0};
    \\var editMode=false;
    \\/* Pan */
    \\canvas.addEventListener('mousedown',function(e){
    \\  if(e.target.closest('.component')||e.target.closest('.net'))return;
    \\  var vb=getVb();if(!vb)return;
    \\  isPanning=true;panStart={x:e.clientX,y:e.clientY};
    \\  vbStart={x:vb.x,y:vb.y};
    \\});
    \\window.addEventListener('mousemove',function(e){
    \\  if(!isPanning)return;var vb=getVb();if(!vb)return;
    \\  var dx=(e.clientX-panStart.x)*(vb.width/canvas.clientWidth);
    \\  var dy=(e.clientY-panStart.y)*(vb.height/canvas.clientHeight);
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
    \\  var comp=e.target.closest('.component');
    \\  if(comp){
    \\    var ref=comp.getAttribute('data-ref');if(!ref)return;
    \\    clearActive();var s=getSvg();
    \\    if(s)s.querySelectorAll('.component[data-ref="'+ref+'"]').forEach(function(el){el.classList.add('comp-active');});
    \\    var info=COMPONENTS[ref]||{};
    \\    var html='<h3>'+ref+'</h3>';
    \\    html+='<div class="sidebar-section"><div class="sidebar-label">Symbol</div><div class="sidebar-value">'+(info.symbol||'-')+'</div></div>';
    \\    html+='<div class="sidebar-section"><div class="sidebar-label">Footprint</div><div class="sidebar-value">'+(info.footprint||'-')+'</div></div>';
    \\    if(info.value){html+='<div class="sidebar-section"><div class="sidebar-label">Value</div><div style="display:flex;gap:0.5rem;align-items:center;"><input id="value-edit" type="text" value="'+info.value+'" style="background:#161b22;border:1px solid #444;border-radius:4px;color:#e0e0e0;padding:0.3rem 0.5rem;font-family:monospace;font-size:0.85rem;width:120px;outline:none;" /><button id="value-save" style="background:#2a4a2a;color:#4a9;border:1px solid #4a9;border-radius:4px;padding:0.3rem 0.6rem;font-size:0.75rem;cursor:pointer;">Save</button></div></div>';}else{html+='<div class="sidebar-section"><div class="sidebar-label">Value</div><div class="sidebar-value">-</div></div>';}
    \\    if(info.note)html+='<div class="sidebar-section"><div class="sidebar-label">Note</div><div class="sidebar-note">'+info.note+'</div></div>';
    \\    /* Build pin-to-net map for this component */
    \\    var pinNets={};
    \\    for(var net in NETS){var members=NETS[net];for(var i=0;i<members.length;i++){var m=members[i];if(m.indexOf(ref+'.')===0){var pn=m.substring(ref.length+1);if(!pinNets[pn])pinNets[pn]=[];pinNets[pn].push(net);}}}
    \\    /* Build pin-to-part map from component data */
    \\    var pinParts={};
    \\    if(info.pins)info.pins.forEach(function(p){pinParts[p.num]={net:p.net,part:p.part};});
    \\    /* Group pins by (part, net) */
    \\    var pinList=Object.keys(pinNets).sort(function(a,b){return(parseInt(a)||0)-(parseInt(b)||0);});
    \\    if(pinList.length>0){
    \\      var groups=[];var gmap={};
    \\      pinList.forEach(function(pn){
    \\        var net=pinNets[pn].join(',');
    \\        var pp=pinParts[parseInt(pn)];
    \\        var part=pp?pp.part:'';
    \\        var key=part+'|'+net;
    \\        if(!gmap[key]){gmap[key]={part:part,nets:pinNets[pn],pins:[]};groups.push(gmap[key]);}
    \\        gmap[key].pins.push(pn);
    \\      });
    \\      html+='<div class="sidebar-section"><div class="sidebar-label">Pins</div><ul class="sidebar-pins">';
    \\      var lastPart='';
    \\      groups.forEach(function(g){
    \\        if(g.part&&g.part!==lastPart){lastPart=g.part;html+='<li style="color:#58a6ff;font-weight:bold;border-bottom:1px solid #333;padding-top:0.5rem;">'+g.part+'</li>';}
    \\        html+='<li><span class="pin-num">'+g.pins.join(',')+'</span> ';
    \\        g.nets.forEach(function(n,i){
    \\          if(i>0)html+=', ';
    \\          html+='<a href="#" class="net-link" data-net="'+n+'" style="color:#e8c547;text-decoration:none;cursor:pointer;">'+n+'</a>';
    \\        });
    \\        html+='</li>';
    \\      });
    \\      html+='</ul></div>';
    \\    }
    \\    openSidebar(html);
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
    \\            var c2=svg.querySelector('.component[data-ref="'+r2+'"]');
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
    \\        var comp=svg.querySelector('.component[data-ref="'+ref+'"]');
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
    \\/* Search */
    \\var searchIdx=-1,searchItems=[];
    \\searchInput.addEventListener('input',function(){
    \\  var q=this.value.toLowerCase().trim();
    \\  searchResults.innerHTML='';searchIdx=-1;searchItems=[];
    \\  if(!q){searchResults.classList.remove('open');return;}
    \\  var results=[];
    \\  for(var ref in COMPONENTS){if(ref.toLowerCase().indexOf(q)>=0)results.push({name:ref,type:'comp'});}
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
    \\function selectSearchResult(r){
    \\  searchResults.classList.remove('open');searchInput.value='';clearActive();
    \\  if(r.type==='comp'){
    \\    var el=svg.querySelector('.component[data-ref="'+r.name+'"]');
    \\    if(el){el.classList.add('comp-active');el.dispatchEvent(new MouseEvent('click',{bubbles:true}));}
    \\  }else{
    \\    getSvg().querySelectorAll('.net[data-net="'+r.name+'"]').forEach(function(el){el.classList.add('net-active');});
    \\    var first=svg.querySelector('.net[data-net="'+r.name+'"]');
    \\    if(first)first.dispatchEvent(new MouseEvent('click',{bubbles:true}));
    \\  }
    \\}
    \\searchInput.addEventListener('blur',function(){setTimeout(function(){searchResults.classList.remove('open');},200);});
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
    \\        }
    \\      });
    \\    }
    \\  }).catch(function(){});
    \\},500);
    \\
    \\}catch(err){console.error('EDA JS error:',err);document.title='JS ERROR: '+err.message;}})();
    \\
;
