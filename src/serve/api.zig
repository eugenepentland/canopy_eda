//! Core `/api/*` HTTP handlers: build/push, scene-graph JSON, ERC, KiCad
//! export, BOM, and the fab-output downloads. Each handler drives the full
//! eval -> render/export pipeline on the request arena (`req.arena`); a result
//! cached into live server state is duped into `page_allocator` first.
//! `HandlerError` is a wide superset — httpz turns any leaked error into a 5xx.

const std = @import("std");
const build_id = @import("../build_id.zig");
const json_writer = @import("../json_writer.zig");
const httpz = @import("httpz");
const infra_fs = @import("../infra/fs.zig");
const lib_limits = @import("../lib_limits.zig");
const log = @import("../infra/log.zig");
const paths = @import("../paths.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const render_json = @import("../render_json.zig");
const export_kicad = @import("../export_kicad.zig");
const bom = @import("../bom.zig");
const zipfile = @import("../zipfile.zig");
const erc_mod = @import("../erc.zig");
const env_mod = @import("../eval/env.zig");
const parser_mod = @import("../sexpr/parser.zig");
const bom_html = @import("bom_html.zig");
const mcp_tools = @import("mcp_tools.zig");
const review_mod = @import("../review.zig");
const thermal_api = @import("thermal_api.zig");
const review_md_mod = @import("../review_md.zig");
const req_checks = @import("../req_checks.zig");
const edit_mod = @import("edit.zig");
const diag_format = @import("diag_format.zig");
const urlcodec = @import("urlcodec.zig");
const page_cache = @import("page_cache.zig");
const serve_root = @import("../serve.zig");
const Server = serve_root.Server;

// ── Constants ─────────────────────────────────────────────────────
const http_not_found: u16 = 404;
const http_bad_request: u16 = 400;
const http_internal_error: u16 = 500;

const max_source_bytes: usize = 10 * 1024 * 1024;
const stream_buf_bytes: usize = 8192;

// Headers
const header_cors_allow_origin = "access-control-allow-origin";
const header_content_type = "Content-Type";
const header_content_disposition = "Content-Disposition";
const content_type_zip = "application/zip";

// JSON fragments / response templates
const err_build = "Build error";
const err_no_body_json = "{\"error\":\"no body\"}";
const ok_json_true = "{\"ok\":true}";
const ok_version_template = "{{\"ok\":true,\"version\":{d}}}";
const err_ok_false_template = "{{\"ok\":false,\"error\":\"{s}\"}}";
const name_field_prefix = "{\"name\":";
const empty_datasheets_reqs = ",\"datasheets\":[],\"requirements\":[]";
const datasheet_ref = @import("datasheet_ref.zig");

/// Error set for HTTP handlers in this module. Wide because handlers
/// orchestrate many subsystems (eval, render, parser, file IO, BOM resolve)
/// and propagate the worst case via `try`. httpz turns any leaked error
/// into a 5xx body, so the union just needs to be a superset of every
/// callee — the type itself is informational.
pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error ||
    infra_fs.File.WriteError || infra_fs.File.OpenError || infra_fs.File.ReadError ||
    infra_fs.Dir.MakeError || infra_fs.Dir.StatFileError ||
    @import("../bom_resolve.zig").ResolveError ||
    @import("../sexpr/parser.zig").ParseError ||
    error{InvalidName} ||
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
/// picks up the rebuild on its next `/api/version/:name` poll. On a build
/// failure the JSON body carries a structured `diagnostic`
/// (`{file,line,col,message,source_line}`) alongside the human-readable text.
pub fn pushApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = http_not_found;
        return;
    };

    const board_path = try paths.designSourcePath(ctx.allocator, ctx.project_dir, name);
    defer ctx.allocator.free(board_path);

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();
    const result = eval.evalFile(board_path) catch |e| {
        try writeBuildErrorJson(ctx, res, board_path, @errorName(e), eval.last_error);
        return;
    };
    const block = switch (result) {
        .design_block => |b| b,
        else => {
            try writeBuildErrorJson(ctx, res, board_path, "not a design-block", null);
            return;
        },
    };

    const new_layout = render_json.renderSceneGraph(ctx.allocator, block, ctx.project_dir) catch null;
    serve_root.setLiveLayoutJson(name, new_layout);
    const v = serve_root.bumpLiveVersion(name);

    std.debug.print("Pushed {s} (v{d})\n", .{ name, v });
    res.body = "ok";
}

/// 500 + `{"ok":false,"error":<text>,"diagnostic":{…}}` for a failed build.
/// `error` is the compiler-style human text (`file:line:col: message` plus the
/// caret block); `diagnostic` is the same data structured for tooling.
fn writeBuildErrorJson(
    ctx: *Server,
    res: *httpz.Response,
    board_path: []const u8,
    err_name: []const u8,
    last_error: ?@import("../eval/evaluator.zig").EvalDiagnostic,
) HandlerError!void {
    const d = try diag_format.load(ctx.allocator, board_path, err_name, last_error);
    const text = try diag_format.formatText(ctx.allocator, d);
    var buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    const w = &buf.writer;
    try w.writeAll("{\"ok\":false,\"error\":");
    try json_writer.writeString(w, text);
    try w.writeAll(",\"diagnostic\":");
    try diag_format.writeJson(w, d);
    try w.writeAll("}");
    res.status = http_internal_error;
    res.content_type = .JSON;
    res.body = buf.written();
}

/// GET /api/version/:name — return `{"version":N}`. The schematic viewer
/// polls this every ~500 ms and reloads the scene graph when N changes.
/// Bumped by `pushApi` and the CLI mutation tools.
pub fn versionApi(_: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = http_not_found;
        return;
    };
    const v = serve_root.getLiveVersion(name);

    res.content_type = .JSON;
    res.header(header_cors_allow_origin, "*");
    const w = res.writer();
    try w.print("{{\"version\":{d}}}", .{v});
}

/// GET /api/scene-graph/:name — return the cached schematic scene-graph JSON
/// produced by the last build/push OF THAT DESIGN.
///
/// Two properties this endpoint used to lack. First, the bytes are copied into
/// `res.arena` while the live lock is held (`liveLayoutFor`), because httpz
/// serializes `res.body` after the handler returns: publishing the shared
/// pointer raced any concurrent push, which frees the previous buffer. Second,
/// the server keeps ONE live slot, so a request whose `:name` is not the design
/// that slot holds is answered 404 rather than handed another design's scene
/// graph — the same "no layout" body it already answered before anything was
/// pushed at all.
pub fn sceneGraphApi(_: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = http_not_found;
        return;
    };
    res.content_type = .JSON;
    res.header(header_cors_allow_origin, "*");
    res.body = serve_root.liveLayoutFor(res.arena, name) orelse {
        res.status = http_not_found;
        res.body = "{\"error\":\"no layout\"}";
        return;
    };
}

/// Serve a component's pinout file (lib/pinouts/:name.sexp) as JSON so the
/// schematic viewer can show the full pin map — primary function + every
/// alternate function — next to the ref-des. Lets the user verify, for
/// example, that the pin they wired to XSPIM_P1_IO5 really does expose that
/// peripheral on the part.
pub fn pinoutApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name_raw = req.param("name") orelse {
        res.status = http_not_found;
        return;
    };
    // Decode before validating so `%2e%2e` can't slip past the traversal check,
    // and so library files with reserved chars (e.g. `…#pbf`) actually resolve.
    const name = try urlcodec.decodeAlloc(ctx.allocator, name_raw);
    if (name.len == 0 or std.mem.indexOfAny(u8, name, "/\\") != null or std.mem.indexOf(u8, name, "..") != null) {
        res.status = http_bad_request;
        res.body = "{\"error\":\"invalid component name\"}";
        res.content_type = .JSON;
        return;
    }

    const path = try std.fmt.allocPrint(ctx.allocator, "{s}/lib/pinouts/{s}.sexp", .{ ctx.project_dir, name });
    defer ctx.allocator.free(path);

    const content = infra_fs.cwd().readFileAlloc(ctx.allocator, path, lib_limits.max_lib_file_bytes) catch |err| {
        // The status stays 404 on every failure: the viewer treats "no pinout"
        // as a soft absence and must not begin 5xx-ing over a library file it
        // could not read. But a pinout that EXISTS and merely failed to load is
        // not "not found", and answering 404 makes it indistinguishable from a
        // part that never had one — so name it on stderr.
        if (err != error.FileNotFound)
            log.warn("pinout api: '{s}' not readable ({s}) — answering 404", .{ path, @errorName(err) });
        res.status = http_not_found;
        res.content_type = .JSON;
        res.body = "{\"error\":\"pinout not found\"}";
        return;
    };

    const nodes = parser_mod.parse(ctx.allocator, content) catch {
        res.status = http_internal_error;
        res.content_type = .JSON;
        res.body = "{\"error\":\"parse error\"}";
        return;
    };

    var buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    const w = &buf.writer;

    try w.writeAll("{\"component\":");
    try json_writer.writeString(w, name);
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
                        try json_writer.writeString(w, pin_id);
                        try w.writeAll(",\"fn\":");
                        try json_writer.writeString(w, fn_name);
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
                                try w.writeAll(name_field_prefix);
                                try json_writer.writeString(w, alt_name);
                                try w.writeAll(",\"type\":");
                                try json_writer.writeString(w, etype);
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
    res.header(header_cors_allow_origin, "*");
    res.body = buf.written();
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
        try w.writeAll(empty_datasheets_reqs);
        return;
    };
    const nodes = parser_mod.parse(allocator, content) catch {
        try w.writeAll(empty_datasheets_reqs);
        return;
    };
    if (nodes.len == 0) {
        try w.writeAll(empty_datasheets_reqs);
        return;
    }
    const top = nodes[0].asList() orelse {
        try w.writeAll(empty_datasheets_reqs);
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
        const remote = datasheet_ref.isRemote(ds);
        const size = if (remote) 0 else datasheetSize(allocator, project_dir, ds);
        try w.writeAll(name_field_prefix);
        try json_writer.writeString(w, ds);
        try w.print(",\"size\":{d},\"remote\":{s}}}", .{ size, if (remote) "true" else "false" });
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
        try json_writer.writeString(w, text);
        for (cl[2..]) |extra| {
            if (env_mod.parseNoteRef(extra)) |r| {
                try w.writeAll(",\"pdf\":");
                try json_writer.writeString(w, r.pdf);
                try w.print(",\"page\":{d}", .{r.page});
                if (r.quote) |q| {
                    try w.writeAll(",\"quote\":");
                    try json_writer.writeString(w, q);
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
    if (!datasheet_ref.isLocal(name)) return 0;
    const path = std.fmt.allocPrint(allocator, "{s}/lib/datasheets/{s}", .{ project_dir, name }) catch return 0;
    defer allocator.free(path);
    const f = infra_fs.cwd().openFile(path, .{}) catch return 0;
    defer f.close();
    const stat = f.stat() catch return 0;
    return stat.size;
}

test "component library info marks HTTP datasheets as remote" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "lib/components");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/components/remote.sexp",
        .data = "(component remote (datasheet \"https" ++ "://example.com/part.pdf\"))\n",
    });
    const project_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);

    var out: std.Io.Writer.Allocating = .init(allocator);
    try writeComponentLibInfo(allocator, &out.writer, project_dir, "remote");
    try std.testing.expect(std.mem.indexOf(
        u8,
        out.written(),
        "\"name\":\"https" ++ "://example.com/part.pdf\",\"size\":0,\"remote\":true",
    ) != null);
}

/// A design with one unconnected pin, so its ERC answer is a real violations
/// document rather than an empty list.
fn writeErcFixture(dir: std.Io.Dir) !void {
    try dir.createDirPath(std.testing.io, "lib/components");
    try dir.createDirPath(std.testing.io, "src");
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/erc-ic.sexp", .data =
        \\(component "erc-ic"
        \\  (description "minimal test regulator"))
    });
    try dir.writeFile(std.testing.io, .{ .sub_path = "src/ercdemo.sexp", .data =
        \\(import erc-ic)
        \\
        \\(design-block "ERC Demo Board"
        \\  (instance "U1" erc-ic
        \\    (id "aa000001")
        \\    (pin 1 "VIN")
        \\    (pin 2 "GND")))
    });
}

/// Drive the real ERC handler against a SHARED server state, so successive
/// calls see the same response cache, and report the body alongside the
/// cache's own verdict header.
fn serveErc(
    state: *serve_root.ServerState,
    alloc: std.mem.Allocator,
    project: []const u8,
    name: []const u8,
) !struct { body: []const u8, cache: []const u8 } {
    var srv = Server{ .allocator = alloc, .project_dir = project, .auth_dir = project, .state = state };
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.param("name", name);
    try ercApi(&srv, ht.req, ht.res);
    return .{
        .body = try alloc.dupe(u8, ht.res.body),
        .cache = try alloc.dupe(u8, ht.res.headers.get("X-Netlisp-Erc-Cache") orelse ""),
    };
}

// spec: Web Server - A cached ERC answer is byte-identical to the freshly computed one it was retained from, and an edit to the design retires it
test "the ERC endpoint answers a repeat request with the identical bytes it retained" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeErcFixture(tmp.dir);
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    var state = serve_root.ServerState{ .caches = .init(std.testing.allocator) };
    defer state.caches.deinit();

    const fresh = try serveErc(&state, alloc, project, "ercdemo");
    try std.testing.expectEqualStrings("miss", fresh.cache);
    const cached = try serveErc(&state, alloc, project, "ercdemo");
    try std.testing.expectEqualStrings("hit", cached.cache);
    // The whole contract: a cache loss changes latency and nothing else.
    try std.testing.expectEqualStrings(fresh.body, cached.body);

    // Adding a second part changes the violations, so the entry must not
    // survive the edit that changed them.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/ercdemo.sexp", .data =
        \\(import erc-ic)
        \\
        \\(design-block "ERC Demo Board"
        \\  (instance "U1" erc-ic
        \\    (id "aa000001")
        \\    (pin 1 "VIN")
        \\    (pin 2 "GND"))
        \\  (instance "U2" erc-ic
        \\    (id "aa000002")
        \\    (pin 1 "VIN")
        \\    (pin 2 "GND")))
    });
    const edited = try serveErc(&state, alloc, project, "ercdemo");
    try std.testing.expectEqualStrings("miss", edited.cache);
    try std.testing.expect(!std.mem.eql(u8, fresh.body, edited.body));
}

// spec: Web Server - The pinout endpoint reads its library file at the class-owned lib_limits cap, so a pinout past the retired 256 KiB figure is served rather than answered 404
test "the pinout endpoint serves a pinout past the retired 256 KiB cap" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // The cap is `lib_limits`', not a literal here. In the 256 KiB..1 MiB band
    // this endpoint used to answer 404 "pinout not found" for a file that was
    // on disk all along — indistinguishable from a part with no pinout.
    const data = try lib_limits.synthPinoutSource(alloc, "big", lib_limits.retired_lib_file_cap_bytes + 4096);
    try std.testing.expect(data.len > lib_limits.retired_lib_file_cap_bytes);
    try std.testing.expect(data.len < lib_limits.max_lib_file_bytes);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "lib/pinouts");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/pinouts/big.sexp", .data = data });
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    var state = serve_root.ServerState{ .caches = .init(std.testing.allocator) };
    defer state.caches.deinit();
    var srv = Server{ .allocator = alloc, .project_dir = project, .auth_dir = project, .state = &state };

    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.param("name", "big");
    try pinoutApi(&srv, ht.req, ht.res);

    try std.testing.expect(ht.res.status != http_not_found);
    // The sentinel pin is the file's last row, so it is in the body only if the
    // read covered the whole file.
    try std.testing.expect(std.mem.indexOf(u8, ht.res.body, "\"LASTFN\"") != null);
}

/// GET /api/export-kicad/:name — build the design, resolve BOM identities,
/// and stream back a `<name>-kicad.zip` containing the KiCad schematic,
/// netlist, and per-instance footprint files.
const ExportTarget = struct { name: []const u8, block: *env_mod.DesignBlock };

/// Shared export prologue: resolve `:name` to its `.sexp`, evaluate it, and
/// return the design block plus the name. On missing param / build failure /
/// non-design result, sets res.status (and body) and returns null. `eval` is
/// owned by the caller so the returned block outlives this call.
fn evalDesignForExport(
    ctx: *Server,
    req: *httpz.Request,
    res: *httpz.Response,
    eval: *Evaluator,
) HandlerError!?ExportTarget {
    const name = req.param("name") orelse {
        res.status = http_not_found;
        return null;
    };

    const board_path = try paths.designSourcePath(ctx.allocator, ctx.project_dir, name);
    defer ctx.allocator.free(board_path);

    const result = eval.evalFile(board_path) catch {
        res.status = http_internal_error;
        res.body = err_build;
        return null;
    };

    return switch (result) {
        .design_block => |b| .{ .name = name, .block = b },
        else => {
            res.status = http_internal_error;
            return null;
        },
    };
}

/// True unless query `key` is explicitly switched off (`=0` / `=false` / an
/// empty value) — the shape for a bundle part that ships by default and can be
/// opted out of.
fn queryFlagOn(req: *httpz.Request, key: []const u8) bool {
    const q = req.query() catch return true;
    const v = q.get(key) orelse return true;
    return !(v.len == 0 or std.mem.eql(u8, v, "0") or std.mem.eql(u8, v, "false"));
}

/// GET /api/export-kicad/:name — build the design and return a zip bundling the
/// KiCad netlist, generated footprints, and STEP models for hand-off to the PCB
/// editor, plus the `.kicad_sch` hierarchy and its project sidecars so the
/// archive opens as a complete KiCad project. `?schematic=0` drops the drawing
/// and returns the netlist-only bundle the endpoint used to serve.
pub fn exportKicadApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();
    const target = (try evalDesignForExport(ctx, req, res, &eval)) orelse return;
    const name = target.name;
    const block = target.block;

    const bom_path = paths.designSiblingPath(ctx.allocator, ctx.project_dir, name, ".bom") catch {
        res.status = http_internal_error;
        return;
    };
    try bom.resolveIdentities(ctx.allocator, block, bom_path, ctx.project_dir);

    const want_sch = queryFlagOn(req, "schematic");
    const zip_data = export_kicad.exportKicadZip(
        ctx.allocator,
        block,
        ctx.project_dir,
        name,
        .{ .schematic = want_sch },
    ) catch {
        res.status = http_internal_error;
        res.body = "Export error";
        return;
    };

    const disposition = std.fmt.allocPrint(ctx.allocator, "attachment; filename=\"{s}-kicad.zip\"", .{name}) catch {
        res.status = http_internal_error;
        return;
    };

    res.header(header_content_type, content_type_zip);
    res.header(header_content_disposition, disposition);
    res.body = zip_data;
}

/// GET /api/export-netlist/:name — build the design and return just the
/// KiCad `.net` file (no footprints, no zip). Used by external tools that
/// only care about connectivity for routing or simulation.
pub fn exportNetlistApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();
    const target = (try evalDesignForExport(ctx, req, res, &eval)) orelse return;
    const name = target.name;
    const block = target.block;

    const bom_path = paths.designSiblingPath(ctx.allocator, ctx.project_dir, name, ".bom") catch {
        res.status = http_internal_error;
        return;
    };
    try bom.resolveIdentities(ctx.allocator, block, bom_path, ctx.project_dir);

    const netlist = export_kicad.exportNetlistOnly(ctx.allocator, block, ctx.project_dir, name) catch {
        res.status = http_internal_error;
        res.body = "Export error";
        return;
    };

    const disposition = std.fmt.allocPrint(ctx.allocator, "attachment; filename=\"{s}.net\"", .{name}) catch {
        res.status = http_internal_error;
        return;
    };

    res.header(header_content_type, "text/plain");
    res.header(header_content_disposition, disposition);
    res.body = netlist;
}

/// GET /api/export-bom-csv/:name — build the design and stream the parts
/// list as `<name>-bom.csv`. Same column layout as the BOM table on the
/// review page; suitable for hand-off to procurement.
pub fn exportBomCsvApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();
    const target = (try evalDesignForExport(ctx, req, res, &eval)) orelse return;
    const name = target.name;
    const block = target.block;

    // Merge in the persisted BOM (manual MPN, manufacturer, datasheet edits
    // from the schematic page). Without this the CSV reflects only what the
    // .sexp source declares — passives whose MPN was set via the inline
    // editor come out blank.
    const bom_path = try paths.designSiblingPath(ctx.allocator, ctx.project_dir, name, ".bom");
    defer ctx.allocator.free(bom_path);
    bom.resolveIdentities(ctx.allocator, block, bom_path, ctx.project_dir) catch |e| {
        log.warn("resolveIdentities {s} failed: {s}", .{ name, @errorName(e) });
    };

    var buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    const w = &buf.writer;
    try bom_html.writeBomCsv(ctx.allocator, w, block);

    const disposition = std.fmt.allocPrint(ctx.allocator, "attachment; filename=\"{s}-bom.csv\"", .{name}) catch {
        res.status = http_internal_error;
        return;
    };

    res.header(header_content_type, "text/csv");
    res.header(header_content_disposition, disposition);
    res.header(header_cors_allow_origin, "*");
    res.body = buf.written();
}

/// GET /api/export-review/:name — design-review package as a zip. Contains
/// `README.md` (a map of the package), `<name>-review.md` (the full markdown
/// report — block overview, validation, power tables, per-hub schematics),
/// `<name>-bom.csv` (the parts list), and the verbatim `.sexp` source for the
/// design plus every sub-module and component it imports — laid out under
/// `src/` and `lib/` so the bundle mirrors a buildable project tree.
pub fn exportReviewPackageApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = http_not_found;
        return;
    };

    // Evaluate the design (or a standalone module) once and keep `eval` alive:
    // its `loaded_files` read-set is the exact list of source files that fed
    // this build — the design itself plus every imported lib/modules and
    // lib/components file — which we bundle alongside the report.
    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();

    const nb = mcp_tools.evalNamedBlock(ctx.allocator, ctx.project_dir, name, &eval) catch {
        res.status = http_internal_error;
        res.body = err_build;
        return;
    };
    const block = nb.block;

    // Merge persisted BOM identities (manual MPN/manufacturer/datasheet edits
    // from the schematic page) so the report + CSV match the live page. A
    // standalone module has no `.bom` sidecar, so skip it there.
    if (!nb.is_module) {
        const bom_path = paths.designSiblingPath(ctx.allocator, ctx.project_dir, name, ".bom") catch null;
        if (bom_path) |bp| {
            defer ctx.allocator.free(bp);
            bom.resolveIdentities(ctx.allocator, block, bp, ctx.project_dir) catch |e| {
                log.warn("export-review resolveIdentities {s} failed: {s}", .{ name, @errorName(e) });
            };
        }
    }

    const violations = mcp_tools.runErcForNamedBlock(ctx.allocator, nb, ctx.project_dir) catch
        &[_]erc_mod.Violation{};

    var check_results = req_checks.runChecks(ctx.allocator, &eval, block) catch
        std.StringHashMapUnmanaged([]req_checks.Result).empty;
    req_checks.applyVerifications(&check_results, block, block.instances);

    var doc = review_mod.buildReview(ctx.allocator, name, block, eval.assertions.items, violations, &check_results) catch {
        res.status = http_internal_error;
        res.body = err_build;
        return;
    };
    // Same attachment the schematic page makes: `buildReview` reads the block
    // alone, and the cooling ladder needs this handler's project directory and
    // the design's saved layouts.
    doc.power.scenarios = thermal_api.scenariosFor(
        ctx.allocator,
        ctx.project_dir,
        name,
        doc.power.thermal,
        doc.power.thermal.ambient_c,
        // The review document describes the design's DEFAULT board, the one the
        // rest of it reports on; comparing named layouts is the thermal page's job.
        null,
    ) catch .{};

    // The design's own top-level source — read once, used only for the zip
    // entry below (the report no longer embeds it; every source file ships as
    // its own zip entry instead).
    const board_path = paths.designSourcePath(ctx.allocator, ctx.project_dir, name) catch null;
    defer if (board_path) |bp| ctx.allocator.free(bp);
    const source: []const u8 = if (board_path) |bp|
        infra_fs.cwd().readFileAlloc(ctx.allocator, bp, max_source_bytes) catch &[_]u8{}
    else
        &[_]u8{};

    const md = review_md_mod.renderToMarkdown(ctx.allocator, block, ctx.project_dir, name, doc, build_id.current()) catch {
        res.status = http_internal_error;
        res.body = "Markdown render error";
        return;
    };

    var csv_buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    bom_html.writeBomCsv(ctx.allocator, &csv_buf.writer, block) catch {
        res.status = http_internal_error;
        res.body = "BOM CSV error";
        return;
    };

    // Collect every source `.sexp` the evaluator read, each under its path
    // relative to the project dir so the bundle reads as a buildable project
    // tree (src/<design>.sexp, lib/modules/*.sexp, lib/components/*.sexp).
    var sources: std.ArrayList(zipfile.Entry) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;

    // The design's own top-level source, added explicitly rather than via
    // `loaded_files`: the evaluator keys the root file on a path slice its
    // caller frees, so that one key can dangle by the time we iterate here.
    // Every *imported* lib file is keyed on a stable dup and is read in the
    // loop below. `source` is the verbatim file (already read for the report).
    if (board_path) |bp| if (source.len > 0) {
        const zn = zipNameForSource(ctx.project_dir, bp);
        try seen.put(ctx.allocator, zn, {});
        try sources.append(ctx.allocator, .{ .name = zn, .data = source });
    };

    var it = eval.loaded_files.keyIterator();
    while (it.next()) |k| {
        const path = k.*;
        if (!std.mem.endsWith(u8, path, ".sexp")) continue;
        const zip_name = zipNameForSource(ctx.project_dir, path);
        if (seen.contains(zip_name)) continue;
        const data = infra_fs.cwd().readFileAlloc(ctx.allocator, path, max_source_bytes) catch continue;
        try seen.put(ctx.allocator, zip_name, {});
        try sources.append(ctx.allocator, .{ .name = zip_name, .data = data });
    }

    // A README mapping the package — what to open first + the source-tree
    // layout — built from the just-collected source names. Non-fatal.
    const source_names = try ctx.allocator.alloc([]const u8, sources.items.len);
    for (sources.items, 0..) |s, i| source_names[i] = s.name;
    const readme = review_md_mod.renderReadme(ctx.allocator, name, doc.generated_at, build_id.current(), source_names) catch "";

    // Assemble the zip: README, report, and CSV at the root, then the source tree.
    const md_name = try std.fmt.allocPrint(ctx.allocator, "{s}-review.md", .{name});
    const csv_name = try std.fmt.allocPrint(ctx.allocator, "{s}-bom.csv", .{name});

    var entries: std.ArrayList(zipfile.Entry) = .empty;
    if (readme.len > 0) try entries.append(ctx.allocator, .{ .name = "README.md", .data = readme });
    try entries.append(ctx.allocator, .{ .name = md_name, .data = md });
    try entries.append(ctx.allocator, .{ .name = csv_name, .data = csv_buf.written() });
    try entries.appendSlice(ctx.allocator, sources.items);

    var zw: std.Io.Writer.Allocating = .init(ctx.allocator);
    zipfile.write(&zw.writer, entries.items) catch {
        zw.deinit();
        res.status = http_internal_error;
        res.body = "Zip error";
        return;
    };
    const zip = try zw.toOwnedSlice();

    // Version the package filename with the build's git hash so successive
    // exports are distinguishable and each review traces to a known build.
    const disposition = try std.fmt.allocPrint(
        ctx.allocator,
        "attachment; filename=\"{s}-review-{s}.zip\"",
        .{ name, build_id.current() },
    );
    res.header(header_content_type, content_type_zip);
    res.header(header_content_disposition, disposition);
    res.header(header_cors_allow_origin, "*");
    res.body = zip;
}

/// Map a loaded source path to its in-zip name: strip the project-dir prefix
/// so the bundle keeps the `src/…` / `lib/…` layout. Falls back to the
/// `lib/`/`src/` tail (for shared-lib paths outside the project dir), then the
/// bare basename.
fn zipNameForSource(project_dir: []const u8, path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, path, project_dir)) {
        const rem = std.mem.trimStart(u8, path[project_dir.len..], "/");
        if (rem.len > 0) return rem;
    }
    if (std.mem.lastIndexOf(u8, path, "/lib/")) |i| return path[i + 1 ..];
    if (std.mem.lastIndexOf(u8, path, "/src/")) |i| return path[i + 1 ..];
    return std.fs.path.basename(path);
}

/// GET /api/erc/:name — run electrical-rule checks (duplicate ref-des,
/// floating nets, unconnected pins, voltage mismatches, missing decoupling)
/// and return the violations as JSON for the schematic viewer's panel.
///
/// The violations are a pure function of the design's sources and its `.bom`
/// identities, so a repeat request for an unchanged design is answered from
/// `serve/read_cache.zig` instead of paying the fresh evaluation again — which
/// on the largest board here is essentially the whole 4 s cost of the endpoint.
/// The endpoint takes no query parameters, so any query bypasses the cache.
pub fn ercApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = http_not_found;
        return;
    };
    // Read the live version BEFORE computing, so a design edit that lands
    // mid-request is treated as a miss next time instead of being baked in.
    const live_version = serve_root.getLiveVersion(name);
    var miss_version: ?u32 = null;
    if (ctx.state.caches.reads.erc.serve(.{
        .scratch = ctx.allocator,
        .req = req,
        .res = res,
        .name = name,
        .live_version = live_version,
    }, &miss_version)) {
        res.content_type = .JSON;
        res.header(header_cors_allow_origin, "*");
        return;
    }

    const board_path = try paths.designSourcePath(ctx.allocator, ctx.project_dir, name);
    defer ctx.allocator.free(board_path);

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();

    const result = eval.evalFile(board_path) catch {
        res.status = http_internal_error;
        res.body = err_build;
        return;
    };

    const block = switch (result) {
        .design_block => |b| b,
        else => {
            res.status = http_internal_error;
            res.body = "Not a design block";
            return;
        },
    };

    const bom_path = try paths.designSiblingPath(ctx.allocator, ctx.project_dir, name, ".bom");
    defer ctx.allocator.free(bom_path);
    try bom.resolveIdentities(ctx.allocator, @constCast(block), bom_path, ctx.project_dir);

    const violations = erc_mod.runErc(ctx.allocator, block, ctx.project_dir) catch {
        res.status = http_internal_error;
        res.body = "ERC error";
        return;
    };

    const json = erc_mod.writeViolationsJson(ctx.allocator, violations) catch {
        res.status = http_internal_error;
        return;
    };

    res.content_type = .JSON;
    res.header(header_cors_allow_origin, "*");
    res.body = json;
    // Captured AFTER `resolveIdentities`, which rewrites the `.bom` when an
    // identity actually moved: stamping it beforehand would record the mtime
    // this very request was about to invalidate.
    ctx.state.caches.reads.erc.store(.{
        .scratch = ctx.allocator,
        .req = req,
        .res = res,
        .name = name,
        .body = json,
        .files = page_cache.capture(ctx.allocator, &eval, ctx.project_dir, name) catch null,
        .live_version = miss_version,
        .current_version = serve_root.getLiveVersion(name),
    });
}

/// Return all designs in the project as a JSON array. Same shape as the
/// CLI `list_designs` tool: `[{name, title, sections, instance_count,
/// net_count, mtime, build_ok}, ...]`.
pub fn designsApi(ctx: *Server, _: *httpz.Request, res: *httpz.Response) HandlerError!void {
    res.content_type = .JSON;
    res.header(header_cors_allow_origin, "*");

    const summaries = mcp_tools.listDesignSummaries(ctx.allocator, ctx.project_dir) catch &[_]mcp_tools.DesignSummary{};

    var buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    const w = &buf.writer;
    try w.writeAll("[");
    for (summaries, 0..) |s, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll(name_field_prefix);
        try json_writer.writeString(w, s.name);
        try w.writeAll(",\"title\":");
        try json_writer.writeString(w, s.title);
        try w.writeAll(",\"sections\":[");
        for (s.sections, 0..) |sec, si| {
            if (si > 0) try w.writeAll(",");
            try json_writer.writeString(w, sec);
        }
        try w.print("],\"instance_count\":{d},\"net_count\":{d},\"mtime\":{d},\"build_ok\":{s}}}", .{
            s.instance_count,
            s.net_count,
            s.mtime_sec,
            if (s.build_ok) "true" else "false",
        });
    }
    try w.writeAll("]");
    res.body = buf.written();
}

/// List free (unassigned) pins on an instance. Thin wrapper over the CLI
/// tool implementation so the browser sidebar can populate the "move pin"
/// dropdown without invoking the local CLI.
pub fn freePinsApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    res.content_type = .JSON;
    res.header(header_cors_allow_origin, "*");

    const name = req.param("name") orelse {
        res.status = http_not_found;
        res.body = "{\"error\":\"missing name\"}";
        return;
    };
    const qs = req.query() catch {
        res.status = http_bad_request;
        res.body = "{\"error\":\"invalid query\"}";
        return;
    };
    const ref_des = qs.get("ref") orelse {
        res.status = http_bad_request;
        res.body = "{\"error\":\"missing ref\"}";
        return;
    };

    var buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer buf.deinit();
    const w = &buf.writer;
    const ok = mcp_tools.listFreePins(ctx.allocator, ctx.project_dir, name, ref_des, .{}, w) catch {
        res.status = http_internal_error;
        res.body = "{\"error\":\"internal\"}";
        return;
    };
    if (!ok) {
        res.status = http_internal_error;
        // The buffer holds plain text like "error: instance not found".
        res.body = try std.fmt.allocPrint(ctx.allocator, "{{\"error\":\"{s}\"}}", .{buf.written()});
        return;
    }
    res.body = try ctx.allocator.dupe(u8, buf.written());
}

/// Return the current `{components, nets}` JSON for a design, matching the
/// shape of the globals `COMPONENTS` and `NETS` that `canvas_page.zig`
/// inlines at page load. The UI uses this after mutations to refresh the
/// sidebar without reloading the page.
pub fn designStateApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    res.content_type = .JSON;
    res.header(header_cors_allow_origin, "*");

    const name = req.param("name") orelse {
        res.status = http_not_found;
        res.body = "{\"error\":\"missing name\"}";
        return;
    };

    const board_path = try paths.designSourcePath(ctx.allocator, ctx.project_dir, name);
    defer ctx.allocator.free(board_path);

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();
    const result = eval.evalFile(board_path) catch {
        res.status = http_internal_error;
        res.body = "{\"error\":\"rebuild_failed\"}";
        return;
    };
    const block = switch (result) {
        .design_block => |b| b,
        else => {
            res.status = http_internal_error;
            res.body = "{\"error\":\"not_a_design\"}";
            return;
        },
    };

    const bom_path = try paths.designSiblingPath(ctx.allocator, ctx.project_dir, name, ".bom");
    defer ctx.allocator.free(bom_path);
    try bom.resolveIdentities(ctx.allocator, @constCast(block), bom_path, ctx.project_dir);

    var sym_cache = try bom_html.buildSymbolPinCache(ctx.allocator, ctx.project_dir);

    var buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer buf.deinit();
    const w = &buf.writer;
    try w.writeAll("{\"components\":{");
    _ = try bom_html.writeComponentsJson(w, block, "", &sym_cache, ctx.allocator, ctx.project_dir);
    try w.writeAll("},\"nets\":{");
    _ = try bom_html.writeNetsJson(ctx.allocator, w, block, "");
    try w.writeAll("}}");

    res.body = try ctx.allocator.dupe(u8, buf.written());
}

/// POST /api/section-note/:name/add — body `{section, text, pdf?, page?}`.
/// Splices a new `(note "text" [(ref ...)])` into the named section of the
/// design's .sexp. Returns the new live_version so the browser's 2 s poll
/// picks up the redraw.
pub fn addSectionNoteApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = http_not_found;
        return;
    };
    const body = req.body() orelse {
        res.status = http_bad_request;
        return;
    };
    const section = jsonField(body, "section") orelse {
        res.status = http_bad_request;
        return;
    };
    const text = jsonField(body, "text") orelse {
        res.status = http_bad_request;
        return;
    };
    const pdf = jsonField(body, "pdf") orelse "";
    const page_u = jsonUintField(body, "page") orelse 0;
    const page: u32 = @intCast(page_u);

    const result = edit_mod.addSectionNoteCore(ctx.allocator, ctx.project_dir, name, section, text, pdf, page) catch |err| {
        res.status = http_internal_error;
        res.content_type = .JSON;
        res.body = try std.fmt.allocPrint(ctx.allocator, err_ok_false_template, .{@errorName(err)});
        return;
    };
    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(ctx.allocator, ok_version_template, .{result.version});
}

/// POST /api/section-note/:name/remove — body `{section, index}`. Deletes the
/// nth (0-based) `(note ...)` form nested directly in the named section.
pub fn removeSectionNoteApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = http_not_found;
        return;
    };
    const body = req.body() orelse {
        res.status = http_bad_request;
        return;
    };
    const section = jsonField(body, "section") orelse {
        res.status = http_bad_request;
        return;
    };
    const idx_u = jsonUintField(body, "index") orelse 0;
    const idx: usize = @intCast(idx_u);

    const result = edit_mod.removeSectionNoteCore(ctx.allocator, ctx.project_dir, name, section, idx) catch |err| {
        res.status = http_internal_error;
        res.content_type = .JSON;
        res.body = try std.fmt.allocPrint(ctx.allocator, err_ok_false_template, .{@errorName(err)});
        return;
    };
    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(ctx.allocator, ok_version_template, .{result.version});
}

/// POST /api/component-datasheet/:component/add — body `{pdf: "file.pdf"}`.
/// Splices a `(datasheet "file.pdf")` entry into
/// `lib/components/<component>.sexp`. Lets the sidebar link uploaded PDFs
/// to parts without manual .sexp editing.
pub fn addComponentDatasheetApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const component_raw = req.param("component") orelse {
        res.status = http_not_found;
        return;
    };
    const component = try urlcodec.decodeAlloc(ctx.allocator, component_raw);
    const body = req.body() orelse {
        res.status = http_bad_request;
        return;
    };
    const pdf = jsonField(body, "pdf") orelse {
        res.status = http_bad_request;
        return;
    };
    const result = edit_mod.addComponentDatasheetCore(ctx.allocator, ctx.project_dir, component, pdf) catch |err| {
        res.status = http_internal_error;
        res.content_type = .JSON;
        res.body = try std.fmt.allocPrint(ctx.allocator, err_ok_false_template, .{@errorName(err)});
        return;
    };
    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(ctx.allocator, ok_version_template, .{result.version});
}

/// POST /api/component-datasheet/:component/remove — body `{pdf: "file.pdf"}`.
/// Counterpart to /add; unlinks a PDF from the library part.
pub fn removeComponentDatasheetApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const component_raw = req.param("component") orelse {
        res.status = http_not_found;
        return;
    };
    const component = try urlcodec.decodeAlloc(ctx.allocator, component_raw);
    const body = req.body() orelse {
        res.status = http_bad_request;
        return;
    };
    const pdf = jsonField(body, "pdf") orelse {
        res.status = http_bad_request;
        return;
    };
    const result = edit_mod.removeComponentDatasheetCore(ctx.allocator, ctx.project_dir, component, pdf) catch |err| {
        res.status = http_internal_error;
        res.content_type = .JSON;
        res.body = try std.fmt.allocPrint(ctx.allocator, err_ok_false_template, .{@errorName(err)});
        return;
    };
    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(ctx.allocator, ok_version_template, .{result.version});
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
