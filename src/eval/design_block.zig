const std = @import("std");
const ast = @import("../sexpr/ast.zig");
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
const rails_mod = @import("rails.zig");
const test_point_mod = @import("test_point.zig");
const power_config_mod = @import("power_config.zig");
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

/// Evaluate a `(design-block "name" form…)` form into a heap-allocated
/// `DesignBlock`. Iterates each child form (instance/port/note/group/section/
/// sub-block/net/series/decouple/verifies), builds nets from collected
/// pin-net declarations and net-ties, auto-assigns ref-deses, and runs the
/// design validator. The returned Value owns the DesignBlock.
pub fn evalDesignBlock(self: *Evaluator, args: []const Node, env: *Env) EvalError!Value {
    if (args.len < 1) return EvalError.ArityError;

    // First arg is name (could be computed via fmt)
    const name_val = try self.evalNode(args[0], env);
    const name = name_val.asString() orelse return EvalError.TypeError;

    var instances: std.ArrayListUnmanaged(Instance) = .empty;
    var all_pin_nets: std.ArrayListUnmanaged(PinNetDecl) = .empty;
    var ports: std.ArrayListUnmanaged(Port) = .empty;
    var notes: std.ArrayListUnmanaged(Note) = .empty;
    var groups: std.ArrayListUnmanaged(Group) = .empty;
    var sections: std.ArrayListUnmanaged(env_mod.Section) = .empty;

    var net_ties: std.ArrayListUnmanaged(NetTie) = .empty;
    var sub_blocks: std.ArrayListUnmanaged(SubBlock) = .empty;
    var verifications: std.ArrayListUnmanaged(env_mod.Verification) = .empty;
    var critical_ics: std.ArrayListUnmanaged(env_mod.CriticalIc) = .empty;
    var test_points: std.ArrayListUnmanaged(env_mod.TestPoint) = .empty;
    var functions: std.ArrayListUnmanaged(env_mod.FunctionGroup) = .empty;
    var parts: std.ArrayListUnmanaged(env_mod.PlaceholderPart) = .empty;
    var layout_spec: env_mod.LayoutSpec = .{};
    var derating: ?f64 = null;
    var kicad_pcb_path: ?[]const u8 = null;
    var net_form_sources: std.StringHashMapUnmanaged(u32) = .empty;

    // Pre-scan: register all explicit ref-des to avoid auto-counter collisions,
    // and all existing id/ids tokens so generateId never re-mints one.
    ids.prescanRefDes(self, args[1..]);
    ids.prescanIds(self, args[1..]);

    // `(hierarchical-ids)` opts this design (and the modules it sub-blocks) into
    // Option-4 sub-block identity. Inherit from any enclosing design and restore
    // on exit so the flag follows the design tree, not evaluation order.
    const saved_hierarchical = self.hierarchical_ids;
    self.hierarchical_ids = saved_hierarchical or hasHierarchicalMarker(args[1..]);
    defer self.hierarchical_ids = saved_hierarchical;

    // Decouple defaults are design-block-local: snapshot and clear so a
    // parent's (decouple-defaults …) never leaks into a nested sub-block
    // module's own decouples. A (decouple-defaults …) form inside this body
    // sets them below; the defer restores the enclosing design's on exit.
    const saved_decouple_defaults = self.decouple_defaults;
    self.decouple_defaults = .{};
    defer self.decouple_defaults = saved_decouple_defaults;

    for (args[1..]) |form| {
        const form_children = form.asList() orelse continue;
        if (form_children.len == 0) continue;
        const form_name = form_children[0].asAtom() orelse continue;

        const sf = ScopeForm.fromAtom(form_name) orelse continue;
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
            .design_doc => try parseDesignDoc(self, form_children, env, &critical_ics),
            .test_point => if (try test_point_mod.parse(self.allocator, form_children)) |tp| try test_points.append(self.allocator, tp),
            .power_config => if (power_config_mod.parse(form_children)) |cfg| {
                if (cfg.derating) |d| derating = d;
            },
            .kicad_pcb => {
                // (kicad-pcb "<absolute path>") — captures the on-disk
                // PCB the file-based sync endpoint writes to. Only the
                // literal string form is supported; no env-var or
                // template expansion (NAS paths are deterministic).
                if (form_children.len >= 2) {
                    if (form_children[1].asString()) |p| {
                        kicad_pcb_path = p;
                    }
                }
            },
            .function => if (try parseFunction(self, form_children)) |f| try functions.append(self.allocator, f),
            .stub => if (try parseStub(self, form_children)) |p| {
                ids.registerRefDes(self, p.part.ref_des);
                try instances.append(self.allocator, p.instance);
                for (p.pin_nets) |pn| try all_pin_nets.append(self.allocator, pn);
                try parts.append(self.allocator, p.part);
            },
            .layout => layout_spec = try parseLayout(self, form_children),
            // Section-only forms are silently ignored at the top level —
            // a design-block body shouldn't carry status/description/pins
            // directly. The exhaustive switch is the contract.
            .pins, .protocol, .calc, .description, .status, .role, .diagram, .hosts, .category => {},
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
        .net_ties = block_ties.toOwnedSlice(self.allocator) catch &.{},
        .verifications = verifications.toOwnedSlice(self.allocator) catch &.{},
        .critical_ics = critical_ics.toOwnedSlice(self.allocator) catch &.{},
        .test_points = test_points.toOwnedSlice(self.allocator) catch &.{},
        .derating = derating,
        .kicad_pcb_path = kicad_pcb_path,
        .functions = functions.toOwnedSlice(self.allocator) catch &.{},
        .parts = parts.toOwnedSlice(self.allocator) catch &.{},
        .layout = layout_spec,
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

fn numberAsUsize(v: env_mod.Value) ?usize {
    const f = v.asNumber() orelse return null;
    if (f < 0) return null;
    return @intFromFloat(f);
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
/// (`status`, `description`, `note`, `port`, `protocol`, `calc`).
const SectionScope = struct {
    description: *[]const u8,
    notes: *std.ArrayListUnmanaged(env_mod.SectionNote),
    ports: *std.ArrayListUnmanaged(env_mod.SectionPort),
    protocols: *std.ArrayListUnmanaged([]const u8),
    calcs: *std.ArrayListUnmanaged(env_mod.CalcBlock),
    explicit_status: *?env_mod.SectionStatus,
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
        .status => {
            if (sf_children.len >= 2) {
                if (sf_children[1].asAtom()) |status_str| {
                    scope.explicit_status.* = parseSectionStatus(status_str);
                }
            }
            return true;
        },
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
                if (nv.asString()) |text| {
                    var ref: ?env_mod.NoteRef = null;
                    for (sf_children[2..]) |extra| {
                        if (env_mod.parseNoteRef(extra)) |r| {
                            ref = r;
                            break;
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
    var explicit_status: ?env_mod.SectionStatus = null;
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
        .explicit_status = &explicit_status,
    };

    for (form_children[child_start..]) |sf| {
        const sf_children = sf.asList() orelse continue;
        if (sf_children.len == 0) continue;
        const sf_name = sf_children[0].asAtom() orelse continue;
        const sft = ScopeForm.fromAtom(sf_name) orelse continue;

        if (try processSharedSectionForm(self, sft, sf_children, env, scope)) continue;

        switch (sft) {
            .role => {
                if (sf_children.len >= 2) {
                    if (sf_children[1].asAtom()) |role_str| {
                        if (std.mem.eql(u8, role_str, "input")) {
                            block_role = .input;
                        } else if (std.mem.eql(u8, role_str, "output")) {
                            block_role = .output;
                        }
                    }
                }
            },
            .diagram => {
                if (sf_children.len >= 2) {
                    if (sf_children[1].asAtom()) |mode| {
                        if (std.mem.eql(u8, mode, "hidden")) diagram_hidden = true;
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
                try evalSectionDecouple(self, sf_children, env, instances, all_pin_nets);
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
            // silently ignored inside a section body.
            .status, .description, .note, .port, .protocol, .calc => {},
            .group, .sub_block, .verifies, .design_doc, .test_point, .power_config, .decouple_defaults, .kicad_pcb, .function, .stub, .layout => {},
        }
    }

    const final_instances = sec_instances.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory;
    const final_pin_groups = sec_pin_groups.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory;
    const final_sub_sections = sec_sub_sections.toOwnedSlice(self.allocator) catch &.{};

    // Infer status: concept if no instances, no pin_groups, and no sub-sections with content
    const status = explicit_status orelse if (final_instances.len == 0 and final_pin_groups.len == 0)
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
fn evalSectionDecouple(
    self: *Evaluator,
    sf_children: []const Node,
    env: *Env,
    instances: *std.ArrayListUnmanaged(Instance),
    all_pin_nets: *std.ArrayListUnmanaged(PinNetDecl),
) EvalError!void {
    if (sf_children.len < 3) return;
    const dec_first_val = try self.evalNode(sf_children[1], env);
    // Stamp the decouple form's own (id) anchor. Under (hierarchical-ids) it
    // seeds every child cap's derived id; otherwise children use the (ids …) sidecar.
    const form_id = try ids.getOrCreateFormId(self, sf_children);
    var sidecar = ids.parseChildIdSidecar(self, sf_children);

    // Multi-net (comp-first) shorthand removed — see evalDecoupleForm. Spell
    // out one (decouple "NET" (comp) COUNT per-pin REF PIN…) per rail.
    if (dec_first_val == .component or dec_first_val == .component_instance) {
        log.warn("decouple no longer supports the multi-net (comp-first) form; " ++
            "write one (decouple \"NET\" (comp) COUNT per-pin REF PIN1 PIN2 …) per rail", .{});
        return EvalError.InvalidForm;
    } else {
        const net_name = dec_first_val.asString() orelse return;
        var has_sub_forms = false;
        for (sf_children[2..]) |ssf| {
            if (ssf.isForm("bulk") or ssf.isForm("bypass")) {
                has_sub_forms = true;
                break;
            }
        }
        if (has_sub_forms) {
            for (sf_children[2..]) |ssf| {
                if (ssf.isForm("bulk") or ssf.isForm("bypass")) {
                    const sub = ssf.asList().?;
                    try builders.emitDecoupleItems(self, sub[1..], net_name, env, instances, all_pin_nets, form_id, &sidecar);
                }
            }
        } else {
            try builders.emitDecoupleItems(self, sf_children[2..], net_name, env, instances, all_pin_nets, form_id, &sidecar);
        }
    }
}

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

    var explicit_status: ?env_mod.SectionStatus = null;

    const sub_scope = SectionScope{
        .description = &sub_description,
        .notes = &sub_notes,
        .ports = &sub_ports,
        .protocols = &sub_protocols,
        .calcs = &sub_calcs,
        .explicit_status = &explicit_status,
    };

    for (sf_children[2..]) |ssf| {
        const ssf_children = ssf.asList() orelse continue;
        if (ssf_children.len == 0) continue;
        const ssf_name = ssf_children[0].asAtom() orelse continue;
        const sft = ScopeForm.fromAtom(ssf_name) orelse continue;

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
            },
            .pins => {
                if (ssf_children.len < 2) continue;
                const pins_ref_val = try self.evalNode(ssf_children[1], env);
                const pins_ref = pins_ref_val.asString() orelse continue;
                const pin_func_map2 = builders.findPinFuncMap(self, instances.items, pins_ref);
                var pg_pins2: std.ArrayListUnmanaged(env_mod.PartPin) = .empty;
                for (ssf_children[2..]) |pin_form| {
                    try builders.processPinForm(self, pin_form, pins_ref, pin_func_map2, env, all_pin_nets, &pg_pins2, net_ties);
                }
                const pg_slice2 = pg_pins2.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory;
                try sub_pin_groups.append(self.allocator, .{ .ref_des = pins_ref, .pins = pg_slice2 });
                try builders.addPartToInstance(self, instances.items, pins_ref, sub_name, pg_slice2);
            },
            .decouple => {
                const pre_count = instances.items.len;
                try evalSectionDecouple(self, ssf_children, env, instances, all_pin_nets);
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
            // variants went through `processSharedSectionForm` above.
            // Sub-sections deliberately accept no top-level-only or
            // section-only forms beyond what's matched above.
            else => {},
        }
    }
    const final_sub_instances = sub_instances.toOwnedSlice(self.allocator) catch &.{};
    const final_sub_pin_groups = sub_pin_groups.toOwnedSlice(self.allocator) catch &.{};

    const status = explicit_status orelse if (final_sub_instances.len == 0 and final_sub_pin_groups.len == 0)
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
        }) catch return EvalError.OutOfMemory;
    }
    // Apply net-ties: merge two nets into one.
    for (net_ties.items) |nt| {
        const a_pins = net_map.get(nt.a);
        const b_pins = net_map.get(nt.b);
        if (a_pins == null and b_pins == null) continue;

        // Auto-aliases (synthesized from symbol pin-function names) must not
        // short-circuit two distinct user-declared nets. If both sides already
        // have pins, the user clearly meant them separate — e.g. the AD7380's
        // pin 19 is named "SDOA" in its pinout, but ad7380-channel uses
        // "SDOA_RAW" on the IC side of a damping resistor and "SDOA" on the
        // output side; merging those would jumper the 100Ω resistor.
        if (nt.is_auto and a_pins != null and b_pins != null) continue;

        const keep = nt.a;
        const remove = nt.b;
        if (net_map.get(remove)) |src_pins| {
            const gop = net_map.getOrPut(self.allocator, keep) catch return EvalError.OutOfMemory;
            if (!gop.found_existing) {
                gop.value_ptr.* = .empty;
            }
            for (src_pins.items) |pin| {
                gop.value_ptr.append(self.allocator, pin) catch return EvalError.OutOfMemory;
            }
            _ = net_map.remove(remove);
        }
        // Also rename per-pin nets: "REMOVE.x" -> "KEEP.x"
        const remove_dot = std.fmt.allocPrint(self.allocator, "{s}.", .{remove}) catch return EvalError.OutOfMemory;
        var rename_keys: std.ArrayListUnmanaged([]const u8) = .empty;
        var map_iter = net_map.iterator();
        while (map_iter.next()) |entry| {
            if (std.mem.startsWith(u8, entry.key_ptr.*, remove_dot)) {
                rename_keys.append(self.allocator, entry.key_ptr.*) catch return EvalError.OutOfMemory;
            }
        }
        for (rename_keys.items) |old_key| {
            const suffix = old_key[remove_dot.len..];
            const new_key = std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ keep, suffix }) catch return EvalError.OutOfMemory;
            if (net_map.fetchRemove(old_key)) |kv| {
                net_map.put(self.allocator, new_key, kv.value) catch return EvalError.OutOfMemory;
            }
        }
    }
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

/// Parse a section status string into a SectionStatus enum value.
fn parseSectionStatus(str: []const u8) ?env_mod.SectionStatus {
    if (std.mem.eql(u8, str, "concept")) return .concept;
    if (std.mem.eql(u8, str, "implemented")) return .implemented;
    if (std.mem.eql(u8, str, "review")) return .review;
    return null;
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

/// Parse a top-level `(design-doc (critical-ic <component> …) …)` form.
/// Each `(critical-ic …)` child names a library component (atom or string)
/// and may carry `(role "…")`, `(rationale "…")`, `(mpn "…")` sub-clauses in
/// any order. Malformed children are skipped rather than failing the build —
/// the design document is advisory, not load-bearing for the netlist.
fn parseDesignDoc(
    self: *Evaluator,
    form_children: []const Node,
    env: *Env,
    out: *std.ArrayListUnmanaged(env_mod.CriticalIc),
) EvalError!void {
    _ = env;
    // form_children[0] = "design-doc"; the rest are (critical-ic …) forms.
    for (form_children[1..]) |child| {
        const cic = child.asList() orelse continue;
        if (cic.len < 2) continue;
        const head = cic[0].asAtom() orelse continue;
        if (!std.mem.eql(u8, head, "critical-ic")) continue;
        const component = cic[1].asAtom() orelse cic[1].asString() orelse continue;

        var role: []const u8 = "";
        var rationale: []const u8 = "";
        var mpn: []const u8 = "";
        for (cic[2..]) |sub_node| {
            const sub = sub_node.asList() orelse continue;
            if (sub.len < 2) continue;
            const sub_head = sub[0].asAtom() orelse continue;
            const val = sub[1].asString() orelse sub[1].asAtom() orelse "";
            if (std.mem.eql(u8, sub_head, "role")) {
                role = val;
            } else if (std.mem.eql(u8, sub_head, "rationale")) {
                rationale = val;
            } else if (std.mem.eql(u8, sub_head, "mpn")) {
                mpn = val;
            }
        }

        out.append(self.allocator, .{
            .component = component,
            .role = role,
            .rationale = rationale,
            .mpn = mpn,
        }) catch return EvalError.OutOfMemory;
    }
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
            .signals = sig_slice,
        },
        .instance = inst,
        .pin_nets = pin_nets.toOwnedSlice(self.allocator) catch &.{},
    };
}

/// Parse a top-level `(layout (anchor "name") (place "name" (rel "ref"))…)`
/// form into a `LayoutSpec`. `(anchor "x")` is shorthand for a pinned root
/// (`rel = .anchor`, no reference); `(place "x" (right-of "y"))` positions x
/// relative to y. Unknown relation keywords and malformed directives are
/// skipped so a typo can't abort the build. Directive order is preserved — the
/// layout solver resolves dependencies, not source order.
fn parseLayout(self: *Evaluator, form_children: []const Node) EvalError!env_mod.LayoutSpec {
    var placements: std.ArrayListUnmanaged(env_mod.Placement) = .empty;
    for (form_children[1..]) |child| {
        const c = child.asList() orelse continue;
        if (c.len < 2) continue;
        const head = c[0].asAtom() orelse continue;
        if (std.mem.eql(u8, head, "anchor")) {
            const name = c[1].asString() orelse c[1].asAtom() orelse continue;
            try placements.append(self.allocator, .{ .name = name, .rel = .anchor });
        } else if (std.mem.eql(u8, head, "place")) {
            // (place "name" (rel "ref"))
            const name = c[1].asString() orelse c[1].asAtom() orelse continue;
            if (c.len < 3) {
                // Bare (place "name") with no relation → treat as an anchor.
                try placements.append(self.allocator, .{ .name = name, .rel = .anchor });
                continue;
            }
            const rel_form = c[2].asList() orelse continue;
            if (rel_form.len < 2) continue;
            const rel_head = rel_form[0].asAtom() orelse continue;
            const rel = relFromAtom(rel_head) orelse continue;
            const ref = rel_form[1].asString() orelse rel_form[1].asAtom() orelse continue;
            try placements.append(self.allocator, .{ .name = name, .rel = rel, .reference = ref });
        }
    }
    return .{ .placements = placements.toOwnedSlice(self.allocator) catch &.{} };
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

/// Parse one `(function "Name" "Subtitle"? (verb "…")? (includes "a" "b" …)?)`
/// form into a `FunctionGroup` for the high-level Function view. The first
/// string after the head is the name, an optional second string is the
/// subtitle; `(verb …)` is the action phrase and `(includes …)` lists the
/// member section / sub-block names. Returns null when there's no name.
fn parseFunction(self: *Evaluator, form_children: []const Node) EvalError!?env_mod.FunctionGroup {
    if (form_children.len < 2) return null;
    const name = form_children[1].asString() orelse return null;
    var subtitle: []const u8 = "";
    var verb: []const u8 = "";
    var stack: u8 = 1;
    var includes: std.ArrayListUnmanaged([]const u8) = .empty;
    for (form_children[2..]) |node| {
        if (node.asString()) |s| {
            if (subtitle.len == 0) subtitle = s;
            continue;
        }
        const lst = node.asList() orelse continue;
        if (lst.len < 1) continue;
        const head = lst[0].asAtom() orelse continue;
        if (std.mem.eql(u8, head, "verb")) {
            if (lst.len >= 2) verb = lst[1].asString() orelse lst[1].asAtom() orelse "";
        } else if (std.mem.eql(u8, head, "stack")) {
            if (lst.len >= 2) {
                if (lst[1].asNumber()) |n| stack = @intFromFloat(@max(1, @min(9, n)));
            }
        } else if (std.mem.eql(u8, head, "includes")) {
            for (lst[1..]) |inc| {
                const s = inc.asString() orelse inc.asAtom() orelse continue;
                includes.append(self.allocator, s) catch return EvalError.OutOfMemory;
            }
        }
    }
    return env_mod.FunctionGroup{
        .name = name,
        .subtitle = subtitle,
        .verb = verb,
        .stack = stack,
        .includes = includes.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
    };
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
    const nodes = try @import("../sexpr/parser.zig").parse(a, src);
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

// spec: eval/design_block - function form parses a named functional group with a verb and member sections
test "design-block parses a (function …) group" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (function "Measurement" "isolated DMM"
        \\    (verb "measures V/R")
        \\    (stack 2)
        \\    (includes "DMM Analog Front-End" "DMM Cal EEPROM")))
    ;
    const nodes = try @import("../sexpr/parser.zig").parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;

    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();

    // Always a design_block here — access the payload directly (no branch).
    const block = (try evalDesignBlock(&eval, form_children[1..], &env)).design_block;
    try testing.expectEqual(@as(usize, 1), block.functions.len);
    const f = block.functions[0];
    try testing.expectEqualStrings("Measurement", f.name);
    try testing.expectEqualStrings("isolated DMM", f.subtitle);
    try testing.expectEqualStrings("measures V/R", f.verb);
    try testing.expectEqual(@as(u8, 2), f.stack);
    try testing.expectEqual(@as(usize, 2), f.includes.len);
    try testing.expectEqualStrings("DMM Analog Front-End", f.includes[0]);
}

// spec: eval/design_block - hosts form records the sub-block instance names a section owns
test "section (hosts …) records owned sub-block names" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (section "PSU" (hosts "psu1" "mon_ch1")))
    ;
    const nodes = try @import("../sexpr/parser.zig").parse(a, src);
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

// spec: eval/design_block - layout form parses (anchor "name") roots and (place "name" (rel "ref")) directives
test "design-block parses a (layout …) form with anchor and place" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (layout
        \\    (anchor "rp2350")
        \\    (place "esp32" (right-of "rp2350"))))
    ;
    const nodes = try @import("../sexpr/parser.zig").parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;

    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();

    const block = (try evalDesignBlock(&eval, form_children[1..], &env)).design_block;
    try testing.expectEqual(@as(usize, 2), block.layout.placements.len);
    try testing.expectEqualStrings("rp2350", block.layout.placements[0].name);
    try testing.expectEqual(env_mod.PlaceRel.anchor, block.layout.placements[0].rel);
    try testing.expectEqualStrings("esp32", block.layout.placements[1].name);
    try testing.expectEqualStrings("rp2350", block.layout.placements[1].reference);
}

// spec: eval/design_block - layout place resolves right-of/left-of/above/below into a relative offset from the referenced block
test "layout place parses each relation keyword" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (layout
        \\    (place "b" (right-of "a"))
        \\    (place "c" (left-of "a"))
        \\    (place "d" (above "a"))
        \\    (place "e" (below "a"))))
    ;
    const nodes = try @import("../sexpr/parser.zig").parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;

    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();

    const block = (try evalDesignBlock(&eval, form_children[1..], &env)).design_block;
    try testing.expectEqual(@as(usize, 4), block.layout.placements.len);
    try testing.expectEqual(env_mod.PlaceRel.right_of, block.layout.placements[0].rel);
    try testing.expectEqual(env_mod.PlaceRel.left_of, block.layout.placements[1].rel);
    try testing.expectEqual(env_mod.PlaceRel.above, block.layout.placements[2].rel);
    try testing.expectEqual(env_mod.PlaceRel.below, block.layout.placements[3].rel);
}

// spec: eval/design_block - bus-net expands one net tie per index in the inclusive range
test "evalBusNetForm expands inclusive index range" {
    // Drive the parser directly: build the (bus-net …) AST, hand it to
    // evalBusNetForm, and read net_ties. Skips the full evalFile pipeline
    // so the test doesn't need a project_dir + pinout fixture.
    const a = std.heap.page_allocator;
    const src = "(bus-net \"FLASH_IO\" 0 2 \"flash\")";
    const nodes = try @import("../sexpr/parser.zig").parse(a, src);
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
    const nodes = try @import("../sexpr/parser.zig").parse(a, src);
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
    const nodes = try @import("../sexpr/parser.zig").parse(a, src);
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
    const nodes = try @import("../sexpr/parser.zig").parse(a, src);
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
    const nodes = try @import("../sexpr/parser.zig").parse(a, src);
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
    const nodes = try @import("../sexpr/parser.zig").parse(a, src);
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
