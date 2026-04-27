//! Shared JSON emission helpers. Before this module, each renderer defined its
//! own `writeJsonEscaped` / `writeJsonString` — some lacked unicode escaping and
//! a couple emitted strings entirely unquoted, which would corrupt the output on
//! input containing `"`, `\`, or control characters. Route new emission through
//! the helpers here.

const std = @import("std");

/// Error set covering writers used throughout the renderers — they all wrap an
/// `ArrayListUnmanaged(u8).writer()` whose `error` is just `Allocator.Error`.
pub const WriteError = std.mem.Allocator.Error;

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

/// Write `"key":"value"` with proper escaping on `value`. The key is written
/// verbatim, since our keys are always ASCII identifiers.
pub fn writeField(w: anytype, key: []const u8, value: []const u8) WriteError!void {
    try w.print("\"{s}\":", .{key});
    try writeString(w, value);
}

test "escape quotes and backslashes" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);
    try writeEscaped(w, "he said \"hi\" and \\");
    try std.testing.expectEqualStrings("he said \\\"hi\\\" and \\\\", buf.items);
}

test "escape control characters" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);
    try writeEscaped(w, "a\x01b\nc");
    try std.testing.expectEqualStrings("a\\u0001b\\nc", buf.items);
}

test "writeField surrounds value with quotes" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);
    try writeField(w, "name", "U1");
    try std.testing.expectEqualStrings("\"name\":\"U1\"", buf.items);
}
