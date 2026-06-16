//! Leak-regression tests for the serve auth/oauth/users stores.
//!
//! These stores keep their persistent rows in module-global lists allocated
//! from `std.heap.page_allocator` (process-lifetime, init-once — NOT leaks and
//! invisible to `std.testing.allocator`). The reload/refresh and CRUD paths are
//! audited by reading, not by these tests; see the audit findings returned with
//! this change.
//!
//! What IS testable here are the pure crypto helpers that take an allocator
//! parameter, return an owned slice, and free their own scratch. Driving them
//! through `std.testing.allocator` proves the owned slice is the *only* live
//! allocation when the call returns — any forgotten internal scratch makes the
//! leak detector panic at test end (idiom 1, OWNED-RETURN), and any internal
//! double-free / escape shows up immediately.

const std = @import("std");
const auth_store = @import("../serve/auth_store.zig");
const oauth_store = @import("../serve/oauth_store.zig");

// leak-audit: sha256Hex(allocator, input) returns a 64-char owned hex slice and
// allocates no scratch — the only live allocation must be the returned slice.
test "leak: auth_store.sha256Hex frees all but the owned return" {
    var ia = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ia.deinit();
    const input = try ia.allocator().dupe(u8, "the quick brown fox");

    const out = try auth_store.sha256Hex(std.testing.allocator, input);
    defer std.testing.allocator.free(out);
    try std.testing.expectEqual(@as(usize, 64), out.len);
}

// leak-audit: oauth_store.sha256Base64Url(allocator, input) allocates only the
// base64url output it returns; the SHA-256 digest is a stack buffer. testing.allocator
// catches any extra scratch left unfreed.
test "leak: oauth_store.sha256Base64Url frees all but the owned return" {
    var ia = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ia.deinit();
    const input = try ia.allocator().dupe(u8, "pkce-verifier-sample-value");

    const out = try oauth_store.sha256Base64Url(std.testing.allocator, input);
    defer std.testing.allocator.free(out);
    // S256 over any input is a 32-byte digest → 43 base64url chars (no padding).
    try std.testing.expectEqual(@as(usize, 43), out.len);
}

// leak-audit: verifyPkce allocates `expected` via sha256Base64Url and must free
// it with its own `defer` before returning the bool. A missing internal free
// here would panic the leak detector even though the function returns no memory.
test "leak: oauth_store.verifyPkce frees its internal scratch (true path)" {
    var ia = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ia.deinit();
    const verifier = try ia.allocator().dupe(u8, "a-code-verifier-string-of-some-length");

    // Compute the matching S256 challenge so we exercise the equal/true branch.
    const challenge = try oauth_store.sha256Base64Url(std.testing.allocator, verifier);
    defer std.testing.allocator.free(challenge);

    const ok = try oauth_store.verifyPkce(std.testing.allocator, verifier, challenge);
    try std.testing.expect(ok);
}

// leak-audit: same internal-free contract on the mismatch/false branch — the
// scratch must be freed regardless of which way the comparison goes.
test "leak: oauth_store.verifyPkce frees its internal scratch (false path)" {
    var ia = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer ia.deinit();
    const verifier = try ia.allocator().dupe(u8, "verifier-value");
    const wrong_challenge = try ia.allocator().dupe(u8, "this-is-not-the-right-challenge");

    const ok = try oauth_store.verifyPkce(std.testing.allocator, verifier, wrong_challenge);
    try std.testing.expect(!ok);
}
