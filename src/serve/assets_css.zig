const std = @import("std");

// ── Shared navbar ─────────────────────────────────────────────────────

pub const NAVBAR_CSS = @embedFile("assets/navbar.css");

/// Render the shared top navigation bar (Designs / Library / Account) into
/// `w`, marking the link whose name matches `active` with the `.active` CSS
/// class so the current page is highlighted.
pub fn writeNavbar(w: anytype, active: []const u8) (std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    try w.writeAll("<div class=\"navbar\"><span class=\"brand\">Canopy EDA</span>");
    if (std.mem.eql(u8, active, "designs")) {
        try w.writeAll("<a href=\"/\" class=\"active\">Designs</a>");
    } else {
        try w.writeAll("<a href=\"/\">Designs</a>");
    }
    if (std.mem.eql(u8, active, "library")) {
        try w.writeAll("<a href=\"/library\" class=\"active\">Library</a>");
    } else {
        try w.writeAll("<a href=\"/library\">Library</a>");
    }
    try w.writeAll("<a href=\"/account\" style=\"margin-left:auto\">Account</a>");
    try w.writeAll("</div>");
}

// ── CSS for index page ────────────────────────────────────────────────

pub const INDEX_CSS = @embedFile("assets/index.css");

// ── CSS for design page (embedded in <style>) ─────────────────────────

pub const DESIGN_CSS = @embedFile("assets/design.css");
