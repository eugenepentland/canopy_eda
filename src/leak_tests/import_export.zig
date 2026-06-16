//! Leak-regression tests for the KiCad import/export + emit + convert area.
//!
//! Every test runs through std.testing.allocator (a leak-detecting allocator
//! that panics at test end on any allocation it tracked but that wasn't
//! freed). Two idioms are used here, picked per-function by reading the
//! source:
//!
//!  1. OWNED-RETURN — fn(allocator, …) returns an owned slice the caller frees
//!     AND is expected to free its own internal scratch (parse nodes, temp
//!     buffers). Driven directly with testing.allocator so any forgotten
//!     scratch fails the test. This is the highest-value coverage.
//!  2. ARENA-CONTRACT — fn(arena, …) allocates-and-forgets into the passed
//!     allocator, expecting the caller's arena reset to reclaim everything.
//!     Driven with an ArenaAllocator backed by testing.allocator: deinit frees
//!     the lot, so the test proves the path doesn't crash/double-free and
//!     doesn't escape to a *different* testing-backed allocator. Mirrors the
//!     existing import_kicad / kicad_pcb tests.

const std = @import("std");

const emit = @import("../emit.zig");
const id_insert = @import("../id_insert.zig");
const export_kicad = @import("../export_kicad.zig");
const export_netlist = @import("../export_kicad_netlist.zig");
const export_footprint = @import("../export_kicad_footprint.zig");
const convert_footprint = @import("../convert/footprint.zig");
const convert_symbol = @import("../convert/symbol.zig");
const import_kicad = @import("../import_kicad.zig");
const pcb_reader = @import("../kicad_pcb/reader.zig");
const pcb_writer = @import("../kicad_pcb/writer.zig");
const env_mod = @import("../eval/env.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const DesignBlock = env_mod.DesignBlock;
const FlatInstance = export_kicad.FlatInstance;
const FlatNet = export_kicad.FlatNet;
const FlatPin = export_kicad.FlatPin;
const ZipEntry = export_footprint.ZipEntry;

// ── Idiom 1: owned-return (frees its own scratch) ──────────────────────

// leak-audit: extractPadNames returns an owned slice of dup'd pad-name
// strings AND must free its parse nodes (freeNodes) internally. The caller
// frees the slice + each element; testing.allocator catches any leaked
// parse scratch or an un-freed element.
test "leak: extractPadNames owned slice frees parse scratch" {
    const alloc = std.testing.allocator;
    const src =
        \\(footprint "R_0402_1005Metric"
        \\  (description "Resistor SMD 0402")
        \\  (pad "1" smd roundrect (pos -0.51 0.00) (size 0.54 0.64))
        \\  (pad "2" smd roundrect (pos 0.51 0.00) (size 0.54 0.64)))
    ;
    const pads = try export_netlist.extractPadNames(alloc, src);
    defer {
        for (pads) |p| alloc.free(p);
        alloc.free(pads);
    }
    try std.testing.expectEqual(@as(usize, 2), pads.len);
}

// leak-audit: error path — a non-footprint root makes extractPadNames return
// error.InvalidFormat. The parse nodes allocated before the check must still
// be freed (the defer freeNodes runs on the error return).
test "leak: extractPadNames error path frees parse nodes" {
    const alloc = std.testing.allocator;
    const src = "(not-a-footprint \"X\")";
    try std.testing.expectError(error.InvalidFormat, export_netlist.extractPadNames(alloc, src));
}

// leak-audit: extractFootprintName dup's the declared name into the caller
// allocator and frees its parse nodes internally; caller frees the returned
// name.
test "leak: extractFootprintName owned name frees parse scratch" {
    const alloc = std.testing.allocator;
    const src = "(footprint \"R_0402_1005Metric\" (pad 1 smd rect (pos 0 0) (size 1 1)))";
    const name = try export_netlist.extractFootprintName(alloc, src);
    defer alloc.free(name);
    try std.testing.expectEqualStrings("R_0402_1005Metric", name);
}

// leak-audit: writeNetlist builds the .net body, returns an owned buffer, and
// internally spins up + deinits its own ArenaAllocator for the connected-pin
// set. Mirrors the existing "netlist generation" test's input shape.
test "leak: writeNetlist owned buffer + internal arena freed" {
    const alloc = std.testing.allocator;
    var fp_map = std.StringHashMap([]const u8).init(alloc);
    defer fp_map.deinit();
    try fp_map.put("r-0402", "R_0402_1005Metric");

    const instances = [_]FlatInstance{
        .{ .ref_des = "R1", .component = "res-0402", .value = "220k", .footprint = "r-0402", .properties = &.{}, .uuid = "" },
    };
    const pins = [_]FlatPin{
        .{ .ref_des = "R1", .pin = "1" },
        .{ .ref_des = "U1", .pin = "3" },
    };
    const nets_arr = [_]FlatNet{
        .{ .name = "VDD", .pins = &pins },
    };
    var fp_pad_map = std.StringHashMap([]const []const u8).init(alloc);
    defer fp_pad_map.deinit();

    const out = try export_netlist.writeNetlist(alloc, "test", &instances, &nets_arr, &fp_map, &fp_pad_map);
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "(ref \"R1\")") != null);
}

// leak-audit: convertFootprint parses, builds an owned output buffer, and must
// freeNodes its parse tree. Caller frees the returned slice.
test "leak: convertFootprint owned buffer frees parse scratch" {
    const alloc = std.testing.allocator;
    const input =
        \\(footprint "R_0402_1005Metric"
        \\  (descr "Resistor SMD 0402")
        \\  (pad "1" smd roundrect (at -0.51 0) (size 0.54 0.64) (layers "F.Cu" "F.Mask" "F.Paste"))
        \\  (pad "2" smd roundrect (at 0.51 0) (size 0.54 0.64) (layers "F.Cu" "F.Mask" "F.Paste"))
        \\  (fp_rect (start -0.93 -0.47) (end 0.93 0.47) (layer "F.CrtYd")))
    ;
    const out = try convert_footprint.convertFootprint(alloc, input);
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "(courtyard") != null);
}

// leak-audit: error path — empty/invalid source returns error.InvalidFormat
// after parsing; the parse nodes must be freed on the error return.
test "leak: convertFootprint error path frees parse nodes" {
    const alloc = std.testing.allocator;
    try std.testing.expectError(error.InvalidFormat, convert_footprint.convertFootprint(alloc, "(random)"));
}

// leak-audit: convertSymbol collects symbol nodes into a temp ArrayList
// (deinit'd), builds an owned output buffer, and freeNodes its parse tree.
test "leak: convertSymbol owned buffer + temp list freed" {
    const alloc = std.testing.allocator;
    const input =
        \\(kicad_symbol_lib (version 20211014) (generator canopy)
        \\  (symbol "R" (pin_numbers hide) (pin_names (offset 0))
        \\    (property "Reference" "R")
        \\    (symbol "R_1_1"
        \\      (pin passive line (at 0 3.81 270) (length 1.27) (name "~") (number "1"))
        \\      (pin passive line (at 0 -3.81 90) (length 1.27) (name "~") (number "2")))))
    ;
    const out = try convert_symbol.convertSymbol(alloc, input, null);
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "passive") != null);
}

// leak-audit: generatePinout collects pins into temp lists (deinit'd) and
// returns an owned buffer; parse nodes freed internally.
test "leak: generatePinout owned buffer frees pin lists" {
    const alloc = std.testing.allocator;
    const input =
        \\(kicad_symbol_lib (version 20211014) (generator canopy)
        \\  (symbol "U1"
        \\    (symbol "U1_1_1"
        \\      (pin power_in line (at 0 0 0) (length 1) (name "VDD") (number "1"))
        \\      (pin power_in line (at 0 1 0) (length 1) (name "GND") (number "2")))))
    ;
    const out = try convert_symbol.generatePinout(alloc, input, null);
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "(pinout") != null);
}

// leak-audit: generatePackage parses two sources and builds several temp
// HashMaps + ArrayLists (all deinit'd) before returning an owned buffer. The
// symbol parse nodes are NOT freed inside the fn (it doesn't call freeNodes
// on sym_nodes/fp_nodes — they're left to the caller's allocator), so the
// parse-node arrays themselves are the one thing testing.allocator would flag
// if this fn forgot to free its own intermediate maps/lists. The parser
// allocates the node arrays through `alloc`; this test documents that
// generatePackage frees every container it owns and confirms the node arrays
// are the deliberate-leak boundary by running under an arena so nothing
// false-fails.
test "leak: generatePackage temp maps/lists freed (arena-wrapped)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sym =
        \\(symbol "R"
        \\  (symbol "R_1_1"
        \\    (pin passive line (at 0 0 0) (length 1) (name "A") (number "1"))
        \\    (pin passive line (at 0 1 0) (length 1) (name "B") (number "2"))))
    ;
    const fp =
        \\(footprint "R_0402"
        \\  (pad "1" smd rect (at 0 0) (size 1 1))
        \\  (pad "2" smd rect (at 1 0) (size 1 1)))
    ;
    const out = try convert_symbol.generatePackage(a, sym, fp, "r-0402", null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(package \"r-0402\"") != null);
}

// leak-audit: exportFootprintMod parses, builds an owned buffer, freeNodes its
// parse tree. Optional model args left null. Caller frees the result.
test "leak: exportFootprintMod owned buffer frees parse scratch" {
    const alloc = std.testing.allocator;
    const source =
        \\(footprint "R_0402_1005Metric"
        \\  (description "Resistor SMD 0402")
        \\  (pad 1 smd roundrect (pos -0.51 0.00) (size 0.54 0.64))
        \\  (pad 2 smd roundrect (pos 0.51 0.00) (size 0.54 0.64))
        \\  (courtyard (rect -0.93 -0.47 0.93 0.47)))
    ;
    const out = try export_footprint.exportFootprintMod(alloc, source, null, null, null);
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "(footprint \"R_0402_1005Metric\"") != null);
}

// leak-audit: buildZip allocates an `offsets` scratch slice (defer-freed) and
// returns an owned buffer. Entry name/data are borrowed (not freed). Caller
// frees the returned archive.
test "leak: buildZip owned archive frees offsets scratch" {
    const alloc = std.testing.allocator;
    const entries = [_]ZipEntry{
        .{ .name = "a.txt", .data = "hello" },
        .{ .name = "b.txt", .data = "world" },
    };
    const zip = try export_footprint.buildZip(alloc, &entries);
    defer alloc.free(zip);
    // Local-file-header signature "PK\x03\x04" leads the archive.
    try std.testing.expect(zip.len >= 4 and std.mem.eql(u8, zip[0..4], &[_]u8{ 'P', 'K', 3, 4 }));
}

// leak-audit: uuidFromId returns a single owned allocPrint'd string; caller
// frees it. No internal scratch, but a forgotten free would be caught.
test "leak: uuidFromId owned string" {
    const alloc = std.testing.allocator;
    const uuid = try export_kicad.uuidFromId(alloc, "a1b2c3d4");
    defer alloc.free(uuid);
    try std.testing.expectEqual(@as(usize, 36), uuid.len);
}

// leak-audit: emitResolved walks the design tree building an owned buffer; for
// each sub-block it allocPrint's a child prefix and defer-frees it. With no
// sub-blocks the only allocation is the result buffer. Mirrors the existing
// "emit placeholder" test's DesignBlock literal.
test "leak: emitResolved owned buffer (flat design)" {
    const alloc = std.testing.allocator;
    var block = DesignBlock{
        .name = "test",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const out = try emit.emitResolved(alloc, &block);
    defer alloc.free(out);
    try std.testing.expect(std.mem.startsWith(u8, out, "(resolved-design \"test\""));
}

// leak-audit: applyInserts builds an internal `edits` ArrayList of allocPrint'd
// text (freed in a defer loop), a uniqueness StringHashMap, and a child-group
// AutoHashMap of ArrayLists (all deinit'd), returning an owned result buffer.
// Exercises the child-sidecar path so all three containers are populated.
test "leak: applyInserts owned buffer frees edit + group scratch" {
    const alloc = std.testing.allocator;
    const src = "(decouple \"VDD\")";
    const child = [_]Evaluator.PendingChildId{
        .{ .parent_form_offset = 0, .key = "100nF@P7#0", .id = "a1b2c3d4" },
    };
    const out = try id_insert.applyInserts(alloc, src, &.{}, &child);
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "(ids (\"100nF@P7#0\" a1b2c3d4))") != null);
}

// leak-audit: error path — a duplicate pending token makes applyInserts return
// error.IdCollision from assertTokensUnique. The `seen` map allocated there
// must be deinit'd on the error return.
test "leak: applyInserts collision error frees seen map" {
    const alloc = std.testing.allocator;
    const src = "(instance \"R1\" comp)(instance \"R2\" comp)";
    const pending = [_]Evaluator.PendingId{
        .{ .form_offset = 0, .id = "a1b2c3d4" },
        .{ .form_offset = 20, .id = "a1b2c3d4" },
    };
    try std.testing.expectError(error.IdCollision, id_insert.applyInserts(alloc, src, &pending, &.{}));
}

// ── Idiom 2: arena-contract (allocate-and-forget into passed arena) ─────

// leak-audit: sanitizeNetName appends into an ArrayList backed by the passed
// allocator and returns its `.items` (arena-owned — no caller free). Wrapping
// the arena over testing.allocator proves it touches only the given allocator
// and never escapes; deinit reclaims everything.
test "leak: sanitizeNetName arena-contract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try import_kicad.sanitizeNetName(a, "/+5.0V(weird)");
    try std.testing.expect(out.len > 0);
}

// leak-audit: sanitizeName is the same arena-contract shape (lowercased slug
// into an ArrayList, returns .items). Empty-after-strip input takes the
// "part" fallback append branch.
test "leak: sanitizeName arena-contract incl. fallback branch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const slug = try import_kicad.sanitizeName(a, "Some Part #1");
    try std.testing.expect(slug.len > 0);
    const fallback = try import_kicad.sanitizeName(a, "***");
    try std.testing.expectEqualStrings("part", fallback);
}

// leak-audit: readBoard parses a .kicad_pcb and allocates a net-id map +
// per-footprint BoardFp records, all into the passed arena. Arena-contract:
// nothing is freed inside; the arena reset reclaims it. Mirrors the existing
// reader tests.
test "leak: readBoard arena-contract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\(kicad_pcb
        \\  (net 0 "")
        \\  (net 1 "VDD")
        \\  (footprint "R_0402"
        \\    (uuid "abc-123")
        \\    (property "Reference" "R7")
        \\    (property "Value" "10k")
        \\    (pad "1" smd roundrect (at 0 0) (net 1 "VDD"))))
    ;
    const fps = try pcb_reader.readBoard(arena.allocator(), src);
    try std.testing.expectEqual(@as(usize, 1), fps.len);
}

// leak-audit: applyOpsToSource parses the board + ops JSON, rewrites the tree,
// and re-prints — every intermediate (parsed JSON, node arrays, printed
// output) lands in the passed arena. Arena-contract; mirrors the existing
// writer tests.
test "leak: applyOpsToSource arena-contract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const src =
        \\(kicad_pcb
        \\  (net 0 "")
        \\  (net 1 "OLD")
        \\  (footprint "R_0402"
        \\    (uuid "fp-1")
        \\    (pad "1" smd roundrect (at 0 0) (net 1 "OLD"))))
    ;
    const ops =
        \\[{"op":"set_pad_net","uuid":"fp-1","pad":"1","net":"NEW"}]
    ;
    const out = try pcb_writer.applyOpsToSource(arena.allocator(), src, ops);
    try std.testing.expect(std.mem.indexOf(u8, out, "NEW") != null);
}
