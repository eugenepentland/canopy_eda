//! Resolve `<name>` design references to filesystem paths.
//!
//! `projects/designs/src/` may be flat (`src/<name>.sexp`) or grouped
//! into project subdirectories (`src/<group>/<name>.sexp`). Callers
//! pass bare basenames (`stm32n6`, `cyclops-analog`) and this module
//! walks `src/` to locate the file. Per-design artifacts (`.bom`,
//! `.layout`, `.ids`, `.kicad.json`) and the autoloaded sidecars
//! (`.checks.sexp`, `.layout.sexp`, `.diagram.sexp` — see
//! `eval/sidecars.zig`) are resolved by reusing the same lookup with a
//! different extension — the artifact lives next to the source file.
//!
//! Behaviour:
//!  - If a unique file with the requested basename exists, its path is
//!    returned (the caller frees the slice with the same allocator).
//!  - If no file matches, the helper falls back to the flat-layout
//!    path `<project_dir>/src/<name><ext>` so this module can also be
//!    used to construct paths for files about to be written.
//!  - If two distinct files share the basename, an error is logged via
//!    `std.log.err` and the first match is returned. Basenames are
//!    expected to be unique under `src/`; the log line is the failure
//!    signal rather than a propagated error so this helper composes
//!    cleanly with every existing error union (which all already cover
//!    `Allocator.Error`).
//!
//! The lookup is served from a cached `src/` basename index rather than a
//! walk per call. The walk-per-call this replaced was measured at ~31 ms of a
//! 42 ms warm `GET /`: the home page resolves one `.layouts.json` sibling per
//! card, and 106 cards each re-walked the same 347-entry tree.
//!
//! Freshness is per REQUEST, not per call. `beginRequest` bumps an epoch from
//! the server's dispatcher; the first lookup of a new epoch re-walks `src/`
//! and compares a no-stat fingerprint (entry count plus a hash of every
//! relative path, which together move on any create, delete or rename), and
//! the rest of that request are served straight from the index. So a request
//! pays at most one walk however many siblings it resolves, and treats the
//! tree as fixed for its own duration — a snapshot, which is what a request
//! wants anyway. A process that never bumps the epoch (the CLI) validates
//! exactly once, matching its one-shot lifetime.
//!
//! That revalidation is invisible to an active release read trace, because WHEN
//! it happens is decided by other requests rather than by the analysis asking
//! (see `ensureSrcIndex`). The index reads no file bytes; the bytes a release
//! consumes still reach the trace through the ordinary read path.
//!
//! Directory mtimes are deliberately NOT the signal, though the kernel does
//! move them: `std.Io.Dir.statFile` on a directory here reports an mtime that
//! does not change when an entry is created inside it, so an index gated on it
//! would freeze permanently. The fingerprint walk is measured instead.
//!
//! Name contract (enforced): `name` is a bare design basename — no path
//! separators (`/`, `\`), no parent-traversal `..`, and no leading `.`
//! (dot-files / relative-current). These helpers are the shared chokepoint
//! reached from server request paths keyed on a URL `:name`, so the
//! sanitization lives here rather than at each call site: a name that would
//! escape `src/` (or resolve a hidden sibling) is rejected with
//! `error.InvalidName` before it can be spliced into a filesystem path.
//! Callers propagate the error; a rejected name never touches disk.

const std = @import("std");
const infra_fs = @import("infra/fs.zig");
const log = @import("infra/log.zig");

/// Error set for the path resolvers: allocation failures plus the
/// design-name contract violation. See the module doc for the contract.
pub const PathError = std.mem.Allocator.Error || error{InvalidName};

/// Release-only source lookup additionally refuses a basename collision. The
/// ordinary editor retains its historical warn-and-first behavior, while a
/// revision lock never certifies a nondeterministically selected source.
pub const UniquePathError = PathError || error{AmbiguousName};

/// Reject any `name` that is not a bare basename — a path separator, a
/// parent-traversal `..`, or a leading `.` would let a URL-supplied name
/// escape `src/` (traversal) or address a hidden sibling. This is the
/// defense-in-depth chokepoint the module doc describes.
fn validateName(name: []const u8) error{InvalidName}!void {
    if (name.len == 0) return error.InvalidName;
    if (name[0] == '.') return error.InvalidName;
    for (name) |c| {
        if (c == '/' or c == '\\') return error.InvalidName;
    }
    if (std.mem.indexOf(u8, name, "..") != null) return error.InvalidName;
}

/// Path to `<name>.sexp` under `<project_dir>/src/`. See module docs.
pub fn designSourcePath(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
) PathError![]u8 {
    return designSiblingPath(allocator, project_dir, name, ".sexp");
}

fn moduleSourcePath(allocator: std.mem.Allocator, project_dir: []const u8, name: []const u8) std.mem.Allocator.Error!?[]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/lib/modules/{s}.sexp", .{ project_dir, name });
    if (infra_fs.cwd().access(path, .{})) |_| return path else |_| {
        allocator.free(path);
        return null;
    }
}

fn siblingOfSource(allocator: std.mem.Allocator, source: []const u8, name: []const u8, ext: []const u8) std.mem.Allocator.Error![]u8 {
    const parent = std.fs.path.dirname(source) orelse ".";
    return std.fmt.allocPrint(allocator, "{s}/{s}{s}", .{ parent, name, ext });
}

/// Resolve one unambiguous source for a manufacturing release. Every sidecar
/// is then derived beside this path; callers must not perform another basename
/// search for a different extension.
pub fn designSourcePathUnique(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
) UniquePathError![]u8 {
    try validateName(name);
    const filename = try std.fmt.allocPrint(allocator, "{s}.sexp", .{name});
    defer allocator.free(filename);
    if (try findStrictlyUniqueInSrc(allocator, project_dir, filename)) |found| return found;
    if (try moduleSourcePath(allocator, project_dir, name)) |module| return module;
    return std.fmt.allocPrint(allocator, "{s}/src/{s}", .{ project_dir, filename });
}

/// Path to `<name><ext>` next to the design source file. `ext` includes
/// the leading dot (`".bom"`, `".layout"`, `".ids"`, `".kicad.json"`,
/// `".checks.sexp"`, `".layout.sexp"`, `".diagram.sexp"`). Falls back to the flat-layout path when the file
/// is not yet present (e.g. first-time write). Rejects a `name` that
/// violates the bare-basename contract (see module docs) with
/// `error.InvalidName`.
pub fn designSiblingPath(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    ext: []const u8,
) PathError![]u8 {
    try validateName(name);

    const filename = try std.fmt.allocPrint(allocator, "{s}{s}", .{ name, ext });
    defer allocator.free(filename);

    if (std.mem.eql(u8, ext, ".sexp")) {
        if (try findUniqueInSrc(allocator, project_dir, filename)) |found| return found;
    } else {
        const source_filename = try std.fmt.allocPrint(allocator, "{s}.sexp", .{name});
        defer allocator.free(source_filename);
        if (try findUniqueInSrc(allocator, project_dir, source_filename)) |source| {
            defer allocator.free(source);
            return siblingOfSource(allocator, source, name, ext);
        }
    }

    // A `lib/modules/<name>.sexp` defmodule is editable too (the schematic
    // viewer's "Edit src" works on module pages). When no design source exists
    // under `src/` but a module of that name does, resolve the sibling next to
    // the module file so reads, snapshots, and saves all target it.
    if (try moduleSourcePath(allocator, project_dir, name)) |module| {
        defer allocator.free(module);
        return siblingOfSource(allocator, module, name, ext);
    }

    // Preserve construction/read compatibility for an orphan artifact when no
    // design or module source exists at all. A resolved release never reaches
    // this branch because it requires the uniquely selected source above.
    if (!std.mem.eql(u8, ext, ".sexp")) {
        if (try findUniqueInSrc(allocator, project_dir, filename)) |found| return found;
    }

    return std.fmt.allocPrint(allocator, "{s}/src/{s}", .{ project_dir, filename });
}

fn findStrictlyUniqueInSrc(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    filename: []const u8,
) (std.mem.Allocator.Error || error{AmbiguousName})!?[]u8 {
    const src_path = try std.fmt.allocPrint(allocator, "{s}/src", .{project_dir});
    defer allocator.free(src_path);

    SrcIndex.mutex.lock();
    defer SrcIndex.mutex.unlock();
    ensureSrcIndex(src_path);
    const hit = SrcIndex.files.get(filename) orelse return null;
    if (hit.shadowed != null) return error.AmbiguousName;
    return try allocator.dupe(u8, hit.path);
}

/// Walk `<project_dir>/src/` and return the path whose basename equals
/// `filename`. On collision, log both paths and return the first match.
fn findUniqueInSrc(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    filename: []const u8,
) std.mem.Allocator.Error!?[]u8 {
    const src_path = try std.fmt.allocPrint(allocator, "{s}/src", .{project_dir});
    defer allocator.free(src_path);

    SrcIndex.mutex.lock();
    defer SrcIndex.mutex.unlock();
    ensureSrcIndex(src_path);
    const hit = SrcIndex.files.get(filename) orelse return null;
    // Reported per LOOKUP, not per index rebuild: `src/` legitimately holds
    // colliding basenames the caller never asks about (a handoff export tree
    // repeats its README and plots per variant), and warning for those on
    // every rebuild would bury the one collision that actually shadowed a
    // resolution.
    if (hit.shadowed) |other| {
        log.warn("paths: ambiguous design basename {s}: keeping {s}, also found {s}", .{ filename, hit.path, other });
    }
    return try allocator.dupe(u8, hit.path);
}

// ── src/ basename index ────────────────────────────────────────────────
//
// Retained for the process, revalidated at most once per request. See the
// module doc for the freshness contract. Everything here runs under
// `SrcIndex.mutex`.

/// One indexed file: the path that wins, plus the first path it shadowed (null
/// when the basename is unique). First match in walk order wins, matching the
/// pre-index behaviour on an ambiguous basename.
const IndexedFile = struct {
    path: []const u8,
    shadowed: ?[]const u8 = null,
};

/// What `src/` looked like, cheaply. Counting entries catches a create or a
/// delete; hashing every relative path catches a rename, which leaves the
/// count alone. Neither needs a `stat`, so a fingerprint walk costs one
/// directory sweep and nothing else.
const SrcFingerprint = struct {
    count: usize = 0,
    hash: u64 = 0,

    fn eql(a: SrcFingerprint, b: SrcFingerprint) bool {
        return a.count == b.count and a.hash == b.hash;
    }
};

/// The index's state. Scoped inside this non-pub struct rather than left as
/// module-level `var`s because `findUniqueInSrc` is reached from plain path
/// helpers with no server handle to thread a store through — the same reason
/// `layout_status.Memo` is shaped this way.
const SrcIndex = struct {
    // The index outlives every request arena that queries it, and has the
    // process's own lifetime.
    // allocator-ok: process-lifetime index, deliberately not request-scoped.
    const store = std.heap.page_allocator;

    var mutex: infra_fs.Mutex = .{};
    /// The `<project_dir>/src` this index describes. Empty means "no index
    /// yet"; a different root (a second project, or a test's tmp tree)
    /// rebuilds.
    var root: []const u8 = "";
    var print: SrcFingerprint = .{};
    /// The epoch this index was last validated against, so repeated lookups
    /// within one request skip the walk.
    var checked_epoch: u64 = 0;
    /// basename → the file that resolves it.
    var files: std.StringHashMapUnmanaged(IndexedFile) = .empty;

    /// Bumped once per request. Starts at 1 so a never-bumped process (the
    /// CLI) still differs from a fresh `checked_epoch` of 0 exactly once.
    var epoch: std.atomic.Value(u64) = .init(1);
};

/// Mark the start of a request, so the next `src/` lookup revalidates the
/// index once and the rest of the request reuses it. Called by the server's
/// dispatcher; a caller that never calls it (the CLI) simply validates once.
pub fn beginRequest() void {
    _ = SrcIndex.epoch.fetchAdd(1, .monotonic);
}

/// Revalidate the index for `src_path`, rebuilding it when the tree moved.
/// Caller holds `SrcIndex.mutex`.
///
/// The walk runs OUTSIDE any active read trace. WHEN this cache revalidates is
/// decided by the request epoch, which every other request bumps — so a release
/// analysis that resolves a sibling while some unrelated poll happens to have
/// invalidated the index would otherwise record a `src/` probe that the same
/// analysis over the same bytes does not record a second later. That made the
/// consumed-input closure a function of concurrent server traffic, and the
/// `fab_before`/`fab` tamper guard trip on an unchanged tree. Nothing is lost
/// by hiding it: the index reads no file bytes, and every byte the release
/// actually consumes still reaches the trace through the ordinary read path.
fn ensureSrcIndex(src_path: []const u8) void {
    var probe = infra_fs.beginCacheProbe();
    defer probe.end();
    if (!srcIndexIsFresh(src_path)) rebuildSrcIndex(src_path);
}

/// True while the cached index can be trusted for this request: same root, and
/// either already validated under this epoch or still matching a freshly
/// measured fingerprint of `src/`.
fn srcIndexIsFresh(src_path: []const u8) bool {
    if (SrcIndex.root.len == 0) return false;
    if (!std.mem.eql(u8, SrcIndex.root, src_path)) return false;

    const now = SrcIndex.epoch.load(.monotonic);
    if (SrcIndex.checked_epoch == now) return true;
    SrcIndex.checked_epoch = now;

    const measured = srcFingerprint(src_path) orelse return false;
    return measured.eql(SrcIndex.print);
}

/// Walk `src_path` counting entries and hashing their relative paths. No
/// `stat`, no allocation beyond the walker's own path buffer. Null when the
/// tree cannot be read, which forces a rebuild rather than a stale hit.
fn srcFingerprint(src_path: []const u8) ?SrcFingerprint {
    var dir = infra_fs.cwd().openDir(src_path, .{ .iterate = true }) catch return null;
    defer dir.close();
    var walker = dir.walk(SrcIndex.store) catch return null;
    defer walker.deinit();

    var out: SrcFingerprint = .{};
    var hasher = std.hash.Wyhash.init(0);
    while (walker.next() catch null) |entry| {
        out.count += 1;
        hasher.update(entry.path);
    }
    out.hash = hasher.final();
    return out;
}

/// Walk `src_path` and replace the index with what is there now. Any failure
/// leaves the index empty and un-rooted, which is fail-CLOSED: an un-rooted
/// index is never fresh, so every lookup rebuilds (a walk per call — exactly
/// the pre-index behaviour) instead of serving a half-built map.
fn rebuildSrcIndex(src_path: []const u8) void {
    buildSrcIndex(src_path) catch freeSrcIndex();
}

fn buildSrcIndex(src_path: []const u8) !void {
    freeSrcIndex();

    var dir = infra_fs.cwd().openDir(src_path, .{ .iterate = true }) catch return;
    defer dir.close();

    var walker = try dir.walk(SrcIndex.store);
    defer walker.deinit();

    var print: SrcFingerprint = .{};
    var hasher = std.hash.Wyhash.init(0);
    while (walker.next() catch null) |entry| {
        print.count += 1;
        hasher.update(entry.path);
        switch (entry.kind) {
            .file, .sym_link => try indexFile(src_path, entry.path, entry.basename),
            else => {},
        }
    }
    print.hash = hasher.final();

    SrcIndex.print = print;
    SrcIndex.root = try SrcIndex.store.dupe(u8, src_path);
}

/// Record one file under its basename, keeping the first match in walk order
/// and remembering the first path it shadowed for the lookup-time warning.
fn indexFile(src_path: []const u8, rel: []const u8, basename: []const u8) std.mem.Allocator.Error!void {
    const full = try std.fmt.allocPrint(SrcIndex.store, "{s}/{s}", .{ src_path, rel });
    errdefer SrcIndex.store.free(full);
    const gop = try SrcIndex.files.getOrPut(SrcIndex.store, basename);
    if (gop.found_existing) {
        if (gop.value_ptr.shadowed == null) {
            gop.value_ptr.shadowed = full;
        } else {
            SrcIndex.store.free(full);
        }
        return;
    }
    gop.key_ptr.* = try SrcIndex.store.dupe(u8, basename);
    gop.value_ptr.* = .{ .path = full };
}

/// Drop every string the index owns and reset it to "no index yet".
fn freeSrcIndex() void {
    var it = SrcIndex.files.iterator();
    while (it.next()) |e| {
        SrcIndex.store.free(e.key_ptr.*);
        SrcIndex.store.free(e.value_ptr.path);
        if (e.value_ptr.shadowed) |sh| SrcIndex.store.free(sh);
    }
    SrcIndex.files.deinit(SrcIndex.store);
    SrcIndex.files = .empty;
    if (SrcIndex.root.len > 0) SrcIndex.store.free(SrcIndex.root);
    SrcIndex.root = "";
    SrcIndex.print = .{};
}

// spec: paths - Resolves <name>.sexp via designSourcePath, falling back to flat layout when missing
test "designSourcePath flat fallback" {
    const allocator = std.testing.allocator;
    const path = try designSourcePath(allocator, "/tmp/no-such-project", "stm32n6");
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/no-such-project/src/stm32n6.sexp", path);
}

// spec: paths - Resolves sibling artifacts via designSiblingPath using the supplied extension
test "designSiblingPath flat fallback" {
    const allocator = std.testing.allocator;
    const path = try designSiblingPath(allocator, "/tmp/no-such-project", "stm32n6", ".bom");
    defer allocator.free(path);
    try std.testing.expectEqualStrings("/tmp/no-such-project/src/stm32n6.bom", path);
}

// spec: paths - Rejects design names that are not bare basenames (traversal defense)
test "designSiblingPath rejects non-basename names" {
    const allocator = std.testing.allocator;
    // Path separators, parent traversal, and leading dots are all refused
    // before any filesystem path is constructed.
    try std.testing.expectError(error.InvalidName, designSiblingPath(allocator, "/p", "../secret", ".bom"));
    try std.testing.expectError(error.InvalidName, designSiblingPath(allocator, "/p", "a/b", ".bom"));
    try std.testing.expectError(error.InvalidName, designSiblingPath(allocator, "/p", "a\\b", ".bom"));
    try std.testing.expectError(error.InvalidName, designSiblingPath(allocator, "/p", ".hidden", ".bom"));
    try std.testing.expectError(error.InvalidName, designSiblingPath(allocator, "/p", "", ".bom"));
    try std.testing.expectError(error.InvalidName, designSourcePath(allocator, "/p", "../../etc/passwd"));
    // A legitimate bare basename still resolves.
    const ok = try designSourcePath(allocator, "/tmp/no-such-project", "stm32n6");
    defer allocator.free(ok);
    try std.testing.expectEqualStrings("/tmp/no-such-project/src/stm32n6.sexp", ok);
}

// spec: Web Server - The src basename index resolves a design sibling without re-walking the tree, and rebuilds when a directory it walked changes mtime
test "src index resolves siblings and rebuilds when the tree's shape changes" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "src", .default_dir);
    try tmp.dir.createDir(std.testing.io, "src/boards", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/boards/alpha.sexp", .data = "(design-block \"A\")" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/boards/alpha.layouts.json", .data = "{}" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    // An existing sibling resolves to its real nested location, not to the
    // flat fallback.
    const first = try designSiblingPath(testing.allocator, root, "alpha", ".layouts.json");
    defer testing.allocator.free(first);
    try testing.expect(std.mem.endsWith(u8, first, "src/boards/alpha.layouts.json"));

    // Repeating the lookup is served from the index and must not change the
    // answer — this is the path that used to re-walk `src/` on every call.
    const again = try designSiblingPath(testing.allocator, root, "alpha", ".layouts.json");
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(first, again);

    // A sibling that does not exist yet still falls back to the flat path, so
    // the helper can name a file about to be written.
    const pending = try designSiblingPath(testing.allocator, root, "beta", ".bom");
    defer testing.allocator.free(pending);
    try testing.expect(std.mem.endsWith(u8, pending, "src/beta.bom"));

    // Creating that file changes its directory's mtime, which is the whole
    // invalidation contract: the next lookup must find it rather than keep
    // serving the flat fallback out of a stale index.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/boards/beta.bom", .data = "x" });
    bustSrcIndexStamps();
    const found = try designSiblingPath(testing.allocator, root, "beta", ".bom");
    defer testing.allocator.free(found);
    try testing.expect(std.mem.endsWith(u8, found, "src/boards/beta.bom"));
}

// spec: paths - A release source lookup rejects duplicate design basenames instead of selecting the first directory walk result
test "release source lookup rejects duplicate basenames" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "src/a");
    try tmp.dir.createDirPath(std.testing.io, "src/b");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/a/twin.sexp", .data = "(design-block \"A\")" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/b/twin.sexp", .data = "(design-block \"B\")" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    bustSrcIndexStamps();
    try testing.expectError(error.AmbiguousName, designSourcePathUnique(testing.allocator, root, "twin"));
}

// spec: paths - Module release sidecars resolve beside the selected module source even when an orphan artifact with the same basename exists under src
test "module sidecars cannot cross-pair with orphan src artifacts" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "src/orphan");
    try tmp.dir.createDirPath(std.testing.io, "lib/modules");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/modules/radio.sexp", .data = "(defmodule radio () (design-block \"Radio\"))" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/orphan/radio.layouts.json", .data = "{}" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);
    bustSrcIndexStamps();
    const sidecar = try designSiblingPath(testing.allocator, root, "radio", ".layouts.json");
    defer testing.allocator.free(sidecar);
    try testing.expect(std.mem.endsWith(u8, sidecar, "lib/modules/radio.layouts.json"));
}

/// Force the next lookup to revalidate, as a new request would.
fn bustSrcIndexStamps() void {
    beginRequest();
}

/// Resolve one design inside a read trace and return that trace's closure
/// digest. `interleaved_request` stands in for an unrelated request landing
/// mid-analysis: it bumps the epoch, so the lookup below is the one that pays
/// the index revalidation.
fn tracedLookupDigest(
    allocator: std.mem.Allocator,
    root: []const u8,
    interleaved_request: bool,
) ![64]u8 {
    var trace = infra_fs.ReadTrace.init(allocator);
    defer trace.deinit();
    trace.begin();
    if (interleaved_request) beginRequest();
    const path = try designSourcePath(allocator, root, "drift");
    defer allocator.free(path);
    // One genuine consumed input, so the comparison is about what ELSE the
    // lookup recorded rather than about two empty traces agreeing.
    const bytes = try infra_fs.cwd().readFileAlloc(allocator, path, 64);
    defer allocator.free(bytes);
    trace.end();
    try std.testing.expect(trace.consistent);
    return trace.digest();
}

// spec: paths - A src index revalidation triggered by another request leaves a traced lookup's consumed-input closure unchanged
test "another request's index revalidation stays out of a traced lookup" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "src/boards");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/boards/drift.sexp", .data = "(design-block \"D\")" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    // Warm the index the way the work preceding a traced analysis does. Twice:
    // the first lookup re-roots the process index onto this tree, the second
    // marks it validated for the current epoch — which is exactly the state a
    // release analysis starts from after its own pre-trace path lookups.
    bustSrcIndexStamps();
    for (0..2) |_| {
        const warm = try designSourcePath(testing.allocator, root, "drift");
        testing.allocator.free(warm);
    }

    const quiet = try tracedLookupDigest(testing.allocator, root, false);
    const busy = try tracedLookupDigest(testing.allocator, root, true);
    try testing.expectEqual(quiet, busy);
}
