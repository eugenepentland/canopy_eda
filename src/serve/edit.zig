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
const eval_modules = @import("../eval/modules.zig");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;
const bom_html = @import("bom_html.zig");
const history = @import("history.zig");
const sexpr_parser = @import("../sexpr/parser.zig");
const erc_mod = @import("../erc.zig");
const diag_format = @import("diag_format.zig");
const datasheet_attach = @import("datasheet_attach.zig");

// ── Constants ─────────────────────────────────────────────────────
const HTTP_NOT_FOUND: u16 = 404;
const HTTP_BAD_REQUEST: u16 = 400;
const HTTP_INTERNAL_ERROR: u16 = 500;
const MAX_SOURCE_BYTES: usize = 10 * 1024 * 1024;

// JSON key prefixes (length-encoded so we don't need bare integer offsets)
const JSON_REF_KEY = "\"ref\":\"";
const JSON_VALUE_KEY = "\"value\":\"";
const JSON_COMPONENT_KEY = "\"component\":\"";
const JSON_OLD_COMPONENT_KEY = "\"oldComponent\":\"";
const JSON_SRC_OFF_KEY = "\"srcOff\":";
const JSON_PINS_KEY = "\"pins\"";

// Repeated string templates / fragments
const COMPONENT_PATH_TEMPLATE = "{s}/lib/components/{s}.sexp";
const INSTANCE_OPEN_TEMPLATE = "(instance \"{s}\"";
const SECTION_OPEN_TEMPLATE = "(section \"{s}\"";
const IMPORT_OPEN = "(import ";

const HEADER_CORS_ALLOW_ORIGIN = "access-control-allow-origin";
const ERR_CANNOT_READ_FILE = "cannot read file";
const ERR_CANNOT_WRITE_FILE = "cannot write file";
const ERR_REBUILD_FAILED = "rebuild failed";
const ERR_INSTANCE_NOT_FOUND = "instance not found";
const ERR_MALFORMED_INSTANCE = "malformed instance form";
const ERR_GENERATED_PART = "this part is generated (decouple/series) or defined in a module — edit its source form directly";
const ERR_NO_EDITABLE_VALUE = "this part has a fixed component with no editable value";
const ERR_MISSING_REF = "missing ref";

const ERR_JSON_NO_BODY = "{\"error\":\"no body\"}";
const ERR_JSON_MISSING_NAME = "{\"error\":\"missing name\"}";
const OK_JSON_TRUE = "{\"ok\":true}";
/// `std.fmt` template for a `{"error":"<msg>"}` JSON body (msg substituted).
const ERR_JSON_FMT = "{{\"error\":\"{s}\"}}";

/// Error set for HTTP handlers in this module. Wide enough to cover
/// every subsystem error that may bubble through `try`: allocator, writer,
/// file IO, BOM resolve, sexpr parser, and httpz form/query parsing.
pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error ||
    std.fs.File.WriteError || std.fs.File.OpenError || std.fs.File.ReadError ||
    std.fs.Dir.MakeError || std.fs.Dir.StatFileError ||
    @import("../bom_resolve.zig").ResolveError ||
    @import("../sexpr/parser.zig").ParseError ||
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
pub fn editValueApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
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
        sendJsonError(ctx, res, 400, ERR_MISSING_REF);
        return;
    };
    const new_value = parseJsonString(body, "\"value\"") orelse {
        sendJsonError(ctx, res, 400, "missing value");
        return;
    };
    const src_off = parseSrcOff(body);

    // Read the .sexp file
    const file_path = paths.designSourcePath(ctx.allocator, ctx.project_dir, name) catch {
        sendJsonError(ctx, res, 500, ERR_CANNOT_READ_FILE);
        return;
    };
    defer ctx.allocator.free(file_path);

    const source = infra_fs.cwd().readFileAlloc(ctx.allocator, file_path, MAX_SOURCE_BYTES) catch {
        sendJsonError(ctx, res, 500, ERR_CANNOT_READ_FILE);
        return;
    };
    defer ctx.allocator.free(source);

    // Locate the enclosing instance form (offset-first → label-robust).
    const inst_open = findInstanceOpen(source, ref_des, src_off) orelse {
        sendJsonError(ctx, res, 404, if (src_off > 0) ERR_GENERATED_PART else ERR_INSTANCE_NOT_FOUND);
        return;
    };
    const inst_end = findFormEnd(source, inst_open) orelse {
        sendJsonError(ctx, res, 400, ERR_MALFORMED_INSTANCE);
        return;
    };

    // Patch the value. Three cases for the component slot inside the instance:
    //  • a family form `(cap-0402 "100nF")` — replace the quoted value in place;
    //  • a *bare* family atom `cap-0402` (what the Add wizard writes when a family
    //    part is added with no value) — wrap it into `(cap-0402 "<value>")` so the
    //    value becomes editable instead of permanently stuck;
    //  • a genuinely fixed component (e.g. `204928-0601`) — nothing to edit.
    var new_source: std.ArrayListUnmanaged(u8) = .empty;
    const nw = new_source.writer(ctx.allocator);
    if (findInstanceValueRange(source, inst_open, inst_end)) |vr| {
        try nw.writeAll(source[0..vr[0]]);
        try nw.writeAll(new_value);
        try nw.writeAll(source[vr[1]..]);
    } else if (findBareComponentRange(source, inst_open, inst_end)) |br| {
        const atom = source[br[0]..br[1]];
        if (!componentIsFamily(ctx.allocator, ctx.project_dir, atom)) {
            sendJsonError(ctx, res, 400, ERR_NO_EDITABLE_VALUE);
            return;
        }
        try nw.writeAll(source[0..br[0]]);
        try nw.print("({s} \"{s}\")", .{ atom, new_value });
        try nw.writeAll(source[br[1]..]);
    } else {
        sendJsonError(ctx, res, 400, ERR_NO_EDITABLE_VALUE);
        return;
    }

    infra_fs.cwd().writeFile(.{ .sub_path = file_path, .data = new_source.items }) catch {
        sendJsonError(ctx, res, 500, ERR_CANNOT_WRITE_FILE);
        return;
    };

    rebuildAndPush(ctx, name, res) catch {
        sendJsonError(ctx, res, 500, ERR_REBUILD_FAILED);
        return;
    };
}

/// Locate the editable value string inside an instance form — the first quoted
/// string of the component family form, e.g. the `100nF` in
/// `(instance "C1" (cap-0402 "100nF") …)`. Returns `{start, end}` (exclusive of
/// the quotes), or null when the part carries a bare/fixed component (nothing to
/// edit) or the form is malformed.
fn findInstanceValueRange(source: []const u8, inst_open: usize, inst_end: usize) ?[2]usize {
    var pos = inst_open + INSTANCE_HEAD.len;
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
    var pos = inst_open + INSTANCE_HEAD.len;
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
    const content = infra_fs.cwd().readFileAlloc(allocator, path, MAX_SOURCE_BYTES) catch return false;
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
    const needle = std.fmt.bufPrint(&buf, INSTANCE_OPEN_TEMPLATE, .{ref}) catch return null;
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
pub fn editFootprintApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
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
    const comp_start_marker = std.mem.indexOf(u8, body, JSON_COMPONENT_KEY) orelse {
        res.status = 400;
        res.body = "missing component";
        return;
    };
    const comp_start = comp_start_marker + JSON_COMPONENT_KEY.len;
    const comp_end = std.mem.indexOfPos(u8, body, comp_start, "\"") orelse {
        res.status = 400;
        return;
    };
    const new_component = body[comp_start..comp_end];

    const old_comp_marker = std.mem.indexOf(u8, body, JSON_OLD_COMPONENT_KEY) orelse {
        res.status = 400;
        res.body = "missing oldComponent";
        return;
    };
    const old_comp_start = old_comp_marker + JSON_OLD_COMPONENT_KEY.len;
    const old_comp_end = std.mem.indexOfPos(u8, body, old_comp_start, "\"") orelse {
        res.status = 400;
        return;
    };
    const old_component = body[old_comp_start..old_comp_end];

    const src_off_marker = std.mem.indexOf(u8, body, JSON_SRC_OFF_KEY) orelse {
        res.status = 400;
        res.body = "missing srcOff";
        return;
    };
    const src_off_num_start = src_off_marker + JSON_SRC_OFF_KEY.len;
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

    // Verify the new component family exists
    const comp_path = std.fmt.allocPrint(ctx.allocator, COMPONENT_PATH_TEMPLATE, .{ ctx.project_dir, new_component }) catch {
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
    const file_path = paths.designSourcePath(ctx.allocator, ctx.project_dir, name) catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(file_path);

    const source = infra_fs.cwd().readFileAlloc(ctx.allocator, file_path, MAX_SOURCE_BYTES) catch {
        res.status = 500;
        res.body = ERR_CANNOT_READ_FILE;
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

    var new_source: std.ArrayListUnmanaged(u8) = .empty;
    const nw = new_source.writer(ctx.allocator);
    try nw.writeAll(source[0..comp_offset]);
    try nw.writeAll(new_component);
    try nw.writeAll(source[comp_offset + old_component.len ..]);

    // Ensure new component is in the import statement
    var final_source = new_source.items;
    if (std.mem.indexOf(u8, final_source, IMPORT_OPEN)) |import_start| {
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
            var new_final: std.ArrayListUnmanaged(u8) = .empty;
            const nfw = new_final.writer(ctx.allocator);
            try nfw.writeAll(final_source[0..import_end]);
            try nfw.writeAll(" ");
            try nfw.writeAll(new_component);
            try nfw.writeAll(final_source[import_end..]);
            final_source = new_final.items;
        }
    }

    const file = infra_fs.cwd().createFile(file_path, .{}) catch {
        res.status = 500;
        res.body = ERR_CANNOT_WRITE_FILE;
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
    const result = eval.evalFile(board_path) catch {
        res.status = 500;
        res.body = ERR_REBUILD_FAILED;
        return;
    };
    const block = switch (result) {
        .design_block => |b| b,
        else => {
            res.status = 500;
            return;
        },
    };

    const bom_path = paths.designSiblingPath(ctx.allocator, ctx.project_dir, name, ".bom") catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(bom_path);
    bom.resolveIdentities(ctx.allocator, block, bom_path, ctx.project_dir) catch |e| warnResolveIdentities(name, e);

    var svg_sym_cache = try bom_html.buildSymbolPinCache(ctx.allocator, ctx.project_dir);

    const new_layout = render_json.renderSceneGraph(ctx.allocator, block, ctx.project_dir) catch null;
    serve_root.setLiveLayoutJson(new_layout);
    _ = serve_root.bumpLiveVersion(name);

    // Return updated COMPONENTS so the client can refresh srcOff values
    var comp_json: std.ArrayListUnmanaged(u8) = .empty;
    const cw = comp_json.writer(ctx.allocator);
    try cw.writeAll("{\"ok\":true,\"components\":{");
    _ = try bom_html.writeComponentsJson(cw, block, "", &svg_sym_cache, ctx.allocator, ctx.project_dir);
    try cw.writeAll("}}");

    res.header(HEADER_CORS_ALLOW_ORIGIN, "*");
    res.content_type = .JSON;
    res.body = comp_json.items;
}

/// POST /api/add-instance/:name
/// Component body: {"section":"Power","component":"cap-0402","value":"100nF","pins":{"1":"VDD","2":"GND"}}
/// Module body:    {"kind":"module","component":"tpsm84338","name":"pwr","args":"(rfbt 220k) (rfbb 47k)"}
/// A module emits a top-level (sub-block "<name>" (<module> <args>)); the
/// section field is ignored for modules (sub-blocks are not evaluated in a section).
pub fn addInstanceApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
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

    const source = infra_fs.cwd().readFileAlloc(ctx.allocator, file_path, MAX_SOURCE_BYTES) catch {
        res.status = 500;
        res.body = ERR_CANNOT_READ_FILE;
        return;
    };
    defer ctx.allocator.free(source);

    // Parse pin assignments from body: "pins":{"1":"VDD","2":"GND"}
    var pin_str: std.ArrayListUnmanaged(u8) = .empty;
    const pw = pin_str.writer(ctx.allocator);
    if (std.mem.indexOf(u8, body, JSON_PINS_KEY)) |pins_start| {
        // Find the opening brace
        var pos = pins_start + JSON_PINS_KEY.len;
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
    var inst_form: std.ArrayListUnmanaged(u8) = .empty;
    const iw = inst_form.writer(ctx.allocator);
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
        try iw.writeAll(pin_str.items);
        try iw.writeAll(")\n");
    }

    // Splice a top-level (import <component>) just before (design-block when the
    // part needs one and it isn't already imported. Everything below operates on
    // this augmented buffer.
    const eff_source: []const u8 = if (want_import and !hasImport(source, component)) blk: {
        const anchor = std.mem.indexOf(u8, source, "(design-block") orelse break :blk source;
        var aug: std.ArrayListUnmanaged(u8) = .empty;
        const aw = aug.writer(ctx.allocator);
        try aw.writeAll(source[0..anchor]);
        try aw.print("{s}{s})\n", .{ IMPORT_OPEN, component });
        try aw.writeAll(source[anchor..]);
        break :blk aug.items;
    } else source;

    // Find insertion point: inside section if specified, otherwise before last closing paren
    var new_source: std.ArrayListUnmanaged(u8) = .empty;
    const nw = new_source.writer(ctx.allocator);

    if (!is_module and section.len > 0) {
        // Find (section "Name" ...) and insert before its closing paren
        const sec_needle = try std.fmt.allocPrint(ctx.allocator, SECTION_OPEN_TEMPLATE, .{section});
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
            try nw.writeAll(inst_form.items);
            try nw.writeAll(eff_source[sec_end..]);
        } else {
            // Section not found, insert at end
            const last_paren = std.mem.lastIndexOfScalar(u8, eff_source, ')') orelse eff_source.len;
            try nw.writeAll(eff_source[0..last_paren]);
            try nw.writeAll("\n");
            try nw.writeAll(inst_form.items);
            try nw.writeAll(eff_source[last_paren..]);
        }
    } else {
        const last_paren = std.mem.lastIndexOfScalar(u8, eff_source, ')') orelse eff_source.len;
        try nw.writeAll(eff_source[0..last_paren]);
        try nw.writeAll("\n");
        try nw.writeAll(inst_form.items);
        try nw.writeAll(eff_source[last_paren..]);
    }

    // Write file
    const file = infra_fs.cwd().createFile(file_path, .{}) catch {
        res.status = 500;
        res.body = ERR_CANNOT_WRITE_FILE;
        return;
    };
    defer file.close();
    file.writeAll(new_source.items) catch {
        res.status = 500;
        return;
    };

    // Rebuild + push live update
    rebuildAndPush(ctx, name, res) catch {
        res.status = 500;
        res.body = ERR_REBUILD_FAILED;
        return;
    };
}

/// POST /api/remove-instance/:name
/// Body: {"ref":"C3"}
pub fn removeInstanceApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
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
        res.body = ERR_MISSING_REF;
        return;
    };

    // Read source file
    const file_path = try paths.designSourcePath(ctx.allocator, ctx.project_dir, name);
    defer ctx.allocator.free(file_path);

    const source = infra_fs.cwd().readFileAlloc(ctx.allocator, file_path, MAX_SOURCE_BYTES) catch {
        res.status = 500;
        res.body = ERR_CANNOT_READ_FILE;
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
        res.body = if (src_off > 0) ERR_GENERATED_PART else ERR_INSTANCE_NOT_FOUND;
        return;
    };
    var inst_end = findFormEnd(source, inst_pos) orelse {
        res.status = 400;
        res.body = ERR_MALFORMED_INSTANCE;
        return;
    };

    // Also eat trailing newline
    if (inst_end < source.len and source[inst_end] == '\n') inst_end += 1;

    // Also eat leading whitespace on the same line
    var inst_start = inst_pos;
    while (inst_start > 0 and (source[inst_start - 1] == ' ' or source[inst_start - 1] == '\t')) : (inst_start -= 1) {}

    var new_source: std.ArrayListUnmanaged(u8) = .empty;
    const nw = new_source.writer(ctx.allocator);
    try nw.writeAll(source[0..inst_start]);
    try nw.writeAll(source[inst_end..]);

    const file = infra_fs.cwd().createFile(file_path, .{}) catch {
        res.status = 500;
        res.body = ERR_CANNOT_WRITE_FILE;
        return;
    };
    defer file.close();
    file.writeAll(new_source.items) catch {
        res.status = 500;
        return;
    };

    std.debug.print("Removed instance {s} from {s}\n", .{ ref_des, name });
    rebuildAndPush(ctx, name, res) catch {
        res.status = 500;
        res.body = ERR_REBUILD_FAILED;
        return;
    };
}

const INSTANCE_HEAD = "(instance";
const PIN_HEAD = "(pin ";

/// Send a JSON `{"error":"…"}` body. `msg` is a trusted static string (no
/// embedded quotes/backslashes) — the frontend's `postEdit` parses the body as
/// JSON, so error paths must speak JSON too (a plaintext body trips its
/// `JSON.parse`, surfacing a cryptic "Unexpected token" to the user).
fn sendJsonError(ctx: *Handler, res: *httpz.Response, status: u16, msg: []const u8) void {
    res.status = status;
    res.content_type = .JSON;
    res.header(HEADER_CORS_ALLOW_ORIGIN, "*");
    res.body = std.fmt.allocPrint(ctx.allocator, ERR_JSON_FMT, .{msg}) catch
        "{\"error\":\"edit failed\"}";
}

/// Parse the optional numeric `"srcOff":N` field (the component-token offset the
/// scene graph publishes as `components[].src`). Returns 0 when absent.
fn parseSrcOff(body: []const u8) usize {
    const m = std.mem.indexOf(u8, body, JSON_SRC_OFF_KEY) orelse return 0;
    var s = m + JSON_SRC_OFF_KEY.len;
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
        if (std.mem.lastIndexOf(u8, source[0..src_off], INSTANCE_HEAD)) |p| {
            // Confirm it opens `(instance "` (not a comment mention) and that
            // src_off really sits inside this instance form.
            var q = p + INSTANCE_HEAD.len;
            while (q < source.len and (source[q] == ' ' or source[q] == '\t')) : (q += 1) {}
            if (q < source.len and source[q] == '"') {
                if (findFormEnd(source, p)) |end| {
                    if (src_off < end) return p;
                }
            }
        }
    }
    var buf: [256]u8 = undefined;
    const needle = std.fmt.bufPrint(&buf, INSTANCE_OPEN_TEMPLATE, .{ref_des}) catch return null;
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
    tokens: *std.ArrayListUnmanaged([]const u8),
) !?PinForm {
    const form_end = findFormEnd(source, form_start) orelse return null;
    var i = form_start + PIN_HEAD.len - 1; // step back over the trailing space
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
    var i = inst_open + INSTANCE_HEAD.len;
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
    out_tokens: *std.ArrayListUnmanaged([]const u8),
) !?PinForm {
    var search = start;
    while (std.mem.indexOfPos(u8, source[0..end], search, PIN_HEAD)) |pf| {
        var tokens: std.ArrayListUnmanaged([]const u8) = .empty;
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
            search = pf + PIN_HEAD.len;
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
    out_tokens: *std.ArrayListUnmanaged([]const u8),
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
pub fn rewirePinApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const body = req.body() orelse {
        sendJsonError(ctx, res, 400, "no body");
        return;
    };

    const ref_des = parseJsonString(body, "\"ref\"") orelse {
        sendJsonError(ctx, res, 400, ERR_MISSING_REF);
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

    const source = infra_fs.cwd().readFileAlloc(ctx.allocator, file_path, MAX_SOURCE_BYTES) catch {
        sendJsonError(ctx, res, 500, ERR_CANNOT_READ_FILE);
        return;
    };
    defer ctx.allocator.free(source);

    // Locate the enclosing instance form (by component-token offset, robust to
    // label-declared instances; ref-des needle as fallback).
    const inst_open = findInstanceOpen(source, ref_des, src_off) orelse {
        sendJsonError(ctx, res, 404, if (src_off > 0) ERR_GENERATED_PART else ERR_INSTANCE_NOT_FOUND);
        return;
    };
    const inst_end = findFormEnd(source, inst_open) orelse {
        sendJsonError(ctx, res, 400, ERR_MALFORMED_INSTANCE);
        return;
    };

    // Find the matching `(pin …)` form — in the instance body or a section-level
    // `(pins "<label>" …)` map — covering single forms AND multi-pin shorthand
    // like `(pin 2 4 6 "VDD")` (which the old `(pin N "` needle could not match).
    var match_tokens: std.ArrayListUnmanaged([]const u8) = .empty;
    defer match_tokens.deinit(ctx.allocator);
    const p = (try findInstancePinForm(ctx.allocator, source, inst_open, inst_end, pin, &match_tokens)) orelse {
        // Pin not declared inline yet — add `(pin <pin> "<net>")` to the instance
        // body. Lets a staged/unwired part (a freshly-added cap with no pins) be
        // connected by dropping it on a net.
        const close = inst_end - 1; // the instance form's closing ')'
        var ins: std.ArrayListUnmanaged(u8) = .empty;
        const iw = ins.writer(ctx.allocator);
        try iw.writeAll(source[0..close]);
        try iw.print("\n    (pin {s} \"{s}\")", .{ pin, new_net });
        try iw.writeAll(source[close..]);
        infra_fs.cwd().writeFile(.{ .sub_path = file_path, .data = ins.items }) catch {
            sendJsonError(ctx, res, 500, ERR_CANNOT_WRITE_FILE);
            return;
        };
        rebuildAndPush(ctx, name, res) catch {
            sendJsonError(ctx, res, 500, ERR_REBUILD_FAILED);
            return;
        };
        return;
    };

    var new_source: std.ArrayListUnmanaged(u8) = .empty;
    const nw = new_source.writer(ctx.allocator);
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
        try nw.writeAll(PIN_HEAD);
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

    infra_fs.cwd().writeFile(.{ .sub_path = file_path, .data = new_source.items }) catch {
        sendJsonError(ctx, res, 500, ERR_CANNOT_WRITE_FILE);
        return;
    };

    rebuildAndPush(ctx, name, res) catch {
        sendJsonError(ctx, res, 500, ERR_REBUILD_FAILED);
        return;
    };
}

/// Bind a bypass/decoupling cap to a specific hub pad: insert (or replace) a
/// `(decouples "IC" PAD)` form inside the instance. The editor calls this when a
/// cap is dropped on a hub pin so the schematic docks it on that pin (via
/// `boundHubPin` in render_svg/context.zig) — instead of whichever hub on a
/// shared net renders first — and the PCB placer keeps it there too. Body:
/// `{"ref":"C4","ic":"U2","pin":"6","srcOff":N}`.
pub fn bindDecoupleApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const body = req.body() orelse {
        sendJsonError(ctx, res, 400, "no body");
        return;
    };

    const ref_des = parseJsonString(body, "\"ref\"") orelse {
        sendJsonError(ctx, res, 400, ERR_MISSING_REF);
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

    const source = infra_fs.cwd().readFileAlloc(ctx.allocator, file_path, MAX_SOURCE_BYTES) catch {
        sendJsonError(ctx, res, 500, ERR_CANNOT_READ_FILE);
        return;
    };
    defer ctx.allocator.free(source);

    const inst_open = findInstanceOpen(source, ref_des, src_off) orelse {
        sendJsonError(ctx, res, 404, if (src_off > 0) ERR_GENERATED_PART else ERR_INSTANCE_NOT_FOUND);
        return;
    };
    const inst_end = findFormEnd(source, inst_open) orelse {
        sendJsonError(ctx, res, 400, ERR_MALFORMED_INSTANCE);
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
    var form: std.ArrayListUnmanaged(u8) = .empty;
    defer form.deinit(ctx.allocator);
    if (numeric)
        try form.writer(ctx.allocator).print("(decouples \"{s}\" {s})", .{ ic, pad })
    else
        try form.writer(ctx.allocator).print("(decouples \"{s}\" \"{s}\")", .{ ic, pad });

    var out: std.ArrayListUnmanaged(u8) = .empty;
    const ow = out.writer(ctx.allocator);

    // Replace an existing (decouples …) in this instance (re-binding to a new
    // pin), else insert one before the instance's closing ')'.
    if (std.mem.indexOfPos(u8, source[0..inst_end], inst_open, "(decouples")) |dpos| {
        const dend = findFormEnd(source, dpos) orelse {
            sendJsonError(ctx, res, 400, "malformed decouples form");
            return;
        };
        try ow.writeAll(source[0..dpos]);
        try ow.writeAll(form.items);
        try ow.writeAll(source[dend..]);
    } else {
        const close = inst_end - 1; // the instance form's closing ')'
        try ow.writeAll(source[0..close]);
        try ow.print("\n    {s}", .{form.items});
        try ow.writeAll(source[close..]);
    }

    infra_fs.cwd().writeFile(.{ .sub_path = file_path, .data = out.items }) catch {
        sendJsonError(ctx, res, 500, ERR_CANNOT_WRITE_FILE);
        return;
    };
    rebuildAndPush(ctx, name, res) catch {
        sendJsonError(ctx, res, 500, ERR_REBUILD_FAILED);
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
pub fn duplicateInstanceApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const body = req.body() orelse {
        sendJsonError(ctx, res, 400, "no body");
        return;
    };
    const ref_des = parseJsonString(body, "\"ref\"") orelse {
        sendJsonError(ctx, res, 400, ERR_MISSING_REF);
        return;
    };
    const src_off = parseSrcOff(body);

    const file_path = try paths.designSourcePath(ctx.allocator, ctx.project_dir, name);
    defer ctx.allocator.free(file_path);
    const source = infra_fs.cwd().readFileAlloc(ctx.allocator, file_path, MAX_SOURCE_BYTES) catch {
        sendJsonError(ctx, res, 500, ERR_CANNOT_READ_FILE);
        return;
    };
    defer ctx.allocator.free(source);

    const inst_open = findInstanceOpen(source, ref_des, src_off) orelse {
        sendJsonError(ctx, res, 404, if (src_off > 0) ERR_GENERATED_PART else ERR_INSTANCE_NOT_FOUND);
        return;
    };
    const inst_end = findFormEnd(source, inst_open) orelse {
        sendJsonError(ctx, res, 400, ERR_MALFORMED_INSTANCE);
        return;
    };

    // Ref string bounds: the first quoted token after "(instance".
    const q1 = std.mem.indexOfScalarPos(u8, source, inst_open, '"') orelse {
        sendJsonError(ctx, res, 400, ERR_MALFORMED_INSTANCE);
        return;
    };
    const q2 = std.mem.indexOfScalarPos(u8, source, q1 + 1, '"') orelse {
        sendJsonError(ctx, res, 400, ERR_MALFORMED_INSTANCE);
        return;
    };
    if (q2 >= inst_end) {
        sendJsonError(ctx, res, 400, ERR_MALFORMED_INSTANCE);
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
    var label_buf: std.ArrayListUnmanaged(u8) = .empty;
    defer label_buf.deinit(ctx.allocator);
    var n: usize = 1;
    while (n < 10000) : (n += 1) {
        label_buf.clearRetainingCapacity();
        const lw = label_buf.writer(ctx.allocator);
        if (n == 1) try lw.print("{s}-copy", .{ref_des}) else try lw.print("{s}-copy{d}", .{ ref_des, n });
        const quoted = std.fmt.allocPrint(ctx.allocator, "\"{s}\"", .{label_buf.items}) catch break;
        defer ctx.allocator.free(quoted);
        if (std.mem.indexOf(u8, source, quoted) == null) break;
    }

    // Assemble: source up to (and including) the original, a blank line, then the
    // clone (ref swapped, id removed), then the rest of the file.
    var out: std.ArrayListUnmanaged(u8) = .empty;
    defer out.deinit(ctx.allocator);
    const ow = out.writer(ctx.allocator);
    try ow.writeAll(source[0..inst_end]);
    try ow.writeAll("\n\n  ");
    try ow.writeAll(source[inst_open .. q1 + 1]); // "(instance \""
    try ow.writeAll(label_buf.items); // new placeholder ref
    try ow.writeAll(source[q2..id_lo]); // "\" <component> <pins> …" up to the id
    try ow.writeAll(source[id_hi..inst_end]); // closing ")" (id removed)
    try ow.writeAll(source[inst_end..]);

    infra_fs.cwd().writeFile(.{ .sub_path = file_path, .data = out.items }) catch {
        sendJsonError(ctx, res, 500, ERR_CANNOT_WRITE_FILE);
        return;
    };
    rebuildAndPush(ctx, name, res) catch {
        sendJsonError(ctx, res, 500, ERR_REBUILD_FAILED);
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
pub fn renameNetApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
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
    const source = infra_fs.cwd().readFileAlloc(ctx.allocator, file_path, MAX_SOURCE_BYTES) catch {
        sendJsonError(ctx, res, 500, ERR_CANNOT_READ_FILE);
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
        sendJsonError(ctx, res, 500, ERR_CANNOT_WRITE_FILE);
        return;
    };
    defer ctx.allocator.free(out);

    infra_fs.cwd().writeFile(.{ .sub_path = file_path, .data = out }) catch {
        sendJsonError(ctx, res, 500, ERR_CANNOT_WRITE_FILE);
        return;
    };
    rebuildAndPush(ctx, name, res) catch {
        sendJsonError(ctx, res, 500, ERR_REBUILD_FAILED);
        return;
    };
}

/// Move a single-pin form `(pin OLD "NET")` to `(pin NEW "NET")` within an
/// instance. Body: `{"ref":"U1","old_pin":"V11","new_pin":"V12"}`. Returns
/// HTTP 409 with a structured error if the destination pin is already used.
pub fn movePinApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    res.content_type = .JSON;
    res.header(HEADER_CORS_ALLOW_ORIGIN, "*");

    const name = req.param("name") orelse {
        res.status = 404;
        res.body = ERR_JSON_MISSING_NAME;
        return;
    };
    const body = req.body() orelse {
        res.status = 400;
        res.body = ERR_JSON_NO_BODY;
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
                res.body = try std.fmt.allocPrint(ctx.allocator, ERR_JSON_FMT, .{@errorName(err)});
                return;
            },
        }
    };

    res.body = try std.fmt.allocPrint(ctx.allocator, "{{\"ok\":true,\"version\":{d}}}", .{result.version});
}

/// Swap the net assignments of two pins on the same instance.
/// Body: `{"ref":"U1","pin_a":"V11","pin_b":"V12"}`.
pub fn swapPinsApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    res.content_type = .JSON;
    res.header(HEADER_CORS_ALLOW_ORIGIN, "*");

    const name = req.param("name") orelse {
        res.status = 404;
        res.body = ERR_JSON_MISSING_NAME;
        return;
    };
    const body = req.body() orelse {
        res.status = 400;
        res.body = ERR_JSON_NO_BODY;
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
                res.body = try std.fmt.allocPrint(ctx.allocator, ERR_JSON_FMT, .{@errorName(err)});
                return;
            },
        }
    };

    res.body = try std.fmt.allocPrint(ctx.allocator, "{{\"ok\":true,\"version\":{d}}}", .{result.version});
}

/// Rebuild design, render SVG, and push live update.
fn rebuildAndPush(ctx: *Handler, name: []const u8, res: *httpz.Response) HandlerError!void {
    const board_path = try paths.designSourcePath(ctx.allocator, ctx.project_dir, name);
    defer ctx.allocator.free(board_path);

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();
    const result = eval.evalFile(board_path) catch return error.RebuildFailed;
    const block = switch (result) {
        .design_block => |b| b,
        else => return error.RebuildFailed,
    };

    const bom_path = try paths.designSiblingPath(ctx.allocator, ctx.project_dir, name, ".bom");
    defer ctx.allocator.free(bom_path);
    bom.resolveIdentities(ctx.allocator, block, bom_path, ctx.project_dir) catch |e| warnResolveIdentities(name, e);

    const layout_json = render_json.renderSceneGraph(ctx.allocator, block, ctx.project_dir) catch null;
    serve_root.setLiveLayoutJson(layout_json);
    _ = serve_root.bumpLiveVersion(name);

    res.header(HEADER_CORS_ALLOW_ORIGIN, "*");
    res.content_type = .JSON;
    res.body = OK_JSON_TRUE;
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
    while (std.mem.indexOfPos(u8, source, from, IMPORT_OPEN)) |p| {
        from = p + IMPORT_OPEN.len;
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

// ── Core mutation API (shared between HTTP handlers and MCP tools) ───────
//
// The `…Core` functions are pure-logic entry points: they take an allocator,
// project dir, design name, and edit args, and return a MutationResult with
// the post-edit live_version. HTTP handlers above still do their own parsing
// and response-shaping; these cores are called by the MCP tool dispatcher
// (see src/serve/mcp.zig). Later, the HTTP handlers can be converted to
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

/// One assertion failure surfaced from the evaluator. `message` is the
/// human-readable text (already formatted by the eval), `is_warning`
/// distinguishes assert-warn from assert.
pub const AssertionFailure = struct {
    message: []const u8,
    is_warning: bool,
};

/// Result of a `build` MCP call. The `version` and `snapshot` mirror the
/// existing MutationResult shape; `eval_ok` is false iff the .sexp failed
/// to parse/evaluate (in which case the JSON viewer state is unchanged).
/// `assertions` and `erc` are summary + flat lists for the agent to act
/// on without a follow-up `run_checks` round-trip.
pub const BuildReport = struct {
    ok: bool,
    version: u32,
    snapshot: ?[]const u8 = null,
    eval_ok: bool,
    error_message: ?[]const u8 = null,
    /// Source-located diagnostic for a failed eval — file:line:col, the
    /// evaluator's message, and the offending source line. Null on success
    /// or when no span was recorded.
    diagnostic: ?diag_format.Diagnostic = null,
    assertion_failures: []const AssertionFailure = &.{},
    erc: []const erc_mod.Violation = &.{},
};

fn designFilePath(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8) ![]u8 {
    return paths.designSourcePath(allocator, project_dir, name);
}

/// Re-evaluate `<name>.sexp`, resolve BOM, render the scene-graph, run
/// ERC, snapshot the prior state, and bump the live version. This is the
/// MCP `build` tool's worker — it mirrors `netlisp build --push <name>`
/// locally. The agent edits files via VFS, then calls this to make
/// changes visible in the browser viewer.
pub fn rebuildDesign(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
) BuildReport {
    const path = designFilePath(allocator, project_dir, name) catch {
        return .{
            .ok = false,
            .version = serve_root.getLiveVersion(name),
            .eval_ok = false,
            .error_message = "out of memory",
        };
    };
    defer allocator.free(path);

    // Snapshot first so the build is undoable via restore_version. Logs
    // and continues on snapshot errors — undo is a nice-to-have.
    const snap_id: ?[]const u8 = history.snapshot(allocator, project_dir, name, "build") catch |e| blk: {
        log.warn("[snapshot] failed for {s}: {s}", .{ name, @errorName(e) });
        break :blk null;
    };

    var eval = Evaluator.init(allocator, project_dir);
    defer eval.deinit();
    const eval_result = eval.evalFile(path) catch |e| {
        // Resolve the span into a full diagnostic (re-reads the file so the
        // shown line matches what the agent just wrote). The human-readable
        // error_message becomes the compiler-style text when a span exists.
        const d: ?diag_format.Diagnostic = diag_format.load(allocator, path, @errorName(e), eval.last_error) catch null;
        const msg: []const u8 = if (d) |dd|
            (diag_format.formatText(allocator, dd) catch @errorName(e))
        else
            @errorName(e);
        return .{
            .ok = false,
            .version = serve_root.getLiveVersion(name),
            .snapshot = snap_id,
            .eval_ok = false,
            .error_message = msg,
            .diagnostic = d,
        };
    };
    const block = switch (eval_result) {
        .design_block => |b| b,
        // Not a top-level design — `name` may be a bare `lib/modules/<name>`
        // module file (where `evalFile` ran the `(defmodule …)` → .nil and
        // registered it). Instantiate it standalone via its parameter
        // defaults so a module rebuilds/pushes the same as a design.
        else => blk: {
            const mres = eval_modules.instantiateStandalone(&eval, name) catch {
                return .{
                    .ok = false,
                    .version = serve_root.getLiveVersion(name),
                    .snapshot = snap_id,
                    .eval_ok = false,
                    .error_message = "not a design-block",
                };
            };
            break :blk switch (mres) {
                .design_block => |b| b,
                else => return .{
                    .ok = false,
                    .version = serve_root.getLiveVersion(name),
                    .snapshot = snap_id,
                    .eval_ok = false,
                    .error_message = "not a design-block",
                },
            };
        },
    };

    var failures: std.ArrayListUnmanaged(AssertionFailure) = .empty;
    for (eval.assertions.items) |a| {
        if (a.passed) continue;
        failures.append(allocator, .{ .message = a.message, .is_warning = a.is_warning }) catch break;
    }

    const bom_path = paths.designSiblingPath(allocator, project_dir, name, ".bom") catch {
        return .{
            .ok = false,
            .version = serve_root.getLiveVersion(name),
            .snapshot = snap_id,
            .eval_ok = true,
            .error_message = "out of memory (bom path)",
            .assertion_failures = failures.items,
        };
    };
    defer allocator.free(bom_path);
    bom.resolveIdentities(allocator, block, bom_path, project_dir) catch |e| warnResolveIdentities(name, e);

    const layout_json = render_json.renderSceneGraph(allocator, block, project_dir) catch null;
    serve_root.setLiveLayoutJson(layout_json);
    const version = serve_root.bumpLiveVersion(name);

    const erc_violations = erc_mod.runErc(allocator, block, project_dir) catch &[_]erc_mod.Violation{};

    return .{
        .ok = true,
        .version = version,
        .snapshot = snap_id,
        .eval_ok = true,
        .assertion_failures = failures.items,
        .erc = erc_violations,
    };
}

fn readDesignSource(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8) EditError![]u8 {
    const path = try designFilePath(allocator, project_dir, name);
    defer allocator.free(path);
    return infra_fs.cwd().readFileAlloc(allocator, path, MAX_SOURCE_BYTES) catch return error.CannotReadDesign;
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
    serve_root.setLiveLayoutJson(layout_json);
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
    std.fs.File.OpenError ||
    std.fs.File.ReadError ||
    std.fs.File.WriteError ||
    error{ FileTooBig, StreamTooLong, EndOfStream };

/// Update MPN and/or manufacturer for `ref_des` in the `.bom` sidecar.
/// Empty string for either field leaves that field untouched (so callers
/// can patch one or both in a single call). Bumps the live version so the
/// browser's poll picks up the change. Shared between the HTTP
/// `editMpnApi` and the MCP `edit_mpn` tool.
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

    if (mpn.len > 0) try bom_resolve.setBomProperty(allocator, bom_path, ref_des, "mpn", mpn);
    if (manufacturer.len > 0) try bom_resolve.setBomProperty(allocator, bom_path, ref_des, "manufacturer", manufacturer);

    return serve_root.bumpLiveVersion(name);
}

/// POST /api/edit-mpn/:name — body `{"ref":"R1","mpn":"…","manufacturer":"…"}`.
/// Either the `mpn` or `manufacturer` field may be omitted; only the present
/// ones are persisted. Persists to the `.bom` sidecar and bumps the live
/// version. Returns `{"ok":true,"version":N}`.
pub fn editMpnApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = HTTP_NOT_FOUND;
        return;
    };
    const body = req.body() orelse {
        res.status = HTTP_BAD_REQUEST;
        res.body = ERR_JSON_NO_BODY;
        return;
    };

    // ref is required.
    const ref_start = std.mem.indexOf(u8, body, JSON_REF_KEY) orelse {
        res.status = HTTP_BAD_REQUEST;
        res.body = ERR_MISSING_REF;
        return;
    };
    const ref_val_start = ref_start + JSON_REF_KEY.len;
    const ref_end = std.mem.indexOfPos(u8, body, ref_val_start, "\"") orelse {
        res.status = HTTP_BAD_REQUEST;
        return;
    };
    const ref_des = body[ref_val_start..ref_end];

    // mpn + manufacturer are optional (empty string = leave alone).
    const mpn = parseOptionalStringField(body, "\"mpn\":\"");
    const manufacturer = parseOptionalStringField(body, "\"manufacturer\":\"");

    if (mpn.len == 0 and manufacturer.len == 0) {
        res.status = HTTP_BAD_REQUEST;
        res.body = "no fields to update";
        return;
    }

    const version = editMpnCore(ctx.allocator, ctx.project_dir, name, ref_des, mpn, manufacturer) catch |e| {
        log.warn("editMpn {s} {s}: {s}", .{ name, ref_des, @errorName(e) });
        res.status = HTTP_INTERNAL_ERROR;
        res.body = "{\"ok\":false}";
        return;
    };

    res.header(HEADER_CORS_ALLOW_ORIGIN, "*");
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
    const block = switch (result) {
        .design_block => |b| b,
        // Module file (`lib/modules/<name>.sexp`) — see writeAndRebuild.
        else => return .{ .version = serve_root.bumpLiveVersion(name), .snapshot = pre_snap },
    };

    const bom_path = paths.designSiblingPath(allocator, project_dir, name, ".bom") catch return error.OutOfMemory;
    defer allocator.free(bom_path);
    bom.resolveIdentities(allocator, block, bom_path, project_dir) catch |e| warnResolveIdentities(name, e);

    const layout_json = render_json.renderSceneGraph(allocator, block, project_dir) catch null;
    serve_root.setLiveLayoutJson(layout_json);
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

    const needle = try std.fmt.allocPrint(allocator, SECTION_OPEN_TEMPLATE, .{section_name});
    defer allocator.free(needle);
    const sec_start = std.mem.indexOf(u8, source, needle) orelse return error.SectionNotFound;
    if (std.mem.indexOfPos(u8, source, sec_start + needle.len, needle) != null) return error.AmbiguousMatch;
    const sec_end = findFormEnd(source, sec_start) orelse return error.MalformedSource;
    const insert_at = sec_end - 1;

    // Indent heuristic: match the first non-whitespace sibling inside the
    // section body so new notes sit alongside existing forms.
    const indent = detectSectionIndent(source, sec_start);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
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
    return writeAndRebuild(allocator, project_dir, name, buf.items, desc);
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

    const needle = try std.fmt.allocPrint(allocator, SECTION_OPEN_TEMPLATE, .{section_name});
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

                    var buf: std.ArrayListUnmanaged(u8) = .empty;
                    defer buf.deinit(allocator);
                    const w = buf.writer(allocator);
                    try w.writeAll(source[0..trim_start]);
                    try w.writeAll(source[trim_end..]);

                    const desc = try std.fmt.allocPrint(allocator, "remove_section_note {s}[{d}]", .{ section_name, idx });
                    defer allocator.free(desc);
                    return writeAndRebuild(allocator, project_dir, name, buf.items, desc);
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

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll(source[0..trim_start]);
    try w.writeAll(source[trim_end..]);

    try writeLibComponent(path, buf.items);
    const version = serve_root.bumpLiveVersion(component_name);
    return .{ .version = version, .snapshot = null };
}

fn libComponentPath(allocator: std.mem.Allocator, project_dir: []const u8, component_name: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, COMPONENT_PATH_TEMPLATE, .{ project_dir, component_name });
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
    out: *std.ArrayListUnmanaged(PinRegion),
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

    var regions: std.ArrayListUnmanaged(PinRegion) = .empty;
    defer regions.deinit(allocator);
    try collectPinRegions(allocator, source, ref_des, &regions);
    if (regions.items.len == 0) return error.InstanceNotFound;

    if (findPinTokenInRegions(source, regions.items, new_pin) != null) return error.PinAlreadyAssigned;
    const old_loc = findPinTokenInRegions(source, regions.items, old_pin) orelse return error.PinNotFound;

    var new_source: std.ArrayListUnmanaged(u8) = .empty;
    defer new_source.deinit(allocator);
    const nw = new_source.writer(allocator);
    try nw.writeAll(source[0..old_loc.start]);
    try nw.writeAll(new_pin);
    try nw.writeAll(source[old_loc.end..]);

    const desc = try std.fmt.allocPrint(allocator, "move_pin {s}.{s} → {s}", .{ ref_des, old_pin, new_pin });
    defer allocator.free(desc);
    return writeAndRebuild(allocator, project_dir, name, new_source.items, desc);
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

    var regions: std.ArrayListUnmanaged(PinRegion) = .empty;
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

    var new_source: std.ArrayListUnmanaged(u8) = .empty;
    defer new_source.deinit(allocator);
    const nw = new_source.writer(allocator);
    try nw.writeAll(source[0..first_start]);
    try nw.writeAll(first_replace);
    try nw.writeAll(source[first_end..second_start]);
    try nw.writeAll(second_replace);
    try nw.writeAll(source[second_end..]);

    const desc = try std.fmt.allocPrint(allocator, "swap_pins {s}.{s} <-> {s}", .{ ref_des, pin_a, pin_b });
    defer allocator.free(desc);
    return writeAndRebuild(allocator, project_dir, name, new_source.items, desc);
}

/// GET /api/source/:name — returns `{"source":"<raw .sexp text>"}`.
pub fn getSourceApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    res.content_type = .JSON;
    res.header(HEADER_CORS_ALLOW_ORIGIN, "*");

    const name = req.param("name") orelse {
        res.status = 404;
        res.body = ERR_JSON_MISSING_NAME;
        return;
    };

    const source = readDesignSource(ctx.allocator, ctx.project_dir, name) catch {
        res.status = 404;
        res.body = "{\"error\":\"cannot read design\"}";
        return;
    };
    defer ctx.allocator.free(source);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(ctx.allocator);
    try w.writeAll("{\"source\":\"");
    try bom_html.writeJsonEscaped(w, source);
    try w.writeAll("\"}");
    res.body = buf.items;
}

/// POST /api/source/:name — body `{"source":"<raw .sexp text>"}`. Validates
/// syntax, writes the file, rebuilds, bumps version. Returns
/// `{"ok":true,"version":N,"snapshot":...}` on success or
/// `{"ok":false,"error":"..."}` with HTTP 400 on invalid source.
pub fn saveSourceApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    res.content_type = .JSON;
    res.header(HEADER_CORS_ALLOW_ORIGIN, "*");

    const name = req.param("name") orelse {
        res.status = 404;
        res.body = ERR_JSON_MISSING_NAME;
        return;
    };
    const body = req.body() orelse {
        res.status = 400;
        res.body = ERR_JSON_NO_BODY;
        return;
    };

    const parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, body, .{}) catch {
        res.status = 400;
        res.body = "{\"ok\":false,\"error\":\"invalid json\"}";
        return;
    };
    defer parsed.deinit();
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

    var out: std.ArrayListUnmanaged(u8) = .empty;
    const w = out.writer(ctx.allocator);
    try w.print("{{\"ok\":true,\"version\":{d},\"snapshot\":", .{result.version});
    if (result.snapshot) |s| {
        try w.writeAll("\"");
        try bom_html.writeJsonEscaped(w, s);
        try w.writeAll("\"");
    } else {
        try w.writeAll("null");
    }
    try w.writeAll("}");
    res.body = out.items;
}

// ── Tests ─────────────────────────────────────────────────────────

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
    var toks: std.ArrayListUnmanaged([]const u8) = .empty;
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
    var toks: std.ArrayListUnmanaged([]const u8) = .empty;
    defer toks.deinit(a);
    // Not in the (tiny) instance body, but in the section's (pins "stm32" …) map.
    const m = (try findInstancePinForm(a, src, inst_open, inst_end, "W16", &toks)).?;
    try std.testing.expectEqualStrings("OLDNET", src[m.net_start..m.net_end]);
    try std.testing.expectEqual(@as(usize, 1), toks.items.len);
    // A pin that exists nowhere stays unmatched.
    toks.clearRetainingCapacity();
    try std.testing.expect((try findInstancePinForm(a, src, inst_open, inst_end, "ZZ9", &toks)) == null);
}
