//! Stable board-review checklist catalog shared by the browser and agent tools.

const std = @import("std");

/// Embedded canonical 13-section board-review checklist.
pub const markdown = @embedFile("serve/assets/board_review_checklist.md");
/// Stable count of discrete checklist decisions in `markdown`.
pub const item_count: usize = 258;

/// Checklist ids are decimal components separated by single dots and must be
/// present in the embedded catalog. Keeping this validation in one module
/// prevents the HTTP and agent mutation surfaces from accepting different ids.
pub fn validItemId(id: []const u8) bool {
    if (id.len == 0 or id.len > 16 or id[0] == '.' or id[id.len - 1] == '.') return false;
    var last_dot = false;
    for (id) |c| {
        if (c == '.') {
            if (last_dot) return false;
            last_dot = true;
        } else {
            if (!std.ascii.isDigit(c)) return false;
            last_dot = false;
        }
    }
    var buffer: [24]u8 = undefined;
    const needle = std.fmt.bufPrint(&buffer, "**{s}**", .{id}) catch return false;
    return std.mem.indexOf(u8, markdown, needle) != null;
}

test "board review catalog retains its stable item identities" {
    var sections: usize = 0;
    var items: usize = 0;
    var lines = std.mem.splitScalar(u8, markdown, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, "## Section ")) sections += 1;
        if (std.mem.startsWith(u8, line, "- [ ] **")) items += 1;
    }
    try std.testing.expectEqual(@as(usize, 13), sections);
    try std.testing.expectEqual(item_count, items);
    try std.testing.expect(validItemId("1.1"));
    try std.testing.expect(validItemId("11.9"));
    try std.testing.expect(validItemId("13.15"));
    try std.testing.expect(!validItemId("../1"));
}
