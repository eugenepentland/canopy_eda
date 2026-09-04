//! Timestamped-backup atomic writer for `.kicad_pcb` boards.
//!
//! Extracted from the file-based KiCad sync (`serve/sync.zig`): before a board
//! file is overwritten, the current copy is rolled into a `backups/` subfolder
//! beside it (`backups/<name>.bak-<stamp>`, newest `max_board_backups` kept),
//! then the new contents land via tmp-file + fsync + rename. The board lives
//! on the NAS outside git, so the rolled backup is the only undo.

const std = @import("std");
const atomic_write = @import("../infra/atomic_write.zig");
const infra_fs = @import("../infra/fs.zig");
const log = @import("../infra/log.zig");
const sortable_stamp = @import("sortable_stamp.zig");

/// How many timestamped board backups (`<path>.bak-<stamp>`) to keep per
/// `.kicad_pcb`. Older ones are pruned best-effort after each backup.
const max_board_backups: usize = 10;
/// Suffix between the board filename and the backup timestamp.
const backup_infix = ".bak-";
/// Subfolder (beside the `.kicad_pcb`) the rolled backups live in, so the
/// board's own directory isn't littered with `.bak-*` siblings.
const backup_dir_name = "backups";

/// The `backups/` directory beside `path` where its rolled backups are kept.
fn backupDirPath(arena: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error![]u8 {
    const dir = std.fs.path.dirname(path) orelse ".";
    return std.fs.path.join(arena, &.{ dir, backup_dir_name });
}

/// Whether `path` currently exists on disk (a missing board = first sync,
/// nothing to back up yet).
fn boardExists(path: []const u8) bool {
    infra_fs.cwd().access(path, .{}) catch return false;
    return true;
}

/// Best-effort cap on the number of `<path>.bak-*` siblings: keeps the
/// newest MAX_BOARD_BACKUPS (the stamp sorts chronologically), deletes the
/// rest. Any failure is logged and ignored — a failed prune must never
/// fail the sync whose backup already succeeded.
fn pruneBackups(arena: std.mem.Allocator, path: []const u8) void {
    pruneBackupsImpl(arena, path) catch |e|
        log.warn("kicad-pcb backup prune for {s} failed: {s}", .{ path, @errorName(e) });
}

fn pruneBackupsImpl(arena: std.mem.Allocator, path: []const u8) !void {
    const backup_dir = try backupDirPath(arena, path);
    const prefix = try std.fmt.allocPrint(arena, "{s}{s}", .{ std.fs.path.basename(path), backup_infix });
    var dir = infra_fs.cwd().openDir(backup_dir, .{ .iterate = true }) catch |e| switch (e) {
        // No backups/ folder yet (e.g. nothing has ever been rolled) → nothing
        // to prune.
        error.FileNotFound => return,
        else => return e,
    };
    defer dir.close();
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.startsWith(u8, entry.name, prefix)) continue;
        try names.append(arena, try arena.dupe(u8, entry.name));
    }
    if (names.items.len <= max_board_backups) return;
    std.mem.sort([]const u8, names.items, {}, lessThanStr);
    for (names.items[0 .. names.items.len - max_board_backups]) |n| {
        dir.deleteFile(n) catch |e|
            log.warn("kicad-pcb backup prune: delete {s} failed: {s}", .{ n, @errorName(e) });
    }
}

fn lessThanStr(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Everything the backup roll + atomic write can fail with: the roll's own
/// allocation, `backups/` mkdir and pre-write copy, plus whatever the staged
/// replacement in `infra/atomic_write.zig` reports.
pub const WriteFileAtomicError = RollBackupError || atomic_write.Error;

/// Everything the backup roll alone can fail with — the `backups/` mkdir and
/// the pre-write copy. A subset of `WriteFileAtomicError`.
pub const RollBackupError = std.mem.Allocator.Error || infra_fs.Dir.MakeError ||
    infra_fs.Dir.CopyFileError;

/// Roll the current contents of `path` into `backups/<name>.bak-<timestamp>`
/// beside it, then prune to the newest `max_board_backups`.
///
/// Split out of `writeFileAtomic` so a multi-file writer that stages every file
/// before renaming any of them (the schematic push, `kicad_sch_push.commit`)
/// can still roll the same backups into the same place, rather than growing a
/// second, subtly-different backup convention in the same directory.
///
/// Timestamped (rather than a single `.bak`) so a quick second push can't
/// clobber the only good backup, and in a `backups/` subfolder rather than as
/// `.bak-*` siblings so the KiCad project directory stays tidy. A missing
/// source file = first write, nothing to back up, so the roll is skipped
/// entirely and no empty `backups/` folder is left behind. Any failure
/// propagates: better to fail loudly than to overwrite with no fallback.
pub fn rollBackup(arena: std.mem.Allocator, path: []const u8) RollBackupError!void {
    if (!boardExists(path)) return;
    // The same stamp the history snapshots carry, so sorting backup filenames
    // sorts them chronologically.
    const stamp = try sortable_stamp.now(arena);
    const backup_dir = try backupDirPath(arena, path);
    try infra_fs.cwd().makePath(backup_dir);
    const base = std.fs.path.basename(path);
    const backup_name = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ base, backup_infix, stamp });
    const backup_path = try std.fs.path.join(arena, &.{ backup_dir, backup_name });
    try infra_fs.cwd().copyFile(path, infra_fs.cwd(), backup_path, .{});
    pruneBackups(arena, path);
}

/// Roll a timestamped backup of `path`, then replace it with `contents`
/// through the tree's one staged writer (`infra/atomic_write.zig`: sibling
/// temporary → flush → fsync → rename).
///
/// This used to stage into a FIXED `<path>.tmp`, which two concurrent board
/// syncs collide on — each would be writing into the file the other renames.
/// `atomic_write` inherits `AtomicFile`'s randomly named temporary instead, so
/// the collision is not representable, and it unlinks the temporary on every
/// failure path rather than leaving a stray `<board>.kicad_pcb.tmp` next to the
/// board. The pre-write copy is rolled by `rollBackup` above — the board lives
/// on the NAS, outside git, so it is the only undo.
pub fn writeFileAtomic(arena: std.mem.Allocator, path: []const u8, contents: []const u8) WriteFileAtomicError!void {
    try rollBackup(arena, path);
    try atomic_write.writeFile(path, contents);
}

// ── tests ──────────────────────────────────────────────────────────

// spec: serve/sync - formatBackupStamp renders epoch seconds as a sortable filesystem-safe stamp
test "formatBackupStamp renders epoch zero as a sortable filesystem-safe stamp" {
    var aa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aa.deinit();
    const stamp = try sortable_stamp.fromEpochSeconds(aa.allocator(), 0);
    try std.testing.expectEqualStrings("1970-01-01T00-00-00", stamp);
}

/// Test helper: pre-seed `n` stamped backups of `b.kicad_pcb`. 1969 stamps
/// sort before any real clock stamp, so a prune must drop the oldest of
/// these, never the freshly-rolled backup.
fn writeStaleBackupsForTest(dir: std.Io.Dir, arena: std.mem.Allocator, n: usize) !void {
    try dir.createDirPath(std.testing.io, backup_dir_name);
    var bdir = try dir.openDir(std.testing.io, backup_dir_name, .{});
    defer bdir.close(std.testing.io);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const bname = try std.fmt.allocPrint(arena, "b.kicad_pcb.bak-1969-01-01T00-00-{d:0>2}", .{i});
        try bdir.writeFile(std.testing.io, .{ .sub_path = bname, .data = "stale" });
    }
}

const BackupScanForTest = struct { count: usize, fresh_holds_old: bool, oldest_present: bool };

/// Test helper: tally the `b.kicad_pcb.bak-*` files in the `backups/` folder —
/// how many, whether the oldest 1969 stamp survived, and whether the fresh
/// (real-clock) backup carries the pre-write board contents.
fn scanBackupsForTest(dir: std.Io.Dir, arena: std.mem.Allocator) !BackupScanForTest {
    var out = BackupScanForTest{ .count = 0, .fresh_holds_old = false, .oldest_present = false };
    var bdir = dir.openDir(std.testing.io, backup_dir_name, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return out,
        else => return e,
    };
    defer bdir.close(std.testing.io);
    var it = bdir.iterate();
    while (try it.next(std.testing.io)) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "b.kicad_pcb.bak-")) continue;
        out.count += 1;
        if (std.mem.endsWith(u8, entry.name, "1969-01-01T00-00-00")) out.oldest_present = true;
        if (std.mem.indexOf(u8, entry.name, "1969") == null) {
            const content = try bdir.readFileAlloc(std.testing.io, entry.name, arena, .limited64(64));
            out.fresh_holds_old = std.mem.eql(u8, content, "old-board");
        }
    }
    return out;
}

// spec: serve/sync - writeFileAtomic rolls a timestamped board backup and prunes beyond MAX_BOARD_BACKUPS
test "writeFileAtomic rolls a timestamped backup and prunes beyond the cap" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var aa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aa.deinit();
    const arena = aa.allocator();

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const board_path = try std.fmt.allocPrint(arena, "{s}/b.kicad_pcb", .{root});
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "b.kicad_pcb", .data = "old-board" });
    // Start at the cap so the freshly-rolled backup pushes the count over it.
    try writeStaleBackupsForTest(tmp.dir, arena, max_board_backups);

    try writeFileAtomic(arena, board_path, "new-board");

    const got = try tmp.dir.readFileAlloc(std.testing.io, "b.kicad_pcb", arena, .limited64(64));
    try std.testing.expectEqualStrings("new-board", got);
    // Cap holds after the new backup joined: the oldest 1969 stamp was pruned
    // and the fresh backup carries the pre-write contents.
    const scan = try scanBackupsForTest(tmp.dir, arena);
    try std.testing.expectEqual(max_board_backups, scan.count);
    try std.testing.expect(scan.fresh_holds_old);
    try std.testing.expect(!scan.oldest_present);
}

// spec: serve/sync - a board write leaves no staging sibling beside the board, so a concurrent sync cannot inherit a half-written file under a predictable name
test "a board write leaves no staging sibling beside the board" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    var aa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aa.deinit();
    const arena = aa.allocator();

    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    const board_path = try std.fmt.allocPrint(arena, "{s}/b.kicad_pcb", .{root});
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "b.kicad_pcb", .data = "old-board" });

    try writeFileAtomic(arena, board_path, "new-board");

    // The board and its `backups/` folder, and nothing else. The private writer
    // this replaced staged into a FIXED `b.kicad_pcb.tmp`, which is both a name
    // a second concurrent sync would write into and a file a failed write could
    // leave behind next to the board.
    var names: usize = 0;
    var it = tmp.dir.iterate();
    while (try it.next(std.testing.io)) |entry| {
        names += 1;
        const is_board = std.mem.eql(u8, entry.name, "b.kicad_pcb");
        const is_backups = std.mem.eql(u8, entry.name, backup_dir_name);
        if (!is_board and !is_backups) {
            std.debug.print("unexpected entry beside the board: {s}\n", .{entry.name});
            return error.StagingResidue;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), names);
}
