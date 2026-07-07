const std = @import("std");
const infra_fs = @import("../infra/fs.zig");
const clock = @import("../infra/clock.zig");
const log = @import("../infra/log.zig");
const paths = @import("../paths.zig");

// ── Constants ─────────────────────────────────────────────────────
const SEXP_FILE_TEMPLATE = "{s}/{s}.sexp";
const LAYOUTS_FILE_TEMPLATE = "{s}/{s}.layouts.json";
const NOTE_MAX_BYTES: usize = 4096;

// Source-snapshot storage: projects/designs/history/<name>/<timestamp>/{name}.sexp
// Timestamp format: YYYY-MM-DDTHH-MM-SS (filesystem-safe, sorts lexicographically).
//
// Layout-snapshot storage lives in a reserved `layouts/` subdir beside the
// source snapshots — projects/designs/history/<name>/layouts/<timestamp>/{name}.layouts.json
// — so a Save/Update to the `.layouts.json` sidecar keeps a rolling backup
// without polluting the source-snapshot list (`listSnapshots` skips the
// `layouts/` subdir). Retention: newest `MAX_LAYOUT_SNAPSHOTS` per design.
const LAYOUT_SUBDIR = "layouts";
const MAX_LAYOUT_SNAPSHOTS: usize = 20;

pub const HistoryError = error{
    InvalidName,
    InvalidSnapshotId,
    SnapshotNotFound,
} ||
    std.mem.Allocator.Error ||
    std.fs.Dir.AccessError ||
    std.fs.Dir.MakeError ||
    std.fs.Dir.CopyFileError ||
    std.fs.Dir.OpenError ||
    std.fs.File.OpenError ||
    std.fs.Dir.Iterator.Error ||
    std.fs.File.ReadError;

fn makeTimestamp(allocator: std.mem.Allocator) ![]u8 {
    const sec = clock.timestamp();
    const epoch_sec: u64 = if (sec < 0) 0 else @intCast(sec);
    const es = std.time.epoch.EpochSeconds{ .secs = epoch_sec };
    const day = es.getEpochDay();
    const year_day = day.calculateYearDay();
    const month_day = year_day.calculateMonthDay();
    const day_sec = es.getDaySeconds();
    return std.fmt.allocPrint(allocator, "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}-{d:0>2}-{d:0>2}", .{
        @as(u32, year_day.year),
        month_day.month.numeric(),
        @as(u32, month_day.day_index) + 1,
        day_sec.getHoursIntoDay(),
        day_sec.getMinutesIntoHour(),
        day_sec.getSecondsIntoMinute(),
    });
}

/// Copy the current .sexp for `name` into
/// projects/designs/history/<name>/<timestamp>/. Returns the snapshot id
/// (caller owns). Returns null when the source file doesn't exist yet (nothing
/// to snapshot on a brand-new create). When `description` is non-null, a
/// `.note` file alongside the copied `.sexp` records the human-readable reason.
pub fn snapshot(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    description: ?[]const u8,
) HistoryError!?[]const u8 {
    const sexp_src = try paths.designSourcePath(allocator, project_dir, name);
    defer allocator.free(sexp_src);

    infra_fs.cwd().access(sexp_src, .{}) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };

    const id = try makeTimestamp(allocator);
    errdefer allocator.free(id);

    const dir = try std.fmt.allocPrint(allocator, "{s}/history/{s}/{s}", .{ project_dir, name, id });
    defer allocator.free(dir);
    try infra_fs.cwd().makePath(dir);

    const dst_sexp = try std.fmt.allocPrint(allocator, SEXP_FILE_TEMPLATE, .{ dir, name });
    defer allocator.free(dst_sexp);
    try infra_fs.cwd().copyFile(sexp_src, infra_fs.cwd(), dst_sexp, .{});

    if (description) |d| if (d.len > 0) {
        const note_path = try std.fmt.allocPrint(allocator, "{s}/.note", .{dir});
        defer allocator.free(note_path);
        if (infra_fs.cwd().createFile(note_path, .{})) |f| {
            defer f.close();
            f.writeAll(d) catch |e| {
                log.warn("write .note failed: {s}", .{@errorName(e)});
            };
        } else |_| {}
    };

    return id;
}

/// One snapshot entry: id plus optional human-readable description loaded
/// from the `.note` file in the snapshot directory, if present.
pub const SnapshotInfo = struct {
    id: []const u8,
    description: ?[]const u8 = null,
};

/// Return all snapshot entries for `name`, newest first. Each entry includes
/// the description from `.note` when available.
pub fn listSnapshots(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
) HistoryError![]SnapshotInfo {
    const dir_path = try std.fmt.allocPrint(allocator, "{s}/history/{s}", .{ project_dir, name });
    defer allocator.free(dir_path);

    var entries: std.ArrayListUnmanaged(SnapshotInfo) = .empty;
    var dir = infra_fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return entries.toOwnedSlice(allocator),
        else => return e,
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        // The reserved `layouts/` subdir holds `.layouts.json` snapshots, not
        // source ones — never surface it as a source snapshot id.
        if (std.mem.eql(u8, entry.name, LAYOUT_SUBDIR)) continue;
        const id = try allocator.dupe(u8, entry.name);
        const note_path = try std.fmt.allocPrint(allocator, "{s}/{s}/.note", .{ dir_path, id });
        defer allocator.free(note_path);
        const description: ?[]const u8 = infra_fs.cwd().readFileAlloc(allocator, note_path, NOTE_MAX_BYTES) catch null;
        try entries.append(allocator, .{ .id = id, .description = description });
    }
    std.mem.sort(SnapshotInfo, entries.items, {}, struct {
        fn lessThan(_: void, a: SnapshotInfo, b: SnapshotInfo) bool {
            return std.mem.lessThan(u8, b.id, a.id);
        }
    }.lessThan);
    return entries.toOwnedSlice(allocator);
}

/// Restore the snapshot at `id` back into src/. Does NOT snapshot the current
/// state — callers should call `snapshot` first if they want the restore to
/// be undoable.
pub fn restore(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    id: []const u8,
) HistoryError!void {
    // Defense against path traversal and weird input.
    if (id.len == 0) return error.InvalidSnapshotId;
    for (id) |c| if (c == '/' or c == '\\' or c == 0) return error.InvalidSnapshotId;
    if (std.mem.indexOf(u8, id, "..") != null) return error.InvalidSnapshotId;

    const dir = try std.fmt.allocPrint(allocator, "{s}/history/{s}/{s}", .{ project_dir, name, id });
    defer allocator.free(dir);
    infra_fs.cwd().access(dir, .{}) catch return error.SnapshotNotFound;

    const src_sexp = try std.fmt.allocPrint(allocator, SEXP_FILE_TEMPLATE, .{ dir, name });
    defer allocator.free(src_sexp);
    const dst_sexp = try paths.designSourcePath(allocator, project_dir, name);
    defer allocator.free(dst_sexp);
    try infra_fs.cwd().copyFile(src_sexp, infra_fs.cwd(), dst_sexp, .{});
}

// ── Layout-sidecar snapshots (`.layouts.json`) ─────────────────────
// The PCB layout sidecar is snapshotted on every Save/Update so a bad save is
// recoverable in-tool. Stored under the reserved `layouts/` subdir (see the
// module header) and capped at `MAX_LAYOUT_SNAPSHOTS` newest per design.

/// `<project>/history/<name>/layouts` — the layout-snapshot root for `name`
/// (caller owns). One chokepoint so the path shape lives in a single place.
fn layoutHistoryDir(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/history/{s}/" ++ LAYOUT_SUBDIR, .{ project_dir, name });
}

/// Copy the `.layouts.json` sidecar at `sidecar_path` into
/// history/<name>/layouts/<timestamp>/<name>.layouts.json before it's
/// overwritten. Returns the snapshot id (caller owns), or null when the sidecar
/// doesn't exist yet (nothing to snapshot on a first-ever save). Prunes to the
/// newest `MAX_LAYOUT_SNAPSHOTS` afterwards (best-effort).
pub fn snapshotLayouts(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    sidecar_path: []const u8,
) HistoryError!?[]const u8 {
    infra_fs.cwd().access(sidecar_path, .{}) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };

    const id = try makeTimestamp(allocator);
    errdefer allocator.free(id);

    const base = try layoutHistoryDir(allocator, project_dir, name);
    defer allocator.free(base);
    const dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, id });
    defer allocator.free(dir);
    try infra_fs.cwd().makePath(dir);

    const dst = try std.fmt.allocPrint(allocator, LAYOUTS_FILE_TEMPLATE, .{ dir, name });
    defer allocator.free(dst);
    try infra_fs.cwd().copyFile(sidecar_path, infra_fs.cwd(), dst, .{});

    pruneLayoutSnapshots(allocator, project_dir, name) catch |e| log.warn("prune layout snapshots {s}: {s}", .{ name, @errorName(e) });
    return id;
}

/// List layout snapshots for `name` (newest first) from the `layouts/` subdir.
/// Each entry is an id only (layout snapshots carry no `.note`). Empty when
/// none exist.
pub fn listLayoutSnapshots(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
) HistoryError![]SnapshotInfo {
    const dir_path = try layoutHistoryDir(allocator, project_dir, name);
    defer allocator.free(dir_path);

    var entries: std.ArrayListUnmanaged(SnapshotInfo) = .empty;
    var dir = infra_fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return entries.toOwnedSlice(allocator),
        else => return e,
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        try entries.append(allocator, .{ .id = try allocator.dupe(u8, entry.name), .description = null });
    }
    std.mem.sort(SnapshotInfo, entries.items, {}, struct {
        fn lessThan(_: void, a: SnapshotInfo, b: SnapshotInfo) bool {
            return std.mem.lessThan(u8, b.id, a.id);
        }
    }.lessThan);
    return entries.toOwnedSlice(allocator);
}

/// Absolute path to layout snapshot `id`'s `.layouts.json` (caller owns).
/// Rejects a traversal-unsafe id and a missing snapshot — the restore handler
/// reads the returned path and re-stamps it back into the live sidecar.
pub fn layoutSnapshotPath(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    id: []const u8,
) HistoryError![]u8 {
    if (id.len == 0) return error.InvalidSnapshotId;
    for (id) |c| if (c == '/' or c == '\\' or c == 0) return error.InvalidSnapshotId;
    if (std.mem.indexOf(u8, id, "..") != null) return error.InvalidSnapshotId;

    const base = try layoutHistoryDir(allocator, project_dir, name);
    defer allocator.free(base);
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}.layouts.json", .{ base, id, name });
    errdefer allocator.free(path);
    infra_fs.cwd().access(path, .{}) catch return error.SnapshotNotFound;
    return path;
}

/// Remove layout snapshots for `name` beyond the newest `MAX_LAYOUT_SNAPSHOTS`.
/// The `layouts/` namespace is layout-only, so deleting a whole timestamp dir
/// here can never touch a source `.sexp` snapshot.
fn pruneLayoutSnapshots(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
) HistoryError!void {
    const snaps = try listLayoutSnapshots(allocator, project_dir, name);
    defer {
        for (snaps) |s| allocator.free(s.id);
        allocator.free(snaps);
    }
    if (snaps.len <= MAX_LAYOUT_SNAPSHOTS) return;

    const base = try layoutHistoryDir(allocator, project_dir, name);
    defer allocator.free(base);
    for (snaps[MAX_LAYOUT_SNAPSHOTS..]) |s| {
        const p = std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, s.id }) catch continue;
        defer allocator.free(p);
        infra_fs.cwd().deleteTree(p) catch |e| log.warn("prune layout snapshot {s}: {s}", .{ p, @errorName(e) });
    }
}

// ── Tests ──────────────────────────────────────────────────────────

/// Seed `count` distinct fake layout-snapshot dirs (dated 2026-01-01, so they
/// sort before any freshly-minted timestamp) for the retention test.
fn seedFakeLayoutSnapshots(alloc: std.mem.Allocator, project: []const u8, name: []const u8, count: usize) !void {
    const base = try layoutHistoryDir(alloc, project, name);
    defer alloc.free(base);
    for (1..count + 1) |n| {
        const d = try std.fmt.allocPrint(alloc, "{s}/2026-01-01T00-00-{d:0>2}", .{ base, n });
        defer alloc.free(d);
        try infra_fs.cwd().makePath(d);
        const f = try std.fmt.allocPrint(alloc, "{s}/{s}.layouts.json", .{ d, name });
        defer alloc.free(f);
        try infra_fs.cwd().writeFile(.{ .sub_path = f, .data = "{}" });
    }
}

// spec: Web Server - The layout sidecar is snapshotted into history and listed newest-first
test "layout snapshot writes to history and lists back" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(project);

    const sidecar = try std.fmt.allocPrint(alloc, "{s}/foo.layouts.json", .{project});
    defer alloc.free(sidecar);
    try infra_fs.cwd().writeFile(.{ .sub_path = sidecar, .data = "{\"rev\":3,\"layouts\":[]}" });

    // No sidecar on disk → nothing to snapshot.
    try std.testing.expect((try snapshotLayouts(alloc, project, "bar", "/no/such/sidecar.json")) == null);

    const id = (try snapshotLayouts(alloc, project, "foo", sidecar)) orelse return error.TestExpectedId;
    defer alloc.free(id);

    const snaps = try listLayoutSnapshots(alloc, project, "foo");
    defer {
        for (snaps) |s| alloc.free(s.id);
        alloc.free(snaps);
    }
    try std.testing.expectEqual(@as(usize, 1), snaps.len);
    try std.testing.expectEqualStrings(id, snaps[0].id);

    // The snapshot preserves the sidecar bytes and resolves by id.
    const p = try layoutSnapshotPath(alloc, project, "foo", id);
    defer alloc.free(p);
    const data = try infra_fs.cwd().readFileAlloc(alloc, p, 1 << 20);
    defer alloc.free(data);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"rev\":3") != null);

    // A traversal-unsafe id is refused before touching disk.
    try std.testing.expectError(error.InvalidSnapshotId, layoutSnapshotPath(alloc, project, "foo", "../etc"));
}

// spec: Web Server - Layout snapshots are pruned to the newest retention cap
test "layout snapshots prune to the newest cap" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(project);

    const sidecar = try std.fmt.allocPrint(alloc, "{s}/foo.layouts.json", .{project});
    defer alloc.free(sidecar);
    try infra_fs.cwd().writeFile(.{ .sub_path = sidecar, .data = "{\"layouts\":[]}" });

    // Pre-seed MAX+2 distinct fake snapshots dated 2026-01-01 (older than the
    // real timestamp the snapshot below mints, so it becomes the newest).
    try seedFakeLayoutSnapshots(alloc, project, "foo", MAX_LAYOUT_SNAPSHOTS + 2);

    // One real snapshot pushes the total past the cap and triggers the prune.
    const id = (try snapshotLayouts(alloc, project, "foo", sidecar)) orelse return error.TestExpectedId;
    defer alloc.free(id);

    const snaps = try listLayoutSnapshots(alloc, project, "foo");
    defer {
        for (snaps) |s| alloc.free(s.id);
        alloc.free(snaps);
    }
    try std.testing.expectEqual(MAX_LAYOUT_SNAPSHOTS, snaps.len);
    // Newest-first: the real snapshot leads; the oldest fakes were pruned.
    try std.testing.expectEqualStrings(id, snaps[0].id);
    try std.testing.expectError(error.SnapshotNotFound, layoutSnapshotPath(alloc, project, "foo", "2026-01-01T00-00-01"));
}

// spec: Web Server - Source-snapshot listing skips the reserved layouts subdir
test "source snapshot list ignores the layouts subdir" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realpathAlloc(alloc, ".");
    defer alloc.free(project);

    // A layout snapshot dir plus a real source snapshot dir side by side.
    const lay = try std.fmt.allocPrint(alloc, "{s}/history/foo/{s}/2026-01-01T00-00-01", .{ project, LAYOUT_SUBDIR });
    defer alloc.free(lay);
    try infra_fs.cwd().makePath(lay);
    const src = try std.fmt.allocPrint(alloc, "{s}/history/foo/2026-01-01T00-00-02", .{project});
    defer alloc.free(src);
    try infra_fs.cwd().makePath(src);

    const snaps = try listSnapshots(alloc, project, "foo");
    defer {
        for (snaps) |s| {
            alloc.free(s.id);
            if (s.description) |d| alloc.free(d);
        }
        alloc.free(snaps);
    }
    // Only the source snapshot is listed; the reserved `layouts/` dir is skipped.
    try std.testing.expectEqual(@as(usize, 1), snaps.len);
    try std.testing.expectEqualStrings("2026-01-01T00-00-02", snaps[0].id);
}
