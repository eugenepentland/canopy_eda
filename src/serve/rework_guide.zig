//! Load the human-authored assembly rework guides for a design.
//!
//! A design may carry several guides: the legacy `<design>.rework.md` sibling
//! plus any `<design>-<slug>.rework.md` companion beside it, so one board can
//! keep a separate bench document per deviation. A companion whose slug is
//! itself a design in that directory (`board-a-base.sexp` beside
//! `board-a.sexp`) stays with its own design. Rendering stays in the
//! assembly client, where `[[uuid:...]]`, `[[pin:UUID.PAD]]`, and `[[net:...]]`
//! targets become board-focus controls.

const std = @import("std");
const infra_fs = @import("../infra/fs.zig");
const log = @import("../infra/log.zig");
const paths = @import("../paths.zig");

const extension = ".rework.md";
/// Cap on a `<slug>.rework.md` read - a hand-written Markdown guide, which is
/// its own artifact class and shares no figure with the .sexp/board readers.
const max_guide_bytes: usize = 256 * 1024;

/// One discovered guide. `slug` is the filename base without `extension` (the
/// legacy file's slug is the design name itself), `title` is the first `# `
/// heading, and `body` is the trimmed Markdown source.
pub const Guide = struct {
    slug: []const u8,
    title: []const u8,
    body: []const u8,
};

/// Return every guide for a design, legacy file first and the rest ordered by
/// filename, skipping any whose slug is a design of its own. A missing
/// directory, or an unreadable, oversized, or empty file, is deliberately
/// equivalent to no guide: assembly review must remain available even when its
/// supplemental bench documents are unavailable.
pub fn loadAll(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
) []const Guide {
    return collect(allocator, project_dir, name) catch &.{};
}

/// True when `filename` is a guide belonging to design `name` — either the
/// legacy `<name>.rework.md` or a `<name>-<slug>.rework.md` companion. The
/// separator is required so `board-a2-foo.rework.md` never joins `board-a`.
fn belongsTo(filename: []const u8, name: []const u8) bool {
    if (!std.mem.endsWith(u8, filename, extension)) return false;
    const base = filename[0 .. filename.len - extension.len];
    if (!std.mem.startsWith(u8, base, name)) return false;
    if (base.len == name.len) return true;
    return base[name.len] == '-';
}

/// True when `slug` names a design of its own in this directory. `board-a-base.sexp`
/// sits beside `board-a.sexp` here, so `board-a-base.rework.md` is that design's
/// own legacy guide, not a `board-a` companion — and its UUID targets address the
/// other board's parts, which would drive focus controls to the wrong board.
fn ownedByAnotherDesign(
    allocator: std.mem.Allocator,
    dir: infra_fs.Dir,
    slug: []const u8,
    name: []const u8,
) bool {
    if (std.mem.eql(u8, slug, name)) return false;
    const source = std.fmt.allocPrint(allocator, "{s}.sexp", .{slug}) catch return false;
    defer allocator.free(source);
    dir.access(source, .{}) catch return false;
    return true;
}

/// Order guides deterministically: the legacy file leads, then filename bytes.
/// Directory iteration order is not stable, so this is what keeps the list the
/// same on every request.
fn earlier(name: []const u8, a: []const u8, b: []const u8) bool {
    const a_legacy = a.len == name.len + extension.len;
    const b_legacy = b.len == name.len + extension.len;
    if (a_legacy != b_legacy) return a_legacy;
    return std.mem.lessThan(u8, a, b);
}

/// The guide's display name: its first `# ` heading, else its slug. A guide
/// whose author never wrote a heading still needs something clickable.
fn titleOf(body: []const u8, slug: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, body, '\n');
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, "# ")) continue;
        const title = std.mem.trim(u8, line[2..], " \t\r");
        if (title.len > 0) return title;
    }
    return slug;
}

fn collect(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
) ![]const Guide {
    const source = try paths.designSourcePath(allocator, project_dir, name);
    const dir_path = std.fs.path.dirname(source) orelse ".";
    var dir = infra_fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return &.{};
    defer dir.close();

    var filenames: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    // All-or-nothing on a listing error: a partial list is worse than none,
    // because the page gives the reader no sign that a guide is missing.
    while (it.next() catch |err| {
        log.warn("rework_guide: cannot list {s}: {s}", .{ dir_path, @errorName(err) });
        return err;
    }) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!belongsTo(entry.name, name)) continue;
        const slug = entry.name[0 .. entry.name.len - extension.len];
        if (ownedByAnotherDesign(allocator, dir, slug, name)) continue;
        try filenames.append(allocator, try allocator.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, filenames.items, name, earlier);

    var guides: std.ArrayList(Guide) = .empty;
    for (filenames.items) |filename| {
        const raw = dir.readFileAlloc(allocator, filename, max_guide_bytes) catch continue;
        const body = std.mem.trim(u8, raw, " \t\r\n");
        if (body.len == 0) continue;
        const slug = filename[0 .. filename.len - extension.len];
        try guides.append(allocator, .{
            .slug = slug,
            .title = titleOf(body, slug),
            .body = body,
        });
    }
    return guides.toOwnedSlice(allocator);
}

test "missing rework guide is optional" {
    // Discovery resolves a path before it can fail, and never frees it — the
    // handler hands it `req.arena`, so the test owns the same shape.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqual(@as(usize, 0), loadAll(
        arena.allocator(),
        "/tmp/netlisp-no-such-project",
        "demo",
    ).len);
}

/// Build `<tmp>/src/` holding a design source plus the named guide files, and
/// return the project directory the loader should be pointed at.
fn seedProject(
    allocator: std.mem.Allocator,
    tmp: *std.testing.TmpDir,
    files: []const [2][]const u8,
) ![]const u8 {
    try tmp.dir.createDirPath(std.testing.io, "src");
    var src = try tmp.dir.openDir(std.testing.io, "src", .{});
    defer src.close(std.testing.io);
    for (files) |file| try src.writeFile(std.testing.io, .{ .sub_path = file[0], .data = file[1] });
    return tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
}

// spec: Web Server - assembly discovers every <design>-<slug>.rework.md companion beside the legacy guide, orders the legacy file first and the rest by filename, and never adopts another design's guide
test "multi-guide discovery orders the legacy file first and rejects foreign designs" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try seedProject(arena.allocator(), &tmp, &.{
        .{ "demo.sexp", "(design-block \"Demo\")" },
        .{ "demo-zeta.rework.md", "# Zeta" },
        .{ "demo.rework.md", "# Legacy" },
        .{ "demo-alpha.rework.md", "# Alpha" },
        .{ "demo2-foreign.rework.md", "# Foreign" },
        .{ "demoextra.rework.md", "# No separator" },
        .{ "demo-blank.rework.md", "   \n\n" },
    });

    const guides = loadAll(arena.allocator(), project, "demo");
    try std.testing.expectEqual(@as(usize, 3), guides.len);
    try std.testing.expectEqualStrings("demo", guides[0].slug);
    try std.testing.expectEqualStrings("demo-alpha", guides[1].slug);
    try std.testing.expectEqualStrings("demo-zeta", guides[2].slug);
}

// spec: Web Server - a rework guide whose slug is itself a design in the same directory stays that design's own legacy guide and is never adopted by its name-prefixed neighbour
test "a sibling design's legacy guide is never adopted by its name-prefixed neighbour" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // The live shape in projects/designs/src/boards/board-a/.
    const project = try seedProject(arena.allocator(), &tmp, &.{
        .{ "demo.sexp", "(design-block \"Demo\")" },
        .{ "demo-base.sexp", "(design-block \"Demo Base\")" },
        .{ "demo.rework.md", "# Demo" },
        .{ "demo-base.rework.md", "# Demo Base" },
        .{ "demo-bypass.rework.md", "# Bypass" },
    });

    const owner = loadAll(arena.allocator(), project, "demo");
    try std.testing.expectEqual(@as(usize, 2), owner.len);
    try std.testing.expectEqualStrings("demo", owner[0].slug);
    try std.testing.expectEqualStrings("demo-bypass", owner[1].slug);

    const sibling = loadAll(arena.allocator(), project, "demo-base");
    try std.testing.expectEqual(@as(usize, 1), sibling.len);
    try std.testing.expectEqualStrings("demo-base", sibling[0].slug);
}

// spec: Web Server - each assembly rework guide takes its title from its first Markdown H1 and falls back to its filename slug
test "guide titles come from the first H1 and fall back to the slug" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try seedProject(arena.allocator(), &tmp, &.{
        .{ "demo.sexp", "(design-block \"Demo\")" },
        .{ "demo.rework.md", "Intro line\n\n#  ADF4159 bypass  \nBody" },
        .{ "demo-untitled.rework.md", "No heading here\n## Not an H1" },
    });

    const guides = loadAll(arena.allocator(), project, "demo");
    try std.testing.expectEqual(@as(usize, 2), guides.len);
    try std.testing.expectEqualStrings("ADF4159 bypass", guides[0].title);
    try std.testing.expectEqualStrings("demo-untitled", guides[1].title);
}

test "a legacy single guide still loads with its body intact" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try seedProject(arena.allocator(), &tmp, &.{
        .{ "demo.sexp", "(design-block \"Demo\")" },
        .{ "demo.rework.md", "\n# Bodge\nReplace [[net:VTUNE]].\n\n" },
    });

    const guides = loadAll(arena.allocator(), project, "demo");
    try std.testing.expectEqual(@as(usize, 1), guides.len);
    try std.testing.expectEqualStrings("demo", guides[0].slug);
    try std.testing.expectEqualStrings("Bodge", guides[0].title);
    try std.testing.expectEqualStrings("# Bodge\nReplace [[net:VTUNE]].", guides[0].body);
}
