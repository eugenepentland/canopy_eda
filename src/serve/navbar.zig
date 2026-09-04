//! Shared primary navigation for every online HTML surface.
//!
//! Full-screen editors may keep a page-specific toolbar immediately below it,
//! but the first bar is always this one so Home, Library and Account never move
//! or disappear between workflows.

const std = @import("std");

pub const css = @embedFile("assets/navbar.css");

/// Top-level destination highlighted by the primary navigation.
pub const Active = enum {
    home,
    library,
    none,
};

/// Write the common site navbar, marking the current top-level destination.
pub fn write(w: *std.Io.Writer, active: Active) std.Io.Writer.Error!void {
    try w.writeAll("<nav class=\"navbar\" aria-label=\"Primary\">");
    try w.writeAll("<a href=\"/\" class=\"brand");
    if (active == .home) try w.writeAll(" active");
    try w.writeByte('"');
    if (active == .home) try w.writeAll(" aria-current=\"page\"");
    try w.writeAll(">Netlisp</a><a href=\"/library\"");
    if (active == .library) try w.writeAll(" class=\"active\" aria-current=\"page\"");
    try w.writeAll(">Library</a>");
    try w.writeAll("<a href=\"https://ward.eugenepentland.dev/admin\" style=\"margin-left:auto\">Account</a></nav>");
}

test "navbar always exposes one direct home link" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try write(&aw.writer, .none);
    const html = aw.written();
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, html, "href=\"/\""));
    try std.testing.expect(std.mem.indexOf(u8, html, ">Netlisp</a>") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, "href=\"/library\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, html, ">Account</a>") != null);
}
