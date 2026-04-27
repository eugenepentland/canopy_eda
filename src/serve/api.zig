const std = @import("std");
const httpz = @import("httpz");
const infra_fs = @import("../infra/fs.zig");
const log = @import("../infra/log.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const render_json = @import("../render_json.zig");
const render_block = @import("../render_block.zig");
const export_kicad = @import("../export_kicad.zig");
const export_kicad_pcb = @import("../export_kicad_pcb.zig");
const layout_mod = @import("../layout.zig");
const bom = @import("../bom.zig");
const export_gerber = @import("../export_gerber.zig");
const fp_mod = @import("../export_kicad_footprint.zig");
const zone_fill = @import("../zone_fill.zig");
const drc_mod = @import("../drc.zig");
const erc_mod = @import("../erc.zig");
const env_mod = @import("../eval/env.zig");
const parser_mod = @import("../sexpr/parser.zig");
const bom_html = @import("bom_html.zig");
const mcp_tools = @import("mcp_tools.zig");
const review_mod = @import("../review.zig");
const review_json_mod = @import("../review_json.zig");
const review_md_mod = @import("../review_md.zig");
const review_state_mod = @import("../review_state.zig");
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

// File path templates (multiple uses across handlers)
const SEXP_PATH_TEMPLATE = "{s}/src/{s}.sexp";
const BOM_PATH_TEMPLATE = "{s}/src/{s}.bom";
const LAYOUT_PATH_TEMPLATE = "{s}/src/{s}.layout";

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
const SECTION_SLUG_KEY = "section_slug";

// PCB default rules (mm)
const DEFAULT_VIA_DRILL_MM: f64 = 0.3;
const DEFAULT_VIA_SIZE_MM: f64 = 0.6;
const DEFAULT_CLEARANCE_MM: f64 = 0.15;
const DEFAULT_TRACK_WIDTH_MM: f64 = 0.2;

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

    const board_path = try std.fmt.allocPrint(ctx.allocator, SEXP_PATH_TEMPLATE, .{ ctx.project_dir, name });
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

/// GET /api/version/:name — return `{"version":N}`. The schematic and PCB
/// viewers poll this every ~500 ms and reload their scene graph when N
/// changes. Bumped by `pushApi` and the MCP mutation tools.
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

/// GET /api/block-diagram-json/:name — evaluate the design and emit the
/// hierarchical block-diagram JSON consumed by the diagram viewer (auto-
/// categorised columns, topology-aware edges between sections).
pub fn blockDiagramJsonApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = HTTP_NOT_FOUND;
        return;
    };
    const board_path = try std.fmt.allocPrint(ctx.allocator, SEXP_PATH_TEMPLATE, .{ ctx.project_dir, name });
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
    const json = render_block.renderBlockDiagramJson(ctx.allocator, block) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = "Render error";
        return;
    };
    res.content_type = .JSON;
    res.header(HEADER_CORS_ALLOW_ORIGIN, "*");
    res.body = json;
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

/// GET /api/layout — return the in-memory editor layout blob the schematic
/// viewer uses for component placement persistence between live reloads.
/// Empty `{}` until something has been POSTed via `layoutPostApi`.
pub fn layoutGetApi(_: *Handler, _: *httpz.Request, res: *httpz.Response) HandlerError!void {
    serve_root.layout_mutex.lock();
    const data = serve_root.layout_data;
    serve_root.layout_mutex.unlock();

    res.content_type = .JSON;
    res.header(HEADER_CORS_ALLOW_ORIGIN, "*");
    res.body = data orelse "{}";
}

/// POST /api/layout — store an arbitrary JSON layout blob in process memory
/// (under `layout_mutex`). The schematic viewer uses this as a session-
/// scoped scratchpad; payload is not validated server-side.
pub fn layoutPostApi(_: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const body = req.body() orelse "{}";

    serve_root.layout_mutex.lock();
    serve_root.layout_data = body;
    serve_root.layout_mutex.unlock();

    res.content_type = .JSON;
    res.header(HEADER_CORS_ALLOW_ORIGIN, "*");
    res.body = OK_JSON_TRUE;
}

/// GET /api/export-kicad/:name — build the design, resolve BOM identities,
/// and stream back a `<name>-kicad.zip` containing the KiCad schematic,
/// netlist, and per-instance footprint files.
pub fn exportKicadApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = HTTP_NOT_FOUND;
        return;
    };

    const board_path = try std.fmt.allocPrint(ctx.allocator, SEXP_PATH_TEMPLATE, .{ ctx.project_dir, name });
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

    const bom_path = std.fmt.allocPrint(ctx.allocator, BOM_PATH_TEMPLATE, .{ ctx.project_dir, name }) catch {
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

    const board_path = try std.fmt.allocPrint(ctx.allocator, SEXP_PATH_TEMPLATE, .{ ctx.project_dir, name });
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

    const bom_path = std.fmt.allocPrint(ctx.allocator, BOM_PATH_TEMPLATE, .{ ctx.project_dir, name }) catch {
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

/// POST /api/update-pcb/:name — sync the design's netlist and footprints to a
/// shared NAS location, then shell out to `src/pcb_update.py` to update the
/// upstream `.kicad_pcb`. Used by the Cyclops design loop; honours the
/// `?short-nets=1` query string for KiCad's net-name truncation mode.
pub fn updatePcbApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const qs = try req.query();
    const short_nets = if (qs.get("short-nets")) |v| std.mem.eql(u8, v, "1") else false;
    const name = req.param("name") orelse {
        res.status = HTTP_NOT_FOUND;
        return;
    };

    const board_path = std.fmt.allocPrint(ctx.allocator, SEXP_PATH_TEMPLATE, .{ ctx.project_dir, name }) catch {
        res.status = HTTP_INTERNAL_ERROR;
        return;
    };
    defer ctx.allocator.free(board_path);

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();

    const result = eval.evalFile(board_path) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = "{\"ok\":false,\"error\":\"Build error\"}";
        res.content_type = .JSON;
        return;
    };

    const block = switch (result) {
        .design_block => |b| b,
        else => {
            res.status = HTTP_INTERNAL_ERROR;
            return;
        },
    };

    const bom_path = std.fmt.allocPrint(ctx.allocator, BOM_PATH_TEMPLATE, .{ ctx.project_dir, name }) catch {
        res.status = HTTP_INTERNAL_ERROR;
        return;
    };
    try bom.resolveIdentities(ctx.allocator, block, bom_path, ctx.project_dir);

    const netlist = export_kicad.exportNetlistOnly(ctx.allocator, block, ctx.project_dir, name) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = "{\"ok\":false,\"error\":\"Export error\"}";
        res.content_type = .JSON;
        return;
    };

    export_kicad.exportFootprints(ctx.allocator, block, ctx.project_dir, "/mnt/nas/Cyclops/Cyclops Digital/footprints.pretty") catch |e| {
        log.warn("exportFootprints failed: {s}", .{@errorName(e)});
    };

    const sections_json = export_kicad.exportSectionLayout(ctx.allocator, block) catch "";
    const sections_path = "/mnt/nas/Cyclops/Cyclops Digital/stm32n6.sections.json";

    const net_path = "/mnt/nas/Cyclops/Cyclops Digital/stm32n6.net";
    {
        const f = infra_fs.cwd().createFile(net_path, .{}) catch {
            res.status = HTTP_INTERNAL_ERROR;
            res.body = "{\"ok\":false,\"error\":\"Cannot write netlist\"}";
            res.content_type = .JSON;
            return;
        };
        defer f.close();
        f.writeAll(netlist) catch {
            res.status = HTTP_INTERNAL_ERROR;
            return;
        };
    }

    if (sections_json.len > 0) {
        const sf = infra_fs.cwd().createFile(sections_path, .{}) catch null;
        if (sf) |f| {
            defer f.close();
            try f.writeAll(sections_json);
        }
    }

    const PCB_UPDATE_MAX_ARGV: usize = 7;
    var argv_buf: [PCB_UPDATE_MAX_ARGV][]const u8 = undefined;
    var argc: usize = 0;
    argv_buf[argc] = "python3";
    argc += 1;
    argv_buf[argc] = "src/pcb_update.py";
    argc += 1;
    if (short_nets) {
        argv_buf[argc] = "--short-nets";
        argc += 1;
    }
    argv_buf[argc] = net_path;
    argc += 1;
    argv_buf[argc] = "/mnt/nas/Cyclops/Cyclops Digital/footprints.pretty";
    argc += 1;
    argv_buf[argc] = "/mnt/nas/Cyclops/Cyclops Digital/Cyclops Digital.kicad_pcb";
    argc += 1;
    argv_buf[argc] = sections_path;
    argc += 1;
    const py_result = std.process.Child.run(.{
        .allocator = ctx.allocator,
        .argv = argv_buf[0..argc],
    }) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = "{\"ok\":false,\"error\":\"Failed to run pcb_update.py\"}";
        res.content_type = .JSON;
        return;
    };
    defer ctx.allocator.free(py_result.stdout);
    defer ctx.allocator.free(py_result.stderr);

    if (py_result.term.Exited != 0) {
        const output = if (py_result.stderr.len > 0) py_result.stderr else py_result.stdout;
        var err_msg: []const u8 = "PCB update script failed";
        const RUNTIME_ERROR_PREFIX = "RuntimeError: ";
        const ERROR_PREFIX = "Error: ";
        if (std.mem.lastIndexOf(u8, output, RUNTIME_ERROR_PREFIX)) |idx| {
            const line_end = std.mem.indexOfPos(u8, output, idx, "\n") orelse output.len;
            err_msg = output[idx + RUNTIME_ERROR_PREFIX.len .. line_end];
        } else if (std.mem.lastIndexOf(u8, output, ERROR_PREFIX)) |idx| {
            const line_end = std.mem.indexOfPos(u8, output, idx, "\n") orelse output.len;
            err_msg = output[idx + ERROR_PREFIX.len .. line_end];
        }
        const body = std.fmt.allocPrint(ctx.allocator, ERR_OK_FALSE_TEMPLATE, .{err_msg}) catch {
            res.body = "{\"ok\":false,\"error\":\"PCB update script failed\"}";
            res.content_type = .JSON;
            return;
        };
        res.body = body;
        res.content_type = .JSON;
        return;
    }

    res.body = OK_JSON_TRUE;
    res.content_type = .JSON;
}

/// GET /api/export-bom-csv/:name — build the design and stream the parts
/// list as `<name>-bom.csv`. Same column layout as the BOM table on the
/// review page; suitable for hand-off to procurement.
pub fn exportBomCsvApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = HTTP_NOT_FOUND;
        return;
    };

    const board_path = try std.fmt.allocPrint(ctx.allocator, SEXP_PATH_TEMPLATE, .{ ctx.project_dir, name });
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

/// GET /api/export-gerber/:name — run the Gerber/Excellon exporter against
/// the saved `.layout` and stream the resulting fab files back as
/// `<name>-gerber.zip` for upload to a PCB house.
pub fn exportGerberApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = HTTP_NOT_FOUND;
        return;
    };

    const board_path = try std.fmt.allocPrint(ctx.allocator, SEXP_PATH_TEMPLATE, .{ ctx.project_dir, name });
    defer ctx.allocator.free(board_path);

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();

    const result = eval.evalFile(board_path) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = ERR_BUILD;
        return;
    };

    var block: *env_mod.DesignBlock = undefined;
    var board_def: ?*env_mod.Board = null;
    switch (result) {
        .design_block => |db| block = db,
        .board => |b| {
            block = b.design;
            board_def = b;
        },
        else => {
            res.status = HTTP_INTERNAL_ERROR;
            res.body = "Not a design block";
            return;
        },
    }

    const bom_path = try std.fmt.allocPrint(ctx.allocator, BOM_PATH_TEMPLATE, .{ ctx.project_dir, name });
    defer ctx.allocator.free(bom_path);
    try bom.resolveIdentities(ctx.allocator, block, bom_path, ctx.project_dir);

    const layout_path_str = try std.fmt.allocPrint(ctx.allocator, LAYOUT_PATH_TEMPLATE, .{ ctx.project_dir, name });
    defer ctx.allocator.free(layout_path_str);

    const files = export_gerber.exportGerber(ctx.allocator, block, ctx.project_dir, name, board_def, layout_path_str) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = "Gerber export error";
        return;
    };

    // Build zip
    var zip_entries: std.ArrayListUnmanaged(fp_mod.ZipEntry) = .empty;
    defer zip_entries.deinit(ctx.allocator);
    for (files) |f| {
        try zip_entries.append(ctx.allocator, .{ .name = f.name, .data = f.data });
    }
    const zip = fp_mod.buildZip(ctx.allocator, zip_entries.items) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = "Zip error";
        return;
    };

    const disposition = try std.fmt.allocPrint(ctx.allocator, "attachment; filename=\"{s}-gerber.zip\"", .{name});
    res.header(HEADER_CONTENT_TYPE, CONTENT_TYPE_ZIP);
    res.header(HEADER_CONTENT_DISPOSITION, disposition);
    res.body = zip;
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
    const board_path = std.fmt.allocPrint(ctx.allocator, SEXP_PATH_TEMPLATE, .{ ctx.project_dir, name }) catch {
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
        .board => |b| @as(*const env_mod.DesignBlock, b.design),
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

/// POST /api/pcb-placement/:name — Save component placements to .layout file
///
/// Request body: {"placements": [{"uuid":"...", "x":10.5, "y":20.3, "angle":90, "layer":"F.Cu"}, ...]}
/// Writes a native .layout file and also updates .kicad_pcb for export compatibility.
pub fn pcbPlacementApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = HTTP_NOT_FOUND;
        return;
    };

    const body = req.body() orelse {
        res.status = HTTP_BAD_REQUEST;
        res.body = ERR_NO_BODY_JSON;
        return;
    };

    // Parse placements from JSON body
    const PlacementEntry = struct { uuid: []const u8, ref: []const u8, x: f64, y: f64, angle: f64, layer: []const u8 };
    var entries: std.ArrayListUnmanaged(PlacementEntry) = .empty;
    defer entries.deinit(ctx.allocator);

    var pos: usize = 0;
    while (pos < body.len) {
        const uuid_key = "\"uuid\":";
        const uuid_start = std.mem.indexOf(u8, body[pos..], uuid_key) orelse break;
        var abs_uuid_start = pos + uuid_start + uuid_key.len;
        while (abs_uuid_start < body.len and body[abs_uuid_start] == ' ') abs_uuid_start += 1;
        if (abs_uuid_start >= body.len or body[abs_uuid_start] != '"') {
            pos = abs_uuid_start;
            continue;
        }
        abs_uuid_start += 1;
        const uuid_end = std.mem.indexOf(u8, body[abs_uuid_start..], "\"") orelse break;
        const uuid = body[abs_uuid_start .. abs_uuid_start + uuid_end];

        const obj_end = std.mem.indexOf(u8, body[abs_uuid_start..], "}") orelse break;
        const obj_slice = body[pos + uuid_start .. abs_uuid_start + obj_end + 1];

        const x = parseJsonFloat(obj_slice, "\"x\":") orelse 0;
        const y = parseJsonFloat(obj_slice, "\"y\":") orelse 0;
        const angle = parseJsonFloat(obj_slice, "\"angle\":") orelse 0;

        // Parse ref
        const REF_KEY = "\"ref\":";
        const LAYER_KEY = "\"layer\":";
        var ref: []const u8 = "";
        if (std.mem.indexOf(u8, obj_slice, REF_KEY)) |rp| {
            var rs = rp + REF_KEY.len;
            while (rs < obj_slice.len and (obj_slice[rs] == ' ' or obj_slice[rs] == '"')) rs += 1;
            const re = std.mem.indexOf(u8, obj_slice[rs..], "\"") orelse obj_slice.len - rs;
            ref = obj_slice[rs .. rs + re];
        }

        // Parse layer
        var layer: []const u8 = "F.Cu";
        if (std.mem.indexOf(u8, obj_slice, LAYER_KEY)) |lp| {
            var ls = lp + LAYER_KEY.len;
            while (ls < obj_slice.len and (obj_slice[ls] == ' ' or obj_slice[ls] == '"')) ls += 1;
            const le = std.mem.indexOf(u8, obj_slice[ls..], "\"") orelse obj_slice.len - ls;
            layer = obj_slice[ls .. ls + le];
        }

        try entries.append(ctx.allocator, .{ .uuid = uuid, .ref = ref, .x = x, .y = y, .angle = angle, .layer = layer });
        pos = abs_uuid_start + obj_end + 1;
    }

    // Write .layout file
    const layout_path = try std.fmt.allocPrint(ctx.allocator, LAYOUT_PATH_TEMPLATE, .{ ctx.project_dir, name });
    defer ctx.allocator.free(layout_path);

    var layout_placements: std.ArrayListUnmanaged(layout_mod.Placement) = .empty;
    defer layout_placements.deinit(ctx.allocator);
    for (entries.items) |e| {
        try layout_placements.append(ctx.allocator, .{
            .ref_des = e.ref,
            .x = e.x,
            .y = e.y,
            .angle = e.angle,
            .side = if (std.mem.eql(u8, e.layer, "B.Cu")) .back else .front,
            .uuid = e.uuid,
        });
    }
    // Load existing routing data (traces/vias/zones) to preserve them
    var existing_traces: []const layout_mod.Trace = &.{};
    var existing_vias: []const layout_mod.Via = &.{};
    var existing_zone_fills: []const layout_mod.ZoneFill = &.{};
    var existing_rules: ?layout_mod.Rules = null;
    if (layout_mod.loadLayout(ctx.allocator, layout_path)) |existing_layout| {
        existing_traces = existing_layout.traces;
        existing_vias = existing_layout.vias;
        existing_zone_fills = existing_layout.zone_fills;
        existing_rules = existing_layout.rules;
    } else |_| {}

    const layout = layout_mod.Layout{
        .placements = layout_placements.items,
        .traces = existing_traces,
        .vias = existing_vias,
        .zone_fills = existing_zone_fills,
        .rules = existing_rules,
    };
    try layout_mod.saveLayout(ctx.allocator, &layout, layout_path);

    // Also update .kicad_pcb for export compatibility
    const pcb_path = try std.fmt.allocPrint(ctx.allocator, "{s}/out/{s}.kicad_pcb", .{ ctx.project_dir, name });
    defer ctx.allocator.free(pcb_path);
    if (infra_fs.cwd().readFileAlloc(ctx.allocator, pcb_path, 100 * 1024 * 1024)) |pcb_content| {
        defer ctx.allocator.free(pcb_content);
        if (applyPlacements(ctx.allocator, pcb_content, body)) |updated| {
            defer ctx.allocator.free(updated);
            if (infra_fs.cwd().createFile(pcb_path, .{})) |f| {
                defer f.close();
                try f.writeAll(updated);
            } else |_| {}
        } else |_| {}
    } else |_| {}

    res.content_type = .JSON;
    res.header(HEADER_CORS_ALLOW_ORIGIN, "*");
    res.body = OK_JSON_TRUE;
}

/// POST /api/pcb-routing/:name — replace the design's traces and vias in the
/// `.layout` file. Existing placements and rules are preserved; the body is
/// a JSON `{traces: [...], vias: [...]}` document the PCB editor sends on
/// every routing edit.
pub fn pcbRoutingApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = HTTP_NOT_FOUND;
        return;
    };

    const body = req.body() orelse {
        res.status = HTTP_BAD_REQUEST;
        res.body = ERR_NO_BODY_JSON;
        return;
    };

    const layout_path = try std.fmt.allocPrint(ctx.allocator, LAYOUT_PATH_TEMPLATE, .{ ctx.project_dir, name });
    defer ctx.allocator.free(layout_path);

    // Load existing layout to preserve placements and rules
    var existing_placements: []const layout_mod.Placement = &.{};
    var existing_rules: ?layout_mod.Rules = null;
    if (layout_mod.loadLayout(ctx.allocator, layout_path)) |existing_layout| {
        existing_placements = existing_layout.placements;
        existing_rules = existing_layout.rules;
    } else |_| {}

    // Parse traces from JSON
    log.warn("[pcbRoutingApi] body len={d}", .{body.len});
    var traces: std.ArrayListUnmanaged(layout_mod.Trace) = .empty;
    defer traces.deinit(ctx.allocator);
    var vias: std.ArrayListUnmanaged(layout_mod.Via) = .empty;
    defer vias.deinit(ctx.allocator);

    // Parse traces array
    const TRACES_KEY = "\"traces\":[";
    const NET_QUOTED_KEY = "\"net\":\"";
    const LAYER_QUOTED_KEY = "\"layer\":\"";
    const POINTS_KEY = "\"points\":[";
    if (std.mem.indexOf(u8, body, TRACES_KEY)) |traces_start| {
        var tpos = traces_start + TRACES_KEY.len;
        while (tpos < body.len) {
            const net_marker = std.mem.indexOf(u8, body[tpos..], NET_QUOTED_KEY) orelse break;
            const abs_net = tpos + net_marker + NET_QUOTED_KEY.len;
            const net_end = std.mem.indexOfPos(u8, body, abs_net, "\"") orelse break;
            const net = body[abs_net..net_end];

            const obj_start = tpos + net_marker;
            const obj_end_rel = std.mem.indexOfPos(u8, body, net_end, "}") orelse break;
            const obj = body[obj_start .. obj_end_rel + 1];

            const layer_marker = std.mem.indexOf(u8, obj, LAYER_QUOTED_KEY) orelse {
                tpos = obj_end_rel + 1;
                continue;
            };
            const layer_start = layer_marker + LAYER_QUOTED_KEY.len;
            const layer_end = std.mem.indexOfPos(u8, obj, layer_start, "\"") orelse {
                tpos = obj_end_rel + 1;
                continue;
            };
            const layer = obj[layer_start..layer_end];

            const width = parseJsonFloat(obj, "\"width\":") orelse DEFAULT_TRACK_WIDTH_MM;

            // Parse points array
            var points: std.ArrayListUnmanaged([2]f64) = .empty;
            if (std.mem.indexOf(u8, obj, POINTS_KEY)) |pts_start| {
                var ppos = pts_start + POINTS_KEY.len;
                while (ppos < obj.len) {
                    const bracket = std.mem.indexOfPos(u8, obj, ppos, "[") orelse break;
                    if (bracket >= obj.len) break;
                    const bracket_end = std.mem.indexOfPos(u8, obj, bracket, "]") orelse break;
                    const pt_str = obj[bracket + 1 .. bracket_end];
                    const comma = std.mem.indexOf(u8, pt_str, ",") orelse {
                        ppos = bracket_end + 1;
                        continue;
                    };
                    const px = std.fmt.parseFloat(f64, pt_str[0..comma]) catch {
                        ppos = bracket_end + 1;
                        continue;
                    };
                    const py = std.fmt.parseFloat(f64, pt_str[comma + 1 ..]) catch {
                        ppos = bracket_end + 1;
                        continue;
                    };
                    try points.append(ctx.allocator, .{ px, py });
                    ppos = bracket_end + 1;
                    // Stop at end of points array
                    if (ppos < obj.len and obj[ppos] == ']') break;
                }
            }

            if (points.items.len >= 2) {
                try traces.append(ctx.allocator, .{
                    .net = net,
                    .layer = layer,
                    .width = width,
                    .points = points.items,
                });
            }

            tpos = obj_end_rel + 1;
            // Stop at end of traces array
            if (tpos < body.len and body[tpos] == ']') break;
        }
    }

    // Parse vias array
    const VIAS_KEY = "\"vias\":[";
    const NET_KEY = "\"net\":\"";
    const FROM_KEY = "\"from\":\"";
    const TO_KEY = "\"to\":\"";
    if (std.mem.indexOf(u8, body, VIAS_KEY)) |vias_start| {
        var vpos = vias_start + VIAS_KEY.len;
        while (vpos < body.len) {
            const x_marker = std.mem.indexOf(u8, body[vpos..], "\"x\":") orelse break;
            const abs_x = vpos + x_marker;
            const obj_end_rel = std.mem.indexOfPos(u8, body, abs_x, "}") orelse break;
            const obj = body[abs_x .. obj_end_rel + 1];

            const x = parseJsonFloat(obj, "\"x\":") orelse 0;
            const y = parseJsonFloat(obj, "\"y\":") orelse 0;
            const drill = parseJsonFloat(obj, "\"drill\":") orelse DEFAULT_VIA_DRILL_MM;
            const pad_size = parseJsonFloat(obj, "\"pad_size\":") orelse DEFAULT_VIA_SIZE_MM;

            var net: []const u8 = "";
            if (std.mem.indexOf(u8, obj, NET_KEY)) |np| {
                const ns = np + NET_KEY.len;
                const ne = std.mem.indexOfPos(u8, obj, ns, "\"") orelse ns;
                net = obj[ns..ne];
            }
            var from: []const u8 = "F.Cu";
            if (std.mem.indexOf(u8, obj, FROM_KEY)) |fp| {
                const fs = fp + FROM_KEY.len;
                const fe = std.mem.indexOfPos(u8, obj, fs, "\"") orelse fs;
                from = obj[fs..fe];
            }
            var to: []const u8 = "B.Cu";
            if (std.mem.indexOf(u8, obj, TO_KEY)) |tp| {
                const ts = tp + TO_KEY.len;
                const te = std.mem.indexOfPos(u8, obj, ts, "\"") orelse ts;
                to = obj[ts..te];
            }

            try vias.append(ctx.allocator, .{
                .x = x,
                .y = y,
                .net = net,
                .drill = drill,
                .pad_size = pad_size,
                .layer_from = from,
                .layer_to = to,
            });

            vpos = obj_end_rel + 1;
            if (vpos < body.len and body[vpos] == ']') break;
        }
    }

    log.warn("[pcbRoutingApi] parsed {d} traces, {d} vias", .{ traces.items.len, vias.items.len });
    const layout = layout_mod.Layout{
        .placements = existing_placements,
        .traces = traces.items,
        .vias = vias.items,
        .zone_fills = &.{},
        .rules = existing_rules,
    };
    layout_mod.saveLayout(ctx.allocator, &layout, layout_path) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = "{\"error\":\"save failed\"}";
        return;
    };

    res.content_type = .JSON;
    res.header(HEADER_CORS_ALLOW_ORIGIN, "*");
    res.body = OK_JSON_TRUE;
}

/// POST /api/pcb-rules/:name — update the design rules (clearance, trace
/// width, via dimensions) stored in the `.layout` file. Used by the PCB
/// editor's settings panel; placements and traces stay untouched.
pub fn pcbRulesApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = HTTP_NOT_FOUND;
        return;
    };

    const body = req.body() orelse {
        res.status = HTTP_BAD_REQUEST;
        res.body = ERR_NO_BODY_JSON;
        return;
    };

    const layout_path = try std.fmt.allocPrint(ctx.allocator, LAYOUT_PATH_TEMPLATE, .{ ctx.project_dir, name });
    defer ctx.allocator.free(layout_path);

    // Load existing layout
    var existing = layout_mod.loadLayout(ctx.allocator, layout_path) catch layout_mod.Layout{
        .placements = &.{},
        .traces = &.{},
        .vias = &.{},
        .zone_fills = &.{},
        .rules = null,
    };

    // Parse rules from JSON
    const clearance = parseJsonFloat(body, "\"clearance\":") orelse DEFAULT_CLEARANCE_MM;
    const track_width = parseJsonFloat(body, "\"track_width\":") orelse DEFAULT_TRACK_WIDTH_MM;
    const via_drill = parseJsonFloat(body, "\"via_drill\":") orelse DEFAULT_VIA_DRILL_MM;
    const via_size = parseJsonFloat(body, "\"via_size\":") orelse DEFAULT_VIA_SIZE_MM;

    existing.rules = .{
        .clearance = clearance,
        .track_width = track_width,
        .via_drill = via_drill,
        .via_size = via_size,
    };

    layout_mod.saveLayout(ctx.allocator, &existing, layout_path) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = "{\"error\":\"save failed\"}";
        return;
    };

    res.content_type = .JSON;
    res.header(HEADER_CORS_ALLOW_ORIGIN, "*");
    res.body = OK_JSON_TRUE;
}

/// POST /api/zone-fill/:name — recompute copper-pour polygons for every
/// zone on the board, persist them into the `.layout` file, and return the
/// fills as JSON for the PCB viewer to render without a round-trip reload.
pub fn zoneFillApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name_param = req.param("name") orelse {
        res.status = HTTP_NOT_FOUND;
        return;
    };

    const board_path = try std.fmt.allocPrint(ctx.allocator, SEXP_PATH_TEMPLATE, .{ ctx.project_dir, name_param });
    defer ctx.allocator.free(board_path);

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();

    const result = eval.evalFile(board_path) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = "{\"error\":\"build error\"}";
        return;
    };

    var block: *env_mod.DesignBlock = undefined;
    var board_def: ?*env_mod.Board = null;
    switch (result) {
        .design_block => |db| block = db,
        .board => |b| {
            block = b.design;
            board_def = b;
        },
        else => {
            res.status = HTTP_INTERNAL_ERROR;
            res.body = "{\"error\":\"not a board\"}";
            return;
        },
    }

    const bd = board_def orelse {
        res.status = HTTP_BAD_REQUEST;
        res.body = "{\"error\":\"no board definition with zones\"}";
        return;
    };

    const bom_path = try std.fmt.allocPrint(ctx.allocator, BOM_PATH_TEMPLATE, .{ ctx.project_dir, name_param });
    defer ctx.allocator.free(bom_path);
    try bom.resolveIdentities(ctx.allocator, block, bom_path, ctx.project_dir);

    const layout_path2 = try std.fmt.allocPrint(ctx.allocator, LAYOUT_PATH_TEMPLATE, .{ ctx.project_dir, name_param });
    defer ctx.allocator.free(layout_path2);

    var existing_layout = layout_mod.loadLayout(ctx.allocator, layout_path2) catch layout_mod.Layout{
        .placements = &.{},
        .traces = &.{},
        .vias = &.{},
        .zone_fills = &.{},
        .rules = null,
    };

    // Compute zone fills
    const fills = zone_fill.computeZoneFills(ctx.allocator, block, bd, ctx.project_dir, &existing_layout) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = "{\"error\":\"zone fill error\"}";
        return;
    };

    // Convert to layout ZoneFill structs and save
    var zone_fills_out: std.ArrayListUnmanaged(layout_mod.ZoneFill) = .empty;
    defer zone_fills_out.deinit(ctx.allocator);
    for (fills) |f| {
        try zone_fills_out.append(ctx.allocator, .{
            .zone_name = f.zone_name,
            .layer = f.layer,
            .polygons = f.polygons,
        });
    }

    existing_layout.zone_fills = zone_fills_out.items;
    layout_mod.saveLayout(ctx.allocator, &existing_layout, layout_path2) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = "{\"error\":\"save error\"}";
        return;
    };

    // Return zone fills as JSON
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(ctx.allocator);
    try w.writeAll("{\"zone_fills\":[");
    for (fills, 0..) |f, fi| {
        if (fi > 0) try w.writeAll(",");
        try w.print("{{\"net\":\"{s}\",\"layer\":\"{s}\",\"polygons\":[", .{ f.zone_name, f.layer });
        for (f.polygons, 0..) |poly, pi| {
            if (pi > 0) try w.writeAll(",");
            try w.writeAll("[");
            for (poly, 0..) |pt, pti| {
                if (pti > 0) try w.writeAll(",");
                try w.print("[{d:.4},{d:.4}]", .{ pt[0], pt[1] });
            }
            try w.writeAll("]");
        }
        try w.writeAll("]}");
    }
    try w.writeAll("]}");

    res.content_type = .JSON;
    res.header(HEADER_CORS_ALLOW_ORIGIN, "*");
    res.body = buf.items;
}

/// GET /api/drc/:name — run the design-rule checker over the saved layout
/// (pad clearance, trace widths, via drill/size, obstacle hits) and return
/// the violations as JSON for the PCB viewer's issues panel.
pub fn drcApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name_param = req.param("name") orelse {
        res.status = HTTP_NOT_FOUND;
        return;
    };

    const board_path = try std.fmt.allocPrint(ctx.allocator, SEXP_PATH_TEMPLATE, .{ ctx.project_dir, name_param });
    defer ctx.allocator.free(board_path);

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();

    const result = eval.evalFile(board_path) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = "{\"error\":\"build error\"}";
        return;
    };

    var block: *env_mod.DesignBlock = undefined;
    var board_def: ?*env_mod.Board = null;
    switch (result) {
        .design_block => |db| {
            block = db;
            // Try loading companion board definition
            const bd_path = std.fmt.allocPrint(ctx.allocator, "{s}/src/{s}-board.sexp", .{ ctx.project_dir, name_param }) catch null;
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
            res.status = HTTP_INTERNAL_ERROR;
            res.body = "{\"error\":\"not a board\"}";
            return;
        },
    }

    const bom_path = try std.fmt.allocPrint(ctx.allocator, BOM_PATH_TEMPLATE, .{ ctx.project_dir, name_param });
    defer ctx.allocator.free(bom_path);
    try bom.resolveIdentities(ctx.allocator, block, bom_path, ctx.project_dir);

    const layout_path3 = try std.fmt.allocPrint(ctx.allocator, LAYOUT_PATH_TEMPLATE, .{ ctx.project_dir, name_param });
    defer ctx.allocator.free(layout_path3);

    const existing_layout = layout_mod.loadLayout(ctx.allocator, layout_path3) catch layout_mod.Layout{
        .placements = &.{},
        .traces = &.{},
        .vias = &.{},
        .zone_fills = &.{},
        .rules = null,
    };

    const violations = drc_mod.runDrc(ctx.allocator, block, board_def, ctx.project_dir, &existing_layout) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = "{\"error\":\"DRC error\"}";
        return;
    };

    res.content_type = .JSON;
    res.header(HEADER_CORS_ALLOW_ORIGIN, "*");
    res.body = try drc_mod.writeViolationsJson(ctx.allocator, violations);
}

/// Apply placement updates to a .kicad_pcb file by matching canopy_uuid.
///
/// Builds a uuid→placement lookup, then scans the PCB content once, replacing
/// each footprint's (at ...) line when its canopy_uuid has a matching placement.
fn applyPlacements(allocator: std.mem.Allocator, pcb_content: []const u8, body: []const u8) ![]const u8 {
    // Parse placements from JSON body into a uuid→{x,y,angle} map
    const Placement = struct { x: f64, y: f64, angle: f64 };
    var placements = std.StringHashMap(Placement).init(allocator);
    defer placements.deinit();

    var pos: usize = 0;
    while (pos < body.len) {
        // Support both "uuid":"..." and "uuid": "..." (with optional space)
        const uuid_key = "\"uuid\":";
        const uuid_start = std.mem.indexOf(u8, body[pos..], uuid_key) orelse break;
        var abs_uuid_start = pos + uuid_start + uuid_key.len;
        while (abs_uuid_start < body.len and body[abs_uuid_start] == ' ') abs_uuid_start += 1;
        if (abs_uuid_start >= body.len or body[abs_uuid_start] != '"') {
            pos = abs_uuid_start;
            continue;
        }
        abs_uuid_start += 1; // skip opening quote
        const uuid_end = std.mem.indexOf(u8, body[abs_uuid_start..], "\"") orelse break;
        const uuid = body[abs_uuid_start .. abs_uuid_start + uuid_end];

        const obj_end = std.mem.indexOf(u8, body[abs_uuid_start..], "}") orelse break;
        const obj_slice = body[pos + uuid_start .. abs_uuid_start + obj_end + 1];

        const x = parseJsonFloat(obj_slice, "\"x\":") orelse 0;
        const y = parseJsonFloat(obj_slice, "\"y\":") orelse 0;
        const angle = parseJsonFloat(obj_slice, "\"angle\":") orelse 0;

        try placements.put(uuid, .{ .x = x, .y = y, .angle = angle });
        pos = abs_uuid_start + obj_end + 1;
    }

    // Pass 1: Find each canopy_uuid in the original content and map its
    // footprint's (at ...) range to the new placement values.
    const Replacement = struct { at_start: usize, at_end: usize, pl: Placement };
    var replacements: std.ArrayListUnmanaged(Replacement) = .empty;
    defer replacements.deinit(allocator);

    const needle = "\"canopy_uuid\" \"";
    var search_pos: usize = 0;
    while (search_pos < pcb_content.len) {
        const rel = std.mem.indexOf(u8, pcb_content[search_pos..], needle) orelse break;
        const uuid_val_start = search_pos + rel + needle.len;
        const uuid_val_end_rel = std.mem.indexOf(u8, pcb_content[uuid_val_start..], "\"") orelse break;
        const uuid_str = pcb_content[uuid_val_start .. uuid_val_start + uuid_val_end_rel];
        search_pos = uuid_val_start + uuid_val_end_rel + 1;

        const pl = placements.get(uuid_str) orelse continue;

        // Walk backwards to find enclosing (footprint "
        const FOOTPRINT_PREFIX = "(footprint \"";
        var fp_start = search_pos - 1;
        while (fp_start > 0) : (fp_start -= 1) {
            if (fp_start + FOOTPRINT_PREFIX.len <= pcb_content.len and
                std.mem.eql(u8, pcb_content[fp_start .. fp_start + FOOTPRINT_PREFIX.len], FOOTPRINT_PREFIX))
                break;
        }
        // Find first (at ...) after (footprint line — skip the footprint name line
        const fp_region = pcb_content[fp_start..uuid_val_start];
        const at_rel = std.mem.indexOf(u8, fp_region, "\n") orelse continue;
        const after_first_line = fp_start + at_rel;
        const at_region = pcb_content[after_first_line..uuid_val_start];
        const at_pos = std.mem.indexOf(u8, at_region, "(at ") orelse continue;
        const abs_at_start = after_first_line + at_pos;
        const at_close = std.mem.indexOf(u8, pcb_content[abs_at_start..], ")") orelse continue;
        const abs_at_end = abs_at_start + at_close + 1;

        try replacements.append(allocator, .{ .at_start = abs_at_start, .at_end = abs_at_end, .pl = pl });
    }

    // Sort replacements by position (should already be in order, but be safe)
    std.mem.sort(Replacement, replacements.items, {}, struct {
        fn lessThan(_: void, a: Replacement, b: Replacement) bool {
            return a.at_start < b.at_start;
        }
    }.lessThan);

    // Pass 2: Build output, replacing each (at ...) range
    var out: std.ArrayListUnmanaged(u8) = .empty;
    try out.ensureTotalCapacity(allocator, pcb_content.len + STREAM_BUF_BYTES);
    const w = out.writer(allocator);

    var cursor: usize = 0;
    for (replacements.items) |r| {
        try w.writeAll(pcb_content[cursor..r.at_start]);
        if (r.pl.angle != 0) {
            try w.print("(at {d:.2} {d:.2} {d:.1})", .{ r.pl.x, r.pl.y, r.pl.angle });
        } else {
            try w.print("(at {d:.2} {d:.2})", .{ r.pl.x, r.pl.y });
        }
        cursor = r.at_end;
    }
    try w.writeAll(pcb_content[cursor..]);

    return out.toOwnedSlice(allocator);
}

fn parseJsonFloat(json: []const u8, key: []const u8) ?f64 {
    const key_pos = std.mem.indexOf(u8, json, key) orelse return null;
    var val_start = key_pos + key.len;
    // Skip optional whitespace after colon
    while (val_start < json.len and (json[val_start] == ' ' or json[val_start] == '\t')) val_start += 1;
    var end = val_start;
    while (end < json.len) : (end += 1) {
        const c = json[end];
        if (c == ',' or c == '}' or c == ' ' or c == '\n' or c == '\r') break;
    }
    return std.fmt.parseFloat(f64, json[val_start..end]) catch null;
}

/// GET /api/erc/:name — run electrical-rule checks (duplicate ref-des,
/// floating nets, unconnected pins, voltage mismatches, missing decoupling)
/// and return the violations as JSON for the schematic viewer's panel.
pub fn ercApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = HTTP_NOT_FOUND;
        return;
    };

    const board_path = try std.fmt.allocPrint(ctx.allocator, SEXP_PATH_TEMPLATE, .{ ctx.project_dir, name });
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
        .board => |b| @as(*const env_mod.DesignBlock, b.design),
        else => {
            res.status = HTTP_INTERNAL_ERROR;
            res.body = "Not a design block";
            return;
        },
    };

    const bom_path = try std.fmt.allocPrint(ctx.allocator, BOM_PATH_TEMPLATE, .{ ctx.project_dir, name });
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
    const board_path = try std.fmt.allocPrint(allocator, SEXP_PATH_TEMPLATE, .{ project_dir, name });
    defer allocator.free(board_path);

    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();

    const result = try eval.evalFile(board_path);
    const block = switch (result) {
        .design_block => |b| b,
        .board => |b| @as(*const env_mod.DesignBlock, b.design),
        else => return error.NotADesign,
    };

    const bom_path = try std.fmt.allocPrint(allocator, BOM_PATH_TEMPLATE, .{ project_dir, name });
    defer allocator.free(bom_path);
    try bom.resolveIdentities(allocator, @constCast(block), bom_path, project_dir);

    const violations = try erc_mod.runErc(allocator, block, project_dir);

    // Run requirement-attached (check ...) primitives + overlay (verifies …)
    // sign-offs so the per-component review entries carry pass/fail/verified
    // status alongside the prose.
    var check_results = req_checks.runChecks(allocator, &eval, block) catch
        std.StringHashMapUnmanaged([]req_checks.Result).empty;
    req_checks.applyVerifications(&check_results, block, block.instances);

    var doc = try review_mod.buildReview(allocator, name, block, eval.assertions.items, violations, &check_results);

    // Attach reconciled review state. Degrades to empty on missing/malformed
    // files so a design with no reviews/ dir still renders a clean report.
    // live_hashes lets reconcile flag stale approvals for sections whose
    // content changed after they were approved.
    const stored_state = review_state_mod.loadState(allocator, project_dir, name) catch review_mod.ReviewState{};
    const live_slugs = try allocator.alloc([]const u8, doc.sections.len);
    const live_hashes = try allocator.alloc([]const u8, doc.sections.len);
    for (doc.sections, 0..) |s, i| {
        live_slugs[i] = s.slug;
        live_hashes[i] = review_mod.sectionContentHash(allocator, s, block, block.sections[i]) catch "";
    }
    doc.review_state = review_state_mod.reconcile(allocator, stored_state, live_slugs, live_hashes) catch review_mod.ReviewState{};

    return doc;
}

fn renderReviewJson(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8) ![]const u8 {
    const doc = try buildDocForName(allocator, project_dir, name);
    return try review_json_mod.renderToJson(allocator, doc);
}

/// Recompute the content hash for a single section so the approve endpoint
/// can stamp it into review-state. Re-evaluates the design, then locates
/// the section whose slug matches. Returns "" if the section isn't found.
fn sectionHashForSlug(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    slug: []const u8,
) ![]const u8 {
    const board_path = try std.fmt.allocPrint(allocator, SEXP_PATH_TEMPLATE, .{ project_dir, name });
    defer allocator.free(board_path);

    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();

    const result = try eval.evalFile(board_path);
    const block = switch (result) {
        .design_block => |b| b,
        .board => |b| @as(*const env_mod.DesignBlock, b.design),
        else => return "",
    };
    const violations = try erc_mod.runErc(allocator, block, project_dir);
    const doc = try review_mod.buildReview(allocator, name, block, eval.assertions.items, violations, null);
    for (doc.sections, 0..) |s, i| {
        if (std.mem.eql(u8, s.slug, slug)) {
            return review_mod.sectionContentHash(allocator, s, block, block.sections[i]) catch "";
        }
    }
    return "";
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

    const board_path = try std.fmt.allocPrint(ctx.allocator, SEXP_PATH_TEMPLATE, .{ ctx.project_dir, name });
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
        .board => |b| @as(*const env_mod.DesignBlock, b.design),
        else => {
            res.status = HTTP_INTERNAL_ERROR;
            res.body = "{\"error\":\"not_a_design\"}";
            return;
        },
    };

    const bom_path = try std.fmt.allocPrint(ctx.allocator, BOM_PATH_TEMPLATE, .{ ctx.project_dir, name });
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

// ── Review-state (persisted per design) ────────────────────────────────

/// Return the reconciled review state for a design as JSON. Reconcile
/// matches the live section list so the client can render empty entries
/// for new sections without a page reload.
pub fn reviewStateGetApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = HTTP_NOT_FOUND;
        return;
    };
    const state = review_state_mod.loadState(ctx.allocator, ctx.project_dir, name) catch review_mod.ReviewState{};
    const json = review_state_mod.renderState(ctx.allocator, state) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = "{\"error\":\"render failed\"}";
        return;
    };
    res.content_type = .JSON;
    res.header(HEADER_CORS_ALLOW_ORIGIN, "*");
    res.body = json;
}

/// POST /api/review-state/:name/item — body {section_slug, text}. Server
/// mints the id and returns {id, version}.
pub fn reviewStateAddItemApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = HTTP_NOT_FOUND;
        return;
    };
    const body = req.body() orelse {
        res.status = HTTP_BAD_REQUEST;
        return;
    };
    const slug = jsonField(body, SECTION_SLUG_KEY) orelse {
        res.status = HTTP_BAD_REQUEST;
        res.body = "missing section_slug";
        return;
    };
    const text = jsonField(body, "text") orelse {
        res.status = HTTP_BAD_REQUEST;
        res.body = "missing text";
        return;
    };
    const id = review_state_mod.addItem(ctx.allocator, ctx.project_dir, name, slug, text) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = "save failed";
        return;
    };
    const v = serve_root.bumpLiveVersion(name);
    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(ctx.allocator, "{{\"ok\":true,\"id\":\"{s}\",\"version\":{d}}}", .{ id, v });
}

/// POST /api/review-state/:name/item/toggle — body {section_slug, id, checked}.
pub fn reviewStateToggleItemApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = HTTP_NOT_FOUND;
        return;
    };
    const body = req.body() orelse {
        res.status = HTTP_BAD_REQUEST;
        return;
    };
    const slug = jsonField(body, SECTION_SLUG_KEY) orelse {
        res.status = HTTP_BAD_REQUEST;
        return;
    };
    const id = jsonField(body, "id") orelse {
        res.status = HTTP_BAD_REQUEST;
        return;
    };
    const checked = jsonBoolField(body, "checked") orelse false;
    review_state_mod.toggleItem(ctx.allocator, ctx.project_dir, name, slug, id, checked) catch {
        res.status = HTTP_INTERNAL_ERROR;
        return;
    };
    const v = serve_root.bumpLiveVersion(name);
    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(ctx.allocator, OK_VERSION_TEMPLATE, .{v});
}

/// POST /api/review-state/:name/item/delete — body {section_slug, id}.
pub fn reviewStateDeleteItemApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = HTTP_NOT_FOUND;
        return;
    };
    const body = req.body() orelse {
        res.status = HTTP_BAD_REQUEST;
        return;
    };
    const slug = jsonField(body, SECTION_SLUG_KEY) orelse {
        res.status = HTTP_BAD_REQUEST;
        return;
    };
    const id = jsonField(body, "id") orelse {
        res.status = HTTP_BAD_REQUEST;
        return;
    };
    review_state_mod.deleteItem(ctx.allocator, ctx.project_dir, name, slug, id) catch {
        res.status = HTTP_INTERNAL_ERROR;
        return;
    };
    const v = serve_root.bumpLiveVersion(name);
    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(ctx.allocator, OK_VERSION_TEMPLATE, .{v});
}

/// POST /api/review-state/:name/approve — body {section_slug, approved, reviewer}.
/// Server stamps approved_at with isoTimestampNow on approval.
pub fn reviewStateApproveApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = HTTP_NOT_FOUND;
        return;
    };
    const body = req.body() orelse {
        res.status = HTTP_BAD_REQUEST;
        return;
    };
    const slug = jsonField(body, SECTION_SLUG_KEY) orelse {
        res.status = HTTP_BAD_REQUEST;
        return;
    };
    const approved = jsonBoolField(body, "approved") orelse false;
    const reviewer = jsonField(body, "reviewer") orelse "";

    // Re-build the design so the approval stamp pins a hash of the section's
    // live content — that way the very next build-time reconcile sees the
    // approval as fresh, and a subsequent edit trips `approval_stale`.
    const content_hash = if (approved) sectionHashForSlug(ctx.allocator, ctx.project_dir, name, slug) catch "" else "";
    review_state_mod.setApproval(ctx.allocator, ctx.project_dir, name, slug, approved, reviewer, content_hash) catch {
        res.status = HTTP_INTERNAL_ERROR;
        return;
    };
    const v = serve_root.bumpLiveVersion(name);
    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(ctx.allocator, OK_VERSION_TEMPLATE, .{v});
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

// Unused import suppression
const suppress = export_kicad_pcb;
