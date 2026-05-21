const std = @import("std");
const ast = @import("../sexpr/ast.zig");
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

// ── Constants ─────────────────────────────────────────────────────
const DECOUPLE_FORM = "decouple";
const BUS_PORT_FORM = "bus-port";
const INSTANCE_FORM = "instance";
const DECOUPLE_MULTI_NET_MIN_ARITY: usize = 6;
const DECOUPLE_MULTI_NET_NET_OFFSET: usize = 5;

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
    var test_points: std.ArrayListUnmanaged(env_mod.TestPoint) = .empty;
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
                try sub_blocks.append(self.allocator, sb);
            },
            .section => try evalSection(self, form_children, env, &instances, &all_pin_nets, &notes, &net_ties, &sections),
            .net => {
                try evalNetForm(self, form_children, env, &net_ties);
                validate.trackNetFormSource(self, form_children, env, &net_form_sources);
            },
            .bus_net => try evalBusNetForm(self, form_children, env, &net_ties),
            .series => try instance_mod.evalSeriesForm(self, form_children, env, &instances, &all_pin_nets, &notes),
            .decouple => try evalDecoupleForm(self, form_children, env, &instances, &all_pin_nets),
            .verifies => if (parseVerifies(self, form_children, env)) |v| try verifications.append(self.allocator, v),
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
            // Section-only forms are silently ignored at the top level —
            // a design-block body shouldn't carry status/description/pins
            // directly. The exhaustive switch is the contract.
            .pins, .protocol, .calc, .description, .status, .role, .diagram => {},
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
        .test_points = test_points.toOwnedSlice(self.allocator) catch &.{},
        .derating = derating,
        .kicad_pcb_path = kicad_pcb_path,
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

/// Evaluate `(bus-net "PREFIX" START END "SUB")` — shorthand for one
/// `(net "PREFIX<i>" "SUB/PREFIX<i>")` per index in `[START, END]`. Lets
/// `(bus-net "FLASH_IO" 0 7 "flash")` replace 8 verbatim net-tie lines
/// at the bottom of a design file. Bounds are inclusive on both ends so
/// the index range mirrors the underlying signal numbering.
fn evalBusNetForm(self: *Evaluator, form_children: []const Node, env: *Env, net_ties: *std.ArrayListUnmanaged(NetTie)) EvalError!void {
    if (form_children.len < 5) return;
    const prefix = (try self.evalNode(form_children[1], env)).asString() orelse return;
    const start_val = try self.evalNode(form_children[2], env);
    const end_val = try self.evalNode(form_children[3], env);
    const sub = (try self.evalNode(form_children[4], env)).asString() orelse return;

    const start = numberAsUsize(start_val) orelse return;
    const end = numberAsUsize(end_val) orelse return;
    if (end < start) return;

    var i: usize = start;
    while (i <= end) : (i += 1) {
        const parent = std.fmt.allocPrint(self.allocator, "{s}{d}", .{ prefix, i }) catch return EvalError.OutOfMemory;
        const child = std.fmt.allocPrint(self.allocator, "{s}/{s}{d}", .{ sub, prefix, i }) catch return EvalError.OutOfMemory;
        try net_ties.append(self.allocator, .{ .a = parent, .b = child });
    }
}

fn numberAsUsize(v: env_mod.Value) ?usize {
    const f = v.asNumber() orelse return null;
    if (f < 0) return null;
    return @intFromFloat(f);
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
    // Stamp the decouple form's own (id) anchor (kept for stability/grep); the
    // synthesized child caps get stable tokens from the (ids …) sidecar.
    _ = try ids.getOrCreateFormId(self, form_children);
    var sidecar = ids.parseChildIdSidecar(self, form_children);

    // Multi-net form: (decouple (comp "val") COUNT per-pin REF "NET1" "NET2" ...)
    if (first_val == .component or first_val == .component_instance) {
        if (form_children.len < DECOUPLE_MULTI_NET_MIN_ARITY) return;
        for (form_children[DECOUPLE_MULTI_NET_NET_OFFSET..]) |mn_node| {
            if (mn_node.isForm("id") or mn_node.isForm("ids")) continue;
            const mn_val = try self.evalNode(mn_node, env);
            const mn_net = mn_val.asString() orelse continue;
            try builders.emitDecoupleItems(
                self,
                form_children[1..DECOUPLE_MULTI_NET_NET_OFFSET],
                mn_net,
                env,
                instances,
                all_pin_nets,
                &sidecar,
            );
        }
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
                    try builders.emitDecoupleItems(self, sub[1..], net_name, env, instances, all_pin_nets, &sidecar);
                }
            }
        } else {
            try builders.emitDecoupleItems(self, form_children[2..], net_name, env, instances, all_pin_nets, &sidecar);
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
            .net => try evalNetForm(self, sf_children, env, net_ties),
            .bus_net => try evalBusNetForm(self, sf_children, env, net_ties),
            .section => try evalSubSection(self, sf_children, env, instances, all_pin_nets, notes, net_ties, &sec_instances, &sec_sub_sections),
            // Shared-form variants are consumed above by
            // `processSharedSectionForm`; top-level-only forms are
            // silently ignored inside a section body.
            .status, .description, .note, .port, .protocol, .calc, .group, .sub_block, .verifies, .test_point, .power_config, .kicad_pcb => {},
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
    // Stamp the decouple form's own (id) anchor; children use the (ids …) sidecar.
    _ = try ids.getOrCreateFormId(self, sf_children);
    var sidecar = ids.parseChildIdSidecar(self, sf_children);

    // Multi-net form: (decouple (comp "val") COUNT per-pin REF "NET1" "NET2" ...)
    if (dec_first_val == .component or dec_first_val == .component_instance) {
        if (sf_children.len < DECOUPLE_MULTI_NET_MIN_ARITY) return;
        for (sf_children[DECOUPLE_MULTI_NET_NET_OFFSET..]) |mn_node| {
            if (mn_node.isForm("id") or mn_node.isForm("ids")) continue;
            const mn_val = try self.evalNode(mn_node, env);
            const mn_net = mn_val.asString() orelse continue;
            try builders.emitDecoupleItems(self, sf_children[1..DECOUPLE_MULTI_NET_NET_OFFSET], mn_net, env, instances, all_pin_nets, &sidecar);
        }
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
                    try builders.emitDecoupleItems(self, sub[1..], net_name, env, instances, all_pin_nets, &sidecar);
                }
            }
        } else {
            try builders.emitDecoupleItems(self, sf_children[2..], net_name, env, instances, all_pin_nets, &sidecar);
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
fn parseVerifies(self: *Evaluator, form_children: []const Node, env: *Env) ?env_mod.Verification {
    if (form_children.len < 2) return null;
    // form_children[0] = "verifies"; form_children[1] = (req "REFDES" REQID)
    const req_form = form_children[1].asList() orelse return null;
    if (req_form.len < 3) return null;
    const req_head = req_form[0].asAtom() orelse return null;
    if (!std.mem.eql(u8, req_head, "req")) return null;
    const ref_des_val = self.evalNode(req_form[1], env) catch return null;
    const ref_des = ref_des_val.asString() orelse return null;
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
        .req_id = req_id,
        .rationale = rationale,
        .signed_by = signed_by,
        .date = date_str,
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
