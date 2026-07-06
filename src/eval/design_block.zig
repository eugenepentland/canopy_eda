const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const numeric = @import("../numeric.zig");
const sexpr_parser = @import("../sexpr/parser.zig");
const log = @import("../infra/log.zig");
const env_mod = @import("env.zig");
const evaluator_mod = @import("evaluator.zig");
const Evaluator = evaluator_mod.Evaluator;
const EvalError = evaluator_mod.EvalError;
const PinNetDecl = evaluator_mod.PinNetDecl;
const NetTie = Evaluator.NetTie;
const ids = @import("ids.zig");
const validate = @import("validate.zig");
const instance_mod = @import("instance.zig");
const builders = @import("builders.zig");
const special_forms = @import("special_forms.zig");
const rails_mod = @import("rails.zig");
const test_point_mod = @import("test_point.zig");
const pin_enrichment = @import("pin_enrichment.zig");
const forms_mod = @import("forms.zig");
const ScopeForm = forms_mod.ScopeForm;

const Node = ast.Node;
const Value = env_mod.Value;
const Env = env_mod.Env;
const Instance = env_mod.Instance;
const DesignBlock = env_mod.DesignBlock;
const PinRef = env_mod.PinRef;
const Net = env_mod.Net;
const Port = env_mod.Port;
const Note = env_mod.Note;
const Group = env_mod.Group;
const SubBlock = env_mod.SubBlock;

/// Sanity cap on the index count a single `(bus-net …)` / `(bus-port …)` form
/// may expand to. A real bus is dozens of lanes wide; a value of thousands is
/// a typo or a hostile file. Without it, `(bus-net "X" 0 100000000 "sub")`
/// allocates 100M net ties — an OOM DoS the HTTP server evaluates on push.
const MAX_BUS_EXPANSION: usize = 4096;

/// True if the design-block body contains a bare `(hierarchical-ids)` form,
/// which opts into Option-4 sub-block identity.
fn hasHierarchicalMarker(forms: []const Node) bool {
    for (forms) |form| {
        const children = form.asList() orelse continue;
        if (children.len == 0) continue;
        const head = children[0].asAtom() orelse continue;
        if (std.mem.eql(u8, head, "hierarchical-ids")) return true;
    }
    return false;
}

/// Form heads that are deliberately inert in scope-form dispatch and must
/// not draw an unknown-sub-form warning: identity anchors consumed by the
/// id machinery (`id`/`ids`), the `(hierarchical-ids)` marker read by
/// `hasHierarchicalMarker`, and the documented-but-inert `(row N)`/`(col N)`
/// grid hints carried by sections and hub instances.
fn isInertFormHead(name: []const u8) bool {
    return std.mem.eql(u8, name, "id") or
        std.mem.eql(u8, name, "ids") or
        std.mem.eql(u8, name, "hierarchical-ids") or
        std.mem.eql(u8, name, "row") or
        std.mem.eql(u8, name, "col");
}

/// Evaluate a `(design-block "name" form…)` form into a heap-allocated
/// `DesignBlock`. Iterates each child form (instance/port/note/group/section/
/// sub-block/net/series/decouple/verifies), builds nets from collected
/// pin-net declarations and net-ties, auto-assigns ref-deses, and runs the
/// design validator. The returned Value owns the DesignBlock.
pub fn evalDesignBlock(self: *Evaluator, args: []const Node, env: *Env) EvalError!Value {
    try special_forms.checkArity(self, .design_block, args);

    // First arg is name (could be computed via fmt); the rest is the body.
    const name_val = try self.evalNode(args[0], env);
    const name = name_val.asString() orelse return EvalError.TypeError;
    return materializeBlock(self, name, args[1..], env);
}

/// Materialize a block body — the forms after the name — into a heap-allocated
/// `DesignBlock`: walk each form (instance/port/section/sub-block/net/…), build
/// nets from the collected pin-net declarations, auto-assign ref-deses, and run
/// the design validator. `evalDesignBlock` parses the name and delegates here;
/// factoring it out lets the lazy `(block …)`/`(defmodule …)` body path reuse
/// the identical routine instead of round-tripping through a wrapper form.
pub fn materializeBlock(self: *Evaluator, name: []const u8, body_forms: []const Node, env: *Env) EvalError!Value {
    var instances: std.ArrayListUnmanaged(Instance) = .empty;
    var all_pin_nets: std.ArrayListUnmanaged(PinNetDecl) = .empty;
    var ports: std.ArrayListUnmanaged(Port) = .empty;
    var notes: std.ArrayListUnmanaged(Note) = .empty;
    var groups: std.ArrayListUnmanaged(Group) = .empty;
    var sections: std.ArrayListUnmanaged(env_mod.Section) = .empty;

    var net_ties: std.ArrayListUnmanaged(NetTie) = .empty;
    var sub_blocks: std.ArrayListUnmanaged(SubBlock) = .empty;
    var functions: std.ArrayListUnmanaged(env_mod.FunctionSpec) = .empty;
    var verifications: std.ArrayListUnmanaged(env_mod.Verification) = .empty;
    var test_points: std.ArrayListUnmanaged(env_mod.TestPoint) = .empty;
    var parts: std.ArrayListUnmanaged(env_mod.PlaceholderPart) = .empty;
    var layout_spec: env_mod.LayoutSpec = .{};
    var board_spec: env_mod.BoardSpec = .{};
    var revision_spec: env_mod.Revision = .{};
    var rough_spec: env_mod.RoughSpec = .{};
    var stackup_spec: env_mod.StackupSpec = .{};
    var net_class_specs: std.ArrayListUnmanaged(env_mod.NetClassSpec) = .empty;
    var kicad_pcb_path: ?[]const u8 = null;
    var net_form_sources: std.StringHashMapUnmanaged(u32) = .empty;

    // Pre-scan: register all explicit ref-des to avoid auto-counter collisions,
    // and all existing id/ids tokens so generateId never re-mints one.
    ids.prescanRefDes(self, body_forms);
    ids.prescanIds(self, body_forms);

    // `(hierarchical-ids)` opts this design (and the modules it sub-blocks) into
    // Option-4 sub-block identity. Inherit from any enclosing design and restore
    // on exit so the flag follows the design tree, not evaluation order.
    const saved_hierarchical = self.hierarchical_ids;
    self.hierarchical_ids = saved_hierarchical or hasHierarchicalMarker(body_forms);
    defer self.hierarchical_ids = saved_hierarchical;

    // Decouple defaults: the IC ref is design-block-local (a parent's
    // fallback host makes no sense inside a different module), but the
    // BYPASS component cascades — a sub-block module that doesn't declare
    // its own (decouple-defaults (bypass …)) inherits the enclosing
    // design's, transitively through nested sub-blocks. A
    // (decouple-defaults …) form inside this body overrides below; the
    // defer restores the enclosing design's defaults on exit.
    const saved_decouple_defaults = self.decouple_defaults;
    self.decouple_defaults = .{ .ic = "", .bypass = saved_decouple_defaults.bypass };
    defer self.decouple_defaults = saved_decouple_defaults;

    for (body_forms) |form| {
        const form_children = form.asList() orelse continue;
        if (form_children.len == 0) continue;
        const form_name = form_children[0].asAtom() orelse continue;

        // Setup special forms may appear inline in a raw `(block …)` body —
        // evaluate `(let …)`/`(assert …)`/`(import …)`/`(id …)` for their
        // binding/effect, then continue. (A `(design-block …)` body never holds
        // these; in the wrapped form they precede the inner block.)
        if (forms_mod.SpecialForm.fromAtom(form_name)) |special| switch (special) {
            .let, .assert_, .assert_range, .import, .id_ => {
                _ = try self.evalNode(form, env);
                continue;
            },
            else => {},
        };

        const sf = ScopeForm.fromAtom(form_name) orelse {
            if (!isInertFormHead(form_name))
                self.warnFmt(form.span, "unknown sub-form ({s} …) in (design-block …)", .{form_name});
            continue;
        };
        switch (sf) {
            .instance => {
                const result = try instance_mod.buildInstance(self, form_children, env);
                ids.registerRefDes(self, result.instance.ref_des);
                try instances.append(self.allocator, result.instance);
                for (result.pin_nets) |pn| try all_pin_nets.append(self.allocator, pn);
                for (result.inline_notes) |note| try notes.append(self.allocator, note);
                try appendAutoAliases(self, result.instance, result.pin_nets, &net_ties);
            },
            .port => {
                const port = try builders.buildPort(self, form_children[1..], env);
                try ports.append(self.allocator, port);
            },
            .bus_port => try builders.expandTopLevelBusPort(self, form_children, env, &ports),
            .note => {
                const note = try builders.buildNote(self, form_children[1..], env);
                try notes.append(self.allocator, note);
            },
            .group => {
                const group = try builders.buildGroup(self, form_children[1..], env);
                try groups.append(self.allocator, group);
            },
            .function => {
                const f = try builders.buildFunction(self, form_children[1..], env);
                try functions.append(self.allocator, f);
            },
            .sub_block => {
                const sb = try builders.buildSubBlock(self, form_children, env);
                try evalSubBlockBridges(self, form_children, sb.name, &net_ties);
                try sub_blocks.append(self.allocator, sb);
            },
            .section => try evalSection(self, form_children, env, &instances, &all_pin_nets, &notes, &net_ties, &sections),
            .net => {
                try evalNetForm(self, form_children, env, &net_ties);
                validate.trackNetFormSource(self, form_children, env, &net_form_sources);
            },
            .bus_net => try evalBusNetForm(self, form_children, env, &net_ties),
            .series => try instance_mod.evalSeriesForm(self, form_children, env, &instances, &all_pin_nets, &notes),
            .fanout => try instance_mod.evalFanoutForm(self, form_children, env, &instances, &all_pin_nets),
            .decouple => try evalDecoupleForm(self, form_children, env, &instances, &all_pin_nets),
            .decouple_defaults => try parseDecoupleDefaults(self, form_children, env),
            .verifies => if (parseVerifies(self, form_children, env)) |v| try verifications.append(self.allocator, v),
            .test_point => if (try test_point_mod.parse(self.allocator, form_children)) |tp| try test_points.append(self.allocator, tp),
            .kicad_pcb => {
                if (parseKicadPcbPath(form_children)) |p| kicad_pcb_path = p;
            },
            .stub => if (try parseStub(self, form_children)) |p| {
                ids.registerRefDes(self, p.part.ref_des);
                try instances.append(self.allocator, p.instance);
                for (p.pin_nets) |pn| try all_pin_nets.append(self.allocator, pn);
                try parts.append(self.allocator, p.part);
            },
            .layout => layout_spec = try parseLayout(self, form_children),
            .board => board_spec = try parseBoard(self, form_children),
            .revision => revision_spec = try parseRevision(self, form_children),
            .rough => rough_spec = try parseRough(self, form_children),
            .stackup => stackup_spec = try parseStackup(self, form_children),
            .net_class => if (try parseNetClass(self, form_children)) |nc|
                net_class_specs.append(self.allocator, nc) catch return EvalError.OutOfMemory,
            // Section-only forms are ignored at the top level — a
            // design-block body shouldn't carry status/description/pins
            // directly. The exhaustive switch is the contract; the warning
            // makes the silent skip visible.
            .pins, .protocol, .calc, .description, .role, .diagram, .hosts, .category => {
                self.warnFmt(form.span, "({s} …) is section-only — ignored at design-block top level", .{form_name});
            },
        }
    }

    try validate.warnCombinableNets(self, &net_form_sources);
    const nets_slice = try buildNets(self, &all_pin_nets, &net_ties);

    // Convert net ties to env NetTie format for storage on the block.
    // Skip auto-aliases: they're block-local helpers (symbol pin-function
    // matching) and would otherwise bridge unrelated nets in the cross-block
    // flatten done by export_kicad_netlist.applyNetTies.
    var block_ties: std.ArrayListUnmanaged(env_mod.NetTie) = .empty;
    for (net_ties.items) |nt| {
        if (nt.is_auto) continue;
        try block_ties.append(self.allocator, .{ .a = nt.a, .b = nt.b });
    }

    const block = self.allocator.create(DesignBlock) catch return EvalError.OutOfMemory;
    block.* = .{
        .name = name,
        .instances = instances.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
        .nets = nets_slice,
        .ports = ports.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
        .notes = notes.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
        .groups = groups.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
        .sub_blocks = sub_blocks.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
        .sections = sections.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
        .functions = functions.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
        .net_ties = block_ties.toOwnedSlice(self.allocator) catch &.{},
        .verifications = verifications.toOwnedSlice(self.allocator) catch &.{},
        .test_points = test_points.toOwnedSlice(self.allocator) catch &.{},
        .kicad_pcb_path = kicad_pcb_path,
        .parts = parts.toOwnedSlice(self.allocator) catch &.{},
        .layout = layout_spec,
        .board = board_spec,
        .revision = revision_spec,
        .rough = rough_spec,
        .stackup = stackup_spec,
        .net_classes = net_class_specs.toOwnedSlice(self.allocator) catch &.{},
    };

    // Auto-assign ref_des for instances with descriptive labels
    try ids.autoAssignRefDes(self, block);

    // Auto-assign global ref_des for sub-block instances
    try ids.autoAssignSubBlockRefDes(self, block);

    // Resolve single-alt pin functions before validation so the renderer,
    // KiCad export, and ERC's own assertion check all see the auto-filled
    // `asserted_fns` slices. Multi-alt pins remain empty and trigger
    // `pin_function_required` in ERC.
    pin_enrichment.enrichPinFunctions(self.allocator, block, self.project_dir) catch return EvalError.OutOfMemory;

    // Validate: warn about dead-end nets, etc.
    try validate.validateDesign(self, block);

    // Derive first-class power-rail entries from sub-block output ports +
    // ferrite-bead union-find. Downstream analyses (power_budget,
    // power_sequencing, ERC integrity checks) consume `block.rails`
    // instead of recomputing rail identity from emergent topology.
    block.rails = rails_mod.build(self.allocator, block) catch return EvalError.OutOfMemory;

    return .{ .design_block = block };
}

/// Read the path from a `(kicad-pcb "<absolute path>")` form — the on-disk
/// PCB the file-based sync endpoint writes to. Only the literal string form
/// is supported; no env-var or template expansion (NAS paths are
/// deterministic). Null when the form carries no string.
fn parseKicadPcbPath(form_children: []const Node) ?[]const u8 {
    if (form_children.len < 2) return null;
    return form_children[1].asString();
}

/// Parse `(revision "ID" (date "YYYY-MM-DD") (change "ID" "summary")…)` — the
/// design's declared board revision. The first argument is the canonical
/// revision id; like ids elsewhere it's a literal string (not evaluated). An
/// optional `(date …)` sub-form carries the cut date and each `(change …)`
/// sub-form appends one changelog entry (newest-first by convention). An
/// id-less form (or a non-string id) is reported as a lint warning and
/// treated as absent, so a typo can't silently version the board.
fn parseRevision(self: *Evaluator, form_children: []const Node) EvalError!env_mod.Revision {
    if (form_children.len < 2) {
        self.warnFmt(form_children[0].span, "(revision …) needs an id, e.g. (revision \"A\")", .{});
        return .{};
    }
    const id = form_children[1].asString() orelse {
        self.warnFmt(form_children[1].span, "(revision …) id must be a quoted string, e.g. (revision \"F4\")", .{});
        return .{};
    };

    var date: []const u8 = "";
    var changes: std.ArrayListUnmanaged(env_mod.RevisionChange) = .empty;

    for (form_children[2..]) |child| {
        const kids = child.asList() orelse {
            self.warnFmt(child.span, "(revision …) extra arguments must be (date …) or (change …) sub-forms", .{});
            continue;
        };
        if (kids.len == 0) continue;
        const head = kids[0].asAtom() orelse continue;
        if (std.mem.eql(u8, head, "date")) {
            if (kids.len >= 2) {
                if (kids[1].asString()) |d| {
                    date = d;
                } else {
                    self.warnFmt(kids[1].span, "(date …) value must be a quoted string", .{});
                }
            }
        } else if (std.mem.eql(u8, head, "change")) {
            if (kids.len < 3) {
                self.warnFmt(child.span, "(change …) needs an id and a summary, e.g. (change \"A\" \"first spin\")", .{});
                continue;
            }
            const cid = kids[1].asString() orelse {
                self.warnFmt(kids[1].span, "(change …) id must be a quoted string", .{});
                continue;
            };
            const summary = kids[2].asString() orelse {
                self.warnFmt(kids[2].span, "(change …) summary must be a quoted string", .{});
                continue;
            };
            try changes.append(self.allocator, .{ .id = cid, .summary = summary });
        } else {
            self.warnFmt(child.span, "unknown sub-form ({s} …) in (revision …)", .{head});
        }
    }

    return .{
        .id = id,
        .date = date,
        .changes = changes.toOwnedSlice(self.allocator) catch &.{},
        .present = true,
    };
}

/// Append auto pin aliases (net-ties) for an instance based on its pinout.
fn appendAutoAliases(
    self: *Evaluator,
    inst: Instance,
    pin_nets: []const PinNetDecl,
    net_ties: *std.ArrayListUnmanaged(NetTie),
) EvalError!void {
    const comp_data = self.component_cache.get(inst.component);
    const pin_lookup_name = if (comp_data) |cd| (if (cd.pinout_name.len > 0) cd.pinout_name else cd.symbol_name) else inst.symbol;
    if (pin_lookup_name.len > 0) {
        if (ids.getSymbolPins(self, pin_lookup_name)) |sym_pins| {
            for (pin_nets) |pn| {
                if (sym_pins.get(pn.pin)) |func_name| {
                    if (pn.net.len > 0 and !std.mem.eql(u8, pn.net, func_name)) {
                        try net_ties.append(self.allocator, .{ .a = pn.net, .b = func_name, .is_auto = true });
                    }
                }
            }
        }
    }
}

/// Evaluate a (net ...) form.
fn evalNetForm(self: *Evaluator, form_children: []const Node, env: *Env, net_ties: *std.ArrayListUnmanaged(NetTie)) EvalError!void {
    if (form_children.len >= 3) {
        const src_val = try self.evalNode(form_children[1], env);
        const src = src_val.asString() orelse return;
        for (form_children[2..]) |dst_node| {
            const dst_val = try self.evalNode(dst_node, env);
            const dst = dst_val.asString() orelse continue;
            try net_ties.append(self.allocator, .{ .a = src, .b = dst });
        }
    }
}

/// Read the literal text of a node — a quoted string or a bare atom —
/// without evaluating it. Bridge/bus-net port and sub names are written as
/// bare atoms (`SCK`, `adc1`) which must not go through `evalNode` (that
/// would treat them as variable lookups); the prefix is a string literal.
/// Returns null for lists/numbers.
fn literalText(node: Node) ?[]const u8 {
    return node.asText();
}

/// Evaluate `(bus-net …)`. Two shapes share the head:
///
///   • Legacy 1:1 — `(bus-net "PREFIX" START END "SUB")` expands to one
///     `(net "PREFIX<i>" "SUB/PREFIX<i>")` per index in `[START, END]`.
///     `(bus-net "FLASH_IO" 0 7 "flash")` replaces 8 verbatim net ties.
///
///   • Strided fan-out — `(bus-net "PREFIX" START END (suffixes A B)
///     (over "s1" "s2") (ports P0 P1 …))` distributes the index range
///     across the flattened `(sub × port)` slot list (sub-major), emitting
///     one tie per `(channel × suffix)`: parent `PREFIX<i><suffix>` ties to
///     `<sub>/<port><suffix>`. Lets the 20 per-channel ADC analog ties
///     collapse to one form. Detected by the presence of an `(over …)`.
///
/// Bounds are inclusive on both ends so the index range mirrors the
/// underlying signal numbering.
fn evalBusNetForm(self: *Evaluator, form_children: []const Node, env: *Env, net_ties: *std.ArrayListUnmanaged(NetTie)) EvalError!void {
    if (form_children.len < 5) return;
    const prefix = (try self.evalNode(form_children[1], env)).asString() orelse return;
    const start = numberAsUsize(try self.evalNode(form_children[2], env)) orelse return;
    const end = numberAsUsize(try self.evalNode(form_children[3], env)) orelse return;
    if (end < start) return;
    if (end - start >= MAX_BUS_EXPANSION) {
        self.warnFmt(form_children[0].span, "(bus-net …) index range {d}..{d} exceeds the {d}-lane cap — ignored", .{ start, end, MAX_BUS_EXPANSION });
        return;
    }

    // Strided mode is opted into by an `(over …)` child; collect its
    // companion `(ports …)` / optional `(suffixes …)` sub-forms.
    var over: ?[]const Node = null;
    var ports: ?[]const Node = null;
    var suffixes: ?[]const Node = null;
    for (form_children[4..]) |c| {
        if (c.isForm("over")) over = c.asList().?[1..];
        if (c.isForm("ports")) ports = c.asList().?[1..];
        if (c.isForm("suffixes")) suffixes = c.asList().?[1..];
    }

    if (over != null and ports != null) {
        try evalStridedBusNet(self, net_ties, prefix, start, end, over.?, ports.?, suffixes);
        return;
    }

    // Legacy 1:1 form: the 5th child is the sub-block name string.
    const sub = (try self.evalNode(form_children[4], env)).asString() orelse return;
    var i: usize = start;
    while (i <= end) : (i += 1) {
        const parent = std.fmt.allocPrint(self.allocator, "{s}{d}", .{ prefix, i }) catch return EvalError.OutOfMemory;
        const child = std.fmt.allocPrint(self.allocator, "{s}/{s}{d}", .{ sub, prefix, i }) catch return EvalError.OutOfMemory;
        try net_ties.append(self.allocator, .{ .a = parent, .b = child });
    }
}

/// Distribute channels `[start, end]` across the flattened `over × ports`
/// slot list (sub-major: all of sub0's ports, then sub1's, …). Channel `k`
/// takes slot `k - start`; for every suffix (or one empty suffix when none
/// is given) it ties `PREFIX<k><suffix>` to `<sub>/<port><suffix>`.
/// Channels beyond the available slots are skipped.
fn evalStridedBusNet(
    self: *Evaluator,
    net_ties: *std.ArrayListUnmanaged(NetTie),
    prefix: []const u8,
    start: usize,
    end: usize,
    over: []const Node,
    ports: []const Node,
    suffixes: ?[]const Node,
) EvalError!void {
    if (ports.len == 0) return;
    var k: usize = start;
    while (k <= end) : (k += 1) {
        const slot = k - start;
        const sub_idx = slot / ports.len;
        const port_idx = slot % ports.len;
        if (sub_idx >= over.len) break; // ran out of slots
        const sub = literalText(over[sub_idx]) orelse continue;
        const port = literalText(ports[port_idx]) orelse continue;
        if (suffixes) |sfx| {
            for (sfx) |sf_node| {
                const suffix = literalText(sf_node) orelse continue;
                try appendStrideTie(self, net_ties, prefix, k, suffix, sub, port);
            }
        } else {
            try appendStrideTie(self, net_ties, prefix, k, "", sub, port);
        }
    }
}

fn appendStrideTie(
    self: *Evaluator,
    net_ties: *std.ArrayListUnmanaged(NetTie),
    prefix: []const u8,
    k: usize,
    suffix: []const u8,
    sub: []const u8,
    port: []const u8,
) EvalError!void {
    const parent = std.fmt.allocPrint(self.allocator, "{s}{d}{s}", .{ prefix, k, suffix }) catch return EvalError.OutOfMemory;
    const far = std.fmt.allocPrint(self.allocator, "{s}/{s}{s}", .{ sub, port, suffix }) catch return EvalError.OutOfMemory;
    try net_ties.append(self.allocator, .{ .a = parent, .b = far });
}

/// Process any `(bridge "PREFIX" PORT… (rename PORT SUFFIX)…)` children of a
/// `(sub-block …)` form. Each bridged port P emits one net-tie
/// `(net "PREFIX<suffix>" "<sub>/P")`, where <suffix> defaults to P unless a
/// `(rename P SUFFIX)` overrides it (e.g. SPI `CS` → board net `…NCS`).
/// Collapses the per-port bridging `(net …)` lines a peripheral sub-block
/// would otherwise need at the design top level. Power/GND ports are simply
/// left off the list — they stay wired through the consolidated rail forms.
fn evalSubBlockBridges(
    self: *Evaluator,
    form_children: []const Node,
    sub_name: []const u8,
    net_ties: *std.ArrayListUnmanaged(NetTie),
) EvalError!void {
    for (form_children[1..]) |child| {
        if (!child.isForm("bridge")) continue;
        const bc = child.asList().?;
        if (bc.len < 2) continue;
        const prefix = literalText(bc[1]) orelse "";
        for (bc[2..]) |item| {
            if (item.isForm("rename")) {
                const rc = item.asList().?;
                if (rc.len < 3) continue;
                const port = literalText(rc[1]) orelse continue;
                const suffix = literalText(rc[2]) orelse continue;
                try appendBridgeTie(self, net_ties, prefix, suffix, sub_name, port);
            } else if (literalText(item)) |port| {
                try appendBridgeTie(self, net_ties, prefix, port, sub_name, port);
            }
        }
    }
}

fn appendBridgeTie(
    self: *Evaluator,
    net_ties: *std.ArrayListUnmanaged(NetTie),
    prefix: []const u8,
    suffix: []const u8,
    sub_name: []const u8,
    port: []const u8,
) EvalError!void {
    const parent = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ prefix, suffix }) catch return EvalError.OutOfMemory;
    const far = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ sub_name, port }) catch return EvalError.OutOfMemory;
    try net_ties.append(self.allocator, .{ .a = parent, .b = far });
}

/// Coerce a design-file number to a `usize` index, rejecting NaN/±inf and
/// out-of-range values (a bare `@intFromFloat` on those is UB in the safety-off
/// ReleaseSmall production build). Returns null on any non-representable input;
/// callers treat null as "skip this form" (and the caller bounds the resulting
/// expansion count so a huge-but-valid number can't OOM).
fn numberAsUsize(v: env_mod.Value) ?usize {
    const f = v.asNumber() orelse return null;
    if (f < 0) return null;
    return numeric.checkedInt(usize, f);
}

/// Evaluate `(decouple-defaults (ic "REF") (bypass (comp)))` — records the
/// per-design fallback host ref and bypass component on the evaluator. With
/// these set, a `(decouple …)` may omit its component (a leading count → use
/// the bypass) and/or its per-pin host ref (the first post-`per-pin` token,
/// unless it equals the default ref, is taken as a pin and the ref defaults
/// in). Both sub-forms are optional and either may appear alone.
fn parseDecoupleDefaults(self: *Evaluator, form_children: []const Node, env: *Env) EvalError!void {
    for (form_children[1..]) |child| {
        const cc = child.asList() orelse continue;
        if (cc.len < 2) continue;
        const head = cc[0].asAtom() orelse continue;
        if (std.mem.eql(u8, head, "ic")) {
            const v = try self.evalNode(cc[1], env);
            if (v.asString()) |s| self.decouple_defaults.ic = s;
        } else if (std.mem.eql(u8, head, "bypass")) {
            // Store the component node verbatim; emitDecoupleItems evals it
            // in the decoupling site's env when a (decouple …) omits its own.
            self.decouple_defaults.bypass = cc[1];
        }
    }
}

/// Evaluate a top-level (decouple ...) form.
fn evalDecoupleForm(
    self: *Evaluator,
    form_children: []const Node,
    env: *Env,
    instances: *std.ArrayListUnmanaged(Instance),
    all_pin_nets: *std.ArrayListUnmanaged(PinNetDecl),
) EvalError!void {
    if (form_children.len < 3) return;
    const first_val = try self.evalNode(form_children[1], env);
    // Stamp the decouple form's own (id) anchor. Under (hierarchical-ids) this
    // single uuid seeds every child cap's derived id; otherwise it is just the
    // form anchor and the children get pinned tokens from the (ids …) sidecar.
    const form_id = try ids.getOrCreateFormId(self, form_children);
    var sidecar = ids.parseChildIdSidecar(self, form_children);

    // The multi-net shorthand (decouple (comp) COUNT per-pin REF "NET1" "NET2" …)
    // auto-applied the cap to every pin of each net — the same auto-discovery
    // footgun. Removed: write one (decouple "NET" (comp) COUNT per-pin REF
    // PIN1 PIN2 …) per rail so the decoupled pins are spelled out.
    if (first_val == .component or first_val == .component_instance) {
        log.warn("decouple no longer supports the multi-net (comp-first) form; " ++
            "write one (decouple \"NET\" (comp) COUNT per-pin REF PIN1 PIN2 …) per rail", .{});
        return EvalError.InvalidForm;
    } else {
        const net_name = first_val.asString() orelse return;

        // Check if children are (bulk ...) / (bypass ...) sub-forms
        var has_sub_forms = false;
        for (form_children[2..]) |sf| {
            if (sf.isForm("bulk") or sf.isForm("bypass")) {
                has_sub_forms = true;
                break;
            }
        }

        if (has_sub_forms) {
            for (form_children[2..]) |sf| {
                if (sf.isForm("bulk") or sf.isForm("bypass")) {
                    const sub = sf.asList().?;
                    try builders.emitDecoupleItems(self, sub[1..], net_name, env, instances, all_pin_nets, form_id, &sidecar);
                }
            }
        } else {
            try builders.emitDecoupleItems(self, form_children[2..], net_name, env, instances, all_pin_nets, form_id, &sidecar);
        }
    }
}

/// Mutable bag of pointers to the per-section accumulators that
/// `processSharedSectionForm` writes into. Bundling them lets both
/// `evalSection` and `evalSubSection` reuse the exact same handler for
/// the forms whose semantics are identical between the two scopes
/// (`description`, `note`, `port`, `protocol`, `calc`).
const SectionScope = struct {
    description: *[]const u8,
    notes: *std.ArrayListUnmanaged(env_mod.SectionNote),
    ports: *std.ArrayListUnmanaged(env_mod.SectionPort),
    protocols: *std.ArrayListUnmanaged([]const u8),
    calcs: *std.ArrayListUnmanaged(env_mod.CalcBlock),
};

/// Process a form whose handling is identical between a section and a
/// nested sub-section. Returns true when the form was consumed; the
/// caller's switch then has nothing to do for that variant.
fn processSharedSectionForm(
    self: *Evaluator,
    sf: ScopeForm,
    sf_children: []const Node,
    env: *Env,
    scope: SectionScope,
) EvalError!bool {
    switch (sf) {
        .description => {
            if (sf_children.len >= 2) {
                const dv = try self.evalNode(sf_children[1], env);
                scope.description.* = dv.asString() orelse "";
            }
            return true;
        },
        .note => {
            if (sf_children.len >= 2) {
                const nv = try self.evalNode(sf_children[1], env);
                if (nv.asString()) |first| {
                    var ref: ?env_mod.NoteRef = null;
                    var text = first;
                    for (sf_children[2..]) |extra| {
                        if (env_mod.parseNoteRef(extra)) |r| {
                            if (ref == null) ref = r;
                        } else if (extra.asString()) |s| {
                            // A second string is the note body — the labeled
                            // form `(note "SUBJECT" "text")`. Join so subject-
                            // tagged notes read naturally and don't warn.
                            text = std.fmt.allocPrint(self.allocator, "{s} — {s}", .{ text, s }) catch text;
                        } else if (!extra.isForm("id") and !extra.isForm("ids")) {
                            // (id …) anchors are inert residue from the
                            // auto-id inserter — skip without warning.
                            self.warnFmt(extra.span, "unknown note modifier in (note …) — expected (ref \"file.pdf\" (page N))", .{});
                        }
                    }
                    try scope.notes.append(self.allocator, .{ .text = text, .ref = ref });
                }
            }
            return true;
        },
        .port => {
            if (try builders.parseSectionPort(self, sf_children, env)) |p| {
                try scope.ports.append(self.allocator, p);
            }
            return true;
        },
        .protocol => {
            if (sf_children.len >= 2) {
                if (sf_children[1].asAtom()) |proto| {
                    try scope.protocols.append(self.allocator, proto);
                }
            }
            return true;
        },
        .calc => {
            if (try builders.parseSectionCalc(self, sf_children, env)) |c| {
                try scope.calcs.append(self.allocator, c);
            }
            return true;
        },
        else => return false,
    }
}

/// Evaluate a section form and its children.
fn evalSection(
    self: *Evaluator,
    form_children: []const Node,
    env: *Env,
    instances: *std.ArrayListUnmanaged(Instance),
    all_pin_nets: *std.ArrayListUnmanaged(PinNetDecl),
    notes: *std.ArrayListUnmanaged(Note),
    net_ties: *std.ArrayListUnmanaged(NetTie),
    sections: *std.ArrayListUnmanaged(env_mod.Section),
) EvalError!void {
    if (form_children.len < 2) return;
    const sec_name_val = try self.evalNode(form_children[1], env);
    const sec_name = sec_name_val.asString() orelse return;
    var sec_instances: std.ArrayListUnmanaged(Instance) = .empty;
    var sec_pin_groups: std.ArrayListUnmanaged(env_mod.PinGroup) = .empty;
    var sec_description: []const u8 = "";
    var sec_notes: std.ArrayListUnmanaged(env_mod.SectionNote) = .empty;
    var sec_ports: std.ArrayListUnmanaged(env_mod.SectionPort) = .empty;
    var sec_protocols: std.ArrayListUnmanaged([]const u8) = .empty;
    var sec_calcs: std.ArrayListUnmanaged(env_mod.CalcBlock) = .empty;
    var sec_sub_sections: std.ArrayListUnmanaged(env_mod.Section) = .empty;
    var block_role: env_mod.BlockRole = .auto;
    var diagram_hidden = false;
    var sec_category: []const u8 = "";
    var sec_hosts: std.ArrayListUnmanaged([]const u8) = .empty;

    // Check for optional description as 2nd positional string arg
    var child_start: usize = 2;
    if (form_children.len > 2) {
        if (form_children[2].asString()) |desc| {
            sec_description = desc;
            child_start = 3;
        }
    }

    const scope = SectionScope{
        .description = &sec_description,
        .notes = &sec_notes,
        .ports = &sec_ports,
        .protocols = &sec_protocols,
        .calcs = &sec_calcs,
    };

    for (form_children[child_start..]) |sf| {
        const sf_children = sf.asList() orelse continue;
        if (sf_children.len == 0) continue;
        const sf_name = sf_children[0].asAtom() orelse continue;
        const sft = ScopeForm.fromAtom(sf_name) orelse {
            if (!isInertFormHead(sf_name))
                self.warnFmt(sf.span, "unknown sub-form ({s} …) in (section …)", .{sf_name});
            continue;
        };

        if (try processSharedSectionForm(self, sft, sf_children, env, scope)) continue;

        switch (sft) {
            .role => {
                if (sf_children.len >= 2) {
                    if (sf_children[1].asAtom()) |role_str| {
                        if (std.mem.eql(u8, role_str, "input")) {
                            block_role = .input;
                        } else if (std.mem.eql(u8, role_str, "output")) {
                            block_role = .output;
                        } else {
                            self.warnFmt(sf_children[1].span, "unknown role '{s}' in (role …) — expected input|output", .{role_str});
                        }
                    }
                }
            },
            .diagram => {
                if (sf_children.len >= 2) {
                    if (sf_children[1].asAtom()) |mode| {
                        if (std.mem.eql(u8, mode, "hidden")) {
                            diagram_hidden = true;
                        } else {
                            self.warnFmt(sf_children[1].span, "unknown diagram mode '{s}' in (diagram …) — expected hidden", .{mode});
                        }
                    }
                }
            },
            .hosts => {
                for (sf_children[1..]) |h| {
                    if (h.asString()) |sub_name| try sec_hosts.append(self.allocator, sub_name);
                }
            },
            .category => {
                if (sf_children.len >= 2) sec_category = sf_children[1].asText() orelse "";
            },
            .bus_port => try builders.expandSectionBusPort(self, sf_children, env, &sec_ports),
            .instance => {
                const result = try instance_mod.buildInstance(self, sf_children, env);
                ids.registerRefDes(self, result.instance.ref_des);
                try instances.append(self.allocator, result.instance);
                try sec_instances.append(self.allocator, result.instance);
                for (result.pin_nets) |pn| try all_pin_nets.append(self.allocator, pn);
                for (result.inline_notes) |note| try notes.append(self.allocator, note);
                try appendAutoAliases(self, result.instance, result.pin_nets, net_ties);
            },
            .pins => try evalPinsForm(self, sf_children, sec_name, env, instances, all_pin_nets, net_ties, &sec_pin_groups),
            .decouple => {
                const pre_count = instances.items.len;
                try evalDecoupleForm(self, sf_children, env, instances, all_pin_nets);
                for (instances.items[pre_count..]) |new_inst| try sec_instances.append(self.allocator, new_inst);
            },
            .series => {
                const pre_s = instances.items.len;
                try instance_mod.evalSeriesForm(self, sf_children, env, instances, all_pin_nets, notes);
                for (instances.items[pre_s..]) |new_inst| try sec_instances.append(self.allocator, new_inst);
            },
            .fanout => {
                const pre_f = instances.items.len;
                try instance_mod.evalFanoutForm(self, sf_children, env, instances, all_pin_nets);
                for (instances.items[pre_f..]) |new_inst| try sec_instances.append(self.allocator, new_inst);
            },
            .net => try evalNetForm(self, sf_children, env, net_ties),
            .bus_net => try evalBusNetForm(self, sf_children, env, net_ties),
            .section => try evalSubSection(self, sf_children, env, instances, all_pin_nets, notes, net_ties, &sec_instances, &sec_sub_sections),
            // Shared-form variants are consumed above by
            // `processSharedSectionForm`; top-level-only forms are
            // ignored inside a section body (with a lint warning so the
            // silent skip is visible).
            .description, .note, .port, .protocol, .calc => {},
            .group,
            .function,
            .sub_block,
            .verifies,
            .test_point,
            .decouple_defaults,
            .kicad_pcb,
            .stub,
            .layout,
            .board,
            .revision,
            .rough,
            .stackup,
            .net_class,
            => {
                self.warnFmt(sf.span, "({s} …) is top-level-only — ignored inside (section …)", .{sf_name});
            },
        }
    }

    const final_instances = sec_instances.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory;
    const final_pin_groups = sec_pin_groups.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory;
    const final_sub_sections = sec_sub_sections.toOwnedSlice(self.allocator) catch &.{};

    // Infer status: concept if no instances, no pin_groups, and no sub-sections with content
    const status = if (final_instances.len == 0 and final_pin_groups.len == 0)
        env_mod.SectionStatus.concept
    else
        env_mod.SectionStatus.implemented;

    try sections.append(self.allocator, .{
        .name = sec_name,
        .description = sec_description,
        .notes = sec_notes.toOwnedSlice(self.allocator) catch &.{},
        .instances = final_instances,
        .pin_groups = final_pin_groups,
        .ports = sec_ports.toOwnedSlice(self.allocator) catch &.{},
        .protocols = sec_protocols.toOwnedSlice(self.allocator) catch &.{},
        .calcs = sec_calcs.toOwnedSlice(self.allocator) catch &.{},
        .sub_sections = final_sub_sections,
        .status = status,
        .block_role = block_role,
        .diagram_hidden = diagram_hidden,
        .category = sec_category,
        .hosts = sec_hosts.toOwnedSlice(self.allocator) catch &.{},
    });
}

/// Evaluate a (pins ...) form within a section.
fn evalPinsForm(
    self: *Evaluator,
    sf_children: []const Node,
    sec_name: []const u8,
    env: *Env,
    instances: *std.ArrayListUnmanaged(Instance),
    all_pin_nets: *std.ArrayListUnmanaged(PinNetDecl),
    net_ties: *std.ArrayListUnmanaged(NetTie),
    sec_pin_groups: *std.ArrayListUnmanaged(env_mod.PinGroup),
) EvalError!void {
    if (sf_children.len < 2) return;
    const pins_ref_val = try self.evalNode(sf_children[1], env);
    const pins_ref = pins_ref_val.asString() orelse return;

    // Sibling `(group "label")` applies its label to every PartPin in this block.
    var group_label: []const u8 = "";
    for (sf_children[2..]) |ch| {
        if (!ch.isForm("group")) continue;
        const gc = ch.asList() orelse continue;
        if (gc.len < 2) continue;
        const gv = try self.evalNode(gc[1], env);
        group_label = gv.asString() orelse (gc[1].asAtom() orelse "");
    }

    const pin_func_map = builders.findPinFuncMap(self, instances.items, pins_ref);
    var pg_pins: std.ArrayListUnmanaged(env_mod.PartPin) = .empty;
    for (sf_children[2..]) |pin_form| {
        if (pin_form.isForm("group")) continue;
        if (!builders.isKnownPinsChild(pin_form)) {
            builders.warnUnknownPinsChild(self, pin_form);
            continue;
        }
        try builders.processPinForm(self, pin_form, pins_ref, pin_func_map, env, all_pin_nets, &pg_pins, net_ties);
    }
    const pg_slice = pg_pins.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory;
    if (group_label.len > 0) {
        for (pg_slice) |*pp| pp.group = group_label;
    }
    try sec_pin_groups.append(self.allocator, .{ .ref_des = pins_ref, .pins = pg_slice, .group = group_label });
    try builders.addPartToInstance(self, instances.items, pins_ref, sec_name, pg_slice);
}

/// Evaluate a decouple form inside a section.
/// Evaluate a nested sub-section within a section.
fn evalSubSection(
    self: *Evaluator,
    sf_children: []const Node,
    env: *Env,
    instances: *std.ArrayListUnmanaged(Instance),
    all_pin_nets: *std.ArrayListUnmanaged(PinNetDecl),
    notes: *std.ArrayListUnmanaged(Note),
    net_ties: *std.ArrayListUnmanaged(NetTie),
    sec_instances: *std.ArrayListUnmanaged(Instance),
    sec_sub_sections: *std.ArrayListUnmanaged(env_mod.Section),
) EvalError!void {
    if (sf_children.len < 2) return;
    const sub_name_val = try self.evalNode(sf_children[1], env);
    const sub_name = sub_name_val.asString() orelse return;
    var sub_instances: std.ArrayListUnmanaged(Instance) = .empty;
    var sub_pin_groups: std.ArrayListUnmanaged(env_mod.PinGroup) = .empty;
    var sub_description: []const u8 = "";
    var sub_notes: std.ArrayListUnmanaged(env_mod.SectionNote) = .empty;
    var sub_ports: std.ArrayListUnmanaged(env_mod.SectionPort) = .empty;
    var sub_protocols: std.ArrayListUnmanaged([]const u8) = .empty;
    var sub_calcs: std.ArrayListUnmanaged(env_mod.CalcBlock) = .empty;

    const sub_scope = SectionScope{
        .description = &sub_description,
        .notes = &sub_notes,
        .ports = &sub_ports,
        .protocols = &sub_protocols,
        .calcs = &sub_calcs,
    };

    for (sf_children[2..]) |ssf| {
        const ssf_children = ssf.asList() orelse continue;
        if (ssf_children.len == 0) continue;
        const ssf_name = ssf_children[0].asAtom() orelse continue;
        const sft = ScopeForm.fromAtom(ssf_name) orelse {
            if (!isInertFormHead(ssf_name))
                self.warnFmt(ssf.span, "unknown sub-form ({s} …) in nested (section …)", .{ssf_name});
            continue;
        };

        if (try processSharedSectionForm(self, sft, ssf_children, env, sub_scope)) continue;

        switch (sft) {
            .bus_port => try builders.expandSectionBusPort(self, ssf_children, env, &sub_ports),
            .instance => {
                const result = try instance_mod.buildInstance(self, ssf_children, env);
                ids.registerRefDes(self, result.instance.ref_des);
                try instances.append(self.allocator, result.instance);
                try sec_instances.append(self.allocator, result.instance);
                try sub_instances.append(self.allocator, result.instance);
                for (result.pin_nets) |pn| try all_pin_nets.append(self.allocator, pn);
                for (result.inline_notes) |note| try notes.append(self.allocator, note);
                // Same as the top-level section instance handler: a nested
                // instance whose pin net differs from its pinout function name
                // must emit the auto-alias tie, or a net referenced elsewhere
                // by function name won't merge (wrong net membership).
                try appendAutoAliases(self, result.instance, result.pin_nets, net_ties);
            },
            .pins => {
                if (ssf_children.len < 2) continue;
                const pins_ref_val = try self.evalNode(ssf_children[1], env);
                const pins_ref = pins_ref_val.asString() orelse continue;
                // Sibling `(group "label")` parsing — mirrors `evalPinsForm`.
                // The nested copy used to drop it silently (and `group` isn't
                // warned because `isKnownPinsChild` whitelists it), so a nested
                // pin group's label just vanished.
                var group_label2: []const u8 = "";
                for (ssf_children[2..]) |ch| {
                    if (!ch.isForm("group")) continue;
                    const gc = ch.asList() orelse continue;
                    if (gc.len < 2) continue;
                    const gv = try self.evalNode(gc[1], env);
                    group_label2 = gv.asString() orelse (gc[1].asAtom() orelse "");
                }
                const pin_func_map2 = builders.findPinFuncMap(self, instances.items, pins_ref);
                var pg_pins2: std.ArrayListUnmanaged(env_mod.PartPin) = .empty;
                for (ssf_children[2..]) |pin_form| {
                    if (pin_form.isForm("group")) continue;
                    if (!builders.isKnownPinsChild(pin_form)) {
                        builders.warnUnknownPinsChild(self, pin_form);
                        continue;
                    }
                    try builders.processPinForm(self, pin_form, pins_ref, pin_func_map2, env, all_pin_nets, &pg_pins2, net_ties);
                }
                const pg_slice2 = pg_pins2.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory;
                if (group_label2.len > 0) {
                    for (pg_slice2) |*pp| pp.group = group_label2;
                }
                try sub_pin_groups.append(self.allocator, .{ .ref_des = pins_ref, .pins = pg_slice2, .group = group_label2 });
                try builders.addPartToInstance(self, instances.items, pins_ref, sub_name, pg_slice2);
            },
            .decouple => {
                const pre_count = instances.items.len;
                try evalDecoupleForm(self, ssf_children, env, instances, all_pin_nets);
                for (instances.items[pre_count..]) |new_inst| {
                    try sec_instances.append(self.allocator, new_inst);
                    try sub_instances.append(self.allocator, new_inst);
                }
            },
            .series => {
                const pre_s = instances.items.len;
                try instance_mod.evalSeriesForm(self, ssf_children, env, instances, all_pin_nets, notes);
                for (instances.items[pre_s..]) |new_inst| {
                    try sec_instances.append(self.allocator, new_inst);
                    try sub_instances.append(self.allocator, new_inst);
                }
            },
            .fanout => {
                const pre_f = instances.items.len;
                try instance_mod.evalFanoutForm(self, ssf_children, env, instances, all_pin_nets);
                for (instances.items[pre_f..]) |new_inst| {
                    try sec_instances.append(self.allocator, new_inst);
                    try sub_instances.append(self.allocator, new_inst);
                }
            },
            .net => try evalNetForm(self, ssf_children, env, net_ties),
            .bus_net => try evalBusNetForm(self, ssf_children, env, net_ties),
            // Sub-sections don't recurse, don't carry top-level-only
            // forms, and don't have `role`/`diagram`. Shared-form
            // variants went through `processSharedSectionForm` above;
            // anything else is ignored with a lint warning.
            .description, .note, .port, .protocol, .calc => {},
            else => {
                self.warnFmt(ssf.span, "({s} …) is not valid inside a nested (section …) — ignored", .{ssf_name});
            },
        }
    }
    const final_sub_instances = sub_instances.toOwnedSlice(self.allocator) catch &.{};
    const final_sub_pin_groups = sub_pin_groups.toOwnedSlice(self.allocator) catch &.{};

    const status = if (final_sub_instances.len == 0 and final_sub_pin_groups.len == 0)
        env_mod.SectionStatus.concept
    else
        env_mod.SectionStatus.implemented;

    try sec_sub_sections.append(self.allocator, .{
        .name = sub_name,
        .description = sub_description,
        .notes = sub_notes.toOwnedSlice(self.allocator) catch &.{},
        .instances = final_sub_instances,
        .pin_groups = final_sub_pin_groups,
        .ports = sub_ports.toOwnedSlice(self.allocator) catch &.{},
        .protocols = sub_protocols.toOwnedSlice(self.allocator) catch &.{},
        .calcs = sub_calcs.toOwnedSlice(self.allocator) catch &.{},
        .status = status,
    });
}

/// Resolve `name` to the canonical root of its tie-connected component.
/// Walks the parent chain; a name with no parent (or a self-parent) is its
/// own root. Structurally identical to `rails.findRoot`.
fn ufFind(uf: *std.StringHashMapUnmanaged([]const u8), name: []const u8) []const u8 {
    var cur = name;
    while (uf.get(cur)) |p| {
        if (std.mem.eql(u8, p, cur)) return cur;
        cur = p;
    }
    return cur;
}

/// Union the components of `a` and `b`, keeping `a`'s root as the canonical
/// survivor (preserving the historic `keep = nt.a` net-tie semantics — the
/// first-named net is the one that stays). Nets referenced only by a tie
/// (a bare trunk with no direct pins) still get a parent entry so their `.x`
/// bypass stubs later rename onto the canonical prefix.
fn ufUnion(
    allocator: std.mem.Allocator,
    uf: *std.StringHashMapUnmanaged([]const u8),
    a: []const u8,
    b: []const u8,
) EvalError!void {
    const ra = ufFind(uf, a);
    const rb = ufFind(uf, b);
    if (std.mem.eql(u8, ra, rb)) return;
    // Point b's root at a's root: a stays canonical.
    uf.put(allocator, rb, ra) catch return EvalError.OutOfMemory;
}

/// Build nets from collected pin-net declarations and net-ties.
fn buildNets(self: *Evaluator, all_pin_nets: *std.ArrayListUnmanaged(PinNetDecl), net_ties: *std.ArrayListUnmanaged(NetTie)) EvalError![]Net {
    var net_map: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(PinRef)) = .empty;
    for (all_pin_nets.items) |pn| {
        const gop = net_map.getOrPut(self.allocator, pn.net) catch return EvalError.OutOfMemory;
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        gop.value_ptr.append(self.allocator, .{
            .ref_des = pn.ref_des,
            .pin = pn.pin,
            .asserted_fns = pn.asserted_fns,
            .i_typ = pn.i_typ,
            .i_max = pn.i_max,
            .load_label = pn.load_label,
        }) catch return EvalError.OutOfMemory;
    }
    // Apply net-ties: merge tied nets transitively via union-find so a chain
    // like (net "A" "B") then (net "B" "C") collapses A+B+C into ONE net.
    //
    // The prior sequential pairwise merge was non-transitive and order-
    // dependent: it merged B into A and removed B, then the second tie's
    // getOrPut("B") *re-created* an empty net B and moved C's pins there,
    // leaving two disjoint nets where the author declared one — a silent
    // connectivity split (the worst class of bug in a netlist tool).
    //
    // Union-find keeps a canonical root per tie-connected component; every
    // net in a component is merged onto that root once, and the "REMOVE.x →
    // KEEP.x" bypass-stub rename runs against the canonical root at the end,
    // in a single pass (was O(ties × nets)).
    var uf: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (net_ties.items) |nt| {
        // A self-tie (a one-char typo like (net "X" "X")) is a no-op; skipping
        // it also avoids the by-value src-pins iteration over a buffer the
        // merge reallocates — a use-after-free that used to delete the net.
        if (std.mem.eql(u8, nt.a, nt.b)) continue;

        // Note: we no longer skip ties whose two trunk names are both absent
        // from net_map — a rail whose pads all sit on per-pin bypass stubs
        // (e.g. "VDD.U1.24") has NO direct-pin trunk net, yet its `.x` stubs
        // still need to rename onto the canonical root. Union is cheap and
        // never fabricates a net, so recording the relationship is always safe;
        // the merge/rename passes below only touch nets that actually exist.

        // Auto-aliases (synthesized from symbol pin-function names) must not
        // short-circuit two distinct user-declared nets. If both sides already
        // have pins, the user clearly meant them separate — e.g. the AD7380's
        // pin 19 is named "SDOA" in its pinout, but ad7380-channel uses
        // "SDOA_RAW" on the IC side of a damping resistor and "SDOA" on the
        // output side; merging those would jumper the 100Ω resistor. Compare
        // canonical roots so a prior tie can't sneak a populated net in via an
        // alias.
        if (nt.is_auto) {
            const ra = ufFind(&uf, nt.a);
            const rb = ufFind(&uf, nt.b);
            if (net_map.getPtr(ra) != null and net_map.getPtr(rb) != null) continue;
        }
        try ufUnion(self.allocator, &uf, nt.a, nt.b);
    }

    // Merge every non-root net's pins onto its canonical root, then drop it.
    {
        var merge_keys: std.ArrayListUnmanaged([]const u8) = .empty;
        var it = net_map.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            const root = ufFind(&uf, key);
            if (!std.mem.eql(u8, root, key)) {
                try merge_keys.append(self.allocator, key);
            }
        }
        for (merge_keys.items) |key| {
            const root = ufFind(&uf, key);
            // Remove the source net FIRST, then get-or-put the root — never hold
            // a value_ptr across a `fetchRemove`, whose backward-shift deletion
            // can move an entry (and invalidate a stale pointer into it).
            const kv = net_map.fetchRemove(key) orelse continue;
            var src = kv.value;
            // The root may not yet exist in net_map (a trunk with no direct
            // pins, e.g. a rail whose pads all sit on per-pin stubs); create it
            // so its `.x` stubs still rename to the canonical prefix below.
            const gop = net_map.getOrPut(self.allocator, root) catch return EvalError.OutOfMemory;
            if (!gop.found_existing) gop.value_ptr.* = .empty;
            for (src.items) |pin| {
                gop.value_ptr.append(self.allocator, pin) catch return EvalError.OutOfMemory;
            }
            src.deinit(self.allocator);
        }
    }

    // Rename per-pin bypass-stub nets "REMOVE.x" → "ROOT.x" in one pass, using
    // the canonical root for each non-root prefix (so chained ties collapse the
    // stubs onto the same trunk the missing_decoupling aggregation expects).
    {
        var rename_keys: std.ArrayListUnmanaged([]const u8) = .empty;
        var it = net_map.iterator();
        while (it.next()) |entry| {
            const key = entry.key_ptr.*;
            if (std.mem.indexOfScalar(u8, key, '.')) |dot| {
                const prefix = key[0..dot];
                const root = ufFind(&uf, prefix);
                if (!std.mem.eql(u8, root, prefix)) {
                    try rename_keys.append(self.allocator, key);
                }
            }
        }
        for (rename_keys.items) |old_key| {
            const dot = std.mem.indexOfScalar(u8, old_key, '.').?;
            const prefix = old_key[0..dot];
            const suffix = old_key[dot + 1 ..];
            const root = ufFind(&uf, prefix);
            const new_key = std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ root, suffix }) catch return EvalError.OutOfMemory;
            if (net_map.fetchRemove(old_key)) |kv| {
                // Fold into an existing same-named stub if the rename collides.
                const gop = net_map.getOrPut(self.allocator, new_key) catch return EvalError.OutOfMemory;
                if (!gop.found_existing) {
                    gop.value_ptr.* = kv.value;
                } else {
                    var src = kv.value;
                    for (src.items) |pin| {
                        gop.value_ptr.append(self.allocator, pin) catch return EvalError.OutOfMemory;
                    }
                    src.deinit(self.allocator);
                }
            }
        }
    }
    uf.deinit(self.allocator);
    // Convert to Net slice
    var nets: std.ArrayListUnmanaged(Net) = .empty;
    var net_iter = net_map.iterator();
    while (net_iter.next()) |entry| {
        nets.append(self.allocator, .{
            .name = entry.key_ptr.*,
            .pins = entry.value_ptr.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
        }) catch return EvalError.OutOfMemory;
    }
    return nets.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory;
}

/// Parse a top-level `(verifies (req "REFDES" REQID) "rationale" ...)` form.
/// Both the short form (single trailing string) and the long form with
/// `(rationale "...")` / `(signed-off-by "...")` / `(date "...")` sub-clauses
/// are accepted. Returns null when the form is malformed.
///
/// The target may be addressed two ways:
///   - `(req "U6" REQID)` — by ref-des (legacy; breaks on renumber).
///   - `(req (id b894897b) REQID)` — by the part's stable `(id …)` token,
///     which survives ref-des renumbering and sub-block renames. Sets
///     `Verification.target_id` and leaves `ref_des` empty.
/// The target of a `(verifies (req <target> …) …)` form: exactly one field is
/// non-empty. `(id <hex>)` selects by stable instance id; anything else is a
/// ref-des string.
const VerifyTarget = struct { ref_des: []const u8 = "", target_id: []const u8 = "" };

/// Parse the `<target>` node of a `(req <target> REQID)` clause. Returns null
/// when the node is a malformed `(id …)` form or a non-string ref-des. Uses the
/// same atom-or-string id tokenisation as `ids.parseId` (all-digit hex ids must
/// be quoted in source).
fn parseVerifyTarget(self: *Evaluator, node: Node, env: *Env) ?VerifyTarget {
    if (node.asList()) |id_form| {
        if (id_form.len < 2) return null;
        const id_head = id_form[0].asAtom() orelse return null;
        if (!std.mem.eql(u8, id_head, "id")) return null;
        const tok = id_form[1].asText() orelse return null;
        return .{ .target_id = tok };
    }
    const v = self.evalNode(node, env) catch return null;
    return .{ .ref_des = v.asString() orelse return null };
}

fn parseVerifies(self: *Evaluator, form_children: []const Node, env: *Env) ?env_mod.Verification {
    if (form_children.len < 2) return null;
    // form_children[0] = "verifies"; form_children[1] = (req <target> REQID)
    const req_form = form_children[1].asList() orelse return null;
    if (req_form.len < 3) return null;
    const req_head = req_form[0].asAtom() orelse return null;
    if (!std.mem.eql(u8, req_head, "req")) return null;

    // Target selector: `(id <hex>)` sub-form matches by stable instance id;
    // anything else is a ref-des string (see `parseVerifyTarget`).
    const target = parseVerifyTarget(self, req_form[1], env) orelse return null;
    const ref_des = target.ref_des;
    const target_id = target.target_id;
    // Accept atom (`b68c3fa5`) or string ("b68c3fa5"). All-digit hex ids
    // like "41510609" must be quoted as a string in the source — bare
    // digits would be tokenised as a decimal int and the AST has no way
    // to recover the original spelling. The id-freezing emitter quotes
    // these automatically, so this only matters for hand-written entries.
    const req_id = req_form[2].asAtom() orelse req_form[2].asString() orelse return null;

    var rationale: []const u8 = "";
    var signed_by: []const u8 = "";
    var date_str: []const u8 = "";

    for (form_children[2..]) |extra| {
        if (extra.asString()) |s| {
            // Short form: a single trailing string is the rationale.
            if (rationale.len == 0) rationale = s;
            continue;
        }
        const sub = extra.asList() orelse continue;
        if (sub.len < 2) continue;
        const sub_head = sub[0].asAtom() orelse continue;
        if (std.mem.eql(u8, sub_head, "rationale")) {
            if (sub[1].asString()) |s| rationale = s;
        } else if (std.mem.eql(u8, sub_head, "signed-off-by")) {
            if (sub[1].asString()) |s| signed_by = s;
            // Optional (date ...) inside signed-off-by
            for (sub[2..]) |inner| {
                const il = inner.asList() orelse continue;
                if (il.len < 2) continue;
                const ih = il[0].asAtom() orelse continue;
                if (std.mem.eql(u8, ih, "date")) {
                    if (il[1].asString()) |d| date_str = d;
                }
            }
        } else if (std.mem.eql(u8, sub_head, "date")) {
            if (sub[1].asString()) |d| date_str = d;
        }
    }

    return .{
        .ref_des = ref_des,
        .target_id = target_id,
        .req_id = req_id,
        .rationale = rationale,
        .signed_by = signed_by,
        .date = date_str,
    };
}

/// Parse a top-level `(rough …)` form into the design's rough-placement seed:
/// an optional `(anchor "REF")` and a list of `(group "name" "REF"…)` priority
/// tiers in authored (descending-priority) order. Member tokens stay raw
/// (ref-des or origin name) — `placement/optimizer.zig` matches them leniently.
/// A `(group …)` with no members is dropped; `(rough)` alone ⇒ `present=false`.
fn parseRough(self: *Evaluator, form_children: []const Node) EvalError!env_mod.RoughSpec {
    var anchor: []const u8 = "";
    var groups: std.ArrayListUnmanaged(env_mod.RoughGroup) = .empty;
    for (form_children[1..]) |child| {
        const cl = child.asList() orelse continue;
        if (cl.len == 0) continue;
        const head = cl[0].asAtom() orelse continue;
        if (std.mem.eql(u8, head, "anchor")) {
            if (cl.len >= 2) anchor = cl[1].asString() orelse cl[1].asAtom() orelse "";
        } else if (std.mem.eql(u8, head, "group")) {
            try parseRoughGroup(self, cl, &groups);
        } else {
            self.warnFmt(child.span, "unknown (rough …) item ({s} …) — expected (anchor …) or (group …)", .{head});
        }
    }
    const grp = groups.toOwnedSlice(self.allocator) catch &.{};
    return .{ .anchor = anchor, .groups = grp, .present = anchor.len > 0 or grp.len > 0 };
}

/// Parse one `(group "name" "REF"…)` child of a `(rough …)` form: the first
/// token is the cosmetic label, the rest are member ref-des / origin tokens.
/// A group with no members after the label is dropped (the caller never sees it).
fn parseRoughGroup(
    self: *Evaluator,
    cl: []const Node,
    out: *std.ArrayListUnmanaged(env_mod.RoughGroup),
) EvalError!void {
    if (cl.len < 2) return;
    const name = cl[1].asString() orelse cl[1].asAtom() orelse "";
    var members: std.ArrayListUnmanaged([]const u8) = .empty;
    for (cl[2..]) |m| {
        const tok = m.asString() orelse m.asAtom() orelse continue;
        members.append(self.allocator, tok) catch return EvalError.OutOfMemory;
    }
    if (members.items.len == 0) return;
    out.append(self.allocator, .{
        .name = name,
        .members = members.toOwnedSlice(self.allocator) catch &.{},
    }) catch return EvalError.OutOfMemory;
}

/// The product of evaluating one `(stub …)` form: the metadata record plus a
/// synthesised placeholder `Instance` (so the part flows through the existing
/// net/diagram/export machinery) and the pin-net declarations its signals
/// produce (so it participates in the flattened netlist that drives diagram
/// edges).
const StubResult = struct {
    part: env_mod.PlaceholderPart,
    instance: Instance,
    pin_nets: []const PinNetDecl,
};

/// Parse a top-level `(stub "name" (role "…") (mpn "…") (category <key>)
/// (size W H) (ref "REF") (signal "name" class "net") …)` placeholder-part
/// form. Auto-assigns a ref-des from the category prefix (overridden by an
/// explicit `(ref …)`), stamps a stable id (inserted into source on first
/// build), and turns each `(signal …)` into a `PinNetDecl` keyed by the signal
/// name so the stub wires into the diagram. Returns null when the stub has no
/// name. The synthesised instance carries `placeholder = true` and an empty
/// footprint — downstream ERC/export branch on that.
fn parseStub(self: *Evaluator, form_children: []const Node) EvalError!?StubResult {
    if (form_children.len < 2) return null;
    const name = form_children[1].asString() orelse form_children[1].asAtom() orelse return null;

    var role: []const u8 = "";
    var mpn: []const u8 = "";
    var category: []const u8 = "";
    var explicit_ref: []const u8 = "";
    var width: f64 = 0;
    var height: f64 = 0;
    var channels: u8 = 1;
    var signals: std.ArrayListUnmanaged(env_mod.PartSignal) = .empty;

    for (form_children[2..]) |sub_node| {
        const sub = sub_node.asList() orelse continue;
        if (sub.len < 2) continue;
        const head = sub[0].asAtom() orelse continue;
        if (std.mem.eql(u8, head, "role")) {
            role = sub[1].asString() orelse sub[1].asAtom() orelse "";
        } else if (std.mem.eql(u8, head, "mpn")) {
            mpn = sub[1].asString() orelse sub[1].asAtom() orelse "";
        } else if (std.mem.eql(u8, head, "category")) {
            category = sub[1].asAtom() orelse sub[1].asString() orelse "";
        } else if (std.mem.eql(u8, head, "ref")) {
            explicit_ref = sub[1].asString() orelse sub[1].asAtom() orelse "";
        } else if (std.mem.eql(u8, head, "size")) {
            if (sub.len >= 3) {
                width = sub[1].asNumber() orelse 0;
                height = sub[2].asNumber() orelse 0;
            }
        } else if (std.mem.eql(u8, head, "channels")) {
            // (channels N) — this stub stands for N identical channels.
            if (sub[1].asNumber()) |nf| {
                if (nf >= 1 and nf <= 255) channels = @intFromFloat(nf);
            }
        } else if (std.mem.eql(u8, head, "signal")) {
            // (signal "NAME" class "NET") — class optional in the middle slot.
            const sig_name = sub[1].asString() orelse sub[1].asAtom() orelse continue;
            var sig_class: []const u8 = "";
            var sig_net: []const u8 = "";
            if (sub.len >= 4) {
                sig_class = sub[2].asAtom() orelse sub[2].asString() orelse "";
                sig_net = sub[3].asString() orelse sub[3].asAtom() orelse "";
            } else if (sub.len == 3) {
                sig_net = sub[2].asString() orelse sub[2].asAtom() orelse "";
            }
            if (sig_net.len == 0) continue;
            try signals.append(self.allocator, .{ .name = sig_name, .class = sig_class, .net = sig_net });
        } else if (!isInertFormHead(head)) {
            self.warnFmt(sub_node.span, "unknown sub-form ({s} …) in (stub …)", .{head});
        }
    }

    const ref_des = if (explicit_ref.len > 0)
        explicit_ref
    else
        try ids.nextRefDes(self, ids.categoryPrefix(category));

    const part_id = try ids.getOrCreateFormId(self, form_children);

    const sig_slice = signals.toOwnedSlice(self.allocator) catch &.{};

    // One PinNetDecl per signal — the signal name is the virtual pin, so the
    // part participates in net-membership without a real pinout.
    var pin_nets: std.ArrayListUnmanaged(PinNetDecl) = .empty;
    for (sig_slice) |sig| {
        try pin_nets.append(self.allocator, .{ .ref_des = ref_des, .pin = sig.name, .net = sig.net });
    }

    const inst = Instance{
        .ref_des = ref_des,
        .label = ref_des,
        .origin_key = name,
        .component = name,
        .value = mpn,
        .footprint = "",
        .symbol = "",
        .id = part_id,
        .placeholder = true,
    };

    return .{
        .part = .{
            .ref_des = ref_des,
            .name = name,
            .role = role,
            .mpn = mpn,
            .category = category,
            .width = width,
            .height = height,
            .id = part_id,
            .channels = channels,
            .signals = sig_slice,
        },
        .instance = inst,
        .pin_nets = pin_nets.toOwnedSlice(self.allocator) catch &.{},
    };
}

/// Parse a top-level `(diagram-layout (anchor "name") (place "name" (rel "ref")…)…)`
/// form into a `LayoutSpec`. `(anchor "x")` and a bare `(place "x")` are pinned
/// roots (no constraints). `(place "x" (right-of "a") (below "b"))` carries
/// *several* constraints — x is positioned relative to every listed block, so a
/// block can be placed by more than one neighbour (recursive relative
/// placement). Unknown relation keywords and malformed sub-clauses are skipped
/// so a typo can't abort the build. Directive order is irrelevant — the solver
/// resolves by dependency, not source order.
fn parseLayout(self: *Evaluator, form_children: []const Node) EvalError!env_mod.LayoutSpec {
    var placements: std.ArrayListUnmanaged(env_mod.Placement) = .empty;
    var rows: std.ArrayListUnmanaged(env_mod.LayoutRow) = .empty;
    var groups: std.ArrayListUnmanaged(env_mod.LayoutGroup) = .empty;
    var edges: std.ArrayListUnmanaged(env_mod.LayoutEdge) = .empty;
    for (form_children[1..]) |child| {
        const c = child.asList() orelse continue;
        if (c.len < 2) continue;
        const head = c[0].asAtom() orelse continue;
        // (edge left|right "a" "b" …) — pin blocks to the diagram's L/R edge.
        if (std.mem.eql(u8, head, "edge")) {
            const side_atom = c[1].asAtom() orelse c[1].asString() orelse continue;
            const side: env_mod.EdgeSide = if (std.mem.eql(u8, side_atom, "right")) .right else .left;
            var members: std.ArrayListUnmanaged([]const u8) = .empty;
            for (c[2..]) |m| {
                const nm = m.asString() orelse m.asAtom() orelse continue;
                try members.append(self.allocator, nm);
            }
            try edges.append(self.allocator, .{
                .side = side,
                .members = members.toOwnedSlice(self.allocator) catch &.{},
            });
            continue;
        }
        // (row "a" "b" …) — an ordered horizontal band of block keys.
        if (std.mem.eql(u8, head, "row")) {
            var members: std.ArrayListUnmanaged([]const u8) = .empty;
            for (c[1..]) |m| {
                const nm = m.asString() orelse m.asAtom() orelse continue;
                try members.append(self.allocator, nm);
            }
            try rows.append(self.allocator, .{ .members = members.toOwnedSlice(self.allocator) catch &.{} });
            continue;
        }
        // (group "Label" "a" "b" …) — a labeled visual region over its members.
        if (std.mem.eql(u8, head, "group")) {
            const label = c[1].asString() orelse c[1].asAtom() orelse "";
            var members: std.ArrayListUnmanaged([]const u8) = .empty;
            for (c[2..]) |m| {
                const nm = m.asString() orelse m.asAtom() orelse continue;
                try members.append(self.allocator, nm);
            }
            try groups.append(self.allocator, .{
                .label = label,
                .members = members.toOwnedSlice(self.allocator) catch &.{},
            });
            continue;
        }
        const is_anchor = std.mem.eql(u8, head, "anchor");
        if (!is_anchor and !std.mem.eql(u8, head, "place")) continue;
        const name = c[1].asString() orelse c[1].asAtom() orelse continue;
        // (anchor "x") and bare (place "x") are pinned roots — no constraints.
        if (is_anchor) {
            try placements.append(self.allocator, .{ .name = name });
            continue;
        }
        // (place "x" (rel "ref") …) — collect every well-formed constraint.
        var constraints: std.ArrayListUnmanaged(env_mod.PlaceConstraint) = .empty;
        for (c[2..]) |rel_node| {
            const rel_form = rel_node.asList() orelse continue;
            if (rel_form.len < 2) continue;
            const rel_head = rel_form[0].asAtom() orelse continue;
            const rel = relFromAtom(rel_head) orelse continue;
            const ref = rel_form[1].asString() orelse rel_form[1].asAtom() orelse continue;
            try constraints.append(self.allocator, .{ .rel = rel, .reference = ref });
        }
        try placements.append(self.allocator, .{
            .name = name,
            .constraints = constraints.toOwnedSlice(self.allocator) catch &.{},
        });
    }
    return .{
        .placements = placements.toOwnedSlice(self.allocator) catch &.{},
        .rows = rows.toOwnedSlice(self.allocator) catch &.{},
        .groups = groups.toOwnedSlice(self.allocator) catch &.{},
        .edges = edges.toOwnedSlice(self.allocator) catch &.{},
    };
}

/// Map a `(place …)` relation keyword to a `PlaceRel`. Returns null for an
/// unrecognised keyword so `parseLayout` can skip the directive.
fn relFromAtom(atom: []const u8) ?env_mod.PlaceRel {
    if (std.mem.eql(u8, atom, "right-of")) return .right_of;
    if (std.mem.eql(u8, atom, "left-of")) return .left_of;
    if (std.mem.eql(u8, atom, "above")) return .above;
    if (std.mem.eql(u8, atom, "below")) return .below;
    return null;
}

/// Map a board edge keyword (`left`/`right`/`top`/`bottom`) to a
/// `PlacementSide`. Returns null for anything else so `parseBoardSides` can skip
/// an unrecognised head (`size`, `corners`).
fn placementSideFromAtom(atom: []const u8) ?env_mod.PlacementSide {
    if (std.mem.eql(u8, atom, "left")) return .left;
    if (std.mem.eql(u8, atom, "right")) return .right;
    if (std.mem.eql(u8, atom, "top")) return .top;
    if (std.mem.eql(u8, atom, "bottom")) return .bottom;
    return null;
}

/// Parse the `(left|right|top|bottom …)` edge lists of a `(board …)` form into
/// `PlacementSideSpec`s. Each list names the parts docked to that physical board
/// edge; an item is a bare ref (`"usbc"`) or a rotation override `(rot <deg>
/// "REF")`. Heads that aren't edge keywords (`size`, `corners`) are skipped here
/// — `parseBoard` reads them. Unknown side keywords / malformed items are skipped
/// so a typo can't abort the build.
fn parseBoardSides(self: *Evaluator, form_children: []const Node) EvalError![]const env_mod.PlacementSideSpec {
    var sides: std.ArrayListUnmanaged(env_mod.PlacementSideSpec) = .empty;
    for (form_children[1..]) |child| {
        const c = child.asList() orelse continue;
        if (c.len < 1) continue;
        const head = c[0].asAtom() orelse continue;
        const side = placementSideFromAtom(head) orelse continue;
        var items: std.ArrayListUnmanaged(env_mod.PlacementItem) = .empty;
        for (c[1..]) |item_node| {
            // (rot <deg> "REF") rotation override, or a bare ref string/atom.
            if (item_node.asList()) |il| {
                const ihead = il[0].asAtom() orelse "";
                if (il.len >= 3 and std.mem.eql(u8, ihead, "rot")) {
                    const deg = il[1].asNumber() orelse continue;
                    const ref = il[2].asString() orelse il[2].asAtom() orelse continue;
                    items.append(self.allocator, .{ .ref = ref, .rot = deg }) catch return EvalError.OutOfMemory;
                }
                continue;
            }
            const ref = item_node.asString() orelse item_node.asAtom() orelse continue;
            items.append(self.allocator, .{ .ref = ref }) catch return EvalError.OutOfMemory;
        }
        sides.append(self.allocator, .{
            .side = side,
            .items = items.toOwnedSlice(self.allocator) catch &.{},
        }) catch return EvalError.OutOfMemory;
    }
    return sides.toOwnedSlice(self.allocator) catch &.{};
}

/// Parse a top-level `(board …)` form: `(size W H)` outline (mm) + per-edge item
/// lists (`(left|right|top|bottom …)`, the words naming physical board edges) +
/// `(corners "REF" …)` mounting hardware. The edge lists are parsed by
/// `parseBoardSides`; this adds the size and corners on top.
fn parseBoard(self: *Evaluator, form_children: []const Node) EvalError!env_mod.BoardSpec {
    const board_sides = try parseBoardSides(self, form_children);
    var w: f64 = 0;
    var h: f64 = 0;
    var corner_radius: f64 = 0;
    var corners: std.ArrayListUnmanaged(env_mod.PlacementItem) = .empty;
    for (form_children[1..]) |child| {
        const c = child.asList() orelse continue;
        if (c.len < 1) continue;
        const head = c[0].asAtom() orelse continue;
        if (std.mem.eql(u8, head, "size")) {
            if (c.len >= 3) {
                w = c[1].asNumber() orelse 0;
                h = c[2].asNumber() orelse 0;
            }
            continue;
        }
        if (std.mem.eql(u8, head, "corner-radius")) {
            if (c.len >= 2) corner_radius = @max(c[1].asNumber() orelse 0, 0);
            continue;
        }
        if (std.mem.eql(u8, head, "corners")) {
            for (c[1..]) |item_node| {
                const ref = item_node.asString() orelse item_node.asAtom() orelse continue;
                corners.append(self.allocator, .{ .ref = ref }) catch return EvalError.OutOfMemory;
            }
        }
    }
    return .{
        .w = w,
        .h = h,
        .corner_radius = corner_radius,
        .sides = board_sides,
        .corners = corners.toOwnedSlice(self.allocator) catch &.{},
        .present = true,
    };
}

/// Parse a top-level `(stackup N (plane IDX "NET")…)` form into a
/// `StackupSpec`. N (total copper layers) is required and must be ≥1; a
/// malformed count leaves the spec absent (warned) so a typo can't silently
/// change the routing model. `(plane …)` entries with a bad index (0 or > N)
/// are skipped with a warning.
fn parseStackup(self: *Evaluator, form_children: []const Node) EvalError!env_mod.StackupSpec {
    if (form_children.len < 2) {
        self.warnFmt(form_children[0].span, "(stackup …) needs a copper layer count, e.g. (stackup 2)", .{});
        return .{};
    }
    const n_raw = form_children[1].asNumber() orelse {
        self.warnFmt(form_children[1].span, "(stackup …) layer count must be a number", .{});
        return .{};
    };
    if (n_raw < 1 or n_raw > 32 or n_raw != @floor(n_raw)) {
        self.warnFmt(form_children[1].span, "(stackup …) layer count must be a whole number 1–32", .{});
        return .{};
    }
    const layers: u8 = @intFromFloat(n_raw);
    var planes: std.ArrayListUnmanaged(env_mod.StackupPlane) = .empty;
    for (form_children[2..]) |child| {
        const c = child.asList() orelse continue;
        if (c.len < 1) continue;
        const head = c[0].asAtom() orelse continue;
        if (!std.mem.eql(u8, head, "plane")) {
            self.warnFmt(c[0].span, "unknown (stackup …) sub-form ({s} …) — expected (plane IDX \"NET\")", .{head});
            continue;
        }
        if (c.len < 3) {
            self.warnFmt(c[0].span, "(plane …) needs a layer index and a net name", .{});
            continue;
        }
        const idx_raw = c[1].asNumber() orelse {
            self.warnFmt(c[1].span, "(plane …) layer index must be a number", .{});
            continue;
        };
        if (idx_raw < 1 or idx_raw > n_raw or idx_raw != @floor(idx_raw)) {
            self.warnFmt(c[1].span, "(plane …) layer index out of range for this stackup", .{});
            continue;
        }
        const net = c[2].asString() orelse c[2].asAtom() orelse {
            self.warnFmt(c[2].span, "(plane …) net must be a name", .{});
            continue;
        };
        planes.append(self.allocator, .{ .index = @intFromFloat(idx_raw), .net = net }) catch return EvalError.OutOfMemory;
    }
    return .{
        .layers = layers,
        .planes = planes.toOwnedSlice(self.allocator) catch &.{},
        .present = true,
    };
}

/// Parse one top-level `(net-class "name" (width MM) (clearance MM)
/// (via DIA DRILL) (priority 0-7) (nets "A" …))` form. Null (with a warning)
/// when the name or the `(nets …)` list is missing — a class that names no
/// nets can't apply.
fn parseNetClass(self: *Evaluator, form_children: []const Node) EvalError!?env_mod.NetClassSpec {
    if (form_children.len < 2) {
        self.warnFmt(form_children[0].span, "(net-class …) needs a name, e.g. (net-class \"power\" …)", .{});
        return null;
    }
    const name = form_children[1].asString() orelse form_children[1].asAtom() orelse {
        self.warnFmt(form_children[1].span, "(net-class …) name must be a string", .{});
        return null;
    };
    var spec = env_mod.NetClassSpec{ .name = name };
    var nets: std.ArrayListUnmanaged([]const u8) = .empty;
    for (form_children[2..]) |child| {
        const c = child.asList() orelse continue;
        if (c.len < 1) continue;
        const head = c[0].asAtom() orelse continue;
        if (std.mem.eql(u8, head, "width")) {
            if (c.len >= 2) spec.width = c[1].asNumber() orelse 0;
        } else if (std.mem.eql(u8, head, "clearance")) {
            if (c.len >= 2) spec.clearance = c[1].asNumber() orelse 0;
        } else if (std.mem.eql(u8, head, "via")) {
            if (c.len >= 2) spec.via_dia = c[1].asNumber() orelse 0;
            if (c.len >= 3) spec.via_drill = c[2].asNumber() orelse 0;
        } else if (std.mem.eql(u8, head, "priority")) {
            if (c.len >= 2) {
                const n = c[1].asNumber() orelse 0;
                if (n < 0 or n > 7) self.warnFmt(c[1].span, "(net-class …) (priority …) is 0-7; clamping {d}", .{n});
                spec.priority = @intFromFloat(std.math.clamp(n, 0, 7));
            }
        } else if (std.mem.eql(u8, head, "nets")) {
            for (c[1..]) |net_node| {
                const net = net_node.asString() orelse net_node.asAtom() orelse continue;
                nets.append(self.allocator, net) catch return EvalError.OutOfMemory;
            }
        } else {
            self.warnFmt(c[0].span, "unknown (net-class …) sub-form ({s} …)", .{head});
        }
    }
    if (nets.items.len == 0) {
        self.warnFmt(form_children[0].span, "(net-class \"{s}\" …) names no nets — add (nets \"A\" …)", .{name});
        return null;
    }
    spec.nets = nets.toOwnedSlice(self.allocator) catch &.{};
    return spec;
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

// spec: eval/design_block - kicad-pcb form captures the literal path on the design block
test "design-block captures (kicad-pcb path)" {
    // Drive the full evaluator with a tiny design-block source: the
    // form should land on `DesignBlock.kicad_pcb_path` as the literal
    // string the user typed, with no expansion or canonicalisation.
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (kicad-pcb "/mnt/nas/test.kicad_pcb"))
    ;
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;

    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();

    const value = try evalDesignBlock(&eval, form_children[1..], &env);
    const block = switch (value) {
        .design_block => |b| b,
        else => return error.TestUnexpectedResult,
    };
    try testing.expect(block.kicad_pcb_path != null);
    try testing.expectEqualStrings("/mnt/nas/test.kicad_pcb", block.kicad_pcb_path.?);
}

// spec: eval/design_block - stackup form captures layer count and plane assignments on the design block
test "design-block captures (stackup …)" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (stackup 4 (plane 2 "GND") (plane 3 "PWR")))
    ;
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;
    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();
    const value = try evalDesignBlock(&eval, form_children[1..], &env);
    const block = switch (value) {
        .design_block => |b| b,
        else => return error.TestUnexpectedResult,
    };
    try testing.expect(block.stackup.present);
    try testing.expectEqual(@as(u8, 4), block.stackup.layers);
    try testing.expectEqual(@as(usize, 2), block.stackup.planes.len);
    try testing.expectEqual(@as(u8, 2), block.stackup.planes[0].index);
    try testing.expectEqualStrings("GND", block.stackup.planes[0].net);
    try testing.expectEqualStrings("PWR", block.stackup.planes[1].net);
}

// spec: eval/design_block - a bare 2-layer stackup declares no planes so ground routes as copper
test "design-block captures a plane-less (stackup 2)" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (stackup 2))
    ;
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;
    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();
    const value = try evalDesignBlock(&eval, form_children[1..], &env);
    const block = switch (value) {
        .design_block => |b| b,
        else => return error.TestUnexpectedResult,
    };
    try testing.expect(block.stackup.present);
    try testing.expectEqual(@as(u8, 2), block.stackup.layers);
    try testing.expect(!block.stackup.hasPlanes());
}

// spec: eval/design_block - net-class forms capture width/clearance/via geometry and routing priority for their listed nets
test "design-block captures (net-class …) rules" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (net-class "power" (width 0.3) (clearance 0.2) (via 0.5 0.3) (nets "VBUS" "+5V"))
        \\  (net-class "hot" (priority 3) (nets "SW"))
        \\  (net-class "over" (priority 99) (nets "CLK"))
        \\  (net-class "broken-no-nets" (width 1.0)))
    ;
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;
    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();
    const value = try evalDesignBlock(&eval, form_children[1..], &env);
    const block = switch (value) {
        .design_block => |b| b,
        else => return error.TestUnexpectedResult,
    };
    // The nets-less class is dropped (warned), the valid ones are kept intact.
    try testing.expectEqual(@as(usize, 3), block.net_classes.len);
    const nc = block.net_classes[0];
    try testing.expectEqualStrings("power", nc.name);
    try testing.expectEqual(@as(f64, 0.3), nc.width);
    try testing.expectEqual(@as(f64, 0.2), nc.clearance);
    try testing.expectEqual(@as(f64, 0.5), nc.via_dia);
    try testing.expectEqual(@as(f64, 0.3), nc.via_drill);
    try testing.expectEqual(@as(u32, 0), nc.priority); // no (priority …) ⇒ baseline tier
    try testing.expectEqual(@as(usize, 2), nc.nets.len);
    try testing.expectEqualStrings("VBUS", nc.nets[0]);
    // Routing-order tier is captured, and an out-of-range value clamps to 7.
    try testing.expectEqual(@as(u32, 3), block.net_classes[1].priority);
    try testing.expectEqual(@as(u32, 7), block.net_classes[2].priority);
}

// spec: eval/design_block - net ties merge transitively so a chained tie collapses all three nets into one
test "buildNets merges chained ties into a single net" {
    const a = std.heap.page_allocator;
    var eval = Evaluator.init(a, "");
    defer eval.deinit();

    // One pin on each of A, B, C, then chain-tie A=B and B=C. All three must
    // collapse into ONE net — the old pairwise merge re-created net B.
    var pins: std.ArrayListUnmanaged(PinNetDecl) = .empty;
    try pins.append(a, .{ .ref_des = "U1", .pin = "1", .net = "A" });
    try pins.append(a, .{ .ref_des = "U2", .pin = "1", .net = "B" });
    try pins.append(a, .{ .ref_des = "U3", .pin = "1", .net = "C" });
    var ties: std.ArrayListUnmanaged(NetTie) = .empty;
    try ties.append(a, .{ .a = "A", .b = "B" });
    try ties.append(a, .{ .a = "B", .b = "C" });

    const nets = try buildNets(&eval, &pins, &ties);
    try testing.expectEqual(@as(usize, 1), nets.len);
    try testing.expectEqualStrings("A", nets[0].name);
    try testing.expectEqual(@as(usize, 3), nets[0].pins.len);
}

// spec: eval/design_block - a reverse-order chained tie also collapses all nets onto the canonical root
test "buildNets merges reverse-order chained ties" {
    const a = std.heap.page_allocator;
    var eval = Evaluator.init(a, "");
    defer eval.deinit();

    var pins: std.ArrayListUnmanaged(PinNetDecl) = .empty;
    try pins.append(a, .{ .ref_des = "U1", .pin = "1", .net = "A" });
    try pins.append(a, .{ .ref_des = "U2", .pin = "1", .net = "B" });
    try pins.append(a, .{ .ref_des = "U3", .pin = "1", .net = "C" });
    // (net "A" "B") then (net "C" "B") — remove side (B) already merged away.
    var ties: std.ArrayListUnmanaged(NetTie) = .empty;
    try ties.append(a, .{ .a = "A", .b = "B" });
    try ties.append(a, .{ .a = "C", .b = "B" });

    const nets = try buildNets(&eval, &pins, &ties);
    try testing.expectEqual(@as(usize, 1), nets.len);
    try testing.expectEqual(@as(usize, 3), nets[0].pins.len);
}

// spec: eval/design_block - a self-tie is a harmless no-op, never deleting the net
test "buildNets self-tie is a no-op" {
    const a = std.heap.page_allocator;
    var eval = Evaluator.init(a, "");
    defer eval.deinit();

    var pins: std.ArrayListUnmanaged(PinNetDecl) = .empty;
    try pins.append(a, .{ .ref_des = "U1", .pin = "1", .net = "X" });
    try pins.append(a, .{ .ref_des = "U2", .pin = "2", .net = "X" });
    var ties: std.ArrayListUnmanaged(NetTie) = .empty;
    try ties.append(a, .{ .a = "X", .b = "X" });

    const nets = try buildNets(&eval, &pins, &ties);
    try testing.expectEqual(@as(usize, 1), nets.len);
    try testing.expectEqualStrings("X", nets[0].name);
    try testing.expectEqual(@as(usize, 2), nets[0].pins.len);
}

// spec: eval/design_block - a tie renames per-pin bypass stubs onto the canonical root prefix
test "buildNets renames bypass stubs onto the canonical root" {
    const a = std.heap.page_allocator;
    var eval = Evaluator.init(a, "");
    defer eval.deinit();

    // A bypass-stub net "VDD3V3.U1.24" whose trunk "VDD3V3" is tied to "3V3":
    // the stub must rename to "3V3.U1.24" so missing_decoupling aggregation
    // sees it under the canonical prefix.
    var pins: std.ArrayListUnmanaged(PinNetDecl) = .empty;
    try pins.append(a, .{ .ref_des = "C1", .pin = "1", .net = "VDD3V3.U1.24" });
    try pins.append(a, .{ .ref_des = "U1", .pin = "24", .net = "3V3" });
    var ties: std.ArrayListUnmanaged(NetTie) = .empty;
    try ties.append(a, .{ .a = "3V3", .b = "VDD3V3" });

    const nets = try buildNets(&eval, &pins, &ties);
    var found_stub = false;
    for (nets) |n| {
        if (std.mem.eql(u8, n.name, "3V3.U1.24")) found_stub = true;
        try testing.expect(!std.mem.startsWith(u8, n.name, "VDD3V3."));
    }
    try testing.expect(found_stub);
}

// spec: eval/design_block - board form parses outline size, corner radius, edge lists, and corners
test "design-block parses a (board ...) form" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (board (size 80 55)
        \\    (corner-radius 3)
        \\    (left "usbc" "rj45")
        \\    (right (rot 90 "sma1"))
        \\    (corners "MK1" "MK2" "MK3" "MK4")))
    ;
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;
    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();
    const block = (try evalDesignBlock(&eval, form_children[1..], &env)).design_block;
    try testing.expect(block.board.present);
    try testing.expectApproxEqAbs(@as(f64, 80), block.board.w, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 55), block.board.h, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 3), block.board.corner_radius, 1e-9);
    try testing.expectEqual(@as(usize, 2), block.board.sides.len);
    try testing.expectEqualStrings("usbc", block.board.sides[0].items[0].ref);
    try testing.expectEqual(@as(f64, 90), block.board.sides[1].items[0].rot.?);
    try testing.expectEqual(@as(usize, 4), block.board.corners.len);
    try testing.expectEqualStrings("MK3", block.board.corners[2].ref);
}

// spec: eval/design_block - revision form captures id, date, and newest-first changelog
test "design-block parses a (revision ...) form" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (revision "F4"
        \\    (date "2026-06-15")
        \\    (change "F4" "Removed antenna-select switch")
        \\    (change "E" "First fab spin")))
    ;
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;
    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();
    const block = (try evalDesignBlock(&eval, form_children[1..], &env)).design_block;
    try testing.expect(block.revision.present);
    try testing.expectEqualStrings("F4", block.revision.id);
    try testing.expectEqualStrings("2026-06-15", block.revision.date);
    try testing.expectEqual(@as(usize, 2), block.revision.changes.len);
    try testing.expectEqualStrings("F4", block.revision.changes[0].id);
    try testing.expectEqualStrings("Removed antenna-select switch", block.revision.changes[0].summary);
    try testing.expectEqualStrings("E", block.revision.changes[1].id);
}

// spec: eval/design_block - revision form with only an id is present with empty date/changelog
test "design-block parses a bare (revision id) form" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (revision "A"))
    ;
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;
    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();
    const block = (try evalDesignBlock(&eval, form_children[1..], &env)).design_block;
    try testing.expect(block.revision.present);
    try testing.expectEqualStrings("A", block.revision.id);
    try testing.expectEqualStrings("", block.revision.date);
    try testing.expectEqual(@as(usize, 0), block.revision.changes.len);
}

// spec: eval/design_block - a design with no (revision …) form is unversioned (present=false)
test "design-block without a revision form is unversioned" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test")
    ;
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;
    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();
    const block = (try evalDesignBlock(&eval, form_children[1..], &env)).design_block;
    try testing.expect(!block.revision.present);
}

// spec: eval/design_block - hosts form records the sub-block instance names a section owns
test "section (hosts …) records owned sub-block names" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (section "PSU" (hosts "psu1" "mon_ch1")))
    ;
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;

    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();

    const value = try evalDesignBlock(&eval, form_children[1..], &env);
    const block = value.design_block;
    try testing.expectEqual(@as(usize, 1), block.sections.len);
    try testing.expectEqual(@as(usize, 2), block.sections[0].hosts.len);
    try testing.expectEqualStrings("psu1", block.sections[0].hosts[0]);
    try testing.expectEqualStrings("mon_ch1", block.sections[0].hosts[1]);
}

// spec: eval/design_block - stub form parses a placeholder part with role, mpn, category, and size
test "stub form parses role mpn category and size" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (stub "my-mcu" (role "Host MCU") (mpn "STM32H563") (category mcu) (size 9 9)))
    ;
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;
    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();
    const block = (try evalDesignBlock(&eval, form_children[1..], &env)).design_block;
    try testing.expectEqual(@as(usize, 1), block.parts.len);
    const p = block.parts[0];
    try testing.expectEqualStrings("my-mcu", p.name);
    try testing.expectEqualStrings("Host MCU", p.role);
    try testing.expectEqualStrings("STM32H563", p.mpn);
    try testing.expectEqualStrings("mcu", p.category);
    try testing.expectEqual(@as(f64, 9), p.width);
    try testing.expectEqual(@as(f64, 9), p.height);
    // It also auto-places: a placeholder instance with the part's ref-des.
    try testing.expectEqual(@as(usize, 1), block.instances.len);
    try testing.expect(block.instances[0].placeholder);
}

// spec: eval/design_block - stub auto-assigns a ref-des from the category prefix when ref is omitted
test "stub auto-assigns a ref-des from the category prefix" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (stub "j" (category connector))
        \\  (stub "u" (category mcu))
        \\  (stub "x" (category power) (ref "U7")))
    ;
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;
    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();
    const block = (try evalDesignBlock(&eval, form_children[1..], &env)).design_block;
    try testing.expectEqual(@as(usize, 3), block.parts.len);
    try testing.expectEqual(@as(u8, 'J'), block.parts[0].ref_des[0]); // connector → J
    try testing.expectEqual(@as(u8, 'U'), block.parts[1].ref_des[0]); // mcu → U
    try testing.expectEqualStrings("U7", block.parts[2].ref_des); // explicit (ref) wins
}

// spec: eval/design_block - stub signal contributes a named virtual pin tied to a net so the stub joins the netlist
test "stub signal contributes net membership" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (stub "a" (category mcu) (signal "SCL" i2c "I2C"))
        \\  (stub "b" (category sensor) (signal "SCL" i2c "I2C")))
    ;
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;
    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();
    const block = (try evalDesignBlock(&eval, form_children[1..], &env)).design_block;
    // Both stubs' "SCL" signal joins the shared "I2C" net → 2 pins on it.
    var pins_on_i2c: usize = 0;
    for (block.nets) |net| {
        if (std.mem.eql(u8, net.name, "I2C")) pins_on_i2c = net.pins.len;
    }
    try testing.expectEqual(@as(usize, 2), pins_on_i2c);
}

// spec: eval/design_block - stub channels count stacks the block as N identical channels in the diagram
test "stub channels count is recorded on the part" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (stub "psu" (category power) (channels 2))
        \\  (stub "solo" (category power)))
    ;
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;
    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();
    const block = (try evalDesignBlock(&eval, form_children[1..], &env)).design_block;
    try testing.expectEqual(@as(u8, 2), block.parts[0].channels);
    try testing.expectEqual(@as(u8, 1), block.parts[1].channels); // default
}

// spec: eval/design_block - layout form parses (anchor "name") roots and (place "name" (rel "ref")) directives
test "design-block parses a (layout …) form with anchor and place" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (diagram-layout
        \\    (anchor "rp2350")
        \\    (place "esp32" (right-of "rp2350"))))
    ;
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;

    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();

    const block = (try evalDesignBlock(&eval, form_children[1..], &env)).design_block;
    try testing.expectEqual(@as(usize, 2), block.layout.placements.len);
    // Anchor: a placement with no constraints.
    try testing.expectEqualStrings("rp2350", block.layout.placements[0].name);
    try testing.expectEqual(@as(usize, 0), block.layout.placements[0].constraints.len);
    // Relative: one constraint, right-of rp2350.
    try testing.expectEqualStrings("esp32", block.layout.placements[1].name);
    try testing.expectEqual(@as(usize, 1), block.layout.placements[1].constraints.len);
    try testing.expectEqual(env_mod.PlaceRel.right_of, block.layout.placements[1].constraints[0].rel);
    try testing.expectEqualStrings("rp2350", block.layout.placements[1].constraints[0].reference);
}

// spec: eval/design_block - layout place resolves right-of/left-of/above/below into a relative offset from the referenced block
test "layout place parses each relation keyword" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (diagram-layout
        \\    (place "b" (right-of "a"))
        \\    (place "c" (left-of "a"))
        \\    (place "d" (above "a"))
        \\    (place "e" (below "a"))))
    ;
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;

    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();

    const block = (try evalDesignBlock(&eval, form_children[1..], &env)).design_block;
    try testing.expectEqual(@as(usize, 4), block.layout.placements.len);
    try testing.expectEqual(env_mod.PlaceRel.right_of, block.layout.placements[0].constraints[0].rel);
    try testing.expectEqual(env_mod.PlaceRel.left_of, block.layout.placements[1].constraints[0].rel);
    try testing.expectEqual(env_mod.PlaceRel.above, block.layout.placements[2].constraints[0].rel);
    try testing.expectEqual(env_mod.PlaceRel.below, block.layout.placements[3].constraints[0].rel);
}

// spec: eval/design_block - layout place collects multiple constraints so a block is positioned by several references
test "layout place collects multiple constraints" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (diagram-layout
        \\    (place "c" (right-of "b") (below "a"))))
    ;
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;

    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();

    const block = (try evalDesignBlock(&eval, form_children[1..], &env)).design_block;
    try testing.expectEqual(@as(usize, 1), block.layout.placements.len);
    const cons = block.layout.placements[0].constraints;
    try testing.expectEqual(@as(usize, 2), cons.len);
    try testing.expectEqual(env_mod.PlaceRel.right_of, cons[0].rel);
    try testing.expectEqualStrings("b", cons[0].reference);
    try testing.expectEqual(env_mod.PlaceRel.below, cons[1].rel);
    try testing.expectEqualStrings("a", cons[1].reference);
}

// spec: eval/design_block - layout row form parses an ordered band of block keys
test "layout row parses an ordered band of block keys" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (diagram-layout
        \\    (row "mcu" "esp32" "screen")
        \\    (row "buck5v" "buck3v3")))
    ;
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;

    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();

    const block = (try evalDesignBlock(&eval, form_children[1..], &env)).design_block;
    try testing.expectEqual(@as(usize, 2), block.layout.rows.len);
    try testing.expectEqual(@as(usize, 3), block.layout.rows[0].members.len);
    try testing.expectEqualStrings("mcu", block.layout.rows[0].members[0]);
    try testing.expectEqualStrings("screen", block.layout.rows[0].members[2]);
    try testing.expectEqual(@as(usize, 2), block.layout.rows[1].members.len);
    try testing.expectEqualStrings("buck3v3", block.layout.rows[1].members[1]);
}

// spec: eval/design_block - layout group form parses a labeled region over member block keys
test "layout group parses a labeled region over member keys" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (diagram-layout
        \\    (group "Brains" "mcu" "esp32")
        \\    (group "Power" "buck5v" "buck3v3" "or_diode")))
    ;
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;

    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();

    const block = (try evalDesignBlock(&eval, form_children[1..], &env)).design_block;
    try testing.expectEqual(@as(usize, 2), block.layout.groups.len);
    try testing.expectEqualStrings("Brains", block.layout.groups[0].label);
    try testing.expectEqual(@as(usize, 2), block.layout.groups[0].members.len);
    try testing.expectEqualStrings("mcu", block.layout.groups[0].members[0]);
    try testing.expectEqualStrings("Power", block.layout.groups[1].label);
    try testing.expectEqual(@as(usize, 3), block.layout.groups[1].members.len);
}

// spec: eval/design_block - layout edge form parses left/right edge-pinned block keys
test "layout edge parses left and right pinned blocks" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (diagram-layout
        \\    (edge left "usbc_host" "barrel")
        \\    (edge right "banana")))
    ;
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;

    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();

    const block = (try evalDesignBlock(&eval, form_children[1..], &env)).design_block;
    try testing.expectEqual(@as(usize, 2), block.layout.edges.len);
    try testing.expectEqual(env_mod.EdgeSide.left, block.layout.edges[0].side);
    try testing.expectEqual(@as(usize, 2), block.layout.edges[0].members.len);
    try testing.expectEqualStrings("usbc_host", block.layout.edges[0].members[0]);
    try testing.expectEqual(env_mod.EdgeSide.right, block.layout.edges[1].side);
    try testing.expectEqualStrings("banana", block.layout.edges[1].members[0]);
}

// spec: eval/design_block - bus-net expands one net tie per index in the inclusive range
test "evalBusNetForm expands inclusive index range" {
    // Drive the parser directly: build the (bus-net …) AST, hand it to
    // evalBusNetForm, and read net_ties. Skips the full evalFile pipeline
    // so the test doesn't need a project_dir + pinout fixture.
    const a = std.heap.page_allocator;
    const src = "(bus-net \"FLASH_IO\" 0 2 \"flash\")";
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;

    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();

    var net_ties: std.ArrayListUnmanaged(NetTie) = .empty;
    try evalBusNetForm(&eval, form_children, &env, &net_ties);

    try testing.expectEqual(@as(usize, 3), net_ties.items.len);
    try testing.expectEqualStrings("FLASH_IO0", net_ties.items[0].a);
    try testing.expectEqualStrings("flash/FLASH_IO0", net_ties.items[0].b);
    try testing.expectEqualStrings("FLASH_IO2", net_ties.items[2].a);
    try testing.expectEqualStrings("flash/FLASH_IO2", net_ties.items[2].b);
}

// spec: eval/design_block - bus-net strided form distributes channels across over x ports with suffixes
test "evalBusNetForm strided fan-out distributes channels across subs and ports" {
    const a = std.heap.page_allocator;
    // 10 channels over 3 subs x 4 ports (12 slots), sub-major, P/N suffixes.
    const src =
        \\(bus-net "ADF_CH" 1 10 (suffixes P N) (over "adc1" "adc2" "adc3")
        \\         (ports AINA_EXT_ AINB_EXT_ AINC_EXT_ AIND_EXT_))
    ;
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;

    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();

    var net_ties: std.ArrayListUnmanaged(NetTie) = .empty;
    try evalBusNetForm(&eval, form_children, &env, &net_ties);

    // 10 channels x 2 suffixes = 20 ties.
    try testing.expectEqual(@as(usize, 20), net_ties.items.len);
    // ch1 → adc1 AINA (slot 0); P then N.
    try testing.expectEqualStrings("ADF_CH1P", net_ties.items[0].a);
    try testing.expectEqualStrings("adc1/AINA_EXT_P", net_ties.items[0].b);
    try testing.expectEqualStrings("ADF_CH1N", net_ties.items[1].a);
    try testing.expectEqualStrings("adc1/AINA_EXT_N", net_ties.items[1].b);
    // ch5 → adc2 AINA (slot 4 = 1*4 + 0).
    try testing.expectEqualStrings("ADF_CH5P", net_ties.items[8].a);
    try testing.expectEqualStrings("adc2/AINA_EXT_P", net_ties.items[8].b);
    // ch10 → adc3 AINB (slot 9 = 2*4 + 1) — the last routed channel.
    try testing.expectEqualStrings("ADF_CH10P", net_ties.items[18].a);
    try testing.expectEqualStrings("adc3/AINB_EXT_P", net_ties.items[18].b);
}

// spec: eval/design_block - sub-block bridge ties prefixed board nets to module ports with optional rename
test "evalSubBlockBridges ties PREFIX+port to sub/port and honours rename" {
    const a = std.heap.page_allocator;
    const src =
        \\(sub-block "imu" (bno08x-imu)
        \\  (bridge "IMU_" SCK MOSI MISO (rename CS NCS)))
    ;
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;

    var eval = Evaluator.init(a, "");
    defer eval.deinit();

    var net_ties: std.ArrayListUnmanaged(NetTie) = .empty;
    try evalSubBlockBridges(&eval, form_children, "imu", &net_ties);

    try testing.expectEqual(@as(usize, 4), net_ties.items.len);
    try testing.expectEqualStrings("IMU_SCK", net_ties.items[0].a);
    try testing.expectEqualStrings("imu/SCK", net_ties.items[0].b);
    try testing.expectEqualStrings("IMU_MISO", net_ties.items[2].a);
    try testing.expectEqualStrings("imu/MISO", net_ties.items[2].b);
    // rename: board net keeps the IMU_NCS name, far side stays the CS port.
    try testing.expectEqualStrings("IMU_NCS", net_ties.items[3].a);
    try testing.expectEqualStrings("imu/CS", net_ties.items[3].b);
}

// spec: eval/design_block - bus-port expands one port per index times optional suffix list
test "expandSectionBusPort expands index x suffix matrix" {
    const a = std.heap.page_allocator;
    const src = "(bus-port \"ADF_CH\" 1 3 (suffixes P N) in differential)";
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;

    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();

    var ports: std.ArrayListUnmanaged(env_mod.SectionPort) = .empty;
    try builders.expandSectionBusPort(&eval, form_children, &env, &ports);

    try testing.expectEqual(@as(usize, 6), ports.items.len);
    try testing.expectEqualStrings("ADF_CH1P", ports.items[0].name);
    try testing.expectEqualStrings("ADF_CH1N", ports.items[1].name);
    try testing.expectEqualStrings("ADF_CH3N", ports.items[5].name);
    try testing.expectEqual(env_mod.PortDirection.in, ports.items[0].direction);
    try testing.expectEqual(env_mod.SignalType.differential, ports.items[0].signal_type);
}

// spec: eval/design_block - verifies req with an (id …) target parses as a stable-id sign-off leaving ref-des empty
test "parseVerifies reads an (id …) target as a stable-id sign-off" {
    const a = std.heap.page_allocator;
    const src =
        \\(verifies (req (id b894897b) deadbeef)
        \\  (rationale "checked against datasheet")
        \\  (signed-off-by "me" (date "2026-05-25")))
    ;
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;

    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();

    const v = parseVerifies(&eval, form_children, &env) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("b894897b", v.target_id);
    try testing.expectEqualStrings("", v.ref_des);
    try testing.expectEqualStrings("deadbeef", v.req_id);
    try testing.expectEqualStrings("checked against datasheet", v.rationale);
    try testing.expectEqualStrings("me", v.signed_by);
    try testing.expectEqualStrings("2026-05-25", v.date);
}

// spec: eval/design_block - verifies req with a ref-des target parses as a ref-des sign-off leaving target-id empty
test "parseVerifies reads a ref-des target as a ref-des sign-off" {
    const a = std.heap.page_allocator;
    const src = "(verifies (req \"U6\" deadbeef) \"looks good\")";
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;

    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();

    const v = parseVerifies(&eval, form_children, &env) orelse return error.TestUnexpectedResult;
    try testing.expectEqualStrings("U6", v.ref_des);
    try testing.expectEqualStrings("", v.target_id);
    try testing.expectEqualStrings("deadbeef", v.req_id);
    try testing.expectEqualStrings("looks good", v.rationale);
}

/// Evaluate a design-block source string with a registered cap family and
/// return the evaluator (caller inspects `warnings`). page_allocator:
/// evaluator allocations are intentionally never freed (project convention).
/// Cap family name shared by the warning/cascade test fixtures.
const TEST_CAP_FAMILY = "cap-0402";

fn evalWarningFixture(alloc: std.mem.Allocator, eval: *Evaluator, source: []const u8) !void {
    eval.* = Evaluator.init(alloc, ".");
    try eval.component_cache.put(alloc, TEST_CAP_FAMILY, .{
        .name = TEST_CAP_FAMILY,
        .symbol_name = "",
        .footprint_name = "",
        .is_family = true,
        .param_type = "",
    });
    try eval.component_cache.put(alloc, "fakeic", .{
        .name = "fakeic",
        .symbol_name = "",
        .footprint_name = "",
        .is_family = false,
        .param_type = "",
    });
    var env = env_mod.Env.init(alloc, null);
    defer env.deinit();
    const nodes = try sexpr_parser.parse(alloc, source);
    _ = try eval.evalNodes(nodes, &env);
}

/// True when any recorded warning message contains `needle`.
fn hasWarningContaining(eval: *const Evaluator, needle: []const u8) bool {
    for (eval.warnings.items) |w| {
        if (std.mem.indexOf(u8, w.message, needle) != null) return true;
    }
    return false;
}

// spec: eval/design_block - an unknown sub-form inside a section records a lint warning naming the form
test "unknown section sub-form records a warning" {
    const alloc = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    try evalWarningFixture(alloc, &eval,
        \\(design-block "T"
        \\  (section "S" "desc"
        \\    (rolle input)))
    );
    try testing.expect(hasWarningContaining(&eval, "unknown sub-form (rolle …) in (section …)"));
}

// spec: eval/design_block - a misspelled role word records a warning listing the expected values
test "unknown role word records a warning" {
    const alloc = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    try evalWarningFixture(alloc, &eval,
        \\(design-block "T"
        \\  (section "S" "desc"
        \\    (role inptu)))
    );
    try testing.expect(hasWarningContaining(&eval, "unknown role 'inptu' in (role …) — expected input|output"));
}

// spec: eval/design_block - an unknown design-block top-level form records a warning
test "unknown design-block sub-form records a warning" {
    const alloc = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    try evalWarningFixture(alloc, &eval,
        \\(design-block "T"
        \\  (placment-order "U1"))
    );
    try testing.expect(hasWarningContaining(&eval, "unknown sub-form (placment-order …) in (design-block …)"));
}

// spec: eval/design_block - an unknown port option records a warning naming the option
test "unknown port option records a warning" {
    const alloc = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    try evalWarningFixture(alloc, &eval,
        \\(design-block "T"
        \\  (port "VDD" in pwoer))
    );
    try testing.expect(hasWarningContaining(&eval, "unknown port option 'pwoer' in (port …)"));
}

// spec: eval/design_block - a non-property sub-form in an instance body records a warning
test "ignored instance sub-form records a warning" {
    const alloc = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    try evalWarningFixture(alloc, &eval,
        \\(design-block "T"
        \\  (instance "C1" (cap-0402 "100nF")
        \\    (pin 1 "VDD")
        \\    (pin 2 "GND")
        \\    (mpn 42)))
    );
    try testing.expect(hasWarningContaining(&eval, "ignored sub-form (mpn …) in (instance \"C1\" …)"));
}

// spec: eval/design_block - inert id/ids/hierarchical-ids/row/col heads never draw warnings
test "inert form heads are warning-free" {
    const alloc = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    try evalWarningFixture(alloc, &eval,
        \\(design-block "T"
        \\  (hierarchical-ids)
        \\  (section "S" "desc"
        \\    (row 0)
        \\    (col 1)
        \\    (instance "C1" (cap-0402 "100nF")
        \\      (pin 1 "VDD")
        \\      (pin 2 "GND")
        \\      (id abcd1234))))
    );
    try testing.expectEqual(@as(usize, 0), eval.warnings.items.len);
}

/// Source for the replicate tests: a tiny one-cap module replicated 3×
/// under (hierarchical-ids), with the replicate form's (id …) pinned so
/// child ids are reproducible across fresh evaluations.
/// Find the first cap-0402 instance in a block, or null.
fn findCapInstance(block: *const DesignBlock) ?Instance {
    for (block.instances) |inst| {
        if (std.mem.eql(u8, inst.component, TEST_CAP_FAMILY)) return inst;
    }
    return null;
}

/// Evaluate a cascade-test source and return the named sub-block's block.
fn evalCascadeFixture(alloc: std.mem.Allocator, eval: *Evaluator, source: []const u8) !*DesignBlock {
    eval.* = undefined;
    try evalWarningFixture(alloc, eval, source);
    const nodes = try sexpr_parser.parse(alloc, source);
    var env = env_mod.Env.init(alloc, null);
    defer env.deinit();
    const v = try eval.evalNodes(nodes, &env);
    const block = switch (v) {
        .design_block => |b| b,
        else => return error.TestUnexpectedResult,
    };
    try testing.expectEqual(@as(usize, 1), block.sub_blocks.len);
    return block.sub_blocks[0].block;
}

// spec: eval/design_block - the decouple-defaults bypass component cascades into sub-block modules that declare none
test "decouple-defaults bypass cascades into a sub-block" {
    const alloc = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    const sub = try evalCascadeFixture(alloc, &eval,
        \\(defmodule mymod ()
        \\  (design-block "Mod"
        \\    (instance "U1" fakeic (pin 1 "VDD") (pin 2 "GND"))
        \\    (decouple "VDD" 1 per-pin U1 1)))
        \\(design-block "Top"
        \\  (decouple-defaults (bypass (cap-0402 "100nF")))
        \\  (sub-block "m" (mymod)))
    );
    const cap = findCapInstance(sub) orelse return error.TestExpectedCap;
    try testing.expectEqualStrings("100nF", cap.value);
}

// spec: eval/design_block - a sub-block module's own decouple-defaults bypass wins over the parent's
test "module-local decouple-defaults bypass wins over the parent" {
    const alloc = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    const sub = try evalCascadeFixture(alloc, &eval,
        \\(defmodule mymod ()
        \\  (design-block "Mod"
        \\    (decouple-defaults (bypass (cap-0402 "1uF")))
        \\    (instance "U1" fakeic (pin 1 "VDD") (pin 2 "GND"))
        \\    (decouple "VDD" 1 per-pin U1 1)))
        \\(design-block "Top"
        \\  (decouple-defaults (bypass (cap-0402 "100nF")))
        \\  (sub-block "m" (mymod)))
    );
    const cap = findCapInstance(sub) orelse return error.TestExpectedCap;
    try testing.expectEqualStrings("1uF", cap.value);
}

// spec: eval/design_block - the bypass default cascades transitively through nested sub-blocks while the ic ref stays local
test "bypass default cascades transitively into nested sub-blocks" {
    const alloc = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    const mid = try evalCascadeFixture(alloc, &eval,
        \\(defmodule innermod ()
        \\  (design-block "Inner"
        \\    (instance "U1" fakeic (pin 1 "VDD") (pin 2 "GND"))
        \\    (decouple "VDD" 1 per-pin U1 1)))
        \\(defmodule outermod ()
        \\  (design-block "Outer"
        \\    (sub-block "inner" (innermod))))
        \\(design-block "Top"
        \\  (decouple-defaults (ic "U99") (bypass (cap-0402 "100nF")))
        \\  (sub-block "outer" (outermod)))
    );
    try testing.expectEqual(@as(usize, 1), mid.sub_blocks.len);
    const cap = findCapInstance(mid.sub_blocks[0].block) orelse return error.TestExpectedCap;
    try testing.expectEqualStrings("100nF", cap.value);
    // The ic ref did NOT cascade: the inner decouple's split net names U1
    // (its explicit ref), not the top-level default U99.
    var found_u1_net = false;
    for (mid.sub_blocks[0].block.nets) |net| {
        if (std.mem.indexOf(u8, net.name, ".U99.") != null) return error.TestIcLeaked;
        if (std.mem.indexOf(u8, net.name, "VDD.") != null) found_u1_net = true;
    }
    try testing.expect(found_u1_net);
}
