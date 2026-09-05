//! KiCad *project* sidecars for an exported schematic — the small files that
//! turn a bare `.kicad_sch` into something KiCad opens with its references
//! resolved.
//!
//! An exported sheet places `netlisp:<part>` symbols and assigns
//! `footprints:<name>` footprints. Both spellings name a *library*, and KiCad
//! reports one `lib_symbol_issues` / `footprint_link_issues` warning per
//! affected symbol while that library is not in the reader's library tables —
//! on a real board that is hundreds of warnings burying the two or three
//! findings worth reading.
//!
//! Four files clear it, all deterministic and all written beside the root
//! sheet (see `Sidecar` below). Measured on the exported `board-c` (22 sheets,
//! 232 parts): `kicad-cli sch erc --severity-all` goes from **730** violations
//! to **2**, both `isolated_pin_label` on genuine one-pin nets, and 0 errors
//! throughout.
//!
//! One caveat, and it is why `footprint_link_issues` is left at KiCad's
//! default severity rather than silenced: `footprints.pretty/` is written by
//! `export-kicad`, not by the schematic exporter. A schematic-only download
//! therefore still reports those warnings until the footprint bundle sits
//! beside it — which is exactly what `export-kicad --with-schematic` (and the
//! `/api/export-kicad` zip) produces in one directory.

const std = @import("std");
const emit = @import("emit.zig");
const json_writer = @import("../json_writer.zig");
const shape_mod = @import("shape.zig");

const Shape = shape_mod.Shape;

/// Library name the exported symbols are qualified with (`netlisp:<part>`),
/// and the file the `sym-lib-table` row points at.
pub const sym_lib_name = "netlisp";
pub const sym_lib_file = sym_lib_name ++ ".kicad_sym";

/// Library name the netlist exporter qualifies footprints with
/// (`footprints:<name>`), and the directory `export-kicad` writes them into.
pub const fp_lib_name = "footprints";
pub const fp_lib_dir = fp_lib_name ++ ".pretty";

/// Bare filenames of the two library tables. KiCad reads them from the
/// project directory, so both are siblings of the root sheet.
pub const sym_lib_table_file = "sym-lib-table";
pub const fp_lib_table_file = "fp-lib-table";

/// Extension of the project file. KiCad finds it by the root sheet's stem, so
/// it must be named `<design>.kicad_pro`.
pub const project_ext = ".kicad_pro";

/// One emitted sidecar: a bare filename (written beside the root sheet, never
/// in a subdirectory) and its bytes.
pub const Sidecar = struct {
    name: []const u8,
    bytes: []const u8,
};

/// `${KIPRJMOD}` expands to the directory holding the project file, so both
/// tables resolve relative to wherever the export is unpacked.
const kiprjmod = "${KIPRJMOD}";

const sym_lib_table_text =
    "(sym_lib_table\n\t(version 7)\n\t(lib (name \"" ++ sym_lib_name ++ "\")(type \"KiCad\")" ++
    "(uri \"" ++ kiprjmod ++ "/" ++ sym_lib_file ++ "\")(options \"\")" ++
    "(descr \"Symbols exported by netlisp\"))\n)\n";

const fp_lib_table_text =
    "(fp_lib_table\n\t(version 7)\n\t(lib (name \"" ++ fp_lib_name ++ "\")(type \"KiCad\")" ++
    "(uri \"" ++ kiprjmod ++ "/" ++ fp_lib_dir ++ "\")(options \"\")" ++
    "(descr \"Footprints exported by netlisp export-kicad\"))\n)\n";

/// Build the four sidecars for `design`, in a fixed order: the two library
/// tables, the project file, then the symbol library. `shapes` and `rails` are
/// the union across every emitted sheet — the library must hold every entry
/// any sheet references, or the warning it exists to clear comes back as
/// "symbol not found in library".
pub fn sidecars(
    arena: std.mem.Allocator,
    design: []const u8,
    shapes: []const Shape,
    rails: []const emit.Rail,
) emit.EmitError![]const Sidecar {
    const project_name = try std.fmt.allocPrint(arena, "{s}" ++ project_ext, .{design});
    const out = try arena.alloc(Sidecar, 4);
    out[0] = .{ .name = sym_lib_table_file, .bytes = sym_lib_table_text };
    out[1] = .{ .name = fp_lib_table_file, .bytes = fp_lib_table_text };
    out[2] = .{ .name = project_name, .bytes = try projectFile(arena, project_name) };
    out[3] = .{ .name = sym_lib_file, .bytes = try emit.libraryFile(arena, shapes, rails) };
    return out;
}

/// A minimal-but-valid KiCad 10 `.kicad_pro`. Every key KiCad expects is
/// present and empty, so the defaults apply and nothing here overrides a
/// severity or a design rule — the file exists to make the project (and with
/// it the project-local library tables) resolvable, not to tune ERC.
fn projectFile(arena: std.mem.Allocator, project_name: []const u8) emit.EmitError![]u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll("{\n  \"board\": {},\n  \"libraries\": {\n");
    try w.writeAll("    \"pinned_footprint_libs\": [],\n    \"pinned_symbol_libs\": []\n  },\n");
    try w.writeAll("  \"meta\": {\n    \"filename\": ");
    try json_writer.writeString(w, project_name);
    try w.writeAll(",\n    \"version\": 1\n  },\n");
    try w.writeAll("  \"net_settings\": {},\n  \"pcbnew\": {},\n  \"schematic\": {},\n");
    try w.writeAll("  \"sheets\": [],\n  \"text_variables\": {}\n}\n");
    return out.toOwnedSlice();
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

// spec: export_kicad_sch - The project sidecars are a sym-lib-table, an fp-lib-table, a minimal <design>.kicad_pro, and a netlisp.kicad_sym holding every placed symbol
test "kicad-sch: the sidecar set names the four project files" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const units = try a.alloc(shape_mod.Unit, 1);
    units[0] = .{ .number = 1, .title = "", .pins = &.{}, .half_w = 254, .half_h = 254 };
    const shapes = [_]Shape{.{ .lib_name = "demo-part", .units = units }};
    const rails = [_]emit.Rail{.{ .lib_name = "PWR_GND", .net = "GND" }};

    const files = try sidecars(a, "demo", &shapes, &rails);
    try testing.expectEqual(@as(usize, 4), files.len);
    try testing.expectEqualStrings("sym-lib-table", files[0].name);
    try testing.expectEqualStrings("fp-lib-table", files[1].name);
    try testing.expectEqualStrings("demo.kicad_pro", files[2].name);
    try testing.expectEqualStrings("netlisp.kicad_sym", files[3].name);

    // The tables name the libraries the sheets qualify their symbols and
    // footprints with — a different name resolves nothing.
    try testing.expect(std.mem.indexOf(u8, files[0].bytes, "(name \"netlisp\")") != null);
    try testing.expect(std.mem.indexOf(u8, files[1].bytes, "(name \"footprints\")") != null);
    // The project file is valid JSON naming itself.
    try testing.expect(std.mem.indexOf(u8, files[2].bytes, "\"demo.kicad_pro\"") != null);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, files[2].bytes, .{});
    defer parsed.deinit();
    try testing.expect(parsed.value.object.get("meta") != null);
}

// spec: export_kicad_sch - The exported netlisp.kicad_sym names its symbols bare while a sheet's lib_symbols block names the same entries by lib_id
test "kicad-sch: the symbol library drops the lib_id prefix" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    const units = try a.alloc(shape_mod.Unit, 1);
    units[0] = .{ .number = 1, .title = "", .pins = &.{}, .half_w = 254, .half_h = 254 };
    const shapes = [_]Shape{.{ .lib_name = "demo-part", .units = units }};
    const rails = [_]emit.Rail{.{ .lib_name = "PWR_GND", .net = "GND" }};

    const lib = try emit.libraryFile(a, &shapes, &rails);
    try testing.expect(std.mem.startsWith(u8, lib, "(kicad_symbol_lib"));
    // Bare names — a colon here would make `netlisp:demo-part` unresolvable.
    try testing.expect(std.mem.indexOf(u8, lib, "(symbol \"demo-part\"") != null);
    try testing.expect(std.mem.indexOf(u8, lib, "(symbol \"PWR_GND\"") != null);
    try testing.expect(std.mem.indexOf(u8, lib, "netlisp:") == null);
    // The PWR_FLAG driver is always present, so the library's shape does not
    // depend on whether this particular design has a ground rail.
    try testing.expect(std.mem.indexOf(u8, lib, "(symbol \"PWR_FLAG\"") != null);
}

// spec: export_kicad_sch - A design name needing JSON escapes is escaped in the exported .kicad_pro rather than breaking it
test "kicad-sch: the project file escapes a hostile design name" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // The private `jsonString` this once carried is now `json_writer.writeString`
    // — the sidecar half of the escaper pair. A `.kicad_pro` is read by KiCad and
    // never by a browser, so `<` stays literal (it is legal JSON), while the
    // three bytes that WOULD corrupt the file are escaped.
    const files = try sidecars(a, "od\"d\\n<a>me\x01", &.{}, &.{});
    try testing.expect(std.mem.indexOf(u8, files[2].bytes, "<a>") != null);
    var parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, files[2].bytes, .{});
    defer parsed.deinit();
    const meta = parsed.value.object.get("meta").?.object.get("filename").?.string;
    try testing.expectEqualStrings("od\"d\\n<a>me\x01.kicad_pro", meta);
}
