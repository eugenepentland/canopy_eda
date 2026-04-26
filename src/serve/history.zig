const std = @import("std");

// Snapshot storage: projects/designs/history/<name>/<timestamp>/{name}.sexp (+ .layout if present)
// Timestamp format: YYYY-MM-DDTHH-MM-SS (filesystem-safe, sorts lexicographically).

pub const HistoryError = error{
    InvalidSnapshotId,
    SnapshotNotFound,
} || std.mem.Allocator.Error;

fn makeTimestamp(allocator: std.mem.Allocator) ![]u8 {
    const sec = std.time.timestamp();
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

/// Copy the current .sexp (and .layout if present) for `name` into
/// projects/designs/history/<name>/<timestamp>/. Returns the snapshot id
/// (caller owns). Returns null when the source file doesn't exist yet (nothing
/// to snapshot on a brand-new create). When `description` is non-null, a
/// `.note` file alongside the copied `.sexp` records the human-readable reason.
pub fn snapshot(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    description: ?[]const u8,
) !?[]const u8 {
    const sexp_src = try std.fmt.allocPrint(allocator, "{s}/src/{s}.sexp", .{ project_dir, name });
    defer allocator.free(sexp_src);

    std.fs.cwd().access(sexp_src, .{}) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };

    const id = try makeTimestamp(allocator);
    errdefer allocator.free(id);

    const dir = try std.fmt.allocPrint(allocator, "{s}/history/{s}/{s}", .{ project_dir, name, id });
    defer allocator.free(dir);
    try std.fs.cwd().makePath(dir);

    const dst_sexp = try std.fmt.allocPrint(allocator, "{s}/{s}.sexp", .{ dir, name });
    defer allocator.free(dst_sexp);
    try std.fs.cwd().copyFile(sexp_src, std.fs.cwd(), dst_sexp, .{});

    const layout_src = try std.fmt.allocPrint(allocator, "{s}/src/{s}.layout", .{ project_dir, name });
    defer allocator.free(layout_src);
    if (std.fs.cwd().access(layout_src, .{})) |_| {
        const dst_layout = try std.fmt.allocPrint(allocator, "{s}/{s}.layout", .{ dir, name });
        defer allocator.free(dst_layout);
        std.fs.cwd().copyFile(layout_src, std.fs.cwd(), dst_layout, .{}) catch |e| {
            std.debug.print("warning: copy layout {s} failed: {s}\n", .{ layout_src, @errorName(e) });
        };
    } else |_| {}

    if (description) |d| if (d.len > 0) {
        const note_path = try std.fmt.allocPrint(allocator, "{s}/.note", .{dir});
        defer allocator.free(note_path);
        if (std.fs.cwd().createFile(note_path, .{})) |f| {
            defer f.close();
            f.writeAll(d) catch |e| {
                std.debug.print("warning: write .note failed: {s}\n", .{@errorName(e)});
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
) ![]SnapshotInfo {
    const dir_path = try std.fmt.allocPrint(allocator, "{s}/history/{s}", .{ project_dir, name });
    defer allocator.free(dir_path);

    var entries: std.ArrayListUnmanaged(SnapshotInfo) = .empty;
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return entries.toOwnedSlice(allocator),
        else => return e,
    };
    defer dir.close();

    var it = dir.iterate();
    while (try it.next()) |entry| {
        if (entry.kind != .directory) continue;
        const id = try allocator.dupe(u8, entry.name);
        const note_path = try std.fmt.allocPrint(allocator, "{s}/{s}/.note", .{ dir_path, id });
        defer allocator.free(note_path);
        const description: ?[]const u8 = std.fs.cwd().readFileAlloc(allocator, note_path, 4096) catch null;
        try entries.append(allocator, .{ .id = id, .description = description });
    }
    std.mem.sort(SnapshotInfo, entries.items, {}, struct {
        fn lessThan(_: void, a: SnapshotInfo, b: SnapshotInfo) bool {
            return std.mem.lessThan(u8, b.id, a.id);
        }
    }.lessThan);
    return entries.toOwnedSlice(allocator);
}

/// Copy a library file under `lib/<subdir>/<name>.sexp` into
/// `history/_lib/<subdir>/<name>/<timestamp>/<name>.sexp`, so library edits
/// are undoable. Returns the snapshot id (caller owns) or null if the source
/// does not exist yet.
pub fn snapshotLibraryFile(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    subdir: []const u8,
    name: []const u8,
    description: ?[]const u8,
) !?[]const u8 {
    const src = try std.fmt.allocPrint(allocator, "{s}/lib/{s}/{s}.sexp", .{ project_dir, subdir, name });
    defer allocator.free(src);

    std.fs.cwd().access(src, .{}) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };

    const id = try makeTimestamp(allocator);
    errdefer allocator.free(id);

    const dir = try std.fmt.allocPrint(allocator, "{s}/history/_lib/{s}/{s}/{s}", .{ project_dir, subdir, name, id });
    defer allocator.free(dir);
    try std.fs.cwd().makePath(dir);

    const dst = try std.fmt.allocPrint(allocator, "{s}/{s}.sexp", .{ dir, name });
    defer allocator.free(dst);
    try std.fs.cwd().copyFile(src, std.fs.cwd(), dst, .{});

    if (description) |d| if (d.len > 0) {
        const note_path = try std.fmt.allocPrint(allocator, "{s}/.note", .{dir});
        defer allocator.free(note_path);
        if (std.fs.cwd().createFile(note_path, .{})) |f| {
            defer f.close();
            f.writeAll(d) catch |e| {
                std.debug.print("warning: write .note failed: {s}\n", .{@errorName(e)});
            };
        } else |_| {}
    };

    return id;
}

/// Restore the snapshot at `id` back into src/. Does NOT snapshot the current
/// state — callers should call `snapshot` first if they want the restore to
/// be undoable.
pub fn restore(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    id: []const u8,
) !void {
    // Defense against path traversal and weird input.
    if (id.len == 0) return error.InvalidSnapshotId;
    for (id) |c| if (c == '/' or c == '\\' or c == 0) return error.InvalidSnapshotId;
    if (std.mem.indexOf(u8, id, "..") != null) return error.InvalidSnapshotId;

    const dir = try std.fmt.allocPrint(allocator, "{s}/history/{s}/{s}", .{ project_dir, name, id });
    defer allocator.free(dir);
    std.fs.cwd().access(dir, .{}) catch return error.SnapshotNotFound;

    const src_sexp = try std.fmt.allocPrint(allocator, "{s}/{s}.sexp", .{ dir, name });
    defer allocator.free(src_sexp);
    const dst_sexp = try std.fmt.allocPrint(allocator, "{s}/src/{s}.sexp", .{ project_dir, name });
    defer allocator.free(dst_sexp);
    try std.fs.cwd().copyFile(src_sexp, std.fs.cwd(), dst_sexp, .{});

    const src_layout = try std.fmt.allocPrint(allocator, "{s}/{s}.layout", .{ dir, name });
    defer allocator.free(src_layout);
    const dst_layout = try std.fmt.allocPrint(allocator, "{s}/src/{s}.layout", .{ project_dir, name });
    defer allocator.free(dst_layout);
    if (std.fs.cwd().access(src_layout, .{})) |_| {
        std.fs.cwd().copyFile(src_layout, std.fs.cwd(), dst_layout, .{}) catch |e| {
            std.debug.print("warning: copy layout {s} failed: {s}\n", .{ src_layout, @errorName(e) });
        };
    } else |_| {}
}
