//! Leak-regression tests for the serve auth stores' pure crypto helpers.
//!
//! The stores keep their persistent rows in module-global lists allocated from
//! `std.heap.page_allocator` (process-lifetime, init-once — NOT leaks and
//! invisible to `std.testing.allocator`). What IS testable here are the pure
//! crypto helpers that take an allocator parameter, return an owned slice, and
//! free their own scratch. Driving them through `std.testing.allocator` proves
//! the owned slice is the *only* live allocation when the call returns — any
//! forgotten internal scratch makes the leak detector panic at test end
//! (idiom 1, OWNED-RETURN), and any internal double-free / escape shows up
//! immediately. (The OAuth/PKCE helpers this file also covered went away with
//! the homegrown OAuth server in the ward migration.)

const std = @import("std");
const auth_store = @import("../serve/auth_store.zig");

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
