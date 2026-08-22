//! HEAD short-hash resolution by direct git metadata reads, used as the local
//! runtime fallback when deployment metadata does not provide a build ID.
//!
//! The stamp used to shell out to `git rev-parse --short HEAD` at every
//! build-configure, and ANY subprocess failure returned "unknown" — verified
//! 2026-08-10: concurrent git activity from other agent sessions failed the
//! subprocess mid-build, the old compiled stamp flipped to "unknown", and the
//! test binary + exe recompiled (~5-6 min), then recompiled AGAIN once git
//! succeeded. Runtime direct reads cannot be disturbed that way: git updates refs
//! by atomic rename, so a reader sees the old or the new value, never a
//! missing file, and the loose-ref → packed-refs fallback covers the
//! `git pack-refs` pruning window. "unknown" is left meaning only a genuinely
//! absent or unresolvable `.git`.

const std = @import("std");

/// Stamp width. `git rev-parse --short` picks 7+ chars by uniqueness; a fixed
/// 9 stays unique far past this repo's size and keeps the stamp deterministic
/// across object-count growth.
pub const short_len = 9;

/// HEAD / loose refs / pointer files are single lines.
const max_meta_bytes = 64 * 1024;
/// packed-refs holds one line per packed ref.
const max_packed_refs_bytes = 16 * 1024 * 1024;

/// Resolve `repo_root/.git` to HEAD's short commit hash, or null when no
/// usable `.git` exists there (the caller's "unknown"). The result is
/// allocated from `gpa`; all scratch lives in an internal arena.
pub fn shortHash(io: std.Io, gpa: std.mem.Allocator, repo_root: []const u8) ?[]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const full = resolveHead(io, arena, repo_root) orelse return null;
    if (full.len < short_len or !isHex(full)) return null;
    return gpa.dupe(u8, full[0..short_len]) catch null;
}

fn resolveHead(io: std.Io, arena: std.mem.Allocator, repo_root: []const u8) ?[]const u8 {
    const gitdir = gitDir(io, arena, repo_root) orelse return null;
    const head = readTrimmed(io, arena, gitdir, "HEAD", max_meta_bytes) orelse return null;
    if (std.mem.startsWith(u8, head, "ref: ")) {
        const refname = std.mem.trim(u8, head["ref: ".len..], " \t");
        return resolveRef(io, arena, gitdir, refname);
    }
    return head; // detached HEAD: the file holds the commit itself
}

/// `.git` as a directory IS the git dir; as a file it is a worktree /
/// submodule pointer (`gitdir: <path>`, absolute or repo-root-relative).
fn gitDir(io: std.Io, arena: std.mem.Allocator, repo_root: []const u8) ?[]const u8 {
    const dot_git = std.fs.path.join(arena, &.{ repo_root, ".git" }) catch return null;
    if (std.Io.Dir.cwd().openDir(io, dot_git, .{})) |dir| {
        var opened = dir;
        opened.close(io);
        return dot_git;
    } else |err| if (err != error.NotDir) return null;
    const pointer = readTrimmed(io, arena, repo_root, ".git", max_meta_bytes) orelse return null;
    if (!std.mem.startsWith(u8, pointer, "gitdir:")) return null;
    const target = std.mem.trim(u8, pointer["gitdir:".len..], " \t");
    if (std.fs.path.isAbsolute(target)) return target;
    return std.fs.path.resolve(arena, &.{ repo_root, target }) catch null;
}

/// A linked worktree's gitdir holds only per-worktree state (HEAD among it);
/// shared refs live in the main repository's git dir, named by `commondir`.
fn commonDir(io: std.Io, arena: std.mem.Allocator, gitdir: []const u8) []const u8 {
    const rel = readTrimmed(io, arena, gitdir, "commondir", max_meta_bytes) orelse return gitdir;
    if (std.fs.path.isAbsolute(rel)) return rel;
    return std.fs.path.resolve(arena, &.{ gitdir, rel }) catch gitdir;
}

fn resolveRef(io: std.Io, arena: std.mem.Allocator, gitdir: []const u8, refname: []const u8) ?[]const u8 {
    if (readTrimmed(io, arena, gitdir, refname, max_meta_bytes)) |hash| return hash;
    const common = commonDir(io, arena, gitdir);
    if (!std.mem.eql(u8, common, gitdir)) {
        if (readTrimmed(io, arena, common, refname, max_meta_bytes)) |hash| return hash;
    }
    return packedRef(io, arena, common, refname);
}

/// Scan packed-refs for `<hash> <refname>`, skipping `#` headers and `^`
/// peeled-tag lines. This is where a ref lands after `git pack-refs` prunes
/// its loose file — the window a loose-ref read alone would miss.
fn packedRef(io: std.Io, arena: std.mem.Allocator, common: []const u8, refname: []const u8) ?[]const u8 {
    const data = readTrimmed(io, arena, common, "packed-refs", max_packed_refs_bytes) orelse return null;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] == '#' or line[0] == '^') continue;
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const name = std.mem.trim(u8, line[space + 1 ..], " \t\r");
        if (std.mem.eql(u8, name, refname)) return line[0..space];
    }
    return null;
}

fn readTrimmed(
    io: std.Io,
    arena: std.mem.Allocator,
    dir_path: []const u8,
    sub_path: []const u8,
    max_bytes: usize,
) ?[]const u8 {
    const path = std.fs.path.join(arena, &.{ dir_path, sub_path }) catch return null;
    const data = std.Io.Dir.cwd().readFileAlloc(io, path, arena, .limited64(max_bytes)) catch return null;
    const trimmed = std.mem.trim(u8, data, " \t\r\n");
    return if (trimmed.len == 0) null else trimmed;
}

fn isHex(s: []const u8) bool {
    for (s) |c| switch (c) {
        '0'...'9', 'a'...'f', 'A'...'F' => {},
        else => return false,
    };
    return true;
}

test "shortHash resolves a loose branch ref without spawning git" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".git/refs/heads");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = ".git/HEAD", .data = "ref: refs/heads/main\n" });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = ".git/refs/heads/main",
        .data = "0123456789abcdef0123456789abcdef01234567\n",
    });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    const hash = shortHash(std.testing.io, std.testing.allocator, root).?;
    defer std.testing.allocator.free(hash);
    try std.testing.expectEqualStrings("012345678", hash);
    // This checkout itself resolves through the same reads (tests run from the
    // repository root, which is always a git checkout or linked worktree here).
    const live = shortHash(std.testing.io, std.testing.allocator, ".") orelse return error.LiveCheckoutUnresolved;
    defer std.testing.allocator.free(live);
    try std.testing.expectEqual(@as(usize, short_len), live.len);
}

// spec: Development pipeline - Follows a worktree gitdir pointer and commondir to the shared refs, with packed-refs and detached HEAD fallbacks

test "shortHash follows worktree pointers packed refs and detached HEAD" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "main/.git/worktrees/wt");
    try tmp.dir.createDirPath(std.testing.io, "main/.git/refs/heads");
    try tmp.dir.createDirPath(std.testing.io, "wt");
    // The branch is packed (loose file pruned), as after `git pack-refs`.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "main/.git/packed-refs", .data = "# pack-refs with: peeled fully-peeled sorted\n" ++
        "1111111111222222222233333333334444444444 refs/heads/feature\n" ++
        "^aaaaaaaaaabbbbbbbbbbccccccccccdddddddddd\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "main/.git/worktrees/wt/HEAD", .data = "ref: refs/heads/feature\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "main/.git/worktrees/wt/commondir", .data = "../..\n" });
    const main_root = try tmp.dir.realPathFileAlloc(std.testing.io, "main", std.testing.allocator);
    defer std.testing.allocator.free(main_root);
    const pointer = try std.fmt.allocPrint(
        std.testing.allocator,
        "gitdir: {s}/.git/worktrees/wt\n",
        .{main_root},
    );
    defer std.testing.allocator.free(pointer);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "wt/.git", .data = pointer });
    const wt_root = try tmp.dir.realPathFileAlloc(std.testing.io, "wt", std.testing.allocator);
    defer std.testing.allocator.free(wt_root);
    const packed_hash = shortHash(std.testing.io, std.testing.allocator, wt_root).?;
    defer std.testing.allocator.free(packed_hash);
    try std.testing.expectEqualStrings("111111111", packed_hash);
    // Detached HEAD in the main checkout: HEAD holds the commit itself.
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "main/.git/HEAD",
        .data = "fedcba9876543210fedcba9876543210fedcba98\n",
    });
    const detached = shortHash(std.testing.io, std.testing.allocator, main_root).?;
    defer std.testing.allocator.free(detached);
    try std.testing.expectEqualStrings("fedcba987", detached);
}

test "shortHash yields null outside a checkout" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", std.testing.allocator);
    defer std.testing.allocator.free(root);
    try std.testing.expect(shortHash(std.testing.io, std.testing.allocator, root) == null);
}
