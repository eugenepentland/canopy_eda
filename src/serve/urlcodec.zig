//! The one percent-decoder for HTTP path parameters.
//!
//! httpz hands `:param` values over verbatim, so every handler that turns one
//! into a filesystem or design lookup has to decode it first — and six handlers
//! grew their own byte-identical private copy doing exactly that. This module is
//! the canonical home guardian's `percent-decode-wrapper` idiom rule names; new
//! handlers call it instead of adding a seventh copy, and the existing copies
//! fold in as they are touched.

const std = @import("std");

/// Percent-decode a path parameter onto `allocator`.
///
/// The returned slice is always the caller's to keep — never a view into
/// httpz's request buffer — and its length matches its allocation, so a caller
/// on a general-purpose allocator can `free` it. That is the one thing the six
/// private copies get wrong: `std.Uri.percentDecodeInPlace` hands back a
/// SHORTER view of the buffer it decoded into, and freeing that view is an
/// invalid free. It never bit them because every one of them runs on a request
/// arena; a canonical helper should not carry the trap forward.
///
/// Invalid escapes are left as written by `percentDecodeInPlace` — a stray `%`
/// in a design name is a character, not a parse failure.
pub fn decodeAlloc(allocator: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error![]u8 {
    const scratch = try allocator.dupe(u8, raw);
    defer allocator.free(scratch);
    return allocator.dupe(u8, std.Uri.percentDecodeInPlace(scratch));
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

// spec: serve/urlcodec - a decoded path parameter is a fresh copy the caller owns and can free, leaving an invalid escape as written
test "decodeAlloc copies before decoding and keeps a stray percent" {
    const raw = "pdf%20demo";
    // Every `free` here is the assertion: the testing allocator panics on an
    // invalid free, so a slice whose length did not match its allocation would
    // fail this test rather than pass it silently on an arena.
    const got = try decodeAlloc(testing.allocator, raw);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("pdf demo", got);
    // The source is untouched — the decode ran over the copy, so a handler may
    // keep the result after the request buffer is gone.
    try testing.expectEqualStrings("pdf%20demo", raw);

    // A percent that begins no valid escape is a character in a design name,
    // not a request to reject.
    const literal = try decodeAlloc(testing.allocator, "100%25");
    defer testing.allocator.free(literal);
    try testing.expectEqualStrings("100%", literal);

    const stray = try decodeAlloc(testing.allocator, "50%off");
    defer testing.allocator.free(stray);
    try testing.expectEqualStrings("50%off", stray);
}
