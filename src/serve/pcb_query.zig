//! Request-query primitives shared by the PCB page and its small serve-layer
//! consumers. Keeps query decoding and the sidecar-scope security boundary in
//! one place instead of growing the already-large page renderer.

const std = @import("std");
const httpz = @import("httpz");

/// Longest accepted sub-block scope. The value is copied into a sidecar path,
/// so it is deliberately much smaller than an arbitrary HTTP query value.
pub const sub_slug_max_len = 128;

/// Accept exactly review.slugify's output alphabet. This rejects traversal,
/// separators, NUL, and percent-decoded path syntax before path construction.
pub fn isValidSubSlug(s: []const u8) bool {
    if (s.len == 0 or s.len > sub_slug_max_len) return false;
    for (s) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
        if (!ok) return false;
    }
    return true;
}

/// Return a validated `?sub=` scope or null for an absent/unsafe value.
pub fn subSlug(req: ?*httpz.Request) ?[]const u8 {
    const r = req orelse return null;
    const q = r.query() catch return null;
    const s = q.get("sub") orelse return null;
    return if (isValidSubSlug(s)) s else null;
}

/// Read a boolean query flag, treating absent, empty, and `0` as false.
pub fn flag(req: ?*httpz.Request, key: []const u8) bool {
    const r = req orelse return false;
    const q = r.query() catch return false;
    const v = q.get(key) orelse return false;
    return !(v.len == 0 or std.mem.eql(u8, v, "0"));
}

/// Read a raw query value, preserving a present empty string.
pub fn raw(req: ?*httpz.Request, key: []const u8) ?[]const u8 {
    const r = req orelse return null;
    const q = r.query() catch return null;
    return q.get(key);
}

/// Read a non-empty query value, mapping absent or empty to null.
pub fn opt(req: ?*httpz.Request, key: []const u8) ?[]const u8 {
    const value = raw(req, key) orelse return null;
    return if (value.len == 0) null else value;
}

/// Parse a query float, returning the PCB option sentinel `-1` on failure.
pub fn floatOpt(req: *httpz.Request, key: []const u8) f64 {
    const value = raw(req, key) orelse return -1;
    return std.fmt.parseFloat(f64, value) catch -1;
}

/// Split a comma query value into trimmed, non-empty arena-backed tokens.
pub fn csv(arena: std.mem.Allocator, req: *httpz.Request, key: []const u8) []const []const u8 {
    const value = raw(req, key) orelse return &.{};
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.tokenizeScalar(u8, value, ',');
    while (it.next()) |token| {
        const trimmed = std.mem.trim(u8, token, " \t");
        if (trimmed.len > 0) list.append(arena, trimmed) catch break;
    }
    return list.toOwnedSlice(arena) catch &.{};
}
