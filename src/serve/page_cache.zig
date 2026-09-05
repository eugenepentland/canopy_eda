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
//! endpoints, the CLI `write_file`/`edit_file` tools, or a bare `vim` save) is
//! picked up on the next load. The capture is keyed off the evaluator's
//! `loaded_files` read-set, so it tracks exactly the files that fed the result.

const std = @import("std");
const infra_fs = @import("../infra/fs.zig");
const process_alloc = @import("../infra/process_alloc.zig");
const paths = @import("../paths.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const sidecars = @import("../eval/sidecars.zig");

/// All cross-request cache state is pinned to the process page allocator so it
/// outlives the per-request arenas that produced it.
const page = process_alloc.durable;

/// Sibling extensions (next to the design `.sexp`) whose contents feed a
/// rendered page or summary even though the evaluator itself doesn't parse
/// them: `.bom` (identity resolution), `.refdes.json` (grouped ref-des), and
/// every autoloaded sidecar (`.checks.sexp`, `.layout.sexp`, `.diagram.sexp` —
/// spliced into the design body, so already in the read-set when they exist,
/// listed here so their *creation* also invalidates).
const sibling_exts = [_][]const u8{ ".bom", ".refdes.json" } ++ sidecars.exts;

/// One file a cached result derived from. `present` records whether the file
/// existed at capture time, so a later appearance (e.g. a first-time `.bom`)
/// invalidates just as a deletion does. `path` is owned by `page`.
///
/// A stamp may instead fingerprint a directory listing (`dir_listing=true`):
/// the cached result depends on WHICH files exist in a directory (a 3D-model
/// upload adds a `.step` to `lib/models/`), and a directory's mtime does not
/// move when an entry is created inside it (see paths.zig), so the stamp
/// records a hash of the relevant entry names and `isValid` re-walks and
/// re-hashes. `dir_suffix` selects the entries that feed the result (e.g.
/// `.step`); it is a static slice, never owned.
pub const FileStamp = struct {
    path: []const u8,
    mtime_ns: i128,
    present: bool,
    dir_listing: bool = false,
    dir_suffix: []const u8 = "",
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
    /// capture, invalidating if it was present. A directory-listing stamp is
    /// re-walked and re-hashed, so an entry created after capture flips it.
    pub fn isValid(self: FileSet) bool {
        for (self.stamps) |s| {
            if (s.dir_listing) {
                const fp = dirListingFingerprint(s.path, s.dir_suffix) orelse {
                    if (s.present) return false;
                    continue;
                };
                if (!s.present or fp != s.mtime_ns) return false;
                continue;
            }
            if (infra_fs.cwd().statFile(s.path)) |st| {
                if (!s.present or st.mtime.nanoseconds != s.mtime_ns) return false;
            } else |_| {
                if (s.present) return false;
            }
        }
        return true;
    }

    /// Append a stamp to the set, growing the owned `page` slice. Used by
    /// callers whose page depends on inputs the evaluator never reads.
    pub fn append(self: *FileSet, stamp: FileStamp) std.mem.Allocator.Error!void {
        const stamps = try page.realloc(self.stamps, self.stamps.len + 1);
        stamps[self.stamps.len - 1] = stamp;
        self.stamps = stamps;
    }
};

/// Stat `path` and record it, duping the path into `page`. An absent file is
/// recorded with `present=false` so its later creation invalidates the entry.
fn stampOf(path: []const u8) std.mem.Allocator.Error!FileStamp {
    const owned = try page.dupe(u8, path);
    if (infra_fs.cwd().statFile(path)) |st| {
        return .{ .path = owned, .mtime_ns = st.mtime.nanoseconds, .present = true };
    } else |_| {
        return .{ .path = owned, .mtime_ns = 0, .present = false };
    }
}

/// Hash the names of the top-level entries of `path` that end in `suffix`,
/// mirroring the scan `findModelFile` performs over `lib/models/` when it
/// resolves a footprint's STEP model. Null when the directory cannot be read
/// (treated as absent — the file-stamp `present` contract).
fn dirListingFingerprint(path: []const u8, suffix: []const u8) ?i128 {
    var dir = infra_fs.cwd().openDir(path, .{ .iterate = true }) catch return null;
    defer dir.close();
    var hasher = std.hash.Wyhash.init(0);
    var count: u64 = 0;
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, suffix)) continue;
        count += 1;
        hasher.update(entry.name);
    }
    hasher.update(std.mem.asBytes(&count));
    return @intCast(hasher.final());
}

/// Stamp a directory's relevant entry listing so a later entry create/delete/
/// rename flips the stamp even though the directory's own mtime does not move
/// on entry creation (see paths.zig). An absent directory is recorded with
/// `present=false`, so its first appearance invalidates too.
fn stampDirListing(path: []const u8, suffix: []const u8) std.mem.Allocator.Error!FileStamp {
    const owned = try page.dupe(u8, path);
    if (dirListingFingerprint(path, suffix)) |fp| {
        return .{ .path = owned, .mtime_ns = fp, .present = true, .dir_listing = true, .dir_suffix = suffix };
    }
    return .{ .path = owned, .mtime_ns = 0, .present = false, .dir_listing = true, .dir_suffix = suffix };
}

/// Extend an existing dependency set with the names of the files in `path`
/// that end in `suffix`. This is for renderers whose output depends on file
/// discovery rather than file contents (for example, which datasheet PDFs are
/// available). The absent-directory case is stamped too, so creating the
/// directory later invalidates the page.
pub fn appendDirListing(files: *FileSet, path: []const u8, suffix: []const u8) std.mem.Allocator.Error!void {
    try files.append(try stampDirListing(path, suffix));
}

/// Extend an existing dependency set with both a matching directory listing
/// and every matching file's mtime. Use this when a renderer consumes the
/// contents of a discovered family of files: the listing catches add/remove/
/// rename, while the individual stamps catch edits in place.
pub fn appendDirFiles(
    files: *FileSet,
    scratch: std.mem.Allocator,
    path: []const u8,
    suffix: []const u8,
) std.mem.Allocator.Error!void {
    try appendDirListing(files, path, suffix);
    var dir = infra_fs.cwd().openDir(path, .{ .iterate = true }) catch return;
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch return) |entry| {
        if ((entry.kind != .file and entry.kind != .sym_link) or
            !std.mem.endsWith(u8, entry.name, suffix)) continue;
        const full = try std.fmt.allocPrint(scratch, "{s}/{s}", .{ path, entry.name });
        defer scratch.free(full);
        try files.append(try stampOf(full));
    }
}

/// Stamp the 3D-model inputs of a rendered PCB page: `lib/models/model-config.json`
/// (offsets/rotations/explicit model overrides) and the top-level `.step`
/// listing of `lib/models/` (which footprints resolve to a model at all). The
/// page embeds its `models` map from exactly these two sources, and the
/// evaluator never reads either — so a model upload/transform would otherwise
/// leave the page cache serving the old map forever.
pub fn appendModelStamps(files: *FileSet, scratch: std.mem.Allocator, project_dir: []const u8) std.mem.Allocator.Error!void {
    const cfg_path = try std.fmt.allocPrint(scratch, "{s}/lib/models/model-config.json", .{project_dir});
    defer scratch.free(cfg_path);
    try files.append(try stampOf(cfg_path));

    const models_path = try std.fmt.allocPrint(scratch, "{s}/lib/models", .{project_dir});
    defer scratch.free(models_path);
    try files.append(try stampDirListing(models_path, ".step"));
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
    return captureWithExtras(scratch, eval, project_dir, name, &.{});
}

/// Capture a single file as a one-element dependency set. For a cached verdict
/// that is a pure function of one file's bytes (for example "this `.sexp`
/// declares no top-level `design-block`"), so such a cache validates through
/// the same `isValid` contract as every other cached page instead of growing
/// its own stamp rule.
pub fn captureOne(path: []const u8) std.mem.Allocator.Error!FileSet {
    const stamps = try page.alloc(FileStamp, 1);
    errdefer page.free(stamps);
    stamps[0] = try stampOf(path);
    return .{ .stamps = stamps };
}

/// Capture the ordinary evaluator/page dependencies plus caller-supplied paths.
/// This is for page-specific sidecars that deliberately do not belong in the
/// shared set above (for example, a PCB page's top-level `.layouts.json`).
pub fn captureWithExtras(
    scratch: std.mem.Allocator,
    eval: *const Evaluator,
    project_dir: []const u8,
    name: []const u8,
    extra_paths: []const []const u8,
) std.mem.Allocator.Error!FileSet {
    var list: std.ArrayList(FileStamp) = .empty;
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
    for (extra_paths) |p| try list.append(page, try stampOf(p));

    return .{ .stamps = try list.toOwnedSlice(page) };
}

/// Capture one dependency set spanning SEVERAL evaluators. `name` may resolve
/// to a design (evaluated by the caller's own evaluator) or to a bare
/// `lib/modules` module, whose real read-set belongs to the resolver's separate
/// evaluator — a cache keyed on only one of the two would never notice edits to
/// the other. `extra_paths` is applied once, with the first evaluator. Null when
/// nothing was captured, which callers must treat as "not cacheable": a set that
/// stamps no file can never go stale.
///
/// Lives here rather than at the call site because the returned `FileSet` owns
/// its memory under this module's `page` allocator — merging its stamps
/// elsewhere would split that ownership across two allocators.
pub fn captureMerged(
    scratch: std.mem.Allocator,
    evals: []const *const Evaluator,
    project_dir: []const u8,
    name: []const u8,
    extra_paths: []const []const u8,
) ?FileSet {
    var merged: std.ArrayList(FileStamp) = .empty;
    for (evals, 0..) |eval, i| {
        const set = captureWithExtras(
            scratch,
            eval,
            project_dir,
            name,
            if (i == 0) extra_paths else &.{},
        ) catch continue;
        merged.appendSlice(page, set.stamps) catch {
            set.deinit();
            continue;
        };
        // The stamps (and the paths they own) moved into `merged`; free the
        // carrier slice alone — `set.deinit()` would free the paths too.
        page.free(set.stamps);
    }
    if (merged.items.len == 0) {
        merged.deinit(page);
        return null;
    }
    const owned = merged.toOwnedSlice(page) catch {
        for (merged.items) |s| page.free(s.path);
        merged.deinit(page);
        return null;
    };
    return .{ .stamps = owned };
}

// spec: Web Server - A captured page-cache read-set stamps the evaluated design's own source file, so editing it invalidates the cached result
test "capture stamps the design source itself, not a freed path" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "src", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/demo.sexp", .data = "(design-block \"Demo\")" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    // Evaluating retains source buffers + AST by design (nodes slice into the
    // source), so the evaluator gets an arena rather than `testing.allocator`.
    var eval_arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer eval_arena.deinit();
    var eval = Evaluator.init(eval_arena.allocator(), root);
    defer eval.deinit();
    {
        // Evaluate through a path the caller frees immediately afterwards —
        // exactly what `pcb_layout_page.resolveBlock` does. The read-set must
        // still name the design, not the freed slice's poisoned bytes.
        const path = try std.fmt.allocPrint(testing.allocator, "{s}/src/demo.sexp", .{root});
        defer testing.allocator.free(path);
        _ = eval.evalFile(path) catch {};
    }

    const files = try capture(testing.allocator, &eval, root, "demo");
    defer files.deinit();
    var stamped = false;
    for (files.stamps) |s| {
        if (std.mem.endsWith(u8, s.path, "src/demo.sexp")) {
            try testing.expect(s.present);
            stamped = true;
        }
    }
    try testing.expect(stamped);
    try testing.expect(files.isValid());
}

test "FileSet validity flips when a tracked file's mtime changes" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const rel = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(rel);
    const fpath = try std.fmt.allocPrint(testing.allocator, "{s}/dep.sexp", .{rel});
    defer testing.allocator.free(fpath);

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "dep.sexp", .data = "(a)" });

    var fs: FileSet = .{ .stamps = try page.alloc(FileStamp, 1) };
    defer fs.deinit();
    fs.stamps[0] = try stampOf(fpath);
    try testing.expect(fs.isValid());

    // A content rewrite bumps mtime → the set must read as stale. (Some
    // filesystems have coarse mtime resolution, so force a distinct stamp.)
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "dep.sexp", .data = "(a b c)" });
    fs.stamps[0].mtime_ns -= std.time.ns_per_s;
    try testing.expect(!fs.isValid());
}

test "absent-then-present sibling invalidates" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const rel = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(rel);
    const fpath = try std.fmt.allocPrint(testing.allocator, "{s}/late.bom", .{rel});
    defer testing.allocator.free(fpath);

    var fs: FileSet = .{ .stamps = try page.alloc(FileStamp, 1) };
    defer fs.deinit();
    fs.stamps[0] = try stampOf(fpath); // absent → present=false
    try testing.expect(!fs.stamps[0].present);
    try testing.expect(fs.isValid());

    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "late.bom", .data = "x" });
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

test "directory-listing stamp flips when a model file appears" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "lib/models");
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const models_dir = try std.fmt.allocPrint(testing.allocator, "{s}/lib/models", .{root});
    defer testing.allocator.free(models_dir);

    // Capture with an empty models dir: no .step files yet.
    var fs: FileSet = .{ .stamps = try page.alloc(FileStamp, 1) };
    defer fs.deinit();
    fs.stamps[0] = try stampDirListing(models_dir, ".step");
    try testing.expect(fs.stamps[0].present);
    try testing.expect(fs.isValid());

    // A model upload adds a .step — the set must now read stale even though
    // the directory's own mtime does not move (see paths.zig).
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/models/qfn50p290x290x90-13n-d.step", .data = "ISO-10303-21;" });
    try testing.expect(!fs.isValid());
}

test "directory-listing stamp ignores non-model files and sprite churn" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "lib/models");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/models/a.step", .data = "x" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const models_dir = try std.fmt.allocPrint(testing.allocator, "{s}/lib/models", .{root});
    defer testing.allocator.free(models_dir);

    var fs: FileSet = .{ .stamps = try page.alloc(FileStamp, 1) };
    defer fs.deinit();
    fs.stamps[0] = try stampDirListing(models_dir, ".step");
    try testing.expect(fs.isValid());

    // A non-model file (sprite-cache PNG written next to the models) must not
    // flip the stamp — the listing stamp only fingerprints `.step` names.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/models/c-0201.png", .data = "png" });
    try testing.expect(fs.isValid());
}

test "absent-then-present models directory invalidates" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const models_dir = try std.fmt.allocPrint(testing.allocator, "{s}/lib/models", .{root});
    defer testing.allocator.free(models_dir);

    // Captured before lib/models exists: present=false, still valid.
    var fs: FileSet = .{ .stamps = try page.alloc(FileStamp, 1) };
    defer fs.deinit();
    fs.stamps[0] = try stampDirListing(models_dir, ".step");
    try testing.expect(!fs.stamps[0].present);
    try testing.expect(fs.isValid());

    // The directory's first appearance must invalidate the entry.
    try tmp.dir.createDirPath(std.testing.io, "lib/models");
    try testing.expect(!fs.isValid());
}

// spec: Web Server - Stable PCB layout pages reuse dependency-validated rendered HTML and invalidate it when the design or layout sidecar changes
test "captureWithExtras invalidates when a page-specific sidecar changes" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    const sidecar = try std.fmt.allocPrint(testing.allocator, "{s}/board.layouts.json", .{root});
    defer testing.allocator.free(sidecar);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "board.layouts.json", .data = "{}" });

    var eval = Evaluator.init(testing.allocator, root);
    defer eval.deinit();
    var files = try captureWithExtras(testing.allocator, &eval, root, "board", &.{sidecar});
    defer files.deinit();
    try testing.expect(files.isValid());
    for (files.stamps) |*stamp| {
        if (std.mem.eql(u8, stamp.path, sidecar)) stamp.mtime_ns -= std.time.ns_per_s;
    }
    try testing.expect(!files.isValid());
}
