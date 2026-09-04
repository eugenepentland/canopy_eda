//! Shared helpers for hierarchical net and reference-designator names.

const std = @import("std");

/// Return the final segment of a slash-delimited hierarchical name.
pub fn leaf(name: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, name, '/') orelse return name;
    return name[slash + 1 ..];
}

/// Return everything before the final slash in a hierarchical name, or null
/// for a name with no parent segment.
pub fn parent(name: []const u8) ?[]const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, name, '/') orelse return null;
    return name[0..slash];
}

test "leaf removes a hierarchy prefix" {
    try std.testing.expectEqualStrings("C17", leaf("buck_3v3/C17"));
    try std.testing.expectEqualStrings("U2", leaf("U2"));
    // A trailing slash has an EMPTY leaf, not the parent segment. Callers that
    // read `leaf(x)[0]` as a ref-des class letter must therefore check the
    // length first — several hand-rolled copies of this split used to fall back
    // to the sub-block name here and report it as the part's class.
    try std.testing.expectEqualStrings("", leaf("buck_3v3/"));
    try std.testing.expectEqualStrings("", leaf(""));
}

test "parent removes a hierarchy leaf" {
    try std.testing.expectEqualStrings("buck_3v3", parent("buck_3v3/VOUT").?);
    try std.testing.expectEqual(@as(?[]const u8, null), parent("VOUT"));
    // The parent of a trailing-slash name is everything before that slash, so
    // `parent` and `leaf` still partition the name exactly.
    try std.testing.expectEqualStrings("buck_3v3", parent("buck_3v3/").?);
}
