//! `netlisp export-pinmap` — the firmware pin map of a design.
//!
//! A board's schematic already knows which pad of which IC carries which net,
//! what the silicon calls that pad, which alternate function the design signed
//! the pad up for, and which functional block the pad was declared in. Firmware
//! then re-types all of it into a header by hand off a PDF, and the two drift
//! silently: a pin move that the schematic, the netlist, the PCB and the ERC
//! all agree on is invisible to the C file that still names the old pad.
//!
//!   netlisp export-pinmap --project-dir <dir> [--ref REF]… \
//!       [--format c|json] [--output <file>] <design>
//!
//! It is READ-ONLY: it evaluates the design through the same seam the PCB page
//! reads (`pcb_layout_page.resolveBlock`), flattens the hierarchy with
//! `flat_netlist.flattenAndMergeNets`, and writes to `--output` or stdout. It
//! mints no id, edits no source, and starts no server.
//!
//! ## What is in a row
//!
//! One row per CONNECTED pad of each selected part — a pad with no net is not a
//! firmware pin. Each row carries the pad id, the pinout's function name for
//! that pad, the alternates (the pinout's own `(alt …)` list unioned with the
//! functions the design asserted with `(as …)`), the flattened net, the
//! `(pins … (group "…"))` label the pad was declared under, and the enclosing
//! `(section …)` with its `(role …)` and `(protocol …)` words.
//!
//! Selected parts are the hub classes — `U`/`J`/`P`/`X`/`Q`, the ref-des
//! letters the schematic renderer draws as boxes — that have a
//! `lib/pinouts/<key>.sexp` entry, because a part with no pinout has no
//! function names to export. `--ref` overrides the class filter and names parts
//! exactly; it matches the flattened ref-des, its leaf, or the instance's
//! source name (`(instance "stm32" …)` is reachable as `--ref stm32`).
//!
//! ## Determinism
//!
//! Parts sort by flattened ref-des and pads sort in natural order
//! (`export_names.padLessThan`), so two runs of one binary are byte-identical
//! and two binaries compare with a plain `diff`. The only per-run value is the
//! build id, which sits on a `*#`-prefixed header line in the C output and in
//! the `"build_id"` member of the JSON, so:
//!
//!   diff -I '^\*#' base.h cand.h            # C
//!   diff -I '"build_id"' base.json cand.json
//!
//! compares the pin map alone.

const std = @import("std");
const build_id = @import("build_id.zig");
const env_mod = @import("eval/env.zig");
const erc = @import("erc.zig");
const exit = @import("exit.zig");
const flat_netlist = @import("flat_netlist.zig");
const infra_fs = @import("infra/fs.zig");
const json_writer = @import("json_writer.zig");
const names = @import("export_names.zig");
const net_name = @import("net_name.zig");
const mcp_arg_names = @import("serve/mcp_arg_names.zig");
const modules_mod = @import("serve/modules.zig");
const pcb_layout_page = @import("serve/pcb_layout_page.zig");
const subprocess = @import("serve/subprocess.zig");
const Evaluator = @import("eval/evaluator.zig").Evaluator;

/// Everything the exporter can fail with: allocation, rendering, and (only for
/// `--output`) the file write. A design that does not resolve, an unusable
/// `--format` and a run naming no design are their own errors so the CLI can
/// print a usage line rather than a stack of I/O names.
pub const PinmapError = std.mem.Allocator.Error || std.Io.Writer.Error ||
    std.Io.Dir.WriteFileError || error{ PinmapUsage, UnresolvedDesign };

/// The two shapes a pin map is written in.
const Format = enum { c, json };

/// The ref-des class letters the schematic renders as hub boxes, and therefore
/// the parts a firmware pin map is about. A passive has no function names.
const hub_classes = "UJPXQ";

/// The prefix on every C header-comment line and the reason a `diff -I '^\*#'`
/// compares the pin map alone. Distinct from a bare `*` so the per-row `/* … */`
/// commentary inside the file is still compared.
const header_mark = "*#";

/// The cap on what the C-syntax check may read back from the compiler. Only
/// the test path reads it; a compiler that floods stdout is killed rather than
/// buffered.
const max_syntax_check_bytes: usize = 1 << 20;

/// Parsed `export-pinmap` argument vector.
const Args = struct {
    project_dir: []const u8 = "projects/designs",
    name: []const u8 = "",
    format: Format = .c,
    output: ?[]const u8 = null,
    refs: []const []const u8 = &.{},
};

/// Parse the CLI argument vector. Unknown flags, a missing value, a second
/// positional and an unusable `--format` are all usage errors rather than a
/// silently-defaulted run that would export the wrong thing.
fn parseArgs(arena: std.mem.Allocator, args: []const []const u8) PinmapError!Args {
    var out: Args = .{};
    var refs: std.ArrayList([]const u8) = .empty;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (!std.mem.startsWith(u8, a, "--")) {
            if (out.name.len != 0) return error.PinmapUsage;
            out.name = a;
            continue;
        }
        if (i + 1 >= args.len) return error.PinmapUsage;
        i += 1;
        if (std.mem.eql(u8, a, "--project-dir")) {
            out.project_dir = args[i];
        } else if (std.mem.eql(u8, a, "--output")) {
            out.output = args[i];
        } else if (std.mem.eql(u8, a, "--ref")) {
            try refs.append(arena, args[i]);
        } else if (std.mem.eql(u8, a, "--format")) {
            out.format = parseFormat(args[i]) orelse return error.PinmapUsage;
        } else return error.PinmapUsage;
    }
    if (out.name.len == 0) return error.PinmapUsage;
    out.refs = refs.items;
    return out;
}

/// The `--format` word, or null when it names neither shape.
fn parseFormat(word: []const u8) ?Format {
    if (std.mem.eql(u8, word, "c")) return .c;
    if (std.mem.eql(u8, word, "json")) return .json;
    return null;
}

// ── The exported model ──────────────────────────────────────────────────────

/// One connected pad of one part, with everything the design knows about it.
const Row = struct {
    pad: []const u8,
    /// The pinout's primary function name for this pad, or "" when the pinout
    /// carries none.
    function: []const u8,
    /// The pinout's `(alt …)` names unioned with the design's `(as …)`
    /// assertions, deduplicated and sorted.
    alternates: []const []const u8,
    /// The flattened, tie-merged net the pad is wired to.
    net: []const u8,
    /// The `(pins REF (group "…"))` label the pad was declared under.
    group: []const u8,
    /// The `(section …)` that declaration sits in.
    section: []const u8,
    /// That section's `(role …)` word, or "" when it declares none.
    role: []const u8,
    /// That section's `(protocol …)` words joined with `|`, or "".
    protocols: []const u8,
};

/// One selected part and its connected pads, sorted.
const Part = struct {
    /// The flattened `sub-block/REF` reference designator.
    ref: []const u8,
    /// The instance's source name — the first argument of `(instance …)`.
    origin: []const u8,
    component: []const u8,
    /// The `lib/pinouts/<key>.sexp` entry the function names were read from.
    pinout: []const u8,
    rows: []const Row,
};

/// A whole pin map, ready to render in either format.
const Document = struct {
    design: []const u8,
    parts: []const Part,
};

/// Where a pad was declared, gathered off the section tree before the rows are
/// built. All fields default empty: a pad declared inline on an instance rather
/// than through a `(pins …)` block genuinely has no group.
const Placement = struct {
    section: []const u8 = "",
    group: []const u8 = "",
    role: []const u8 = "",
    protocols: []const u8 = "",
    /// The function name the `(pins …)` block itself resolved for the pad, used
    /// when no pinout file is readable at export time.
    pin_name: []const u8 = "",
};

/// The two lookups the section walk produces: per-pad placement (from
/// `(pins …)` blocks, which name individual pads) and per-ref placement (from
/// instances declared inside a section, which name no pad at all).
const Placements = struct {
    by_pad: std.StringHashMapUnmanaged(Placement) = .empty,
    by_ref: std.StringHashMapUnmanaged(Placement) = .empty,
};

/// `"<ref>|<pad>"`, the key both the placement and asserted-function lookups
/// use. Spelled once so the two can never key differently.
fn padKey(arena: std.mem.Allocator, ref: []const u8, pad: []const u8) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}|{s}", .{ ref, pad });
}

/// Join a sub-block path prefix onto a local name, the `sub-block/REF` spelling
/// `flat_netlist.collectNets` gives every flattened ref-des and net.
fn joinPath(arena: std.mem.Allocator, prefix: []const u8, name: []const u8) std.mem.Allocator.Error![]const u8 {
    if (prefix.len == 0) return name;
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, name });
}

// ── Collection ──────────────────────────────────────────────────────────────

/// Walk the section tree of `block` and every sub-block, recording where each
/// pad and each part was declared. Later declarations never displace earlier
/// ones, so the answer does not depend on hash iteration order anywhere.
fn collectPlacements(
    arena: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    prefix: []const u8,
    out: *Placements,
) std.mem.Allocator.Error!void {
    for (block.sections) |section| try walkSection(arena, section, prefix, out);
    for (block.sub_blocks) |sb| {
        try collectPlacements(arena, sb.block, try joinPath(arena, prefix, sb.name), out);
    }
}

/// Record one section's pin groups, its own instances, and its sub-sections.
fn walkSection(
    arena: std.mem.Allocator,
    section: env_mod.Section,
    prefix: []const u8,
    out: *Placements,
) std.mem.Allocator.Error!void {
    const base = Placement{
        .section = section.name,
        .role = roleWord(section.block_role),
        .protocols = try joinWords(arena, section.protocols),
    };
    for (section.pin_groups) |group| try recordGroup(arena, group, base, prefix, out);
    for (section.instances) |inst| {
        try putFirst(arena, &out.by_ref, try joinPath(arena, prefix, inst.ref_des), base);
    }
    for (section.sub_sections) |sub| try walkSection(arena, sub, prefix, out);
}

/// Record every pad of one `(pins REF (group "…") …)` block.
fn recordGroup(
    arena: std.mem.Allocator,
    group: env_mod.PinGroup,
    base: Placement,
    prefix: []const u8,
    out: *Placements,
) std.mem.Allocator.Error!void {
    const ref = try joinPath(arena, prefix, group.ref_des);
    try putFirst(arena, &out.by_ref, ref, base);
    for (group.pins) |pin| {
        var placed = base;
        placed.group = group.group;
        placed.pin_name = pin.pin_name;
        try putFirst(arena, &out.by_pad, try padKey(arena, ref, pin.pin), placed);
    }
}

/// Insert `value` at `key` unless something is already there — first
/// declaration wins, so a part named by two sections keeps the first one.
fn putFirst(
    arena: std.mem.Allocator,
    map: *std.StringHashMapUnmanaged(Placement),
    key: []const u8,
    value: Placement,
) std.mem.Allocator.Error!void {
    const gop = try map.getOrPut(arena, key);
    if (!gop.found_existing) gop.value_ptr.* = value;
}

/// The word a section's `(role …)` declares, or "" for the inferred default.
fn roleWord(role: env_mod.BlockRole) []const u8 {
    return switch (role) {
        .auto => "",
        .input => "input",
        .output => "output",
    };
}

/// Join a word list with `|` — the separator is `|` rather than `,` so the
/// value can sit inside a C comment and a JSON string unescaped either way.
fn joinWords(arena: std.mem.Allocator, words: []const []const u8) std.mem.Allocator.Error![]const u8 {
    if (words.len == 0) return "";
    var aw: std.Io.Writer.Allocating = .init(arena);
    for (words, 0..) |word, i| {
        if (i > 0) aw.writer.writeAll("|") catch return error.OutOfMemory;
        aw.writer.writeAll(word) catch return error.OutOfMemory;
    }
    return aw.written();
}

/// Collect the `(as "FN")` assertions on every pin of the design, keyed by the
/// flattened `"<ref>|<pad>"`.
///
/// `asserted_fns.buildMap` already builds this map, but keys it by the
/// SUB-BLOCK-LOCAL ref-des (both renderers read it that way), so two modules'
/// `U1` share one entry. A pin map names flattened parts, so the prefix has to
/// be carried — the same `sub-block/REF` join `flat_netlist.collectNets` makes.
fn collectAsserted(
    arena: std.mem.Allocator,
    block: *const env_mod.DesignBlock,
    prefix: []const u8,
    out: *std.StringHashMapUnmanaged([]const []const u8),
) std.mem.Allocator.Error!void {
    for (block.nets) |net| try recordAssertedPins(arena, net, prefix, out);
    for (block.sub_blocks) |sb| {
        try collectAsserted(arena, sb.block, try joinPath(arena, prefix, sb.name), out);
    }
}

/// Record one net's pins that carry an assertion.
fn recordAssertedPins(
    arena: std.mem.Allocator,
    net: env_mod.Net,
    prefix: []const u8,
    out: *std.StringHashMapUnmanaged([]const []const u8),
) std.mem.Allocator.Error!void {
    for (net.pins) |pin| {
        if (pin.asserted_fns.len == 0) continue;
        const key = try padKey(arena, try joinPath(arena, prefix, pin.ref_des), pin.pin);
        try out.put(arena, key, pin.asserted_fns);
    }
}

/// Whether `inst` is one of the parts this run exports.
///
/// With `--ref` the named parts are exported whatever their class, so a passive
/// carrying a pinout can be asked for by name. Without it, the hub classes are
/// the selection. Either way a part with no readable pinout is skipped by the
/// caller — there would be no function name to write.
fn selects(refs: []const []const u8, inst: flat_netlist.FlatInstance) bool {
    if (refs.len == 0) return isHub(inst.ref_des);
    for (refs) |want| {
        if (std.mem.eql(u8, want, inst.ref_des)) return true;
        if (std.mem.eql(u8, want, net_name.leaf(inst.ref_des))) return true;
        if (inst.origin_key.len != 0 and std.mem.eql(u8, want, inst.origin_key)) return true;
    }
    return false;
}

/// Whether a flattened ref-des names a hub class part.
fn isHub(ref: []const u8) bool {
    const local = net_name.leaf(ref);
    if (local.len == 0) return false;
    return std.mem.indexOfScalar(u8, hub_classes, local[0]) != null;
}

/// The `lib/pinouts` lookup key for an instance: its declared pinout, else its
/// symbol, else the component family name — the same fallback chain
/// `eval/pin_enrichment.putSymbol` uses.
fn pinoutKey(inst: flat_netlist.FlatInstance) []const u8 {
    if (inst.pinout.len > 0) return inst.pinout;
    if (inst.symbol.len > 0) return inst.symbol;
    return inst.component;
}

/// Build the whole pin map for one resolved block.
fn buildDocument(
    arena: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    block: *env_mod.DesignBlock,
    refs: []const []const u8,
) std.mem.Allocator.Error!Document {
    var nets: std.ArrayList(flat_netlist.FlatNet) = .empty;
    try flat_netlist.flattenAndMergeNets(arena, block, &nets);
    var pad_nets: std.StringHashMapUnmanaged([]const u8) = .empty;
    var pads_by_ref: PadsByRef = .empty;
    try indexPadNets(arena, nets.items, &pad_nets, &pads_by_ref);

    var placements: Placements = .{};
    try collectPlacements(arena, block, "", &placements);
    var asserted: std.StringHashMapUnmanaged([]const []const u8) = .empty;
    try collectAsserted(arena, block, "", &asserted);

    var instances: std.ArrayList(flat_netlist.FlatInstance) = .empty;
    try flat_netlist.collectInstances(arena, block, "", &instances);
    std.mem.sort(flat_netlist.FlatInstance, instances.items, {}, lessInstance);

    var parts: std.ArrayList(Part) = .empty;
    for (instances.items) |inst| {
        if (!selects(refs, inst)) continue;
        const key = pinoutKey(inst);
        const pinout = erc.loadPinoutMap(arena, project_dir, key) orelse continue;
        const rows = try buildRows(arena, .{
            .inst = inst,
            .pinout = pinout,
            .pad_nets = &pad_nets,
            .pads_by_ref = &pads_by_ref,
            .placements = &placements,
            .asserted = &asserted,
        });
        if (rows.len == 0) continue;
        try parts.append(arena, .{
            .ref = inst.ref_des,
            .origin = inst.origin_key,
            .component = inst.component,
            .pinout = key,
            .rows = rows,
        });
    }
    return .{ .design = name, .parts = parts.items };
}

/// Order flattened instances by ref-des, the order the document is written in.
fn lessInstance(_: void, a: flat_netlist.FlatInstance, b: flat_netlist.FlatInstance) bool {
    return std.mem.order(u8, a.ref_des, b.ref_des) == .lt;
}

/// Index every `(ref, pad)` to the net it sits on. Nets are visited in sorted
/// order and the first claim wins, so a pad that somehow appears on two nets
/// resolves the same way on every run instead of by hash order.
fn indexPadNets(
    arena: std.mem.Allocator,
    nets: []flat_netlist.FlatNet,
    out: *std.StringHashMapUnmanaged([]const u8),
    pads_by_ref: *PadsByRef,
) std.mem.Allocator.Error!void {
    std.mem.sort(flat_netlist.FlatNet, nets, {}, lessNet);
    for (nets) |net| try indexOneNet(arena, net, out, pads_by_ref);
}

/// Every wired pad of one part, in the order the sorted nets named them.
const PadsByRef = std.StringHashMapUnmanaged(std.ArrayList([]const u8));

/// Order flattened nets by name.
fn lessNet(_: void, a: flat_netlist.FlatNet, b: flat_netlist.FlatNet) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

/// Claim every pad of one net that no earlier net already claimed.
///
// twin-drift-ok: `export_spice.indexOneNet` indexes a different value — the
// SPICE NODE a net maps to, after ground-class nets have collapsed onto `0` —
// where this one indexes the design's own net NAME, which is what the pin
// map's `net` column must show. The shared part is a first-wins insert into a
// hash map; parameterising a four-line loop over its value type would hide
// which of the two answers a caller gets.
fn indexOneNet(
    arena: std.mem.Allocator,
    net: flat_netlist.FlatNet,
    out: *std.StringHashMapUnmanaged([]const u8),
    pads_by_ref: *PadsByRef,
) std.mem.Allocator.Error!void {
    for (net.pins) |pin| {
        const gop = try out.getOrPut(arena, try padKey(arena, pin.ref_des, pin.pin));
        if (gop.found_existing) continue;
        gop.value_ptr.* = net.name;
        // Built in the same pass as the pad index: rescanning that index once
        // per part is quadratic on a board with thousands of pads.
        const by_ref = try pads_by_ref.getOrPut(arena, pin.ref_des);
        if (!by_ref.found_existing) by_ref.value_ptr.* = .empty;
        try by_ref.value_ptr.append(arena, pin.pin);
    }
}

/// Everything `buildRows` reads, gathered so the function keeps a signature
/// under the parameter cap.
const RowRequest = struct {
    inst: flat_netlist.FlatInstance,
    pinout: std.StringHashMapUnmanaged(erc.PinoutEntry),
    pad_nets: *const std.StringHashMapUnmanaged([]const u8),
    pads_by_ref: *const PadsByRef,
    placements: *const Placements,
    asserted: *const std.StringHashMapUnmanaged([]const []const u8),
};

/// Build one part's rows: every pad the design wired, in natural pad order.
///
/// The pads come from the NETLIST, not from the pinout: a pin map is about pads
/// firmware can reach, and a pinout also lists every pad the design left
/// unconnected.
fn buildRows(arena: std.mem.Allocator, req: RowRequest) std.mem.Allocator.Error![]const Row {
    const wired = req.pads_by_ref.get(req.inst.ref_des) orelse return &.{};
    const pads = try arena.dupe([]const u8, wired.items);
    std.mem.sort([]const u8, pads, {}, names.padLessThan);

    const rows = try arena.alloc(Row, pads.len);
    for (pads, rows) |pad, *row| {
        const key = try padKey(arena, req.inst.ref_des, pad);
        const placed = req.placements.by_pad.get(key) orelse
            req.placements.by_ref.get(req.inst.ref_des) orelse Placement{};
        const entry = req.pinout.get(pad);
        row.* = .{
            .pad = pad,
            .function = if (entry) |e| e.primary else placed.pin_name,
            .alternates = try mergeAlternates(arena, entry, req.asserted.get(key) orelse &.{}),
            .net = req.pad_nets.get(key) orelse "",
            .group = placed.group,
            .section = placed.section,
            .role = placed.role,
            .protocols = placed.protocols,
        };
    }
    return rows;
}

/// The pinout's declared alternates unioned with the design's `(as …)`
/// assertions, deduplicated and sorted so the row is stable.
fn mergeAlternates(
    arena: std.mem.Allocator,
    entry: ?erc.PinoutEntry,
    assertions: []const []const u8,
) std.mem.Allocator.Error![]const []const u8 {
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    var out: std.ArrayList([]const u8) = .empty;
    if (entry) |e| try appendUnseen(arena, e.alts, &seen, &out);
    try appendUnseen(arena, assertions, &seen, &out);
    std.mem.sort([]const u8, out.items, {}, lessWord);
    return out.items;
}

/// Append the words of `list` not already in `seen`.
fn appendUnseen(
    arena: std.mem.Allocator,
    list: []const []const u8,
    seen: *std.StringHashMapUnmanaged(void),
    out: *std.ArrayList([]const u8),
) std.mem.Allocator.Error!void {
    for (list) |word| {
        if (word.len == 0) continue;
        const gop = try seen.getOrPut(arena, word);
        if (gop.found_existing) continue;
        try out.append(arena, word);
    }
}

/// Lexicographic word order, for the alternate lists.
fn lessWord(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

// ── Rendering ───────────────────────────────────────────────────────────────

/// Render `doc` in `format`.
fn render(arena: std.mem.Allocator, doc: Document, format: Format) PinmapError![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    switch (format) {
        .c => try renderC(arena, &aw.writer, doc),
        .json => try renderJson(&aw.writer, doc),
    }
    return aw.written();
}

/// Write the C header: a `*#` comment header, an include guard, one
/// `#define <REF>_<NET>_PIN "<pad>"` per row, and one table per part.
fn renderC(arena: std.mem.Allocator, w: *std.Io.Writer, doc: Document) PinmapError!void {
    var table: names.Table = .{};
    const guard = try std.fmt.allocPrint(arena, "NETLISP_PINMAP_{s}_H", .{
        try names.sanitize(arena, .upper, doc.design),
    });
    try writeCHeader(w, doc, guard);
    for (doc.parts) |part| try writeCPart(arena, w, part, &table);
    try w.print("\n#endif /* {s} */\n", .{guard});
}

/// The block comment, the include guard and the sanitising note.
fn writeCHeader(w: *std.Io.Writer, doc: Document, guard: []const u8) std.Io.Writer.Error!void {
    try w.writeAll("/*\n");
    try w.print("{s} netlisp export-pinmap — firmware pin map\n", .{header_mark});
    try w.print("{s} design: {s}\n", .{ header_mark, doc.design });
    try w.print("{s} build: {s}\n", .{ header_mark, build_id.current() });
    try w.print("{s} parts: {d}\n", .{ header_mark, doc.parts.len });
    try w.print("{s} Generated file — do not edit. Every line of this header starts\n", .{header_mark});
    try w.print("{s} with the mark above, so `diff -I '^\\*#' a.h b.h` compares the pin\n", .{header_mark});
    try w.print("{s} map alone.\n", .{header_mark});
    try w.writeAll("*/\n");
    try w.print("#ifndef {s}\n#define {s}\n", .{ guard, guard });
    try w.writeAll(
        \\
        \\/* Names are sanitised into C identifiers: every byte outside
        \\   [A-Za-z0-9_] becomes '_', runs of '_' collapse, leading and trailing
        \\   '_' are trimmed, an empty result becomes 'X', and a leading digit is
        \\   prefixed with 'N' (net "3V3" -> N3V3). Macros are upper-cased and
        \\   table identifiers lower-cased. Two different design names that fold
        \\   to one spelling are separated by a _2 / _3 / ... suffix; each macro
        \\   quotes the design net it came from, so any such fold is visible. */
        \\
    );
}

/// One part: its banner, its `#define`s, and its table.
fn writeCPart(
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    part: Part,
    table: *names.Table,
) PinmapError!void {
    const ref_upper = try names.sanitize(arena, .upper, part.ref);
    try w.print("\n/* {s}", .{part.ref});
    if (part.origin.len != 0) try w.print(" \"{s}\"", .{part.origin});
    try w.print(" — {s} (pinout {s}), {d} connected pads */\n", .{ part.component, part.pinout, part.rows.len });
    for (part.rows) |row| try writeCDefine(arena, w, ref_upper, row, table);

    const ident = (try table.unique(arena, part.ref, try std.fmt.allocPrint(arena, "{s}_pinmap", .{
        try names.sanitize(arena, .lower, part.ref),
    }))).name;
    try w.print("\nstatic const struct {{ const char *pad, *function, *net, *group; }} {s}[] = {{\n", .{ident});
    for (part.rows) |row| try writeCRow(w, row);
    try w.writeAll("};\n");
}

/// One `#define <REF>_<NET>_PIN "<pad>"` line.
fn writeCDefine(
    arena: std.mem.Allocator,
    w: *std.Io.Writer,
    ref_upper: []const u8,
    row: Row,
    table: *names.Table,
) PinmapError!void {
    const candidate = try std.fmt.allocPrint(arena, "{s}_{s}_PIN", .{
        ref_upper,
        try names.sanitize(arena, .upper, row.net),
    });
    // Keyed by ref+pad, which is unique, so a net landing on several pads gets
    // one macro per pad rather than one macro that silently keeps the last.
    const macro = try table.unique(arena, try padKey(arena, ref_upper, row.pad), candidate);
    try w.print("#define {s} \"{s}\" /* net \"{s}\"", .{ macro.name, row.pad, row.net });
    if (row.function.len != 0) try w.print(", function {s}", .{row.function});
    try w.writeAll(" */\n");
}

/// One table row plus its trailing provenance comment.
fn writeCRow(w: *std.Io.Writer, row: Row) std.Io.Writer.Error!void {
    try w.writeAll("  { ");
    try writeCString(w, row.pad);
    try w.writeAll(", ");
    try writeCString(w, row.function);
    try w.writeAll(", ");
    try writeCString(w, row.net);
    try w.writeAll(", ");
    try writeCString(w, row.group);
    try w.writeAll(" },");
    try writeCRowComment(w, row);
    try w.writeAll("\n");
}

/// The `/* … */` note carrying what the four columns have no room for.
fn writeCRowComment(w: *std.Io.Writer, row: Row) std.Io.Writer.Error!void {
    if (row.section.len == 0 and row.alternates.len == 0 and row.role.len == 0 and row.protocols.len == 0) return;
    try w.writeAll(" /*");
    if (row.section.len != 0) try w.print(" section \"{s}\"", .{row.section});
    if (row.role.len != 0) try w.print(" role {s}", .{row.role});
    if (row.protocols.len != 0) try w.print(" protocol {s}", .{row.protocols});
    for (row.alternates, 0..) |alt, i| try w.print("{s}{s}", .{ if (i == 0) " alt " else "/", alt });
    try w.writeAll(" */");
}

/// A C string literal. `"` and `\` are escaped and every other byte is written
/// through; a design name is source text, so it may carry either.
fn writeCString(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeAll("\"");
    for (s) |c| {
        if (c == '"' or c == '\\') try w.writeAll("\\");
        try w.writeByte(c);
    }
    try w.writeAll("\"");
}

/// Write the JSON pin map: the same rows, one member per line so the only
/// per-run value (`build_id`) sits alone and `diff -I '"build_id"'` compares
/// the pin map alone.
fn renderJson(w: *std.Io.Writer, doc: Document) PinmapError!void {
    try w.writeAll("{\n  \"design\": ");
    try json_writer.writeString(w, doc.design);
    try w.writeAll(",\n  \"build_id\": ");
    try json_writer.writeString(w, build_id.current());
    try w.writeAll(",\n  \"parts\": [");
    for (doc.parts, 0..) |part, i| {
        try w.writeAll(if (i == 0) "\n" else ",\n");
        try writePartObject(w, part);
    }
    try w.writeAll(if (doc.parts.len == 0) "]\n}\n" else "\n  ]\n}\n");
}

/// One part object.
fn writePartObject(w: *std.Io.Writer, part: Part) PinmapError!void {
    try w.writeAll("    { \"ref\": ");
    try json_writer.writeString(w, part.ref);
    try w.writeAll(", \"name\": ");
    try json_writer.writeString(w, part.origin);
    try w.writeAll(", \"component\": ");
    try json_writer.writeString(w, part.component);
    try w.writeAll(", \"pinout\": ");
    try json_writer.writeString(w, part.pinout);
    try w.writeAll(", \"pads\": [");
    for (part.rows, 0..) |row, i| {
        try w.writeAll(if (i == 0) "\n" else ",\n");
        try writePadObject(w, row);
    }
    try w.writeAll(if (part.rows.len == 0) "] }" else "\n    ] }");
}

/// One pad object.
fn writePadObject(w: *std.Io.Writer, row: Row) PinmapError!void {
    try w.writeAll("      { \"pad\": ");
    try json_writer.writeString(w, row.pad);
    try w.writeAll(", \"function\": ");
    try json_writer.writeString(w, row.function);
    try w.writeAll(", \"alternates\": [");
    for (row.alternates, 0..) |alt, i| {
        if (i > 0) try w.writeAll(", ");
        try json_writer.writeString(w, alt);
    }
    try w.writeAll("], \"net\": ");
    try json_writer.writeString(w, row.net);
    try w.writeAll(", \"group\": ");
    try json_writer.writeString(w, row.group);
    try w.writeAll(", \"section\": ");
    try json_writer.writeString(w, row.section);
    try w.writeAll(", \"role\": ");
    try json_writer.writeString(w, row.role);
    try w.writeAll(", \"protocols\": ");
    try json_writer.writeString(w, row.protocols);
    try w.writeAll(" }");
}

// ── Entry points ────────────────────────────────────────────────────────────

/// Resolve `parsed.name` and render its pin map, or `error.UnresolvedDesign`.
///
// twin-drift-ok: `export_spice.exportOne` reads the same three lines because
// resolving a design IS three lines here — `Evaluator.init`, the shared
// `pcb_layout_page.resolveBlock` seam, and the module-block teardown — and
// every read-only CLI in this tree (netlist_dump, gerber_dump, drc_dump)
// repeats them too. What follows differs entirely: one builds a pin-map
// Document over a pinout, the other a SPICE Deck over a node table. Lifting a
// four-line skeleton whose only shared statement is a call into a seam both
// already share would add an indirection and share nothing.
fn exportOne(arena: std.mem.Allocator, parsed: Args) PinmapError![]const u8 {
    var eval = Evaluator.init(arena, parsed.project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        arena.destroy(mr.eval);
    };
    const block = pcb_layout_page.resolveBlock(arena, parsed.project_dir, parsed.name, &eval, &module_res) orelse
        return error.UnresolvedDesign;
    const doc = try buildDocument(arena, parsed.project_dir, parsed.name, block, parsed.refs);
    return render(arena, doc, parsed.format);
}

const usage_line =
    "Usage: netlisp export-pinmap [--project-dir <d>] [--ref REF]… [--format c|json] [--output <file>] <design>\n";

/// CLI entry: `netlisp export-pinmap …`.
///
// twin-drift-ok: the twin is `export_spice.cmdExportSpice`. Both are the
// standard CLI wrapper — arena, parse, run, write to `--output` or stdout —
// over their OWN `Args` type, usage line and error set, which is what the four
// differing lines are. There is no shared body left to lift once those are
// removed.
pub fn cmdExportPinmap(allocator: std.mem.Allocator, args: []const []const u8) PinmapError!void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = parseArgs(arena, args) catch exit.fatal(usage_line, .{});
    const text = exportOne(arena, parsed) catch |err| switch (err) {
        error.UnresolvedDesign => exit.fatal("export-pinmap: cannot resolve design '{s}'\n", .{parsed.name}),
        else => return err,
    };
    if (parsed.output) |path| {
        try infra_fs.cwd().writeFile(.{ .sub_path = path, .data = text });
        return;
    }
    try std.Io.File.stdout().writeStreamingAll(infra_fs.currentIo(), text);
}

/// `export_pinmap` — the registered structured tool. Returns the exported file
/// text verbatim (the same bytes `--output` would write), or a plain
/// `error: …` line with `ok:false` when the request is unusable — the shape
/// `get_language_reference` already uses for a text-returning tool.
pub fn tool(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) PinmapError!bool {
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, out);
    defer out.* = aw.toArrayList();
    const name = stringArg(args_val, "name") orelse {
        try aw.writer.writeAll("error: name is required");
        return false;
    };
    const format = parseFormat(stringArg(args_val, "format") orelse "c") orelse {
        try aw.writer.writeAll("error: format must be \"c\" or \"json\"");
        return false;
    };
    const parsed = Args{
        .project_dir = project_dir,
        .name = name,
        .format = format,
        .refs = try refList(allocator, args_val),
    };
    const text = exportOne(allocator, parsed) catch |err| switch (err) {
        error.UnresolvedDesign => {
            try aw.writer.print("error: cannot resolve design \"{s}\"", .{name});
            return false;
        },
        else => return err,
    };
    try aw.writer.writeAll(text);
    return true;
}

/// A string argument off the tool's JSON object, or null.
fn stringArg(args_val: ?std.json.Value, key: []const u8) ?[]const u8 {
    const av = args_val orelse return null;
    if (av != .object) return null;
    const v = av.object.get(key) orelse return null;
    if (v != .string or v.string.len == 0) return null;
    return v.string;
}

/// The optional `refs` allowlist, read the way every other name-list tool
/// argument is read.
fn refList(allocator: std.mem.Allocator, args_val: ?std.json.Value) std.mem.Allocator.Error![]const []const u8 {
    return mcp_arg_names.parse(allocator, args_val, "refs");
}

// ── The C-compiler check ────────────────────────────────────────────────────

/// Whether a rendered C header compiles, judged by the system C compiler.
const Syntax = enum { compiles, rejected, no_compiler };

/// Run `cc -fsyntax-only` over `source`. The text is piped into the compiler by
/// a shell rather than written to a file, so the check leaves nothing behind
/// and needs no writable directory. `no_compiler` when `cc` is not on PATH,
/// which is how a machine without a toolchain skips rather than fails.
fn checkCSyntax(allocator: std.mem.Allocator, source: []const u8) std.mem.Allocator.Error!Syntax {
    var probe = try subprocess.runCaptured(allocator, &.{ "sh", "-c", "command -v cc >/dev/null 2>&1" }, 4096, 10_000);
    defer probe.deinit(allocator);
    if (probe.outcome != .ok or probe.exit_code != 0) return .no_compiler;

    var run = try subprocess.runCaptured(
        allocator,
        &.{ "sh", "-c", "printf '%s' \"$1\" | cc -std=c99 -fsyntax-only -x c -", "sh", source },
        max_syntax_check_bytes,
        60_000,
    );
    defer run.deinit(allocator);
    if (run.outcome == .ok and run.exit_code == 0) return .compiles;
    return .rejected;
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// The pads of the fixture's hub part: a net repeated on several pads, a
/// leading-digit net, a slashed net, a quote inside a group label, and a pad
/// carrying alternates.
///
/// At file scope rather than inside `fixture()` because a fixture that built
/// these arrays as locals would return the address of stack storage.
const fixture_hub_rows = [_]Row{
    .{
        .pad = "F1",
        .function = "VDD",
        .alternates = &.{},
        .net = "3V3",
        .group = "VDD Power",
        .section = "Core",
        .role = "input",
        .protocols = "",
    },
    .{
        .pad = "J14",
        .function = "VDD",
        .alternates = &.{},
        .net = "3V3",
        .group = "VDD Power",
        .section = "Core",
        .role = "input",
        .protocols = "",
    },
    .{
        .pad = "A3",
        .function = "PA3",
        .alternates = &.{ "USB1_OTG_HS_DP", "USB1_OTG_HS_DP_ALT" },
        .net = "usb/DP",
        .group = "USB 2.0 HS \"PHY\"",
        .section = "USB",
        .role = "",
        .protocols = "USB2.0-HS|SPI",
    },
};

/// The one pad of the fixture's sub-block connector: a hierarchical ref-des,
/// no placement at all, and a net that folds onto the hub's `usb/DP`.
const fixture_sub_rows = [_]Row{.{
    .pad = "1",
    .function = "IO1",
    .alternates = &.{},
    .net = "usb.DP",
    .group = "",
    .section = "",
    .role = "",
    .protocols = "",
}};

/// The fixture's two parts.
const fixture_parts = [_]Part{
    .{ .ref = "U1", .origin = "stm32", .component = "stm32n657l0h3q", .pinout = "stm32n657l0h3q", .rows = &fixture_hub_rows },
    .{ .ref = "usb/J2", .origin = "", .component = "conn", .pinout = "conn", .rows = &fixture_sub_rows },
};

/// A two-part pin map covering everything the renderers have to get right.
fn fixture() Document {
    return .{ .design = "demo-board", .parts = &fixture_parts };
}

// spec: export-pinmap - the CLI parses the project dir, the format, the output path and repeated ref filters, and refuses a run that names no design, names two, or names an unknown format
test "export-pinmap CLI parses its flags and refuses an unusable vector" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const parsed = try parseArgs(arena, &.{ "--project-dir", "p", "--ref", "U1", "--ref", "stm32", "--format", "json", "--output", "x.json", "board-b" });
    try testing.expectEqualStrings("p", parsed.project_dir);
    try testing.expectEqualStrings("board-b", parsed.name);
    try testing.expectEqualStrings("x.json", parsed.output.?);
    try testing.expectEqual(Format.json, parsed.format);
    try testing.expectEqual(@as(usize, 2), parsed.refs.len);
    try testing.expectEqualStrings("stm32", parsed.refs[1]);
    // The default project dir and format are the documented ones.
    const bare = try parseArgs(arena, &.{"board-b"});
    try testing.expectEqualStrings("projects/designs", bare.project_dir);
    try testing.expectEqual(Format.c, bare.format);
    // A run naming no design, naming two, carrying an unknown flag, a flag with
    // no value, or an unknown format is a usage error rather than a wrong export.
    try testing.expectError(error.PinmapUsage, parseArgs(arena, &.{}));
    try testing.expectError(error.PinmapUsage, parseArgs(arena, &.{ "a", "b" }));
    try testing.expectError(error.PinmapUsage, parseArgs(arena, &.{ "--wat", "x", "a" }));
    try testing.expectError(error.PinmapUsage, parseArgs(arena, &.{ "a", "--format" }));
    try testing.expectError(error.PinmapUsage, parseArgs(arena, &.{ "--format", "rust", "a" }));
}

// spec: export-pinmap - the C header carries an include guard, one macro per connected pad with the repeated net separated by a suffix, one table per part, and a *#-marked header carrying the build id
test "the C pin map guards, defines and tabulates every row" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = try render(arena, fixture(), .c);
    try testing.expect(std.mem.indexOf(u8, text, "#ifndef NETLISP_PINMAP_DEMO_BOARD_H") != null);
    try testing.expect(std.mem.indexOf(u8, text, "#endif /* NETLISP_PINMAP_DEMO_BOARD_H */") != null);
    // The build id is the only per-run value and it sits on a `*#` line.
    try testing.expect(std.mem.indexOf(u8, text, "*# build: test\n") != null);
    // A leading-digit net is guarded, and the SECOND pad of that net gets its
    // own macro instead of silently redefining the first.
    try testing.expect(std.mem.indexOf(u8, text, "#define U1_N3V3_PIN \"F1\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "#define U1_N3V3_PIN_2 \"J14\"") != null);
    // A hierarchical ref-des folds into a legal identifier for both spellings.
    try testing.expect(std.mem.indexOf(u8, text, "#define USB_J2_USB_DP_PIN \"1\"") != null);
    try testing.expect(std.mem.indexOf(u8, text, "} usb_j2_pinmap[] = {") != null);
    try testing.expect(std.mem.indexOf(u8, text, "} u1_pinmap[] = {") != null);
    // The four declared columns carry the pad, function, net and group, with a
    // quote inside the group label escaped rather than closing the literal.
    try testing.expect(std.mem.indexOf(u8, text, "{ \"A3\", \"PA3\", \"usb/DP\", \"USB 2.0 HS \\\"PHY\\\"\" },") != null);
    // …and the provenance the columns have no room for rides in the comment.
    try testing.expect(std.mem.indexOf(u8, text, "protocol USB2.0-HS|SPI alt USB1_OTG_HS_DP/USB1_OTG_HS_DP_ALT */") != null);
}

// spec: export-pinmap - the JSON pin map carries the same rows with the alternates as an array and the build id alone on its own line
test "the JSON pin map carries every row and parses" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = try render(arena, fixture(), .json);
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, text, .{});
    const parts = root.object.get("parts").?.array.items;
    try testing.expectEqual(@as(usize, 2), parts.len);
    try testing.expectEqualStrings("demo-board", root.object.get("design").?.string);
    try testing.expectEqualStrings("U1", parts[0].object.get("ref").?.string);
    try testing.expectEqualStrings("stm32", parts[0].object.get("name").?.string);
    const pads = parts[0].object.get("pads").?.array.items;
    try testing.expectEqual(@as(usize, 3), pads.len);
    try testing.expectEqualStrings("usb/DP", pads[2].object.get("net").?.string);
    try testing.expectEqualStrings("USB", pads[2].object.get("section").?.string);
    try testing.expectEqualStrings("USB2.0-HS|SPI", pads[2].object.get("protocols").?.string);
    try testing.expectEqual(@as(usize, 2), pads[2].object.get("alternates").?.array.items.len);
    // The build id is on its own line, which is what makes the documented
    // `diff -I '"build_id"'` comparison possible.
    try testing.expect(std.mem.indexOf(u8, text, "\n  \"build_id\": \"test\",\n") != null);
}

// spec: export-pinmap - two renders of one pin map are byte-identical in both formats, so a differential comparison sees only real changes
test "a pin map renders identically twice in both formats" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings(try render(arena, fixture(), .c), try render(arena, fixture(), .c));
    try testing.expectEqualStrings(try render(arena, fixture(), .json), try render(arena, fixture(), .json));
}

// spec: export-pinmap - the exported C header is accepted by a C99 compiler when one is on PATH, and the check reports no_compiler rather than failing when none is
test "the exported C header compiles as C99" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = try render(arena, fixture(), .c);
    const verdict = try checkCSyntax(arena, text);
    // `rejected` is the only failing verdict: a machine with no C compiler
    // skips the claim rather than turning a missing toolchain into a red test.
    try testing.expect(verdict != .rejected);
}

// spec: export-pinmap - a part with no readable pinout, no connected pad, or outside the selection is left out of the pin map
test "part selection covers the hub classes, an explicit ref list and a hierarchical name" {
    const hub = flat_netlist.FlatInstance{
        .ref_des = "U1",
        .component = "stm32",
        .origin_key = "stm32",
        .value = "",
        .footprint = "",
        .properties = &.{},
        .uuid = "",
    };
    const passive = flat_netlist.FlatInstance{
        .ref_des = "ldo/C7",
        .component = "cap-0402",
        .origin_key = "",
        .value = "100nF",
        .footprint = "",
        .properties = &.{},
        .uuid = "",
    };
    // Without a ref list the hub classes are the selection and a passive is not.
    try testing.expect(selects(&.{}, hub));
    try testing.expect(!selects(&.{}, passive));
    // With one, the named part is exported whatever its class — by flattened
    // ref-des, by its leaf, or by the source name the design author wrote.
    try testing.expect(selects(&.{"ldo/C7"}, passive));
    try testing.expect(selects(&.{"C7"}, passive));
    try testing.expect(selects(&.{"stm32"}, hub));
    try testing.expect(!selects(&.{"U2"}, hub));
    // A sub-block hub is still a hub: the class letter is the LEAF's.
    try testing.expect(isHub("usb/J2"));
    try testing.expect(!isHub("usb/"));
}

/// The `inputSchema` object the tool catalog declares for `name`, or null when
/// the catalog carries no such tool.
fn declaredSchema(arena: std.mem.Allocator, name: []const u8) !?std.json.ObjectMap {
    const mcp_tools = @import("serve/mcp_tools.zig");
    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, mcp_tools.tools_list_result, .{});
    for (root.object.get("tools").?.array.items) |entry| {
        if (std.mem.eql(u8, entry.object.get("name").?.string, name))
            return entry.object.get("inputSchema").?.object;
    }
    return null;
}

// spec: export-pinmap - the exporter is registered as a read-only structured tool and its declared schema names every argument the handler reads
test "export_pinmap is a registered read-only tool with a round-tripping schema" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const mcp_tools = @import("serve/mcp_tools.zig");

    try testing.expect(mcp_tools.isKnownTool("export_pinmap"));
    // It writes no project file — the CLI's `--output` is the caller's own path
    // — so it is not gated as a mutation and starts no autocommit session.
    try testing.expect(!mcp_tools.isMutationTool("export_pinmap"));

    const schema = (try declaredSchema(arena, "export_pinmap")).?;
    const props = schema.get("properties").?.object;
    // Every argument the handler reads is declared, and the schema is closed —
    // an undeclared argument is one a strict client could not send at all.
    try testing.expectEqualStrings("string", props.get("name").?.object.get("type").?.string);
    try testing.expectEqualStrings("string", props.get("format").?.object.get("type").?.string);
    try testing.expectEqualStrings("string", props.get("refs").?.object.get("items").?.object.get("type").?.string);
    try testing.expect(!schema.get("additionalProperties").?.bool);
    const required = schema.get("required").?.array.items;
    try testing.expectEqual(@as(usize, 1), required.len);
    try testing.expectEqualStrings("name", required[0].string);
}

// spec: export-pinmap - the tool refuses a missing design name and an unknown format with an ok:false error line rather than exporting something else
test "the pinmap tool refuses an unusable request" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.ArrayList(u8) = .empty;
    try testing.expect(!try tool(arena, ".", null, &out));
    try testing.expect(std.mem.indexOf(u8, out.items, "error: name is required") != null);

    out.clearRetainingCapacity();
    const bad_format = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"name\":\"x\",\"format\":\"rust\"}", .{});
    try testing.expect(!try tool(arena, ".", bad_format, &out));
    try testing.expect(std.mem.indexOf(u8, out.items, "error: format must be") != null);

    // A design that does not exist is named in the refusal rather than yielding
    // an empty export a caller could mistake for a design with no pins.
    out.clearRetainingCapacity();
    const missing = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"name\":\"no-such-design\"}", .{});
    try testing.expect(!try tool(arena, "/nonexistent-netlisp-project", missing, &out));
    try testing.expect(std.mem.indexOf(u8, out.items, "no-such-design") != null);
}
