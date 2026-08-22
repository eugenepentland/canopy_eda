//! Manufacturer-safe basenames for fabrication packages.

const std = @import("std");

/// JLCPCB rejects archive entries whose names contain these tokens (case
/// insensitive), even when the token is merely part of the design slug. Keep
/// safe project names descriptive; use a neutral basename for a rejected slug.
pub fn prefix(name: []const u8) []const u8 {
    const forbidden = [_][]const u8{ "eval", "copy", "convert", "confirm" };
    for (forbidden) |word| {
        if (name.len < word.len) continue;
        for (0..name.len - word.len + 1) |i| {
            if (std.ascii.eqlIgnoreCase(name[i..][0..word.len], word)) return "board";
        }
    }
    for (name) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '_')) return "board";
    }
    return if (name.len == 0) "board" else name;
}

// spec: serve/fab_filename - forbidden JLCPCB words and special characters fall back to a neutral fabrication basename
test "forbidden JLCPCB names use a neutral fabrication basename" {
    try std.testing.expectEqualStrings("board", prefix("rf-switch-eval"));
    try std.testing.expectEqualStrings("board", prefix("MyCopyBoard"));
    try std.testing.expectEqualStrings("board", prefix("unsafe board"));
    try std.testing.expectEqualStrings("rf-switch-rev-f", prefix("rf-switch-rev-f"));
}
