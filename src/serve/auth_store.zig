//! Shared helpers for the auth sidecars (passkeys, OAuth clients/tokens, plugin
//! tokens, passwords) that each persist a JSON file under `<auth_dir>`. Every
//! store used to carry its own byte-identical copy of these two helpers; they
//! live here now so the directory-creation policy and the hash encoding have a
//! single definition.

const std = @import("std");
const infra_fs = @import("../infra/fs.zig");
const log = @import("../infra/log.zig");

const Sha256 = std.crypto.hash.sha2.Sha256;

/// Best-effort `mkdir -p <auth_dir>`. A failure is logged but not fatal — the
/// subsequent file write surfaces the real error to the caller.
pub fn ensureAuthDir(auth_dir: []const u8) void {
    infra_fs.cwd().makePath(auth_dir) catch |e| {
        log.warn("makePath {s} failed: {s}", .{ auth_dir, @errorName(e) });
    };
}

/// Lowercase-hex SHA-256 of `input` (64 chars). Caller owns the returned slice.
pub fn sha256Hex(allocator: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]u8 {
    var digest: [32]u8 = undefined;
    Sha256.hash(input, &digest, .{});
    const hex = "0123456789abcdef";
    var out = try allocator.alloc(u8, 64);
    for (digest, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
    return out;
}

test "sha256Hex matches a known vector" {
    const got = try sha256Hex(std.testing.allocator, "abc");
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings(
        "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        got,
    );
}
