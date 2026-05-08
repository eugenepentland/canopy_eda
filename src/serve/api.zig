const std = @import("std");
const httpz = @import("httpz");
const infra_fs = @import("../infra/fs.zig");
const log = @import("../infra/log.zig");
const paths = @import("../paths.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const render_json = @import("../render_json.zig");
const export_kicad = @import("../export_kicad.zig");
const bom = @import("../bom.zig");
const fp_mod = @import("../export_kicad_footprint.zig");
const erc_mod = @import("../erc.zig");
const env_mod = @import("../eval/env.zig");
const parser_mod = @import("../sexpr/parser.zig");
const bom_html = @import("bom_html.zig");
const mcp_tools = @import("mcp_tools.zig");
const review_mod = @import("../review.zig");
const review_json_mod = @import("../review_json.zig");
const review_md_mod = @import("../review_md.zig");
const req_checks = @import("../req_checks.zig");
const edit_mod = @import("edit.zig");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;

// ── Constants ─────────────────────────────────────────────────────
const HTTP_NOT_FOUND: u16 = 404;
const HTTP_BAD_REQUEST: u16 = 400;
const HTTP_INTERNAL_ERROR: u16 = 500;

const MAX_SOURCE_BYTES: usize = 10 * 1024 * 1024;
const STREAM_BUF_BYTES: usize = 8192;

// Headers
const HEADER_CORS_ALLOW_ORIGIN = "access-control-allow-origin";
const HEADER_CONTENT_TYPE = "Content-Type";
const HEADER_CONTENT_DISPOSITION = "Content-Disposition";
const CONTENT_TYPE_ZIP = "application/zip";

// JSON fragments / response templates
const ERR_BUILD = "Build error";
const ERR_NO_BODY_JSON = "{\"error\":\"no body\"}";
const OK_JSON_TRUE = "{\"ok\":true}";
const OK_VERSION_TEMPLATE = "{{\"ok\":true,\"version\":{d}}}";
const ERR_OK_FALSE_TEMPLATE = "{{\"ok\":false,\"error\":\"{s}\"}}";
const NAME_FIELD_PREFIX = "{\"name\":";
const EMPTY_DATASHEETS_REQS = ",\"datasheets\":[],\"requirements\":[]";

/// Error set for HTTP handlers in this module. Wide because handlers
/// orchestrate many subsystems (eval, render, parser, file IO, BOM resolve)
/// and propagate the worst case via `try`. httpz turns any leaked error
/// into a 5xx body, so the union just needs to be a superset of every
/// callee — the type itself is informational.
pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error ||
    std.fs.File.WriteError || std.fs.File.OpenError || std.fs.File.ReadError ||
    std.fs.Dir.MakeError || std.fs.Dir.StatFileError ||
    @import("../bom_resolve.zig").ResolveError ||
    @import("../sexpr/parser.zig").ParseError ||
    error{
        FileTooBig,
        StreamTooLong,
        EndOfStream,
        Canceled,
        ConnectionTimedOut,
        NotOpenForReading,
        SocketNotConnected,
        ReadOnlyFileSystem,
        LinkQuotaExceeded,
        InvalidEscapeSequence,
    };

/// POST /api/push/:name — re-evaluate the design's `.sexp` source, replace the
/// live scene-graph JSON, and bump the version counter so the browser viewer
/// picks up the rebuild on its next `/api/version/:name` poll.
pub fn pushApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = HTTP_NOT_FOUND;
        return;
    };

    const board_path = try paths.designSourcePath(ctx.allocator, ctx.project_dir, name);
    defer ctx.allocator.free(board_path);

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();

    const result = eval.evalFile(board_path) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = ERR_BUILD;
        return;
    };

    const block = switch (result) {
        .design_block => |b| b,
        else => {
            res.status = HTTP_INTERNAL_ERROR;
            return;
        },
    };

    const new_layout = render_json.renderSceneGraph(ctx.allocator, block, ctx.project_dir) catch null;
    serve_root.setLiveLayoutJson(new_layout);
    const v = serve_root.bumpLiveVersion(name);

    std.debug.print("Pushed {s} (v{d})\n", .{ name, v });
    res.body = "ok";
}

/// GET /api/version/:name — return `{"version":N}`. The schematic viewer
/// polls this every ~500 ms and reloads the scene graph when N changes.
/// Bumped by `pushApi` and the MCP mutation tools.
pub fn versionApi(_: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = HTTP_NOT_FOUND;
        return;
    };
    const v = serve_root.getLiveVersion(name);

    res.content_type = .JSON;
    res.header(HEADER_CORS_ALLOW_ORIGIN, "*");
    const w = res.writer();
    try w.print("{{\"version\":{d}}}", .{v});
}

/// GET /api/scene-graph/:name — return the cached schematic scene-graph JSON
/// produced by the last build/push. Read under `live_mutex`; falls back to a
/// minimal `{"error":"no layout"}` body when nothing has been pushed yet.
pub fn sceneGraphApi(_: *Handler, _: *httpz.Request, res: *httpz.Response) HandlerError!void {
    serve_root.live_mutex.lock();
    const data = serve_root.live_layout_json;
    serve_root.live_mutex.unlock();

    res.content_type = .JSON;
    res.header(HEADER_CORS_ALLOW_ORIGIN, "*");
    res.body = data orelse "{\"error\":\"no layout\"}";
}

/// Serve a component's pinout file (lib/pinouts/:name.sexp) as JSON so the
/// schematic viewer can show the full pin map — primary function + every
/// alternate function — next to the ref-des. Lets the user verify, for
/// example, that the pin they wired to XSPIM_P1_IO5 really does expose that
/// peripheral on the part.
pub fn pinoutApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name_raw = req.param("name") orelse {
        res.status = HTTP_NOT_FOUND;
        return;
    };
    // Decode before validating so `%2e%2e` can't slip past the traversal check,
    // and so library files with reserved chars (e.g. `…#pbf`) actually resolve.
    const name = try urlDecodeAlloc(ctx.allocator, name_raw);
    if (name.len == 0 or std.mem.indexOfAny(u8, name, "/\\") != null or std.mem.indexOf(u8, name, "..") != null) {
        res.status = HTTP_BAD_REQUEST;
        res.body = "{\"error\":\"invalid component name\"}";
        res.content_type = .JSON;
        return;
    }

    const path = try std.fmt.allocPrint(ctx.allocator, "{s}/lib/pinouts/{s}.sexp", .{ ctx.project_dir, name });
    defer ctx.allocator.free(path);

    const content = infra_fs.cwd().readFileAlloc(ctx.allocator, path, 1024 * 256) catch {
        res.status = HTTP_NOT_FOUND;
        res.content_type = .JSON;
        res.body = "{\"error\":\"pinout not found\"}";
        return;
    };

    const nodes = parser_mod.parse(ctx.allocator, content) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.content_type = .JSON;
        res.body = "{\"error\":\"parse error\"}";
        return;
    };

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(ctx.allocator);

    try w.writeAll("{\"component\":");
    try writeJsonString(w, name);
    try writeComponentLibInfo(ctx.allocator, w, ctx.project_dir, name);
    try w.writeAll(",\"pins\":[");

    var first_pin = true;
    if (nodes.len > 0) {
        if (nodes[0].asList()) |top| {
            if (top.len >= 2) {
                const head = top[0].asAtom() orelse "";
                if (std.mem.eql(u8, head, "pinout")) {
                    for (top[2..]) |child| {
                        const cl = child.asList() orelse continue;
                        if (cl.len < 3) continue;
                        const ch = cl[0].asAtom() orelse continue;
                        if (!std.mem.eql(u8, ch, "pin")) continue;
                        const pin_id = cl[1].asAtom() orelse cl[1].asString() orelse continue;
                        const fn_name = cl[2].asString() orelse cl[2].asAtom() orelse continue;

                        if (!first_pin) try w.writeAll(",");
                        first_pin = false;
                        try w.writeAll("{\"id\":");
                        try writeJsonString(w, pin_id);
                        try w.writeAll(",\"fn\":");
                        try writeJsonString(w, fn_name);
                        try w.writeAll(",\"alts\":[");

                        var first_alt = true;
                        if (cl.len > 3) {
                            for (cl[3..]) |alt_node| {
                                const al = alt_node.asList() orelse continue;
                                if (al.len < 2) continue;
                                const hd = al[0].asAtom() orelse continue;
                                if (!std.mem.eql(u8, hd, "alt")) continue;
                                const alt_name = al[1].asString() orelse al[1].asAtom() orelse continue;
                                const etype = if (al.len >= 3) (al[2].asAtom() orelse al[2].asString() orelse "") else "";

                                if (!first_alt) try w.writeAll(",");
                                first_alt = false;
                                try w.writeAll(NAME_FIELD_PREFIX);
                                try writeJsonString(w, alt_name);
                                try w.writeAll(",\"type\":");
                                try writeJsonString(w, etype);
                                try w.writeAll("}");
                            }
                        }
                        try w.writeAll("]}");
                    }
                }
            }
        }
    }

    try w.writeAll("]}");

    res.content_type = .JSON;
    res.header(HEADER_CORS_ALLOW_ORIGIN, "*");
    res.body = buf.items;
}

/// Append `"datasheets":[{name,size}], "requirements":[{text,pdf,page}]` to
/// the pinout JSON. Reads `lib/components/<name>.sexp` and scans for
/// `(datasheet ...)` and `(requirement ...)` forms. Emits empty arrays when
/// the component file isn't found — pinouts without a sibling component
/// definition (legacy) still render, just with nothing to link to.
fn writeComponentLibInfo(
    allocator: std.mem.Allocator,
    w: anytype,
    project_dir: []const u8,
    name: []const u8,
) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}/lib/components/{s}.sexp", .{ project_dir, name });
    defer allocator.free(path);
    const content = infra_fs.cwd().readFileAlloc(allocator, path, 1024 * 512) catch {
        try w.writeAll(EMPTY_DATASHEETS_REQS);
        return;
    };
    const nodes = parser_mod.parse(allocator, content) catch {
        try w.writeAll(EMPTY_DATASHEETS_REQS);
        return;
    };
    if (nodes.len == 0) {
        try w.writeAll(EMPTY_DATASHEETS_REQS);
        return;
    }
    const top = nodes[0].asList() orelse {
        try w.writeAll(EMPTY_DATASHEETS_REQS);
        return;
    };

    try w.writeAll(",\"datasheets\":[");
    var first_ds = true;
    for (top[1..]) |child| {
        const cl = child.asList() orelse continue;
        if (cl.len < 2) continue;
        const head = cl[0].asAtom() orelse continue;
        if (!std.mem.eql(u8, head, "datasheet")) continue;
        const ds = cl[1].asString() orelse (cl[1].asAtom() orelse continue);
        if (!first_ds) try w.writeAll(",");
        first_ds = false;
        const size = datasheetSize(allocator, project_dir, ds);
        try w.writeAll(NAME_FIELD_PREFIX);
        try writeJsonString(w, ds);
        try w.print(",\"size\":{d}}}", .{size});
    }
    try w.writeAll("]");

    try w.writeAll(",\"requirements\":[");
    var first_r = true;
    for (top[1..]) |child| {
        const cl = child.asList() orelse continue;
        if (cl.len < 2) continue;
        const head = cl[0].asAtom() orelse continue;
        if (!std.mem.eql(u8, head, "requirement")) continue;
        const text = cl[1].asString() orelse continue;
        if (!first_r) try w.writeAll(",");
        first_r = false;
        try w.writeAll("{\"text\":");
        try writeJsonString(w, text);
        for (cl[2..]) |extra| {
            if (env_mod.parseNoteRef(extra)) |r| {
                try w.writeAll(",\"pdf\":");
                try writeJsonString(w, r.pdf);
                try w.print(",\"page\":{d}", .{r.page});
                if (r.quote) |q| {
                    try w.writeAll(",\"quote\":");
                    try writeJsonString(w, q);
                }
                break;
            }
        }
        try w.writeAll("}");
    }
    try w.writeAll("]");
}

/// Stat `lib/datasheets/<name>` and return the file size, or 0 if missing.
/// Used by the sidebar pinout panel so users can see which declared
/// datasheets have actually been uploaded without an extra round-trip.
fn datasheetSize(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8) u64 {
    const path = std.fmt.allocPrint(allocator, "{s}/lib/datasheets/{s}", .{ project_dir, name }) catch return 0;
    defer allocator.free(path);
    const f = infra_fs.cwd().openFile(path, .{}) catch return 0;
    defer f.close();
    const stat = f.stat() catch return 0;
    return stat.size;
}

/// GET /api/export-kicad/:name — build the design, resolve BOM identities,
/// and stream back a `<name>-kicad.zip` containing the KiCad schematic,
/// netlist, and per-instance footprint files.
pub fn exportKicadApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = HTTP_NOT_FOUND;
        return;
    };

    const board_path = try paths.designSourcePath(ctx.allocator, ctx.project_dir, name);
    defer ctx.allocator.free(board_path);

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();

    const result = eval.evalFile(board_path) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = ERR_BUILD;
        return;
    };

    const block = switch (result) {
        .design_block => |b| b,
        else => {
            res.status = HTTP_INTERNAL_ERROR;
            return;
        },
    };

    const bom_path = paths.designSiblingPath(ctx.allocator, ctx.project_dir, name, ".bom") catch {
        res.status = HTTP_INTERNAL_ERROR;
        return;
    };
    try bom.resolveIdentities(ctx.allocator, block, bom_path, ctx.project_dir);

    const zip_data = export_kicad.exportKicadZip(ctx.allocator, block, ctx.project_dir, name) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = "Export error";
        return;
    };

    const disposition = std.fmt.allocPrint(ctx.allocator, "attachment; filename=\"{s}-kicad.zip\"", .{name}) catch {
        res.status = HTTP_INTERNAL_ERROR;
        return;
    };

    res.header(HEADER_CONTENT_TYPE, CONTENT_TYPE_ZIP);
    res.header(HEADER_CONTENT_DISPOSITION, disposition);
    res.body = zip_data;
}

/// GET /api/export-netlist/:name — build the design and return just the
/// KiCad `.net` file (no footprints, no zip). Used by external tools that
/// only care about connectivity for routing or simulation.
pub fn exportNetlistApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = HTTP_NOT_FOUND;
        return;
    };

    const board_path = try paths.designSourcePath(ctx.allocator, ctx.project_dir, name);
    defer ctx.allocator.free(board_path);

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();

    const result = eval.evalFile(board_path) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = ERR_BUILD;
        return;
    };

    const block = switch (result) {
        .design_block => |b| b,
        else => {
            res.status = HTTP_INTERNAL_ERROR;
            return;
        },
    };

    const bom_path = paths.designSiblingPath(ctx.allocator, ctx.project_dir, name, ".bom") catch {
        res.status = HTTP_INTERNAL_ERROR;
        return;
    };
    try bom.resolveIdentities(ctx.allocator, block, bom_path, ctx.project_dir);

    const netlist = export_kicad.exportNetlistOnly(ctx.allocator, block, ctx.project_dir, name) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = "Export error";
        return;
    };

    const disposition = std.fmt.allocPrint(ctx.allocator, "attachment; filename=\"{s}.net\"", .{name}) catch {
        res.status = HTTP_INTERNAL_ERROR;
        return;
    };

    res.header(HEADER_CONTENT_TYPE, "text/plain");
    res.header(HEADER_CONTENT_DISPOSITION, disposition);
    res.body = netlist;
}

/// GET /api/export-bom-csv/:name — build the design and stream the parts
/// list as `<name>-bom.csv`. Same column layout as the BOM table on the
/// review page; suitable for hand-off to procurement.
pub fn exportBomCsvApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = HTTP_NOT_FOUND;
        return;
    };

    const board_path = try paths.designSourcePath(ctx.allocator, ctx.project_dir, name);
    defer ctx.allocator.free(board_path);

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();

    const result = eval.evalFile(board_path) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = ERR_BUILD;
        return;
    };

    const block = switch (result) {
        .design_block => |b| b,
        else => {
            res.status = HTTP_INTERNAL_ERROR;
            return;
        },
    };

    // Merge in the persisted BOM (manual MPN, manufacturer, datasheet edits
    // from the schematic page). Without this the CSV reflects only what the
    // .sexp source declares — passives whose MPN was set via the inline
    // editor come out blank.
    const bom_path = try paths.designSiblingPath(ctx.allocator, ctx.project_dir, name, ".bom");
    defer ctx.allocator.free(bom_path);
    bom.resolveIdentities(ctx.allocator, block, bom_path, ctx.project_dir) catch |e| {
        log.warn("resolveIdentities {s} failed: {s}", .{ name, @errorName(e) });
    };

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(ctx.allocator);
    try bom_html.writeBomCsv(w, block);

    const disposition = std.fmt.allocPrint(ctx.allocator, "attachment; filename=\"{s}-bom.csv\"", .{name}) catch {
        res.status = HTTP_INTERNAL_ERROR;
        return;
    };

    res.header(HEADER_CONTENT_TYPE, "text/csv");
    res.header(HEADER_CONTENT_DISPOSITION, disposition);
    res.header(HEADER_CORS_ALLOW_ORIGIN, "*");
    res.body = buf.items;
}

/// GET /api/export-review/:name — design-review package as a zip with two
/// files: `<name>-review.md` (full markdown report including system block
/// diagram, per-hub schematics, power tables, ERC, per-IC checklist, and
/// the verbatim source) plus `<name>-bom.csv` (parts list as CSV).
pub fn exportReviewPackageApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = HTTP_NOT_FOUND;
        return;
    };

    // Build a fully-populated ReviewDoc using the same path the live page
    // uses — ensures the export reflects exactly what the reviewer sees.
    const doc = buildDocForName(ctx.allocator, ctx.project_dir, name) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = ERR_BUILD;
        return;
    };

    // Re-evaluate so we have access to the underlying block + check_results.
    // This duplicates the work in buildDocForName but avoids leaking those
    // intermediates through the function signature; the cost is one extra
    // eval per export which is acceptable for a manual operation.
    const board_path = paths.designSourcePath(ctx.allocator, ctx.project_dir, name) catch {
        res.status = HTTP_INTERNAL_ERROR;
        return;
    };
    defer ctx.allocator.free(board_path);

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();
    const result = eval.evalFile(board_path) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = ERR_BUILD;
        return;
    };
    const block = switch (result) {
        .design_block => |b| b,
        else => {
            res.status = HTTP_INTERNAL_ERROR;
            return;
        },
    };
    var check_results = req_checks.runChecks(ctx.allocator, &eval, block) catch
        std.StringHashMapUnmanaged([]req_checks.Result).empty;
    req_checks.applyVerifications(&check_results, block, block.instances);

    // Read the source file verbatim for embedding.
    const source = infra_fs.cwd().readFileAlloc(ctx.allocator, board_path, 8 * 1024 * 1024) catch &[_]u8{};

    // Render markdown.
    const md = review_md_mod.renderToMarkdown(ctx.allocator, block, ctx.project_dir, name, doc, source, &check_results) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = "Markdown render error";
        return;
    };

    // Render BOM CSV.
    var csv_buf: std.ArrayListUnmanaged(u8) = .empty;
    bom_html.writeBomCsv(csv_buf.writer(ctx.allocator), block) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = "BOM CSV error";
        return;
    };

    // Filenames inside the zip include the design name so a reviewer who
    // unzips into a shared directory doesn't collide with another design.
    const md_name = std.fmt.allocPrint(ctx.allocator, "{s}-review.md", .{name}) catch {
        res.status = HTTP_INTERNAL_ERROR;
        return;
    };
    const csv_name = std.fmt.allocPrint(ctx.allocator, "{s}-bom.csv", .{name}) catch {
        res.status = HTTP_INTERNAL_ERROR;
        return;
    };

    const entries = [_]fp_mod.ZipEntry{
        .{ .name = md_name, .data = md },
        .{ .name = csv_name, .data = csv_buf.items },
    };
    const zip = fp_mod.buildZip(ctx.allocator, &entries) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = "Zip error";
        return;
    };

    const disposition = try std.fmt.allocPrint(ctx.allocator, "attachment; filename=\"{s}-review.zip\"", .{name});
    res.header(HEADER_CONTENT_TYPE, CONTENT_TYPE_ZIP);
    res.header(HEADER_CONTENT_DISPOSITION, disposition);
    res.body = zip;
}

/// GET /api/erc/:name — run electrical-rule checks (duplicate ref-des,
/// floating nets, unconnected pins, voltage mismatches, missing decoupling)
/// and return the violations as JSON for the schematic viewer's panel.
pub fn ercApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = HTTP_NOT_FOUND;
        return;
    };

    const board_path = try paths.designSourcePath(ctx.allocator, ctx.project_dir, name);
    defer ctx.allocator.free(board_path);

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();

    const result = eval.evalFile(board_path) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = ERR_BUILD;
        return;
    };

    const block = switch (result) {
        .design_block => |b| b,
        else => {
            res.status = HTTP_INTERNAL_ERROR;
            res.body = "Not a design block";
            return;
        },
    };

    const bom_path = try paths.designSiblingPath(ctx.allocator, ctx.project_dir, name, ".bom");
    defer ctx.allocator.free(bom_path);
    try bom.resolveIdentities(ctx.allocator, @constCast(block), bom_path, ctx.project_dir);

    const violations = erc_mod.runErc(ctx.allocator, block, ctx.project_dir) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = "ERC error";
        return;
    };

    const json = erc_mod.writeViolationsJson(ctx.allocator, violations) catch {
        res.status = HTTP_INTERNAL_ERROR;
        return;
    };

    res.content_type = .JSON;
    res.header(HEADER_CORS_ALLOW_ORIGIN, "*");
    res.body = json;
}

/// Build the review document for a design and render it as JSON. Evaluates
/// the design fresh each call (not live-layout cache) so assertions and ERC
/// reflect the current source on disk. Returns 500 with a plain-text error
/// body on build failures — the review page calls this on load and the MCP
/// tool shares the same code path.
pub fn reviewJsonApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = HTTP_NOT_FOUND;
        return;
    };
    res.content_type = .JSON;
    res.header(HEADER_CORS_ALLOW_ORIGIN, "*");
    const json = renderReviewJson(ctx.allocator, ctx.project_dir, name) catch |err| {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = try std.fmt.allocPrint(ctx.allocator, "{{\"error\":\"{s}\"}}", .{@errorName(err)});
        return;
    };
    res.body = json;
}

/// Return all designs in the project as a JSON array. Same shape as the
/// MCP `list_designs` tool: `[{name, title, sections, instance_count,
/// net_count, mtime, build_ok}, ...]`.
pub fn designsApi(ctx: *Handler, _: *httpz.Request, res: *httpz.Response) HandlerError!void {
    res.content_type = .JSON;
    res.header(HEADER_CORS_ALLOW_ORIGIN, "*");

    const summaries = mcp_tools.listDesignSummaries(ctx.allocator, ctx.project_dir) catch &[_]mcp_tools.DesignSummary{};

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(ctx.allocator);
    try w.writeAll("[");
    for (summaries, 0..) |s, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll(NAME_FIELD_PREFIX);
        try writeJsonString(w, s.name);
        try w.writeAll(",\"title\":");
        try writeJsonString(w, s.title);
        try w.writeAll(",\"sections\":[");
        for (s.sections, 0..) |sec, si| {
            if (si > 0) try w.writeAll(",");
            try writeJsonString(w, sec);
        }
        try w.print("],\"instance_count\":{d},\"net_count\":{d},\"mtime\":{d},\"build_ok\":{s}}}", .{
            s.instance_count,
            s.net_count,
            s.mtime_sec,
            if (s.build_ok) "true" else "false",
        });
    }
    try w.writeAll("]");
    res.body = buf.items;
}

fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeAll("\"");
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0...0x08, 0x0b, 0x0c, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{c}),
        else => try w.writeByte(c),
    };
    try w.writeAll("\"");
}

/// Legacy `/review/:name` route — the schematic page now embeds every review
/// section inline, so we 301-redirect here. Old bookmarks and PR links keep
/// working; scroll anchors (`#sec-<slug>`) are preserved by the browser.
pub fn reviewPage(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = HTTP_NOT_FOUND;
        return;
    };
    const location = try std.fmt.allocPrint(ctx.allocator, "/schematics/{s}", .{name});
    res.status = 301;
    res.header("location", location);
}

/// Shared build path: evaluate, resolve BOM identities, run ERC, package
/// the ReviewDoc. Returns an opaque error on build failure.
fn buildDocForName(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
) !review_mod.ReviewDoc {
    const board_path = try paths.designSourcePath(allocator, project_dir, name);
    defer allocator.free(board_path);

    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();

    const result = try eval.evalFile(board_path);
    const block = switch (result) {
        .design_block => |b| b,
        else => return error.NotADesign,
    };

    const bom_path = try paths.designSiblingPath(allocator, project_dir, name, ".bom");
    defer allocator.free(bom_path);
    try bom.resolveIdentities(allocator, @constCast(block), bom_path, project_dir);

    const violations = try erc_mod.runErc(allocator, block, project_dir);

    // Run requirement-attached (check ...) primitives + overlay (verifies …)
    // sign-offs so the per-component review entries carry pass/fail/verified
    // status alongside the prose.
    var check_results = req_checks.runChecks(allocator, &eval, block) catch
        std.StringHashMapUnmanaged([]req_checks.Result).empty;
    req_checks.applyVerifications(&check_results, block, block.instances);

    const doc = try review_mod.buildReview(allocator, name, block, eval.assertions.items, violations, &check_results);
    return doc;
}

fn renderReviewJson(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8) ![]const u8 {
    const doc = try buildDocForName(allocator, project_dir, name);
    return try review_json_mod.renderToJson(allocator, doc);
}

/// List free (unassigned) pins on an instance. Thin wrapper over the MCP
/// tool implementation so the browser sidebar can populate the "move pin"
/// dropdown without going through the MCP transport.
pub fn freePinsApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    res.content_type = .JSON;
    res.header(HEADER_CORS_ALLOW_ORIGIN, "*");

    const name = req.param("name") orelse {
        res.status = HTTP_NOT_FOUND;
        res.body = "{\"error\":\"missing name\"}";
        return;
    };
    const qs = req.query() catch {
        res.status = HTTP_BAD_REQUEST;
        res.body = "{\"error\":\"invalid query\"}";
        return;
    };
    const ref_des = qs.get("ref") orelse {
        res.status = HTTP_BAD_REQUEST;
        res.body = "{\"error\":\"missing ref\"}";
        return;
    };

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(ctx.allocator);
    const w = buf.writer(ctx.allocator);
    const ok = mcp_tools.listFreePins(ctx.allocator, ctx.project_dir, name, ref_des, null, w) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = "{\"error\":\"internal\"}";
        return;
    };
    if (!ok) {
        res.status = HTTP_INTERNAL_ERROR;
        // buf.items holds plain text like "error: instance not found".
        res.body = try std.fmt.allocPrint(ctx.allocator, "{{\"error\":\"{s}\"}}", .{buf.items});
        return;
    }
    res.body = try ctx.allocator.dupe(u8, buf.items);
}

/// Return the current `{components, nets}` JSON for a design, matching the
/// shape of the globals `COMPONENTS` and `NETS` that `canvas_page.zig`
/// inlines at page load. The UI uses this after mutations to refresh the
/// sidebar without reloading the page.
pub fn designStateApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    res.content_type = .JSON;
    res.header(HEADER_CORS_ALLOW_ORIGIN, "*");

    const name = req.param("name") orelse {
        res.status = HTTP_NOT_FOUND;
        res.body = "{\"error\":\"missing name\"}";
        return;
    };

    const board_path = try paths.designSourcePath(ctx.allocator, ctx.project_dir, name);
    defer ctx.allocator.free(board_path);

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();
    const result = eval.evalFile(board_path) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = "{\"error\":\"rebuild_failed\"}";
        return;
    };
    const block = switch (result) {
        .design_block => |b| b,
        else => {
            res.status = HTTP_INTERNAL_ERROR;
            res.body = "{\"error\":\"not_a_design\"}";
            return;
        },
    };

    const bom_path = try paths.designSiblingPath(ctx.allocator, ctx.project_dir, name, ".bom");
    defer ctx.allocator.free(bom_path);
    try bom.resolveIdentities(ctx.allocator, @constCast(block), bom_path, ctx.project_dir);

    var sym_cache = try bom_html.buildSymbolPinCache(ctx.allocator, ctx.project_dir);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(ctx.allocator);
    const w = buf.writer(ctx.allocator);
    try w.writeAll("{\"components\":{");
    _ = try bom_html.writeComponentsJson(w, block, "", &sym_cache, ctx.allocator, ctx.project_dir);
    try w.writeAll("},\"nets\":{");
    _ = try bom_html.writeNetsJson(w, block, "");
    try w.writeAll("}}");

    res.body = try ctx.allocator.dupe(u8, buf.items);
}

/// POST /api/section-note/:name/add — body `{section, text, pdf?, page?}`.
/// Splices a new `(note "text" [(ref ...)])` into the named section of the
/// design's .sexp. Returns the new live_version so the browser's 2 s poll
/// picks up the redraw.
pub fn addSectionNoteApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = HTTP_NOT_FOUND;
        return;
    };
    const body = req.body() orelse {
        res.status = HTTP_BAD_REQUEST;
        return;
    };
    const section = jsonField(body, "section") orelse {
        res.status = HTTP_BAD_REQUEST;
        return;
    };
    const text = jsonField(body, "text") orelse {
        res.status = HTTP_BAD_REQUEST;
        return;
    };
    const pdf = jsonField(body, "pdf") orelse "";
    const page_u = jsonUintField(body, "page") orelse 0;
    const page: u32 = @intCast(page_u);

    const result = edit_mod.addSectionNoteCore(ctx.allocator, ctx.project_dir, name, section, text, pdf, page) catch |err| {
        res.status = HTTP_INTERNAL_ERROR;
        res.content_type = .JSON;
        res.body = try std.fmt.allocPrint(ctx.allocator, ERR_OK_FALSE_TEMPLATE, .{@errorName(err)});
        return;
    };
    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(ctx.allocator, OK_VERSION_TEMPLATE, .{result.version});
}

/// POST /api/section-note/:name/remove — body `{section, index}`. Deletes the
/// nth (0-based) `(note ...)` form nested directly in the named section.
pub fn removeSectionNoteApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = HTTP_NOT_FOUND;
        return;
    };
    const body = req.body() orelse {
        res.status = HTTP_BAD_REQUEST;
        return;
    };
    const section = jsonField(body, "section") orelse {
        res.status = HTTP_BAD_REQUEST;
        return;
    };
    const idx_u = jsonUintField(body, "index") orelse 0;
    const idx: usize = @intCast(idx_u);

    const result = edit_mod.removeSectionNoteCore(ctx.allocator, ctx.project_dir, name, section, idx) catch |err| {
        res.status = HTTP_INTERNAL_ERROR;
        res.content_type = .JSON;
        res.body = try std.fmt.allocPrint(ctx.allocator, ERR_OK_FALSE_TEMPLATE, .{@errorName(err)});
        return;
    };
    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(ctx.allocator, OK_VERSION_TEMPLATE, .{result.version});
}

/// POST /api/component-datasheet/:component/add — body `{pdf: "file.pdf"}`.
/// Splices a `(datasheet "file.pdf")` entry into
/// `lib/components/<component>.sexp`. Lets the sidebar link uploaded PDFs
/// to parts without manual .sexp editing.
pub fn addComponentDatasheetApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const component_raw = req.param("component") orelse {
        res.status = HTTP_NOT_FOUND;
        return;
    };
    const component = try urlDecodeAlloc(ctx.allocator, component_raw);
    const body = req.body() orelse {
        res.status = HTTP_BAD_REQUEST;
        return;
    };
    const pdf = jsonField(body, "pdf") orelse {
        res.status = HTTP_BAD_REQUEST;
        return;
    };
    const result = edit_mod.addComponentDatasheetCore(ctx.allocator, ctx.project_dir, component, pdf) catch |err| {
        res.status = HTTP_INTERNAL_ERROR;
        res.content_type = .JSON;
        res.body = try std.fmt.allocPrint(ctx.allocator, ERR_OK_FALSE_TEMPLATE, .{@errorName(err)});
        return;
    };
    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(ctx.allocator, OK_VERSION_TEMPLATE, .{result.version});
}

/// POST /api/component-datasheet/:component/remove — body `{pdf: "file.pdf"}`.
/// Counterpart to /add; unlinks a PDF from the library part.
pub fn removeComponentDatasheetApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const component_raw = req.param("component") orelse {
        res.status = HTTP_NOT_FOUND;
        return;
    };
    const component = try urlDecodeAlloc(ctx.allocator, component_raw);
    const body = req.body() orelse {
        res.status = HTTP_BAD_REQUEST;
        return;
    };
    const pdf = jsonField(body, "pdf") orelse {
        res.status = HTTP_BAD_REQUEST;
        return;
    };
    const result = edit_mod.removeComponentDatasheetCore(ctx.allocator, ctx.project_dir, component, pdf) catch |err| {
        res.status = HTTP_INTERNAL_ERROR;
        res.content_type = .JSON;
        res.body = try std.fmt.allocPrint(ctx.allocator, ERR_OK_FALSE_TEMPLATE, .{@errorName(err)});
        return;
    };
    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(ctx.allocator, OK_VERSION_TEMPLATE, .{result.version});
}

/// Extract a positive integer value for `"key":N` out of a flat JSON body.
/// Same shortcut approach as `jsonField`/`jsonBoolField` — no full parser,
/// but plenty for the small POSTs these endpoints handle.
fn jsonUintField(body: []const u8, key: []const u8) ?u64 {
    var buf: [64]u8 = undefined;
    const marker = std.fmt.bufPrint(&buf, "\"{s}\":", .{key}) catch return null;
    const start = std.mem.indexOf(u8, body, marker) orelse return null;
    var i: usize = start + marker.len;
    while (i < body.len and (body[i] == ' ' or body[i] == '\t')) : (i += 1) {}
    var end: usize = i;
    while (end < body.len and body[end] >= '0' and body[end] <= '9') : (end += 1) {}
    if (end == i) return null;
    return std.fmt.parseInt(u64, body[i..end], 10) catch null;
}

/// Extract `"key":"value"` from a flat JSON body. Matches the substring
/// pattern used by edit.zig for other small endpoints — good enough for
/// these short POSTs and avoids pulling in a full JSON parse per request.
fn jsonField(body: []const u8, key: []const u8) ?[]const u8 {
    var buf: [64]u8 = undefined;
    const marker = std.fmt.bufPrint(&buf, "\"{s}\":\"", .{key}) catch return null;
    const start = std.mem.indexOf(u8, body, marker) orelse return null;
    const val_start = start + marker.len;
    const end = std.mem.indexOfPos(u8, body, val_start, "\"") orelse return null;
    return body[val_start..end];
}

fn jsonBoolField(body: []const u8, key: []const u8) ?bool {
    var buf: [64]u8 = undefined;
    const marker = std.fmt.bufPrint(&buf, "\"{s}\":", .{key}) catch return null;
    const start = std.mem.indexOf(u8, body, marker) orelse return null;
    const val_start = start + marker.len;
    if (std.mem.startsWith(u8, body[val_start..], "true")) return true;
    if (std.mem.startsWith(u8, body[val_start..], "false")) return false;
    return null;
}

/// httpz returns URL path params verbatim — `%23` stays `%23`, not `#`.
/// Library filenames can include reserved chars (e.g. `ltc6655bhms8-2-5#pbf`),
/// so endpoints that map a `:component` param to a file on disk need to
/// percent-decode first or they'll miss the file.
fn urlDecodeAlloc(allocator: std.mem.Allocator, raw: []const u8) ![]u8 {
    const buf = try allocator.dupe(u8, raw);
    return std.Uri.percentDecodeInPlace(buf);
}
