//! Resolve `<name>` design references to filesystem paths.
//!
//! `projects/designs/src/` may be flat (`src/<name>.sexp`) or grouped
//! into project subdirectories (`src/<group>/<name>.sexp`). Callers
//! pass bare basenames (`stm32n6`, `cyclops-analog`) and this module
//! walks `src/` to locate the file. Per-design artifacts (`.bom`,
//! `.layout`, `.ids`, `.kicad.json`) and the autoloaded `.checks.sexp`
//! sibling are resolved by reusing the same lookup with a different
//! extension — the artifact lives next to the source file.
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

/// Path to `<name><ext>` next to the design source file. `ext` includes
/// the leading dot (`".bom"`, `".layout"`, `".ids"`, `".kicad.json"`,
/// `".checks.sexp"`). Falls back to the flat-layout path when the file
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

    if (try findUniqueInSrc(allocator, project_dir, filename)) |found| return found;

    // A `lib/modules/<name>.sexp` defmodule is editable too (the schematic
    // viewer's "Edit src" works on module pages). When no design source exists
    // under `src/` but a module of that name does, resolve the sibling next to
    // the module file so reads, snapshots, and saves all target it.
    const mod_sexp = try std.fmt.allocPrint(allocator, "{s}/lib/modules/{s}.sexp", .{ project_dir, name });
    defer allocator.free(mod_sexp);
    if (infra_fs.cwd().access(mod_sexp, .{})) |_| {
        return std.fmt.allocPrint(allocator, "{s}/lib/modules/{s}{s}", .{ project_dir, name, ext });
    } else |_| {}

    return std.fmt.allocPrint(allocator, "{s}/src/{s}", .{ project_dir, filename });
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
    if (!srcIndexIsFresh(src_path)) rebuildSrcIndex(src_path);
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

/// Force the next lookup to revalidate, as a new request would.
fn bustSrcIndexStamps() void {
    beginRequest();
}
