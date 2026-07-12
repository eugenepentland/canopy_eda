//! Timestamped-backup atomic writer for `.kicad_pcb` boards.
//!
//! Extracted from the file-based KiCad sync (`serve/sync.zig`): before a board
//! file is overwritten, the current copy is rolled into a `backups/` subfolder
//! beside it (`backups/<name>.bak-<stamp>`, newest `max_board_backups` kept),
//! then the new contents land via tmp-file + fsync + rename. The board lives
//! on the NAS outside git, so the rolled backup is the only undo.

const std = @import("std");
const infra_fs = @import("../infra/fs.zig");
const clock = @import("../infra/clock.zig");
const log = @import("../infra/log.zig");

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

/// Render an epoch-seconds value as `YYYY-MM-DDTHH-MM-SS` — the same
/// filesystem-safe, lexicographically-sortable stamp the history snapshots
/// use, so sorting backup filenames sorts them chronologically.
fn formatBackupStamp(arena: std.mem.Allocator, epoch_sec: u64) std.mem.Allocator.Error![]u8 {
    const es = std.time.epoch.EpochSeconds{ .secs = epoch_sec };
    const year_day = es.getEpochDay().calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_sec = es.getDaySeconds();
    return std.fmt.allocPrint(arena, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}-{d:0>2}-{d:0>2}", .{
        @as(u32, year_day.year),
        month_day.month.numeric(),
        @as(u32, month_day.day_index) + 1,
        day_sec.getHoursIntoDay(),
        day_sec.getMinutesIntoHour(),
        day_sec.getSecondsIntoMinute(),
    });
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

/// Everything the backup roll + atomic write can fail with: allocation, the
/// `backups/` mkdir, the pre-write copy, and the tmp-file create/write/rename.
pub const WriteFileAtomicError = std.mem.Allocator.Error || std.fs.Dir.MakeError ||
    std.fs.Dir.CopyFileError || std.fs.File.OpenError || std.fs.File.WriteError ||
    std.fs.Dir.RenameError;

/// Write `contents` to `path` atomically via tmp file → fsync(file) →
/// rename. NAS callers concerned about partial visibility through NFS
/// caches can run `sync` post-hoc; for a human-driven button press the
/// rename is durable enough in practice.
pub fn writeFileAtomic(arena: std.mem.Allocator, path: []const u8, contents: []const u8) WriteFileAtomicError!void {
    // Roll the current file to `backups/<name>.bak-<timestamp>` before
    // overwriting so a bad sync (e.g. an unwanted prune) is one copy away from
    // undo — the board lives on the NAS, outside git, so this is the only
    // safety net. Backups live in a `backups/` subfolder beside the board (not
    // as `.bak-*` siblings) so the KiCad project directory stays tidy.
    // Timestamped (rather than a single `.bak`) so a quick second push can't
    // clobber the only good backup; `pruneBackups` keeps the newest
    // MAX_BOARD_BACKUPS. Abort the whole write if the backup can't be made;
    // better to fail loudly than overwrite with no fallback. A missing source
    // board = first sync, nothing to back up yet, so skip the roll entirely
    // (and don't leave an empty backups/ folder behind).
    if (boardExists(path)) {
        const now = clock.timestamp();
        const stamp = try formatBackupStamp(arena, if (now < 0) 0 else @intCast(now));
        const backup_dir = try backupDirPath(arena, path);
        try infra_fs.cwd().makePath(backup_dir);
        const base = std.fs.path.basename(path);
        const backup_name = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ base, backup_infix, stamp });
        const backup_path = try std.fs.path.join(arena, &.{ backup_dir, backup_name });
        try infra_fs.cwd().copyFile(path, infra_fs.cwd(), backup_path, .{});
        pruneBackups(arena, path);
    }

    const tmp_path = try std.fmt.allocPrint(arena, "{s}.tmp", .{path});

    var tmp = try infra_fs.cwd().createFile(tmp_path, .{ .truncate = true });
    {
        defer tmp.close();
        try tmp.writeAll(contents);
        // Best-effort durability before the rename. On systems where
        // fsync isn't supported (in-memory FS in some test sandboxes)
        // we still want the rename to proceed — surfacing the error
        // would make the whole sync fail for a non-actionable reason.
        tmp.sync() catch |e| log.warn("kicad-pcb tmp fsync failed: {s}", .{@errorName(e)});
    }

    try infra_fs.cwd().rename(tmp_path, path);
}

// ── tests ──────────────────────────────────────────────────────────

// spec: serve/sync - formatBackupStamp renders epoch seconds as a sortable filesystem-safe stamp
test "formatBackupStamp renders epoch zero as a sortable filesystem-safe stamp" {
    var aa = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer aa.deinit();
    const stamp = try formatBackupStamp(aa.allocator(), 0);
    try std.testing.expectEqualStrings("1970-01-01T00-00-00", stamp);
}

/// Test helper: pre-seed `n` stamped backups of `b.kicad_pcb`. 1969 stamps
/// sort before any real clock stamp, so a prune must drop the oldest of
/// these, never the freshly-rolled backup.
fn writeStaleBackupsForTest(dir: std.fs.Dir, arena: std.mem.Allocator, n: usize) !void {
    try dir.makePath(backup_dir_name);
    var bdir = try dir.openDir(backup_dir_name, .{});
    defer bdir.close();
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const bname = try std.fmt.allocPrint(arena, "b.kicad_pcb.bak-1969-01-01T00-00-{d:0>2}", .{i});
        try bdir.writeFile(.{ .sub_path = bname, .data = "stale" });
    }
}

const BackupScanForTest = struct { count: usize, fresh_holds_old: bool, oldest_present: bool };

/// Test helper: tally the `b.kicad_pcb.bak-*` files in the `backups/` folder —
/// how many, whether the oldest 1969 stamp survived, and whether the fresh
/// (real-clock) backup carries the pre-write board contents.
fn scanBackupsForTest(dir: std.fs.Dir, arena: std.mem.Allocator) !BackupScanForTest {
    var out = BackupScanForTest{ .count = 0, .fresh_holds_old = false, .oldest_present = false };
    var bdir = dir.openDir(backup_dir_name, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return out,
        else => return e,
    };
    defer bdir.close();
    var it = bdir.iterate();
    while (try it.next()) |entry| {
        if (!std.mem.startsWith(u8, entry.name, "b.kicad_pcb.bak-")) continue;
        out.count += 1;
        if (std.mem.endsWith(u8, entry.name, "1969-01-01T00-00-00")) out.oldest_present = true;
        if (std.mem.indexOf(u8, entry.name, "1969") == null) {
            const content = try bdir.readFileAlloc(arena, entry.name, 64);
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

    const root = try tmp.dir.realpathAlloc(arena, ".");
    const board_path = try std.fmt.allocPrint(arena, "{s}/b.kicad_pcb", .{root});
    try tmp.dir.writeFile(.{ .sub_path = "b.kicad_pcb", .data = "old-board" });
    // Start at the cap so the freshly-rolled backup pushes the count over it.
    try writeStaleBackupsForTest(tmp.dir, arena, max_board_backups);

    try writeFileAtomic(arena, board_path, "new-board");

    const got = try tmp.dir.readFileAlloc(arena, "b.kicad_pcb", 64);
    try std.testing.expectEqualStrings("new-board", got);
    // Cap holds after the new backup joined: the oldest 1969 stamp was pruned
    // and the fresh backup carries the pre-write contents.
    const scan = try scanBackupsForTest(tmp.dir, arena);
    try std.testing.expectEqual(max_board_backups, scan.count);
    try std.testing.expect(scan.fresh_holds_old);
    try std.testing.expect(!scan.oldest_present);
}
