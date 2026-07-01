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
//! The walk runs once per call. With a small project tree this is
//! microseconds; introducing a cache would mean threading invalidation
//! through every write site, which is a worse trade-off.
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

    var dir = infra_fs.cwd().openDir(src_path, .{ .iterate = true }) catch return null;
    defer dir.close();

    var walker = dir.walk(allocator) catch return null;
    defer walker.deinit();

    var found: ?[]u8 = null;
    while (walker.next() catch null) |entry| {
        if (entry.kind != .file and entry.kind != .sym_link) continue;
        if (!std.mem.eql(u8, entry.basename, filename)) continue;
        const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ src_path, entry.path });
        if (found) |existing| {
            log.warn("paths: ambiguous design basename {s}: keeping {s}, also found {s}", .{ filename, existing, full });
            allocator.free(full);
            continue;
        }
        found = full;
    }
    return found;
}

// Pull `commands.zig`'s CLI-arg-parsing tests (e.g. `parseBuildArgs`) into the
// test tree. `commands.zig` is not referenced by `main.zig`'s root `test {}`
// block, and it already depends on this module, so bridging here (test-scope
// only) is the least-intrusive way to collect those tests without editing the
// root file. The `@import` cycle is harmless — it is not comptime-recursive.
test {
    _ = @import("commands.zig");
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
