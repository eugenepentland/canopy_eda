//! Shared JSON emission helpers. Before this module, each renderer defined its
//! own `writeJsonEscaped` / `writeJsonString` — some lacked unicode escaping and
//! a couple emitted strings entirely unquoted, which would corrupt the output on
//! input containing `"`, `\`, or control characters. Route new emission through
//! the helpers here.

const std = @import("std");

/// Error set covering both allocating and I/O-backed writers used throughout
/// the renderers.
pub const WriteError = std.mem.Allocator.Error || std.Io.Writer.Error;

/// Write `s` to `w`, escaping characters that are illegal inside a JSON string
/// body. Does NOT write the surrounding `"` quotes — use `writeString` for that.
pub fn writeEscaped(w: anytype, s: []const u8) WriteError!void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
}

/// Write `s` as a full JSON string literal, including surrounding `"` quotes.
pub fn writeString(w: anytype, s: []const u8) WriteError!void {
    try w.writeByte('"');
    try writeEscaped(w, s);
    try w.writeByte('"');
}

/// Write a JSON string that is safe to embed verbatim in an HTML `script`
/// element. In addition to JSON escapes this encodes `<` and JavaScript's two
/// unicode line separators, preventing `</script>` termination and parse drift.
pub fn writeScriptString(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s[i];
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            '<' => try w.writeAll("\\u003c"),
            0xE2 => {
                const line_separator = i + 2 < s.len and s[i + 1] == 0x80 and
                    (s[i + 2] == 0xA8 or s[i + 2] == 0xA9);
                if (line_separator) {
                    try w.writeAll(if (s[i + 2] == 0xA8) "\\u2028" else "\\u2029");
                    i += 2;
                } else try w.writeByte(c);
            },
            else => if (c < 0x20) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

/// Write `"key":"value"` with proper escaping on `value`. The key is written
/// verbatim, since our keys are always ASCII identifiers.
pub fn writeField(w: anytype, key: []const u8, value: []const u8) WriteError!void {
    try w.print("\"{s}\":", .{key});
    try writeString(w, value);
}

test "escape quotes and backslashes" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const w = &out.writer;
    try writeEscaped(w, "he said \"hi\" and \\");
    try std.testing.expectEqualStrings("he said \\\"hi\\\" and \\\\", out.written());
}

test "escape control characters" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const w = &out.writer;
    try writeEscaped(w, "a\x01b\nc");
    try std.testing.expectEqualStrings("a\\u0001b\\nc", out.written());
}

test "writeField surrounds value with quotes" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    const w = &out.writer;
    try writeField(w, "name", "U1");
    try std.testing.expectEqualStrings("\"name\":\"U1\"", out.written());
}

test "script strings escape closing tags and JavaScript line separators" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeScriptString(&out.writer, "</script>\xE2\x80\xA8\xE2\x80\xA9");
    try std.testing.expectEqualStrings("\"\\u003c/script>\\u2028\\u2029\"", out.written());
}
