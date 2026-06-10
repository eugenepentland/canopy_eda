//! Attach a datasheet PDF to a library component.
//!
//! The pure splice (`spliceDatasheet`) inserts a `(datasheet "file.pdf")`
//! form before the closing paren of the component definition, matching the
//! file's indent style and deduping on the normalised filename stem — it's
//! the unit-testable core that `edit.addComponentDatasheetCore` (and the
//! schematic-sidebar link endpoints built on it) run on. The HTTP handler
//! `attachDatasheetApi` (POST `/api/attach-datasheet` `{component, file}`)
//! is the library page's one-click attach: it validates that both the
//! component and the uploaded PDF exist, then performs the splice —
//! idempotently, an already-linked datasheet returns ok with a note.

const std = @import("std");
const httpz = @import("httpz");
const json_writer = @import("../json_writer.zig");
const infra_fs = @import("../infra/fs.zig");
const edit_mod = @import("edit.zig");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;

/// Error set for the HTTP handler.
pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error;

/// Errors from the pure splice.
pub const SpliceError = error{
    /// No `(component …)` / `(component-family …)` form in the source.
    MalformedSource,
    /// A datasheet with the same stem is already linked.
    DuplicateImport,
    OutOfMemory,
};

/// Splice `(datasheet "<pdf>")` into the first component form of `source`,
/// returning the new file contents (caller owns). Dedupe is stem-based: a
/// filename that differs from an existing link only by a re-download counter
/// (`foo__1_.pdf` vs `foo.pdf`) counts as already linked.
pub fn spliceDatasheet(
    allocator: std.mem.Allocator,
    source: []const u8,
    pdf: []const u8,
) SpliceError![]u8 {
    const form_start = std.mem.indexOf(u8, source, "(component") orelse return error.MalformedSource;
    const form_end = findFormEnd(source, form_start) orelse return error.MalformedSource;
    if (linksDatasheet(source[form_start..form_end], pdf)) return error.DuplicateImport;

    // Insert before the closing `)` with the file's child indent.
    const insert_at = form_end - 1;
    const indent = detectIndent(source, form_start);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(allocator);
    const w = buf.writer(allocator);
    try w.writeAll(source[0..insert_at]);
    try w.writeByte('\n');
    try w.writeAll(indent);
    try w.writeAll("(datasheet \"");
    for (pdf) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        else => try w.writeByte(c),
    };
    try w.writeAll("\")");
    try w.writeAll(source[insert_at..]);
    return buf.toOwnedSlice(allocator);
}

/// True iff `component_form` already declares a `(datasheet "…")` whose stem
/// matches `pdf`'s — the single-link dedupe predicate, suffix-insensitive.
pub fn linksDatasheet(component_form: []const u8, pdf: []const u8) bool {
    const want = datasheetStem(pdf);
    const open = "(datasheet \"";
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, component_form, i, open)) |at| {
        const name_start = at + open.len;
        const end = std.mem.indexOfScalarPos(u8, component_form, name_start, '"') orelse break;
        const have = datasheetStem(component_form[name_start..end]);
        if (have.len == want.len and std.ascii.eqlIgnoreCase(have, want)) return true;
        i = end + 1;
    }
    return false;
}

/// Canonical comparison stem for a datasheet filename: drop `.pdf` and any
/// trailing duplicate-download marker so two names that differ only by a
/// re-download counter compare equal. Handles both the raw browser form
/// (`foo (1)`) and the post-sanitise form the filename whitelist bakes it into
/// (`foo__1_`). A part number that merely ends in digits (`lm2596`) is left
/// untouched — only a parenthesised or `__`-wrapped counter is removed.
pub fn datasheetStem(name: []const u8) []const u8 {
    var s = name;
    if (std.ascii.endsWithIgnoreCase(s, ".pdf")) s = s[0 .. s.len - 4];
    // Raw form: trailing `(<digits>)`.
    if (s.len >= 3 and s[s.len - 1] == ')') {
        if (std.mem.lastIndexOfScalar(u8, s, '(')) |open| {
            const inner = s[open + 1 .. s.len - 1];
            if (inner.len > 0 and allAsciiDigits(inner)) return std.mem.trimRight(u8, s[0..open], " _");
        }
    }
    // Post-sanitise form: trailing `__<digits>_` (from `(N)` once `(`/`)` map to `_`).
    if (s.len >= 4 and s[s.len - 1] == '_') {
        var j = s.len - 1;
        while (j > 0 and s[j - 1] >= '0' and s[j - 1] <= '9') j -= 1;
        if (j < s.len - 1 and j >= 2 and s[j - 1] == '_' and s[j - 2] == '_') {
            s = std.mem.trimRight(u8, s[0 .. j - 2], " _");
        }
    }
    return s;
}

fn allAsciiDigits(s: []const u8) bool {
    for (s) |c| if (c < '0' or c > '9') return false;
    return true;
}

/// One past the closing paren of the form opening at `open_pos`. Respects
/// strings and `;` line comments. (Local copy of edit.zig's scanner so the
/// splice stays import-light and independently testable.)
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

/// Indent prefix of the first child line inside the component form, falling
/// back to two spaces for single-line definitions.
fn detectIndent(source: []const u8, form_start: usize) []const u8 {
    var i: usize = form_start;
    while (i < source.len and source[i] != '\n') : (i += 1) {}
    if (i >= source.len) return "  ";
    i += 1;
    const indent_start = i;
    while (i < source.len and (source[i] == ' ' or source[i] == '\t')) : (i += 1) {}
    if (i == indent_start) return "  ";
    return source[indent_start..i];
}

// ── HTTP handler ─────────────────────────────────────────────────────────

/// POST /api/attach-datasheet — body `{"component":"<lib name>","file":"x.pdf"}`.
/// Validates that `lib/components/<component>.sexp` and
/// `lib/datasheets/<file>` both exist, then splices the `(datasheet …)` form
/// into the component. Idempotent: an already-linked file returns
/// `{"ok":true,"note":"already linked"}`.
pub fn attachDatasheetApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    res.content_type = .JSON;
    const body = req.body() orelse {
        res.status = 400;
        res.body = "{\"ok\":false,\"error\":\"missing body\"}";
        return;
    };
    const component = jsonField(body, "component") orelse {
        res.status = 400;
        res.body = "{\"ok\":false,\"error\":\"missing 'component'\"}";
        return;
    };
    const file = jsonField(body, "file") orelse {
        res.status = 400;
        res.body = "{\"ok\":false,\"error\":\"missing 'file'\"}";
        return;
    };

    if (!try requireExists(ctx, res, "lib/components/{s}.sexp", component, "component not found in lib/components/")) return;
    if (!try requireExists(ctx, res, "lib/datasheets/{s}", file, "datasheet not found in lib/datasheets/ — upload it first")) return;

    const result = edit_mod.addComponentDatasheetCore(ctx.allocator, ctx.project_dir, component, file) catch |err| {
        if (err == error.DuplicateImport) {
            res.body = "{\"ok\":true,\"note\":\"already linked\"}";
            return;
        }
        res.status = 500;
        var buf: std.ArrayListUnmanaged(u8) = .empty;
        const w = buf.writer(ctx.allocator);
        try w.writeAll("{\"ok\":false,\"error\":");
        try json_writer.writeString(w, @errorName(err));
        try w.writeAll("}");
        res.body = buf.items;
        return;
    };
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(ctx.allocator);
    try w.print("{{\"ok\":true,\"version\":{d}}}", .{result.version});
    res.body = buf.items;
}

/// Validate a project-relative name (no traversal) and that the file at
/// `fmt` (one `{s}` for the name) exists. Writes a 4xx JSON error and
/// returns false otherwise.
fn requireExists(
    ctx: *Handler,
    res: *httpz.Response,
    comptime fmt: []const u8,
    name: []const u8,
    not_found_msg: []const u8,
) HandlerError!bool {
    const bad = name.len == 0 or std.mem.indexOf(u8, name, "..") != null or
        std.mem.indexOfAny(u8, name, "/\\\"") != null;
    if (!bad) {
        const rel = try std.fmt.allocPrint(ctx.allocator, fmt, .{name});
        defer ctx.allocator.free(rel);
        const path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ ctx.project_dir, rel });
        defer ctx.allocator.free(path);
        if (infra_fs.cwd().access(path, .{})) |_| {
            return true;
        } else |_| {}
    }
    res.status = if (bad) 400 else 404;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(ctx.allocator);
    try w.writeAll("{\"ok\":false,\"error\":");
    try json_writer.writeString(w, if (bad) "invalid name" else not_found_msg);
    try w.writeAll("}");
    res.body = buf.items;
    return false;
}

/// Extract `"key":"value"` from a flat JSON body — same shortcut the other
/// small POST endpoints use.
fn jsonField(body: []const u8, key: []const u8) ?[]const u8 {
    var buf: [64]u8 = undefined;
    const marker = std.fmt.bufPrint(&buf, "\"{s}\":\"", .{key}) catch return null;
    const start = std.mem.indexOf(u8, body, marker) orelse return null;
    const val_start = start + marker.len;
    const end = std.mem.indexOfPos(u8, body, val_start, "\"") orelse return null;
    return body[val_start..end];
}

// ── Tests ────────────────────────────────────────────────────────────────

// spec: serve/datasheet_attach - spliceDatasheet inserts the (datasheet …) form before the component's closing paren with matching indent
test "spliceDatasheet inserts with the file's indent" {
    const a = std.testing.allocator;
    const source =
        \\(component "lt3045"
        \\  (description "LDO")
        \\  (footprint msop-12))
    ;
    const out = try spliceDatasheet(a, source, "lt3045.pdf");
    defer a.free(out);
    try std.testing.expectEqualStrings(
        \\(component "lt3045"
        \\  (description "LDO")
        \\  (footprint msop-12)
        \\  (datasheet "lt3045.pdf"))
    , out);
}

// spec: serve/datasheet_attach - spliceDatasheet dedupes on the normalised stem (re-download counters ignored)
test "spliceDatasheet is idempotent on already-linked stems" {
    const a = std.testing.allocator;
    const source =
        \\(component "lt3045"
        \\  (datasheet "lt3045.pdf"))
    ;
    try std.testing.expectError(error.DuplicateImport, spliceDatasheet(a, source, "lt3045.pdf"));
    // Re-download marker form of the same datasheet is also a duplicate.
    try std.testing.expectError(error.DuplicateImport, spliceDatasheet(a, source, "lt3045__1_.pdf"));
}

// spec: serve/datasheet_attach - spliceDatasheet rejects sources without a component form
test "spliceDatasheet rejects non-component sources" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.MalformedSource, spliceDatasheet(a, "(design-block \"x\")", "a.pdf"));
}
