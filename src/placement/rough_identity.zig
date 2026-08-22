//! Stable identity rules for rough-placement hubs and authored anchors.

const std = @import("std");
const env = @import("../eval/env.zig");

fn leaf(name: []const u8) []const u8 {
    const slash = std.mem.lastIndexOfScalar(u8, name, '/');
    return if (slash) |i| name[i + 1 ..] else name;
}

/// Match an authored token against a flattened ref or stable origin key.
pub fn nameMatch(ref: []const u8, origin: []const u8, want: []const u8) bool {
    if (want.len == 0) return false;
    if (ref.len > 0 and (std.mem.eql(u8, ref, want) or std.mem.eql(u8, leaf(ref), want))) return true;
    return origin.len > 0 and (std.mem.eql(u8, origin, want) or std.mem.eql(u8, leaf(origin), want));
}

/// Apply the fallback ref-prefix hub/passive classification.
pub fn isHub(ref: []const u8) bool {
    const s = leaf(ref);
    if (s.len == 0) return true;
    return switch (s[0]) {
        'R', 'C', 'L', 'F', 'D', 'Y' => false,
        else => true,
    };
}

/// Classify a part while letting an explicit authored anchor override prefixes.
pub fn isHubForRough(ref: []const u8, origin: []const u8, rough: env.RoughSpec) bool {
    return isHub(ref) or nameMatch(ref, origin, rough.anchor);
}

// spec: placement/optimizer - (rough …) anchor/group tokens match by ref-des or origin name
test "rough identity matches authored names by ref or origin" {
    try std.testing.expect(nameMatch("U1", "", "U1"));
    try std.testing.expect(nameMatch("clk/U1", "", "U1"));
    try std.testing.expect(nameMatch("U17", "U1", "U1"));
    try std.testing.expect(!nameMatch("U2", "", "U1"));
}

// spec: placement/optimizer - an explicit rough anchor overrides a passive-looking ref-des prefix and is prepared as a hub
test "explicit rough anchor overrides a passive-looking prefix" {
    const rough = env.RoughSpec{ .anchor = "DIV1", .present = true };
    try std.testing.expect(isHubForRough("DIV1", "DIV1", rough));
    try std.testing.expect(isHubForRough("divider/U17", "DIV1", rough));
    try std.testing.expect(!isHubForRough("D2", "D_CLAMP", rough));
}
