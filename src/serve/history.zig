//! Design version history: before every mutation a timestamped copy of the
//! design's files is written under `<state>/history/<name>/<ts>/`, and this
//! module lists, restores, and (for layouts) snapshots them.
//!
//! `<state>` is the project directory unless `--state-dir` / `NETLISP_STATE_DIR`
//! relocated runtime output (`paths.stateDir`). Sources and sidecars never
//! move; only these snapshots do, which is what lets a TRACKED project be
//! served and laid out without its `git status` filling up.
//!
//! A snapshot covers the design source AND every autoloaded sidecar that
//! exists beside it (`<name>.checks.sexp`, `<name>.layout.sexp`,
//! `<name>.diagram.sexp` — see `eval/sidecars.zig`), because those files are
//! part of the design: a Design Settings save on a split board lands in
//! `<name>.layout.sexp`, and a snapshot that held the design source alone gave
//! that save a history entry which did not contain the byte it changed. Undo
//! then restored an untouched design file and left the sidecar at the NEWER
//! state — a silent, wrong undo.
//!
//! What a snapshot captured is recorded in a `.files` manifest beside the
//! copies, one basename per line. Its PRESENCE is the version marker: an entry
//! written before sidecars were snapshotted has no manifest and is restored
//! design-file-only, exactly as it was written, so old entries stay usable. An
//! entry that HAS one is authoritative in both directions — a sidecar the
//! manifest does not list did not exist when the snapshot was taken, so
//! restoring that revision deletes it.
//!
//! A snapshot still does not capture `lib/`: an old revision re-evaluates
//! against today's modules.

const std = @import("std");
const atomic_write = @import("../infra/atomic_write.zig");
const infra_fs = @import("../infra/fs.zig");
const json_writer = @import("../json_writer.zig");
const log = @import("../infra/log.zig");
const paths = @import("../paths.zig");
const sidecars = @import("../eval/sidecars.zig");
const sortable_stamp = @import("sortable_stamp.zig");

// ── Constants ─────────────────────────────────────────────────────
const layouts_file_template = "{s}/{s}.layouts.json";
const note_max_bytes: usize = 4096;
/// Manifest of the design files one snapshot directory captured, one basename
/// per line. See the module header — its presence is the entry's version.
const manifest_name = ".files";
const manifest_max_bytes: usize = 4096;
/// Upper bound on a design file this module copies through memory. Matches the
/// evaluator's own file cap, so a design it can build is a design it can undo.
const source_max_bytes: usize = 10 * 1024 * 1024;

/// The files one snapshot covers, in a fixed order: slot 0 is the design
/// source, then one slot per `sidecars.kinds` entry.
const design_slots = 1 + sidecars.kinds.len;

/// The extension of slot `i` — `".sexp"` for the design, the sidecar's own
/// suffix otherwise.
fn slotExt(i: usize) []const u8 {
    return if (i == 0) ".sexp" else sidecars.kinds[i - 1].ext();
}

/// The LIVE path of slot `i` for `name` (caller owns). Every slot resolves
/// beside the design source, so a grouped `src/<group>/` layout and a
/// `lib/modules/` design both find their own siblings.
fn slotPath(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8, i: usize) HistoryError![]u8 {
    return paths.designSiblingPath(allocator, project_dir, name, slotExt(i));
}

/// True when `manifest` lists `basename` as a captured file. A null manifest
/// is a legacy entry: only the design source (slot 0) was ever captured, so
/// that is the only slot it can restore and the only one it can speak for.
fn manifestCovers(manifest: ?[]const u8, i: usize, basename: []const u8) bool {
    const text = manifest orelse return i == 0;
    var lines = std.mem.tokenizeAny(u8, text, "\r\n");
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t"), basename)) return true;
    }
    return false;
}

// Source-snapshot storage: projects/designs/history/<name>/<timestamp>/ holds
// {name}.sexp, each sidecar that existed, the `.files` manifest and the `.note`.
// Timestamp format: YYYY-MM-DDTHH-MM-SS (filesystem-safe, sorts lexicographically).
//
// Layout-snapshot storage lives in a reserved `layouts/` subdir beside the
// source snapshots — projects/designs/history/<name>/layouts/<timestamp>/{name}.layouts.json
// — so a Save/Update to the `.layouts.json` sidecar keeps a rolling backup
// without polluting the source-snapshot list (`listSnapshots` skips the
// `layouts/` subdir). Retention: newest `MAX_LAYOUT_SNAPSHOTS` per design.
/// The directory that holds this project's `history/` tree: the process
/// runtime-state root, which is `project_dir` itself unless `--state-dir` /
/// `NETLISP_STATE_DIR` moved it. Every path below is built from this, so the
/// relocation is one decision rather than four spellings.
fn historyRoot(project_dir: []const u8) []const u8 {
    return paths.stateDir(project_dir);
}

const layout_subdir = "layouts";
const max_layout_snapshots: usize = 20;

pub const HistoryError = error{
    InvalidName,
    InvalidSnapshotId,
    SnapshotNotFound,
} ||
    std.mem.Allocator.Error ||
    atomic_write.Error ||
    infra_fs.Dir.AccessError ||
    infra_fs.Dir.MakeError ||
    infra_fs.Dir.CopyFileError ||
    infra_fs.Dir.DeleteFileError ||
    infra_fs.Dir.OpenError ||
    infra_fs.File.OpenError ||
    infra_fs.Iterator.Error ||
    infra_fs.File.ReadError ||
    std.Io.Dir.WriteFileError;

/// Copy every file of `name` — the design source plus each autoloaded sidecar
/// that exists — into projects/designs/history/<name>/<timestamp>/, together
/// with the `.files` manifest naming exactly what was captured. Returns the
/// snapshot id (caller owns), or null when the design source doesn't exist yet
/// (nothing to snapshot on a brand-new create). When `description` is
/// non-null, a `.note` file alongside the copies records the human-readable
/// reason.
pub fn snapshot(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    description: ?[]const u8,
) HistoryError!?[]const u8 {
    const sexp_src = try slotPath(allocator, project_dir, name, 0);
    defer allocator.free(sexp_src);

    infra_fs.cwd().access(sexp_src, .{}) catch |e| switch (e) {
        error.FileNotFound => return null,
        else => return e,
    };

    const id = try sortable_stamp.now(allocator);
    errdefer allocator.free(id);

    const dir = try std.fmt.allocPrint(allocator, "{s}/history/{s}/{s}", .{ historyRoot(project_dir), name, id });
    defer allocator.free(dir);
    try infra_fs.cwd().makePath(dir);

    try captureSlots(allocator, project_dir, name, dir);

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

/// Copy each existing slot of `name` into the snapshot directory `dir` and
/// write the `.files` manifest. The manifest is written LAST and lists exactly
/// the copies that succeeded, so a manifest on disk always describes a
/// complete entry — a half-written directory has none, and `restore` reads it
/// as legacy (design-file-only) rather than deleting a sidecar it never saw.
fn captureSlots(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    dir: []const u8,
) HistoryError!void {
    var manifest: std.ArrayList(u8) = .empty;
    defer manifest.deinit(allocator);

    for (0..design_slots) |i| {
        const src = try slotPath(allocator, project_dir, name, i);
        defer allocator.free(src);
        if (i > 0) infra_fs.cwd().access(src, .{}) catch |e| switch (e) {
            error.FileNotFound => continue,
            else => return e,
        };
        const basename = std.fs.path.basename(src);
        const dst = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, basename });
        defer allocator.free(dst);
        try infra_fs.cwd().copyFile(src, infra_fs.cwd(), dst, .{});
        try manifest.appendSlice(allocator, basename);
        try manifest.append(allocator, '\n');
    }

    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, manifest_name });
    defer allocator.free(manifest_path);
    try infra_fs.cwd().writeFile(.{ .sub_path = manifest_path, .data = manifest.items });
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
    const dir_path = try std.fmt.allocPrint(allocator, "{s}/history/{s}", .{ historyRoot(project_dir), name });
    defer allocator.free(dir_path);

    var entries: std.ArrayList(SnapshotInfo) = .empty;
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
        if (std.mem.eql(u8, entry.name, layout_subdir)) continue;
        const id = try allocator.dupe(u8, entry.name);
        const note_path = try std.fmt.allocPrint(allocator, "{s}/{s}/.note", .{ dir_path, id });
        defer allocator.free(note_path);
        const description: ?[]const u8 = infra_fs.cwd().readFileAlloc(allocator, note_path, note_max_bytes) catch null;
        try entries.append(allocator, .{ .id = id, .description = description });
    }
    std.mem.sort(SnapshotInfo, entries.items, {}, struct {
        fn lessThan(_: void, a: SnapshotInfo, b: SnapshotInfo) bool {
            return std.mem.lessThan(u8, b.id, a.id);
        }
    }.lessThan);
    return entries.toOwnedSlice(allocator);
}

/// Write the `{"snapshots":[{id,description}, …]}` document BOTH history
/// surfaces answer — `GET /api/history/:name` and the `list_history` tool.
///
/// One writer because the two hand-written copies had already drifted on the
/// only field either of them formats: the endpoint spelled a snapshot with no
/// `.note` as `"description":""` and the tool as `"description":null`, so one
/// list read two different ways depending on which surface asked. `null` is
/// the spelling kept — it is what `SnapshotInfo.description` holds, and it
/// distinguishes "no note" from a note that is empty. The history panel in
/// `schematic_viewer.js` tests the field for truthiness, which reads both the
/// same, so the browser is unaffected.
pub fn writeSnapshotsJson(w: *std.Io.Writer, snaps: []const SnapshotInfo) (std.Io.Writer.Error || std.mem.Allocator.Error)!void {
    try w.writeAll("{\"snapshots\":[");
    for (snaps, 0..) |s, i| {
        if (i > 0) try w.writeAll(",");
        try w.writeAll("{\"id\":");
        try json_writer.writeString(w, s.id);
        try w.writeAll(",\"description\":");
        if (s.description) |d| try json_writer.writeString(w, d) else try w.writeAll("null");
        try w.writeAll("}");
    }
    try w.writeAll("]}");
}

/// Restore the snapshot at `id` back into src/. Does NOT snapshot the current
/// state — callers should call `snapshot` first if they want the restore to
/// be undoable.
///
/// Every file the entry covers moves together. The snapshot's bytes are read
/// in full FIRST and only then committed, each through the atomic writer, so a
/// failure mid-way cannot leave one revision's design file paired with
/// another's sidecar — a mixture that is neither of the two states the user
/// asked for and may not evaluate at all. A sidecar the manifest proves did
/// not exist at snapshot time is deleted; a legacy entry (no manifest) proves
/// nothing about sidecars and therefore leaves them alone.
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

    const dir = try std.fmt.allocPrint(allocator, "{s}/history/{s}/{s}", .{ historyRoot(project_dir), name, id });
    defer allocator.free(dir);
    infra_fs.cwd().access(dir, .{}) catch return error.SnapshotNotFound;

    const manifest_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, manifest_name });
    defer allocator.free(manifest_path);
    const manifest: ?[]u8 = infra_fs.cwd().readFileAlloc(allocator, manifest_path, manifest_max_bytes) catch null;
    defer if (manifest) |m| allocator.free(m);

    var dest: [design_slots]?[]u8 = @splat(null);
    var staged: [design_slots]?[]u8 = @splat(null);
    defer for (0..design_slots) |i| {
        if (dest[i]) |d| allocator.free(d);
        if (staged[i]) |b| allocator.free(b);
    };

    for (0..design_slots) |i| {
        const live = try slotPath(allocator, project_dir, name, i);
        dest[i] = live;
        const basename = std.fs.path.basename(live);
        if (!manifestCovers(manifest, i, basename)) continue;
        const from = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir, basename });
        defer allocator.free(from);
        // A file the manifest promises but the directory does not hold is a
        // damaged entry: refuse it whole rather than restore part of it.
        staged[i] = infra_fs.cwd().readFileAlloc(allocator, from, source_max_bytes) catch
            return error.SnapshotNotFound;
    }

    for (0..design_slots) |i| {
        const live = dest[i].?;
        if (staged[i]) |bytes| {
            try atomic_write.writeFile(live, bytes);
            continue;
        }
        // Only a manifest-bearing entry can prove absence; a legacy one is
        // silent about sidecars, so nothing is removed for it.
        if (i == 0 or manifest == null) continue;
        infra_fs.cwd().deleteFile(live) catch |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        };
    }
}

// ── Layout-sidecar snapshots (`.layouts.json`) ─────────────────────
// The PCB layout sidecar is snapshotted on every Save/Update so a bad save is
// recoverable in-tool. Stored under the reserved `layouts/` subdir (see the
// module header) and capped at `MAX_LAYOUT_SNAPSHOTS` newest per design.

/// `<project>/history/<name>/layouts` — the layout-snapshot root for `name`
/// (caller owns). One chokepoint so the path shape lives in a single place.
fn layoutHistoryDir(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, "{s}/history/{s}/" ++ layout_subdir, .{ historyRoot(project_dir), name });
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

    const id = try sortable_stamp.now(allocator);
    errdefer allocator.free(id);

    const base = try layoutHistoryDir(allocator, project_dir, name);
    defer allocator.free(base);
    const dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ base, id });
    defer allocator.free(dir);
    try infra_fs.cwd().makePath(dir);

    const dst = try std.fmt.allocPrint(allocator, layouts_file_template, .{ dir, name });
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

    var entries: std.ArrayList(SnapshotInfo) = .empty;
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
    if (snaps.len <= max_layout_snapshots) return;

    const base = try layoutHistoryDir(allocator, project_dir, name);
    defer allocator.free(base);
    for (snaps[max_layout_snapshots..]) |s| {
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

/// Write `data` at `<project>/src/<rel>` for the snapshot fixtures below.
fn seedSrcFile(alloc: std.mem.Allocator, project: []const u8, rel: []const u8, data: []const u8) !void {
    const dir = try std.fmt.allocPrint(alloc, "{s}/src", .{project});
    defer alloc.free(dir);
    try infra_fs.cwd().makePath(dir);
    const path = try std.fmt.allocPrint(alloc, "{s}/{s}", .{ dir, rel });
    defer alloc.free(path);
    try infra_fs.cwd().writeFile(.{ .sub_path = path, .data = data });
}

/// The current bytes of `<project>/src/<rel>`, or null when it is gone.
fn readSrcFile(alloc: std.mem.Allocator, project: []const u8, rel: []const u8) !?[]u8 {
    const path = try std.fmt.allocPrint(alloc, "{s}/src/{s}", .{ project, rel });
    defer alloc.free(path);
    return infra_fs.cwd().readFileAlloc(alloc, path, 1 << 20) catch |e| switch (e) {
        error.FileNotFound => null,
        else => e,
    };
}

// spec: Web Server - A source snapshot captures the design file and every sidecar beside it, so restoring one undoes an edit that landed in a sidecar
test "snapshot and restore cover the design's sidecars" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(project);

    try seedSrcFile(alloc, project, "split.sexp", "(design-block \"Split\")");
    try seedSrcFile(alloc, project, "split.layout.sexp", "(design-rules (clearance 0.2))");

    const id = (try snapshot(alloc, project, "split", "before")) orelse return error.TestExpectedId;
    defer alloc.free(id);

    // A settings save lands in the sidecar, and a diagram sidecar appears that
    // the snapshot never saw.
    try seedSrcFile(alloc, project, "split.layout.sexp", "(design-rules (clearance 0.9))");
    try seedSrcFile(alloc, project, "split.diagram.sexp", "(diagram-layout)");

    try restore(alloc, project, "split", id);

    const layout = (try readSrcFile(alloc, project, "split.layout.sexp")) orelse return error.TestExpectedEqual;
    defer alloc.free(layout);
    try std.testing.expectEqualStrings("(design-rules (clearance 0.2))", layout);
    // The design file the settings save never touched comes back unchanged.
    const design = (try readSrcFile(alloc, project, "split.sexp")) orelse return error.TestExpectedEqual;
    defer alloc.free(design);
    try std.testing.expectEqualStrings("(design-block \"Split\")", design);
    // The manifest proves the diagram sidecar did not exist in this revision.
    try std.testing.expect((try readSrcFile(alloc, project, "split.diagram.sexp")) == null);
}

// spec: Web Server - A history entry written before sidecars were snapshotted still restores its design file and leaves today's sidecars alone
test "a legacy single-file history entry stays restorable" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(project);

    try seedSrcFile(alloc, project, "old.sexp", "(design-block \"New\")");
    try seedSrcFile(alloc, project, "old.layout.sexp", "(stackup (layers 4))");

    // A pre-manifest entry: the design source alone, no `.files`.
    const dir = try std.fmt.allocPrint(alloc, "{s}/history/old/2026-01-01T00-00-01", .{project});
    defer alloc.free(dir);
    try infra_fs.cwd().makePath(dir);
    const legacy = try std.fmt.allocPrint(alloc, "{s}/old.sexp", .{dir});
    defer alloc.free(legacy);
    try infra_fs.cwd().writeFile(.{ .sub_path = legacy, .data = "(design-block \"Old\")" });

    try restore(alloc, project, "old", "2026-01-01T00-00-01");

    const design = (try readSrcFile(alloc, project, "old.sexp")) orelse return error.TestExpectedEqual;
    defer alloc.free(design);
    try std.testing.expectEqualStrings("(design-block \"Old\")", design);
    // The entry says nothing about sidecars, so today's is neither reverted
    // nor deleted.
    const layout = (try readSrcFile(alloc, project, "old.layout.sexp")) orelse return error.TestExpectedEqual;
    defer alloc.free(layout);
    try std.testing.expectEqualStrings("(stackup (layers 4))", layout);
}

// spec: Web Server - The layout sidecar is snapshotted into history and listed newest-first
test "layout snapshot writes to history and lists back" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
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
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(project);

    const sidecar = try std.fmt.allocPrint(alloc, "{s}/foo.layouts.json", .{project});
    defer alloc.free(sidecar);
    try infra_fs.cwd().writeFile(.{ .sub_path = sidecar, .data = "{\"layouts\":[]}" });

    // Pre-seed MAX+2 distinct fake snapshots dated 2026-01-01 (older than the
    // real timestamp the snapshot below mints, so it becomes the newest).
    try seedFakeLayoutSnapshots(alloc, project, "foo", max_layout_snapshots + 2);

    // One real snapshot pushes the total past the cap and triggers the prune.
    const id = (try snapshotLayouts(alloc, project, "foo", sidecar)) orelse return error.TestExpectedId;
    defer alloc.free(id);

    const snaps = try listLayoutSnapshots(alloc, project, "foo");
    defer {
        for (snaps) |s| alloc.free(s.id);
        alloc.free(snaps);
    }
    try std.testing.expectEqual(max_layout_snapshots, snaps.len);
    // Newest-first: the real snapshot leads; the oldest fakes were pruned.
    try std.testing.expectEqualStrings(id, snaps[0].id);
    try std.testing.expectError(error.SnapshotNotFound, layoutSnapshotPath(alloc, project, "foo", "2026-01-01T00-00-01"));
}

// spec: Web Server - Source-snapshot listing skips the reserved layouts subdir
test "source snapshot list ignores the layouts subdir" {
    const alloc = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(project);

    // A layout snapshot dir plus a real source snapshot dir side by side.
    const lay = try std.fmt.allocPrint(alloc, "{s}/history/foo/{s}/2026-01-01T00-00-01", .{ project, layout_subdir });
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

test "restore rejects traversal chars only, letting a clean id reach the lookup" {
    // The `c == '/'/'\\'/0` guard must reject ONLY those chars; flipping any
    // `==` to `!=` rejects an ordinary id too, so a clean id must instead fall
    // through to the on-disk lookup and fail with SnapshotNotFound.
    try std.testing.expectError(
        error.SnapshotNotFound,
        restore(std.testing.allocator, "/no/such/project/dir", "design", "cleanid123"),
    );
}

// spec: Web Server - An installed runtime-state root moves history/ off the project, leaving its sources and sidecars in place
test "a state root relocates history without moving the design" {
    const alloc = std.testing.allocator;
    var project_tmp = std.testing.tmpDir(.{});
    defer project_tmp.cleanup();
    var state_tmp = std.testing.tmpDir(.{});
    defer state_tmp.cleanup();
    const project = try project_tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(project);
    const state = try state_tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);
    defer alloc.free(state);

    const sidecar = try std.fmt.allocPrint(alloc, "{s}/foo.layouts.json", .{project});
    defer alloc.free(sidecar);
    try infra_fs.cwd().writeFile(.{ .sub_path = sidecar, .data = "{\"rev\":7,\"layouts\":[]}" });

    // Serving or laying out a TRACKED project used to drop history/ into it.
    paths.setStateRoot(state);
    defer paths.setStateRoot(null);

    const id = (try snapshotLayouts(alloc, project, "foo", sidecar)) orelse return error.TestExpectedId;
    defer alloc.free(id);

    // The snapshot is readable exactly as before — the relocation is invisible
    // to every caller, which is why no call site had to learn about it …
    const p = try layoutSnapshotPath(alloc, project, "foo", id);
    defer alloc.free(p);
    try std.testing.expect(std.mem.startsWith(u8, p, state));
    const data = try infra_fs.cwd().readFileAlloc(alloc, p, 1 << 20);
    defer alloc.free(data);
    try std.testing.expect(std.mem.indexOf(u8, data, "\"rev\":7") != null);

    // … and the project directory grew no history/ at all.
    const in_project = try std.fmt.allocPrint(alloc, "{s}/history", .{project});
    defer alloc.free(in_project);
    try std.testing.expectError(error.FileNotFound, infra_fs.cwd().access(in_project, .{}));

    // Clearing the root puts the next snapshot back beside the design, so the
    // relocation is a startup decision and not a one-way door.
    paths.setStateRoot(null);
    const back_id = (try snapshotLayouts(alloc, project, "foo", sidecar)) orelse return error.TestExpectedId;
    defer alloc.free(back_id);
    const back = try layoutSnapshotPath(alloc, project, "foo", back_id);
    defer alloc.free(back);
    try std.testing.expect(std.mem.startsWith(u8, back, project));
}
