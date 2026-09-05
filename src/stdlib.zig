//! The bundled standard library, and the one place library sub-paths are
//! resolved.
//!
//! A netlisp project keeps its parts under `<project>/lib/` — `components/`,
//! `footprints/`, `pinouts/`, `modules/`, `parts/`. A brand-new project has
//! none of that, and every passive the evaluator auto-imports (`cap-0402`,
//! `res-0402`, …) would be an `UnboundVariable` at first use. So the
//! repository's `stdlib/` is compiled INTO the binary by `build.zig` (the
//! `stdlib_embed` module) and consulted after the project's own files.
//!
//! Resolution order, for every library sub-path:
//!
//!   1. `<project_dir>/lib/<sub>/<name>.sexp`   — the project always wins
//!   2. `<lib_root>/lib/<sub>/<name>.sexp`      — `--lib-dir` / `NETLISP_LIB_DIR`
//!   3. `<stdlib_root>/<sub>/<name>.sexp`       — `NETLISP_STDLIB_DIR`
//!   4. the embedded table                       — what this binary shipped with
//!
//! Steps 2 and 3 are process-wide because the ~40 readers of `lib/` files all
//! take a `project_dir` and nothing else; threading two more directories
//! through every one of them would be a wide change for a value that is set
//! once at startup and never varies per call. `main.zig` calls `setRoots`
//! before dispatching a command; nothing else writes them.
//!
//! Bytes served from the bundle carry a synthetic path under
//! `bundled_prefix` rather than a real filename, because there IS no file —
//! `isBundledPath` recognizes it and `readPath` serves it, so a caller that
//! records a read-set (page-cache stamps, the fab gate's consumed-input
//! closure, the design archive) can still read back what it depended on. A
//! bundled file is immutable for the life of the binary, which is the one
//! property those callers actually need.

const std = @import("std");
const embed = @import("stdlib_embed");
const infra_fs = @import("infra/fs.zig");

/// The scheme that marks a synthetic path as this module's rather than the
/// filesystem's. Deliberately free of `<`, `>` and `..`: these paths travel
/// into diagnostics, HTML, JSON and zip entries, and one must never be
/// mistaken for something on disk or escape a directory.
const bundled_scheme = "netlisp:";

/// Prefix of the synthetic path reported for a file served from the embedded
/// table — e.g. `netlisp:stdlib/lib/components/cap-0402.sexp`.
pub const bundled_prefix = bundled_scheme ++ "stdlib/";

/// One resolved library file. `path` is the real filename for a disk hit and a
/// `bundled_prefix` path for a bundled one; both `path` and `bytes` are owned
/// by the caller's allocator.
pub const Found = struct {
    path: []u8,
    bytes: []u8,
    bundled: bool,
};

// ── Process-wide roots ────────────────────────────────────────────────
//
// Set once from `main.zig` (CLI flag, then environment) and read everywhere.
// Both default to null, so a unit test — and any embedder that never calls
// `setRoots` — sees exactly the project directory plus the embedded table.

/// The two override roots, scoped inside a non-pub container rather than left
/// as module-level `var`s for the same reason `paths.SrcIndex` is: the readers
/// that consult them are plain helpers with no handle to thread a store
/// through. Empty means unset.
const Roots = struct {
    var lib: []const u8 = "";
    var stdlib: []const u8 = "";
};

/// Install the two override roots. `lib` is a project-shaped directory (it
/// contains `lib/`), `stdlib` is a `stdlib/`-shaped one (it contains
/// `components/`, `footprints/`, …). Both slices must outlive the process;
/// `main.zig` allocates them for the run. Null or empty clears an override.
pub fn setRoots(lib: ?[]const u8, stdlib: ?[]const u8) void {
    Roots.lib = lib orelse "";
    Roots.stdlib = stdlib orelse "";
}

/// The `--lib-dir` / `NETLISP_LIB_DIR` root, or null when none is installed.
/// The import resolver walks its own roots, so it asks for this one directly.
pub fn libRoot() ?[]const u8 {
    return if (Roots.lib.len > 0) Roots.lib else null;
}

// ── Resolution ────────────────────────────────────────────────────────

/// Resolve `sub_path` (project-relative, e.g. `"lib/footprints/c-0402.sexp"`)
/// through the full order in the module header. Null when no root and not the
/// bundle carries it.
pub fn open(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    sub_path: []const u8,
    max_bytes: usize,
) ?Found {
    if (openUnder(allocator, project_dir, sub_path, max_bytes)) |found| return found;
    if (libRoot()) |root| {
        if (!std.mem.eql(u8, root, project_dir)) {
            if (openUnder(allocator, root, sub_path, max_bytes)) |found| return found;
        }
    }
    return standard(allocator, sub_path, max_bytes);
}

/// The bytes `open` would return, discarding the path. The common case: a
/// reader that only wants the file's contents.
pub fn read(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    sub_path: []const u8,
    max_bytes: usize,
) ?[]u8 {
    const found = open(allocator, project_dir, sub_path, max_bytes) orelse return null;
    allocator.free(found.path);
    return found.bytes;
}

/// The path `sub_path` resolves to WITHOUT reading it: a real filename when a
/// root carries it, the synthetic bundled path when only the bundle does, null
/// when nothing does. For the readers that are structured around a path —
/// their diagnostics, caches and read-sets all key on it — which then read it
/// back through `readPath`. Caller owns the slice.
pub fn resolvePath(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    sub_path: []const u8,
) ?[]u8 {
    if (pathUnder(allocator, project_dir, sub_path)) |path| return path;
    if (libRoot()) |root| {
        if (!std.mem.eql(u8, root, project_dir)) {
            if (pathUnder(allocator, root, sub_path)) |path| return path;
        }
    }
    if (Roots.stdlib.len > 0) {
        if (pathUnder(allocator, Roots.stdlib, stripLibPrefix(sub_path))) |path| return path;
    }
    if (bundled(sub_path) == null) return null;
    return bundledPath(allocator, sub_path) catch null;
}

/// True when `sub_path` resolves anywhere — including the bundle. Used where
/// the old code called `access()` to test for a library file's existence.
pub fn exists(allocator: std.mem.Allocator, project_dir: []const u8, sub_path: []const u8) bool {
    const path = resolvePath(allocator, project_dir, sub_path) orelse return false;
    allocator.free(path);
    return true;
}

/// Resolve `sub_path` from the standard library ALONE — the
/// `NETLISP_STDLIB_DIR` override if one is set, else the embedded table. This
/// is the tail of `open`, exposed separately for the import resolver, which
/// walks its own roots first so it can keep per-root diagnostics.
pub fn standard(allocator: std.mem.Allocator, sub_path: []const u8, max_bytes: usize) ?Found {
    if (Roots.stdlib.len > 0) {
        const rel = stripLibPrefix(sub_path);
        const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ Roots.stdlib, rel }) catch return null;
        if (infra_fs.cwd().readFileAlloc(allocator, path, max_bytes)) |bytes| {
            return .{ .path = path, .bytes = bytes, .bundled = false };
        } else |_| allocator.free(path);
    }
    const bytes = bundled(sub_path) orelse return null;
    if (bytes.len > max_bytes) return null;
    const path = bundledPath(allocator, sub_path) catch return null;
    const copy = allocator.dupe(u8, bytes) catch {
        allocator.free(path);
        return null;
    };
    return .{ .path = path, .bytes = copy, .bundled = true };
}

/// The embedded table's bytes for `sub_path`, or null. Static storage — never
/// freed, and never mutated.
pub fn bundled(sub_path: []const u8) ?[]const u8 {
    for (embed.entries) |entry| {
        if (std.mem.eql(u8, entry.path, sub_path)) return entry.bytes;
    }
    return null;
}

/// The synthetic path reported for a bundled `sub_path`. Caller owns it.
pub fn bundledPath(allocator: std.mem.Allocator, sub_path: []const u8) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ bundled_prefix, sub_path });
}

/// True for a path this module reported for a bundled file.
pub fn isBundledPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, bundled_prefix);
}

/// How a path should read to a person or inside an archive: a bundled one
/// loses only the scheme, so it shows as `stdlib/lib/footprints/c-0402.sexp`
/// and cannot collide with a project file of the same name. Anything else is
/// returned unchanged. A view, not a copy.
pub fn displayPath(path: []const u8) []const u8 {
    return if (isBundledPath(path)) path[bundled_scheme.len..] else path;
}

/// Read back a path this module previously reported — a real filename through
/// the filesystem, a bundled one out of the table. For the callers that keep a
/// read-set of resolved paths and later re-read it (page-cache stamps, the fab
/// gate's read-set digest, the design archive's source bundle).
pub fn readPath(allocator: std.mem.Allocator, path: []const u8, max_bytes: usize) ?[]u8 {
    if (isBundledPath(path)) {
        const bytes = bundled(path[bundled_prefix.len..]) orelse return null;
        if (bytes.len > max_bytes) return null;
        return allocator.dupe(u8, bytes) catch null;
    }
    return infra_fs.cwd().readFileAlloc(allocator, path, max_bytes) catch null;
}

// ── Listing ───────────────────────────────────────────────────────────

/// Walks the basenames (no `.sexp`) the bundle carries under one `lib/`
/// sub-directory, in the table's sorted order. `netlisp library`, `describe`
/// and the server's library page merge these with what the project's own
/// directory holds, so a bundled part is discoverable rather than only
/// resolvable.
pub const StemIterator = struct {
    prefix: []const u8,
    index: usize = 0,

    pub fn next(self: *StemIterator) ?[]const u8 {
        while (self.index < embed.entries.len) {
            const entry = embed.entries[self.index];
            self.index += 1;
            if (!std.mem.startsWith(u8, entry.path, self.prefix)) continue;
            const rest = entry.path[self.prefix.len..];
            // Only direct children: the bundle is flat today, and a nested
            // file would otherwise list under a name containing a separator.
            if (std.mem.indexOfScalar(u8, rest, '/') != null) continue;
            if (!std.mem.endsWith(u8, rest, ".sexp")) continue;
            return rest[0 .. rest.len - ".sexp".len];
        }
        return null;
    }
};

/// The directories a LISTING should enumerate for `lib/<sub>/`, in priority
/// order: the project's own, the shared `--lib-dir` root, and a
/// `NETLISP_STDLIB_DIR` override. The embedded table is not a directory —
/// walk `stemsIn` for that, after these. Appended to `out`, each path owned by
/// `allocator`.
pub fn listDirs(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    sub: []const u8,
    out: *std.ArrayList([]const u8),
) std.mem.Allocator.Error!void {
    try out.append(allocator, try std.fmt.allocPrint(allocator, "{s}/lib/{s}", .{ project_dir, sub }));
    if (libRoot()) |root| {
        if (!std.mem.eql(u8, root, project_dir)) {
            try out.append(allocator, try std.fmt.allocPrint(allocator, "{s}/lib/{s}", .{ root, sub }));
        }
    }
    if (Roots.stdlib.len > 0) {
        try out.append(allocator, try std.fmt.allocPrint(allocator, "{s}/{s}", .{ Roots.stdlib, sub }));
    }
}

/// Bundled basenames under a directory prefix written out in full, e.g.
/// `stems("lib/footprints/")`. Allocation-free, so a caller on a request arena
/// pays nothing; a caller holding only the bare sub-directory name at runtime
/// uses `stemsIn` instead.
pub fn stems(prefix: []const u8) StemIterator {
    return .{ .prefix = prefix };
}

/// `stems` for a caller that has the bare sub-directory name (`"components"`,
/// `"footprints"`, `"pinouts"`, `"modules"`, `"parts"`) at runtime. The
/// returned iterator borrows `buf`, which must outlive it; size it
/// `max_stems_prefix`.
pub fn stemsIn(buf: []u8, sub: []const u8) StemIterator {
    // A sub-directory name too long for the buffer can name nothing in the
    // table, so match an impossible prefix rather than report an error every
    // listing call site would have to thread through.
    const prefix = std.fmt.bufPrint(buf, "lib/{s}/", .{sub}) catch return .{ .prefix = "\x00" };
    return .{ .prefix = prefix };
}

/// Buffer size `stemsIn` needs: `"lib/" ++ sub ++ "/"` for any sub-directory
/// name a library could plausibly carry.
pub const max_stems_prefix = "lib/".len + 32 + "/".len;

// ── Internals ─────────────────────────────────────────────────────────

fn openUnder(
    allocator: std.mem.Allocator,
    root: []const u8,
    sub_path: []const u8,
    max_bytes: usize,
) ?Found {
    const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, sub_path }) catch return null;
    const bytes = infra_fs.cwd().readFileAlloc(allocator, path, max_bytes) catch {
        allocator.free(path);
        return null;
    };
    return .{ .path = path, .bytes = bytes, .bundled = false };
}

/// `<root>/<sub_path>` when that file exists, else null (freeing the path it
/// built). The existence probe, as opposed to `openUnder`'s read.
fn pathUnder(allocator: std.mem.Allocator, root: []const u8, sub_path: []const u8) ?[]u8 {
    const path = std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, sub_path }) catch return null;
    infra_fs.cwd().access(path, .{}) catch {
        allocator.free(path);
        return null;
    };
    return path;
}

/// `"lib/components/x.sexp"` → `"components/x.sexp"`. A `NETLISP_STDLIB_DIR`
/// is laid out like the repository's `stdlib/`, which has no `lib/` level.
fn stripLibPrefix(sub_path: []const u8) []const u8 {
    if (std.mem.startsWith(u8, sub_path, "lib/")) return sub_path["lib/".len..];
    return sub_path;
}

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: stdlib - Every passive family the evaluator auto-imports is carried by the bundled standard library
test "the bundle carries the whole passives prelude" {
    const prelude = [_][]const u8{
        "cap-0201", "cap-0402", "cap-0603",     "cap-0805",
        "res-0201", "res-0402", "res-0603",     "res-0805",
        "ind-0201", "ind-0402", "ind-0603",     "ind-0805",
        "ind-1616", "ind-2016", "ferrite-0402", "led-0402",
    };
    for (prelude) |name| {
        // Each family must be present AND declare the footprint it needs — a
        // family whose land pattern is missing builds but cannot be fabricated,
        // which the next test then proves resolves.
        try expectFamilyBundled(name);
    }
}

/// Assert the bundle carries `lib/components/<name>.sexp` and that it names a
/// footprint. Holds the per-name work so its caller keeps a single loop.
fn expectFamilyBundled(name: []const u8) !void {
    var buf: [96]u8 = undefined;
    const sub = try std.fmt.bufPrint(&buf, "lib/components/{s}.sexp", .{name});
    try testing.expect(bundled(sub) != null);
    try testing.expect(std.mem.indexOf(u8, bundled(sub).?, "(footprint ") != null);
}

// spec: stdlib - Every footprint a bundled component names resolves inside the bundle
test "every bundled component's footprint and pinout is bundled too" {
    var comps = stems("lib/components/");
    while (comps.next()) |name| {
        var buf: [96]u8 = undefined;
        const sub = try std.fmt.bufPrint(&buf, "lib/components/{s}.sexp", .{name});
        const bytes = bundled(sub).?;
        try expectReferencedFileBundled(bytes, "(footprint ", "lib/footprints/");
        try expectReferencedFileBundled(bytes, "(pinout ", "lib/pinouts/");
    }
}

/// Assert that the single-token argument of `form` inside `bytes` names a file
/// the bundle carries under `dir`. A form that is absent is fine — only
/// `component` requires a pinout, and a family names none.
fn expectReferencedFileBundled(bytes: []const u8, form: []const u8, dir: []const u8) !void {
    const at = std.mem.indexOf(u8, bytes, form) orelse return;
    var rest = bytes[at + form.len ..];
    rest = std.mem.trimStart(u8, rest, " \t\"");
    const end = std.mem.indexOfAny(u8, rest, " \t\")\n").?;
    var buf: [160]u8 = undefined;
    const sub = try std.fmt.bufPrint(&buf, "{s}{s}.sexp", .{ dir, rest[0..end] });
    try testing.expect(bundled(sub) != null);
}

// spec: stdlib - A project's own lib/ file overrides the bundled one of the same name
test "a project file overrides the bundle, and a missing one falls through to it" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "lib/components");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "lib/components/cap-0402.sexp",
        .data = "(component-family \"cap-0402\" (symbol generic-cap) (footprint local-0402) (parameter \"value\" capacitance))",
    });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    const local = open(testing.allocator, root, "lib/components/cap-0402.sexp", 1 << 20).?;
    defer testing.allocator.free(local.path);
    defer testing.allocator.free(local.bytes);
    try testing.expect(!local.bundled);
    try testing.expect(std.mem.indexOf(u8, local.bytes, "local-0402") != null);

    // A family the project does NOT carry still resolves, out of the bundle,
    // and reports a bundled path rather than a filename that does not exist.
    const fell_through = open(testing.allocator, root, "lib/components/res-0402.sexp", 1 << 20).?;
    defer testing.allocator.free(fell_through.path);
    defer testing.allocator.free(fell_through.bytes);
    try testing.expect(fell_through.bundled);
    try testing.expect(isBundledPath(fell_through.path));
    try testing.expectEqualStrings("netlisp:stdlib/lib/components/res-0402.sexp", fell_through.path);
}

// spec: stdlib - A bundled path reads back through readPath so a recorded read-set stays complete
test "a bundled path reads back by path" {
    const found = standard(testing.allocator, "lib/footprints/c-0402.sexp", 1 << 20).?;
    defer testing.allocator.free(found.path);
    defer testing.allocator.free(found.bytes);

    const again = readPath(testing.allocator, found.path, 1 << 20).?;
    defer testing.allocator.free(again);
    try testing.expectEqualStrings(found.bytes, again);

    // A path that is not bundled goes to the filesystem, and a missing file is
    // a null rather than an error — every caller here is a `catch continue`.
    try testing.expect(readPath(testing.allocator, "/definitely/not/here.sexp", 1 << 20) == null);
}

// spec: stdlib - NETLISP_STDLIB_DIR replaces the embedded table without disturbing the project's own lib/
test "a stdlib root overrides the embedded table" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "components");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "components/res-0402.sexp",
        .data = "(component-family \"res-0402\" (symbol generic-res) (footprint override-0402) (parameter \"value\" resistance))",
    });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    setRoots(null, root);
    defer setRoots(null, null);

    const found = open(testing.allocator, "/no/such/project", "lib/components/res-0402.sexp", 1 << 20).?;
    defer testing.allocator.free(found.path);
    defer testing.allocator.free(found.bytes);
    try testing.expect(!found.bundled);
    try testing.expect(std.mem.indexOf(u8, found.bytes, "override-0402") != null);

    // Anything the override root does NOT carry still comes from the table:
    // pointing at a directory is an addition, not an amputation.
    try testing.expect(exists(testing.allocator, "/no/such/project", "lib/components/cap-0402.sexp"));
}

// spec: stdlib - The bundle lists its own contents so library search and describe can see it
test "bundled stems list one sub-directory at a time" {
    var comps = stems("lib/components/");
    try testing.expect(try listsStem(&comps, "cap-0402"));

    var buf: [max_stems_prefix]u8 = undefined;
    var fps = stemsIn(&buf, "footprints");
    try testing.expect(try listsStem(&fps, "c-0402"));

    // A sub-directory the bundle does not carry lists nothing rather than
    // leaking the whole table.
    var empty_buf: [max_stems_prefix]u8 = undefined;
    var none = stemsIn(&empty_buf, "datasheets");
    try testing.expect(none.next() == null);
}

/// Drain `it`, asserting every stem it yields is a bare basename, and report
/// whether `want` was among them.
fn listsStem(it: *StemIterator, want: []const u8) !bool {
    var found = false;
    while (it.next()) |name| {
        if (std.mem.eql(u8, name, want)) found = true;
        try testing.expect(std.mem.indexOfScalar(u8, name, '/') == null);
        try testing.expect(!std.mem.endsWith(u8, name, ".sexp"));
    }
    return found;
}
