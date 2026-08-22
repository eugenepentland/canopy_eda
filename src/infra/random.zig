//! Random port. All RNG construction and direct entropy reads in
//! production code go through this module so Guardian's `ban-rng`
//! check has one whitelisted entry point. Thin re-exports — this is
//! a boundary marker, not an abstraction.
//!
//! Usage:
//!     const infra_random = @import("infra/random.zig");
//!     var bytes: [32]u8 = undefined;
//!     infra_random.bytes(&bytes);

const std = @import("std");

/// Fill `buf` with cryptographically-secure random bytes.
pub fn bytes(buf: []u8) std.Io.RandomSecureError!void {
    return bytesWithIo(@import("fs.zig").currentIo(), buf);
}

fn bytesWithIo(io: std.Io, buf: []u8) std.Io.RandomSecureError!void {
    return std.Io.randomSecure(io, buf);
}

test "secure entropy failure propagates without a fallback" {
    var buf: [16]u8 = undefined;
    try std.testing.expectError(error.EntropyUnavailable, bytesWithIo(std.Io.failing, &buf));
}
