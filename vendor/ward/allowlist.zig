//! Public-route allowlist — decides whether a request path skips verification.
//!
//! Each entry is either an exact path (`/healthz`) or a prefix written with a
//! trailing `/*` (`/public/*`), which matches the prefix base and anything
//! beneath it at a path boundary — so `/public/*` covers `/public` and
//! `/public/app.css` but not `/publicity`. Pure: no allocation, no I/O.

const std = @import("std");

/// Suffix marking a prefix (subtree) allowlist entry, e.g. `/public/*`.
const prefix_suffix = "/*";

/// A per-app list of public route patterns, matched against a request path.
pub const Allowlist = struct {
    /// Borrowed patterns: exact paths, or `<base>/*` prefix (subtree) entries.
    patterns: []const []const u8,

    /// Reports whether `path` is public and may bypass verification.
    pub fn isPublic(self: Allowlist, path: []const u8) bool {
        for (self.patterns) |pattern| {
            if (matches(pattern, path)) return true;
        }
        return false;
    }
};

/// Matches one allowlist pattern against `path` with exact-or-prefix semantics.
fn matches(pattern: []const u8, path: []const u8) bool {
    if (std.mem.endsWith(u8, pattern, prefix_suffix)) {
        const base = pattern[0 .. pattern.len - prefix_suffix.len];
        if (std.mem.eql(u8, path, base)) return true;
        return isUnder(path, base);
    }
    return std.mem.eql(u8, pattern, path);
}

/// Reports whether `path` lies strictly beneath `base` at a `/` boundary.
fn isUnder(path: []const u8, base: []const u8) bool {
    if (path.len <= base.len) return false;
    if (!std.mem.startsWith(u8, path, base)) return false;
    return path[base.len] == '/';
}

const exact_list = [_][]const u8{"/healthz"};
const prefix_list = [_][]const u8{"/public/*"};

// spec: Public-route allowlist - An exact allowlist entry bypasses verification only for its own path
test "exact entry matches only its own path" {
    const list = Allowlist{ .patterns = &exact_list };
    try std.testing.expect(list.isPublic("/healthz"));
    try std.testing.expect(!list.isPublic("/healthz/deep"));
}

// spec: Public-route allowlist - A path beneath an allowlisted prefix bypasses verification
test "prefix entry matches a path beneath it" {
    const list = Allowlist{ .patterns = &prefix_list };
    try std.testing.expect(list.isPublic("/public/app.css"));
}

// spec: Public-route allowlist - A prefix allowlist entry ignores a path that merely shares its leading text
test "prefix entry ignores a sibling that shares leading text" {
    const list = Allowlist{ .patterns = &prefix_list };
    try std.testing.expect(!list.isPublic("/publicity"));
}

// spec: Public-route allowlist - A path matching no allowlist entry still requires verification
test "unlisted path is not public" {
    const list = Allowlist{ .patterns = &exact_list };
    try std.testing.expect(!list.isPublic("/secret"));
}
