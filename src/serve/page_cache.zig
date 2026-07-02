//! File-mtime fingerprints for the server's cross-request page caches.
//!
//! The HTTP server runs every request on a per-request arena that is freed
//! after the response (the fix for an 11.7 GB request-leak), so nothing
//! survives a request by default. Caching an expensive result (a rendered
//! schematic page, a design summary) across requests therefore means storing
//! it in `page_allocator` and re-deriving validity from the source files it
//! came from. A `FileSet` records the `(path, mtime, present)` of every file an
//! evaluation read — the design `.sexp`, its `.checks.sexp`, every
//! transitively-imported `lib/` file, and the `.bom`/`.refdes.json`/`.notes.md`
//! siblings the renderer consumes. A cached entry is valid only while every
//! recorded file still has its recorded mtime and presence; any edit, add, or
//! delete flips it, so a live design edit (via `/api/push`, the surgical edit
//! endpoints, the MCP `write_file`/`edit_file` tools, or a bare `vim` save) is
//! picked up on the next load. The capture is keyed off the evaluator's
//! `loaded_files` read-set, so it tracks exactly the files that fed the result.

const std = @import("std");
const infra_fs = @import("../infra/fs.zig");
const paths = @import("../paths.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;

/// All cross-request cache state is pinned to the process page allocator so it
/// outlives the per-request arenas that produced it.
const page = std.heap.page_allocator;

/// Sibling extensions (next to the design `.sexp`) whose contents feed a
/// rendered page or summary even though the evaluator itself doesn't parse
/// them: `.bom` (identity resolution), `.refdes.json` (grouped ref-des), and
/// `.checks.sexp` (spliced verification forms — already in the read-set when
/// it exists, listed here so its *creation* also invalidates).
const sibling_exts = [_][]const u8{ ".bom", ".refdes.json", ".checks.sexp" };

/// One file a cached result derived from. `present` records whether the file
/// existed at capture time, so a later appearance (e.g. a first-time `.bom`)
/// invalidates just as a deletion does. `path` is owned by `page`.
pub const FileStamp = struct {
    path: []const u8,
    mtime_ns: i128,
    present: bool,
};

/// The complete file dependency set of one cached result. Owned by `page`.
pub const FileSet = struct {
    stamps: []FileStamp,

    /// Free the owned path strings and the stamp slice.
    pub fn deinit(self: FileSet) void {
        for (self.stamps) |s| page.free(s.path);
        page.free(self.stamps);
    }

    /// True only while every recorded file still has its captured mtime and
    /// presence — i.e. nothing the cached result depends on has changed. A
    /// stat failure is treated as "absent": unchanged if it was absent at
    /// capture, invalidating if it was present.
    pub fn isValid(self: FileSet) bool {
        for (self.stamps) |s| {
            if (infra_fs.cwd().statFile(s.path)) |st| {
                if (!s.present or st.mtime != s.mtime_ns) return false;
            } else |_| {
                if (s.present) return false;
            }
        }
        return true;
    }
};

/// Stat `path` and record it, duping the path into `page`. An absent file is
/// recorded with `present=false` so its later creation invalidates the entry.
fn stampOf(path: []const u8) std.mem.Allocator.Error!FileStamp {
    const owned = try page.dupe(u8, path);
    if (infra_fs.cwd().statFile(path)) |st| {
        return .{ .path = owned, .mtime_ns = st.mtime, .present = true };
    } else |_| {
        return .{ .path = owned, .mtime_ns = 0, .present = false };
    }
}

/// Notes sidecar path, matching `serve/notes.zig`'s subdir-aware convention
/// (`<sexp-dir>/<name>.notes.md`) so the stamp tracks the exact file the
/// open-task count reads.
fn notesSibling(scratch: std.mem.Allocator, project_dir: []const u8, name: []const u8) std.mem.Allocator.Error![]u8 {
    const src = paths.designSourcePath(scratch, project_dir, name) catch return std.fmt.allocPrint(scratch, "{s}.notes.md", .{name});
    defer scratch.free(src);
    const dir = std.fs.path.dirname(src) orelse "";
    if (dir.len == 0) return std.fmt.allocPrint(scratch, "{s}.notes.md", .{name});
    return std.fmt.allocPrint(scratch, "{s}/{s}.notes.md", .{ dir, name });
}

/// The bare module name of a loaded `…/lib/modules/<m>.sexp` path (null for any
/// other file). Its `<m>.layouts.json` sidecar holds the ★ star that drives the
/// block-overview design-maturity dot + the module-layout panels, but the
/// evaluator never parses it — so `capture` stamps it explicitly, resolving the
/// path through the same `designSiblingPath` the reader (`layout_status.read`)
/// uses. That matters because the sidecar is NOT always next to the module: an
/// orphaned `src/<m>.layouts.json` (left by a retired wrapper design) wins
/// `findUniqueInSrc`, so a naive lib/modules guess would track the wrong file
/// and never invalidate. A `src/` design's own board layout is deliberately not
/// tracked — it drives no maturity dot and would re-render the page on every
/// optimizer solve.
fn moduleNameFromPath(sexp_path: []const u8) ?[]const u8 {
    if (!std.mem.endsWith(u8, sexp_path, ".sexp")) return null;
    if (std.mem.indexOf(u8, sexp_path, "lib/modules/") == null) return null;
    const base = std.fs.path.basename(sexp_path);
    return base[0 .. base.len - ".sexp".len];
}

/// Capture the dependency set of a just-completed evaluation of design `name`:
/// every file the evaluator read (`eval.loaded_files` — design, checks, and all
/// transitively-imported lib files) plus the `.bom`/`.refdes.json`/`.checks`/
/// `.notes.md` siblings. `scratch` is the request arena (used only to build
/// sibling path strings); every retained path is duped into `page`. The
/// returned `FileSet` is owned by the caller (`deinit` it when evicting).
pub fn capture(
    scratch: std.mem.Allocator,
    eval: *const Evaluator,
    project_dir: []const u8,
    name: []const u8,
) std.mem.Allocator.Error!FileSet {
    var list: std.ArrayListUnmanaged(FileStamp) = .empty;
    errdefer {
        for (list.items) |s| page.free(s.path);
        list.deinit(page);
    }

    var it = eval.loaded_files.keyIterator();
    while (it.next()) |k| {
        try list.append(page, try stampOf(k.*));
        // A module's ★ layout star lives in its `<module>.layouts.json`, which
        // the evaluator never parses but the maturity dot / layout panels read.
        // Resolve it through the reader's own `designSiblingPath` (so an orphaned
        // `src/<m>.layouts.json` is tracked at the path actually read) and stamp
        // it, so starring a layout invalidates pages showing its completion.
        if (moduleNameFromPath(k.*)) |m| {
            const lp = paths.designSiblingPath(scratch, project_dir, m, ".layouts.json") catch continue;
            defer scratch.free(lp);
            try list.append(page, try stampOf(lp));
        }
    }

    for (sibling_exts) |ext| {
        const p = paths.designSiblingPath(scratch, project_dir, name, ext) catch continue;
        defer scratch.free(p);
        try list.append(page, try stampOf(p));
    }
    if (notesSibling(scratch, project_dir, name)) |np| {
        defer scratch.free(np);
        try list.append(page, try stampOf(np));
    } else |_| {}

    return .{ .stamps = try list.toOwnedSlice(page) };
}

test "FileSet validity flips when a tracked file's mtime changes" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(rel);
    const fpath = try std.fmt.allocPrint(testing.allocator, "{s}/dep.sexp", .{rel});
    defer testing.allocator.free(fpath);

    try tmp.dir.writeFile(.{ .sub_path = "dep.sexp", .data = "(a)" });

    var fs: FileSet = .{ .stamps = try page.alloc(FileStamp, 1) };
    defer fs.deinit();
    fs.stamps[0] = try stampOf(fpath);
    try testing.expect(fs.isValid());

    // A content rewrite bumps mtime → the set must read as stale. (Some
    // filesystems have coarse mtime resolution, so force a distinct stamp.)
    try tmp.dir.writeFile(.{ .sub_path = "dep.sexp", .data = "(a b c)" });
    fs.stamps[0].mtime_ns -= std.time.ns_per_s;
    try testing.expect(!fs.isValid());
}

test "absent-then-present sibling invalidates" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const rel = try tmp.dir.realpathAlloc(testing.allocator, ".");
    defer testing.allocator.free(rel);
    const fpath = try std.fmt.allocPrint(testing.allocator, "{s}/late.bom", .{rel});
    defer testing.allocator.free(fpath);

    var fs: FileSet = .{ .stamps = try page.alloc(FileStamp, 1) };
    defer fs.deinit();
    fs.stamps[0] = try stampOf(fpath); // absent → present=false
    try testing.expect(!fs.stamps[0].present);
    try testing.expect(fs.isValid());

    try tmp.dir.writeFile(.{ .sub_path = "late.bom", .data = "x" });
    try testing.expect(!fs.isValid());
}

test "moduleNameFromPath extracts the module name only for lib/modules sexps" {
    const testing = std.testing;
    // A loaded module source → its bare name (capture then resolves the sidecar
    // via designSiblingPath, so an orphaned src/<m>.layouts.json is tracked too).
    try testing.expectEqualStrings("w55rp20", moduleNameFromPath("projects/designs/lib/modules/w55rp20.sexp").?);
    try testing.expectEqualStrings("tpsm84338", moduleNameFromPath("/abs/lib/modules/tpsm84338.sexp").?);

    // A `src/` design source is not a module → not tracked (its board layout
    // drives no maturity dot and would re-render the page on every solve).
    try testing.expect(moduleNameFromPath("projects/designs/src/barracuda/barracuda-base.sexp") == null);
    // Library files that aren't modules, and non-`.sexp` paths, are ignored.
    try testing.expect(moduleNameFromPath("projects/designs/lib/components/res-0402.sexp") == null);
    try testing.expect(moduleNameFromPath("projects/designs/lib/modules/w55rp20.layouts.json") == null);
}
