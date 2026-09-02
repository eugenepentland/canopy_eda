//! Recover PCB layouts that exist only in history and fold them back into a
//! block's `.layouts.json` as ordinary named rows.
//!
//! Two archives hold boards the sidecar itself no longer does. `history/<name>/
//! layouts/<stamp>/` keeps the pre-write copy taken before every layout
//! mutation, and git keeps every committed revision of the sidecar. Under the
//! retired single-layout rule a design's Save REPLACED its whole list, so each
//! of those copies is a distinct placement + routing that is otherwise
//! unreachable — the autoroute progression of a board, one snapshot per run.
//!
//! This module reads both archives, drops anything whose board already exists
//! (fingerprinted on placement AND copper, so two routings of one placement are
//! kept apart), and appends the rest to the sidecar. Recovered rows are plain
//! manual entries: they get a `?layout=<name>` permalink, a score, Load / ★ /
//! Delete, exactly like a layout you saved by hand.
//!
//! Nothing is destroyed. The existing rows keep their order and the ★ never
//! moves, so the KiCad sync and the fab outputs resolve the same board before
//! and after. The CLI seam is `serve/layout_backfill_command.zig`.

const std = @import("std");
const infra_fs = @import("../infra/fs.zig");
const paths = @import("../paths.zig");
const history = @import("history.zig");
const subprocess = @import("subprocess.zig");
const page = @import("pcb_layout_page.zig");
const saved_zone = @import("saved_zone.zig");
const sidecar_publish = @import("layout_sidecar_publish.zig");

const SavedLayout = page.SavedLayout;

/// A sidecar body above this size is treated as unreadable rather than loaded —
/// the same ceiling the page itself reads a `.layouts.json` with, so a board
/// this pass can mine is a board the viewer can open. It was an independent
/// literal of the same value; the shared constant is what keeps the two from
/// parting.
const sidecar_max_bytes: usize = page.sidecar_max_bytes;
/// Ceiling on one `git` invocation's captured output, and how long it may run.
/// Walking up to `max_git_revisions` of history is a batch job, so the deadline
/// is far longer than the per-request one in autocommit.zig.
const git_output_cap: usize = 16 * 1024 * 1024;
const git_history_timeout_ms: u64 = 30_000;
/// Newest-first revisions inspected per sidecar. Every distinct board in them
/// is a candidate; the cap only bounds how far back a pathological history is
/// walked, so one runaway file cannot stall a whole-project pass.
const max_git_revisions: usize = 200;

/// Where a recovered board was found — reported so a run says which archive
/// produced each row.
pub const Source = enum { history, git };

/// How many rows a backfill added to one block, and what it left behind.
pub const Report = struct {
    /// Rows appended to the sidecar (0 when nothing new was found).
    added: usize = 0,
    /// Distinct boards found but not added because `limit` was reached.
    over_limit: usize = 0,
    /// Rows the sidecar already had before the pass.
    existing: usize = 0,
    /// The sidecar was actually written (false for a dry run, or no additions).
    written: bool = false,
    /// Per-source tallies of what was added.
    from_history: usize = 0,
    from_git: usize = 0,
};

/// Knobs for one backfill pass.
pub const Options = struct {
    /// Most rows to append to a single block. A bound, not a target: it exists
    /// so a block with a very long history cannot bury its hand-saved layouts.
    limit: usize = 20,
    /// Report what would be added without touching the sidecar.
    dry_run: bool = false,
};

/// A board found in an archive, with the stamp that dates it.
const Candidate = struct {
    layout: SavedLayout,
    source: Source,
    /// `YYYY-MM-DDTHH-MM-SS` — the snapshot directory name, or the commit date.
    stamp: []const u8,
};

/// Fold every board recoverable from history into `name`'s sidecar.
///
/// Candidates are considered newest-first, so when `limit` bites it is the
/// oldest boards that are dropped. Recovered rows land as `manual` — they are
/// kept, named boards now, not auto stamps, and a manual row is never folded
/// away by the panel's duplicate collapse. Returns what the pass did; a block
/// with no archive, or nothing new in it, reports `added = 0` and writes
/// nothing.
pub fn backfill(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    opts: Options,
) Report {
    const current = page.readLayouts(alloc, project_dir, name);
    var report = Report{ .existing = current.len };

    // Boards already present, so a recovered copy of one is skipped.
    var seen = std.AutoHashMapUnmanaged(u64, void).empty;
    for (current) |L| seen.put(alloc, boardKey(L), {}) catch return report;
    // Names already spoken for, so a recovered row can never shadow one.
    var taken = std.StringHashMapUnmanaged(void).empty;
    for (current) |L| taken.put(alloc, L.name, {}) catch return report;

    var out: std.ArrayList(SavedLayout) = .empty;
    out.appendSlice(alloc, current) catch return report;

    for (collect(alloc, project_dir, name)) |cand| {
        const key = boardKey(cand.layout);
        if (seen.contains(key)) continue;
        seen.put(alloc, key, {}) catch return report;
        if (report.added >= opts.limit) {
            report.over_limit += 1;
            continue;
        }
        var entry = cand.layout;
        entry.kind = page.kind_manual;
        // Never steal the ★: the blessed board is the user's pick, and the
        // KiCad sync and fab outputs must resolve the same one after this pass.
        entry.default = false;
        entry.name = uniqueName(alloc, &taken, cand) orelse continue;
        taken.put(alloc, entry.name, {}) catch return report;
        out.append(alloc, entry) catch return report;
        report.added += 1;
        switch (cand.source) {
            .history => report.from_history += 1,
            .git => report.from_git += 1,
        }
    }

    if (report.added == 0 or opts.dry_run) return report;
    report.written = write(alloc, project_dir, name, out.items);
    return report;
}

/// Persist the merged list with user-save semantics. The previous sidecar is
/// rolled into `history/` first, so this pass is itself undoable — the recovery
/// archive is the only place the rows it replaces still live.
fn write(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    layouts: []const SavedLayout,
) bool {
    return sidecar_publish.publish(alloc, project_dir, name, .{ .snapshot_previous = true }, layouts, mergedRows);
}

/// The list is already merged before the hold is taken — this pass reads the
/// sidecar's rows through `collect`, not through the transaction — so the
/// publish callback is the identity.
fn mergedRows(layouts: []const SavedLayout, _: std.mem.Allocator) ?[]const SavedLayout {
    return layouts;
}

/// Every board in both archives, newest-first: the `history/` snapshots (which
/// `listLayoutSnapshots` already returns newest-first) ahead of the git
/// revisions. Order decides which copy of a duplicated board supplies the name
/// and which are dropped, so the freshest spelling wins.
fn collect(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8) []const Candidate {
    var out: std.ArrayList(Candidate) = .empty;
    appendHistory(alloc, project_dir, name, &out);
    appendGit(alloc, project_dir, name, &out);
    return out.items;
}

/// Candidates from `history/<name>/layouts/<stamp>/`.
fn appendHistory(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    out: *std.ArrayList(Candidate),
) void {
    const snaps = history.listLayoutSnapshots(alloc, project_dir, name) catch return;
    for (snaps) |snap| {
        const path = history.layoutSnapshotPath(alloc, project_dir, name, snap.id) catch continue;
        const data = infra_fs.cwd().readFileAlloc(alloc, path, sidecar_max_bytes) catch continue;
        const parsed = page.parseLayouts(alloc, data) orelse continue;
        for (parsed) |L| out.append(alloc, .{ .layout = L, .source = .history, .stamp = snap.id }) catch return;
    }
}

/// Candidates from the sidecar's committed git revisions. A project that is not
/// a git checkout, or a sidecar git has never seen, simply yields none — the
/// history archive stands alone.
fn appendGit(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    out: *std.ArrayList(Candidate),
) void {
    const rel = relSidecarPath(alloc, project_dir, name) orelse return;
    const log = gitCapture(alloc, project_dir, &.{
        "log", "--all", "--pretty=format:%H %ad", "--date=format:%Y-%m-%dT%H-%M-%S", "--", rel,
    }) orelse return;

    var lines = std.mem.tokenizeScalar(u8, log, '\n');
    var n: usize = 0;
    while (lines.next()) |line| {
        if (n >= max_git_revisions) return;
        n += 1;
        const sp = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const sha = line[0..sp];
        const stamp = std.mem.trim(u8, line[sp + 1 ..], " \t\r");
        const spec = std.fmt.allocPrint(alloc, "{s}:{s}", .{ sha, rel }) catch return;
        const blob = gitCapture(alloc, project_dir, &.{ "show", spec }) orelse continue;
        const parsed = page.parseLayouts(alloc, blob) orelse continue;
        for (parsed) |L| out.append(alloc, .{ .layout = L, .source = .git, .stamp = stamp }) catch return;
    }
}

/// The sidecar's path RELATIVE to `project_dir` — what `git log`/`git show`
/// need, since both run with `-C project_dir`. Null when the resolved path
/// isn't under the project (nothing git there could name).
fn relSidecarPath(alloc: std.mem.Allocator, project_dir: []const u8, name: []const u8) ?[]const u8 {
    const abs = paths.designSiblingPath(alloc, project_dir, name, page.layouts_ext) catch return null;
    if (!std.mem.startsWith(u8, abs, project_dir)) return null;
    const rest = abs[project_dir.len..];
    const trimmed = std.mem.trimStart(u8, rest, "/");
    return if (trimmed.len == 0) null else trimmed;
}

/// Run `git -C project_dir <args…>` and return stdout, or null on any failure
/// (git missing, not a repo, non-zero exit). Read-only: this module never runs
/// a git subcommand that writes.
fn gitCapture(alloc: std.mem.Allocator, project_dir: []const u8, args: []const []const u8) ?[]const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    argv.appendSlice(alloc, &.{ "git", "-C", project_dir }) catch return null;
    argv.appendSlice(alloc, args) catch return null;
    const res = subprocess.runCaptured(alloc, argv.items, git_output_cap, git_history_timeout_ms) catch return null;
    // A timeout / oversized capture / spawn failure is reported through
    // `outcome`, not as an error — treat every one of them as "no git here".
    if (res.outcome != .ok or (res.exit_code orelse 1) != 0) return null;
    return if (res.stdout.len == 0) null else res.stdout;
}

/// A name for a recovered row that no existing row already uses. The archive's
/// own spelling is kept when it is free — that preserves the meaningful
/// `auto · Jun 17 16:31:13` stamps — and otherwise the row is dated from the
/// snapshot it came out of, which is what disambiguates the many boards saved
/// under the generic name `layout`.
fn uniqueName(
    alloc: std.mem.Allocator,
    taken: *std.StringHashMapUnmanaged(void),
    cand: Candidate,
) ?[]const u8 {
    const orig = cand.layout.name;
    if (orig.len > 0 and !taken.contains(orig)) return orig;
    const base = if (orig.len > 0) orig else "layout";
    var sbuf: [32]u8 = undefined;
    const dated = std.fmt.allocPrint(alloc, "{s} · {s}", .{ base, shortStamp(&sbuf, cand.stamp) }) catch return null;
    if (!taken.contains(dated)) return dated;
    // Two distinct boards inside one snapshot second: number them apart rather
    // than dropping either.
    var i: usize = 2;
    while (i < 100) : (i += 1) {
        const numbered = std.fmt.allocPrint(alloc, "{s} #{d}", .{ dated, i }) catch return null;
        if (!taken.contains(numbered)) return numbered;
    }
    return null;
}

/// `2026-07-25T05-19-23` → `07-25 05:19:23`: the year is noise in a panel row,
/// and the `:` separators read as a clock. Formats into the CALLER's `buf` (the
/// result is copied by the `allocPrint` it feeds, so nothing outlives it).
/// Anything not in that shape is passed through unchanged.
fn shortStamp(buf: []u8, stamp: []const u8) []const u8 {
    if (stamp.len != "YYYY-MM-DDTHH-MM-SS".len or stamp[10] != 'T') return stamp;
    return std.fmt.bufPrint(buf, "{s} {s}:{s}:{s}", .{
        stamp[5..10], stamp[11..13], stamp[14..16], stamp[17..19],
    }) catch stamp;
}

// ── Board identity ──────────────────────────────────────────────────────────

/// Fingerprint of the BOARD a layout describes: every part pose plus every
/// piece of copper.
///
/// Copper is part of the identity on purpose. The optimizer score measures
/// placement only, so two autoroute runs over one placement score identically —
/// keying on the score alone would collapse exactly the candidates this whole
/// feature exists to let you compare. Float fields are hashed by their bits:
/// two snapshots of one board store the same decimal text and so decode to the
/// same bits, and no float→int conversion is needed to compare them.
pub fn boardKey(L: SavedLayout) u64 {
    var h = std.hash.Wyhash.init(0);
    for (L.parts) |p| {
        h.update(p.ref);
        h.update(std.mem.asBytes(&p.x));
        h.update(std.mem.asBytes(&p.y));
        h.update(std.mem.asBytes(&p.rot));
        h.update(std.mem.asBytes(&p.side));
    }
    const r = L.routes orelse return h.final();
    for (r.tracks) |t| {
        h.update(std.mem.asBytes(&t.x1));
        h.update(std.mem.asBytes(&t.y1));
        h.update(std.mem.asBytes(&t.x2));
        h.update(std.mem.asBytes(&t.y2));
        h.update(std.mem.asBytes(&t.l));
        h.update(t.net);
    }
    for (r.vias) |v| {
        h.update(std.mem.asBytes(&v.x));
        h.update(std.mem.asBytes(&v.y));
        h.update(v.net);
    }
    for (r.zones) |z| {
        h.update(z.net);
        var legacy: [1][]const u8 = undefined;
        for (saved_zone.layers(&z, &legacy)) |layer_name| h.update(layer_name);
        h.update(std.mem.asBytes(&z.poly.len));
    }
    return h.final();
}

// ── Tests ───────────────────────────────────────────────────────────────────

/// A sidecar body with one starred board: U1 at (1,1), no copper.
const t_current =
    \\{"default":"layout","layouts":[
    \\ {"name":"layout","kind":"manual","ts":9,"parts":[{"ref":"U1","x":1,"y":1,"rot":0}]}]}
;

/// Write a project holding `name`'s sidecar plus one history snapshot.
fn tWrite(dir: std.Io.Dir, name: []const u8, stamp: []const u8, sidecar: []const u8, snap: []const u8) !void {
    var buf: [256]u8 = undefined;
    try dir.createDirPath(std.testing.io, "src");
    try dir.writeFile(std.testing.io, .{ .sub_path = try std.fmt.bufPrint(&buf, "src/{s}.layouts.json", .{name}), .data = sidecar });
    var dbuf: [256]u8 = undefined;
    const snap_dir = try std.fmt.bufPrint(&dbuf, "history/{s}/layouts/{s}", .{ name, stamp });
    try dir.createDirPath(std.testing.io, snap_dir);
    var fbuf: [320]u8 = undefined;
    try dir.writeFile(std.testing.io, .{
        .sub_path = try std.fmt.bufPrint(&fbuf, "{s}/{s}.layouts.json", .{ snap_dir, name }),
        .data = snap,
    });
}

// spec: serve/layout-backfill - a board's identity covers its copper, so two routings of one placement stay distinct
test "board identity covers copper, not just placement" {
    const parts = [_]page.PartPose{.{ .ref = "U1", .x = 1, .y = 1, .rot = 0 }};
    const a = [_]page.SavedTrack{.{ .x1 = 0, .y1 = 0, .x2 = 1, .y2 = 0, .l = 0, .w = 0.25, .net = "GND" }};
    const b = [_]page.SavedTrack{.{ .x1 = 0, .y1 = 0, .x2 = 5, .y2 = 0, .l = 0, .w = 0.25, .net = "GND" }};
    const base = SavedLayout{ .name = "x", .kind = page.kind_manual, .ts = 1, .score = null, .parts = &parts };

    var routed_a = base;
    routed_a.routes = .{ .tracks = &a, .vias = &.{}, .zones = &.{} };
    var routed_b = base;
    routed_b.routes = .{ .tracks = &b, .vias = &.{}, .zones = &.{} };

    // Same placement, different copper — the case the panel's score-based
    // collapse gets wrong and this key must not.
    try std.testing.expect(boardKey(routed_a) != boardKey(routed_b));
    // The same board hashes the same however many times it is read back.
    try std.testing.expectEqual(boardKey(routed_a), boardKey(routed_a));
    // Bare placement differs from the same placement carrying copper.
    try std.testing.expect(boardKey(base) != boardKey(routed_a));
}

// spec: serve/layout-backfill - recovered rows append after the existing ones and never move the star
// spec: serve/layout-backfill - a recovered board already present in the sidecar is skipped
test "backfill appends recovered boards and leaves the existing rows and star alone" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    // The snapshot holds the board the sidecar still has (skipped) plus one it
    // no longer does (recovered).
    try tWrite(tmp.dir, "foo", "2026-07-25T05-19-23", t_current,
        \\{"layouts":[
        \\ {"name":"layout","kind":"manual","ts":9,"parts":[{"ref":"U1","x":1,"y":1,"rot":0}]},
        \\ {"name":"older","kind":"manual","ts":8,"parts":[{"ref":"U1","x":7,"y":7,"rot":0}]}]}
    );

    const report = backfill(alloc, project, "foo", .{});
    try std.testing.expectEqual(@as(usize, 1), report.added);
    try std.testing.expectEqual(@as(usize, 1), report.existing);
    try std.testing.expectEqual(@as(usize, 1), report.from_history);
    try std.testing.expect(report.written);

    const after = page.readLayouts(alloc, project, "foo");
    try std.testing.expectEqual(@as(usize, 2), after.len);
    // The original row keeps its place and its ★ …
    try std.testing.expectEqualStrings("layout", after[0].name);
    try std.testing.expect(after[0].default);
    // … and the recovered board lands behind it, unstarred and manual.
    try std.testing.expectEqualStrings("older", after[1].name);
    try std.testing.expect(!after[1].default);
    try std.testing.expectEqualStrings(page.kind_manual, after[1].kind);
    try std.testing.expectEqual(@as(f64, 7), after[1].parts[0].x);
}

// spec: serve/layout-backfill - a recovered row keeps its archive name when free and is dated from its snapshot when taken
test "a recovered row is dated only when its archive name is already taken" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    // Two recovered boards: one under the generic name the sidecar already
    // uses, one under a free name it does not.
    try tWrite(tmp.dir, "foo", "2026-07-25T05-19-23", t_current,
        \\{"layouts":[
        \\ {"name":"layout","kind":"manual","ts":8,"parts":[{"ref":"U1","x":3,"y":3,"rot":0}]},
        \\ {"name":"auto · Jun 17 16:31:13","kind":"auto","ts":7,"parts":[{"ref":"U1","x":4,"y":4,"rot":0}]}]}
    );

    const report = backfill(alloc, project, "foo", .{});
    try std.testing.expectEqual(@as(usize, 2), report.added);
    const after = page.readLayouts(alloc, project, "foo");
    try std.testing.expectEqual(@as(usize, 3), after.len);
    // The colliding "layout" is dated from the snapshot it came out of …
    try std.testing.expectEqualStrings("layout · 07-25 05:19:23", after[1].name);
    // … while a free name is kept verbatim, so the meaningful auto stamps read
    // the same after recovery as they did before.
    try std.testing.expectEqualStrings("auto · Jun 17 16:31:13", after[2].name);
}

// spec: serve/layout-backfill - the limit bounds how many rows one block gains and reports what it turned away
// spec: serve/layout-backfill - a dry run reports what it would add and writes nothing
test "the limit caps additions and a dry run writes nothing" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    try tWrite(tmp.dir, "foo", "2026-07-25T05-19-23", t_current,
        \\{"layouts":[
        \\ {"name":"a","kind":"manual","ts":8,"parts":[{"ref":"U1","x":3,"y":3,"rot":0}]},
        \\ {"name":"b","kind":"manual","ts":7,"parts":[{"ref":"U1","x":4,"y":4,"rot":0}]},
        \\ {"name":"c","kind":"manual","ts":6,"parts":[{"ref":"U1","x":5,"y":5,"rot":0}]}]}
    );

    // A dry run at the default limit reports every recoverable board …
    const dry = backfill(alloc, project, "foo", .{ .dry_run = true });
    try std.testing.expectEqual(@as(usize, 3), dry.added);
    try std.testing.expect(!dry.written);
    // … and leaves the sidecar exactly as it found it.
    try std.testing.expectEqual(@as(usize, 1), page.readLayouts(alloc, project, "foo").len);

    // A limit of 1 takes the newest board and counts the rest as turned away,
    // rather than silently dropping them.
    const capped = backfill(alloc, project, "foo", .{ .limit = 1 });
    try std.testing.expectEqual(@as(usize, 1), capped.added);
    try std.testing.expectEqual(@as(usize, 2), capped.over_limit);
    try std.testing.expectEqual(@as(usize, 2), page.readLayouts(alloc, project, "foo").len);
}

// spec: serve/layout-backfill - empty inputs: a block with no archive and an empty sidecar recovers nothing and writes nothing
// spec: serve/layout-backfill - malformed encoding: an unparseable snapshot is skipped and the boards around it still recover
test "an empty archive recovers nothing and a malformed snapshot is stepped over" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", alloc);

    // No sidecar, no history/, no git: nothing to recover, nothing written.
    try tmp.dir.createDirPath(std.testing.io, "src");
    const bare = backfill(alloc, project, "bare", .{});
    try std.testing.expectEqual(@as(usize, 0), bare.added);
    try std.testing.expectEqual(@as(usize, 0), bare.existing);
    try std.testing.expect(!bare.written);

    // An empty sidecar with an empty layout list is the same answer.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/empty.layouts.json", .data = "{\"layouts\":[]}" });
    try std.testing.expectEqual(@as(usize, 0), backfill(alloc, project, "empty", .{}).added);

    // A snapshot that is not JSON at all sits between two that are: it is
    // stepped over, and neither neighbour is lost with it.
    try tWrite(tmp.dir, "foo", "2026-07-25T05-19-23", t_current,
        \\{"layouts":[{"name":"good-new","kind":"manual","ts":8,"parts":[{"ref":"U1","x":3,"y":3,"rot":0}]}]}
    );
    try tmp.dir.createDirPath(std.testing.io, "history/foo/layouts/2026-07-24T00-00-00");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "history/foo/layouts/2026-07-24T00-00-00/foo.layouts.json",
        .data = "{ this is not json",
    });
    try tmp.dir.createDirPath(std.testing.io, "history/foo/layouts/2026-07-23T00-00-00");
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "history/foo/layouts/2026-07-23T00-00-00/foo.layouts.json",
        .data =
        \\{"layouts":[{"name":"good-old","kind":"manual","ts":7,"parts":[{"ref":"U1","x":4,"y":4,"rot":0}]}]}
        ,
    });

    const report = backfill(alloc, project, "foo", .{});
    try std.testing.expectEqual(@as(usize, 2), report.added);
    const after = page.readLayouts(alloc, project, "foo");
    try std.testing.expectEqualStrings("good-new", after[1].name);
    try std.testing.expectEqualStrings("good-old", after[2].name);
}
