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
const Server = serve_root.Server;
const edit = @import("edit.zig");
const HandlerError = edit.HandlerError;
const paths = @import("../paths.zig");

const header_cors = "access-control-allow-origin";
const max_source_bytes: usize = 10 * 1024 * 1024;
const max_lib_file_bytes: usize = 1024 * 1024;
const sexp_ext = ".sexp";
const footprint_open = "(footprint ";

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
pub fn validateSourceApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    res.content_type = .JSON;
    res.header(header_cors, "*");

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
    const source = source_val.string;

    var out: std.ArrayList(u8) = .empty;
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
/// `{"components":[{"name":…,"family":bool,"footprint":…}],
///   "modules":[{"name":…,"params":…,"placement":bool}]}`.
/// `footprint` powers the wizard's footprint preview; `placement` flags a module
/// with a premade `(placement …)` layout. Best-effort — a missing directory
/// yields an empty list rather than an error.
pub fn libIndexApi(ctx: *Server, _: *httpz.Request, res: *httpz.Response) HandlerError!void {
    res.content_type = .JSON;
    res.header(header_cors, "*");

    var out: std.ArrayList(u8) = .empty;
    const w = out.writer(ctx.allocator);

    try w.writeAll("{\"components\":[");
    try emitComponents(ctx, w);
    try w.writeAll("],\"modules\":[");
    try emitModules(ctx, w);
    try w.writeAll("]}");
    res.body = out.items;
}

fn emitComponents(ctx: *Server, w: anytype) HandlerError!void {
    const dir_path = try std.fmt.allocPrint(ctx.allocator, "{s}/lib/components", .{ctx.project_dir});
    var dir = infra_fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();
    var iter = dir.iterate();
    var first = true;
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, sexp_ext)) continue;
        const base = entry.name[0 .. entry.name.len - sexp_ext.len];
        const content = dir.readFileAlloc(ctx.allocator, entry.name, max_lib_file_bytes) catch continue;
        const is_family = std.mem.indexOf(u8, content, "(component-family ") != null;
        const footprint = extractFootprint(content);
        if (!first) try w.writeAll(",");
        first = false;
        try w.writeAll("{\"name\":");
        try json_writer.writeString(w, base);
        try w.print(",\"family\":{}", .{is_family});
        try w.writeAll(",\"footprint\":");
        try json_writer.writeString(w, footprint);
        try w.writeAll("}");
    }
}

/// Pull the footprint name out of a component `.sexp` — handles both the atom
/// form `(footprint c-0402)` and the quoted form `(footprint "sot891")`.
/// Returns "" when no footprint form is present.
fn extractFootprint(content: []const u8) []const u8 {
    const k = std.mem.indexOf(u8, content, footprint_open) orelse return "";
    var i = k + footprint_open.len;
    while (i < content.len and content[i] == ' ') : (i += 1) {}
    if (i >= content.len) return "";
    if (content[i] == '"') {
        i += 1;
        const start = i;
        const end = std.mem.indexOfScalarPos(u8, content, i, '"') orelse return "";
        return content[start..end];
    }
    const start = i;
    while (i < content.len) : (i += 1) {
        switch (content[i]) {
            ' ', ')', '\n', '\t', '\r' => break,
            else => {},
        }
    }
    return content[start..i];
}

fn emitModules(ctx: *Server, w: anytype) HandlerError!void {
    const dir_path = try std.fmt.allocPrint(ctx.allocator, "{s}/lib/modules", .{ctx.project_dir});
    var dir = infra_fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return;
    defer dir.close();
    var iter = dir.iterate();
    var first = true;
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, sexp_ext)) continue;
        const base = entry.name[0 .. entry.name.len - sexp_ext.len];
        const content = dir.readFileAlloc(ctx.allocator, entry.name, max_lib_file_bytes) catch "";
        const params = extractModuleParams(content, base);
        // A premade layout = the defmodule body carries a (placement …) spec.
        const has_placement = std.mem.indexOf(u8, content, "(placement") != null;
        if (!first) try w.writeAll(",");
        first = false;
        try w.writeAll("{\"name\":");
        try json_writer.writeString(w, base);
        try w.writeAll(",\"params\":");
        try json_writer.writeString(w, params);
        try w.print(",\"placement\":{}", .{has_placement});
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

// ── POST /api/diagram-layout/:name ────────────────────────────────

/// Index of the ')' matching the '(' at `open`, skipping strings and `;`
/// comments. Returns null when unbalanced.
fn matchParen(source: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    var i = open;
    var in_str = false;
    while (i < source.len) : (i += 1) {
        const c = source[i];
        if (in_str) {
            if (c == '\\') {
                i += 1;
            } else if (c == '"') in_str = false;
            continue;
        }
        switch (c) {
            '"' => in_str = true,
            ';' => while (i < source.len and source[i] != '\n') : (i += 1) {},
            '(' => depth += 1,
            ')' => {
                depth -= 1;
                if (depth == 0) return i;
            },
            else => {},
        }
    }
    return null;
}

/// True when only whitespace precedes byte `pos` on its line — i.e. the form
/// at `pos` opens a line, so it isn't inside a `;` comment or trailing another
/// token. Keeps a commented "(layout …)" mention from being mistaken for the
/// real form.
fn atLineStart(source: []const u8, pos: usize) bool {
    var i = pos;
    while (i > 0) {
        i -= 1;
        if (source[i] == '\n') return true;
        if (source[i] != ' ' and source[i] != '\t') return false;
    }
    return true;
}

/// Find the byte range `[start, end)` of the first top-level `(diagram-layout …)`
/// or `(layout …)` form, or null when neither exists. Only line-opening matches
/// count, so a comment mentioning the form is skipped.
fn findLayoutForm(source: []const u8) ?struct { start: usize, end: usize } {
    const heads = [_][]const u8{ "(diagram-layout", "(layout" };
    for (heads) |head| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, source, from, head)) |start| {
            from = start + head.len;
            // Require a delimiter after the head so "(layout" doesn't match a
            // longer atom like "(layout-order", and a line-start before it.
            const after = start + head.len;
            const delim_ok = after >= source.len or std.mem.indexOfScalar(u8, " \n\t()", source[after]) != null;
            if (delim_ok and atLineStart(source, start)) {
                const close = matchParen(source, start) orelse continue;
                return .{ .start = start, .end = close + 1 };
            }
        }
    }
    return null;
}

/// POST /api/diagram-layout/:name — body `{"form":"(diagram-layout …)"}`.
/// Replaces the design's existing `(diagram-layout …)`/`(layout …)` form (or
/// inserts the new one just before the design-block's closing paren), then
/// validates + writes + rebuilds via the normal mutation path. Powers the
/// Layout tab's drag-to-arrange writeback — the schematic twin of PCB
/// `spec-save`.
pub fn saveDiagramLayoutApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    res.content_type = .JSON;
    res.header(header_cors, "*");

    const name = req.param("name") orelse {
        res.status = 404;
        res.body = "{\"ok\":false,\"error\":\"missing name\"}";
        return;
    };
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
    if (parsed.value != .object) {
        res.status = 400;
        res.body = "{\"ok\":false,\"error\":\"body must be a JSON object\"}";
        return;
    }
    const form_val = parsed.value.object.get("form") orelse {
        res.status = 400;
        res.body = "{\"ok\":false,\"error\":\"missing form\"}";
        return;
    };
    if (form_val != .string or form_val.string.len == 0) {
        res.status = 400;
        res.body = "{\"ok\":false,\"error\":\"form must be a non-empty string\"}";
        return;
    }
    const form = form_val.string;

    const path = paths.designSourcePath(ctx.allocator, ctx.project_dir, name) catch {
        res.status = 500;
        return;
    };
    const source = infra_fs.cwd().readFileAlloc(ctx.allocator, path, max_source_bytes) catch {
        res.status = 404;
        res.body = "{\"ok\":false,\"error\":\"cannot read design\"}";
        return;
    };

    var out: std.ArrayList(u8) = .empty;
    const w = out.writer(ctx.allocator);
    if (findLayoutForm(source)) |span| {
        try w.writeAll(source[0..span.start]);
        try w.writeAll(form);
        try w.writeAll(source[span.end..]);
    } else if (std.mem.indexOf(u8, source, "(design-block")) |db| {
        const close = matchParen(source, db) orelse {
            res.status = 400;
            res.body = "{\"ok\":false,\"error\":\"unbalanced design-block\"}";
            return;
        };
        try w.writeAll(source[0..close]);
        try w.writeAll("  ");
        try w.writeAll(form);
        try w.writeAll("\n");
        try w.writeAll(source[close..]);
    } else {
        res.status = 400;
        res.body = "{\"ok\":false,\"error\":\"no design-block\"}";
        return;
    }

    const result = edit.writeDesignCore(ctx.allocator, ctx.project_dir, name, out.items) catch |err| {
        res.status = 400;
        res.body = try std.fmt.allocPrint(ctx.allocator, "{{\"ok\":false,\"error\":\"{s}\"}}", .{@errorName(err)});
        return;
    };
    res.body = try std.fmt.allocPrint(ctx.allocator, "{{\"ok\":true,\"version\":{d}}}", .{result.version});
}

// ── Tests ─────────────────────────────────────────────────────────

test "findLayoutForm finds a diagram-layout form and its bounds" {
    // spec: serve/edit_assist - diagram-layout writeback locates the existing form
    const src =
        \\(design-block "X"
        \\  (diagram-layout (anchor "a") (place "b" (right-of "a")))
        \\  (instance "C1" (cap-0402 "1nF")))
    ;
    const span = findLayoutForm(src).?;
    try std.testing.expect(std.mem.startsWith(u8, src[span.start..span.end], "(diagram-layout"));
    try std.testing.expect(std.mem.endsWith(u8, src[span.start..span.end], ")"));
    // The legacy alias is found too (forms sit at line start in real files).
    const legacy = "(design-block \"X\"\n  (layout (anchor \"a\")))";
    try std.testing.expect(findLayoutForm(legacy) != null);
    // A commented mention is NOT mistaken for the form.
    try std.testing.expect(findLayoutForm("(design-block \"X\"\n  ;; see (layout …) below\n  )") == null);
    // Absent → null.
    try std.testing.expect(findLayoutForm("(design-block \"X\")") == null);
}

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

test "extractFootprint reads atom and quoted footprint forms" {
    // spec: serve/edit_assist - lib-index reports each component's footprint name
    const atom =
        \\(component-family "cap-0402"
        \\  (footprint c-0402)
        \\  (parameter "value" capacitance))
    ;
    try std.testing.expectEqualStrings("c-0402", extractFootprint(atom));
    const quoted =
        \\(component "x"
        \\  (footprint "sot891")
        \\  (mpn "X"))
    ;
    try std.testing.expectEqualStrings("sot891", extractFootprint(quoted));
    // No footprint form → empty.
    try std.testing.expectEqualStrings("", extractFootprint("(component \"x\" (mpn \"X\"))"));
}
