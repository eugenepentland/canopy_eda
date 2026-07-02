//! Shared HTML/XML/SVG output escaping. Untrusted text — design titles, net
//! names, ref-des, component values, pinout function names, user notes — reaches
//! server-rendered HTML and inline SVG; `import-kicad` ingests arbitrary net
//! names from third-party boards and uploaded library files carry arbitrary
//! strings, so this text is genuinely attacker-influenced, not merely internal.
//! Route every interpolation of design-derived text into markup through these
//! helpers rather than a raw `{s}`.
const std = @import("std");

/// Escape `s` for an XML/HTML text node AND for double- or single-quoted
/// attribute values: `& < > " '` become entities. The single-quote escape
/// means the same helper is safe in every SVG/HTML text and attribute context,
/// so callers never have to reason about which context they are in.
pub fn writeXml(w: anytype, s: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll("&#39;"),
        else => try w.writeByte(c),
    };
}

test "writeXml escapes markup and both quote styles" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);
    try writeXml(w, "a<b>&\"'c");
    try std.testing.expectEqualStrings("a&lt;b&gt;&amp;&quot;&#39;c", buf.items);
}

test "writeXml neutralizes a script/attribute breakout" {
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    const w = buf.writer(std.testing.allocator);
    try writeXml(w, "\"><script>alert(1)</script>");
    // No literal '<', '>' or '"' survives, so neither an attribute nor a tag can be closed.
    try std.testing.expect(std.mem.indexOfScalar(u8, buf.items, '<') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, buf.items, '>') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, buf.items, '"') == null);
}
