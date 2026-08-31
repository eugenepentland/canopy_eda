//! Classification and validation for component `(datasheet "…")` values.
//!
//! A declaration may name an uploaded PDF in `lib/datasheets/` or point at
//! an HTTP(S) resource. Keeping this policy in one place prevents renderers
//! and mutation endpoints from disagreeing about which remote links are safe.

const std = @import("std");

/// True when `value` is a syntactically safe HTTP(S) URL.
pub fn isRemote(value: []const u8) bool {
    const separator = std.mem.indexOf(u8, value, "://") orelse return false;
    const scheme = value[0..separator];
    if (!std.ascii.eqlIgnoreCase(scheme, "http") and !std.ascii.eqlIgnoreCase(scheme, "https")) return false;
    const prefix_len = separator + "://".len;

    const authority = value[prefix_len..];
    if (authority.len == 0) return false;
    const host_end = std.mem.indexOfAny(u8, authority, "/?#") orelse authority.len;
    if (host_end == 0) return false;

    for (value) |c| if (isUnsafeUrlByte(c)) return false;
    return true;
}

/// True when `value` is a traversal-safe basename for `lib/datasheets/`.
///
/// The accepted byte set is the one `upload_datasheet.sanitizeFilename` WRITES,
/// `+` included: a Mini-Circuits part number carries one (`TSY-83LNW+.pdf`), and
/// a name the store can produce but this predicate rejects is a file that can be
/// written and never cited. `+` is inert here — it is neither a path separator
/// nor a shell metacharacter, and these names only ever become a
/// `lib/datasheets/<name>` path or a `/datasheets/<name>` URL path segment
/// (where `+` is literal; only query strings decode it as a space).
pub fn isLocal(value: []const u8) bool {
    if (value.len == 0 or value.len > 255) return false;
    if (std.mem.indexOf(u8, value, "..") != null) return false;
    if (std.mem.indexOfAny(u8, value, "/\\\"") != null) return false;
    for (value) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.' or c == '+';
        if (!ok) return false;
    }
    return true;
}

/// True when `value` is either a safe local basename or HTTP(S) URL.
pub fn isValid(value: []const u8) bool {
    return isLocal(value) or isRemote(value);
}

fn isUnsafeUrlByte(c: u8) bool {
    if (c <= 0x20 or c == 0x7f) return true;
    return switch (c) {
        '"', '\\', '<', '>' => true,
        else => false,
    };
}

test "datasheet refs accept local PDFs and HTTP URLs only" {
    try std.testing.expect(isLocal("QPL3050SR.pdf"));
    try std.testing.expect(isRemote("https" ++ "://example.com/QPL3050SR.pdf?rev=2"));
    try std.testing.expect(isRemote("HTTP" ++ "://example.com/datasheet"));
    try std.testing.expect(isValid("part.pdf"));
    try std.testing.expect(isValid("https" ++ "://example.com/part.pdf"));
    try std.testing.expect(!isValid("javascript:alert(1)"));
    try std.testing.expect(!isValid("https" ++ ":///missing-host.pdf"));
    try std.testing.expect(!isValid("https" ++ "://example.com/a b.pdf"));
    try std.testing.expect(!isValid("../secret.pdf"));
}
