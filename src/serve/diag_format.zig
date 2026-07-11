//! Build-error diagnostic formatting.
//!
//! When a design fails to evaluate, the evaluator stashes the source span +
//! message in `Evaluator.last_error`. This module turns that into something a
//! human can act on: `file:line:col`, the message, the offending source line,
//! and a caret under the column — rendered as plain text, JSON (`/api/push`,
//! the MCP `build` tool), or a standalone HTML error page (schematic GET).

const std = @import("std");
const json_writer = @import("../json_writer.zig");
const infra_fs = @import("../infra/fs.zig");
const evaluator_mod = @import("../eval/evaluator.zig");

const max_source_bytes: usize = 10 * 1024 * 1024;

/// A resolved build diagnostic. All slices are owned by the allocator passed
/// to `build`/`load` (duped there), so the struct outlives the evaluator.
pub const Diagnostic = struct {
    /// Path of the design source the failed eval started from. The span is
    /// only guaranteed to refer to this file when `source_line` is non-empty —
    /// errors inside imported modules carry spans of the module's buffer, in
    /// which case the offset consistency check below blanks the source line.
    file: []const u8,
    line: u32,
    col: u32,
    /// Human-readable evaluator message (or the bare Zig error name when the
    /// evaluator recorded no span).
    message: []const u8,
    /// The offending source line, without its trailing newline. Empty when
    /// the span doesn't consistently point into `file`'s contents.
    source_line: []const u8,
};

/// Build a `Diagnostic` from an in-memory source buffer. Pure — no file IO —
/// so it's unit-testable. `last_error` null (the evaluator recorded no span)
/// degrades to line/col 0 with just the error name.
pub fn build(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    source: []const u8,
    err_name: []const u8,
    last_error: ?evaluator_mod.EvalDiagnostic,
) std.mem.Allocator.Error!Diagnostic {
    const file = try allocator.dupe(u8, file_path);
    const le = last_error orelse return .{
        .file = file,
        .line = 0,
        .col = 0,
        .message = try allocator.dupe(u8, err_name),
        .source_line = "",
    };
    const message = try allocator.dupe(u8, le.message);
    return .{
        .file = file,
        .line = le.span.line,
        .col = le.span.col,
        .message = message,
        .source_line = try allocator.dupe(u8, sourceLineAt(source, le.span.line, le.span.offset)),
    };
}

/// Build a `Diagnostic` by reading `file_path` from disk. The read happens at
/// error time, so the line shown matches what the user last saved.
pub fn load(
    allocator: std.mem.Allocator,
    file_path: []const u8,
    err_name: []const u8,
    last_error: ?evaluator_mod.EvalDiagnostic,
) std.mem.Allocator.Error!Diagnostic {
    const source = infra_fs.cwd().readFileAlloc(allocator, file_path, max_source_bytes) catch "";
    return build(allocator, file_path, source, err_name, last_error);
}

/// Extract the source line containing byte `offset`, but only when that
/// offset really lands on 1-based line `line` of `source` — the consistency
/// check that keeps us from showing design-file text for a span that actually
/// points into an imported module's buffer. Returns "" on any mismatch.
fn sourceLineAt(source: []const u8, line: u32, offset: u32) []const u8 {
    if (offset >= source.len and source.len > 0) return "";
    if (source.len == 0) return "";
    const off: usize = @min(@as(usize, offset), source.len - 1);
    var line_no: u32 = 1;
    for (source[0..off]) |c| {
        if (c == '\n') line_no += 1;
    }
    if (line_no != line) return "";
    var start: usize = off;
    while (start > 0 and source[start - 1] != '\n') start -= 1;
    var end: usize = off;
    while (end < source.len and source[end] != '\n') end += 1;
    return source[start..end];
}

/// The caret line for a 1-based column: whitespace up to `col-1` (tabs from
/// the source line are preserved so the caret stays aligned in terminals and
/// <pre> blocks alike), then a single `^`.
pub fn caretLine(allocator: std.mem.Allocator, source_line: []const u8, col: u32) std.mem.Allocator.Error![]u8 {
    const n: usize = if (col > 0) col - 1 else 0;
    var buf = try allocator.alloc(u8, n + 1);
    for (0..n) |i| {
        buf[i] = if (i < source_line.len and source_line[i] == '\t') '\t' else ' ';
    }
    buf[n] = '^';
    return buf;
}

/// Render the diagnostic as the conventional compiler-style text block:
/// `file:line:col: message`, then the source line, then the caret line.
/// Omits the source/caret lines when the source line is unavailable.
pub fn formatText(allocator: std.mem.Allocator, d: Diagnostic) std.mem.Allocator.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(allocator);
    try w.print("{s}:{d}:{d}: {s}", .{ d.file, d.line, d.col, d.message });
    if (d.source_line.len > 0) {
        const caret = try caretLine(allocator, d.source_line, d.col);
        defer allocator.free(caret);
        try w.print("\n  {s}\n  {s}", .{ d.source_line, caret });
    }
    return buf.toOwnedSlice(allocator);
}

/// Write the diagnostic as a JSON object:
/// `{"file":…,"line":N,"col":N,"message":…,"source_line":…}`. Callers pass
/// ArrayList writers, so the error surface is allocation only.
pub fn writeJson(w: anytype, d: Diagnostic) std.mem.Allocator.Error!void {
    try w.writeAll("{\"file\":");
    try json_writer.writeString(w, d.file);
    try w.print(",\"line\":{d},\"col\":{d},\"message\":", .{ d.line, d.col });
    try json_writer.writeString(w, d.message);
    try w.writeAll(",\"source_line\":");
    try json_writer.writeString(w, d.source_line);
    try w.writeAll("}");
}

/// Standalone dark-theme HTML error page for a failed schematic build:
/// design title, `file:line:col`, the message, and a monospace source line
/// with a caret under the failing column.
pub fn renderErrorPage(
    allocator: std.mem.Allocator,
    design_name: []const u8,
    d: Diagnostic,
) std.mem.Allocator.Error![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(allocator);
    try w.writeAll(
        "<!DOCTYPE html><html><head><meta charset=\"utf-8\">" ++
            "<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">" ++
            "<title>Build error</title><style>" ++
            "body{margin:0;background:#0d1117;color:#c9d1d9;font-family:-apple-system,BlinkMacSystemFont,\"Segoe UI\",sans-serif}" ++
            ".build-err{max-width:860px;margin:40px auto;background:#161b22;border:1px solid #da3633;border-radius:10px;padding:22px 26px}" ++
            ".build-err h1{margin:0 0 6px;font-size:1.1rem;color:#f85149}" ++
            ".be-loc{font-family:ui-monospace,SFMono-Regular,monospace;font-size:0.82rem;color:#79c0ff;margin-bottom:10px}" ++
            ".be-msg{font-size:0.9rem;margin-bottom:14px}" ++
            "pre{background:#0d1117;border:1px solid #21262d;border-radius:6px;padding:12px 14px;" ++
            "font-size:0.82rem;line-height:1.5;overflow-x:auto;color:#c9d1d9;margin:0}" ++
            "pre .caret{color:#f85149;font-weight:700}" ++
            "</style></head><body><div class=\"build-err\"><h1>Build error — ",
    );
    try writeHtmlEscaped(w, design_name);
    try w.writeAll("</h1><div class=\"be-loc\">");
    try writeHtmlEscaped(w, d.file);
    if (d.line > 0) try w.print(":{d}:{d}", .{ d.line, d.col });
    try w.writeAll("</div><div class=\"be-msg\">");
    try writeHtmlEscaped(w, d.message);
    try w.writeAll("</div>");
    if (d.source_line.len > 0) {
        const caret = try caretLine(allocator, d.source_line, d.col);
        defer allocator.free(caret);
        try w.writeAll("<pre>");
        try writeHtmlEscaped(w, d.source_line);
        try w.writeAll("\n<span class=\"caret\">");
        try writeHtmlEscaped(w, caret);
        try w.writeAll("</span></pre>");
    }
    try w.writeAll("</div></body></html>");
    return buf.toOwnedSlice(allocator);
}

fn writeHtmlEscaped(w: anytype, s: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(c),
    };
}

// spec: serve/diag_format - caretLine pads to the 1-based column (preserving tabs) and ends with a caret
test "caretLine aligns under the failing column" {
    const a = std.testing.allocator;
    const caret = try caretLine(a, "  (port x)", 4);
    defer a.free(caret);
    try std.testing.expectEqualStrings("   ^", caret);

    const caret_tab = try caretLine(a, "\t(bad)", 2);
    defer a.free(caret_tab);
    try std.testing.expectEqualStrings("\t^", caret_tab);
}

// spec: serve/diag_format - build extracts the offending source line from the buffer at the span
test "build resolves the source line and formatText renders the caret block" {
    const a = std.testing.allocator;
    const source = "(design-block \"X\"\n  (port 42 in))\n";
    const le = evaluator_mod.EvalDiagnostic{
        // Points at `(port …` on line 2, col 3 (offset of '(' = 20).
        .span = .{ .line = 2, .col = 3, .offset = 20 },
        .message = "port name must be a string",
    };
    const d = try build(a, "src/x.sexp", source, "InvalidForm", le);
    defer {
        a.free(d.file);
        a.free(d.message);
        a.free(d.source_line);
    }
    try std.testing.expectEqualStrings("  (port 42 in))", d.source_line);
    try std.testing.expectEqual(@as(u32, 2), d.line);

    const text = try formatText(a, d);
    defer a.free(text);
    try std.testing.expectEqualStrings(
        "src/x.sexp:2:3: port name must be a string\n" ++
            "    (port 42 in))\n" ++
            "    ^",
        text,
    );
}

// spec: serve/diag_format - build blanks the source line when the span doesn't match the buffer (module-file spans)
test "build omits the source line on span/buffer mismatch" {
    const a = std.testing.allocator;
    const source = "(design-block \"X\")\n";
    const le = evaluator_mod.EvalDiagnostic{
        // Claims line 9 but the offset lands on line 1 → inconsistent (span is
        // from some other file's buffer).
        .span = .{ .line = 9, .col = 1, .offset = 3 },
        .message = "boom",
    };
    const d = try build(a, "src/x.sexp", source, "InvalidForm", le);
    defer {
        a.free(d.file);
        a.free(d.message);
        a.free(d.source_line);
    }
    try std.testing.expectEqualStrings("", d.source_line);
}
