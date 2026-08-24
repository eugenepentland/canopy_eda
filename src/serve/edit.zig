//! Design-file mutation for the server: snapshot → write → re-evaluate → bump
//! the live version. Backs the CLI `build` tool (`rebuildDesign` →
//! `BuildReport`), the value/edit HTTP routes (`writeAndRebuild` and the
//! granular edits), BOM resolution, and version restore — the write half of
//! the schematic viewer, paired with the read-only handlers in `mcp_tools`.
const std = @import("std");
const httpz = @import("httpz");
const infra_fs = @import("../infra/fs.zig");
const log = @import("../infra/log.zig");
const paths = @import("../paths.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const render_json = @import("../render_json.zig");
const bom = @import("../bom.zig");
const bom_resolve = @import("../bom_resolve.zig");
const env_mod = @import("../eval/env.zig");
const serve_root = @import("../serve.zig");
const Server = serve_root.Server;
const bom_html = @import("bom_html.zig");
const pcb_part_json = @import("pcb_part_json.zig");
const history = @import("history.zig");
const id_insert = @import("../id_insert.zig");
const sexpr_parser = @import("../sexpr/parser.zig");
const datasheet_attach = @import("datasheet_attach.zig");
const rebuild_design = @import("rebuild_design.zig");
const modules_mod = @import("modules.zig");
const SexprNode = @import("../sexpr/ast.zig").Node;

// ── Constants ─────────────────────────────────────────────────────
const http_not_found: u16 = 404;
const http_bad_request: u16 = 400;
const http_internal_error: u16 = 500;
const max_source_bytes: usize = 10 * 1024 * 1024;

// JSON key prefixes (length-encoded so we don't need bare integer offsets)
const json_ref_key = "\"ref\":\"";
const json_value_key = "\"value\":\"";
const json_component_key = "\"component\":\"";
const json_old_component_key = "\"oldComponent\":\"";
const json_src_off_key = "\"srcOff\":";
const json_pins_key = "\"pins\"";

// Repeated string templates / fragments
const component_path_template = "{s}/lib/components/{s}.sexp";
const instance_open_template = "(instance \"{s}\"";
const section_open_template = "(section \"{s}\"";
const import_open = "(import ";

const header_cors_allow_origin = "access-control-allow-origin";
const err_cannot_read_file = "cannot read file";
const err_cannot_write_file = "cannot write file";
const err_rebuild_failed = "rebuild failed";
const err_instance_not_found = "instance not found";
const err_malformed_instance = "malformed instance form";
const err_generated_part = "this part is generated (decouple/series) or defined in a module — edit its source form directly";
const err_no_editable_value = "this part has a fixed component with no editable value";
const err_missing_ref = "missing ref";

const err_json_no_body = "{\"error\":\"no body\"}";
const err_json_missing_name = "{\"error\":\"missing name\"}";
const ok_json_true = "{\"ok\":true}";
/// `std.fmt` template for a `{"error":"<msg>"}` JSON body (msg substituted).
const err_json_fmt = "{{\"error\":\"{s}\"}}";

/// Adapts an allocating writer's generic `WriteFailed` back to the historical
/// allocator-only contract. Growing this writer is its only failure mode.
const AllocatingWriter = struct {
    writer: *std.Io.Writer,

    fn writeAll(self: AllocatingWriter, bytes: []const u8) std.mem.Allocator.Error!void {
        self.writer.writeAll(bytes) catch return error.OutOfMemory;
    }

    fn writeByte(self: AllocatingWriter, byte: u8) std.mem.Allocator.Error!void {
        self.writer.writeByte(byte) catch return error.OutOfMemory;
    }

    fn print(self: AllocatingWriter, comptime format: []const u8, args: anytype) std.mem.Allocator.Error!void {
        self.writer.print(format, args) catch return error.OutOfMemory;
    }
};

/// Error set for HTTP handlers in this module. Wide enough to cover
/// every subsystem error that may bubble through `try`: allocator, writer,
/// file IO, BOM resolve, sexpr parser, and httpz form/query parsing.
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
        InvalidEscapeSequence,
        NotOpenForReading,
        ConnectionTimedOut,
        Canceled,
        ReadOnlyFileSystem,
        LinkQuotaExceeded,
        RebuildFailed,
    };

fn warnResolveIdentities(name: []const u8, err: anyerror) void {
    log.warn("resolveIdentities {s} failed: {s}", .{ name, @errorName(err) });
}

/// POST /api/edit-value/:name — patch a single instance's value string in
/// the source `.sexp` (e.g. C3 → `0.5pF`), re-evaluate the design, and
/// bump the live version so the schematic viewer redraws on its next poll.
pub fn editValueApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const body = req.body() orelse {
        sendJsonError(ctx, res, 400, "no body");
        return;
    };

    // Parse JSON: {"ref": "C3", "value": "0.5pF", "srcOff": 1234}
    const ref_des = parseJsonString(body, "\"ref\"") orelse {
        sendJsonError(ctx, res, 400, err_missing_ref);
        return;
    };
    const new_value = parseJsonString(body, "\"value\"") orelse {
        sendJsonError(ctx, res, 400, "missing value");
        return;
    };
    const src_off = parseSrcOff(body);

    // Read the .sexp file
    const file_path = paths.designSourcePath(ctx.allocator, ctx.project_dir, name) catch {
        sendJsonError(ctx, res, 500, err_cannot_read_file);
        return;
    };
    defer ctx.allocator.free(file_path);

    const source = infra_fs.cwd().readFileAlloc(ctx.allocator, file_path, max_source_bytes) catch {
        sendJsonError(ctx, res, 500, err_cannot_read_file);
        return;
    };
    defer ctx.allocator.free(source);

    // Locate the enclosing instance form (offset-first → label-robust).
    const inst_open = findInstanceOpen(source, ref_des, src_off) orelse {
        sendJsonError(ctx, res, 404, if (src_off > 0) err_generated_part else err_instance_not_found);
        return;
    };
    const inst_end = findFormEnd(source, inst_open) orelse {
        sendJsonError(ctx, res, 400, err_malformed_instance);
        return;
    };

    // Patch the value. Three cases for the component slot inside the instance:
    //  • a family form `(cap-0402 "100nF")` — replace the quoted value in place;
    //  • a *bare* family atom `cap-0402` (what the Add wizard writes when a family
    //    part is added with no value) — wrap it into `(cap-0402 "<value>")` so the
    //    value becomes editable instead of permanently stuck;
    //  • a genuinely fixed component (e.g. `204928-0601`) — nothing to edit.
    var new_source: std.Io.Writer.Allocating = .init(ctx.allocator);
    const nw = &new_source.writer;
    if (findInstanceValueRange(source, inst_open, inst_end)) |vr| {
        try nw.writeAll(source[0..vr[0]]);
        try nw.writeAll(new_value);
        try nw.writeAll(source[vr[1]..]);
    } else if (findBareComponentRange(source, inst_open, inst_end)) |br| {
        const atom = source[br[0]..br[1]];
        if (!componentIsFamily(ctx.allocator, ctx.project_dir, atom)) {
            sendJsonError(ctx, res, 400, err_no_editable_value);
            return;
        }
        try nw.writeAll(source[0..br[0]]);
        try nw.print("({s} \"{s}\")", .{ atom, new_value });
        try nw.writeAll(source[br[1]..]);
    } else {
        sendJsonError(ctx, res, 400, err_no_editable_value);
        return;
    }

    infra_fs.cwd().writeFile(.{ .sub_path = file_path, .data = new_source.written() }) catch {
        sendJsonError(ctx, res, 500, err_cannot_write_file);
        return;
    };

    rebuildAndPush(ctx, name, res) catch {
        sendJsonError(ctx, res, 500, err_rebuild_failed);
        return;
    };
}

/// Locate the editable value string inside an instance form — the first quoted
/// string of the component family form, e.g. the `100nF` in
/// `(instance "C1" (cap-0402 "100nF") …)`. Returns `{start, end}` (exclusive of
/// the quotes), or null when the part carries a bare/fixed component (nothing to
/// edit) or the form is malformed.
fn findInstanceValueRange(source: []const u8, inst_open: usize, inst_end: usize) ?[2]usize {
    var pos = inst_open + instance_head.len;
    while (pos < inst_end and isPinWs(source[pos])) : (pos += 1) {}
    if (pos >= inst_end or source[pos] != '"') return null;
    pos = (std.mem.indexOfScalarPos(u8, source, pos + 1, '"') orelse inst_end) + 1; // past label
    while (pos < inst_end and isPinWs(source[pos])) : (pos += 1) {}
    if (pos >= inst_end or source[pos] != '(') return null; // fixed component
    const comp_end = findFormEnd(source, pos) orelse inst_end;
    const vq = std.mem.indexOfScalarPos(u8, source, pos + 1, '"') orelse return null;
    if (vq >= comp_end) return null;
    const vs = vq + 1;
    const ve = std.mem.indexOfScalarPos(u8, source, vs, '"') orelse return null;
    return .{ vs, ve };
}

/// Locate the *bare* component atom inside an instance form — the
/// unparenthesized component token right after the label, e.g. the `cap-0402`
/// in `(instance "cap-0402" cap-0402 …)`. Returns `{start, end}` of the atom,
/// or null when the component is a family form `(… "value")` (use
/// findInstanceValueRange) or the form is malformed. Pairs with
/// findInstanceValueRange to cover both spellings of the component slot.
fn findBareComponentRange(source: []const u8, inst_open: usize, inst_end: usize) ?[2]usize {
    var pos = inst_open + instance_head.len;
    while (pos < inst_end and isPinWs(source[pos])) : (pos += 1) {}
    if (pos >= inst_end or source[pos] != '"') return null;
    pos = (std.mem.indexOfScalarPos(u8, source, pos + 1, '"') orelse inst_end) + 1; // past label
    while (pos < inst_end and isPinWs(source[pos])) : (pos += 1) {}
    if (pos >= inst_end or source[pos] == '(') return null; // family form, not a bare atom
    const start = pos;
    while (pos < inst_end and !isPinTokenEnd(source[pos])) : (pos += 1) {}
    if (pos == start) return null;
    return .{ start, pos };
}

/// True when `lib/components/<name>.sexp` declares a `(component-family …)`, so a
/// bare instance of it can be wrapped into `(<name> "<value>")` and given an
/// editable value. False for a fixed `(component …)`, an unsafe name, or a
/// missing/unreadable file (in which case the caller leaves the part uneditable).
fn componentIsFamily(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8) bool {
    if (!safeLibName(name)) return false;
    const path = libComponentPath(allocator, project_dir, name) catch return false;
    defer allocator.free(path);
    const content = infra_fs.cwd().readFileAlloc(allocator, path, max_source_bytes) catch return false;
    defer allocator.free(content);
    return std.mem.indexOf(u8, content, "(component-family ") != null;
}

/// POST /api/edit-footprint/:name — swap an instance's component family
/// (e.g. `cap-0805` → `cap-0603`) using a source-offset checksum to
/// detect concurrent edits, ensure the new family is in `(import …)`,
/// rebuild, and return the refreshed components JSON.
/// True when `c` separates S-expression tokens (whitespace, parens, quote) —
/// used to confirm a substring match is a whole token, not a fragment.
fn isFootprintTokenBoundary(c: u8) bool {
    return std.mem.indexOfScalar(u8, " \t\n\r()\"", c) != null;
}

/// Locate the byte offset of `component` as a standalone token inside the
/// `(instance "ref" …)` form. editFootprintApi's fallback for when the caller's
/// `srcOff` points at the instance form (the scene-graph `components[].src`
/// offset) rather than at the component token itself. Returns null when the
/// instance or a whole-token match isn't found.
fn findComponentTokenInInstance(source: []const u8, ref: []const u8, component: []const u8) ?usize {
    if (ref.len == 0 or component.len == 0) return null;
    var buf: [256]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, instance_open_template, .{ref}) catch return null;
    const inst_start = std.mem.indexOf(u8, source, needle) orelse return null;
    const inst_end = findFormEnd(source, inst_start) orelse source.len;
    var from = inst_start + needle.len;
    while (std.mem.indexOfPos(u8, source[0..inst_end], from, component)) |pos| {
        const before_ok = pos == 0 or isFootprintTokenBoundary(source[pos - 1]);
        const after_pos = pos + component.len;
        const after_ok = after_pos >= inst_end or isFootprintTokenBoundary(source[after_pos]);
        if (before_ok and after_ok) return pos;
        from = pos + 1;
    }
    return null;
}

/// POST /api/edit-footprint/:name — swap an instance's component/footprint
/// family. Body `{"ref","component","oldComponent","srcOff"}`: replaces the
/// `oldComponent` token (located at `srcOff`, or via `ref` when srcOff points
/// at the instance form), ensures the new family is imported, rebuilds, and
/// returns the refreshed `components` map.
pub fn editFootprintApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
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
    const comp_start_marker = std.mem.indexOf(u8, body, json_component_key) orelse {
        res.status = 400;
        res.body = "missing component";
        return;
    };
    const comp_start = comp_start_marker + json_component_key.len;
    const comp_end = std.mem.indexOfPos(u8, body, comp_start, "\"") orelse {
        res.status = 400;
        return;
    };
    const new_component = body[comp_start..comp_end];

    const old_comp_marker = std.mem.indexOf(u8, body, json_old_component_key) orelse {
        res.status = 400;
        res.body = "missing oldComponent";
        return;
    };
    const old_comp_start = old_comp_marker + json_old_component_key.len;
    const old_comp_end = std.mem.indexOfPos(u8, body, old_comp_start, "\"") orelse {
        res.status = 400;
        return;
    };
    const old_component = body[old_comp_start..old_comp_end];

    const src_off_marker = std.mem.indexOf(u8, body, json_src_off_key) orelse {
        res.status = 400;
        res.body = "missing srcOff";
        return;
    };
    const src_off_num_start = src_off_marker + json_src_off_key.len;
    var src_off_num_end = src_off_num_start;
    while (src_off_num_end < body.len and body[src_off_num_end] >= '0' and body[src_off_num_end] <= '9') : (src_off_num_end += 1) {}
    const source_offset = std.fmt.parseInt(usize, body[src_off_num_start..src_off_num_end], 10) catch {
        res.status = 400;
        res.body = "invalid srcOff";
        return;
    };

    // Optional `ref` lets us recover when srcOff points at the instance form
    // (the scene-graph offset) instead of at the component token.
    const ref_des = parseJsonString(body, "\"ref\"") orelse "";
    // PCB pages can display passives flattened out of a module. Keep the route
    // name as the open parent design (so its live version gets rebuilt/bumped),
    // while editing the module file that actually owns the selected instance.
    const source_name = parseJsonString(body, "\"sourceName\"") orelse name;

    // Verify the new component family exists
    const comp_path = std.fmt.allocPrint(ctx.allocator, component_path_template, .{ ctx.project_dir, new_component }) catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(comp_path);
    infra_fs.cwd().access(comp_path, .{}) catch {
        res.status = 400;
        res.body = "component family not found";
        return;
    };

    // Read the .sexp file
    const file_path = paths.designSourcePath(ctx.allocator, ctx.project_dir, source_name) catch {
        res.status = 400;
        res.body = "invalid source name";
        return;
    };
    defer ctx.allocator.free(file_path);

    const source = infra_fs.cwd().readFileAlloc(ctx.allocator, file_path, max_source_bytes) catch {
        res.status = 500;
        res.body = err_cannot_read_file;
        return;
    };
    defer ctx.allocator.free(source);

    // The component token must sit exactly at `source_offset`. When it doesn't
    // (e.g. srcOff is the instance-form offset the scene graph reports), fall
    // back to locating the token inside the `(instance "ref" …)` form.
    const direct_ok = source_offset + old_component.len <= source.len and
        std.mem.eql(u8, source[source_offset .. source_offset + old_component.len], old_component);
    const comp_offset = if (direct_ok)
        source_offset
    else
        findComponentTokenInInstance(source, ref_des, old_component) orelse {
            res.status = 400;
            res.body = "source offset mismatch — file may have changed";
            return;
        };

    var new_source: std.Io.Writer.Allocating = .init(ctx.allocator);
    const nw = &new_source.writer;
    try nw.writeAll(source[0..comp_offset]);
    try nw.writeAll(new_component);
    try nw.writeAll(source[comp_offset + old_component.len ..]);

    // Ensure new component is in the import statement
    var final_source = new_source.written();
    if (std.mem.indexOf(u8, final_source, import_open)) |import_start| {
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
        const found_in_import = blk: {
            var search_from: usize = 0;
            while (std.mem.indexOfPos(u8, import_section, search_from, new_component)) |ipos| {
                const before_ok = ipos == 0 or import_section[ipos - 1] == ' ' or import_section[ipos - 1] == '\n';
                const after_pos = ipos + new_component.len;
                const after_ok = after_pos >= import_section.len or
                    import_section[after_pos] == ' ' or
                    import_section[after_pos] == '\n' or
                    import_section[after_pos] == ')';
                if (before_ok and after_ok) break :blk true;
                search_from = ipos + 1;
            }
            break :blk false;
        };
        if (!found_in_import) {
            var new_final: std.Io.Writer.Allocating = .init(ctx.allocator);
            const nfw = &new_final.writer;
            try nfw.writeAll(final_source[0..import_end]);
            try nfw.writeAll(" ");
            try nfw.writeAll(new_component);
            try nfw.writeAll(final_source[import_end..]);
            final_source = new_final.written();
        }
    }

    const file = infra_fs.cwd().createFile(file_path, .{}) catch {
        res.status = 500;
        res.body = err_cannot_write_file;
        return;
    };
    defer file.close();
    file.writeAll(final_source) catch {
        res.status = 500;
        return;
    };

    std.debug.print("Edited footprint {s} {s} -> \"{s}\"\n", .{ name, old_component, new_component });

    // Rebuild and push live update
    const board_path = paths.designSourcePath(ctx.allocator, ctx.project_dir, name) catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(board_path);

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();
    const direct_block: ?*env_mod.DesignBlock = if (eval.evalFile(board_path)) |result|
        switch (result) {
            .design_block => |b| b,
            else => null,
        }
    else |_|
        null;
    // The new footprint was just written to `board_path`; pin whatever ids that
    // evaluation minted before the BOM resolve below turns them into uuids.
    // Only the direct-design branch owns `board_path`'s spans — a module block
    // resolved below evaluates a different file through its own evaluator.
    if (direct_block != null) _ = id_insert.persistMintedIds(ctx.allocator, board_path, &eval);
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        ctx.allocator.destroy(mr.eval);
    };
    const block = direct_block orelse blk: {
        module_res = modules_mod.resolveModuleBlock(ctx.allocator, ctx.project_dir, name);
        break :blk if (module_res) |mr| mr.block else {
            res.status = 500;
            res.body = err_rebuild_failed;
            return;
        };
    };

    const bom_path = paths.designSiblingPath(ctx.allocator, ctx.project_dir, name, ".bom") catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(bom_path);
    bom.resolveIdentities(ctx.allocator, block, bom_path, ctx.project_dir) catch |e| warnResolveIdentities(name, e);

    var svg_sym_cache = try bom_html.buildSymbolPinCache(ctx.allocator, ctx.project_dir);

    const new_layout = render_json.renderSceneGraph(ctx.allocator, block, ctx.project_dir) catch null;
    serve_root.setLiveLayoutJson(name, new_layout);
    const version = serve_root.bumpLiveVersion(name);

    // Return updated COMPONENTS plus PCB edit provenance so both schematic and
    // board clients can refresh source offsets without navigating away.
    var comp_json: std.Io.Writer.Allocating = .init(ctx.allocator);
    const cw = &comp_json.writer;
    try cw.print("{{\"ok\":true,\"version\":{d},\"components\":{{", .{version});
    _ = try bom_html.writeComponentsJson(cw, block, "", &svg_sym_cache, ctx.allocator, ctx.project_dir);
    try cw.writeAll("},\"part_edits\":");
    try cw.writeAll(pcb_part_json.buildEditSources(ctx.allocator, block, name));
    try cw.writeAll("}");

    res.header(header_cors_allow_origin, "*");
    res.content_type = .JSON;
    res.body = comp_json.written();
}

/// POST /api/add-instance/:name
/// Component body: {"section":"Power","component":"cap-0402","value":"100nF","pins":{"1":"VDD","2":"GND"}}
/// Module body:    {"kind":"module","component":"tpsm84338","name":"pwr","args":"(rfbt 220k) (rfbb 47k)"}
/// A module emits a top-level (sub-block "<name>" (<module> <args>)); the
/// section field is ignored for modules (sub-blocks are not evaluated in a section).
pub fn addInstanceApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const body = req.body() orelse {
        res.status = 400;
        res.body = "no body";
        return;
    };

    const component = parseJsonString(body, "\"component\"") orelse {
        res.status = 400;
        res.body = "missing component";
        return;
    };
    const value = parseJsonString(body, "\"value\"") orelse "";
    const section = parseJsonString(body, "\"section\"") orelse "";
    // Optional caller-chosen ref-des. When omitted we emit the component name
    // as a descriptive (non-standard) label, which the evaluator's post-build
    // auto-assignment renumbers to the right prefix (C1, R3, …). An instance
    // form requires a ref-des string first arg, so this must never be empty.
    const ref_arg = parseJsonString(body, "\"ref\"") orelse "";
    const label = if (ref_arg.len > 0) ref_arg else component;

    // `kind:"module"` emits a (sub-block "<name>" (<module> <args>)) instead of
    // an (instance …). Modules live at design-block top level (they are not
    // evaluated inside a (section …)), so the section field is ignored for them.
    // `args` is the already-formatted inside-parens text (named "(rfbt 220k)" or
    // positional "220k 47k"); empty for a fully-defaulted module.
    const kind = parseJsonString(body, "\"kind\"") orelse "component";
    const is_module = std.mem.eql(u8, kind, "module");
    const sub_name = blk: {
        const n = parseJsonString(body, "\"name\"") orelse "";
        break :blk if (n.len > 0) n else component;
    };
    const mod_args = parseJsonString(body, "\"args\"") orelse "";
    // When the part needs a top-level (import …) to resolve — every module, and
    // any non-family component (an IC) — the client sets "import":true and we
    // splice one in (idempotent) so the rebuilt design evaluates. Component
    // families (cap-0402, res-0805, …) auto-load, so the flag is omitted there.
    const want_import = std.mem.indexOf(u8, body, "\"import\":true") != null or
        std.mem.indexOf(u8, body, "\"import\": true") != null;

    // Read source file
    const file_path = try paths.designSourcePath(ctx.allocator, ctx.project_dir, name);
    defer ctx.allocator.free(file_path);

    const source = infra_fs.cwd().readFileAlloc(ctx.allocator, file_path, max_source_bytes) catch {
        res.status = 500;
        res.body = err_cannot_read_file;
        return;
    };
    defer ctx.allocator.free(source);

    // Parse pin assignments from body: "pins":{"1":"VDD","2":"GND"}
    var pin_str: std.Io.Writer.Allocating = .init(ctx.allocator);
    const pw = &pin_str.writer;
    if (std.mem.indexOf(u8, body, json_pins_key)) |pins_start| {
        // Find the opening brace
        var pos = pins_start + json_pins_key.len;
        while (pos < body.len and body[pos] != '{') : (pos += 1) {}
        if (pos < body.len) {
            pos += 1; // skip {
            while (pos < body.len and body[pos] != '}') {
                // Parse "pin_num":"net_name"
                while (pos < body.len and body[pos] != '"') : (pos += 1) {}
                if (pos >= body.len) break;
                pos += 1;
                const pin_start = pos;
                while (pos < body.len and body[pos] != '"') : (pos += 1) {}
                const pin_num = body[pin_start..pos];
                pos += 1; // skip closing "

                while (pos < body.len and body[pos] != '"') : (pos += 1) {}
                if (pos >= body.len) break;
                pos += 1;
                const net_start = pos;
                while (pos < body.len and body[pos] != '"') : (pos += 1) {}
                const net_name = body[net_start..pos];
                pos += 1;

                try pw.print("\n    (pin {s} \"{s}\")", .{ pin_num, net_name });

                while (pos < body.len and (body[pos] == ',' or body[pos] == ' ')) : (pos += 1) {}
            }
        }
    }

    // Build the form — a (sub-block …) for modules, otherwise an (instance …).
    var inst_form: std.Io.Writer.Allocating = .init(ctx.allocator);
    const iw = &inst_form.writer;
    if (is_module) {
        if (mod_args.len > 0) {
            try iw.print("  (sub-block \"{s}\" ({s} {s}))\n", .{ sub_name, component, mod_args });
        } else {
            try iw.print("  (sub-block \"{s}\" ({s}))\n", .{ sub_name, component });
        }
    } else {
        if (value.len > 0) {
            try iw.print("  (instance \"{s}\" ({s} \"{s}\")", .{ label, component, value });
        } else {
            try iw.print("  (instance \"{s}\" {s}", .{ label, component });
        }
        try iw.writeAll(pin_str.written());
        try iw.writeAll(")\n");
    }

    // Splice a top-level (import <component>) just before (design-block when the
    // part needs one and it isn't already imported. Everything below operates on
    // this augmented buffer.
    const eff_source: []const u8 = if (want_import and !hasImport(source, component)) blk: {
        const anchor = std.mem.indexOf(u8, source, "(design-block") orelse break :blk source;
        var aug: std.Io.Writer.Allocating = .init(ctx.allocator);
        const aw = &aug.writer;
        try aw.writeAll(source[0..anchor]);
        try aw.print("{s}{s})\n", .{ import_open, component });
        try aw.writeAll(source[anchor..]);
        break :blk aug.written();
    } else source;

    // Find insertion point: inside section if specified, otherwise before last closing paren
    var new_source: std.Io.Writer.Allocating = .init(ctx.allocator);
    const nw = &new_source.writer;

    if (!is_module and section.len > 0) {
        // Find (section "Name" ...) and insert before its closing paren
        const sec_needle = try std.fmt.allocPrint(ctx.allocator, section_open_template, .{section});
        defer ctx.allocator.free(sec_needle);

        if (std.mem.indexOf(u8, eff_source, sec_needle)) |sec_start| {
            // Find matching closing paren
            var depth: u32 = 0;
            var sec_end: usize = sec_start;
            for (eff_source[sec_start..], 0..) |ch, i| {
                if (ch == '(') depth += 1;
                if (ch == ')') {
                    depth -= 1;
                    if (depth == 0) {
                        sec_end = sec_start + i;
                        break;
                    }
                }
            }
            try nw.writeAll(eff_source[0..sec_end]);
            try nw.writeAll("\n");
            try nw.writeAll(inst_form.written());
            try nw.writeAll(eff_source[sec_end..]);
        } else {
            // Section not found, insert at end
            const last_paren = std.mem.lastIndexOfScalar(u8, eff_source, ')') orelse eff_source.len;
            try nw.writeAll(eff_source[0..last_paren]);
            try nw.writeAll("\n");
            try nw.writeAll(inst_form.written());
            try nw.writeAll(eff_source[last_paren..]);
        }
    } else {
        const last_paren = std.mem.lastIndexOfScalar(u8, eff_source, ')') orelse eff_source.len;
        try nw.writeAll(eff_source[0..last_paren]);
        try nw.writeAll("\n");
        try nw.writeAll(inst_form.written());
        try nw.writeAll(eff_source[last_paren..]);
    }

    // Write file
    const file = infra_fs.cwd().createFile(file_path, .{}) catch {
        res.status = 500;
        res.body = err_cannot_write_file;
        return;
    };
    defer file.close();
    file.writeAll(new_source.written()) catch {
        res.status = 500;
        return;
    };

    // Rebuild + push live update
    rebuildAndPush(ctx, name, res) catch {
        res.status = 500;
        res.body = err_rebuild_failed;
        return;
    };
}

/// POST /api/new-design  Body: {"name":"my-board","title":"My Board"}
/// Scaffold a fresh design file src/<name>.sexp = (design-block "<title>") so a
/// design can be started from the home page / editor instead of hand-writing the
/// stub. 409 if a design with that basename already exists; 400 on an unsafe name.
pub fn newDesignApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const body = req.body() orelse {
        res.status = 400;
        res.body = "no body";
        return;
    };
    const name = parseJsonString(body, "\"name\"") orelse {
        res.status = 400;
        res.body = "missing name";
        return;
    };
    // The name becomes a filesystem basename (src/<name>.sexp) and a URL path, so
    // restrict it to a safe charset — no traversal, no spaces, no quoting needed.
    if (name.len == 0 or name.len > 64) {
        res.status = 400;
        res.body = "name must be 1-64 characters";
        return;
    }
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_';
        if (!ok) {
            res.status = 400;
            res.body = "name may contain only letters, digits, '-' and '_'";
            return;
        }
    }
    // Title is embedded inside a quoted s-expr string; if it carries a char that
    // would need escaping, fall back to the (safe) name rather than risk bad source.
    const raw_title = parseJsonString(body, "\"title\"") orelse "";
    const title = blk: {
        if (raw_title.len == 0) break :blk name;
        if (std.mem.indexOfAny(u8, raw_title, "\"\\\n\r") != null) break :blk name;
        break :blk raw_title;
    };

    const file_path = try paths.designSourcePath(ctx.allocator, ctx.project_dir, name);
    defer ctx.allocator.free(file_path);

    // designSourcePath returns an existing match or the flat fallback; refuse only
    // when something is actually there (don't clobber a design or a same-named module).
    if (infra_fs.cwd().access(file_path, .{})) |_| {
        res.status = 409;
        res.body = "a design with that name already exists";
        return;
    } else |_| {}

    const content = try std.fmt.allocPrint(ctx.allocator, "(design-block \"{s}\")\n", .{title});
    defer ctx.allocator.free(content);
    infra_fs.cwd().writeFile(.{ .sub_path = file_path, .data = content }) catch {
        res.status = 500;
        res.body = err_cannot_write_file;
        return;
    };

    res.status = 200;
    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(ctx.allocator, "{{\"ok\":true,\"url\":\"/schematics/{s}\"}}", .{name});
}

// ── Structural authoring (sections, ports, ref-des, DNP) ───────────────────
// New surgical endpoints that let the editor build a conventional, organized
// design (not just a flat instance pile). They mirror the existing splice +
// findInstanceOpen/findFormEnd patterns and share the writeAndRebuild tail.

/// Write `s` as a quoted s-expr string with the two chars that need escaping.
fn writeSexprString(w: anytype, s: []const u8) std.mem.Allocator.Error!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

/// Byte index just before the `(design-block …)` closing paren — the splice
/// point for a new top-level form. Null when the source has no design-block.
fn designBlockInsertPos(source: []const u8) ?usize {
    const db = std.mem.indexOf(u8, source, "(design-block") orelse return null;
    const end = findFormEnd(source, db) orelse return null;
    return end - 1;
}

fn isEditableDesignRoot(node: SexprNode) bool {
    const children = node.asList() orelse return false;
    return node.isForm("design-block") or
        (node.isForm("block") and children.len >= 2 and children[1].asString() != null);
}

/// Find either a top-level editable design root or the direct design body of a
/// standalone `(defmodule …)`. The latter is what `/pcb-layout/<module-name>`
/// evaluates, so its source-level PCB settings must be editable from that page.
fn editableDesignRoot(nodes: []const SexprNode) ?SexprNode {
    for (nodes) |node| if (isEditableDesignRoot(node)) return node;
    for (nodes) |node| {
        if (!node.isForm("defmodule")) continue;
        const children = node.asList() orelse continue;
        if (children.len < 4) continue;
        for (children[3..]) |child| if (isEditableDesignRoot(child)) return child;
    }
    return null;
}

/// Replace every direct atom-valued `form_name` child of the editable design
/// root, or append one when it still relies on that form's default. AST offsets
/// keep similarly named text in comments and nested helper blocks out of the
/// edit while the byte splice preserves all unrelated source formatting.
fn patchRootAtomForm(
    allocator: std.mem.Allocator,
    source: []const u8,
    form_name: []const u8,
    replacement: []const u8,
) EditError![]u8 {
    const nodes = sexpr_parser.parse(allocator, source) catch return error.InvalidSource;
    defer sexpr_parser.freeNodes(allocator, nodes);

    const root = editableDesignRoot(nodes) orelse return error.MalformedSource;
    const children = root.asList() orelse return error.MalformedSource;
    if (children.len < 2) return error.MalformedSource;

    const root_open: usize = @intCast(root.span.offset);
    const root_end = findFormEnd(source, root_open) orelse return error.MalformedSource;
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = AllocatingWriter{ .writer = &out.writer };
    var cursor: usize = 0;
    var found = false;
    for (children[2..]) |child| {
        if (!child.isForm(form_name)) continue;
        const start: usize = @intCast(child.span.offset);
        const end = findFormEnd(source, start) orelse return error.MalformedSource;
        if (start < cursor or end > root_end) return error.MalformedSource;
        try w.writeAll(source[cursor..start]);
        try w.writeAll(replacement);
        cursor = end;
        found = true;
    }
    if (found) {
        try w.writeAll(source[cursor..]);
        return out.toOwnedSlice();
    }

    try w.writeAll(source[0 .. root_end - 1]);
    try w.writeAll("\n  ");
    try w.writeAll(replacement);
    try w.writeAll(source[root_end - 1 ..]);
    return out.toOwnedSlice();
}

fn patchBoardRoleSource(allocator: std.mem.Allocator, source: []const u8, role: env_mod.BoardRole) EditError![]u8 {
    return patchRootAtomForm(allocator, source, "board-role", switch (role) {
        .board => "(board-role board)",
        .subcircuit => "(board-role subcircuit)",
    });
}

fn patchPowerPlaneSource(allocator: std.mem.Allocator, source: []const u8, enabled: bool) EditError![]u8 {
    return patchRootAtomForm(allocator, source, "power-plane", if (enabled) "(power-plane on)" else "(power-plane off)");
}

const BoardRouteMeta = struct { role: env_mod.BoardRole = .subcircuit, power_plane: bool = true };

fn boardRouteMeta(allocator: std.mem.Allocator, source: []const u8) EditError!BoardRouteMeta {
    const nodes = sexpr_parser.parse(allocator, source) catch return error.InvalidSource;
    defer sexpr_parser.freeNodes(allocator, nodes);
    var meta = BoardRouteMeta{};
    const root = editableDesignRoot(nodes) orelse return error.MalformedSource;
    const children = root.asList() orelse return error.MalformedSource;
    for (children[2..]) |child| {
        const values = child.asList() orelse continue;
        if (values.len < 2) continue;
        const word = values[1].asAtom() orelse continue;
        if (child.isForm("board-role")) {
            if (std.mem.eql(u8, word, "board")) meta.role = .board else if (std.mem.eql(u8, word, "subcircuit")) meta.role = .subcircuit;
        } else if (child.isForm("power-plane")) {
            if (std.mem.eql(u8, word, "on")) meta.power_plane = true else if (std.mem.eql(u8, word, "off")) meta.power_plane = false;
        }
    }
    return meta;
}

/// GET /api/board-role/:name — role plus the source-level supply-plane choice
/// used to build the subcircuit autorouter control.
pub fn getBoardRoleApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse return sendJsonError(ctx, res, http_not_found, "missing design");
    const source = readDesignSource(ctx.allocator, ctx.project_dir, name) catch
        return sendJsonError(ctx, res, http_not_found, "cannot read design source");
    defer ctx.allocator.free(source);
    const meta = boardRouteMeta(ctx.allocator, source) catch
        return sendJsonError(ctx, res, http_bad_request, "source does not contain an editable design root");
    res.header(header_cors_allow_origin, "*");
    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(ctx.allocator, "{{\"role\":\"{s}\",\"power_plane\":{s},\"power_plane_applicable\":{s}}}", .{
        @tagName(meta.role), if (meta.power_plane) "true" else "false", if (meta.role == .subcircuit) "true" else "false",
    });
}

/// POST /api/board-role/:name  Body: {"role":"board|subcircuit"}.
/// Surgically updates the design-root role, snapshots, and rebuilds so every
/// role-aware GUI/API consumer observes the change immediately.
pub fn setBoardRoleApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse return sendJsonError(ctx, res, http_not_found, "missing design");
    const body = req.body() orelse return sendJsonError(ctx, res, http_bad_request, "missing body");
    const role_text = parseJsonString(body, "\"role\"") orelse
        return sendJsonError(ctx, res, http_bad_request, "missing role");
    const role: env_mod.BoardRole = if (std.mem.eql(u8, role_text, "board"))
        .board
    else if (std.mem.eql(u8, role_text, "subcircuit"))
        .subcircuit
    else
        return sendJsonError(ctx, res, http_bad_request, "role must be board or subcircuit");

    const source = readDesignSource(ctx.allocator, ctx.project_dir, name) catch
        return sendJsonError(ctx, res, http_not_found, "cannot read design source");
    defer ctx.allocator.free(source);
    const updated = patchBoardRoleSource(ctx.allocator, source, role) catch |err| {
        const message = switch (err) {
            error.InvalidSource => "design source has invalid s-expression syntax",
            error.MalformedSource => "source does not contain an editable design root",
            else => "could not update design role",
        };
        return sendJsonError(ctx, res, http_bad_request, message);
    };
    defer ctx.allocator.free(updated);

    const result = writeAndRebuild(ctx.allocator, ctx.project_dir, name, updated, "set board role from schematic") catch
        return sendJsonError(ctx, res, http_internal_error, "could not save and rebuild design role");
    res.header(header_cors_allow_origin, "*");
    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(ctx.allocator, "{{\"ok\":true,\"role\":\"{s}\",\"version\":{d}}}", .{
        @tagName(role), result.version,
    });
}

/// POST /api/power-plane/:name  Body: {"enabled":true|false}. Updates the
/// source-level plane policy, then rebuilds before the PCB page reloads.
pub fn setPowerPlaneApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse return sendJsonError(ctx, res, http_not_found, "missing design");
    const body = req.body() orelse return sendJsonError(ctx, res, http_bad_request, "missing body");
    const root = std.json.parseFromSliceLeaky(std.json.Value, req.arena, body, .{}) catch
        return sendJsonError(ctx, res, http_bad_request, "invalid JSON");
    if (root != .object) return sendJsonError(ctx, res, http_bad_request, "missing enabled");
    const enabled_v = root.object.get("enabled") orelse
        return sendJsonError(ctx, res, http_bad_request, "missing enabled");
    if (enabled_v != .bool) return sendJsonError(ctx, res, http_bad_request, "enabled must be boolean");

    const source = readDesignSource(ctx.allocator, ctx.project_dir, name) catch
        return sendJsonError(ctx, res, http_not_found, "cannot read design source");
    defer ctx.allocator.free(source);
    const meta = boardRouteMeta(ctx.allocator, source) catch
        return sendJsonError(ctx, res, http_bad_request, "source does not contain an editable design root");
    if (meta.role != .subcircuit)
        return sendJsonError(ctx, res, http_bad_request, "power-plane mode applies only to subcircuits");
    const updated = patchPowerPlaneSource(ctx.allocator, source, enabled_v.bool) catch |err| {
        const message = switch (err) {
            error.InvalidSource => "design source has invalid s-expression syntax",
            error.MalformedSource => "source does not contain an editable design root",
            else => "could not update power-plane setting",
        };
        return sendJsonError(ctx, res, http_bad_request, message);
    };
    defer ctx.allocator.free(updated);

    const result = writeAndRebuild(ctx.allocator, ctx.project_dir, name, updated, "set subcircuit power-plane mode") catch
        return sendJsonError(ctx, res, http_internal_error, "could not save and rebuild power-plane setting");
    res.header(header_cors_allow_origin, "*");
    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(ctx.allocator, "{{\"ok\":true,\"power_plane\":{s},\"version\":{d}}}", .{
        if (enabled_v.bool) "true" else "false", result.version,
    });
}

/// Emit `{"ok":true,"version":N}` (or rebuild-failure 500) for a finished mutation.
fn finishMutation(ctx: *Server, name: []const u8, new_source: []const u8, desc: []const u8, res: *httpz.Response) HandlerError!void {
    const result = writeAndRebuild(ctx.allocator, ctx.project_dir, name, new_source, desc) catch {
        res.status = 500;
        res.body = err_rebuild_failed;
        return;
    };
    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(ctx.allocator, "{{\"ok\":true,\"version\":{d}}}", .{result.version});
}

/// POST /api/add-section/:name  Body: {"section":"Power","subtitle":"3V3 buck"}
/// Splice an empty `(section "Name" "subtitle"?)` into the design-block.
pub fn addSectionApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const body = req.body() orelse {
        res.status = 400;
        res.body = "no body";
        return;
    };
    const section = parseJsonString(body, "\"section\"") orelse {
        res.status = 400;
        res.body = "missing section";
        return;
    };
    if (section.len == 0) {
        res.status = 400;
        res.body = "section name is empty";
        return;
    }
    const subtitle = parseJsonString(body, "\"subtitle\"") orelse "";
    const source = readDesignSource(ctx.allocator, ctx.project_dir, name) catch {
        res.status = 500;
        res.body = err_cannot_read_file;
        return;
    };
    defer ctx.allocator.free(source);

    const needle = try std.fmt.allocPrint(ctx.allocator, section_open_template, .{section});
    defer ctx.allocator.free(needle);
    if (std.mem.indexOf(u8, source, needle) != null) {
        res.status = 409;
        res.body = "a section with that name already exists";
        return;
    }
    const insert_at = designBlockInsertPos(source) orelse {
        res.status = 400;
        res.body = "not a design-block";
        return;
    };

    var buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer buf.deinit();
    const w = AllocatingWriter{ .writer = &buf.writer };
    try w.writeAll(source[0..insert_at]);
    try w.writeAll("\n  (section ");
    try writeSexprString(w, section);
    if (subtitle.len > 0) {
        try w.writeByte(' ');
        try writeSexprString(w, subtitle);
    }
    try w.writeAll(")\n");
    try w.writeAll(source[insert_at..]);
    try finishMutation(ctx, name, buf.written(), "add_section", res);
}

/// POST /api/rename-section/:name  Body: {"from":"Power","to":"Power Rails"}
pub fn renameSectionApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const body = req.body() orelse {
        res.status = 400;
        res.body = "no body";
        return;
    };
    const from = parseJsonString(body, "\"from\"") orelse {
        res.status = 400;
        res.body = "missing from";
        return;
    };
    const to = parseJsonString(body, "\"to\"") orelse {
        res.status = 400;
        res.body = "missing to";
        return;
    };
    if (to.len == 0) {
        res.status = 400;
        res.body = "new name is empty";
        return;
    }
    const source = readDesignSource(ctx.allocator, ctx.project_dir, name) catch {
        res.status = 500;
        res.body = err_cannot_read_file;
        return;
    };
    defer ctx.allocator.free(source);

    const needle = try std.fmt.allocPrint(ctx.allocator, section_open_template, .{from});
    defer ctx.allocator.free(needle);
    const at = std.mem.indexOf(u8, source, needle) orelse {
        res.status = 404;
        res.body = "section not found";
        return;
    };
    // Replace just the quoted name token: `(section "` is needle minus the name+quote.
    const name_start = at + "(section \"".len;
    const name_end = name_start + from.len; // followed by the closing quote
    var buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer buf.deinit();
    const w = AllocatingWriter{ .writer = &buf.writer };
    try w.writeAll(source[0..name_start]);
    for (to) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        else => try w.writeByte(c),
    };
    try w.writeAll(source[name_end..]);
    try finishMutation(ctx, name, buf.written(), "rename_section", res);
}

/// POST /api/remove-section/:name  Body: {"section":"Power"}
/// Deletes an EMPTY section (metadata only); refuses one holding parts (409).
pub fn removeSectionApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const body = req.body() orelse {
        res.status = 400;
        res.body = "no body";
        return;
    };
    const section = parseJsonString(body, "\"section\"") orelse {
        res.status = 400;
        res.body = "missing section";
        return;
    };
    const source = readDesignSource(ctx.allocator, ctx.project_dir, name) catch {
        res.status = 500;
        res.body = err_cannot_read_file;
        return;
    };
    defer ctx.allocator.free(source);

    const needle = try std.fmt.allocPrint(ctx.allocator, section_open_template, .{section});
    defer ctx.allocator.free(needle);
    const sec_start = std.mem.indexOf(u8, source, needle) orelse {
        res.status = 404;
        res.body = "section not found";
        return;
    };
    const sec_end = findFormEnd(source, sec_start) orelse {
        res.status = 500;
        res.body = err_malformed_instance;
        return;
    };
    // Only metadata (subtitle / row / col / role / protocol) may remain — refuse if
    // the section still carries parts or wiring so we never silently orphan them.
    const inner = source[sec_start..sec_end];
    const content_forms = [_][]const u8{ "(instance", "(sub-block", "(pins ", "(note", "(group", "(port", "(bus", "(decouple", "(series", "(test-point" };
    for (content_forms) |needle2| {
        if (std.mem.indexOf(u8, inner, needle2) != null) {
            res.status = 409;
            res.body = "section is not empty — move or delete its parts first";
            return;
        }
    }
    // Excise the form plus a leading blank line / indentation.
    var cut_start = sec_start;
    while (cut_start > 0 and (source[cut_start - 1] == ' ' or source[cut_start - 1] == '\t')) cut_start -= 1;
    if (cut_start > 0 and source[cut_start - 1] == '\n') cut_start -= 1;
    var cut_end = sec_end;
    if (cut_end < source.len and source[cut_end] == '\n') cut_end += 1;

    var buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer buf.deinit();
    const w = AllocatingWriter{ .writer = &buf.writer };
    try w.writeAll(source[0..cut_start]);
    try w.writeAll(source[cut_end..]);
    try finishMutation(ctx, name, buf.written(), "remove_section", res);
}

/// POST /api/add-port/:name  Body: {"net":"VDD","dir":"in"}  (dir: in|out|bidi)
pub fn addPortApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const body = req.body() orelse {
        res.status = 400;
        res.body = "no body";
        return;
    };
    const net = parseJsonString(body, "\"net\"") orelse {
        res.status = 400;
        res.body = "missing net";
        return;
    };
    const dir = parseJsonString(body, "\"dir\"") orelse "bidi";
    const dir_ok = std.mem.eql(u8, dir, "in") or std.mem.eql(u8, dir, "out") or std.mem.eql(u8, dir, "bidi");
    if (net.len == 0 or !dir_ok) {
        res.status = 400;
        res.body = "need net and dir in|out|bidi";
        return;
    }
    const source = readDesignSource(ctx.allocator, ctx.project_dir, name) catch {
        res.status = 500;
        res.body = err_cannot_read_file;
        return;
    };
    defer ctx.allocator.free(source);

    const dup = try std.fmt.allocPrint(ctx.allocator, "(port \"{s}\"", .{net});
    defer ctx.allocator.free(dup);
    if (std.mem.indexOf(u8, source, dup) != null) {
        res.status = 409;
        res.body = "a port for that net already exists";
        return;
    }
    const insert_at = designBlockInsertPos(source) orelse {
        res.status = 400;
        res.body = "not a design-block";
        return;
    };
    var buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer buf.deinit();
    const w = AllocatingWriter{ .writer = &buf.writer };
    try w.writeAll(source[0..insert_at]);
    try w.writeAll("\n  (port ");
    try writeSexprString(w, net);
    try w.writeByte(' ');
    try w.writeAll(dir);
    try w.writeAll(")\n");
    try w.writeAll(source[insert_at..]);
    try finishMutation(ctx, name, buf.written(), "add_port", res);
}

/// POST /api/remove-port/:name  Body: {"net":"VDD"}
pub fn removePortApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const body = req.body() orelse {
        res.status = 400;
        res.body = "no body";
        return;
    };
    const net = parseJsonString(body, "\"net\"") orelse {
        res.status = 400;
        res.body = "missing net";
        return;
    };
    const source = readDesignSource(ctx.allocator, ctx.project_dir, name) catch {
        res.status = 500;
        res.body = err_cannot_read_file;
        return;
    };
    defer ctx.allocator.free(source);

    const open_needle = try std.fmt.allocPrint(ctx.allocator, "(port \"{s}\"", .{net});
    defer ctx.allocator.free(open_needle);
    const p_start = std.mem.indexOf(u8, source, open_needle) orelse {
        res.status = 404;
        res.body = "port not found";
        return;
    };
    const p_end = findFormEnd(source, p_start) orelse {
        res.status = 500;
        res.body = err_malformed_instance;
        return;
    };
    var cut_start = p_start;
    while (cut_start > 0 and (source[cut_start - 1] == ' ' or source[cut_start - 1] == '\t')) cut_start -= 1;
    if (cut_start > 0 and source[cut_start - 1] == '\n') cut_start -= 1;
    var cut_end = p_end;
    if (cut_end < source.len and source[cut_end] == '\n') cut_end += 1;
    var buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer buf.deinit();
    const w = &buf.writer;
    try w.writeAll(source[0..cut_start]);
    try w.writeAll(source[cut_end..]);
    try finishMutation(ctx, name, buf.written(), "remove_port", res);
}

/// POST /api/rename-refdes/:name  Body: {"ref":"C3","to":"C10","srcOff":1234}
pub fn renameRefdesApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const body = req.body() orelse {
        res.status = 400;
        res.body = "no body";
        return;
    };
    const ref = parseJsonString(body, "\"ref\"") orelse {
        res.status = 400;
        res.body = err_missing_ref;
        return;
    };
    const to = parseJsonString(body, "\"to\"") orelse {
        res.status = 400;
        res.body = "missing to";
        return;
    };
    if (to.len == 0) {
        res.status = 400;
        res.body = "new ref is empty";
        return;
    }
    const src_off = parseSrcOff(body);
    const source = readDesignSource(ctx.allocator, ctx.project_dir, name) catch {
        res.status = 500;
        res.body = err_cannot_read_file;
        return;
    };
    defer ctx.allocator.free(source);

    // Refuse a collision with an existing explicit instance label.
    const collide = try std.fmt.allocPrint(ctx.allocator, "(instance \"{s}\"", .{to});
    defer ctx.allocator.free(collide);
    if (std.mem.indexOf(u8, source, collide) != null) {
        res.status = 409;
        res.body = "another instance already uses that ref";
        return;
    }
    const open = findInstanceOpen(source, ref, src_off) orelse {
        res.status = 404;
        res.body = err_instance_not_found;
        return;
    };
    const lq = std.mem.indexOfScalarPos(u8, source, open, '"') orelse {
        res.status = 500;
        res.body = err_malformed_instance;
        return;
    };
    const rq = std.mem.indexOfScalarPos(u8, source, lq + 1, '"') orelse {
        res.status = 500;
        res.body = err_malformed_instance;
        return;
    };
    var buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer buf.deinit();
    const w = &buf.writer;
    try w.writeAll(source[0 .. lq + 1]);
    for (to) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        else => try w.writeByte(c),
    };
    try w.writeAll(source[rq..]);
    try finishMutation(ctx, name, buf.written(), "rename_refdes", res);
}

/// POST /api/set-dnp/:name  Body: {"ref":"R7","dnp":true,"srcOff":1234}
/// Toggle a `(dnp)` marker inside an instance (Do-Not-Populate).
pub fn setDnpApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const body = req.body() orelse {
        res.status = 400;
        res.body = "no body";
        return;
    };
    const ref = parseJsonString(body, "\"ref\"") orelse {
        res.status = 400;
        res.body = err_missing_ref;
        return;
    };
    const want_dnp = std.mem.indexOf(u8, body, "\"dnp\":true") != null or
        std.mem.indexOf(u8, body, "\"dnp\": true") != null;
    const src_off = parseSrcOff(body);
    const source = readDesignSource(ctx.allocator, ctx.project_dir, name) catch {
        res.status = 500;
        res.body = err_cannot_read_file;
        return;
    };
    defer ctx.allocator.free(source);

    const open = findInstanceOpen(source, ref, src_off) orelse {
        res.status = 404;
        res.body = err_instance_not_found;
        return;
    };
    const end = findFormEnd(source, open) orelse {
        res.status = 500;
        res.body = err_malformed_instance;
        return;
    };
    const dnp_rel = std.mem.indexOf(u8, source[open..end], "(dnp)");
    var buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer buf.deinit();
    const w = &buf.writer;
    if (want_dnp) {
        if (dnp_rel != null) {
            res.status = 200;
            res.content_type = .JSON;
            res.body = "{\"ok\":true,\"noop\":true}";
            return;
        }
        try w.writeAll(source[0 .. end - 1]);
        try w.writeAll(" (dnp)");
        try w.writeAll(source[end - 1 ..]);
    } else {
        if (dnp_rel == null) {
            res.status = 200;
            res.content_type = .JSON;
            res.body = "{\"ok\":true,\"noop\":true}";
            return;
        }
        var d = open + dnp_rel.?;
        var d_end = d + "(dnp)".len;
        while (d > 0 and source[d - 1] == ' ') d -= 1; // eat one or more leading spaces
        if (d_end < source.len and source[d_end] == '\n' and (d == 0 or source[d - 1] == '\n')) d_end += 1;
        try w.writeAll(source[0..d]);
        try w.writeAll(source[d_end..]);
    }
    try finishMutation(ctx, name, buf.written(), "set_dnp", res);
}

/// POST /api/remove-instance/:name
/// Body: {"ref":"C3"}
pub fn removeInstanceApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const body = req.body() orelse {
        res.status = 400;
        res.body = "no body";
        return;
    };

    const ref_des = parseJsonString(body, "\"ref\"") orelse {
        res.status = 400;
        res.body = err_missing_ref;
        return;
    };

    // Read source file
    const file_path = try paths.designSourcePath(ctx.allocator, ctx.project_dir, name);
    defer ctx.allocator.free(file_path);

    const source = infra_fs.cwd().readFileAlloc(ctx.allocator, file_path, max_source_bytes) catch {
        res.status = 500;
        res.body = err_cannot_read_file;
        return;
    };
    defer ctx.allocator.free(source);

    // Locate the instance form. Prefer the scene-graph `srcOff` (robust to
    // label-declared parts that auto-renumber — e.g. a wizard-added cap whose
    // source ref-des is the component name, not the build-time C4), with the
    // `(instance "REF"` needle as fallback.
    const src_off = parseSrcOff(body);
    const inst_pos = findInstanceOpen(source, ref_des, src_off) orelse {
        res.status = 404;
        res.body = if (src_off > 0) err_generated_part else err_instance_not_found;
        return;
    };
    var inst_end = findFormEnd(source, inst_pos) orelse {
        res.status = 400;
        res.body = err_malformed_instance;
        return;
    };

    // Also eat trailing newline
    if (inst_end < source.len and source[inst_end] == '\n') inst_end += 1;

    // Also eat leading whitespace on the same line
    var inst_start = inst_pos;
    while (inst_start > 0 and (source[inst_start - 1] == ' ' or source[inst_start - 1] == '\t')) : (inst_start -= 1) {}

    var new_source: std.Io.Writer.Allocating = .init(ctx.allocator);
    const nw = &new_source.writer;
    try nw.writeAll(source[0..inst_start]);
    try nw.writeAll(source[inst_end..]);

    const file = infra_fs.cwd().createFile(file_path, .{}) catch {
        res.status = 500;
        res.body = err_cannot_write_file;
        return;
    };
    defer file.close();
    file.writeAll(new_source.written()) catch {
        res.status = 500;
        return;
    };

    std.debug.print("Removed instance {s} from {s}\n", .{ ref_des, name });
    rebuildAndPush(ctx, name, res) catch {
        res.status = 500;
        res.body = err_rebuild_failed;
        return;
    };
}

const instance_head = "(instance";
const pin_head = "(pin ";

/// Send a JSON `{"error":"…"}` body. `msg` is a trusted static string (no
/// embedded quotes/backslashes) — the frontend's `postEdit` parses the body as
/// JSON, so error paths must speak JSON too (a plaintext body trips its
/// `JSON.parse`, surfacing a cryptic "Unexpected token" to the user).
fn sendJsonError(ctx: *Server, res: *httpz.Response, status: u16, msg: []const u8) void {
    res.status = status;
    res.content_type = .JSON;
    res.header(header_cors_allow_origin, "*");
    res.body = std.fmt.allocPrint(ctx.allocator, err_json_fmt, .{msg}) catch
        "{\"error\":\"edit failed\"}";
}

/// Parse the optional numeric `"srcOff":N` field (the component-token offset the
/// scene graph publishes as `components[].src`). Returns 0 when absent.
fn parseSrcOff(body: []const u8) usize {
    const m = std.mem.indexOf(u8, body, json_src_off_key) orelse return 0;
    var s = m + json_src_off_key.len;
    while (s < body.len and body[s] == ' ') : (s += 1) {}
    var e = s;
    while (e < body.len and body[e] >= '0' and body[e] <= '9') : (e += 1) {}
    return std.fmt.parseInt(usize, body[s..e], 10) catch 0;
}

/// Locate the opening '(' of the `(instance "…"` form a part lives in. `src_off`
/// is the component-token offset the scene graph publishes (`components[].src`);
/// scanning back to the enclosing `(instance` makes the edit endpoints robust to
/// instances declared with a descriptive *label* that auto-renumbers to a
/// different ref-des (e.g. `(instance "expansion" 204928-0601 …)` → U10, so
/// `(instance "U10"` is never in the source). Falls back to a `(instance "REF"`
/// needle when no usable offset is given.
fn findInstanceOpen(source: []const u8, ref_des: []const u8, src_off: usize) ?usize {
    if (src_off > 0 and src_off <= source.len) {
        if (std.mem.lastIndexOf(u8, source[0..src_off], instance_head)) |p| {
            // Confirm it opens `(instance "` (not a comment mention) and that
            // src_off really sits inside this instance form.
            var q = p + instance_head.len;
            while (q < source.len and (source[q] == ' ' or source[q] == '\t')) : (q += 1) {}
            if (q < source.len and source[q] == '"') {
                if (findFormEnd(source, p)) |end| {
                    if (src_off < end) return p;
                }
            }
        }
    }
    var buf: [256]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, instance_open_template, .{ref_des}) catch return null;
    return std.mem.indexOf(u8, source, needle);
}

/// A parsed `(pin …)` form. The leading pin-id tokens are appended to the
/// caller's list; the struct carries the net-string bounds and flags the caller
/// needs to decide whether a multi-pin split is safe.
const PinForm = struct {
    form_start: usize,
    form_end: usize,
    net_start: usize, // index just past the opening quote of the net string
    net_end: usize, // index of the closing quote
    has_subform: bool, // an `(as …)` (or other) sub-form sits among the tokens
    clean_tail: bool, // only whitespace between the net's close-quote and ')'
};

fn isPinWs(ch: u8) bool {
    return ch == ' ' or ch == '\t' or ch == '\n' or ch == '\r';
}

/// True at the end of a pin-id token: whitespace, a sub-form '(', the net
/// string '"', or the form's ')'.
fn isPinTokenEnd(ch: u8) bool {
    return isPinWs(ch) or ch == '"' or ch == '(' or ch == ')';
}

/// Parse a `(pin …)` form starting at `form_start` (the '('). Appends the
/// leading pin-id tokens (slices into `source`) to `tokens` and returns the net
/// string bounds + safety flags. Returns null for a malformed form (no net).
fn parsePinForm(
    allocator: std.mem.Allocator,
    source: []const u8,
    form_start: usize,
    tokens: *std.ArrayList([]const u8),
) !?PinForm {
    const form_end = findFormEnd(source, form_start) orelse return null;
    var i = form_start + pin_head.len - 1; // step back over the trailing space
    var has_subform = false;
    while (i < form_end) {
        while (i < form_end and isPinWs(source[i])) : (i += 1) {}
        if (i >= form_end) return null;
        const ch = source[i];
        if (ch == ')') return null; // no net string
        if (ch == '"') {
            const ns = i + 1;
            const ne = std.mem.indexOfScalarPos(u8, source, ns, '"') orelse return null;
            var t = ne + 1;
            var clean = true;
            while (t + 1 < form_end) : (t += 1) {
                if (!isPinWs(source[t])) {
                    clean = false;
                    break;
                }
            }
            return PinForm{
                .form_start = form_start,
                .form_end = form_end,
                .net_start = ns,
                .net_end = ne,
                .has_subform = has_subform,
                .clean_tail = clean,
            };
        }
        if (ch == '(') {
            has_subform = true;
            i = findFormEnd(source, i) orelse return null;
            continue;
        }
        const ts = i;
        while (i < form_end and !isPinTokenEnd(source[i])) : (i += 1) {}
        try tokens.append(allocator, source[ts..i]);
    }
    return null;
}

/// The source label of an instance (its first quoted string), e.g. "stm32" in
/// `(instance "stm32" …)`. The label drives lookup of the instance's
/// section-level `(pins "<label>" …)` pin maps.
fn instanceLabel(source: []const u8, inst_open: usize) ?[]const u8 {
    var i = inst_open + instance_head.len;
    while (i < source.len and isPinWs(source[i])) : (i += 1) {}
    if (i >= source.len or source[i] != '"') return null;
    const s = i + 1;
    const e = std.mem.indexOfScalarPos(u8, source, s, '"') orelse return null;
    return source[s..e];
}

/// Scan `(pin …)` forms in [start, end) for the first whose pin-id token list
/// contains `pin`; on a hit, appends that form's tokens to `out_tokens` and
/// returns the parsed form.
fn findPinFormInRegion(
    allocator: std.mem.Allocator,
    source: []const u8,
    start: usize,
    end: usize,
    pin: []const u8,
    out_tokens: *std.ArrayList([]const u8),
) !?PinForm {
    var search = start;
    while (std.mem.indexOfPos(u8, source[0..end], search, pin_head)) |pf| {
        var tokens: std.ArrayList([]const u8) = .empty;
        defer tokens.deinit(allocator);
        if ((parsePinForm(allocator, source, pf, &tokens) catch null)) |parsed| {
            for (tokens.items) |tk| {
                if (std.mem.eql(u8, tk, pin)) {
                    try out_tokens.appendSlice(allocator, tokens.items);
                    return parsed;
                }
            }
            search = parsed.form_end;
        } else {
            search = pf + pin_head.len;
        }
    }
    return null;
}

/// Find the `(pin …)` form for `pin` belonging to the instance at `inst_open`,
/// searching the instance body first and then every section-level
/// `(pins "<label>" …)` map that declares the instance's pins (the main-IC
/// pin-map pattern). Tokens of the matched form are appended to `out_tokens`.
fn findInstancePinForm(
    allocator: std.mem.Allocator,
    source: []const u8,
    inst_open: usize,
    inst_end: usize,
    pin: []const u8,
    out_tokens: *std.ArrayList([]const u8),
) !?PinForm {
    if (try findPinFormInRegion(allocator, source, inst_open, inst_end, pin, out_tokens)) |m| return m;
    const label = instanceLabel(source, inst_open) orelse return null;
    var needle_buf: [256]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "(pins \"{s}\"", .{label}) catch return null;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, source, from, needle)) |pp| {
        const pe = findFormEnd(source, pp) orelse source.len;
        if (try findPinFormInRegion(allocator, source, pp, pe, pin, out_tokens)) |m| return m;
        from = pe;
    }
    return null;
}

/// POST /api/rewire-pin/:name
/// Body: {"ref":"U1","pin":"5","net":"VDD_NEW","srcOff":1234}
pub fn rewirePinApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const body = req.body() orelse {
        sendJsonError(ctx, res, 400, "no body");
        return;
    };

    const ref_des = parseJsonString(body, "\"ref\"") orelse {
        sendJsonError(ctx, res, 400, err_missing_ref);
        return;
    };
    const pin = parseJsonString(body, "\"pin\"") orelse {
        sendJsonError(ctx, res, 400, "missing pin");
        return;
    };
    const new_net = parseJsonString(body, "\"net\"") orelse {
        sendJsonError(ctx, res, 400, "missing net");
        return;
    };
    const src_off = parseSrcOff(body);

    const file_path = try paths.designSourcePath(ctx.allocator, ctx.project_dir, name);
    defer ctx.allocator.free(file_path);

    const source = infra_fs.cwd().readFileAlloc(ctx.allocator, file_path, max_source_bytes) catch {
        sendJsonError(ctx, res, 500, err_cannot_read_file);
        return;
    };
    defer ctx.allocator.free(source);

    // Locate the enclosing instance form (by component-token offset, robust to
    // label-declared instances; ref-des needle as fallback).
    const inst_open = findInstanceOpen(source, ref_des, src_off) orelse {
        sendJsonError(ctx, res, 404, if (src_off > 0) err_generated_part else err_instance_not_found);
        return;
    };
    const inst_end = findFormEnd(source, inst_open) orelse {
        sendJsonError(ctx, res, 400, err_malformed_instance);
        return;
    };

    // Find the matching `(pin …)` form — in the instance body or a section-level
    // `(pins "<label>" …)` map — covering single forms AND multi-pin shorthand
    // like `(pin 2 4 6 "VDD")` (which the old `(pin N "` needle could not match).
    var match_tokens: std.ArrayList([]const u8) = .empty;
    defer match_tokens.deinit(ctx.allocator);
    const p = (try findInstancePinForm(ctx.allocator, source, inst_open, inst_end, pin, &match_tokens)) orelse {
        // Pin not declared inline yet — add `(pin <pin> "<net>")` to the instance
        // body. Lets a staged/unwired part (a freshly-added cap with no pins) be
        // connected by dropping it on a net.
        const close = inst_end - 1; // the instance form's closing ')'
        var ins: std.Io.Writer.Allocating = .init(ctx.allocator);
        const iw = &ins.writer;
        try iw.writeAll(source[0..close]);
        try iw.print("\n    (pin {s} \"{s}\")", .{ pin, new_net });
        try iw.writeAll(source[close..]);
        infra_fs.cwd().writeFile(.{ .sub_path = file_path, .data = ins.written() }) catch {
            sendJsonError(ctx, res, 500, err_cannot_write_file);
            return;
        };
        rebuildAndPush(ctx, name, res) catch {
            sendJsonError(ctx, res, 500, err_rebuild_failed);
            return;
        };
        return;
    };

    var new_source: std.Io.Writer.Allocating = .init(ctx.allocator);
    const nw = &new_source.writer;
    if (match_tokens.items.len <= 1) {
        // Single-pin form: replace just the net string, preserving any trailing
        // `(as …)`/`(id …)` annotations.
        try nw.writeAll(source[0..p.net_start]);
        try nw.writeAll(new_net);
        try nw.writeAll(source[p.net_end..]);
    } else {
        // Multi-pin shorthand: split the target pin into its own form, leaving
        // the rest on the original net. Only safe for a clean `(pin … "net")`.
        if (p.has_subform or !p.clean_tail) {
            sendJsonError(ctx, res, 400, "this pin shares an annotated multi-pin (pin …) form — edit the source directly");
            return;
        }
        const old_net = source[p.net_start..p.net_end];
        try nw.writeAll(source[0..p.form_start]);
        try nw.writeAll(pin_head);
        var first = true;
        for (match_tokens.items) |tk| {
            if (std.mem.eql(u8, tk, pin)) continue;
            if (!first) try nw.writeByte(' ');
            try nw.writeAll(tk);
            first = false;
        }
        try nw.print(" \"{s}\") (pin {s} \"{s}\")", .{ old_net, pin, new_net });
        try nw.writeAll(source[p.form_end..]);
    }

    infra_fs.cwd().writeFile(.{ .sub_path = file_path, .data = new_source.written() }) catch {
        sendJsonError(ctx, res, 500, err_cannot_write_file);
        return;
    };

    rebuildAndPush(ctx, name, res) catch {
        sendJsonError(ctx, res, 500, err_rebuild_failed);
        return;
    };
}

/// Bind a bypass/decoupling cap to a specific hub pad: insert (or replace) a
/// `(decouples "IC" PAD)` form inside the instance. The editor calls this when a
/// cap is dropped on a hub pin so the schematic docks it on that pin (via
/// `boundHubPin` in render_svg/context.zig) — instead of whichever hub on a
/// shared net renders first — and the PCB placer keeps it there too. Body:
/// `{"ref":"C4","ic":"U2","pin":"6","srcOff":N}`.
pub fn bindDecoupleApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const body = req.body() orelse {
        sendJsonError(ctx, res, 400, "no body");
        return;
    };

    const ref_des = parseJsonString(body, "\"ref\"") orelse {
        sendJsonError(ctx, res, 400, err_missing_ref);
        return;
    };
    const ic = parseJsonString(body, "\"ic\"") orelse {
        sendJsonError(ctx, res, 400, "missing ic");
        return;
    };
    const pad = parseJsonString(body, "\"pin\"") orelse {
        sendJsonError(ctx, res, 400, "missing pin");
        return;
    };
    const src_off = parseSrcOff(body);

    const file_path = try paths.designSourcePath(ctx.allocator, ctx.project_dir, name);
    defer ctx.allocator.free(file_path);

    const source = infra_fs.cwd().readFileAlloc(ctx.allocator, file_path, max_source_bytes) catch {
        sendJsonError(ctx, res, 500, err_cannot_read_file);
        return;
    };
    defer ctx.allocator.free(source);

    const inst_open = findInstanceOpen(source, ref_des, src_off) orelse {
        sendJsonError(ctx, res, 404, if (src_off > 0) err_generated_part else err_instance_not_found);
        return;
    };
    const inst_end = findFormEnd(source, inst_open) orelse {
        sendJsonError(ctx, res, 400, err_malformed_instance);
        return;
    };

    // Build the form. A numeric pad stays bare (the `(decouples "U1" 24)` idiom);
    // a non-numeric pad ("B1") is quoted, the same as a `(pin …)` token.
    var numeric = pad.len > 0;
    for (pad) |c| {
        if (c < '0' or c > '9') {
            numeric = false;
            break;
        }
    }
    var form: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer form.deinit();
    const fw = &form.writer;
    if (numeric)
        try fw.print("(decouples \"{s}\" {s})", .{ ic, pad })
    else
        try fw.print("(decouples \"{s}\" \"{s}\")", .{ ic, pad });

    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    const ow = &out.writer;

    // Replace an existing (decouples …) in this instance (re-binding to a new
    // pin), else insert one before the instance's closing ')'.
    if (std.mem.indexOfPos(u8, source[0..inst_end], inst_open, "(decouples")) |dpos| {
        const dend = findFormEnd(source, dpos) orelse {
            sendJsonError(ctx, res, 400, "malformed decouples form");
            return;
        };
        try ow.writeAll(source[0..dpos]);
        try ow.writeAll(form.written());
        try ow.writeAll(source[dend..]);
    } else {
        const close = inst_end - 1; // the instance form's closing ')'
        try ow.writeAll(source[0..close]);
        try ow.print("\n    {s}", .{form.written()});
        try ow.writeAll(source[close..]);
    }

    infra_fs.cwd().writeFile(.{ .sub_path = file_path, .data = out.written() }) catch {
        sendJsonError(ctx, res, 500, err_cannot_write_file);
        return;
    };
    rebuildAndPush(ctx, name, res) catch {
        sendJsonError(ctx, res, 500, err_rebuild_failed);
        return;
    };
}

/// Duplicate an instance (copy/paste): clone its source form verbatim — same
/// component, value, pins, and any `(decouples …)`/`(dnp)` — right after the
/// original, with two edits: the `(id …)` is stripped (the clone mints a fresh
/// id, never sharing the original's frozen one), and the ref-des is replaced
/// with a unique non-standard placeholder ("C2-copy") so `autoAssignRefDes`
/// gives it a brand-new ref instead of colliding with the original. Body:
/// `{"ref":"C2","srcOff":N}`.
pub fn duplicateInstanceApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const body = req.body() orelse {
        sendJsonError(ctx, res, 400, "no body");
        return;
    };
    const ref_des = parseJsonString(body, "\"ref\"") orelse {
        sendJsonError(ctx, res, 400, err_missing_ref);
        return;
    };
    const src_off = parseSrcOff(body);

    const file_path = try paths.designSourcePath(ctx.allocator, ctx.project_dir, name);
    defer ctx.allocator.free(file_path);
    const source = infra_fs.cwd().readFileAlloc(ctx.allocator, file_path, max_source_bytes) catch {
        sendJsonError(ctx, res, 500, err_cannot_read_file);
        return;
    };
    defer ctx.allocator.free(source);

    const inst_open = findInstanceOpen(source, ref_des, src_off) orelse {
        sendJsonError(ctx, res, 404, if (src_off > 0) err_generated_part else err_instance_not_found);
        return;
    };
    const inst_end = findFormEnd(source, inst_open) orelse {
        sendJsonError(ctx, res, 400, err_malformed_instance);
        return;
    };

    // Ref string bounds: the first quoted token after "(instance".
    const q1 = std.mem.indexOfScalarPos(u8, source, inst_open, '"') orelse {
        sendJsonError(ctx, res, 400, err_malformed_instance);
        return;
    };
    const q2 = std.mem.indexOfScalarPos(u8, source, q1 + 1, '"') orelse {
        sendJsonError(ctx, res, 400, err_malformed_instance);
        return;
    };
    if (q2 >= inst_end) {
        sendJsonError(ctx, res, 400, err_malformed_instance);
        return;
    }

    // (id …) bounds, if present — stripped from the clone (incl. a leading space).
    var id_lo: usize = inst_end - 1; // default: empty split (nothing to strip)
    var id_hi: usize = inst_end - 1;
    if (std.mem.indexOfPos(u8, source[0..inst_end], inst_open, "(id ")) |idp| {
        id_hi = findFormEnd(source, idp) orelse inst_end;
        id_lo = if (idp > 0 and source[idp - 1] == ' ') idp - 1 else idp;
    }

    // Unique non-standard placeholder label so the clone renumbers to a fresh ref.
    var label_buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer label_buf.deinit();
    var n: usize = 1;
    while (n < 10000) : (n += 1) {
        label_buf.clearRetainingCapacity();
        const lw = &label_buf.writer;
        if (n == 1) try lw.print("{s}-copy", .{ref_des}) else try lw.print("{s}-copy{d}", .{ ref_des, n });
        const quoted = std.fmt.allocPrint(ctx.allocator, "\"{s}\"", .{label_buf.written()}) catch break;
        defer ctx.allocator.free(quoted);
        if (std.mem.indexOf(u8, source, quoted) == null) break;
    }

    // Assemble: source up to (and including) the original, a blank line, then the
    // clone (ref swapped, id removed), then the rest of the file.
    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    defer out.deinit();
    const ow = &out.writer;
    try ow.writeAll(source[0..inst_end]);
    try ow.writeAll("\n\n  ");
    try ow.writeAll(source[inst_open .. q1 + 1]); // "(instance \""
    try ow.writeAll(label_buf.written()); // new placeholder ref
    try ow.writeAll(source[q2..id_lo]); // "\" <component> <pins> …" up to the id
    try ow.writeAll(source[id_hi..inst_end]); // closing ")" (id removed)
    try ow.writeAll(source[inst_end..]);

    infra_fs.cwd().writeFile(.{ .sub_path = file_path, .data = out.written() }) catch {
        sendJsonError(ctx, res, 500, err_cannot_write_file);
        return;
    };
    rebuildAndPush(ctx, name, res) catch {
        sendJsonError(ctx, res, 500, err_rebuild_failed);
        return;
    };
}

/// Rename a net everywhere it appears: replace every quoted `"from"` token with
/// `"to"` across the source. A net name surfaces as a quoted token in `(pin …
/// "NET")`, `(port "NET" …)`, `(net "NET" …)` and the like, so one exact-token
/// (quote-delimited) pass renames all pins/ports/net-forms at once — and won't
/// touch a longer string that merely contains the name (a note, a wider net like
/// "VDD3V3"). Renaming onto an existing net merges them (intentional). Body:
/// `{"from":"LED2_DRV","to":"GP11_NET"}`.
pub fn renameNetApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const body = req.body() orelse {
        sendJsonError(ctx, res, 400, "no body");
        return;
    };
    const from = parseJsonString(body, "\"from\"") orelse {
        sendJsonError(ctx, res, 400, "missing from");
        return;
    };
    const to = parseJsonString(body, "\"to\"") orelse {
        sendJsonError(ctx, res, 400, "missing to");
        return;
    };
    if (from.len == 0 or to.len == 0) {
        sendJsonError(ctx, res, 400, "empty net name");
        return;
    }
    // `to` becomes a bare quoted token; quotes/parens/whitespace would corrupt it.
    if (std.mem.indexOfAny(u8, to, "\"()\x20\t\r\n") != null) {
        sendJsonError(ctx, res, 400, "invalid net name (no spaces, quotes or parens)");
        return;
    }

    const file_path = try paths.designSourcePath(ctx.allocator, ctx.project_dir, name);
    defer ctx.allocator.free(file_path);
    const source = infra_fs.cwd().readFileAlloc(ctx.allocator, file_path, max_source_bytes) catch {
        sendJsonError(ctx, res, 500, err_cannot_read_file);
        return;
    };
    defer ctx.allocator.free(source);

    const needle = try std.fmt.allocPrint(ctx.allocator, "\"{s}\"", .{from});
    defer ctx.allocator.free(needle);
    if (std.mem.count(u8, source, needle) == 0) {
        sendJsonError(ctx, res, 404, "net not found");
        return;
    }
    const repl = try std.fmt.allocPrint(ctx.allocator, "\"{s}\"", .{to});
    defer ctx.allocator.free(repl);
    const out = std.mem.replaceOwned(u8, ctx.allocator, source, needle, repl) catch {
        sendJsonError(ctx, res, 500, err_cannot_write_file);
        return;
    };
    defer ctx.allocator.free(out);

    infra_fs.cwd().writeFile(.{ .sub_path = file_path, .data = out }) catch {
        sendJsonError(ctx, res, 500, err_cannot_write_file);
        return;
    };
    rebuildAndPush(ctx, name, res) catch {
        sendJsonError(ctx, res, 500, err_rebuild_failed);
        return;
    };
}

/// Move a single-pin form `(pin OLD "NET")` to `(pin NEW "NET")` within an
/// instance. Body: `{"ref":"U1","old_pin":"V11","new_pin":"V12"}`. Returns
/// HTTP 409 with a structured error if the destination pin is already used.
pub fn movePinApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    res.content_type = .JSON;
    res.header(header_cors_allow_origin, "*");

    const name = req.param("name") orelse {
        res.status = 404;
        res.body = err_json_missing_name;
        return;
    };
    const body = req.body() orelse {
        res.status = 400;
        res.body = err_json_no_body;
        return;
    };

    const ref_des = parseJsonString(body, "\"ref\"") orelse {
        res.status = 400;
        res.body = "{\"error\":\"missing ref\"}";
        return;
    };
    const old_pin = parseJsonString(body, "\"old_pin\"") orelse {
        res.status = 400;
        res.body = "{\"error\":\"missing old_pin\"}";
        return;
    };
    const new_pin = parseJsonString(body, "\"new_pin\"") orelse {
        res.status = 400;
        res.body = "{\"error\":\"missing new_pin\"}";
        return;
    };

    // Resolve ref_des → source key. Source `.sexp` forms use the instance's
    // `label` (e.g. "stm32") when set, and the ref_des otherwise. The scene
    // graph/UI always speaks ref_des.
    const source_key = resolveSourceKey(ctx.allocator, ctx.project_dir, name, ref_des) catch ref_des;

    const result = movePinCore(ctx.allocator, ctx.project_dir, name, source_key, old_pin, new_pin) catch |err| {
        switch (err) {
            error.PinAlreadyAssigned => {
                res.status = 409;
                res.body = try std.fmt.allocPrint(ctx.allocator, "{{\"error\":\"pin_already_assigned\",\"pin\":\"{s}\"}}", .{new_pin});
                return;
            },
            error.PinNotFound => {
                res.status = 404;
                res.body = "{\"error\":\"pin_not_found\"}";
                return;
            },
            error.InstanceNotFound => {
                res.status = 404;
                res.body = "{\"error\":\"instance_not_found\"}";
                return;
            },
            error.InvalidSource => {
                res.status = 400;
                res.body = "{\"error\":\"invalid_pin_id\"}";
                return;
            },
            error.RebuildFailed => {
                res.status = 500;
                res.body = "{\"error\":\"rebuild_failed\"}";
                return;
            },
            else => {
                res.status = 500;
                res.body = try std.fmt.allocPrint(ctx.allocator, err_json_fmt, .{@errorName(err)});
                return;
            },
        }
    };

    res.body = try std.fmt.allocPrint(ctx.allocator, "{{\"ok\":true,\"version\":{d}}}", .{result.version});
}

/// Swap the net assignments of two pins on the same instance.
/// Body: `{"ref":"U1","pin_a":"V11","pin_b":"V12"}`.
pub fn swapPinsApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    res.content_type = .JSON;
    res.header(header_cors_allow_origin, "*");

    const name = req.param("name") orelse {
        res.status = 404;
        res.body = err_json_missing_name;
        return;
    };
    const body = req.body() orelse {
        res.status = 400;
        res.body = err_json_no_body;
        return;
    };

    const ref_des = parseJsonString(body, "\"ref\"") orelse {
        res.status = 400;
        res.body = "{\"error\":\"missing ref\"}";
        return;
    };
    const pin_a = parseJsonString(body, "\"pin_a\"") orelse {
        res.status = 400;
        res.body = "{\"error\":\"missing pin_a\"}";
        return;
    };
    const pin_b = parseJsonString(body, "\"pin_b\"") orelse {
        res.status = 400;
        res.body = "{\"error\":\"missing pin_b\"}";
        return;
    };

    const source_key = resolveSourceKey(ctx.allocator, ctx.project_dir, name, ref_des) catch ref_des;

    const result = swapPinsCore(ctx.allocator, ctx.project_dir, name, source_key, pin_a, pin_b) catch |err| {
        switch (err) {
            error.PinNotFound => {
                res.status = 404;
                res.body = "{\"error\":\"pin_not_found\"}";
                return;
            },
            error.InstanceNotFound => {
                res.status = 404;
                res.body = "{\"error\":\"instance_not_found\"}";
                return;
            },
            error.InvalidSource => {
                res.status = 400;
                res.body = "{\"error\":\"invalid_pin_id\"}";
                return;
            },
            error.RebuildFailed => {
                res.status = 500;
                res.body = "{\"error\":\"rebuild_failed\"}";
                return;
            },
            else => {
                res.status = 500;
                res.body = try std.fmt.allocPrint(ctx.allocator, err_json_fmt, .{@errorName(err)});
                return;
            },
        }
    };

    res.body = try std.fmt.allocPrint(ctx.allocator, "{{\"ok\":true,\"version\":{d}}}", .{result.version});
}

/// Rebuild design, render SVG, and push live update. Every caller has just
/// written the design source, so this is a write tail like `writeAndRebuild`:
/// it pins the minted ids before identity resolution derives uuids from them.
fn rebuildAndPush(ctx: *Server, name: []const u8, res: *httpz.Response) HandlerError!void {
    const board_path = try paths.designSourcePath(ctx.allocator, ctx.project_dir, name);
    defer ctx.allocator.free(board_path);

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();
    const result = eval.evalFile(board_path) catch return error.RebuildFailed;
    _ = id_insert.persistMintedIds(ctx.allocator, board_path, &eval);
    const block = switch (result) {
        .design_block => |b| b,
        // A standalone `lib/modules/<name>.sexp` evaluates by registering its
        // defmodule rather than returning a flattened design block. Parsing and
        // import resolution succeeded, so publish the source mutation exactly
        // as writeAndRebuild does; the module schematic re-instantiates it on
        // reload. Rejecting this path after the file was already written made
        // every structured edit on `/schematics/<module>` report a false 500.
        else => {
            _ = serve_root.bumpLiveVersion(name);
            res.header(header_cors_allow_origin, "*");
            res.content_type = .JSON;
            res.body = ok_json_true;
            return;
        },
    };

    const bom_path = try paths.designSiblingPath(ctx.allocator, ctx.project_dir, name, ".bom");
    defer ctx.allocator.free(bom_path);
    bom.resolveIdentities(ctx.allocator, block, bom_path, ctx.project_dir) catch |e| warnResolveIdentities(name, e);

    const layout_json = render_json.renderSceneGraph(ctx.allocator, block, ctx.project_dir) catch null;
    serve_root.setLiveLayoutJson(name, layout_json);
    _ = serve_root.bumpLiveVersion(name);

    res.header(header_cors_allow_origin, "*");
    res.content_type = .JSON;
    res.body = ok_json_true;
}

fn parseJsonString(body: []const u8, key: []const u8) ?[]const u8 {
    const marker = std.mem.indexOf(u8, body, key) orelse return null;
    var start = marker + key.len;
    while (start < body.len and body[start] != '"') : (start += 1) {}
    start += 1; // skip opening quote
    const end = std.mem.indexOfPos(u8, body, start, "\"") orelse return null;
    return body[start..end];
}

/// True when `source` already has a top-level `(import <name>)`. Token-aware so
/// `(import foo)` does not match a request to import `foobar`.
fn hasImport(source: []const u8, name: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, source, from, import_open)) |p| {
        from = p + import_open.len;
        var q = from;
        while (q < source.len and source[q] == ' ') : (q += 1) {}
        if (std.mem.startsWith(u8, source[q..], name)) {
            const after = q + name.len;
            if (after >= source.len) return true;
            switch (source[after]) {
                ' ', ')', '\n', '\t', '\r' => return true,
                else => {},
            }
        }
    }
    return false;
}

// ── Core mutation API (shared between HTTP handlers and CLI tools) ───────
//
// The `…Core` functions are pure-logic entry points: they take an allocator,
// project dir, design name, and edit args, and return a MutationResult with
// the post-edit live_version. HTTP handlers above still do their own parsing
// and response-shaping; these cores are called by the CLI tool dispatcher
// (see src/tool_cli.zig). Later, the HTTP handlers can be converted to
// delegate here to remove duplication.

pub const EditError = error{
    InstanceNotFound,
    PinNotFound,
    PinAlreadyAssigned,
    SectionNotFound,
    ComponentNotFound,
    NoteNotFound,
    ImportsFormMissing,
    DuplicateImport,
    DuplicateParameter,
    DuplicateRequirement,
    InvalidRequirement,
    MalformedSource,
    InvalidSource,
    CannotReadDesign,
    CannotWriteDesign,
    RebuildFailed,
    SnapshotNotFound,
    InvalidSnapshotId,
    AmbiguousMatch,
    InvalidName,
} || std.mem.Allocator.Error;

/// Returned by every `…Core` mutation to tell the caller the new live
/// version (so it can include the value the next viewer poll will see) and
/// the pre-edit snapshot id used by `restoreDesignCore` for undo.
pub const MutationResult = struct {
    version: u32,
    /// Snapshot id for the state immediately before this mutation, or null if
    /// the file did not exist yet (brand-new design). Caller owns the memory.
    snapshot: ?[]const u8 = null,
};

pub const AssertionFailure = rebuild_design.AssertionFailure;
pub const BuildWarning = rebuild_design.BuildWarning;
pub const BuildReport = rebuild_design.BuildReport;
pub const rebuildDesign = rebuild_design.run;

fn designFilePath(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8) ![]u8 {
    return paths.designSourcePath(allocator, project_dir, name);
}

fn readDesignSource(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8) EditError![]u8 {
    const path = try designFilePath(allocator, project_dir, name);
    defer allocator.free(path);
    return infra_fs.cwd().readFileAlloc(allocator, path, max_source_bytes) catch return error.CannotReadDesign;
}

/// Snapshot → write → re-evaluate → bump the live version. The canonical
/// design-file mutation tail, shared by the granular edits here.
pub fn writeAndRebuild(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    new_source: []const u8,
    description: ?[]const u8,
) EditError!MutationResult {
    const path = try designFilePath(allocator, project_dir, name);
    defer allocator.free(path);

    // Snapshot prior state before overwriting. Null means the design didn't
    // exist yet (brand-new create). Snapshot errors are logged but don't
    // block the write — undo is a nice-to-have, not a hard requirement.
    const snap_id: ?[]const u8 = history.snapshot(allocator, project_dir, name, description) catch |e| blk: {
        log.warn("[snapshot] failed for {s}: {s}", .{ name, @errorName(e) });
        break :blk null;
    };

    {
        const file = infra_fs.cwd().createFile(path, .{}) catch return error.CannotWriteDesign;
        defer file.close();
        file.writeAll(new_source) catch return error.CannotWriteDesign;
    }

    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();
    const result = eval.evalFile(path) catch return error.RebuildFailed;
    // Pin the identities this evaluation minted back into the source we just
    // wrote, BEFORE anything derives a uuid from them. `generateId` is process
    // randomness, so an id that never reaches the file is a different id (and
    // therefore a different `uuidFromId`, and a missed `.bom` property
    // carry-forward) on every later evaluation. Identity is persisted at write
    // time — this is the shared tail of every design mutation, so the read
    // paths that follow find the ids already in the source and never mutate.
    // Same call, same best-effort error handling as `rebuild_design.run`.
    _ = id_insert.persistMintedIds(allocator, path, &eval);
    const block = switch (result) {
        .design_block => |b| b,
        // A `lib/modules/<name>.sexp` file evaluates to a `(defmodule …)`, not
        // a design-block. It parsed, its imports resolved, and the module
        // registered without error, so accept the save and bump the version;
        // the `/modules/<name>` page re-instantiates the module on the next
        // load (surfacing any body-level diagnostic there). BOM/scene-graph
        // need a flattened design, so they're skipped for a module file.
        else => return .{ .version = serve_root.bumpLiveVersion(name), .snapshot = snap_id },
    };

    const bom_path = paths.designSiblingPath(allocator, project_dir, name, ".bom") catch return error.OutOfMemory;
    defer allocator.free(bom_path);
    bom.resolveIdentities(allocator, block, bom_path, project_dir) catch |e| warnResolveIdentities(name, e);

    const layout_json = render_json.renderSceneGraph(allocator, block, project_dir) catch null;
    serve_root.setLiveLayoutJson(name, layout_json);
    const version = serve_root.bumpLiveVersion(name);

    return .{ .version = version, .snapshot = snap_id };
}

fn findInstanceEnd(source: []const u8, inst_start: usize) ?usize {
    var depth: u32 = 0;
    for (source[inst_start..], 0..) |ch, i| {
        if (ch == '(') depth += 1;
        if (ch == ')') {
            depth -= 1;
            if (depth == 0) return inst_start + i + 1;
        }
    }
    return null;
}

/// Find the index one past the closing paren of the form whose open paren
/// lives at `open_pos`. Respects strings and `;` line comments, so section
/// bodies (which commonly contain both) are handled correctly.
fn findFormEnd(source: []const u8, open_pos: usize) ?usize {
    var i: usize = open_pos;
    var depth: i32 = 0;
    while (i < source.len) : (i += 1) {
        const ch = source[i];
        if (ch == '"') {
            i += 1;
            while (i < source.len and source[i] != '"') : (i += 1) {
                if (source[i] == '\\' and i + 1 < source.len) i += 1;
            }
            continue;
        }
        if (ch == ';') {
            while (i < source.len and source[i] != '\n') : (i += 1) {}
            continue;
        }
        if (ch == '(') depth += 1;
        if (ch == ')') {
            depth -= 1;
            if (depth == 0) return i + 1;
        }
    }
    return null;
}

/// Error set for the BOM-side MPN/manufacturer edit path. Narrower than
/// `EditError` because we don't touch the `.sexp` source or rebuild the
/// design — just patch the `.bom` sidecar via `bom_resolve.setBomProperty`.
pub const MpnEditError = std.mem.Allocator.Error ||
    infra_fs.File.OpenError ||
    infra_fs.File.ReadError ||
    infra_fs.File.WriteError ||
    error{ InvalidName, FileTooBig, StreamTooLong, EndOfStream, DiskQuota, BrokenPipe, NotOpenForWriting, EntropyUnavailable };

/// Update MPN and/or manufacturer for `ref_des` in the `.bom` sidecar.
/// Empty string for either field leaves that field untouched (so callers
/// can patch one or both in a single call). Bumps the live version so the
/// browser's poll picks up the change. Shared between the HTTP
/// `editMpnApi` and the CLI `edit_mpn` tool.
pub fn editMpnCore(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    ref_des: []const u8,
    mpn: []const u8,
    manufacturer: []const u8,
) MpnEditError!u32 {
    const bom_path = try paths.designSiblingPath(allocator, project_dir, name, ".bom");
    defer allocator.free(bom_path);

    if (mpn.len > 0) bom_resolve.setBomProperty(allocator, bom_path, ref_des, "mpn", mpn) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |other| return other,
    };
    if (manufacturer.len > 0) bom_resolve.setBomProperty(allocator, bom_path, ref_des, "manufacturer", manufacturer) catch |err| switch (err) {
        error.WriteFailed => return error.OutOfMemory,
        else => |other| return other,
    };

    return serve_root.bumpLiveVersion(name);
}

/// POST /api/edit-mpn/:name — body `{"ref":"R1","mpn":"…","manufacturer":"…"}`.
/// Either the `mpn` or `manufacturer` field may be omitted; only the present
/// ones are persisted. Persists to the `.bom` sidecar and bumps the live
/// version. Returns `{"ok":true,"version":N}`.
pub fn editMpnApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = http_not_found;
        return;
    };
    const body = req.body() orelse {
        res.status = http_bad_request;
        res.body = err_json_no_body;
        return;
    };

    // ref is required.
    const ref_start = std.mem.indexOf(u8, body, json_ref_key) orelse {
        res.status = http_bad_request;
        res.body = err_missing_ref;
        return;
    };
    const ref_val_start = ref_start + json_ref_key.len;
    const ref_end = std.mem.indexOfPos(u8, body, ref_val_start, "\"") orelse {
        res.status = http_bad_request;
        return;
    };
    const ref_des = body[ref_val_start..ref_end];

    // mpn + manufacturer are optional (empty string = leave alone).
    const mpn = parseOptionalStringField(body, "\"mpn\":\"");
    const manufacturer = parseOptionalStringField(body, "\"manufacturer\":\"");

    if (mpn.len == 0 and manufacturer.len == 0) {
        res.status = http_bad_request;
        res.body = "no fields to update";
        return;
    }

    const version = editMpnCore(ctx.allocator, ctx.project_dir, name, ref_des, mpn, manufacturer) catch |e| {
        log.warn("editMpn {s} {s}: {s}", .{ name, ref_des, @errorName(e) });
        res.status = http_internal_error;
        res.body = "{\"ok\":false}";
        return;
    };

    res.header(header_cors_allow_origin, "*");
    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(ctx.allocator, "{{\"ok\":true,\"version\":{d}}}", .{version});
}

/// Look for `key` (e.g. `"\"mpn\":\""`) in a tiny JSON body and return the
/// quoted string value, or "" if the key is missing. Doesn't unescape — the
/// inputs we accept here (MPN, manufacturer) don't use JSON escapes in
/// practice. Used by `editMpnApi`.
fn parseOptionalStringField(body: []const u8, key: []const u8) []const u8 {
    const start = std.mem.indexOf(u8, body, key) orelse return "";
    const val_start = start + key.len;
    const end = std.mem.indexOfPos(u8, body, val_start, "\"") orelse return "";
    return body[val_start..end];
}

/// Overwrite (or create) the design's `.sexp` with `new_source`. Validates
/// syntax via the sexpr parser before writing, snapshots any prior state,
/// then rebuilds the design.
pub fn writeDesignCore(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    new_source: []const u8,
) EditError!MutationResult {
    // Pre-flight: reject obvious syntax errors so a broken file never hits
    // disk. Semantic errors (missing imports, assertion failures) still fall
    // through to the rebuild step — the auto-snapshot serves as undo there.
    _ = sexpr_parser.parse(allocator, new_source) catch return error.InvalidSource;

    // Ensure src/ exists so brand-new designs can be created.
    const src_dir = try std.fmt.allocPrint(allocator, "{s}/src", .{project_dir});
    defer allocator.free(src_dir);
    infra_fs.cwd().makePath(src_dir) catch |e| {
        log.warn("makePath {s} failed: {s}", .{ src_dir, @errorName(e) });
    };

    return writeAndRebuild(allocator, project_dir, name, new_source, "write_design");
}

/// Restore a design from a history snapshot. First snapshots the current
/// state (so restore is itself undoable), then copies the snapshot files
/// back into `src/` and rebuilds.
pub fn restoreDesignCore(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    id: []const u8,
) EditError!MutationResult {
    // Snapshot current state first so the restore can be undone.
    const pre_desc = try std.fmt.allocPrint(allocator, "pre-restore {s}", .{id});
    defer allocator.free(pre_desc);
    const pre_snap: ?[]const u8 = history.snapshot(allocator, project_dir, name, pre_desc) catch |e| blk: {
        log.warn("[snapshot] pre-restore failed for {s}: {s}", .{ name, @errorName(e) });
        break :blk null;
    };

    history.restore(allocator, project_dir, name, id) catch |e| switch (e) {
        error.InvalidSnapshotId => return error.InvalidSnapshotId,
        error.SnapshotNotFound => return error.SnapshotNotFound,
        else => return error.CannotReadDesign,
    };

    // Rebuild from the restored source.
    const path = try designFilePath(allocator, project_dir, name);
    defer allocator.free(path);

    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();
    const result = eval.evalFile(path) catch return error.RebuildFailed;
    // A restore REPLACES the source file, so it is a write like any other: an
    // old revision that predates id minting must gain its ids here rather than
    // hand a random one to `resolveIdentities` below. See writeAndRebuild.
    _ = id_insert.persistMintedIds(allocator, path, &eval);
    const block = switch (result) {
        .design_block => |b| b,
        // Module file (`lib/modules/<name>.sexp`) — see writeAndRebuild.
        else => return .{ .version = serve_root.bumpLiveVersion(name), .snapshot = pre_snap },
    };

    const bom_path = paths.designSiblingPath(allocator, project_dir, name, ".bom") catch return error.OutOfMemory;
    defer allocator.free(bom_path);
    bom.resolveIdentities(allocator, block, bom_path, project_dir) catch |e| warnResolveIdentities(name, e);

    const layout_json = render_json.renderSceneGraph(allocator, block, project_dir) catch null;
    serve_root.setLiveLayoutJson(name, layout_json);
    const version = serve_root.bumpLiveVersion(name);

    return .{ .version = version, .snapshot = pre_snap };
}

/// Splice a new `(note "text" [(ref "file.pdf" (page N))])` into the body of
/// a `(section "NAME" ...)` form. Inserts immediately before the closing `)`
/// of the section. `pdf` is optional — when non-empty, emits the `(ref ...)`
/// sub-form; when the page is 0 it's omitted. This is the design-specific
/// half of the two-tier notes model (design notes live in the .sexp; library
/// requirements live in `lib/components/<...>.sexp`).
pub fn addSectionNoteCore(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    section_name: []const u8,
    text: []const u8,
    pdf: []const u8,
    page: u32,
) EditError!MutationResult {
    if (text.len == 0) return error.InvalidSource;
    const source = try readDesignSource(allocator, project_dir, name);
    defer allocator.free(source);

    const needle = try std.fmt.allocPrint(allocator, section_open_template, .{section_name});
    defer allocator.free(needle);
    const sec_start = std.mem.indexOf(u8, source, needle) orelse return error.SectionNotFound;
    if (std.mem.indexOfPos(u8, source, sec_start + needle.len, needle) != null) return error.AmbiguousMatch;
    const sec_end = findFormEnd(source, sec_start) orelse return error.MalformedSource;
    const insert_at = sec_end - 1;

    // Indent heuristic: match the first non-whitespace sibling inside the
    // section body so new notes sit alongside existing forms.
    const indent = detectSectionIndent(source, sec_start);

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const w = AllocatingWriter{ .writer = &buf.writer };
    try w.writeAll(source[0..insert_at]);
    try w.writeByte('\n');
    try w.writeAll(indent);
    try w.writeAll("(note \"");
    for (text) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        else => try w.writeByte(c),
    };
    try w.writeAll("\"");
    if (pdf.len > 0) {
        try w.writeAll(" (ref \"");
        for (pdf) |c| switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            else => try w.writeByte(c),
        };
        try w.writeAll("\"");
        if (page > 0) try w.print(" (page {d})", .{page});
        try w.writeAll(")");
    }
    try w.writeAll(")\n");
    try w.writeAll(source[insert_at..]);

    const desc = try std.fmt.allocPrint(allocator, "add_section_note {s}", .{section_name});
    defer allocator.free(desc);
    return writeAndRebuild(allocator, project_dir, name, buf.written(), desc);
}

/// Remove the `idx`-th `(note ...)` form inside a named section (0-based,
/// in source order). Used by the review UI when a reviewer clicks the
/// delete button on a design note.
pub fn removeSectionNoteCore(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    section_name: []const u8,
    idx: usize,
) EditError!MutationResult {
    const source = try readDesignSource(allocator, project_dir, name);
    defer allocator.free(source);

    const needle = try std.fmt.allocPrint(allocator, section_open_template, .{section_name});
    defer allocator.free(needle);
    const sec_start = std.mem.indexOf(u8, source, needle) orelse return error.SectionNotFound;
    if (std.mem.indexOfPos(u8, source, sec_start + needle.len, needle) != null) return error.AmbiguousMatch;
    const sec_end = findFormEnd(source, sec_start) orelse return error.MalformedSource;

    // Walk `(note ` forms that are direct children of the section (depth 1
    // relative to the section). Skip anything nested in sub-sections or
    // instances so the caller's idx matches what the review UI shows.
    // String literals and `;` line comments are skipped so parens inside
    // them don't confuse depth tracking.
    var cursor: usize = sec_start + 1;
    var depth: usize = 1;
    var note_idx: usize = 0;
    while (cursor < sec_end) {
        const ch = source[cursor];
        if (ch == ';') {
            while (cursor < sec_end and source[cursor] != '\n') : (cursor += 1) {}
            continue;
        }
        if (ch == '(') {
            if (depth == 1 and std.mem.startsWith(u8, source[cursor..], "(note")) {
                const end = findFormEnd(source, cursor) orelse return error.MalformedSource;
                if (note_idx == idx) {
                    var trim_start: usize = cursor;
                    while (trim_start > 0 and (source[trim_start - 1] == ' ' or source[trim_start - 1] == '\t')) : (trim_start -= 1) {}
                    if (trim_start > 0 and source[trim_start - 1] == '\n') trim_start -= 1;
                    var trim_end: usize = end;
                    if (trim_end < source.len and source[trim_end] == '\n') trim_end += 1;

                    var buf: std.Io.Writer.Allocating = .init(allocator);
                    defer buf.deinit();
                    const w = AllocatingWriter{ .writer = &buf.writer };
                    try w.writeAll(source[0..trim_start]);
                    try w.writeAll(source[trim_end..]);

                    const desc = try std.fmt.allocPrint(allocator, "remove_section_note {s}[{d}]", .{ section_name, idx });
                    defer allocator.free(desc);
                    return writeAndRebuild(allocator, project_dir, name, buf.written(), desc);
                }
                note_idx += 1;
                cursor = end;
                continue;
            }
            depth += 1;
        } else if (ch == ')') {
            depth -= 1;
            if (depth == 0) break;
        } else if (ch == '"') {
            var j: usize = cursor + 1;
            while (j < source.len and source[j] != '"') : (j += 1) {
                if (source[j] == '\\' and j + 1 < source.len) j += 1;
            }
            cursor = j + 1;
            continue;
        }
        cursor += 1;
    }

    return error.NoteNotFound;
}

/// Splice a `(datasheet "file.pdf")` entry into the component definition at
/// `lib/components/<component>.sexp`. Dedupes — a filename whose stem already
/// links (ignoring a re-download counter) returns `DuplicateImport` rather than
/// re-adding. Lets the schematic sidebar link a PDF to a part with one click
/// instead of editing the library by hand.
///
/// The library file isn't rebuilt into a design (it's a library, not a
/// design), so this path bypasses the usual writeAndRebuild flow: we do a
/// quick parse-check of the result, snapshot if possible, and bump a
/// server-wide version the pinout cache reads off.
pub fn addComponentDatasheetCore(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    component_name: []const u8,
    pdf: []const u8,
) EditError!MutationResult {
    if (pdf.len == 0) return error.InvalidSource;
    if (!safeLibName(component_name)) return error.InvalidSource;
    if (!safePdfName(pdf)) return error.InvalidSource;

    const path = try libComponentPath(allocator, project_dir, component_name);
    defer allocator.free(path);
    const source = infra_fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch return error.CannotReadDesign;
    defer allocator.free(source);

    // Pure splice (dedupes on the normalised stem — see datasheet_attach.zig,
    // where the logic lives so it's unit-testable).
    const new_source = datasheet_attach.spliceDatasheet(allocator, source, pdf) catch |err| switch (err) {
        error.MalformedSource => return error.MalformedSource,
        error.DuplicateImport => return error.DuplicateImport,
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer allocator.free(new_source);

    try writeLibComponent(path, new_source);
    const version = serve_root.bumpLiveVersion(component_name);
    return .{ .version = version, .snapshot = null };
}

/// Remove a single `(datasheet "file.pdf")` line from
/// `lib/components/<component>.sexp`. Silently succeeds when the link
/// didn't exist so UI double-clicks don't 500.
pub fn removeComponentDatasheetCore(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    component_name: []const u8,
    pdf: []const u8,
) EditError!MutationResult {
    if (pdf.len == 0) return error.InvalidSource;
    if (!safeLibName(component_name)) return error.InvalidSource;
    if (!safePdfName(pdf)) return error.InvalidSource;

    const path = try libComponentPath(allocator, project_dir, component_name);
    defer allocator.free(path);
    const source = infra_fs.cwd().readFileAlloc(allocator, path, 1024 * 1024) catch return error.CannotReadDesign;
    defer allocator.free(source);

    const needle = try std.fmt.allocPrint(allocator, "(datasheet \"{s}\")", .{pdf});
    defer allocator.free(needle);
    const pos = std.mem.indexOf(u8, source, needle) orelse return error.NoteNotFound;
    const end = pos + needle.len;

    // Trim preceding whitespace + newline so we don't leave a blank line.
    var trim_start: usize = pos;
    while (trim_start > 0 and (source[trim_start - 1] == ' ' or source[trim_start - 1] == '\t')) : (trim_start -= 1) {}
    if (trim_start > 0 and source[trim_start - 1] == '\n') trim_start -= 1;
    var trim_end: usize = end;
    if (trim_end < source.len and source[trim_end] == '\n') trim_end += 1;

    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const w = AllocatingWriter{ .writer = &buf.writer };
    try w.writeAll(source[0..trim_start]);
    try w.writeAll(source[trim_end..]);

    try writeLibComponent(path, buf.written());
    const version = serve_root.bumpLiveVersion(component_name);
    return .{ .version = version, .snapshot = null };
}

fn libComponentPath(allocator: std.mem.Allocator, project_dir: []const u8, component_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, component_path_template, .{ project_dir, component_name });
}

fn writeLibComponent(path: []const u8, new_source: []const u8) EditError!void {
    const file = infra_fs.cwd().createFile(path, .{}) catch return error.CannotWriteDesign;
    defer file.close();
    file.writeAll(new_source) catch return error.CannotWriteDesign;
}

fn safeLibName(name: []const u8) bool {
    if (name.len == 0) return false;
    if (std.mem.indexOf(u8, name, "..") != null) return false;
    if (std.mem.indexOfAny(u8, name, "/\\") != null) return false;
    return true;
}

fn safePdfName(name: []const u8) bool {
    if (name.len == 0 or name.len > 255) return false;
    if (std.mem.indexOf(u8, name, "..") != null) return false;
    if (std.mem.indexOfAny(u8, name, "/\\\"") != null) return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_' or c == '-' or c == '.';
        if (!ok) return false;
    }
    return true;
}

/// Return the indentation prefix (leading whitespace) of the first child
/// form inside a `(section ...)` body, so splice points match the file's
/// existing indent style. Falls back to two spaces when the section is
/// empty.
fn detectSectionIndent(source: []const u8, sec_start: usize) []const u8 {
    // Skip past `(section "NAME"` opening — find the first newline after it.
    var i: usize = sec_start;
    while (i < source.len and source[i] != '\n') : (i += 1) {}
    if (i >= source.len) return "  ";
    i += 1;
    const indent_start = i;
    while (i < source.len and (source[i] == ' ' or source[i] == '\t')) : (i += 1) {}
    if (i == indent_start) return "  ";
    return source[indent_start..i];
}

const PinTokenLoc = struct { start: usize, end: usize };

/// Scan the interior of a single `(pin ...)` form — starting just after
/// `(pin ` and bounded by `limit` — for the first top-level bareword token
/// equal to `pin`. Stops at the first `"` (net string) or the form's
/// closing `)`. Nested sub-forms like `(as "AF")` are skipped as opaque,
/// so pin IDs declared as `(pin W12 (as "TIM2_CH2") "CNV_MASTER")` are
/// recognised just like plain `(pin W12 "CNV_MASTER")` forms.
fn findPinInForm(source: []const u8, start: usize, limit: usize, pin: []const u8) ?PinTokenLoc {
    var i: usize = start;
    while (i < limit) {
        const c = source[i];
        if (c == ')' or c == '"') return null;
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r') {
            i += 1;
            continue;
        }
        if (c == '(') {
            var depth: usize = 1;
            i += 1;
            while (i < limit and depth > 0) : (i += 1) {
                if (source[i] == '(') depth += 1 else if (source[i] == ')') depth -= 1;
            }
            continue;
        }
        const tok_start = i;
        while (i < limit) : (i += 1) {
            const cc = source[i];
            if (cc == ' ' or cc == '\t' or cc == '\n' or cc == '\r' or cc == '"' or cc == '(' or cc == ')') break;
        }
        if (std.mem.eql(u8, source[tok_start..i], pin)) return .{ .start = tok_start, .end = i };
    }
    return null;
}

/// Locate the byte range of the first pin-ID token equal to `pin` across
/// every `(pin ...)` form inside `regions`. Works for both single-pin
/// `(pin X "NET")` and multi-pin shorthand `(pin 1 2 3 "NET")` — in the
/// shorthand case the returned range covers just the matching numeric
/// token, so callers can rename it in place and leave the rest of the
/// list intact.
fn findPinTokenInRegions(source: []const u8, regions: []const PinRegion, pin: []const u8) ?PinTokenLoc {
    for (regions) |r| {
        var search: usize = r.start;
        while (std.mem.indexOfPos(u8, source, search, "(pin ")) |p| {
            if (p >= r.end) break;
            if (findPinInForm(source, p + "(pin ".len, r.end, pin)) |loc| return loc;
            search = p + "(pin ".len;
        }
    }
    return null;
}

/// Map a ref_des (e.g. "U3") to the string used in the `.sexp` source for
/// that instance's `(instance "X" ...)` and `(pins "X" ...)` forms. Returns
/// the instance's `label` if set, otherwise the ref_des itself. Falls back
/// to the ref_des on any evaluation error.
fn resolveSourceKey(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    ref_des: []const u8,
) ![]const u8 {
    const path = try designFilePath(allocator, project_dir, name);
    defer allocator.free(path);
    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();
    const result = eval.evalFile(path) catch return ref_des;
    const block = switch (result) {
        .design_block => |b| b,
        else => return ref_des,
    };
    for (block.instances) |inst| {
        if (std.mem.eql(u8, inst.ref_des, ref_des)) {
            return if (inst.label.len > 0) try allocator.dupe(u8, inst.label) else ref_des;
        }
    }
    return ref_des;
}

const PinRegion = struct { start: usize, end: usize };

/// Collect the byte ranges of every form that may contain pin assignments
/// for `ref_des`: inline `(instance "REF" ...)` forms, and section-level
/// `(pins "REF" ...)` routing groups.
fn collectPinRegions(
    allocator: std.mem.Allocator,
    source: []const u8,
    ref_des: []const u8,
    out: *std.ArrayList(PinRegion),
) EditError!void {
    const heads = [_][]const u8{ "(instance \"", "(pins \"" };
    inline for (heads) |head| {
        const needle = try std.fmt.allocPrint(allocator, "{s}{s}\"", .{ head, ref_des });
        defer allocator.free(needle);
        var search: usize = 0;
        while (std.mem.indexOfPos(u8, source, search, needle)) |p| {
            const end = findInstanceEnd(source, p) orelse return error.MalformedSource;
            try out.append(allocator, .{ .start = p, .end = end });
            search = end;
        }
    }
}

/// Rename the pin-ID token `old_pin` to `new_pin` inside any `(pin ...)`
/// form that declares pins for `ref_des` — works whether the old token
/// sits in a single-pin form `(pin OLD "NET")` or inside a multi-pin
/// shorthand `(pin 1 OLD 3 "NET")`. Multi-pin shorthand stays shorthand:
/// only the numeric token changes. Fails with `PinAlreadyAssigned` if
/// `new_pin` is already used anywhere across those regions.
pub fn movePinCore(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    ref_des: []const u8,
    old_pin: []const u8,
    new_pin: []const u8,
) EditError!MutationResult {
    if (old_pin.len == 0 or new_pin.len == 0) return error.InvalidSource;
    for (new_pin) |c| if (c == ' ' or c == '\t' or c == '\n' or c == '"' or c == '(' or c == ')') return error.InvalidSource;
    if (std.mem.eql(u8, old_pin, new_pin)) return error.InvalidSource;

    const source = try readDesignSource(allocator, project_dir, name);
    defer allocator.free(source);

    var regions: std.ArrayList(PinRegion) = .empty;
    defer regions.deinit(allocator);
    try collectPinRegions(allocator, source, ref_des, &regions);
    if (regions.items.len == 0) return error.InstanceNotFound;

    if (findPinTokenInRegions(source, regions.items, new_pin) != null) return error.PinAlreadyAssigned;
    const old_loc = findPinTokenInRegions(source, regions.items, old_pin) orelse return error.PinNotFound;

    var new_source: std.Io.Writer.Allocating = .init(allocator);
    defer new_source.deinit();
    const nw = AllocatingWriter{ .writer = &new_source.writer };
    try nw.writeAll(source[0..old_loc.start]);
    try nw.writeAll(new_pin);
    try nw.writeAll(source[old_loc.end..]);

    const desc = try std.fmt.allocPrint(allocator, "move_pin {s}.{s} → {s}", .{ ref_des, old_pin, new_pin });
    defer allocator.free(desc);
    return writeAndRebuild(allocator, project_dir, name, new_source.written(), desc);
}

/// Swap the pin-ID tokens of two pins on the same instance so the nets
/// attached to `pin_a` and `pin_b` trade places. Each pin may live in a
/// single-pin `(pin X "NET")` form or inside a multi-pin shorthand
/// `(pin A B C "NET")` — the numeric/ID token is renamed wherever it
/// sits, so shorthand forms stay shorthand.
pub fn swapPinsCore(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    ref_des: []const u8,
    pin_a: []const u8,
    pin_b: []const u8,
) EditError!MutationResult {
    if (pin_a.len == 0 or pin_b.len == 0) return error.InvalidSource;
    for (pin_a) |c| if (c == ' ' or c == '\t' or c == '\n' or c == '"' or c == '(' or c == ')') return error.InvalidSource;
    for (pin_b) |c| if (c == ' ' or c == '\t' or c == '\n' or c == '"' or c == '(' or c == ')') return error.InvalidSource;
    if (std.mem.eql(u8, pin_a, pin_b)) return error.InvalidSource;

    const source = try readDesignSource(allocator, project_dir, name);
    defer allocator.free(source);

    var regions: std.ArrayList(PinRegion) = .empty;
    defer regions.deinit(allocator);
    try collectPinRegions(allocator, source, ref_des, &regions);
    if (regions.items.len == 0) return error.InstanceNotFound;

    const a_loc = findPinTokenInRegions(source, regions.items, pin_a) orelse return error.PinNotFound;
    const b_loc = findPinTokenInRegions(source, regions.items, pin_b) orelse return error.PinNotFound;

    const a_first = a_loc.start < b_loc.start;
    const first_start = if (a_first) a_loc.start else b_loc.start;
    const first_end = if (a_first) a_loc.end else b_loc.end;
    const first_replace: []const u8 = if (a_first) pin_b else pin_a;
    const second_start = if (a_first) b_loc.start else a_loc.start;
    const second_end = if (a_first) b_loc.end else a_loc.end;
    const second_replace: []const u8 = if (a_first) pin_a else pin_b;

    var new_source: std.Io.Writer.Allocating = .init(allocator);
    defer new_source.deinit();
    const nw = AllocatingWriter{ .writer = &new_source.writer };
    try nw.writeAll(source[0..first_start]);
    try nw.writeAll(first_replace);
    try nw.writeAll(source[first_end..second_start]);
    try nw.writeAll(second_replace);
    try nw.writeAll(source[second_end..]);

    const desc = try std.fmt.allocPrint(allocator, "swap_pins {s}.{s} <-> {s}", .{ ref_des, pin_a, pin_b });
    defer allocator.free(desc);
    return writeAndRebuild(allocator, project_dir, name, new_source.written(), desc);
}

/// GET /api/source/:name — returns `{"source":"<raw .sexp text>"}`.
pub fn getSourceApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    res.content_type = .JSON;
    res.header(header_cors_allow_origin, "*");

    const name = req.param("name") orelse {
        res.status = 404;
        res.body = err_json_missing_name;
        return;
    };

    const source = readDesignSource(ctx.allocator, ctx.project_dir, name) catch {
        res.status = 404;
        res.body = "{\"error\":\"cannot read design\"}";
        return;
    };
    defer ctx.allocator.free(source);

    var buf: std.Io.Writer.Allocating = .init(ctx.allocator);
    const w = &buf.writer;
    try w.writeAll("{\"source\":\"");
    try bom_html.writeJsonEscaped(w, source);
    try w.writeAll("\"}");
    res.body = buf.written();
}

/// POST /api/source/:name — body `{"source":"<raw .sexp text>"}`. Validates
/// syntax, writes the file, rebuilds, bumps version. Returns
/// `{"ok":true,"version":N,"snapshot":...}` on success or
/// `{"ok":false,"error":"..."}` with HTTP 400 on invalid source.
pub fn saveSourceApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    res.content_type = .JSON;
    res.header(header_cors_allow_origin, "*");

    const name = req.param("name") orelse {
        res.status = 404;
        res.body = err_json_missing_name;
        return;
    };
    const body = req.body() orelse {
        res.status = 400;
        res.body = err_json_no_body;
        return;
    };

    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, body, .{}) catch {
        res.status = 400;
        res.body = "{\"ok\":false,\"error\":\"invalid json\"}";
        return;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        res.status = 400;
        res.body = "{\"ok\":false,\"error\":\"body must be a JSON object\"}";
        return;
    }
    const source_val = parsed.value.object.get("source") orelse {
        res.status = 400;
        res.body = "{\"ok\":false,\"error\":\"missing source\"}";
        return;
    };
    if (source_val != .string) {
        res.status = 400;
        res.body = "{\"ok\":false,\"error\":\"source must be a string\"}";
        return;
    }

    const result = writeDesignCore(ctx.allocator, ctx.project_dir, name, source_val.string) catch |err| {
        switch (err) {
            error.InvalidSource => {
                res.status = 400;
                res.body = "{\"ok\":false,\"error\":\"invalid sexp syntax\"}";
                return;
            },
            error.RebuildFailed => {
                res.status = 400;
                res.body = "{\"ok\":false,\"error\":\"rebuild failed: source wrote but evaluator rejected it\"}";
                return;
            },
            error.CannotWriteDesign => {
                res.status = 500;
                res.body = "{\"ok\":false,\"error\":\"cannot write file\"}";
                return;
            },
            else => {
                res.status = 500;
                res.body = try std.fmt.allocPrint(ctx.allocator, "{{\"ok\":false,\"error\":\"{s}\"}}", .{@errorName(err)});
                return;
            },
        }
    };

    var out: std.Io.Writer.Allocating = .init(ctx.allocator);
    const w = &out.writer;
    try w.print("{{\"ok\":true,\"version\":{d},\"snapshot\":", .{result.version});
    if (result.snapshot) |s| {
        try w.writeAll("\"");
        try bom_html.writeJsonEscaped(w, s);
        try w.writeAll("\"");
    } else {
        try w.writeAll("null");
    }
    try w.writeAll("}");
    res.body = out.written();
}

// ── Tests ─────────────────────────────────────────────────────────

// spec: Web Server - the schematic Design type control replaces only the design root's board-role form, preserving comments and nested module text
test "schematic design type replaces the direct board role only" {
    const allocator = std.testing.allocator;
    const source =
        \\(defmodule helper ()
        \\  (design-block "Nested" (board-role subcircuit)))
        \\(design-block "Main"
        \\  ;; Example text: (board-role subcircuit)
        \\  (section "Power")
        \\  (board-role subcircuit))
    ;
    const updated = try patchBoardRoleSource(allocator, source, .board);
    defer allocator.free(updated);

    try std.testing.expect(std.mem.indexOf(u8, updated, "(design-block \"Nested\" (board-role subcircuit))") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, ";; Example text: (board-role subcircuit)") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "(section \"Power\")\n  (board-role board))") != null);
}

// spec: Web Server - the schematic Design type control adds an explicit role when a string-named block currently relies on the subcircuit default
test "schematic design type inserts a board role into a string block root" {
    const allocator = std.testing.allocator;
    const source =
        \\(import helper)
        \\(block "Carrier"
        \\  (section "IO"))
    ;
    const updated = try patchBoardRoleSource(allocator, source, .subcircuit);
    defer allocator.free(updated);

    try std.testing.expectEqualStrings(
        \\(import helper)
        \\(block "Carrier"
        \\  (section "IO")
        \\  (board-role subcircuit))
    ,
        updated,
    );
}

// spec: Web Server - A subcircuit's PCB autorouter offers a Power plane toggle for implicit and authored stackups: on keeps supply planes, off routes supplies as ordinary copper while retaining ground planes; the choice is saved in design source and reused by routing, DRC, reload, and fabrication outputs
test "autorouter power-plane toggle patches nested module design settings" {
    const allocator = std.testing.allocator;
    const source =
        \\(defmodule bcuda-lt3045-ldo ((vout 3.3))
        \\  "LDO"
        \\  (let label (fmt "~V LDO" vout))
        \\  (design-block label
        \\    (stackup 4 (plane 2 "GND") (plane 3 "VOUT"))))
    ;
    const updated = try patchPowerPlaneSource(allocator, source, false);
    defer allocator.free(updated);
    try std.testing.expect(std.mem.indexOf(u8, updated, "(power-plane off)") != null);
    try std.testing.expect(std.mem.indexOf(u8, updated, "(plane 3 \"VOUT\")") != null);
    const meta = try boardRouteMeta(allocator, updated);
    try std.testing.expectEqual(env_mod.BoardRole.subcircuit, meta.role);
    try std.testing.expect(!meta.power_plane);
    const restored = try patchPowerPlaneSource(allocator, updated, true);
    defer allocator.free(restored);
    try std.testing.expect((try boardRouteMeta(allocator, restored)).power_plane);
    try std.testing.expect(std.mem.indexOf(u8, restored, "(plane 3 \"VOUT\")") != null);

    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "meta.role!==\"subcircuit\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "power_plane_applicable===false") == null);
    try std.testing.expect(std.mem.indexOf(u8, js, "rpower.id=\"r-power-plane\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "fetch(\"/api/power-plane/\"") != null);
}

test "componentLinksDatasheet dedupes a re-download counter name" {
    // spec: serve/edit - datasheet dedupe ignores re-download counter suffix
    const form =
        \\(component "tps55289"
        \\  (datasheet "tps55289.pdf"))
    ;
    // Exact, ` (1)`, and post-sanitise `__1_` variants all count as duplicates.
    try std.testing.expect(datasheet_attach.linksDatasheet(form, "tps55289.pdf"));
    try std.testing.expect(datasheet_attach.linksDatasheet(form, "tps55289 (1).pdf"));
    try std.testing.expect(datasheet_attach.linksDatasheet(form, "tps55289__1_.pdf"));
    // A genuinely different datasheet is not a duplicate.
    try std.testing.expect(!datasheet_attach.linksDatasheet(form, "tps55289-errata.pdf"));
}

test "findComponentTokenInInstance locates the token via ref" {
    // spec: serve/edit - edit-footprint locates the component token within the instance form
    const src =
        \\(design-block "X"
        \\  (instance "C4" (cap-0402 "1pF")
        \\    (pin 1 "GND")))
    ;
    const inst_off = std.mem.indexOf(u8, src, "(instance \"C4\"").?;
    const off = findComponentTokenInInstance(src, "C4", "cap-0402").?;
    try std.testing.expect(off > inst_off);
    try std.testing.expectEqualStrings("cap-0402", src[off .. off + "cap-0402".len]);
    // No match for a ref that isn't present.
    try std.testing.expect(findComponentTokenInInstance(src, "C9", "cap-0402") == null);
}

test "datasheetStem keeps a trailing-digit part number intact" {
    // spec: serve/edit - datasheet stem preserves trailing-digit part numbers
    try std.testing.expectEqualStrings("lm2596", datasheet_attach.datasheetStem("lm2596.pdf"));
    try std.testing.expectEqualStrings("tps55289", datasheet_attach.datasheetStem("tps55289__2_.pdf"));
}

test "findInstanceOpen finds a label-declared instance by component offset" {
    // spec: serve/edit - rewire-pin locates the instance by component-token offset
    const src =
        \\(design-block "X"
        \\  (instance "expansion" 204928-0601
        \\    (pin 2 4 6 "VDD")))
    ;
    const head = "(instance \"expansion\"";
    const comp_off = std.mem.indexOf(u8, src, "204928-0601").?;
    // ref-des "U10" is NOT in the source (label auto-renumbers) — offset wins.
    const open = findInstanceOpen(src, "U10", comp_off).?;
    try std.testing.expectEqualStrings(head, src[open .. open + head.len]);
    // With no offset, falls back to the label/ref-des needle.
    try std.testing.expectEqual(open, findInstanceOpen(src, "expansion", 0).?);
    try std.testing.expect(findInstanceOpen(src, "NOPE", 0) == null);
}

test "parsePinForm reads single and multi-pin shorthand forms" {
    // spec: serve/edit - rewire-pin splits a multi-pin shorthand to re-wire one pin
    const src =
        \\(instance "x" foo
        \\  (pin 2 4 6 "VDD")
        \\  (pin W16 (as "PG11") "BPSK"))
    ;
    const a = std.testing.allocator;
    var toks: std.ArrayList([]const u8) = .empty;
    defer toks.deinit(a);

    const shorthand = std.mem.indexOf(u8, src, "(pin 2").?;
    const pf = (try parsePinForm(a, src, shorthand, &toks)).?;
    try std.testing.expectEqual(@as(usize, 3), toks.items.len);
    try std.testing.expectEqualStrings("2", toks.items[0]);
    try std.testing.expectEqualStrings("6", toks.items[2]);
    try std.testing.expectEqualStrings("VDD", src[pf.net_start..pf.net_end]);
    try std.testing.expect(!pf.has_subform and pf.clean_tail);

    // A single pin carrying an (as …) annotation → one token, sub-form flagged.
    toks.clearRetainingCapacity();
    const annotated = std.mem.indexOf(u8, src, "(pin W16").?;
    const pf2 = (try parsePinForm(a, src, annotated, &toks)).?;
    try std.testing.expectEqual(@as(usize, 1), toks.items.len);
    try std.testing.expectEqualStrings("W16", toks.items[0]);
    try std.testing.expectEqualStrings("BPSK", src[pf2.net_start..pf2.net_end]);
    try std.testing.expect(pf2.has_subform);
}

test "findInstancePinForm finds a pin in a section (pins label) map" {
    // spec: serve/edit - rewire-pin finds a pin in a section pins map
    const src =
        \\(design-block "X"
        \\  (instance "stm32" big-mcu)
        \\  (section "Y"
        \\    (pins "stm32" (group "G") (pin W16 (as "PG11") "OLDNET"))))
    ;
    const a = std.testing.allocator;
    const inst_open = std.mem.indexOf(u8, src, "(instance \"stm32\"").?;
    const inst_end = findFormEnd(src, inst_open).?;
    var toks: std.ArrayList([]const u8) = .empty;
    defer toks.deinit(a);
    // Not in the (tiny) instance body, but in the section's (pins "stm32" …) map.
    const m = (try findInstancePinForm(a, src, inst_open, inst_end, "W16", &toks)).?;
    try std.testing.expectEqualStrings("OLDNET", src[m.net_start..m.net_end]);
    try std.testing.expectEqual(@as(usize, 1), toks.items.len);
    // A pin that exists nowhere stays unmatched.
    toks.clearRetainingCapacity();
    try std.testing.expect((try findInstancePinForm(a, src, inst_open, inst_end, "ZZ9", &toks)) == null);
}

test "parseSrcOff reads the digits that follow the srcOff key" {
    // `m + JSON_SRC_OFF_KEY.len` steps FORWARD past the key onto the digits;
    // a `+`->`-` flip rewinds before the key, landing on a non-digit and
    // yielding 0 instead of the real offset.
    try std.testing.expectEqual(@as(usize, 42), parseSrcOff("{\"aaaaaaaa\":1,\"srcOff\":42}"));
}

test "findPinInForm locates a bareword pin token before any net string" {
    // The `(c == ')' or c == '\"')` bailout must fire only on the form close
    // or a net string; flipping either `==` to `!=` makes it bail on the very
    // first ordinary token char, so the pin is never found.
    const src = "(pin W12 \"CNV\")";
    const loc = findPinInForm(src, "(pin ".len, src.len, "W12") orelse return error.TestPinNotFound;
    try std.testing.expectEqualStrings("W12", src[loc.start..loc.end]);
}

/// Read one `.bom` entry by ref-des for the identity tests below. Returns the
/// entry, or `null` when the sidecar has no row for `ref`.
fn testBomEntry(
    allocator: std.mem.Allocator,
    bom_path: []const u8,
    ref: []const u8,
) !?bom.BomEntry {
    const entries = try bom.loadBom(allocator, bom_path);
    for (entries) |e| {
        if (std.mem.eql(u8, e.ref_des, ref)) return e;
    }
    return null;
}

/// Look up a property value on a `.bom` entry.
fn testBomProp(entry: bom.BomEntry, key: []const u8) ?[]const u8 {
    for (entry.properties) |p| {
        if (std.mem.eql(u8, p.key, key)) return p.value;
    }
    return null;
}

// spec: serve/edit - a design saved through writeAndRebuild pins its minted (id …) into the source, so the next save reproduces the same uuid and the .bom's MPN carries forward
test "writeAndRebuild pins minted ids so uuid and BOM properties survive a second save" {
    // page_allocator: the evaluator allocates from it and never frees (AST
    // slices reference source buffers), so testing.allocator would flag those
    // intentional leaks. Same convention as the id_insert persist test.
    const alloc = std.heap.page_allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(project_dir);

    try tmp.dir.createDirPath(std.testing.io, "lib/components");
    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/components/cap.sexp",
        .data =
        \\(component-family cap
        \\  (param-type capacitance)
        \\  (footprint "0402"))
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/components/0402.sexp",
        .data = "(component 0402 (footprint \"0402.kicad_mod\"))",
    });

    const design_path = try std.fmt.allocPrint(alloc, "{s}/src/idpersist.sexp", .{project_dir});
    defer alloc.free(design_path);
    const bom_path = try std.fmt.allocPrint(alloc, "{s}/src/idpersist.bom", .{project_dir});
    defer alloc.free(bom_path);

    // The editor saves a brand-new instance carrying no `(id …)`.
    const authored =
        \\(import cap)
        \\(design-block "Id Persist"
        \\  (instance "C1" (cap "100nF")
        \\    (pin 1 "VDD")
        \\    (pin 2 "GND")))
    ;
    _ = try writeAndRebuild(alloc, project_dir, "idpersist", authored, "first save");

    // (a) The id the evaluation minted is now IN the source, not just in RAM.
    const saved1 = try infra_fs.cwd().readFileAlloc(alloc, design_path, max_source_bytes);
    defer alloc.free(saved1);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, saved1, "(id "));

    const entry1 = (try testBomEntry(alloc, bom_path, "C1")) orelse return error.TestNoBomEntry;
    try std.testing.expect(entry1.uuid.len > 0);
    // The sidecar names a token the source actually carries — the property that
    // makes every later `uuidFromId(id)` reproduce.
    const id_token = try std.fmt.allocPrint(alloc, "(id {s})", .{entry1.id});
    defer alloc.free(id_token);
    try std.testing.expect(std.mem.indexOf(u8, saved1, id_token) != null);

    // The inline MPN editor writes a property keyed on that identity.
    try bom_resolve.setBomProperty(alloc, bom_path, "C1", "mpn", "GRM155R71C104KA88D");

    // Second save: read the file back and store it again, exactly as the editor
    // does. Without the pin, this evaluation mints a FRESH random id and both
    // the uuid and the id-keyed property carry-forward are lost.
    _ = try writeAndRebuild(alloc, project_dir, "idpersist", saved1, "second save");

    const saved2 = try infra_fs.cwd().readFileAlloc(alloc, design_path, max_source_bytes);
    defer alloc.free(saved2);
    // A pinned design mints nothing, so the source is byte-stable across saves.
    try std.testing.expectEqualStrings(saved1, saved2);

    const entry2 = (try testBomEntry(alloc, bom_path, "C1")) orelse return error.TestNoBomEntry;
    // (b) Same instance, same uuid.
    try std.testing.expectEqualStrings(entry1.id, entry2.id);
    try std.testing.expectEqualStrings(entry1.uuid, entry2.uuid);
    // (c) The MPN survived, because carry-forward is keyed on that stable id.
    const mpn = testBomProp(entry2, "mpn") orelse return error.TestMpnDropped;
    try std.testing.expectEqualStrings("GRM155R71C104KA88D", mpn);
}

// spec: serve/edit - restoring a history snapshot pins the restored source's minted ids before identity resolution
test "restoreDesignCore pins the restored revision's minted ids" {
    const alloc = std.heap.page_allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(project_dir);

    try tmp.dir.createDirPath(std.testing.io, "lib/components");
    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/components/cap.sexp",
        .data =
        \\(component-family cap
        \\  (param-type capacitance)
        \\  (footprint "0402"))
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "lib/components/0402.sexp",
        .data = "(component 0402 (footprint \"0402.kicad_mod\"))",
    });

    const design_path = try std.fmt.allocPrint(alloc, "{s}/src/idrestore.sexp", .{project_dir});
    defer alloc.free(design_path);

    // Both revisions are written straight to disk, so history holds a revision
    // that predates id minting — the shape a restore has to cope with. (They
    // are deliberately id-free on BOTH sides: `history.snapshot` ids are
    // second-granular, so a restore inside the same second re-snapshots over
    // the entry it is about to read and the test must not depend on which
    // revision wins that race.)
    const rev1 =
        \\(import cap)
        \\(design-block "Id Restore"
        \\  (instance "C1" (cap "100nF")
        \\    (pin 1 "VDD")
        \\    (pin 2 "GND")))
    ;
    try infra_fs.cwd().writeFile(.{ .sub_path = design_path, .data = rev1 });
    const snap_id = (try history.snapshot(alloc, project_dir, "idrestore", "first revision")) orelse
        return error.TestNoSnapshot;

    const rev2 =
        \\(import cap)
        \\(design-block "Id Restore"
        \\  (instance "C1" (cap "220nF")
        \\    (pin 1 "VDD")
        \\    (pin 2 "GND")))
    ;
    try infra_fs.cwd().writeFile(.{ .sub_path = design_path, .data = rev2 });

    _ = try restoreDesignCore(alloc, project_dir, "idrestore", snap_id);
    const restored = try infra_fs.cwd().readFileAlloc(alloc, design_path, max_source_bytes);
    defer alloc.free(restored);
    // The restore's own rebuild minted an id for the id-free revision it put
    // back, and pinned it — a restored revision is not left identity-less,
    // whichever of the two id-free revisions the snapshot race hands back.
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, restored, "(id "));
}
