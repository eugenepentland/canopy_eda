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
    return writeEntities(w, s, "&#39;");
}

/// `writeXml` with the apostrophe spelled as the hexadecimal character
/// reference `&#x27;` rather than the decimal `&#39;`. Both are U+0027 to every
/// XML and HTML parser, so the two forms are interchangeable for a reader; they
/// are not interchangeable for a byte comparison, which is the whole reason
/// this variant exists. The page templates in `src/serve/templates/` have
/// emitted the hex form since they were written, and their rendered pages are
/// compared byte-for-byte against captured references, so they call this and
/// every other caller calls `writeXml`.
///
/// Only `writeXml`'s spelling round-trips through `decodeXmlAlloc`; nothing
/// decodes template output, which goes straight to a browser.
pub fn writeXmlHexApos(w: anytype, s: []const u8) !void {
    return writeEntities(w, s, "&#x27;");
}

/// The one entity table. `apostrophe` is the only thing the two public
/// spellings above disagree about — keeping the other four in a single switch
/// is what stops them from drifting apart.
fn writeEntities(w: anytype, s: []const u8, comptime apostrophe: []const u8) !void {
    for (s) |c| switch (c) {
        '&' => try w.writeAll("&amp;"),
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '"' => try w.writeAll("&quot;"),
        '\'' => try w.writeAll(apostrophe),
        else => try w.writeByte(c),
    };
}

/// Inverse of `writeXml`: expand exactly the entity set it produces, onto
/// `gpa`. An unrecognised `&…;` run is copied through verbatim — text that came
/// from somewhere other than `writeXml` is design-derived and must survive a
/// round-trip, not become an error.
///
/// It lives beside `writeXml` because the two tables have to agree: a character
/// added to the escaper and not to this table silently reaches a PDF as a
/// literal `&#39;`. The round-trip test below is what holds them together.
pub fn decodeXmlAlloc(gpa: std.mem.Allocator, s: []const u8) std.mem.Allocator.Error![]const u8 {
    const table = [_]struct { name: []const u8, ch: u8 }{
        .{ .name = "&amp;", .ch = '&' },
        .{ .name = "&lt;", .ch = '<' },
        .{ .name = "&gt;", .ch = '>' },
        .{ .name = "&quot;", .ch = '"' },
        .{ .name = "&#39;", .ch = '\'' },
    };
    var out: std.ArrayList(u8) = .empty;
    try out.ensureTotalCapacity(gpa, s.len);
    var i: usize = 0;
    scan: while (i < s.len) {
        if (s[i] == '&') {
            for (table) |e| {
                if (std.mem.startsWith(u8, s[i..], e.name)) {
                    out.appendAssumeCapacity(e.ch);
                    i += e.name.len;
                    continue :scan;
                }
            }
        }
        out.appendAssumeCapacity(s[i]);
        i += 1;
    }
    return out.toOwnedSlice(gpa);
}

test "writeXml escapes markup and both quote styles" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeXml(&out.writer, "a<b>&\"'c");
    try std.testing.expectEqualStrings("a&lt;b&gt;&amp;&quot;&#39;c", out.written());
}

test "writeXml neutralizes a script/attribute breakout" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try writeXml(&out.writer, "\"><script>alert(1)</script>");
    const written = out.written();
    // No literal '<', '>' or '"' survives, so neither an attribute nor a tag can be closed.
    try std.testing.expect(std.mem.indexOfScalar(u8, written, '<') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, written, '>') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, written, '"') == null);
}

test "the two apostrophe spellings differ in nothing but the apostrophe" {
    var decimal: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer decimal.deinit();
    var hex: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer hex.deinit();
    // Every byte, so a character escaped by one spelling and not the other
    // fails here rather than on a page nobody diffed.
    var all: [256]u8 = undefined;
    for (&all, 0..) |*b, i| b.* = @intCast(i);
    try writeXml(&decimal.writer, &all);
    try writeXmlHexApos(&hex.writer, &all);

    const at = std.mem.indexOf(u8, decimal.written(), "&#39;").?;
    try std.testing.expectEqualStrings(decimal.written()[0..at], hex.written()[0..at]);
    try std.testing.expectEqualStrings("&#39;", decimal.written()[at..][0..5]);
    try std.testing.expectEqualStrings("&#x27;", hex.written()[at..][0..6]);
    try std.testing.expectEqualStrings(decimal.written()[at + 5 ..], hex.written()[at + 6 ..]);
}

test "decodeXmlAlloc round-trips every byte writeXml can escape" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    // Every byte, so a character added to one table and not the other fails
    // here rather than reaching a PDF as a literal `&#39;`.
    var all: [256]u8 = undefined;
    for (&all, 0..) |*b, i| b.* = @intCast(i);
    try writeXml(&out.writer, &all);
    const back = try decodeXmlAlloc(std.testing.allocator, out.written());
    defer std.testing.allocator.free(back);
    try std.testing.expectEqualSlices(u8, &all, back);
}

test "decodeXmlAlloc copies an entity it does not know through verbatim" {
    const got = try decodeXmlAlloc(std.testing.allocator, "a &nbsp; b &amp; c &");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("a &nbsp; b & c &", got);
}
