//! The project's vendor symbol index: every `.kicad_sym` under
//! `lib/sources/`, keyed by the names a netlisp component can be looked up by.
//!
//! A part imported from a vendor library keeps its original `.kicad_sym`
//! beside the `.kicad_mod` the footprint exporter already reuses verbatim
//! (`export_kicad_footprint.findSourceKicadMod`). This module is the symbol
//! twin of that lookup, with the same name normalisation — case-insensitive,
//! `_` and `-` interchangeable — so `LP5907MFX-1.8_NOPB` finds
//! `lp5907mfx-1.8-nopb`.
//!
//! Two keys per file: every symbol's own name, and the file's stem. The stem
//! matters because a vendor exporter sometimes names the file after the
//! download rather than the part; the symbol name matters because one library
//! can hold many symbols, and because a part number containing a comma
//! (`74AHCT1G125GF,132`) is spelled with an underscore in the filename.
//!
//! Everything degrades to "no vendor symbol": a missing directory, an
//! unreadable file, or a library that fails to parse costs that one part its
//! drawn body and nothing else.

const std = @import("std");
const infra_fs = @import("../infra/fs.zig");
const log = @import("../infra/log.zig");
const reader = @import("reader.zig");

/// Where a project keeps the original vendor files it imported parts from.
pub const sources_subdir = "lib/sources";

/// Extension `load` indexes out of `sources_subdir`. Public because a cache of
/// an export built from this index has to stamp exactly the files that index
/// read — one spelling, so a scan and its dependency set can never disagree.
pub const suffix = ".kicad_sym";
/// Cap on a vendor `lib/sources/<file>.kicad_sym` read. A vendor symbol
/// library dwarfs a netlisp `lib/` source - the largest in this project is
/// ~248 KB, already 94% of a 256 KiB cap - so the class carries its own
/// figure rather than sharing the lib-source one.
const max_vendor_symbol_bytes: usize = 4 * 1024 * 1024;
const max_name_len: usize = 128;

/// Vendor symbols by normalised lookup name. Built once per export and read
/// concurrently by nothing — the exporter is single-threaded.
pub const Library = struct {
    by_name: std.StringHashMapUnmanaged(reader.Symbol) = .empty,
    /// How many `.kicad_sym` files parsed, for the export's coverage report.
    files: usize = 0,

    /// The vendor symbol registered under `name`, or null when the project has
    /// none (or the name is longer than any real part number).
    pub fn find(self: Library, name: []const u8) ?reader.Symbol {
        if (name.len == 0 or name.len > max_name_len) return null;
        var buf: [max_name_len]u8 = undefined;
        return self.by_name.get(normalize(&buf, name));
    }
};

/// Index every vendor library in `<project_dir>/lib/sources`. Files are read in
/// sorted order and the first registration of a name wins, so the index — and
/// therefore the exported schematic — does not depend on directory order.
pub fn load(arena: std.mem.Allocator, project_dir: []const u8) std.mem.Allocator.Error!Library {
    var lib = Library{};
    const dir_path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ project_dir, sources_subdir });
    const files = try listSources(arena, dir_path);
    std.mem.sort([]const u8, files, {}, lessName);
    for (files) |name| try indexFile(arena, &lib, dir_path, name);
    return lib;
}

fn lessName(_: void, x: []const u8, y: []const u8) bool {
    return std.mem.lessThan(u8, x, y);
}

/// Every `.kicad_sym` filename in `dir_path`. An absent or unreadable
/// directory is simply a project with no vendor sources.
fn listSources(arena: std.mem.Allocator, dir_path: []const u8) std.mem.Allocator.Error![][]const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    var dir = infra_fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return out.items;
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, suffix)) continue;
        try out.append(arena, try arena.dupe(u8, entry.name));
    }
    return out.items;
}

/// Read one library and register its symbols. Registered under each symbol's
/// own name, and — for the first symbol only — under the file's stem.
fn indexFile(
    arena: std.mem.Allocator,
    lib: *Library,
    dir_path: []const u8,
    file: []const u8,
) std.mem.Allocator.Error!void {
    const path = try std.fmt.allocPrint(arena, "{s}/{s}", .{ dir_path, file });
    const src = infra_fs.cwd().readFileAlloc(arena, path, max_vendor_symbol_bytes) catch return;
    const syms = reader.parseLibrary(arena, src) catch |err| {
        log.warn("export-kicad-sch: vendor symbol library {s} is unreadable ({s})", .{ file, @errorName(err) });
        return;
    };
    if (syms.len == 0) return;
    lib.files += 1;
    for (syms) |sym| try register(arena, lib, sym.name, sym);
    try register(arena, lib, file[0 .. file.len - suffix.len], syms[0]);
}

fn register(
    arena: std.mem.Allocator,
    lib: *Library,
    name: []const u8,
    sym: reader.Symbol,
) std.mem.Allocator.Error!void {
    if (name.len == 0 or name.len > max_name_len) return;
    var buf: [max_name_len]u8 = undefined;
    const gop = try lib.by_name.getOrPut(arena, try arena.dupe(u8, normalize(&buf, name)));
    if (!gop.found_existing) gop.value_ptr.* = sym;
}

/// Lowercase, with `_` folded onto `-` — the same normalisation the footprint
/// passthrough uses, so the two lookups agree on what "the same part" means.
/// Writes into `buf`, which must be at least `name.len` bytes.
fn normalize(buf: []u8, name: []const u8) []const u8 {
    for (name, 0..) |c, i| {
        buf[i] = if (c == '_') '-' else std.ascii.toLower(c);
    }
    return buf[0..name.len];
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

const flat_lib = @embedFile("testdata/vendor-flat.kicad_sym");

/// Write the flat fixture into a temporary project's `lib/sources` under
/// `file_name`, and return that project's absolute path.
fn tempProject(arena: std.mem.Allocator, tmp: *testing.TmpDir, file_name: []const u8) ![]const u8 {
    try tmp.dir.createDirPath(std.testing.io, sources_subdir);
    var dir = try tmp.dir.openDir(std.testing.io, sources_subdir, .{});
    defer dir.close(std.testing.io);
    try dir.writeFile(std.testing.io, .{ .sub_path = file_name, .data = flat_lib });
    return tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
}

// spec: export_kicad_sch - A vendor symbol is found by component, symbol, or pinout name, case-insensitively and with underscores folded onto hyphens
test "kicad-sym: the vendor index matches names case-insensitively across _ and -" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    // The file stem differs from the symbol name in case and separator, so
    // both keys have to be registered for either spelling to resolve.
    const dir = try tempProject(a, &tmp, "Acme_3.kicad_sym");

    const lib = try load(a, dir);
    try testing.expectEqual(@as(usize, 1), lib.files);
    try testing.expect(lib.find("acme-3") != null);
    try testing.expect(lib.find("ACME-3") != null);
    try testing.expect(lib.find("acme_3") != null);
    try testing.expectEqualStrings("ACME-3", lib.find("ACME_3").?.name);
    try testing.expect(lib.find("") == null);
    try testing.expect(lib.find("no-such-part") == null);
}

// spec: export_kicad_sch - A project with no lib/sources directory, or an unparseable vendor file in it, yields an empty vendor index rather than an error
test "kicad-sym: the vendor index tolerates a missing directory and a junk library" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const missing = try load(a, "/nonexistent-project");
    try testing.expectEqual(@as(usize, 0), missing.files);
    try testing.expect(missing.find("acme-3") == null);

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tempProject(a, &tmp, "good.kicad_sym");
    var dir_handle = try tmp.dir.openDir(std.testing.io, sources_subdir, .{});
    defer dir_handle.close(std.testing.io);
    try dir_handle.writeFile(std.testing.io, .{ .sub_path = "junk.kicad_sym", .data = "((((not a library" });

    // The junk file is skipped; the readable one still indexes.
    const lib = try load(a, dir);
    try testing.expectEqual(@as(usize, 1), lib.files);
    try testing.expect(lib.find("acme-3") != null);
    try testing.expect(lib.find("junk") == null);
}
