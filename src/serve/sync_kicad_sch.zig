//! `POST /api/sync-kicad-sch/:name` and the `sync_kicad_sch` CLI tool — the
//! network surfaces of the guarded schematic push (`kicad_sch_push.zig`).
//!
//! The board twin is `POST /api/sync-kicad-pcb/:name` in `sync.zig`, and this
//! mirrors its shape deliberately: `?dry_run=1` returns the would-be op list
//! without writing, a design that declares no `(kicad-pcb "<path>")` is a 400
//! naming the missing form, and a refusal — a hand-drawn sheet in the way, or
//! KiCad holding the project open — is a 409 carrying the reason.
//!
//! The one difference in spirit is what a refusal protects. The board sync
//! guards against MOVING an existing footprint; this guards against
//! OVERWRITING an existing drawing. Both answer 409 and write nothing.
//!
//! Every policy decision lives in `kicad_sch_push`; this module only resolves
//! the named design, merges its BOM identities (so the pushed symbols carry the
//! UUIDs the netlist and the board already carry), and renders the plan as
//! JSON.

const std = @import("std");
const httpz = @import("httpz");
const id_insert = @import("../id_insert.zig");
const log = @import("../infra/log.zig");
const paths = @import("../paths.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const bom = @import("../bom.zig");
const push = @import("../kicad_sch_push.zig");
const mcp_tools = @import("mcp_tools.zig");
const pcb_layout_page = @import("pcb_layout_page.zig");
const serve_root = @import("../serve.zig");
const Server = serve_root.Server;

/// Only allocation and the JSON writer's own failure escape the handler;
/// everything else becomes a status code with a body.
pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error;

const http_bad_request: u16 = 400;
const http_not_found: u16 = 404;
const http_conflict: u16 = 409;
const http_internal_error: u16 = 500;

const header_cors_allow_origin = "access-control-allow-origin";

const err_not_found = "No design by that name\n";
const err_no_pcb_path = "This design declares no (kicad-pcb \"<path>\") form, so there is no " ++
    "KiCad project directory to push the schematic into\n";
const err_no_directory = "The design's (kicad-pcb \"<path>\") is a bare filename with no " ++
    "directory, so there is nowhere to write the schematic\n";
const err_export = "KiCad schematic export failed\n";
const err_write = "Writing the schematic into the KiCad project directory failed\n";

/// Everything `runPush` can fail with: resolving/evaluating the design plus
/// every way the push itself can fail.
pub const PushApiError = mcp_tools.ToolError || push.PushError;

/// Resolve `name` as a design, merge its BOM identities, and run the push. The
/// evaluator owns the arena the block borrows, so it must outlive the run — the
/// plan's strings are copied onto `arena` before this returns.
pub fn runPush(
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    opts: push.Options,
) PushApiError!push.Result {
    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();
    const nb = try mcp_tools.evalNamedBlock(allocator, project_dir, name, &eval);

    // A push WRITES `(uuid …)` into sheets in the user's KiCad project, so it
    // pins the ids those uuids come from first — the same thing the CLI twin
    // (`commands.cmdSyncKicadSch` via `evalForExport`) does, so the two
    // surfaces cannot disagree about a part's identity. The read-only
    // `GET /api/kicad-sch` export deliberately does NOT do this: a GET must not
    // mutate, and after any one build/save/push the ids are already in source.
    if (paths.designSourcePath(allocator, project_dir, name)) |source_path| {
        defer allocator.free(source_path);
        _ = id_insert.persistMintedIds(allocator, source_path, &eval);
    } else |_| {}

    // A bare module never declares a board, so the identity merge only ever
    // applies to a real design — exactly as on the export path.
    if (!nb.is_module) {
        if (paths.designSiblingPath(allocator, project_dir, name, ".bom")) |bom_path| {
            defer allocator.free(bom_path);
            bom.resolveIdentities(allocator, nb.block, bom_path, project_dir) catch |e| {
                log.warn("sync-kicad-sch resolveIdentities {s} failed: {s}", .{ name, @errorName(e) });
            };
        } else |_| {}
    }
    return push.run(allocator, arena, nb.block, project_dir, opts);
}

// ── JSON ─────────────────────────────────────────────────────────────

/// Render a finished push as the response body. Same envelope on a dry run, a
/// real write, and a refusal — a client reads `ok` / `written` / `refusal`
/// rather than three different shapes.
pub fn writeResultJson(
    w: *std.Io.Writer,
    name: []const u8,
    result: push.Result,
    dry_run: bool,
) std.Io.Writer.Error!void {
    const plan = result.plan;
    try w.writeAll("{\"ok\":");
    try w.writeAll(if (plan.refusal == null) "true" else "false");
    try w.writeAll(",\"name\":");
    try pcb_layout_page.writeJsonStr(w, name);
    try w.writeAll(",\"dir\":");
    try pcb_layout_page.writeJsonStr(w, plan.target.dir);
    try w.writeAll(",\"project\":");
    try pcb_layout_page.writeJsonStr(w, plan.target.project);
    try w.writeAll(",\"root\":");
    try pcb_layout_page.writeJsonStr(w, plan.root);
    try w.print(",\"dry_run\":{s},\"written\":{s}", .{
        if (dry_run) "true" else "false",
        if (result.written) "true" else "false",
    });
    try writeSummary(w, plan);
    if (plan.refusal) |why| {
        try w.writeAll(",\"refusal\":");
        try pcb_layout_page.writeJsonStr(w, why);
    }
    try w.writeAll(",\"files\":");
    try writeOps(w, plan.ops);
    try w.writeByte('}');
}

fn writeSummary(w: *std.Io.Writer, plan: push.Plan) std.Io.Writer.Error!void {
    try w.print(
        ",\"summary\":{{\"create\":{d},\"overwrite\":{d},\"keep\":{d}," ++
            "\"advise\":{d},\"skip\":{d},\"refuse\":{d}}}",
        .{
            plan.count(.create),
            plan.count(.overwrite),
            plan.count(.keep),
            plan.count(.advise),
            plan.count(.skip),
            plan.count(.refuse),
        },
    );
}

fn writeOps(w: *std.Io.Writer, ops: []const push.FileOp) std.Io.Writer.Error!void {
    try w.writeByte('[');
    for (ops, 0..) |op, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll("{\"name\":");
        try pcb_layout_page.writeJsonStr(w, op.name);
        try w.writeAll(",\"action\":");
        try pcb_layout_page.writeJsonStr(w, op.action.label());
        try w.print(",\"bytes\":{d},\"note\":", .{op.bytes});
        try pcb_layout_page.writeJsonStr(w, op.note);
        try w.writeByte('}');
    }
    try w.writeByte(']');
}

// ── HTTP ─────────────────────────────────────────────────────────────

/// POST /api/sync-kicad-sch/:name[?dry_run=1][?force=1] — export the design's
/// schematic under its KiCad project's name and write it into the directory the
/// design's `(kicad-pcb …)` names.
///
/// 200 with the op list on success or on a dry run; 400 when the design
/// declares no board; 404 for an unknown name; 409 when a hand-drawn sheet or a
/// KiCad lock refuses the push (nothing written); 500 on an export or write
/// failure.
pub fn syncKicadSchApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name_raw = req.param("name") orelse {
        res.status = http_not_found;
        res.body = err_not_found;
        return;
    };
    const name = try urlDecodeAlloc(res.arena, name_raw);
    const dry_run = queryFlag(req, "dry_run");
    const opts = push.Options{ .dry_run = dry_run, .force = queryFlag(req, "force") };

    const result = runPush(ctx.allocator, res.arena, ctx.project_dir, name, opts) catch |e| {
        setFailure(res, name, e);
        return;
    };

    var aw: std.Io.Writer.Allocating = .init(res.arena);
    try writeResultJson(&aw.writer, name, result, dry_run);
    // A refusal is a 409 with the SAME body as a success — the client's toast
    // and the op list both come from it, so there is nothing extra to parse.
    res.status = if (result.plan.refusal == null) 200 else http_conflict;
    res.content_type = .JSON;
    res.header(header_cors_allow_origin, "*");
    res.body = aw.written();
}

/// Map a failed push onto a status + plain-text body. Kept out of the handler
/// so the happy path reads as one straight line.
fn setFailure(res: *httpz.Response, name: []const u8, e: PushApiError) void {
    switch (e) {
        error.PcbPathUnset => setError(res, http_bad_request, err_no_pcb_path),
        error.PcbPathNotInDirectory => setError(res, http_bad_request, err_no_directory),
        error.FileNotFound, error.NotADesign, error.InvalidName => setError(res, http_not_found, err_not_found),
        error.PushWriteFailed => setError(res, http_internal_error, err_write),
        else => {
            log.warn("sync-kicad-sch {s} failed: {s}", .{ name, @errorName(e) });
            setError(res, http_internal_error, err_export);
        },
    }
}

fn setError(res: *httpz.Response, status: u16, body: []const u8) void {
    res.status = status;
    res.body = body;
}

/// True when the named query param is set to "1" or "true", matching the board
/// sync's `?dry_run=1` / `?prune=1` spelling.
fn queryFlag(req: *httpz.Request, key: []const u8) bool {
    const q = req.query() catch return false;
    const v = q.get(key) orelse return false;
    return std.mem.eql(u8, v, "1") or std.mem.eql(u8, v, "true");
}

/// Percent-decode a path param. httpz hands `:params` over verbatim, so every
/// filesystem-facing use decodes first.
fn urlDecodeAlloc(allocator: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error![]u8 {
    const buf = try allocator.dupe(u8, raw);
    return std.Uri.percentDecodeInPlace(buf);
}

// ── CLI ──────────────────────────────────────────────────────────────

/// `sync_kicad_sch` — the agent-facing twin. Same JSON as the endpoint, and the
/// same refusal semantics: a refused push returns `ok:false` with the reason
/// rather than an error, because the caller's next move is to read the reason,
/// not to retry.
pub fn mcpSyncKicadSch(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) PushApiError!bool {
    const name = argStr(args_val, "name") orelse {
        try out.appendSlice(alloc, "missing required arg: name");
        return false;
    };
    const dry_run = argBool(args_val, "dry_run") orelse false;
    const opts = push.Options{ .dry_run = dry_run, .force = argBool(args_val, "force") orelse false };

    const result = runPush(alloc, alloc, project_dir, name, opts) catch |e| {
        const msg = try std.fmt.allocPrint(alloc, "error: {s}", .{explain(e)});
        defer alloc.free(msg);
        try out.appendSlice(alloc, msg);
        return false;
    };

    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    try writeResultJson(&aw.writer, name, result, dry_run);
    try out.appendSlice(alloc, aw.written());
    // A refusal is reported as a normal result carrying `ok:false`; only a
    // failure to get that far is a tool error.
    return true;
}

/// One sentence per failure mode, so an agent learns the rule instead of an
/// error name.
fn explain(e: PushApiError) []const u8 {
    return switch (e) {
        error.PcbPathUnset => "this design declares no (kicad-pcb \"<path>\") form, " ++
            "so there is no KiCad project directory to push the schematic into",
        error.PcbPathNotInDirectory => "the design's (kicad-pcb \"<path>\") is a bare filename " ++
            "with no directory, so there is nowhere to write the schematic",
        error.FileNotFound, error.NotADesign, error.InvalidName => "no design by that name",
        error.PushWriteFailed => "writing into the KiCad project directory failed",
        else => "the schematic export failed",
    };
}

fn argStr(args_val: ?std.json.Value, key: []const u8) ?[]const u8 {
    const av = args_val orelse return null;
    if (av != .object) return null;
    const v = av.object.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn argBool(args_val: ?std.json.Value, key: []const u8) ?bool {
    const av = args_val orelse return null;
    if (av != .object) return null;
    const v = av.object.get(key) orelse return null;
    return if (v == .bool) v.bool else null;
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

/// The same three-part fixture the export endpoint uses, plus the
/// `(kicad-pcb …)` declaration that makes it pushable. Every instance carries
/// an explicit `(id …)`: an un-stamped design mints a random id per evaluation,
/// which becomes the symbol UUID, so the export would not be comparable.
fn writePushFixture(dir: std.Io.Dir, file: []const u8, board_path: []const u8) !void {
    try dir.createDirPath(std.testing.io, "lib/components");
    try dir.createDirPath(std.testing.io, "src");
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/sch-ic.sexp", .data =
        \\(component "sch-ic"
        \\  (description "minimal test regulator"))
    });
    try dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/sch-cap.sexp", .data =
        \\(component-family "sch-cap"
        \\  (description "minimal test cap")
        \\  (parameter "value" capacitance))
    });
    var buf: [4096]u8 = undefined;
    const src = try std.fmt.bufPrint(&buf,
        \\(import sch-ic)
        \\(import sch-cap)
        \\
        \\(design-block "Sch Push Board"
        \\  (kicad-pcb "{s}")
        \\  (section "Core Rail" "sch-ic 5V-to-3.3V test rail"
        \\    (row 0) (col 0)
        \\    (instance "U1" sch-ic
        \\      (id "aa000001")
        \\      (pin 1 "VIN")
        \\      (pin 2 "VOUT")
        \\      (pin 3 "GND"))
        \\    (instance "C1" (sch-cap "1uF")
        \\      (id "aa000002")
        \\      (pin 1 "VIN")
        \\      (pin 2 "GND"))))
    , .{board_path});
    var name_buf: [128]u8 = undefined;
    const sub_path = try std.fmt.bufPrint(&name_buf, "src/{s}.sexp", .{file});
    try dir.writeFile(std.testing.io, .{ .sub_path = sub_path, .data = src });
}

const Served = struct { status: u16, body: []const u8 };

/// Drive the real handler and copy the status + body out.
fn serve(
    alloc: std.mem.Allocator,
    project: []const u8,
    name: []const u8,
    query: ?[2][]const u8,
) !Served {
    var state = serve_root.ServerState{};
    var srv = Server{ .allocator = alloc, .project_dir = project, .auth_dir = project, .state = &state };
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.param("name", name);
    if (query) |q| ht.query(q[0], q[1]);
    try syncKicadSchApi(&srv, ht.req, ht.res);
    return .{ .status = ht.res.status, .body = try alloc.dupe(u8, ht.res.body) };
}

// spec: Web Server - POST /api/sync-kicad-sch/:name?dry_run=1 reports the per-file plan and writes nothing, and the same call without it writes the sheets into the board's directory
test "the sync-kicad-sch endpoint dry-runs before it writes" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "kicad");
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    const board = try std.fmt.allocPrint(alloc, "{s}/kicad/Widget.kicad_pcb", .{root});
    try writePushFixture(tmp.dir, "pushdemo", board);

    const dry = try serve(alloc, root, "pushdemo", [2][]const u8{ "dry_run", "1" });
    try testing.expectEqual(@as(u16, 200), dry.status);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, dry.body, .{});
    defer parsed.deinit();
    const o = parsed.value.object;
    try testing.expectEqual(true, o.get("ok").?.bool);
    try testing.expectEqual(false, o.get("written").?.bool);
    // The root sheet is named after the KiCad PROJECT, not the design.
    try testing.expectEqualStrings("Widget.kicad_sch", o.get("root").?.string);
    try testing.expectEqualStrings("Widget", o.get("project").?.string);
    // …and the dry run left the directory empty.
    try testing.expectError(error.FileNotFound, tmp.dir.readFileAlloc(std.testing.io, "kicad/Widget.kicad_sch", alloc, .limited64(64)));

    const wrote = try serve(alloc, root, "pushdemo", null);
    try testing.expectEqual(@as(u16, 200), wrote.status);
    try testing.expect(std.mem.indexOf(u8, wrote.body, "\"written\":true") != null);
    const sheet = try tmp.dir.readFileAlloc(std.testing.io, "kicad/Widget.kicad_sch", alloc, .limited64(1 << 20));
    try testing.expect(std.mem.indexOf(u8, sheet, "(generator \"netlisp\")") != null);
    // The sidecars land beside it under the project's name.
    _ = try tmp.dir.readFileAlloc(std.testing.io, "kicad/Widget.kicad_pro", alloc, .limited64(1 << 16));
    _ = try tmp.dir.readFileAlloc(std.testing.io, "kicad/netlisp.kicad_sym", alloc, .limited64(1 << 20));
}

// spec: Web Server - POST /api/sync-kicad-sch/:name answers 409 and writes nothing when an existing schematic is not netlisp's, and 404 for an unknown name
test "the sync-kicad-sch endpoint's refusal, missing-board and unknown-name statuses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "kicad");
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    const board = try std.fmt.allocPrint(alloc, "{s}/kicad/Widget.kicad_pcb", .{root});
    try writePushFixture(tmp.dir, "pushdemo", board);

    // A hand-drawn schematic already in the target directory.
    const drawn = "(kicad_sch (version 20250114) (generator \"eeschema\")\n" ++
        "  (symbol (lib_id \"Device:R\") (at 100 100 0) (uuid \"abc\"))\n)";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "kicad/Widget.kicad_sch", .data = drawn });

    const refused = try serve(alloc, root, "pushdemo", null);
    try testing.expectEqual(@as(u16, 409), refused.status);
    try testing.expect(std.mem.indexOf(u8, refused.body, "\"ok\":false") != null);
    try testing.expect(std.mem.indexOf(u8, refused.body, "refusal") != null);
    // Nothing was written: the user's drawing is byte-identical.
    try testing.expectEqualStrings(drawn, try tmp.dir.readFileAlloc(std.testing.io, "kicad/Widget.kicad_sch", alloc, .limited64(4096)));

    // …and force is the documented override.
    const forced = try serve(alloc, root, "pushdemo", [2][]const u8{ "force", "1" });
    try testing.expectEqual(@as(u16, 200), forced.status);

    const unknown = try serve(alloc, root, "no-such-board", null);
    try testing.expectEqual(@as(u16, 404), unknown.status);
}

// spec: Web Server - POST /api/sync-kicad-sch/:name answers 400 naming the missing (kicad-pcb ...) form for a design that declares no board
test "the sync-kicad-sch endpoint names the missing kicad-pcb form" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "lib/components");
    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/components/sch-ic.sexp", .data =
        \\(component "sch-ic" (description "minimal test regulator"))
    });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/noboard.sexp", .data =
        \\(import sch-ic)
        \\(design-block "No Board"
        \\  (instance "U1" sch-ic (id "aa000001") (pin 1 "VIN") (pin 2 "GND")))
    });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    const got = try serve(alloc, root, "noboard", null);
    try testing.expectEqual(@as(u16, 400), got.status);
    try testing.expect(std.mem.indexOf(u8, got.body, "(kicad-pcb") != null);
}

// spec: Web Server - The sync_kicad_sch CLI tool is registered as a mutation and rejects a call with no name
test "sync_kicad_sch is a registered mutation tool that requires a name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    try testing.expect(mcp_tools.isKnownTool("sync_kicad_sch"));
    try testing.expect(mcp_tools.isMutationTool("sync_kicad_sch"));

    var out: std.ArrayList(u8) = .empty;
    const ok = try mcpSyncKicadSch(alloc, ".", null, &out);
    try testing.expectEqual(false, ok);
    try testing.expect(std.mem.indexOf(u8, out.items, "missing required arg: name") != null);
}

// spec: Web Server - The sync_kicad_sch CLI tool reports a refusal as an ok:false result carrying the reason, rather than as a tool error
test "sync_kicad_sch reports a refusal as a result, not an error" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();

    var tmp = testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "kicad");
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    const board = try std.fmt.allocPrint(alloc, "{s}/kicad/Widget.kicad_pcb", .{root});
    try writePushFixture(tmp.dir, "pushdemo", board);
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "kicad/~Widget.kicad_pcb.lck",
        .data = "{\"hostname\":\"kicad-box\",\"username\":\"eugene\"}",
    });

    var args: std.json.ObjectMap = .empty;
    try args.put(alloc, "name", .{ .string = "pushdemo" });
    var out: std.ArrayList(u8) = .empty;
    const ok = try mcpSyncKicadSch(alloc, root, .{ .object = args }, &out);
    try testing.expectEqual(true, ok);
    try testing.expect(std.mem.indexOf(u8, out.items, "\"ok\":false") != null);
    try testing.expect(std.mem.indexOf(u8, out.items, "eugene@kicad-box") != null);
    // The lock blocked the write, so the sheet never appeared.
    try testing.expectError(error.FileNotFound, tmp.dir.readFileAlloc(std.testing.io, "kicad/Widget.kicad_sch", alloc, .limited64(64)));
}
