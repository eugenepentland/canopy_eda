//! KiCad netlist writer: emits the `.net` file — components (ref, value,
//! footprint, id-derived UUID) and their net membership — from a flattened
//! design, pulling pad names and footprint names out of the library source. The
//! electrical half of a KiCad export.

const std = @import("std");
const parser_mod = @import("sexpr/parser.zig");
const ast_mod = @import("sexpr/ast.zig");
const env_mod = @import("eval/env.zig");
const DesignBlock = env_mod.DesignBlock;

const flat_netlist = @import("flat_netlist.zig");
const FlatInstance = flat_netlist.FlatInstance;
const FlatNet = flat_netlist.FlatNet;
const FlatPin = flat_netlist.FlatPin;
const Property = env_mod.Property;
const kicad_format = @import("kicad_pcb/format.zig");

/// Error set for the KiCad netlist helpers in this module — covers parser
/// failures, allocator failures, and the local `InvalidFormat` thrown when
/// a footprint sexp is missing the expected nodes.
pub const NetlistError = std.mem.Allocator.Error || std.Io.Writer.Error || parser_mod.ParseError || error{InvalidFormat};

// --- Netlist writer ---

/// Emit a KiCad `.net` file body for a flattened design: the components
/// section with footprint references and tstamps, then the nets section
/// where any pad not present on a real net is gathered into the
/// unconnected (`code "0"`) net so KiCad treats them as NC.
///
/// The `design_name` is escaped with `kicad_format.sexprEscape`; every other
/// quoted field is copied VERBATIM, and the split is the string's provenance,
/// not a guess. A ref-des, value, footprint name, net name or pad name here is
/// (built from) a slice of a `.string` token the project's own tokenizer read
/// out of a `.sexp`, so it is ALREADY in the grammar's escaped form: it cannot
/// hold a bare `"` and every `\` in it is followed by a byte of the same token.
/// Copying such a slice between quotes always re-parses to the bytes the source
/// meant; escaping it a second time doubles every sequence it carries. Property
/// values round-trip through the `.bom` sidecar, which escapes on write and
/// decodes on read (`bom.decodeOwned`), so they arrive in that same form. The
/// design name is the exception — it comes from the CLI or an HTTP path, never
/// through the tokenizer, so it is the one field a genuinely raw `"` can reach,
/// and one raw `"` makes the WHOLE `.net` unparseable.
pub fn writeNetlist(
    allocator: std.mem.Allocator,
    design_name: []const u8,
    instances: []const FlatInstance,
    nets: []const FlatNet,
    fp_name_map: *const std.StringHashMapUnmanaged([]const u8),
    fp_pad_map: *const std.StringHashMapUnmanaged([]const []const u8),
) (std.mem.Allocator.Error || std.Io.Writer.Error)![]const u8 {
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const w = &buf.writer;

    // Scratch for the escaped design name below and for the connected-pin key
    // set further down.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const tmp = arena.allocator();

    try w.writeAll("(export (version \"E\")\n");
    try w.writeAll("  (design\n");
    // The design name is a CLI/HTTP-supplied string, not a tokenizer slice, so
    // it is the one field here that can carry a genuinely raw `"`.
    try w.print("    (source \"{s}\")\n", .{try kicad_format.sexprEscape(tmp, design_name)});
    try w.writeAll("    (tool \"canopy-eda\"))\n");

    // Components
    try w.writeAll("  (components\n");
    for (instances) |inst| {
        try w.print("    (comp (ref \"{s}\")\n", .{inst.ref_des});
        try w.print("      (value \"{s}\")\n", .{inst.value});
        const kicad_fp = fp_name_map.get(inst.footprint) orelse inst.footprint;
        try w.print("      (footprint \"footprints:{s}\")\n", .{kicad_fp});
        // Sheetpath + tstamp for KiCad PCB ↔ netlist matching.
        // KiCad constructs: FindFootprintByPath(sheetpath_tstamps / component_tstamp)
        try w.writeAll("      (sheetpath (names /) (tstamps /))\n");
        if (inst.uuid.len > 0) {
            try w.print("      (tstamp {s})\n", .{inst.uuid});
        }
        // Properties. These round-trip through the `.bom` sidecar, which
        // escapes on write and decodes on read (`bom.decodeOwned`), so what
        // arrives here is the tokenizer form the library file spelled.
        for (inst.properties) |prop| {
            try w.print("      (property (name \"{s}\") (value \"{s}\"))\n", .{ prop.key, prop.value });
        }
        // Do Not Populate — KiCad reads these two properties to mark the part DNP
        // and drop it from the assembly BOM while keeping it in the netlist.
        if (inst.dnp) {
            try w.writeAll("      (property (name \"dnp\") (value \"\"))\n");
            try w.writeAll("      (property (name \"exclude_from_bom\") (value \"\"))\n");
        }
        try w.writeAll("    )\n");
    }
    try w.writeAll("  )\n");

    // Build set of connected pins per component: "REF\x00PIN" -> true
    var connected_pins = std.StringHashMapUnmanaged(void).empty;
    for (nets) |net| {
        for (net.pins) |pin| {
            const key = try std.fmt.allocPrint(tmp, "{s}\x00{s}", .{ pin.ref_des, pin.pin });
            try connected_pins.put(tmp, key, {});
        }
    }

    // Nets
    try w.writeAll("  (nets\n");
    // Unconnected net with NC pad nodes
    try w.writeAll("    (net (code \"0\") (name \"\")\n");
    for (instances) |inst| {
        const pads = fp_pad_map.get(inst.footprint) orelse continue;
        for (pads) |pad_name| {
            const key = try std.fmt.allocPrint(tmp, "{s}\x00{s}", .{ inst.ref_des, pad_name });
            if (!connected_pins.contains(key)) {
                try w.print("      (node (ref \"{s}\") (pin \"{s}\"))\n", .{ inst.ref_des, pad_name });
            }
        }
    }
    try w.writeAll("    )\n");
    for (nets, 0..) |net, i| {
        if (net.pins.len == 0) continue;
        try w.print("    (net (code \"{d}\") (name \"{s}\")\n", .{ i + 1, net.name });
        for (net.pins) |pin| {
            try w.print("      (node (ref \"{s}\") (pin \"{s}\"))\n", .{ pin.ref_des, pin.pin });
        }
        try w.writeAll("    )\n");
    }
    try w.writeAll("  )\n");

    try w.writeAll(")\n");
    return buf.toOwnedSlice();
}

// --- Footprint pad extraction ---

/// Parse a `.sexp` footprint and return the ordered list of pad names. The
/// netlist writer uses this to surface pads that don't appear on any net,
/// so KiCad sees the full pad inventory even when the design leaves some NC.
pub fn extractPadNames(allocator: std.mem.Allocator, source: []const u8) NetlistError![]const []const u8 {
    const nodes = try parser_mod.parse(allocator, source);
    defer parser_mod.freeNodes(allocator, nodes);

    if (nodes.len == 0) return error.InvalidFormat;
    const root = nodes[0];
    if (!root.isForm("footprint")) return error.InvalidFormat;
    const children = root.asList() orelse return error.InvalidFormat;

    var pads: std.ArrayList([]const u8) = .empty;
    for (children[2..]) |child| {
        if (child.isForm("pad")) {
            const cl = child.asList() orelse continue;
            if (cl.len < 2) continue;
            // Project footprints write pad numbers as bare tokens (`(pad 1 …)`),
            // which the tokenizer parses as `.int` — asAtom()/asString() both
            // return null and the pad silently vanished from the NC inventory.
            // tokenText renders the int, so numerically-padded footprints get a
            // full pad list (the whole point of this map).
            const name = cl[1].tokenText(allocator) orelse continue;
            try pads.append(allocator, try allocator.dupe(u8, name));
        }
    }
    return pads.toOwnedSlice(allocator);
}

// --- Footprint name extraction ---

/// Pull the declared footprint name out of a parsed `.sexp` source. The
/// netlist writer uses this to map the project's internal footprint id
/// (e.g. `r-0402`) to the KiCad library name (`R_0402_1005Metric`).
pub fn extractFootprintName(allocator: std.mem.Allocator, source: []const u8) NetlistError![]const u8 {
    const nodes = try parser_mod.parse(allocator, source);
    defer parser_mod.freeNodes(allocator, nodes);

    if (nodes.len == 0) return error.InvalidFormat;
    const root = nodes[0];
    if (!root.isForm("footprint")) return error.InvalidFormat;
    const children = root.asList() orelse return error.InvalidFormat;
    if (children.len < 2) return error.InvalidFormat;

    const name = children[1].asAtom() orelse children[1].asString() orelse return error.InvalidFormat;
    return try allocator.dupe(u8, name);
}

// --- Hierarchy flattening ---

/// Join `prefix` and `name` with a `/`, or duplicate `name` alone when there
/// is no prefix. The unit of hierarchy-path qualification for ref-des and net
/// names as the flattener descends into sub-blocks.
// ── Design-hierarchy flattening ───────────────────────────────────────────
//
// DECLARED in `flat_netlist.zig`. Walking a `(sub-block …)` tree and merging
// `(net …)` ties is not a KiCad concern — `src/placement/*` needs the same
// flatten this writer does, and reaching up to an exporter for it was the
// upward edge `guardian.toml`'s `[[boundary]]` rule freezes. Re-exported here
// under their historical names so existing callers are untouched.

pub const FlatTie = flat_netlist.FlatTie;
pub const CanonicalNetMap = flat_netlist.CanonicalNetMap;
pub const collectInstances = flat_netlist.collectInstances;
pub const collectNets = flat_netlist.collectNets;
pub const collectNetTies = flat_netlist.collectNetTies;
pub const applyNetTies = flat_netlist.applyNetTies;
pub const applyNetTiesMapped = flat_netlist.applyNetTiesMapped;

// ── Tests ──────────────────────────────────────────────────────────────

/// Depth-first search for the first `(NAME "STRING")` form under `nodes`,
/// returning the string payload as written (still grammar-escaped). Test
/// support for the escaping round-trip below, which has to read a field back
/// out of the emitted document rather than trust a substring match.
fn findFormString(nodes: []const ast_mod.Node, name: []const u8) ?[]const u8 {
    for (nodes) |n| {
        const children = n.asList() orelse continue;
        if (n.isForm(name) and children.len >= 2) {
            if (children[1].asString()) |s| return s;
        }
        if (findFormString(children, name)) |s| return s;
    }
    return null;
}

// spec: export_kicad - Escapes the netlist's design name, the one field that is not a tokenizer slice, and copies already-escaped design strings through untouched
test "writeNetlist escapes the raw design name and copies tokenizer slices verbatim" {
    const alloc = std.testing.allocator;
    // The design name comes from the CLI or an HTTP path: these bytes are RAW,
    // and one of them would otherwise close the token and wreck the document.
    const raw_name = "board \\ \"one\"";
    // A value/net as the TOKENIZER hands them over — already escaped form, the
    // spelling a `.sexp` carrying `2.54mm pitch (0.1\")` actually produces.
    const slice_value = "10\\\"K";
    const slice_net = "VDD\\\"RAW";

    const fp_names: std.StringHashMapUnmanaged([]const u8) = .empty;
    const fp_pads: std.StringHashMapUnmanaged([]const []const u8) = .empty;
    const props = [_]Property{.{ .key = "mpn", .value = "PART\\\"X" }};
    const instances = [_]FlatInstance{.{
        .ref_des = "R1",
        .component = "res-0402",
        .value = slice_value,
        .footprint = "r-0402",
        .properties = &props,
        .uuid = "",
    }};
    const pins = [_]FlatPin{.{ .ref_des = "R1", .pin = "1" }};
    const nets = [_]FlatNet{.{ .name = slice_net, .pins = &pins }};

    const out = try writeNetlist(alloc, raw_name, &instances, &nets, &fp_names, &fp_pads);
    defer alloc.free(out);

    // The whole document parses — with the raw name unescaped, its `"` closes
    // the source token early and everything after it is read as garbage.
    const nodes = try parser_mod.parse(alloc, out);
    defer parser_mod.freeNodes(alloc, nodes);
    try std.testing.expectEqual(@as(usize, 1), nodes.len);

    // The design name decodes back to the exact raw bytes handed in …
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const source_tok = findFormString(nodes, "source") orelse return error.SourceMissing;
    try std.testing.expectEqualStrings(raw_name, try kicad_format.sexprUnescape(a, source_tok));

    // … while every tokenizer slice reaches the file byte for byte. Escaping
    // these a second time is what turns the project's own `(0.1\")` pin-header
    // description into `(0.1\\")` on the KiCad side.
    const value_tok = findFormString(nodes, "value") orelse return error.ValueMissing;
    try std.testing.expectEqualStrings(slice_value, value_tok);
    try std.testing.expect(std.mem.indexOf(u8, out, "(name \"VDD\\\"RAW\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(value \"PART\\\"X\")") != null);
}

// spec: export_kicad_netlist - extractPadNames reads bare-integer pad numbers so numerically-padded footprints appear in the NC inventory
test "extractPadNames reads bare-int, quoted, and atom pad numbers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Project footprints spell numeric pads bare; the fix must not drop them.
    const src =
        \\(footprint "MIX"
        \\  (pad 1 smd rect (pos 0 0) (size 1 1))
        \\  (pad "2" smd rect (pos 1 0) (size 1 1))
        \\  (pad A1 thru circle (pos 2 0) (size 1 1) (drill 0.5)))
    ;
    const pads = try extractPadNames(a, src);
    try std.testing.expectEqual(@as(usize, 3), pads.len);
    try std.testing.expectEqualStrings("1", pads[0]);
    try std.testing.expectEqualStrings("2", pads[1]);
    try std.testing.expectEqualStrings("A1", pads[2]);
}
