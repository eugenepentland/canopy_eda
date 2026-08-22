//! Runtime build identity for exported review artifacts and diagnostics.
//!
//! Production receives `.git/netlisp-deploy-id` from the checksum-verified
//! release candidate at deployment time. Keeping that commit identity out of
//! the compiler input graph lets Zig reuse an unchanged ReleaseSafe executable
//! across documentation/config-only commits. Local Debug binaries fall back to
//! the checkout's git metadata, preserving useful development stamps without
//! making HEAD a compiler input.

const std = @import("std");
const builtin = @import("builtin");
const githash = @import("githash.zig");
const infra_fs = @import("infra/fs.zig");

const unknown = "unknown";
const deploy_id_path = ".git/netlisp-deploy-id";

/// Resolve the runtime build identity. A deployment-provided value
/// must be exactly the same nine lowercase hexadecimal characters produced by
/// `githash.shortHash`; malformed metadata is ignored in favor of the checkout
/// fallback. Any returned allocation belongs to `allocator`.
pub fn load(
    io: std.Io,
    allocator: std.mem.Allocator,
    repo_root: []const u8,
) []const u8 {
    if (deploymentId(allocator, repo_root)) |id| return id;
    return githash.shortHash(io, allocator, repo_root) orelse unknown;
}

/// Return the identity installed by the executable root during initialization.
/// Tests have their own root and deliberately use a stable sentinel.
pub fn current() []const u8 {
    if (builtin.is_test) return "test";
    return @import("root").process_build_id;
}

fn deploymentId(allocator: std.mem.Allocator, repo_root: []const u8) ?[]const u8 {
    const path = std.fs.path.join(allocator, &.{ repo_root, deploy_id_path }) catch return null;
    defer allocator.free(path);
    const raw = infra_fs.cwd().readFileAlloc(allocator, path, 64) catch return null;
    defer allocator.free(raw);
    const trimmed = std.mem.trim(u8, raw, " \t\r\n");
    if (!valid(trimmed)) return null;
    return allocator.dupe(u8, trimmed) catch null;
}

fn valid(raw: []const u8) bool {
    if (raw.len != githash.short_len) return false;
    for (raw) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

fn freeResolved(allocator: std.mem.Allocator, resolved: []const u8) void {
    if (!std.mem.eql(u8, resolved, unknown)) allocator.free(resolved);
}

// spec: Development pipeline - Resolves build identity at runtime without making each commit a compiler input

test "deployment build id wins only when it is canonical" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, ".git", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = deploy_id_path, .data = "abcdef012\n" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);

    const from_deploy = load(std.testing.io, std.testing.allocator, root);
    defer std.testing.allocator.free(from_deploy);
    try std.testing.expectEqualStrings("abcdef012", from_deploy);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = deploy_id_path, .data = "ABCDEF012\n" });
    try std.testing.expectEqualStrings(unknown, load(std.testing.io, std.testing.allocator, root));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = deploy_id_path, .data = "../../bad\n" });
    try std.testing.expectEqualStrings(unknown, load(std.testing.io, std.testing.allocator, root));
}

test "runtime build id falls back to git metadata" {
    const resolved = load(std.testing.io, std.testing.allocator, ".");
    defer freeResolved(std.testing.allocator, resolved);
    try std.testing.expectEqual(@as(usize, githash.short_len), resolved.len);
}
