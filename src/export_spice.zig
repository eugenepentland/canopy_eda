//! `netlisp export-spice` — a flattened SPICE netlist for a design.
//!
//! The board already carries every connection a simulator needs; what stops a
//! designer opening it in ngspice is transcription. This writes the deck: one
//! element line per part, ground-class nets on node 0, one `.subckt` stub per
//! integrated circuit, and a header that says exactly which parts of a real
//! simulation are still missing.
//!
//!   netlisp export-spice --project-dir <dir> [--output <file>] <design>
//!
//! It is READ-ONLY: it evaluates the design through the same seam the PCB page
//! reads (`pcb_layout_page.resolveBlock`), flattens the hierarchy with
//! `flat_netlist.flattenAndMergeNets`, and writes to `--output` or stdout. It
//! mints no id, edits no source, and starts no server.
//!
//! ## What the deck is and is not
//!
//! R / C / L become `R` / `C` / `L` lines carrying the value parsed out of the
//! authored string by `req_checks.parseValueFor`, the project's one reader of
//! those spellings — which matters because SPICE reads `1M` as a MILLI, so the
//! authored text can never be passed through verbatim. A capacitance and an
//! inductance keep the micro unit that reader works in and take SPICE's own `u`
//! scale factor, rather than being multiplied into farads and henries where
//! `10uF` would come out 9.999999999999999e-6. A value
//! that does not parse becomes a `{<REF>_VALUE}` parameter placeholder with the
//! raw string in a comment beside it. A ferrite bead is a DC short, so it
//! becomes an `R` at the `dcr-max` its BOM part declares, or a commented
//! placeholder when nothing declares one. Diodes and transistors emit `D` / `Q`
//! / `M` lines naming a `<MPN>_MODEL` placeholder, with the matching `.model`
//! card written as a COMMENT. Everything else — every IC and connector —
//! becomes an `X` line into an EMPTY `.subckt` stub whose pin list is real.
//!
//! So the deck LOADS once models and bodies are supplied, and it does not
//! simulate before that. It also carries no parasitics of any kind: no trace
//! R/L/C, no pad capacitance, no coupling, and an ideal capacitor with no ESR
//! or ESL. The header comment says all of this in the file itself.
//!
//! ## Determinism
//!
//! Nets, parts and subcircuits are all sorted before any name is assigned, so
//! the sanitised spellings (and the `_2` suffixes a name collision forces) are
//! stable. The only per-run value is the build id on a `*#` header line:
//!
//!   diff -I '^\*#' base.cir cand.cir
//!
//! compares the netlist alone. Per-part commentary uses a plain `* ` so it
//! stays inside the comparison.

const std = @import("std");
const build_id = @import("build_id.zig");
const env_mod = @import("eval/env.zig");
const erc = @import("erc.zig");
const exit = @import("exit.zig");
const flat_netlist = @import("flat_netlist.zig");
const infra_fs = @import("infra/fs.zig");
const na = @import("eval/net_analysis.zig");
const names = @import("export_names.zig");
const net_name = @import("net_name.zig");
const req_checks = @import("req_checks.zig");
const modules_mod = @import("serve/modules.zig");
const pcb_layout_page = @import("serve/pcb_layout_page.zig");
const Evaluator = @import("eval/evaluator.zig").Evaluator;

/// Everything the exporter can fail with: allocation, rendering, and (only for
/// `--output`) the file write. A design that does not resolve and a run naming
/// no design are their own errors so the CLI can print a usage line.
pub const SpiceError = std.mem.Allocator.Error || std.Io.Writer.Error ||
    std.Io.Dir.WriteFileError || error{ SpiceUsage, UnresolvedDesign };

/// The prefix on every header-comment line. A plain `*` starts an ordinary
/// SPICE comment and is used for the per-part commentary, which must stay
/// inside a differential comparison; only these lines are ignorable.
const header_mark = "*#";

/// The SPICE node every ground-class net maps to.
const ground_node = "0";

/// SPICE's own micro scale factor. A capacitance and an inductance are written
/// in the micro unit `req_checks` parses them in and given this suffix, rather
/// than multiplied into farads and henries: `10uF * 1e-6` is 9.999999999999999e-6
/// in binary floating point, and a deck should not carry that.
const micro_suffix = "u";

/// The BOM property a ferrite bead's DC resistance is authored on.
const dcr_property = "dcr-max";

/// What a part becomes in the deck.
const Class = enum {
    resistor,
    capacitor,
    inductor,
    /// A DC short with a declared winding resistance — emitted as an `R`.
    ferrite,
    diode,
    /// Three terminals: a BJT (`Q`) or, when the part reads as a field-effect
    /// device, a MOSFET (`M`).
    transistor,
    /// An `X` line into a `.subckt` stub: every IC, connector and module.
    subcircuit,
    /// A test point, fiducial or mounting hole: real copper, no circuit element.
    mechanical,
};

/// Parsed `export-spice` argument vector.
const Args = struct {
    project_dir: []const u8 = "projects/designs",
    name: []const u8 = "",
    output: ?[]const u8 = null,
};

/// Parse the CLI argument vector. An unknown flag, a flag with no value, a
/// missing design and a second positional are all usage errors.
fn parseArgs(args: []const []const u8) SpiceError!Args {
    var out: Args = .{};
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const a = args[i];
        if (!std.mem.startsWith(u8, a, "--")) {
            if (out.name.len != 0) return error.SpiceUsage;
            out.name = a;
            continue;
        }
        if (i + 1 >= args.len) return error.SpiceUsage;
        i += 1;
        if (std.mem.eql(u8, a, "--project-dir")) {
            out.project_dir = args[i];
        } else if (std.mem.eql(u8, a, "--output")) {
            out.output = args[i];
        } else return error.SpiceUsage;
    }
    if (out.name.len == 0) return error.SpiceUsage;
    return out;
}

// ── The exported model ──────────────────────────────────────────────────────

/// One part as it will be written.
const Element = struct {
    /// The flattened `sub-block/REF` reference designator.
    ref: []const u8,
    /// The unique SPICE element name, already carrying its class letter.
    spice: []const u8,
    class: Class,
    component: []const u8,
    /// The authored value string, kept verbatim for the comment.
    value: []const u8,
    /// The value in the unit its class is parsed in — ohms for a resistor and a
    /// bead, microfarads and microhenries for a capacitor and an inductor,
    /// which `valueSuffix` spells with SPICE's own `u` — or null when the
    /// authored string did not parse.
    magnitude: ?f64,
    /// The `<MPN>_MODEL` placeholder a D/Q/M line names, or "".
    model: []const u8,
    /// The `.subckt` an `X` line enters, or "".
    subckt: []const u8,
    dnp: bool,
    /// The nodes, in pad order.
    nodes: []const []const u8,
    /// The reason this part could not be written as its class would suggest,
    /// or "" when it could. Printed as a `* ` note beside the element.
    note: []const u8,
};

/// One `.subckt` stub: the pin list is the design's own, the body is empty.
const Subckt = struct {
    name: []const u8,
    component: []const u8,
    /// Pad ids in natural order.
    pads: []const []const u8,
    /// The port name each pad is exposed under, parallel to `pads`.
    ports: []const []const u8,
};

/// A `.model` card the deck references but cannot supply.
const ModelStub = struct {
    name: []const u8,
    /// The SPICE device-type word the card would carry (`D`, `NPN`, `NMOS`).
    kind: []const u8,
    /// The parts that reference it, joined with `, `.
    used_by: []const u8,
};

/// A whole deck, ready to render.
const Deck = struct {
    design: []const u8,
    net_count: usize,
    elements: []const Element,
    subckts: []const Subckt,
    models: []const ModelStub,
    /// Every net whose sanitised spelling had to be moved off a collision,
    /// rendered as `<design name> -> <spice name>` lines.
    renames: []const []const u8,
};

// ── Classification ──────────────────────────────────────────────────────────

/// The alphabetic prefix of a flattened ref-des (`ldo/C17` → `C`, `TP3` → `TP`).
fn refClassPrefix(ref: []const u8) []const u8 {
    const local = net_name.leaf(ref);
    var i: usize = 0;
    while (i < local.len and std.ascii.isAlphabetic(local[i])) i += 1;
    return local[0..i];
}

/// What a part becomes, from its component family first and its ref-des class
/// second.
///
/// The family has to win: this project's ref-des assigner gives a ferrite bead
/// an `L`, because a bead and an inductor share the `generic-ind` symbol — so
/// judging on the letter alone would emit a 600-ohm bead as a 600-henry
/// inductor. `pad_count` decides the ambiguous cases (a dual diode in a
/// three-pad package is a subcircuit, not a `D`).
fn classify(component: []const u8, ref: []const u8, pad_count: usize) Class {
    if (containsFold(component, "ferrite")) return .ferrite;
    const prefix = refClassPrefix(ref);
    if (eqlAny(prefix, &.{ "TP", "FID", "MH", "MP", "H" })) return .mechanical;
    if (eqlAny(prefix, &.{"R"})) return .resistor;
    if (eqlAny(prefix, &.{"C"})) return .capacitor;
    if (eqlAny(prefix, &.{"L"})) return .inductor;
    if (eqlAny(prefix, &.{"FB"})) return .ferrite;
    if (eqlAny(prefix, &.{"D"})) return if (pad_count == 2) .diode else .subcircuit;
    if (eqlAny(prefix, &.{"Q"})) return transistorClass(pad_count);
    return .subcircuit;
}

/// A `Q`-class part with two pads is a diode-connected package, with three a
/// transistor, and with any other count a subcircuit.
fn transistorClass(pad_count: usize) Class {
    if (pad_count == 2) return .diode;
    if (pad_count == 3) return .transistor;
    return .subcircuit;
}

/// Whether `word` equals any of `list`.
fn eqlAny(word: []const u8, list: []const []const u8) bool {
    for (list) |candidate| {
        if (std.mem.eql(u8, word, candidate)) return true;
    }
    return false;
}

/// Case-insensitive substring test.
fn containsFold(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// The SPICE class letter an element line must start with.
fn classLetter(class: Class) u8 {
    return switch (class) {
        .resistor, .ferrite => 'R',
        .capacitor => 'C',
        .inductor => 'L',
        .diode => 'D',
        .transistor => 'Q',
        // A mechanical part is never written as an element, so this letter is
        // never spelled into a deck; it exists to keep the mapping total.
        .subcircuit, .mechanical => 'X',
    };
}

/// How many nodes an element line carries.
fn terminalCount(class: Class) usize {
    return switch (class) {
        .resistor, .capacitor, .inductor, .ferrite, .diode => 2,
        .transistor => 3,
        .subcircuit, .mechanical => 0,
    };
}

/// A named property's value, or "".
fn property(inst: flat_netlist.FlatInstance, key: []const u8) []const u8 {
    for (inst.properties) |p| {
        if (std.mem.eql(u8, p.key, key)) return p.value;
    }
    return "";
}

/// The part number a model placeholder is named after: the resolved `mpn`,
/// else the component family.
fn modelSource(inst: flat_netlist.FlatInstance) []const u8 {
    const mpn = property(inst, "mpn");
    return if (mpn.len != 0) mpn else inst.component;
}

/// Whether a three-terminal part reads as a field-effect device, which decides
/// `M` versus `Q`. Judged on the component family and the resolved part number,
/// the only two places the design says what the part is.
fn isFieldEffect(inst: flat_netlist.FlatInstance) bool {
    return containsFold(inst.component, "fet") or containsFold(inst.component, "mos") or
        containsFold(modelSource(inst), "fet") or containsFold(modelSource(inst), "mos");
}

/// The SPICE value of a passive, in the base unit, or null when the authored
/// string is not a value of that class.
fn magnitudeOf(class: Class, inst: flat_netlist.FlatInstance) ?f64 {
    const token = magnitudeToken(inst.value);
    return switch (class) {
        .resistor => req_checks.parseValueFor(.R, token),
        .capacitor => req_checks.parseValueFor(.C, token),
        .inductor => req_checks.parseValueFor(.L, token),
        // A bead's own value is its impedance at a test frequency, which is not
        // a DC element at all; the winding resistance is the DC model.
        .ferrite => req_checks.parseOhms(magnitudeToken(property(inst, dcr_property))),
        else => null,
    };
}

/// The magnitude of an authored value: its first whitespace-delimited word.
///
/// `"1nF 2kV"` and `"10uF 25V"` are a capacitance followed by a voltage RATING,
/// and the whole string parses as nothing — so without this the corpus's rated
/// capacitors would all come out as `{<REF>_VALUE}` placeholders. The
/// first-token rule is not invented here: `eval/value_kind.magnitudeSuffix`
/// already reads exactly the same word when it classifies a value's kind.
fn magnitudeToken(value: []const u8) []const u8 {
    const cut = std.mem.indexOfAny(u8, value, " \t") orelse return value;
    return value[0..cut];
}

/// The SPICE scale factor a class's magnitude carries: none for the ohms a
/// resistor and a bead are parsed in, `u` for the microfarads and microhenries
/// a capacitor and an inductor are.
fn valueSuffix(class: Class) []const u8 {
    return switch (class) {
        .capacitor, .inductor => micro_suffix,
        else => "",
    };
}

// ── Collection ──────────────────────────────────────────────────────────────

/// The per-component pad set every instance of that component is written
/// against, so one `.subckt` serves them all.
const ComponentPads = struct {
    pads: []const []const u8,
    /// The pinout's function name for each pad, parallel to `pads`; "" where
    /// the part has no `lib/pinouts` entry or the entry names that pad nothing.
    functions: []const []const u8,
};

/// Build the whole deck for one resolved block.
fn buildDeck(
    arena: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    block: *env_mod.DesignBlock,
) std.mem.Allocator.Error!Deck {
    var nets: std.ArrayList(flat_netlist.FlatNet) = .empty;
    try flat_netlist.flattenAndMergeNets(arena, block, &nets);
    std.mem.sort(flat_netlist.FlatNet, nets.items, {}, lessNet);

    var nodes: names.Table = .{};
    var renames: std.ArrayList([]const u8) = .empty;
    var pad_nodes: std.StringHashMapUnmanaged([]const u8) = .empty;
    var pads_by_ref: PadsByRef = .empty;
    try indexNodes(arena, nets.items, &nodes, &pad_nodes, &pads_by_ref, &renames);

    var instances: std.ArrayList(flat_netlist.FlatInstance) = .empty;
    try flat_netlist.collectInstances(arena, block, "", &instances);
    std.mem.sort(flat_netlist.FlatInstance, instances.items, {}, lessInstance);

    var pads_by_component: std.StringHashMapUnmanaged(ComponentPads) = .empty;
    try indexComponentPads(arena, project_dir, instances.items, &pads_by_ref, &pads_by_component);

    var element_names: names.Table = .{};
    var subckt_names: names.Table = .{};
    var subckts: std.ArrayList(Subckt) = .empty;
    var models: std.StringHashMapUnmanaged(ModelStub) = .empty;
    var elements: std.ArrayList(Element) = .empty;
    for (instances.items) |inst| {
        const built = try buildElement(arena, .{
            .inst = inst,
            .pads = pads_by_component.get(inst.component) orelse ComponentPads{ .pads = &.{}, .functions = &.{} },
            .pad_nodes = &pad_nodes,
            .nodes = &nodes,
            .element_names = &element_names,
            .subckt_names = &subckt_names,
            .subckts = &subckts,
            .models = &models,
        });
        try elements.append(arena, built);
    }
    std.mem.sort(Subckt, subckts.items, {}, lessSubckt);
    return .{
        .design = name,
        .net_count = nets.items.len,
        .elements = elements.items,
        .subckts = subckts.items,
        .models = try sortedModels(arena, &models),
        .renames = renames.items,
    };
}

/// Order flattened nets by name.
fn lessNet(_: void, a: flat_netlist.FlatNet, b: flat_netlist.FlatNet) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

/// Order flattened instances by ref-des.
fn lessInstance(_: void, a: flat_netlist.FlatInstance, b: flat_netlist.FlatInstance) bool {
    return std.mem.order(u8, a.ref_des, b.ref_des) == .lt;
}

/// Order subcircuit stubs by name.
fn lessSubckt(_: void, a: Subckt, b: Subckt) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

/// `"<ref>|<pad>"`, the key the pad→node index uses.
fn padKey(arena: std.mem.Allocator, ref: []const u8, pad: []const u8) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(arena, "{s}|{s}", .{ ref, pad });
}

/// Assign a SPICE node to every net and index every pad onto it.
///
/// Ground-class nets — judged by `net_analysis.isGroundName`, the project's one
/// ground predicate, over the base name so a per-pin bypass stub `GND.U1.A3`
/// is still ground — go to node 0 without entering the name table, so they can
/// never be renamed out from under the deck.
fn indexNodes(
    arena: std.mem.Allocator,
    nets: []const flat_netlist.FlatNet,
    table: *names.Table,
    pad_nodes: *std.StringHashMapUnmanaged([]const u8),
    pads_by_ref: *PadsByRef,
    renames: *std.ArrayList([]const u8),
) std.mem.Allocator.Error!void {
    for (nets) |net| {
        const node = try nodeFor(arena, net.name, table, renames);
        try indexOneNet(arena, net, node, pad_nodes, pads_by_ref);
    }
}

/// Every wired pad of one part, in the order the sorted nets named them.
const PadsByRef = std.StringHashMapUnmanaged(std.ArrayList([]const u8));

/// Record one net's pads against their node and their part. Both indexes are
/// built in this single pass because the alternative — rescanning the pad index
/// once per part — is quadratic on a board with thousands of pads.
///
// twin-drift-ok: see the note on `export_pinmap.indexOneNet` — this one indexes
// the SPICE node a net maps to (ground already collapsed onto `0`), that one
// the design's own net name.
fn indexOneNet(
    arena: std.mem.Allocator,
    net: flat_netlist.FlatNet,
    node: []const u8,
    pad_nodes: *std.StringHashMapUnmanaged([]const u8),
    pads_by_ref: *PadsByRef,
) std.mem.Allocator.Error!void {
    for (net.pins) |pin| {
        const gop = try pad_nodes.getOrPut(arena, try padKey(arena, pin.ref_des, pin.pin));
        if (gop.found_existing) continue;
        gop.value_ptr.* = node;
        const by_ref = try pads_by_ref.getOrPut(arena, pin.ref_des);
        if (!by_ref.found_existing) by_ref.value_ptr.* = .empty;
        try by_ref.value_ptr.append(arena, pin.pin);
    }
}

/// The node one net maps to, recording any collision rename.
fn nodeFor(
    arena: std.mem.Allocator,
    raw: []const u8,
    table: *names.Table,
    renames: *std.ArrayList([]const u8),
) std.mem.Allocator.Error![]const u8 {
    if (na.isGroundName(net_name.leaf(na.baseNetName(raw)))) return ground_node;
    const assigned = try table.unique(arena, raw, try names.sanitize(arena, .upper, raw));
    if (assigned.collided_with) |other| {
        try renames.append(arena, try std.fmt.allocPrint(arena, "{s} -> {s} (folds onto {s})", .{
            raw, assigned.name, other,
        }));
    }
    return assigned.name;
}

/// Index each component family to the pad set every instance of it is written
/// against: the union of the pads this design actually wired, in natural order.
///
/// The union rather than the pinout's full pad list, because a `.subckt` whose
/// ports are the pads the board uses is the one every `X` line can be written
/// against without inventing nodes for pads no design touched — and because
/// `erc.loadPinoutMap` deliberately keys a pad BOTH by its id and by its
/// primary function name, so its key set is not a pad list.
fn indexComponentPads(
    arena: std.mem.Allocator,
    project_dir: []const u8,
    instances: []const flat_netlist.FlatInstance,
    pads_by_ref: *const PadsByRef,
    out: *std.StringHashMapUnmanaged(ComponentPads),
) std.mem.Allocator.Error!void {
    var unioned: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    for (instances) |inst| try unionPads(arena, inst, pads_by_ref, &unioned, &seen);

    for (instances) |inst| {
        if (out.contains(inst.component)) continue;
        const list = unioned.get(inst.component) orelse continue;
        std.mem.sort([]const u8, list.items, {}, names.padLessThan);
        try out.put(arena, inst.component, .{
            .pads = list.items,
            .functions = try padFunctions(arena, project_dir, inst, list.items),
        });
    }
}

/// Fold one instance's wired pads into its component's pad set.
fn unionPads(
    arena: std.mem.Allocator,
    inst: flat_netlist.FlatInstance,
    pads_by_ref: *const PadsByRef,
    unioned: *std.StringHashMapUnmanaged(std.ArrayList([]const u8)),
    seen: *std.StringHashMapUnmanaged(void),
) std.mem.Allocator.Error!void {
    const gop = try unioned.getOrPut(arena, inst.component);
    if (!gop.found_existing) gop.value_ptr.* = .empty;
    const pads = pads_by_ref.get(inst.ref_des) orelse return;
    for (pads.items) |pad| {
        const mark = try std.fmt.allocPrint(arena, "{s}|{s}", .{ inst.component, pad });
        if ((try seen.getOrPut(arena, mark)).found_existing) continue;
        try gop.value_ptr.append(arena, pad);
    }
}

/// The pinout's function name for each pad, or "" throughout when the part has
/// no readable `lib/pinouts` entry.
fn padFunctions(
    arena: std.mem.Allocator,
    project_dir: []const u8,
    inst: flat_netlist.FlatInstance,
    pads: []const []const u8,
) std.mem.Allocator.Error![]const []const u8 {
    const out = try arena.alloc([]const u8, pads.len);
    const pinout = readPinout(arena, project_dir, inst);
    for (pads, out) |pad, *fn_name| {
        fn_name.* = if (pinout) |map| (if (map.get(pad)) |e| e.primary else "") else "";
    }
    return out;
}

/// The instance's `lib/pinouts` entry, or null when there is none to read.
fn readPinout(
    arena: std.mem.Allocator,
    project_dir: []const u8,
    inst: flat_netlist.FlatInstance,
) ?std.StringHashMapUnmanaged(erc.PinoutEntry) {
    const key = if (inst.pinout.len > 0) inst.pinout else if (inst.symbol.len > 0) inst.symbol else inst.component;
    if (key.len == 0) return null;
    return erc.loadPinoutMap(arena, project_dir, key);
}

/// Everything `buildElement` needs, gathered so the function keeps a signature
/// under the parameter cap.
const ElementRequest = struct {
    inst: flat_netlist.FlatInstance,
    pads: ComponentPads,
    pad_nodes: *const std.StringHashMapUnmanaged([]const u8),
    nodes: *names.Table,
    element_names: *names.Table,
    subckt_names: *names.Table,
    subckts: *std.ArrayList(Subckt),
    models: *std.StringHashMapUnmanaged(ModelStub),
};

/// Turn one flattened instance into the element line it will be written as,
/// registering the `.subckt` or `.model` stub it needs along the way.
fn buildElement(arena: std.mem.Allocator, req: ElementRequest) std.mem.Allocator.Error!Element {
    const class = classify(req.inst.component, req.inst.ref_des, req.pads.pads.len);
    const wanted = terminalCount(class);
    // Every element needs at least one wired pad, and a class with a fixed
    // terminal count needs all of them; a part short of that is reported as a
    // comment rather than written with an invented node.
    const need = @max(wanted, 1);
    const effective: Class = if (req.pads.pads.len < need) .mechanical else class;
    const used = if (effective == .subcircuit or effective == .mechanical)
        req.pads.pads
    else
        req.pads.pads[0..wanted];
    return .{
        .ref = req.inst.ref_des,
        .spice = try elementName(arena, effective, req.inst.ref_des, req.element_names),
        .class = effective,
        .component = req.inst.component,
        .value = req.inst.value,
        .magnitude = magnitudeOf(effective, req.inst),
        .model = try registerModel(arena, effective, req.inst, req.models),
        .subckt = if (effective == .subcircuit) try registerSubckt(arena, req) else "",
        .dnp = req.inst.dnp,
        .nodes = try nodeList(arena, req, used),
        .note = elementNote(class, effective, req.pads.pads.len, need),
    };
}

/// Why an element could not be written as its class would suggest.
fn elementNote(class: Class, effective: Class, have: usize, wanted: usize) []const u8 {
    if (class == effective) return "";
    if (have < wanted) return "fewer wired pads than the element needs — no element emitted";
    return "";
}

/// The unique SPICE element name. A ref-des that already begins with its class
/// letter is used as it stands (`R12` → `R12`); anything else — a sub-block
/// path, a `FB` bead that must be written as an `R` — is prefixed, so the name
/// always declares the element's own class the way SPICE requires.
fn elementName(
    arena: std.mem.Allocator,
    class: Class,
    ref: []const u8,
    table: *names.Table,
) std.mem.Allocator.Error![]const u8 {
    const folded = try names.sanitize(arena, .upper, ref);
    const letter = classLetter(class);
    const candidate = if (folded[0] == letter)
        folded
    else
        try std.fmt.allocPrint(arena, "{c}{s}", .{ letter, folded });
    return (try table.unique(arena, ref, candidate)).name;
}

/// The node each used pad sits on, with an unwired pad given its own dangling
/// node rather than being silently shorted to whatever came before it.
fn nodeList(
    arena: std.mem.Allocator,
    req: ElementRequest,
    pads: []const []const u8,
) std.mem.Allocator.Error![]const []const u8 {
    const out = try arena.alloc([]const u8, pads.len);
    for (pads, out) |pad, *node| {
        if (req.pad_nodes.get(try padKey(arena, req.inst.ref_des, pad))) |wired| {
            node.* = wired;
            continue;
        }
        const raw = try std.fmt.allocPrint(arena, "{s}|{s}|nc", .{ req.inst.ref_des, pad });
        const candidate = try names.sanitize(arena, .upper, try std.fmt.allocPrint(arena, "{s}_{s}_NC", .{
            req.inst.ref_des, pad,
        }));
        node.* = (try req.nodes.unique(arena, raw, candidate)).name;
    }
    return out;
}

/// Register (once) the `.subckt` stub this instance's component needs and
/// return its name.
fn registerSubckt(arena: std.mem.Allocator, req: ElementRequest) std.mem.Allocator.Error![]const u8 {
    const assigned = try req.subckt_names.unique(
        arena,
        req.inst.component,
        try names.sanitize(arena, .upper, req.inst.component),
    );
    // `unique` answers stably, so a component asked for twice is registered
    // once: the second instance sees its own name already taken.
    for (req.subckts.items) |existing| {
        if (std.mem.eql(u8, existing.name, assigned.name)) return assigned.name;
    }
    try req.subckts.append(arena, .{
        .name = assigned.name,
        .component = req.inst.component,
        .pads = req.pads.pads,
        .ports = try portNames(arena, req.pads),
    });
    return assigned.name;
}

/// One port name per pad: the pinout's function name where there is one, else
/// `P<pad>`, uniquified within this subcircuit (a part with nine `VSS` pads
/// cannot declare nine ports called VSS).
fn portNames(arena: std.mem.Allocator, pads: ComponentPads) std.mem.Allocator.Error![]const []const u8 {
    var table: names.Table = .{};
    const out = try arena.alloc([]const u8, pads.pads.len);
    for (pads.pads, pads.functions, out) |pad, fn_name, *port| {
        const raw = if (fn_name.len != 0) fn_name else try std.fmt.allocPrint(arena, "P{s}", .{pad});
        port.* = (try table.unique(arena, pad, try names.sanitize(arena, .upper, raw))).name;
    }
    return out;
}

/// Register (once) the `.model` card a D/Q/M line references and return its
/// placeholder name. Returns "" for every class that needs no model.
fn registerModel(
    arena: std.mem.Allocator,
    class: Class,
    inst: flat_netlist.FlatInstance,
    models: *std.StringHashMapUnmanaged(ModelStub),
) std.mem.Allocator.Error![]const u8 {
    if (class != .diode and class != .transistor) return "";
    const name = try std.fmt.allocPrint(arena, "{s}_MODEL", .{
        try names.sanitize(arena, .upper, modelSource(inst)),
    });
    const kind = modelKind(class, inst);
    const gop = try models.getOrPut(arena, name);
    if (!gop.found_existing) {
        gop.value_ptr.* = .{ .name = name, .kind = kind, .used_by = inst.ref_des };
        return name;
    }
    gop.value_ptr.used_by = try std.fmt.allocPrint(arena, "{s}, {s}", .{ gop.value_ptr.used_by, inst.ref_des });
    return name;
}

/// The SPICE device-type word a stub card would carry. `NPN` and `NMOS` are
/// GUESSES — nothing in the design says which polarity the part is — which is
/// exactly why the card is written as a comment for a human to complete.
fn modelKind(class: Class, inst: flat_netlist.FlatInstance) []const u8 {
    if (class == .diode) return "D";
    return if (isFieldEffect(inst)) "NMOS" else "NPN";
}

/// The registered model stubs in name order.
fn sortedModels(
    arena: std.mem.Allocator,
    models: *std.StringHashMapUnmanaged(ModelStub),
) std.mem.Allocator.Error![]const ModelStub {
    const out = try arena.alloc(ModelStub, models.count());
    var it = models.valueIterator();
    var i: usize = 0;
    while (it.next()) |stub| : (i += 1) out[i] = stub.*;
    std.mem.sort(ModelStub, out, {}, lessModel);
    return out;
}

/// Order model stubs by name.
fn lessModel(_: void, a: ModelStub, b: ModelStub) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

// ── Rendering ───────────────────────────────────────────────────────────────

/// Render the whole deck.
fn render(arena: std.mem.Allocator, deck: Deck) SpiceError![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(arena);
    const w = &aw.writer;
    try writeHeader(w, deck);
    for (deck.renames) |line| try w.print("* net renamed: {s}\n", .{line});
    for (deck.elements) |element| try writeElement(w, element);
    try writeModels(w, deck);
    try writeSubckts(w, deck);
    try w.writeAll(".end\n");
    return aw.written();
}

/// The `*#`-marked header: the identity, the counts, and the limits.
fn writeHeader(w: *std.Io.Writer, deck: Deck) std.Io.Writer.Error!void {
    try w.print("{s} netlisp export-spice — flattened SPICE netlist for {s}\n", .{ header_mark, deck.design });
    try w.print("{s} build: {s}\n", .{ header_mark, build_id.current() });
    try w.print("{s} nets: {d}, parts: {d}, subcircuit stubs: {d}, model stubs: {d}\n", .{
        header_mark, deck.net_count, deck.elements.len, deck.subckts.len, deck.models.len,
    });
    try w.print("{s}\n", .{header_mark});
    try w.writeAll(
        \\*# LIMITS — this deck does not simulate as written:
        \\*#   - every IC is an EMPTY .subckt stub: the pin list is the design's,
        \\*#     the body is not there;
        \\*#   - no device models: each D/Q/M line names a <MPN>_MODEL placeholder
        \\*#     and its .model card is written as a COMMENT to be completed;
        \\*#   - no parasitics of any kind: no trace R/L/C, no pad capacitance, no
        \\*#     coupling, and an ideal capacitor with no ESR or ESL;
        \\*#   - a value the reader could not parse becomes a {<REF>_VALUE}
        \\*#     parameter with the authored string in the comment beside it;
        \\*#   - a 3-terminal device's node order is its PAD order, so the model
        \\*#     supplied for it must be pinned the same way;
        \\*#   - DNP parts are written as comments.
        \\*# Ground-class nets map to node 0; every other net name is folded to
        \\*# [A-Z0-9_] and a fold collision is reported above as a rename.
        \\*# Two exports compare with: diff -I '^\*#'
        \\*
        \\
    );
}

/// One element: its line, or the comment that stands in for it.
fn writeElement(w: *std.Io.Writer, element: Element) SpiceError!void {
    if (element.note.len != 0) try w.print("* {s} ({s}): {s}\n", .{ element.ref, element.component, element.note });
    if (element.class == .mechanical) {
        try w.print("* {s} ({s}): no SPICE element for this class\n", .{ element.ref, element.component });
        return;
    }
    try writeValueNote(w, element);
    if (element.dnp) {
        try w.writeAll("* DNP — not populated:\n* ");
    }
    try w.print("{s}", .{element.spice});
    for (element.nodes) |node| try w.print(" {s}", .{node});
    try writeTail(w, element);
    try w.writeAll("\n");
}

/// The `* ` note a value that could not be read leaves beside its element.
fn writeValueNote(w: *std.Io.Writer, element: Element) std.Io.Writer.Error!void {
    if (element.magnitude != null) return;
    if (element.class == .ferrite) {
        try w.print("* {s}: no {s} declared for this bead — supply {{{s}_VALUE}} (its DC resistance)\n", .{
            element.ref, dcr_property, element.spice,
        });
        return;
    }
    if (!needsValue(element.class)) return;
    try w.print("* {s}: value \"{s}\" is not readable as a {s} — supply {{{s}_VALUE}}\n", .{
        element.ref, element.value, unitWord(element.class), element.spice,
    });
}

/// Whether an element line ends in a value rather than a model or subcircuit.
fn needsValue(class: Class) bool {
    return switch (class) {
        .resistor, .capacitor, .inductor, .ferrite => true,
        else => false,
    };
}

/// The quantity word a class's value names, for the unreadable-value note.
fn unitWord(class: Class) []const u8 {
    return switch (class) {
        .resistor, .ferrite => "resistance",
        .capacitor => "capacitance",
        .inductor => "inductance",
        else => "value",
    };
}

/// What follows the nodes: a value, a model name, or a subcircuit name.
fn writeTail(w: *std.Io.Writer, element: Element) SpiceError!void {
    if (element.class == .subcircuit) {
        try w.print(" {s}", .{element.subckt});
        return;
    }
    if (element.model.len != 0) {
        try w.print(" {s}", .{element.model});
        return;
    }
    if (element.magnitude) |value| {
        try w.print(" ", .{});
        try writeMagnitude(w, value);
        try w.print("{s}", .{valueSuffix(element.class)});
        return;
    }
    try w.print(" {{{s}_VALUE}}", .{element.spice});
}

/// How many decimal places a component value is written to before its trailing
/// zeros are trimmed. Enough for any authored value (five significant figures
/// is the most a passive carries) and short enough to absorb the binary
/// floating-point residue of the parser's own scaling: `470nF` reads back as
/// 0.47000000000000003 microfarads, and a deck should say `0.47u`.
const value_decimals = 12;

/// Write a component value as a plain decimal with its trailing zeros removed.
///
/// Not `{e}` and not bare `{d}`: `{e}` writes `4.7e3` where a deck reads better
/// as `4700`, and `{d}` writes every bit of the residue above. A value too wide
/// for the buffer (no authored component value is) falls back to scientific
/// notation rather than being truncated into a different number.
fn writeMagnitude(w: *std.Io.Writer, value: f64) std.Io.Writer.Error!void {
    var buf: [160]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, "{d:.[1]}", .{ value, value_decimals }) catch
        return w.print("{e}", .{value});
    try w.writeAll(trimTrailingZeros(text));
}

/// Drop the trailing zeros (and then a bare trailing point) of a fixed-point
/// decimal. A string with no point is returned unchanged, so an integer
/// spelling can never lose a digit.
fn trimTrailingZeros(text: []const u8) []const u8 {
    // Not a net name: the decimal point of a formatted component value, so this
    // is not the bypass-stub collapse `net_analysis.baseNetName` owns.
    const decimal_point = ".";
    if (std.mem.indexOf(u8, text, decimal_point) == null) return text;
    const without_zeros = std.mem.trimEnd(u8, text, "0");
    return std.mem.trimEnd(u8, without_zeros, decimal_point);
}

/// The commented `.model` cards.
fn writeModels(w: *std.Io.Writer, deck: Deck) std.Io.Writer.Error!void {
    if (deck.models.len == 0) return;
    try w.writeAll("*\n* Device models — SUPPLY THESE. Each card below is a COMMENT: the\n* device type is a guess the design does not carry.\n");
    for (deck.models) |model| {
        try w.print("* .model {s} {s}   ; used by {s}\n", .{ model.name, model.kind, model.used_by });
    }
}

/// The `.subckt` stubs, one per IC component.
fn writeSubckts(w: *std.Io.Writer, deck: Deck) std.Io.Writer.Error!void {
    if (deck.subckts.len == 0) return;
    try w.writeAll("*\n* Subcircuit stubs — EMPTY BODIES. The ports below are the pads this\n* design wires, in pad order; supply a body before simulating.\n");
    for (deck.subckts) |sub| try writeSubckt(w, sub);
}

/// One stub: its pad map, its port list, and its empty body.
fn writeSubckt(w: *std.Io.Writer, sub: Subckt) std.Io.Writer.Error!void {
    try w.print("*\n* {s} — pad map:", .{sub.component});
    for (sub.pads, sub.ports) |pad, port| try w.print(" {s}={s}", .{ pad, port });
    try w.print("\n.subckt {s}", .{sub.name});
    for (sub.ports) |port| try w.print(" {s}", .{port});
    try w.print("\n.ends {s}\n", .{sub.name});
}

// ── Entry points ────────────────────────────────────────────────────────────

/// Resolve `parsed.name` and render its deck, or `error.UnresolvedDesign`.
///
// twin-drift-ok: see the note on `export_pinmap.exportOne` — resolving a design
// IS the three lines both share, through a seam they already share, and what
// each does with the resolved block has nothing in common.
fn exportOne(arena: std.mem.Allocator, parsed: Args) SpiceError![]const u8 {
    var eval = Evaluator.init(arena, parsed.project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        arena.destroy(mr.eval);
    };
    const block = pcb_layout_page.resolveBlock(arena, parsed.project_dir, parsed.name, &eval, &module_res) orelse
        return error.UnresolvedDesign;
    return render(arena, try buildDeck(arena, parsed.project_dir, parsed.name, block));
}

const usage_line = "Usage: netlisp export-spice [--project-dir <d>] [--output <file>] <design>\n";

/// CLI entry: `netlisp export-spice …`.
///
// twin-drift-ok: see the note on `export_pinmap.cmdExportPinmap` — the standard
// CLI wrapper over this module's own `Args` type, usage line and error set.
pub fn cmdExportSpice(allocator: std.mem.Allocator, args: []const []const u8) SpiceError!void {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const parsed = parseArgs(args) catch exit.fatal(usage_line, .{});
    const text = exportOne(arena, parsed) catch |err| switch (err) {
        error.UnresolvedDesign => exit.fatal("export-spice: cannot resolve design '{s}'\n", .{parsed.name}),
        else => return err,
    };
    if (parsed.output) |path| {
        try infra_fs.cwd().writeFile(.{ .sub_path = path, .data = text });
        return;
    }
    try std.Io.File.stdout().writeStreamingAll(infra_fs.currentIo(), text);
}

/// `export_spice` — the registered structured tool. Returns the deck text
/// verbatim (the same bytes `--output` would write), or a plain `error: …`
/// line with `ok:false` when the request is unusable.
pub fn tool(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    args_val: ?std.json.Value,
    out: *std.ArrayList(u8),
) SpiceError!bool {
    var aw: std.Io.Writer.Allocating = .fromArrayList(allocator, out);
    defer out.* = aw.toArrayList();
    const name = stringArg(args_val, "name") orelse {
        try aw.writer.writeAll("error: name is required");
        return false;
    };
    const text = exportOne(allocator, .{ .project_dir = project_dir, .name = name }) catch |err| switch (err) {
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

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

/// The node lists of the fixture's elements. At file scope, like every array
/// below, because a fixture that built them as locals would return the address
/// of stack storage.
const fixture_rail_nodes = [_][]const u8{ "N3V3", "0" };
const fixture_bead_nodes = [_][]const u8{ "V_12V", "V_12V_RF" };
const fixture_diode_nodes = [_][]const u8{ "USB_DP", "0" };
const fixture_ic_nodes = [_][]const u8{ "N3V3", "0", "USB_DP" };

/// One element of each kind the renderer has a branch for: a readable passive
/// value, a DNP part with an unreadable one, a bead written as its DC
/// resistance, a diode naming a model stub, an IC entering a subcircuit stub,
/// and a mechanical part that becomes no element at all.
const fixture_elements = [_]Element{
    .{
        .ref = "R1",
        .spice = "R1",
        .class = .resistor,
        .component = "res-0402",
        .value = "4.7k",
        .magnitude = 4700.0,
        .model = "",
        .subckt = "",
        .dnp = false,
        .nodes = &fixture_rail_nodes,
        .note = "",
    },
    .{
        .ref = "C1",
        .spice = "C1",
        .class = .capacitor,
        .component = "cap-0402",
        .value = "DNP",
        .magnitude = null,
        .model = "",
        .subckt = "",
        .dnp = true,
        .nodes = &fixture_rail_nodes,
        .note = "",
    },
    .{
        .ref = "C7",
        .spice = "C7",
        .class = .capacitor,
        .component = "cap-0402",
        .value = "4.7uF",
        .magnitude = 4.7,
        .model = "",
        .subckt = "",
        .dnp = false,
        .nodes = &fixture_rail_nodes,
        .note = "",
    },
    .{
        .ref = "L11",
        .spice = "RL11",
        .class = .ferrite,
        .component = "ferrite-0603",
        .value = "600R",
        .magnitude = 0.15,
        .model = "",
        .subckt = "",
        .dnp = false,
        .nodes = &fixture_bead_nodes,
        .note = "",
    },
    .{
        .ref = "D1",
        .spice = "D1",
        .class = .diode,
        .component = "diode-esd",
        .value = "",
        .magnitude = null,
        .model = "BAT54_MODEL",
        .subckt = "",
        .dnp = false,
        .nodes = &fixture_diode_nodes,
        .note = "",
    },
    .{
        .ref = "usb/U2",
        .spice = "XUSB_U2",
        .class = .subcircuit,
        .component = "usb-phy",
        .value = "",
        .magnitude = null,
        .model = "",
        .subckt = "USB_PHY",
        .dnp = false,
        .nodes = &fixture_ic_nodes,
        .note = "",
    },
    .{
        .ref = "TP4",
        .spice = "TP4",
        .class = .mechanical,
        .component = "testpoint",
        .value = "",
        .magnitude = null,
        .model = "",
        .subckt = "",
        .dnp = false,
        .nodes = &.{},
        .note = "",
    },
};

const fixture_pads = [_][]const u8{ "1", "2", "3" };
const fixture_ports = [_][]const u8{ "VDD", "GND", "DP" };
const fixture_subckts = [_]Subckt{.{
    .name = "USB_PHY",
    .component = "usb-phy",
    .pads = &fixture_pads,
    .ports = &fixture_ports,
}};
const fixture_models = [_]ModelStub{.{ .name = "BAT54_MODEL", .kind = "D", .used_by = "D1" }};
const fixture_renames = [_][]const u8{"usb.DP -> USB_DP_2 (folds onto usb/DP)"};

/// A deck covering every branch the renderer has.
fn fixture() Deck {
    return .{
        .design = "demo-board",
        .net_count = 6,
        .elements = &fixture_elements,
        .subckts = &fixture_subckts,
        .models = &fixture_models,
        .renames = &fixture_renames,
    };
}

// spec: export-spice - the CLI parses the project dir and the output path with one positional design name, and refuses a run that names no design, names two, or carries an unknown flag
test "export-spice CLI parses its flags and refuses an unusable vector" {
    const parsed = try parseArgs(&.{ "--project-dir", "p", "--output", "deck.cir", "barracuda" });
    try testing.expectEqualStrings("p", parsed.project_dir);
    try testing.expectEqualStrings("barracuda", parsed.name);
    try testing.expectEqualStrings("deck.cir", parsed.output.?);
    try testing.expectEqualStrings("projects/designs", (try parseArgs(&.{"barracuda"})).project_dir);
    try testing.expectError(error.SpiceUsage, parseArgs(&.{}));
    try testing.expectError(error.SpiceUsage, parseArgs(&.{ "a", "b" }));
    try testing.expectError(error.SpiceUsage, parseArgs(&.{ "--wat", "x", "a" }));
    try testing.expectError(error.SpiceUsage, parseArgs(&.{ "a", "--output" }));
}

// spec: export-spice - a part's class comes from its component family before its ref-des letter, so a ferrite bead carrying an L ref-des is not written as an inductor, and a pad count decides the ambiguous packages
test "classification prefers the component family over the ref-des letter" {
    // The ref-des assigner gives a bead an `L`; the family is what says it is a
    // bead, and a 600-ohm bead written as a 600-henry inductor is the exact bug
    // this ordering exists to prevent.
    try testing.expectEqual(Class.ferrite, classify("ferrite-0603", "L11", 2));
    try testing.expectEqual(Class.inductor, classify("ind-0603", "L12", 2));
    try testing.expectEqual(Class.resistor, classify("res-0402", "ldo/R7", 2));
    try testing.expectEqual(Class.capacitor, classify("cap-0402", "C9", 2));
    try testing.expectEqual(Class.mechanical, classify("testpoint", "TP4", 1));
    try testing.expectEqual(Class.subcircuit, classify("stm32", "U1", 214));
    // A pad count decides the ambiguous packages: a two-pad Q is a diode-
    // connected part, a three-pad one a transistor, and anything else a stub.
    try testing.expectEqual(Class.diode, classify("bat54", "D1", 2));
    try testing.expectEqual(Class.subcircuit, classify("dual-diode", "D2", 3));
    try testing.expectEqual(Class.transistor, classify("2n7002", "Q1", 3));
    try testing.expectEqual(Class.subcircuit, classify("quad-fet", "Q2", 8));
}

// spec: export-spice - an authored value carrying a rating after its magnitude is read as its magnitude rather than as nothing
test "a rated value is read as its magnitude" {
    // The corpus writes a capacitor's voltage rating after its value; the whole
    // string parses as no capacitance at all, so the first word is what counts.
    try testing.expectEqualStrings("1nF", magnitudeToken("1nF 2kV"));
    try testing.expectEqualStrings("10uF", magnitudeToken("10uF 25V"));
    try testing.expectEqualStrings("4.7k", magnitudeToken("4.7k"));
    try testing.expectEqualStrings("", magnitudeToken(" 100nF"));
    try testing.expectEqual(@as(?f64, 1e-3), req_checks.parseValueFor(.C, magnitudeToken("1nF 2kV")));
}

// spec: export-spice - the element name carries its own class letter, so a ref-des that already starts with it is kept and a sub-block path or a bead written as a resistor is prefixed
test "element names declare their SPICE class" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var table: names.Table = .{};

    try testing.expectEqualStrings("R12", try elementName(arena, .resistor, "R12", &table));
    // A bead is written as an R, so its L ref-des must be prefixed.
    try testing.expectEqualStrings("RL11", try elementName(arena, .ferrite, "L11", &table));
    // A sub-block path does not start with the class letter either.
    try testing.expectEqualStrings("CLDO_C7", try elementName(arena, .capacitor, "ldo/C7", &table));
    try testing.expectEqualStrings("XUSB_U2", try elementName(arena, .subcircuit, "usb/U2", &table));
    // Two refs folding onto one spelling are separated rather than shorted.
    try testing.expectEqualStrings("CLDO_C7_2", try elementName(arena, .capacitor, "ldo.C7", &table));
}

// spec: export-spice - the rendered deck writes one element line per part with ground on node 0, comments out a DNP part, names a model and a subcircuit stub for the parts that need one, and ends with .end
test "the rendered deck writes every element, stub and limit" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const text = try render(arena, fixture());
    // A readable passive value is written in SI base units, not the authored
    // spelling — SPICE reads `1M` as a milli, so the text can never pass through.
    try testing.expect(std.mem.indexOf(u8, text, "\nR1 N3V3 0 4700\n") != null);
    // A capacitance keeps the micro unit it was parsed in and carries SPICE's
    // own `u`: multiplying 4.7 uF into farads would write 4.7000000000000004e-6.
    try testing.expect(std.mem.indexOf(u8, text, "\nC7 N3V3 0 4.7u\n") != null);
    // A ferrite is its DC resistance, on an R line.
    try testing.expect(std.mem.indexOf(u8, text, "\nRL11 V_12V V_12V_RF 0.15\n") != null);
    // A DNP part is present but commented, so nothing it would load is applied.
    try testing.expect(std.mem.indexOf(u8, text, "* DNP — not populated:\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\n* C1 N3V3 0 {C1_VALUE}\n") != null);
    // …and the unreadable value it carries is named in the comment beside it.
    try testing.expect(std.mem.indexOf(u8, text, "value \"DNP\" is not readable as a capacitance") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\nD1 USB_DP 0 BAT54_MODEL\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\nXUSB_U2 N3V3 0 USB_DP USB_PHY\n") != null);
    // Every stub is present and every stub is inert: a commented .model card
    // and a .subckt whose body is empty.
    try testing.expect(std.mem.indexOf(u8, text, "* .model BAT54_MODEL D   ; used by D1\n") != null);
    try testing.expect(std.mem.indexOf(u8, text, "\n.subckt USB_PHY VDD GND DP\n.ends USB_PHY\n") != null);
    // A mechanical part is reported rather than silently dropped, the fold
    // collision is reported, and the deck terminates.
    try testing.expect(std.mem.indexOf(u8, text, "* TP4 (testpoint): no SPICE element") != null);
    try testing.expect(std.mem.indexOf(u8, text, "* net renamed: usb.DP -> USB_DP_2") != null);
    try testing.expect(std.mem.endsWith(u8, text, "\n.end\n"));
    // The build id is the only per-run value and it sits on a `*#` line.
    try testing.expect(std.mem.indexOf(u8, text, "*# build: test\n") != null);
}

// spec: export-spice - a component value is written as a plain decimal with the parser's binary floating-point residue trimmed away, and an integer spelling keeps every digit
test "component values are written as trimmed decimals" {
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    // 470nF reads back from the microfarad parser as 0.47000000000000003, and
    // 4.7k as exactly 4700: both must print as the value the design authored.
    try writeMagnitude(&aw.writer, 0.47000000000000003);
    try aw.writer.writeAll(" ");
    try writeMagnitude(&aw.writer, 4700.0);
    try aw.writer.writeAll(" ");
    try writeMagnitude(&aw.writer, 0.15);
    try aw.writer.writeAll(" ");
    try writeMagnitude(&aw.writer, 10.0);
    try aw.writer.writeAll(" ");
    // A milliohm shunt keeps its magnitude rather than rounding to zero.
    try writeMagnitude(&aw.writer, 0.001);
    try testing.expectEqualStrings("0.47 4700 0.15 10 0.001", aw.written());
    // An integer spelling has no point to trim, so no digit can be lost.
    try testing.expectEqualStrings("100", trimTrailingZeros("100"));
    try testing.expectEqualStrings("100", trimTrailingZeros("100.000"));
}

// spec: export-spice - two renders of one deck are byte-identical, so a differential comparison sees only real changes
test "a deck renders identically twice" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try testing.expectEqualStrings(try render(arena, fixture()), try render(arena, fixture()));
}

// spec: export-spice - a ground-class net maps to node 0 while every other net is folded, and the ground predicate is the project's own so a split or per-pin ground still reaches 0
test "ground-class nets map to node 0" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var table: names.Table = .{};
    var renames: std.ArrayList([]const u8) = .empty;

    try testing.expectEqualStrings("0", try nodeFor(arena, "GND", &table, &renames));
    try testing.expectEqualStrings("0", try nodeFor(arena, "AGND", &table, &renames));
    try testing.expectEqualStrings("0", try nodeFor(arena, "GND2", &table, &renames));
    // A per-pin bypass stub carved off a ground rail is still ground, and so is
    // a sub-block's own ground once flattened.
    try testing.expectEqualStrings("0", try nodeFor(arena, "GND.U1.A3", &table, &renames));
    try testing.expectEqualStrings("0", try nodeFor(arena, "ldo/GND", &table, &renames));
    // Everything else is folded, and a rail is never mistaken for a ground.
    try testing.expectEqualStrings("N3V3", try nodeFor(arena, "3V3", &table, &renames));
    try testing.expectEqualStrings("USB_DP", try nodeFor(arena, "usb/DP", &table, &renames));
    try testing.expectEqual(@as(usize, 0), renames.items.len);
    // …and a second net folding onto a taken spelling is separated and reported
    // rather than silently shorted onto the first.
    try testing.expectEqualStrings("USB_DP_2", try nodeFor(arena, "usb.DP", &table, &renames));
    try testing.expectEqual(@as(usize, 1), renames.items.len);
}

// spec: export-spice - the exporter is registered as a read-only structured tool and its declared schema names every argument the handler reads
test "export_spice is a registered read-only tool with a round-tripping schema" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const mcp_tools = @import("serve/mcp_tools.zig");

    try testing.expect(mcp_tools.isKnownTool("export_spice"));
    // It writes no project file, so it is not gated as a mutation.
    try testing.expect(!mcp_tools.isMutationTool("export_spice"));

    const root = try std.json.parseFromSliceLeaky(std.json.Value, arena, mcp_tools.tools_list_result, .{});
    var schema: ?std.json.ObjectMap = null;
    for (root.object.get("tools").?.array.items) |entry| {
        if (std.mem.eql(u8, entry.object.get("name").?.string, "export_spice"))
            schema = entry.object.get("inputSchema").?.object;
    }
    const props = schema.?.get("properties").?.object;
    try testing.expectEqualStrings("string", props.get("name").?.object.get("type").?.string);
    // Closed: the deck takes exactly one argument, so an undeclared one is a
    // request a strict client could not send.
    try testing.expect(!schema.?.get("additionalProperties").?.bool);
    const required = schema.?.get("required").?.array.items;
    try testing.expectEqual(@as(usize, 1), required.len);
    try testing.expectEqualStrings("name", required[0].string);
}

// spec: export-spice - the tool refuses a missing design name and an unresolvable design with an ok:false error line rather than exporting an empty deck
test "the spice tool refuses an unusable request" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var out: std.ArrayList(u8) = .empty;
    try testing.expect(!try tool(arena, ".", null, &out));
    try testing.expect(std.mem.indexOf(u8, out.items, "error: name is required") != null);

    // An unresolvable design is named in the refusal rather than yielding a
    // header-only deck a caller could mistake for a board with no parts.
    out.clearRetainingCapacity();
    const missing = try std.json.parseFromSliceLeaky(std.json.Value, arena, "{\"name\":\"no-such-design\"}", .{});
    try testing.expect(!try tool(arena, "/nonexistent-netlisp-project", missing, &out));
    try testing.expect(std.mem.indexOf(u8, out.items, "no-such-design") != null);
}
