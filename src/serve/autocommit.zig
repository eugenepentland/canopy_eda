//! Best-effort per-mutation git auto-commit for the MCP mutation surface.
//!
//! Every authenticated MCP mutation tool (write_file, edit_file, delete_file,
//! move_file, build, restore_version, download_*, import_kicad, the design-note
//! / requirement / pcb-layout tools, …) writes files under `--project-dir`,
//! which in production is its own git checkout. Left alone, each mutation lands
//! as an anonymous uncommitted working-tree change: no attribution, no durable
//! history, no recoverability. This module commits exactly that mutation's file
//! changes to git, authored as the acting ward user.
//!
//! ## The seam
//!
//! `mcp.zig`'s tool dispatcher is the single choke point every mutation flows
//! through, so the whole feature hangs off two calls there and needs no edits
//! to the (frozen) `mcp_tools.zig` handlers:
//!
//!   1. `begin` — run BEFORE the mutation. Snapshots the repo's already-dirty
//!      paths (the loose human work to protect) and returns a `Session`. Returns
//!      null when auto-commit is disabled, the dir is not a git repo, or git is
//!      unavailable — the caller then skips step 2.
//!   2. `commit` — run AFTER a SUCCESSFUL mutation. Re-snapshots the dirty set,
//!      takes the paths that are newly dirty (`after − before`), and commits just
//!      those. Anything already dirty in `before` (a human's mid-edit) is never
//!      swept in, and `history/` snapshots and `*.bak-*`/backup artifacts are
//!      always excluded even if a code path reports them.
//!
//! Deriving the touched paths from a before/after status diff — rather than from
//! each tool's arguments — makes ONE seam cover the whole mutation surface,
//! including the tools whose output set is dynamic (import_kicad, download_*).
//!
//! ## Guarantees
//!
//! * **Path-scoped.** Never `git add .`/`-A` over the tree — only the specific
//!   touched paths are staged (`git add -A -- <paths>`, which also stages
//!   deletions) and committed with a pathspec, so other staged or loose work is
//!   left exactly as it was.
//! * **Attributed.** `--author` is the acting ward user (`<name> <name@ward>`);
//!   the committer stays the server (`netlisp <netlisp@server>`). The dev-bypass
//!   path authors as the dev-admin identity.
//! * **Fail-open.** git missing, not a repo, a lost commit race, or any non-zero
//!   git exit is logged to stderr and swallowed — the mutation already succeeded,
//!   so no error ever propagates to the MCP client.
//! * **Serialized.** A single module mutex serializes the git index operations,
//!   since the httpz server is multi-threaded.

const std = @import("std");
const log = @import("../infra/log.zig");
const config = @import("../config.zig");
const subprocess = @import("subprocess.zig");

// ── Constants ─────────────────────────────────────────────────────

/// Committer identity (the server itself), set with `-c` on the commit so a repo
/// with no configured `user.name`/`user.email` still commits cleanly.
const committer_name = "netlisp";
const committer_email = "netlisp@server";

/// Author identity used when there is no ward user (the local-dev bypass).
const dev_author = "netlisp-dev";

/// Ward has no email for a user, so the author email is synthesized as
/// `<username>@ward`.
const author_domain = "ward";

/// git subprocess guards. `git status` on a busy design repo stays well under a
/// few hundred KiB; the cap and wall-clock deadline exist only so a wedged git
/// can never pin a request thread (a timeout is treated as fail-open).
const git_output_cap: usize = 8 << 20;
const git_timeout_ms: u64 = 10_000;

/// How many touched paths to spell out in the commit subject before summarizing
/// the rest as `(+N more)` — keeps the one-line message greppable but bounded.
const msg_path_cap: usize = 8;

/// Serializes the git index operations (`add` + `commit`) across the
/// multi-threaded server: one in-flight index operation at a time. Held in a
/// container-scope namespace (not a bare file-scope `var`) so the state has an
/// owner rather than being loose global mutable state.
const GitLock = struct {
    var mu: std.Thread.Mutex = .{};
};

const PathSet = std.StringHashMapUnmanaged(void);

/// Captured before a mutation so `commit` can tell the mutation's own file
/// changes apart from pre-existing loose work. Backed by the caller's
/// (request-arena) allocator; `deinit` releases the before-set (a no-op under an
/// arena, but correct for any other allocator).
pub const Session = struct {
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    /// The set of project-relative paths already dirty before the mutation.
    before: PathSet,

    pub fn deinit(self: *Session) void {
        self.before.deinit(self.allocator);
    }
};

// ── Public API ────────────────────────────────────────────────────

/// Snapshot the repo state before a mutation. Returns null — so the caller skips
/// the commit entirely — when auto-commit is disabled, `project_dir` is not a
/// git repo, or git is unavailable. `allocator` should be the request arena; the
/// returned session borrows it.
pub fn begin(allocator: std.mem.Allocator, project_dir: []const u8) ?Session {
    if (!config.gitAutocommitEnabled(allocator)) return null;
    // A successful `git status` doubles as the is-a-repo check: it exits
    // non-zero outside a work tree, which `collectStatus` reports as null.
    const before = collectStatus(allocator, project_dir) orelse return null;
    return .{ .allocator = allocator, .project_dir = project_dir, .before = before };
}

/// Commit the paths this mutation touched (`after − before`), authored as
/// `username` (null → the dev-admin identity), with `tool_name` in the subject.
/// A no-op when `session` is null. Fail-open: every git failure is logged and
/// swallowed so it can never surface to the MCP client.
pub fn commit(session: ?Session, username: ?[]const u8, tool_name: []const u8) void {
    const s = session orelse return;
    // Hold the index lock across the after-snapshot AND the stage/commit so no
    // other autocommit can interleave between measuring and committing.
    GitLock.mu.lock();
    defer GitLock.mu.unlock();
    commitLocked(s, username, tool_name);
}

// ── Internals ─────────────────────────────────────────────────────

fn commitLocked(s: Session, username: ?[]const u8, tool_name: []const u8) void {
    const after = collectStatus(s.allocator, s.project_dir) orelse return;
    const touched = touchedPaths(s.allocator, s.before, after) catch |e| {
        log.warn("autocommit: collecting touched paths failed: {s}", .{@errorName(e)});
        return;
    };
    if (touched.len == 0) return;

    stageAndCommit(s.allocator, s.project_dir, touched, username, tool_name);
}

/// The project-relative paths dirty in `after` but not in `before`, with
/// `history/` and backup artifacts filtered out. Order is unspecified.
fn touchedPaths(
    allocator: std.mem.Allocator,
    before: PathSet,
    after: PathSet,
) std.mem.Allocator.Error![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var it = after.keyIterator();
    while (it.next()) |k| {
        const path = k.*;
        if (before.contains(path)) continue;
        if (isExcluded(path)) continue;
        try list.append(allocator, path);
    }
    // An exact-length owned slice so a non-arena caller (the unit test) can free
    // it without a capacity mismatch.
    return list.toOwnedSlice(allocator);
}

/// Paths that must never enter an auto-commit even if git reports them dirty:
/// the design-history snapshot tree and any `*.bak-*`/`backups/` artifact.
fn isExcluded(path: []const u8) bool {
    if (std.mem.startsWith(u8, path, "history/")) return true;
    if (std.mem.startsWith(u8, path, "backups/")) return true;
    if (std.mem.indexOf(u8, path, "/backups/") != null) return true;
    if (std.mem.indexOf(u8, path, ".bak-") != null) return true;
    return false;
}

/// Run `git status --porcelain -z` in `project_dir` and parse the dirty paths
/// into a set. Returns null on any git failure (git missing, not a repo, timed
/// out, or non-zero exit) so the caller fails open.
fn collectStatus(allocator: std.mem.Allocator, project_dir: []const u8) ?PathSet {
    // NUL-terminated (`-z`) so paths are verbatim (never quoted/escaped);
    // default untracked mode collapses a wholly-untracked dir to one entry
    // (cheap, and `git add -- <dir>/` still stages it) while a new file inside a
    // TRACKED dir — where every mutation writes — is listed individually.
    const argv = [_][]const u8{ "git", "-C", project_dir, "status", "--porcelain", "-z" };
    const res = subprocess.runCaptured(allocator, &argv, git_output_cap, git_timeout_ms) catch |e| {
        log.warn("autocommit: git status spawn failed: {s}", .{@errorName(e)});
        return null;
    };
    if (res.outcome != .ok or (res.exit_code orelse 1) != 0) return null;

    var set: PathSet = .empty;
    parseStatusZ(allocator, res.stdout, &set) catch |e| {
        log.warn("autocommit: parsing git status failed: {s}", .{@errorName(e)});
        return null;
    };
    return set;
}

/// Parse `git status --porcelain -z` output into the set of dirty paths. Each
/// record is `XY<space>PATH\0`; a rename/copy (`R`/`C` in either status column)
/// carries a second `\0`-terminated field, the source path, which is added too.
fn parseStatusZ(allocator: std.mem.Allocator, data: []const u8, set: *PathSet) std.mem.Allocator.Error!void {
    var it = std.mem.splitScalar(u8, data, 0);
    while (it.next()) |seg| {
        if (seg.len < 4 or seg[2] != ' ') continue; // not a status record
        const x = seg[0];
        const y = seg[1];
        try set.put(allocator, seg[3..], {});
        if (x == 'R' or x == 'C' or y == 'R' or y == 'C') {
            // Rename/copy source path is the next NUL-terminated field.
            if (it.next()) |src| {
                if (src.len > 0) try set.put(allocator, src, {});
            }
        }
    }
}

/// Stage exactly `paths` and commit only them, authored as the ward user. Never
/// touches the rest of the index/tree. Fail-open on every git error.
fn stageAndCommit(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    paths: []const []const u8,
    username: ?[]const u8,
    tool_name: []const u8,
) void {
    // Stage exactly these paths. `add -A -- <paths>` records modifications,
    // additions, AND deletions for the given pathspecs and nothing else.
    var add_argv: std.ArrayList([]const u8) = .empty;
    add_argv.appendSlice(allocator, &.{ "git", "-C", project_dir, "add", "-A", "--" }) catch return;
    add_argv.appendSlice(allocator, paths) catch return;
    if (!runGit(allocator, add_argv.items, "add")) return;

    const author = authorArg(allocator, username) catch return;
    const msg = commitMessage(allocator, tool_name, paths) catch return;

    // `commit -- <paths>` commits only the pathspec (implicit --only): other
    // staged/loose work is left untouched. `-c user.*` supplies the committer so
    // a repo without a configured identity still commits. Empty-diff exits
    // non-zero ("nothing to commit"); runGit reports it, and it is benign.
    var commit_argv: std.ArrayList([]const u8) = .empty;
    commit_argv.appendSlice(allocator, &.{
        "git",
        "-c",
        "user.name=" ++ committer_name,
        "-c",
        "user.email=" ++ committer_email,
        "-C",
        project_dir,
        "commit",
        "--author",
        author,
        "-m",
        msg,
        "--",
    }) catch return;
    commit_argv.appendSlice(allocator, paths) catch return;
    _ = runGit(allocator, commit_argv.items, "commit");
}

/// Run a git subprocess, returning true only on a clean zero exit. Any spawn
/// failure, timeout, or non-zero exit is logged and reported false — the caller
/// fails open.
fn runGit(allocator: std.mem.Allocator, argv: []const []const u8, label: []const u8) bool {
    const res = subprocess.runCaptured(allocator, argv, git_output_cap, git_timeout_ms) catch |e| {
        log.warn("autocommit: git {s} spawn failed: {s}", .{ label, @errorName(e) });
        return false;
    };
    if (res.outcome != .ok) {
        log.warn("autocommit: git {s} did not complete ({s})", .{ label, @tagName(res.outcome) });
        return false;
    }
    if ((res.exit_code orelse 1) != 0) {
        log.warn("autocommit: git {s} exited {?d}", .{ label, res.exit_code });
        return false;
    }
    return true;
}

/// The `--author` value for the commit: `<name> <name@ward>`, using the ward
/// username or, when there is none (the dev bypass) or it is empty, the
/// dev-admin identity.
fn authorArg(allocator: std.mem.Allocator, username: ?[]const u8) std.mem.Allocator.Error![]const u8 {
    const name = if (username) |u| (if (u.len > 0) u else dev_author) else dev_author;
    return std.fmt.allocPrint(allocator, "{s} <{s}@{s}>", .{ name, name, author_domain });
}

/// A one-line, greppable commit subject: `mcp: <tool> <paths…>`, listing up to
/// `msg_path_cap` paths and summarizing any remainder as `(+N more)`.
fn commitMessage(
    allocator: std.mem.Allocator,
    tool_name: []const u8,
    paths: []const []const u8,
) std.mem.Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(allocator);
    try w.print("mcp: {s}", .{tool_name});
    const shown = @min(paths.len, msg_path_cap);
    for (paths[0..shown]) |p| try w.print(" {s}", .{p});
    if (paths.len > shown) try w.print(" (+{d} more)", .{paths.len - shown});
    return buf.toOwnedSlice(allocator);
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

test "authorArg attributes to the ward user and falls back to the dev identity" {
    // spec: Web Server - The auto-commit author is the ward user, falling back to the dev-admin identity
    const a = try authorArg(testing.allocator, "ada");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("ada <ada@ward>", a);

    // A null username (the dev bypass) authors as the dev-admin identity.
    const dev = try authorArg(testing.allocator, null);
    defer testing.allocator.free(dev);
    try testing.expectEqualStrings("netlisp-dev <netlisp-dev@ward>", dev);

    // An empty username is treated the same as absent.
    const empty = try authorArg(testing.allocator, "");
    defer testing.allocator.free(empty);
    try testing.expectEqualStrings("netlisp-dev <netlisp-dev@ward>", empty);
}

test "parseStatusZ reads porcelain paths including a rename's source" {
    // spec: Web Server - The auto-commit parses porcelain status into a dirty-path set including a rename's source
    var set: PathSet = .empty;
    defer set.deinit(testing.allocator);
    // A modified file, an untracked file, and a staged rename (two fields).
    const data = " M lib/a.sexp\x00?? src/new.sexp\x00R  src/dst.sexp\x00src/orig.sexp\x00";
    try parseStatusZ(testing.allocator, data, &set);
    try testing.expect(set.contains("lib/a.sexp"));
    try testing.expect(set.contains("src/new.sexp"));
    try testing.expect(set.contains("src/dst.sexp"));
    // The rename's source path is captured as its own entry, not mis-parsed.
    try testing.expect(set.contains("src/orig.sexp"));
    try testing.expectEqual(@as(u32, 4), set.count());
}

test "isExcluded rejects history and backup artifacts only" {
    // spec: Web Server - The auto-commit always excludes history snapshots and backup artifacts
    try testing.expect(isExcluded("history/foo/2026/foo.sexp"));
    try testing.expect(isExcluded("backups/board.bak"));
    try testing.expect(isExcluded("src/boards/x/x.kicad_pcb.bak-20260101"));
    try testing.expect(isExcluded("lib/modules/clock.layouts.json.bak-premigrate-x"));
    // Real design/library sources are never excluded.
    try testing.expect(!isExcluded("src/boards/x/x.sexp"));
    try testing.expect(!isExcluded("lib/components/part.sexp"));
}

test "touchedPaths keeps only newly-dirty, non-excluded paths" {
    // spec: Web Server - The auto-commit stages only new-or-changed paths, never pre-existing loose work
    var before: PathSet = .empty;
    defer before.deinit(testing.allocator);
    var after: PathSet = .empty;
    defer after.deinit(testing.allocator);

    // A file the human was already editing before the mutation.
    try before.put(testing.allocator, "src/loose.sexp", {});
    // After the mutation: the loose file is still dirty, plus the mutation's new
    // file, plus an excluded history snapshot.
    try after.put(testing.allocator, "src/loose.sexp", {});
    try after.put(testing.allocator, "src/mutated.sexp", {});
    try after.put(testing.allocator, "history/mutated/2026/mutated.sexp", {});

    const touched = try touchedPaths(testing.allocator, before, after);
    defer testing.allocator.free(touched);
    // Only the mutation's own new file — loose work and history are excluded.
    try testing.expectEqual(@as(usize, 1), touched.len);
    try testing.expectEqualStrings("src/mutated.sexp", touched[0]);
}

test "commitMessage is a one-line greppable subject with a path cap" {
    // spec: Web Server - The auto-commit message names the tool and touched paths on one greppable line
    const few = try commitMessage(testing.allocator, "edit_file", &.{ "a.sexp", "b.sexp" });
    defer testing.allocator.free(few);
    try testing.expectEqualStrings("mcp: edit_file a.sexp b.sexp", few);
    // Never spans multiple lines (greppable).
    try testing.expect(std.mem.indexOfScalar(u8, few, '\n') == null);

    // More than the cap summarizes the remainder.
    const many = try commitMessage(testing.allocator, "import_kicad", &.{
        "p0", "p1", "p2", "p3", "p4", "p5", "p6", "p7", "p8", "p9",
    });
    defer testing.allocator.free(many);
    try testing.expect(std.mem.startsWith(u8, many, "mcp: import_kicad p0 p1"));
    try testing.expect(std.mem.endsWith(u8, many, "(+2 more)"));
}

// ── git integration tests ─────────────────────────────────────────
// These shell out to a real `git`; they init a throwaway repo under
// `std.testing.tmpDir` and skip gracefully when git is unavailable.

/// Run git in `dir` for test setup, skipping the whole test if git is missing.
fn gitTest(allocator: std.mem.Allocator, dir: []const u8, args: []const []const u8) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "git", "-C", dir });
    try argv.appendSlice(allocator, args);
    const res = std.process.Child.run(.{ .allocator = allocator, .argv = argv.items }) catch
        return error.SkipZigTest; // git not installed
    defer allocator.free(res.stdout);
    defer allocator.free(res.stderr);
    if (res.term != .Exited or res.term.Exited != 0) return error.GitSetupFailed;
}

/// Absolute path of `sub` inside the test tmp dir.
fn tmpPath(allocator: std.mem.Allocator, tmp: *std.testing.TmpDir, sub: []const u8) ![]const u8 {
    const base = try tmp.dir.realpathAlloc(allocator, ".");
    defer allocator.free(base);
    return std.fs.path.join(allocator, &.{ base, sub });
}

test "commit stages only the mutation's paths and leaves loose work dirty" {
    // spec: Web Server - A per-mutation auto-commit records only touched paths as the ward user, sparing loose work
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmpPath(a, &tmp, ".");

    try gitTest(a, dir, &.{"init"});
    try gitTest(a, dir, &.{ "config", "user.email", "seed@test" });
    try gitTest(a, dir, &.{ "config", "user.name", "seed" });
    // Seed a committed baseline.
    try tmp.dir.writeFile(.{ .sub_path = "tracked.sexp", .data = "base\n" });
    try gitTest(a, dir, &.{ "add", "-A" });
    try gitTest(a, dir, &.{ "commit", "-m", "seed" });

    // Loose human work present before the mutation: an untracked file and a
    // mid-edit of the tracked file.
    try tmp.dir.writeFile(.{ .sub_path = "human_loose.txt", .data = "loose\n" });
    try tmp.dir.writeFile(.{ .sub_path = "tracked.sexp", .data = "base\nhuman edit\n" });

    const session = begin(a, dir) orelse return error.SkipZigTest;

    // The mutation: a brand-new source file.
    try tmp.dir.writeFile(.{ .sub_path = "mutated.sexp", .data = "new\n" });

    commit(session, "ada", "write_file");

    // HEAD is the auto-commit: authored by the ward user, committed by the
    // server, and touching ONLY the mutation's file.
    const fmt = try std.process.Child.run(.{
        .allocator = a,
        .argv = &.{ "git", "-C", dir, "log", "-1", "--pretty=%an|%ae|%cn|%ce|%s" },
    });
    try testing.expect(std.mem.indexOf(u8, fmt.stdout, "ada|ada@ward|netlisp|netlisp@server|") != null);
    try testing.expect(std.mem.indexOf(u8, fmt.stdout, "mcp: write_file mutated.sexp") != null);

    const files = try std.process.Child.run(.{
        .allocator = a,
        .argv = &.{ "git", "-C", dir, "show", "--name-only", "--pretty=format:", "HEAD" },
    });
    try testing.expect(std.mem.indexOf(u8, files.stdout, "mutated.sexp") != null);
    try testing.expect(std.mem.indexOf(u8, files.stdout, "tracked.sexp") == null);

    // Loose human work is still uncommitted after the auto-commit.
    const status = try std.process.Child.run(.{
        .allocator = a,
        .argv = &.{ "git", "-C", dir, "status", "--porcelain" },
    });
    try testing.expect(std.mem.indexOf(u8, status.stdout, "human_loose.txt") != null);
    try testing.expect(std.mem.indexOf(u8, status.stdout, "tracked.sexp") != null);
}

test "begin is a no-op outside a git repository" {
    // spec: Web Server - The auto-commit is a silent no-op when the project dir is not a git repository
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // A path git cannot resolve to a work tree (the test tmp dir itself is
    // nested in this repo, so a real subdir would resolve upward to it). git
    // exits non-zero here, so `begin` yields no session and nothing commits.
    const dir = try tmpPath(a, &tmp, "not-a-real-dir");

    try testing.expect(begin(a, dir) == null);
    // commit(null, …) is itself a harmless no-op.
    commit(null, "ada", "write_file");
}
