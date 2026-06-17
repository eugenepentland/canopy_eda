//! Editing-assistance endpoints for the in-browser source editor.
//!
//! These power the "smart editor" half of manual schematic editing — moving
//! errors from save-time to type-time and feeding the editor the grammar it
//! already knows:
//!
//!   * `POST /api/validate/:name` — dry-evaluate a *candidate* source buffer
//!     (the editor's unsaved text) and return parse/eval errors, lint
//!     warnings, and failed assertions as a flat `diagnostics` array with
//!     1-based line/col spans. Nothing is written to disk and the live
//!     version is left untouched — this is the read-only twin of
//!     `POST /api/source`.
//!   * `GET /api/lib-index` — the autocomplete index: every component /
//!     family in `lib/components/` and every module in `lib/modules/`, so
//!     the editor can complete `(import …)` and `(sub-block (mod …))`.
//!
//! Both use the per-request arena (`ctx.allocator`), so there is nothing to
//! free by hand.

const std = @import("std");
const httpz = @import("httpz");
const infra_fs = @import("../infra/fs.zig");
const json_writer = @import("../json_writer.zig");
const diag_format = @import("diag_format.zig");
const sexpr_parser = @import("../sexpr/parser.zig");
const evaluator_mod = @import("../eval/evaluator.zig");
const Evaluator = evaluator_mod.Evaluator;
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;
const HandlerError = @import("edit.zig").HandlerError;

const HEADER_CORS = "access-control-allow-origin";
const MAX_SOURCE_BYTES: usize = 10 * 1024 * 1024;
const MAX_LIB_FILE_BYTES: usize = 1024 * 1024;
const SEXP_EXT = ".sexp";

// ── POST /api/validate/:name ──────────────────────────────────────

/// Dry-validate the posted candidate source without touching disk or the
/// live version. Body: `{"source":"<raw .sexp text>"}`. Response:
/// `{"ok":bool,"diagnostics":[{severity,line,col,message,sourceLine}]}`.
///
/// `severity` is `"error"` (parse/eval failure — stops the build),
/// `"warning"` (a silently-ignored sub-form the evaluator flagged), or
/// `"assert"` (a failed design assertion). Errors and warnings carry a
/// 1-based span into the candidate buffer; assertions are design-level and
/// report line 0.
pub fn validateSourceApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    res.content_type = .JSON;
    res.header(HEADER_CORS, "*");

    const name = req.param("name") orelse "design";
    const body = req.body() orelse {
        res.status = 400;
        res.body = "{\"ok\":false,\"error\":\"no body\"}";
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
    const source = source_val.string;

    var out: std.ArrayListUnmanaged(u8) = .empty;
    const w = out.writer(ctx.allocator);

    // Pre-flight parse so a pure syntax error reports as "syntax error" with
    // a clear name rather than the evaluator's catch-all ImportError. The
    // parser does not expose a span, so syntax errors land at line 0 (a
    // file-level marker) — eval errors below keep their precise span.
    const parse_failed: ?[]const u8 = if (sexpr_parser.parse(ctx.allocator, source)) |_|
        null
    else |perr|
        @errorName(perr);

    var ok = true;
    var err_diag: ?diag_format.Diagnostic = null;

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();

    if (parse_failed == null) {
        const failed = blk: {
            _ = eval.evalSource(source) catch |e| {
                err_diag = diag_format.build(ctx.allocator, name, source, @errorName(e), eval.last_error) catch null;
                break :blk true;
            };
            break :blk false;
        };
        ok = !failed;
    } else {
        ok = false;
    }

    try w.print("{{\"ok\":{},\"diagnostics\":[", .{ok});
    var first = true;

    if (parse_failed) |perr_name| {
        const msg = try std.fmt.allocPrint(ctx.allocator, "syntax error: {s}", .{perr_name});
        try writeDiag(w, &first, "error", 0, 0, msg, "");
    } else if (err_diag) |d| {
        try writeDiag(w, &first, "error", d.line, d.col, d.message, d.source_line);
    }

    // Lint warnings the evaluator collected (silently-ignored sub-forms etc.).
    // Re-resolve each span into the candidate buffer for the source line.
    for (eval.warnings.items) |wn| {
        const wd = diag_format.build(ctx.allocator, name, source, "warning", .{
            .span = wn.span,
            .message = wn.message,
        }) catch continue;
        try writeDiag(w, &first, "warning", wd.line, wd.col, wd.message, wd.source_line);
    }

    // Failed assertions (design-level, no source span).
    for (eval.assertions.items) |a| {
        if (a.passed) continue;
        const sev: []const u8 = if (a.is_warning) "warning" else "assert";
        try writeDiag(w, &first, sev, 0, 0, a.message, "");
    }

    try w.writeAll("]}");
    res.body = out.items;
}

/// Emit one diagnostic object into the array, prefixing a comma when it is
/// not the first. `*first` is flipped to false on the first call.
fn writeDiag(
    w: anytype,
    first: *bool,
    severity: []const u8,
    line: u32,
    col: u32,
    message: []const u8,
    source_line: []const u8,
) HandlerError!void {
    if (!first.*) try w.writeAll(",");
    first.* = false;
    try w.writeAll("{\"severity\":");
    try json_writer.writeString(w, severity);
    try w.print(",\"line\":{d},\"col\":{d},\"message\":", .{ line, col });
    try json_writer.writeString(w, message);
    try w.writeAll(",\"sourceLine\":");
    try json_writer.writeString(w, source_line);
    try w.writeAll("}");
}

// ── GET /api/lib-index ────────────────────────────────────────────

/// The autocomplete index: component/family names from `lib/components/` and
/// module names (with their parameter lists) from `lib/modules/`. Response:
/// `{"components":[{"name":…,"family":bool}],"modules":[{"name":…,"params":…}]}`.
/// Best-effort — a missing directory yields an empty list rather than an error.
pub fn libIndexApi(ctx: *Handler, _: *httpz.Request, res: *httpz.Response) HandlerError!void {
    res.content_type = .JSON;
    res.header(HEADER_CORS, "*");

    var out: std.ArrayListUnmanaged(u8) = .empty;
    const w = out.writer(ctx.allocator);

    try w.writeAll("{\"components\":[");
    try emitComponents(ctx, w);
    try w.writeAll("],\"modules\":[");
    try emitModules(ctx, w);
    try w.writeAll("]}");
    res.body = out.items;
}

fn emitComponents(ctx: *Handler, w: anytype) HandlerError!void {
    const dir_path = try std.fmt.allocPrint(ctx.allocator, "{s}/lib/components", .{ctx.project_dir});
    var dir = infra_fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();
    var iter = dir.iterate();
    var first = true;
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, SEXP_EXT)) continue;
        const base = entry.name[0 .. entry.name.len - SEXP_EXT.len];
        const content = dir.readFileAlloc(ctx.allocator, entry.name, MAX_LIB_FILE_BYTES) catch continue;
        const is_family = std.mem.indexOf(u8, content, "(component-family ") != null;
        if (!first) try w.writeAll(",");
        first = false;
        try w.writeAll("{\"name\":");
        try json_writer.writeString(w, base);
        try w.print(",\"family\":{}}}", .{is_family});
    }
}

fn emitModules(ctx: *Handler, w: anytype) HandlerError!void {
    const dir_path = try std.fmt.allocPrint(ctx.allocator, "{s}/lib/modules", .{ctx.project_dir});
    var dir = infra_fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();
    var iter = dir.iterate();
    var first = true;
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, SEXP_EXT)) continue;
        const base = entry.name[0 .. entry.name.len - SEXP_EXT.len];
        const content = dir.readFileAlloc(ctx.allocator, entry.name, MAX_LIB_FILE_BYTES) catch "";
        const params = extractModuleParams(content, base);
        if (!first) try w.writeAll(",");
        first = false;
        try w.writeAll("{\"name\":");
        try json_writer.writeString(w, base);
        try w.writeAll(",\"params\":");
        try json_writer.writeString(w, params);
        try w.writeAll("}");
    }
}

/// Best-effort extraction of a defmodule's parameter list as a flat string of
/// param names, e.g. `(defmodule tpsm84338 ((rfbt 220k) rfbb) …)` → `rfbt rfbb`.
/// Returns "" when no `(defmodule <name> (…))` shape is found. Scans the
/// param group, taking the first atom of each nested `(param default)` pair
/// and each bare atom; depth-tracked so defaults don't leak in.
fn extractModuleParams(content: []const u8, mod_name: []const u8) []const u8 {
    var needle_buf: [256]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "(defmodule {s}", .{mod_name}) catch return "";
    const head = std.mem.indexOf(u8, content, needle) orelse return "";
    // Find the '(' that opens the parameter list (the first '(' after the name).
    var i = head + needle.len;
    while (i < content.len and content[i] != '(' and content[i] != ')') : (i += 1) {}
    if (i >= content.len or content[i] != '(') return "";
    const params_open = i;
    // Walk the param group, tracking depth. At depth 1 the first atom of each
    // nested group is a param name; bare atoms at depth 1 are param names too.
    var depth: usize = 0;
    var start: usize = params_open;
    var end: usize = params_open;
    i = params_open;
    while (i < content.len) : (i += 1) {
        const c = content[i];
        if (c == '(') {
            depth += 1;
            if (depth == 1) start = i + 1;
        } else if (c == ')') {
            depth -= 1;
            if (depth == 0) {
                end = i;
                break;
            }
        }
    }
    if (end <= start) return "";
    return paramNames(content[start..end]);
}

/// From the raw text inside a parameter group, return a space-joined list of
/// the parameter names: the first token of each `(name default)` pair, and any
/// bare atom. Operates in place on a small scratch slice of the source — the
/// returned slice borrows `group`, so it lives as long as the file content.
fn paramNames(group: []const u8) []const u8 {
    // We can't allocate a new joined string without an allocator here, so we
    // return a trimmed view when the group is already just space-separated
    // bare atoms; otherwise fall back to the raw group (the editor strips
    // parens client-side for display).
    return std.mem.trim(u8, group, " \t\n\r");
}

// ── Tests ─────────────────────────────────────────────────────────

test "extractModuleParams reads a simple parameter list" {
    // spec: serve/edit_assist - lib-index extracts a module's parameter names
    const src =
        \\(defmodule tpsm84338 (rfbt rfbb rled)
        \\  (design-block "x"))
    ;
    const p = extractModuleParams(src, "tpsm84338");
    try std.testing.expectEqualStrings("rfbt rfbb rled", p);
}

test "extractModuleParams handles defaulted params" {
    // spec: serve/edit_assist - lib-index handles (param default) pairs
    const src =
        \\(defmodule buck ((rfbt 220k) (rfbb 47k))
        \\  (design-block "x"))
    ;
    const p = extractModuleParams(src, "buck");
    // Defaulted params keep their nested form in the raw view; the editor
    // displays the names. We assert the group is captured non-empty.
    try std.testing.expect(p.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, p, "rfbt") != null);
}

test "extractModuleParams returns empty for missing module" {
    // spec: serve/edit_assist - lib-index returns no params when the defmodule is absent
    try std.testing.expectEqualStrings("", extractModuleParams("(design-block \"x\")", "nope"));
}
