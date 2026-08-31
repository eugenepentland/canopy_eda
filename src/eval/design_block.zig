//! `(design-block …)` evaluation — the core that turns a design-block body (or
//! a `(defmodule …)` instantiation) into a `*DesignBlock`: dispatches each scope
//! form, wires instances/nets/ports/sections/sub-blocks, and applies
//! bus-net/bus-port expansion (capped at `max_bus_expansion` to bound a hostile
//! file's allocation). Entry points `evalDesignBlock` / `materializeBlock`;
//! failures propagate as `EvalError`. Pipeline: evaluator → here → DesignBlock.

const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const numeric = @import("../numeric.zig");
const net_names = @import("../net_name.zig");
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
const net_envelopes = @import("net_envelopes.zig");
const test_point_mod = @import("test_point.zig");
const micro_forms = @import("micro_forms.zig");
const pin_enrichment = @import("pin_enrichment.zig");
const forms_mod = @import("forms.zig");
const board_role_mod = @import("board_role.zig");
const net_analysis = @import("net_analysis.zig");
const section_maturity = @import("section_maturity.zig");
const stackup_presets = @import("stackup_presets.zig");
const outline_mod = @import("../placement/outline.zig");
const pll_loop = @import("../pll_loop.zig");
const frequency_plan = @import("../frequency_plan.zig");
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
const max_bus_expansion: usize = 4096;

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

/// Apply the source-level subcircuit power-plane switch after every body form
/// has been read, so it is independent of `(power-plane …)` / `(stackup …)`
/// order. The authored source remains intact: rebuilding after switching back
/// on restores every declared supply plane. Only the evaluated electrical role
/// is filtered; layer count and physical construction are unchanged.
fn applyPowerPlanePolicy(self: *Evaluator, board: env_mod.BoardSpec, stackup: *env_mod.StackupSpec) EvalError!void {
    const disabled_for_subcircuit = board.role == .subcircuit and !board.power_plane;
    if (!disabled_for_subcircuit) return;
    if (!stackup.present or stackup.planes.len == 0) return;
    const kept = self.allocator.alloc(env_mod.StackupPlane, stackup.planes.len) catch return EvalError.OutOfMemory;
    var count: usize = 0;
    for (stackup.planes) |plane| {
        if (!net_analysis.isGroundName(net_names.leaf(plane.net))) continue;
        kept[count] = plane;
        count += 1;
    }
    stackup.planes = kept[0..count];
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
    var instances: std.ArrayList(Instance) = .empty;
    var all_pin_nets: std.ArrayList(PinNetDecl) = .empty;
    var ports: std.ArrayList(Port) = .empty;
    var notes: std.ArrayList(Note) = .empty;
    var groups: std.ArrayList(Group) = .empty;
    var sections: std.ArrayList(env_mod.Section) = .empty;
    var net_ties: std.ArrayList(NetTie) = .empty;
    var sub_blocks: std.ArrayList(SubBlock) = .empty;
    var functions: std.ArrayList(env_mod.FunctionSpec) = .empty;
    var verifications: std.ArrayList(env_mod.Verification) = .empty;
    var test_points: std.ArrayList(env_mod.TestPoint) = .empty;
    var parts: std.ArrayList(env_mod.PlaceholderPart) = .empty;
    var layout_spec: env_mod.LayoutSpec = .{};
    var board_spec: env_mod.BoardSpec = .{};
    var revision_spec: env_mod.Revision = .{};
    var rough_spec: env_mod.RoughSpec = .{};
    var stackup_spec: env_mod.StackupSpec = .{};
    var pdn_intents: std.ArrayList(env_mod.PdnIntent) = .empty;
    var envelope_decls: std.ArrayList(net_envelopes.Declaration) = .empty;
    var fabrication_layers: std.ArrayList(env_mod.FabricationLayerSpec) = .empty;
    var net_class_specs: std.ArrayList(env_mod.NetClassSpec) = .empty;
    var pll_loop_specs: std.ArrayList(pll_loop.Spec) = .empty;
    defer pll_loop_specs.deinit(self.allocator);
    var frequency_plan_specs: std.ArrayList(frequency_plan.Spec) = .empty;
    defer frequency_plan_specs.deinit(self.allocator);
    var design_rules_spec: env_mod.DesignRulesSpec = .{};
    var pcb_plan_spec: ?env_mod.PcbPlanSpec = null;
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

    var build = BlockBuildState{
        .name = name,
        .instances = &instances,
        .all_pin_nets = &all_pin_nets,
        .ports = &ports,
        .notes = &notes,
        .groups = &groups,
        .sections = &sections,
        .net_ties = &net_ties,
        .sub_blocks = &sub_blocks,
        .functions = &functions,
        .verifications = &verifications,
        .test_points = &test_points,
        .parts = &parts,
        .layout_spec = &layout_spec,
        .board_spec = &board_spec,
        .revision_spec = &revision_spec,
        .rough_spec = &rough_spec,
        .stackup_spec = &stackup_spec,
        .pdn_intents = &pdn_intents,
        .envelope_decls = &envelope_decls,
        .fabrication_layers = &fabrication_layers,
        .net_class_specs = &net_class_specs,
        .pll_loop_specs = &pll_loop_specs,
        .frequency_plan_specs = &frequency_plan_specs,
        .design_rules_spec = &design_rules_spec,
        .pcb_plan_spec = &pcb_plan_spec,
        .kicad_pcb_path = &kicad_pcb_path,
        .net_form_sources = &net_form_sources,
    };
    try evalBlockBodyForms(self, body_forms, env, &build);
    try applyPowerPlanePolicy(self, board_spec, &stackup_spec);
    // Every instance now exists, so a `(decouples "IC" FUNC)` / `(near "REF"
    // FUNC)` can finally be read against the pinout of the part it names — in
    // either declaration order.
    builders.resolveDecoupleTargets(self, instances.items);
    builders.resolveNearTargets(self, instances.items);
    if (!build.has_explicit_layout)
        try seedLayoutFromSectionGrid(self, body_forms, env, &layout_spec);

    section_maturity.creditSections(sections.items, sub_blocks.items, groups.items, layout_spec.groups, body_forms);
    try validate.warnCombinableNets(self, &net_form_sources);
    const nets_slice = try buildNets(self, &all_pin_nets, &net_ties);

    const block_ties = try collectBlockTies(self, net_ties);

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
        .net_ties = block_ties,
        .verifications = verifications.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
        .test_points = test_points.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
        .kicad_pcb_path = kicad_pcb_path,
        .parts = parts.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
        .layout = layout_spec,
        .board = board_spec,
        .revision = revision_spec,
        .rough = rough_spec,
        .stackup = stackup_spec,
        .pdn_intents = pdn_intents.toOwnedSlice(self.allocator) catch &.{},
        .fabrication_layers = fabrication_layers.toOwnedSlice(self.allocator) catch &.{},
        .net_classes = net_class_specs.toOwnedSlice(self.allocator) catch &.{},
        .design_rules = design_rules_spec,
        .pcb_plan = pcb_plan_spec,
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

    // Domain-specific engineering declarations run after the complete local
    // block exists, so their component roles resolve against actual instance
    // values/tolerances regardless of source order.
    for (pll_loop_specs.items) |spec| pll_loop.evaluate(self.allocator, &self.assertions, &self.pll_reports, block, spec) catch return EvalError.OutOfMemory;
    // The frequency plan is a pure function of its own declaration — it names
    // no instances — so it needs the block only for ordering: its assertions
    // land after the loop-filter screens, in declaration order.
    for (frequency_plan_specs.items) |spec| frequency_plan.evaluate(self.allocator, &self.assertions, &self.frequency_plan_reports, spec) catch return EvalError.OutOfMemory;

    // Derive first-class power-rail entries from sub-block output ports +
    // ferrite-bead union-find. Downstream analyses (power_budget,
    // power_sequencing, ERC integrity checks) consume `block.rails`
    // instead of recomputing rail identity from emergent topology.
    block.rails = rails_mod.build(self.allocator, block) catch return EvalError.OutOfMemory;

    // Voltage envelopes run AFTER rails, and consume them: a rail is the seed a
    // module-internal node inherits across its own ferrite. This is what gives
    // the release rating checks a potential for `buck_5v75/VIN_F` and every
    // other net the supply tree cannot name. Authored `(net-envelope …)` forms
    // join here, and any that understates what the design already proves is
    // recorded as a failed assertion rather than silently believed.
    const envelopes = net_envelopes.build(self.allocator, block, build.envelope_decls.items) catch
        return EvalError.OutOfMemory;
    block.net_envelopes = envelopes.envelopes;
    for (envelopes.contradictions) |bad| {
        const msg = std.fmt.allocPrint(
            self.allocator,
            "(net-envelope \"{s}\" (rated {d} {d})) does not cover the {d}–{d} V this design already declares for that net",
            .{ bad.net, bad.declared_min, bad.declared_max, bad.derived_min, bad.derived_max },
        ) catch return EvalError.OutOfMemory;
        self.assertions.append(self.allocator, .{ .passed = false, .message = msg }) catch
            return EvalError.OutOfMemory;
    }

    return .{ .design_block = block };
}

/// Mutable accumulator for one design-block materialization. Keeping the bag
/// in one struct lets `(repeat …)` recursively send each body form through the
/// exact same builders as a hand-written form without duplicating the large
/// scope-form dispatch switch.
const BlockBuildState = struct {
    name: []const u8,
    instances: *std.ArrayList(Instance),
    all_pin_nets: *std.ArrayList(PinNetDecl),
    ports: *std.ArrayList(Port),
    notes: *std.ArrayList(Note),
    groups: *std.ArrayList(Group),
    sections: *std.ArrayList(env_mod.Section),
    net_ties: *std.ArrayList(NetTie),
    sub_blocks: *std.ArrayList(SubBlock),
    functions: *std.ArrayList(env_mod.FunctionSpec),
    verifications: *std.ArrayList(env_mod.Verification),
    test_points: *std.ArrayList(env_mod.TestPoint),
    parts: *std.ArrayList(env_mod.PlaceholderPart),
    layout_spec: *env_mod.LayoutSpec,
    board_spec: *env_mod.BoardSpec,
    revision_spec: *env_mod.Revision,
    rough_spec: *env_mod.RoughSpec,
    stackup_spec: *env_mod.StackupSpec,
    pdn_intents: *std.ArrayList(env_mod.PdnIntent),
    envelope_decls: *std.ArrayList(net_envelopes.Declaration),
    fabrication_layers: *std.ArrayList(env_mod.FabricationLayerSpec),
    net_class_specs: *std.ArrayList(env_mod.NetClassSpec),
    pll_loop_specs: *std.ArrayList(pll_loop.Spec),
    frequency_plan_specs: *std.ArrayList(frequency_plan.Spec),
    design_rules_spec: *env_mod.DesignRulesSpec,
    pcb_plan_spec: *?env_mod.PcbPlanSpec,
    kicad_pcb_path: *?[]const u8,
    net_form_sources: *std.StringHashMapUnmanaged(u32),
    has_explicit_layout: bool = false,
};

fn evalBlockBodyForms(
    self: *Evaluator,
    body_forms: []const Node,
    env: *Env,
    build: *BlockBuildState,
) EvalError!void {
    for (body_forms) |form| try evalBlockBodyForm(self, form, env, build);
}

/// Expand a design-scope `(repeat name start end body…)`. Each body form runs
/// through `evalBlockBodyForm`, so an expanded instance/sub-block/net is
/// indistinguishable from the same form written out by hand. The repeat owns
/// one source-resident ID anchor; generated children derive from that anchor,
/// their normal `origin_key`, and the lexical index, avoiding impossible
/// per-iteration `(id …)` insertions at one shared source offset. A repeat-level
/// `(ids ("origin@index" token) …)` sidecar overrides individual derivations so
/// an unrolled design can migrate without changing its established PCB UUIDs.
fn evalBlockRepeat(
    self: *Evaluator,
    form_children: []const Node,
    env: *Env,
    build: *BlockBuildState,
) EvalError!void {
    const spec = try special_forms.parseRepeat(self, form_children[1..], env);
    const repeat_id = try ids.getOrCreateFormId(self, form_children);
    const sidecar = ids.parseChildIdSidecar(self, form_children);
    var it = spec.iterator();
    while (it.next()) |index| {
        var loop_env = Env.init(self.allocator, env);
        defer loop_env.deinit();
        try loop_env.put(spec.name, .{ .number = @floatFromInt(index) });

        const first_instance = build.instances.items.len;
        const first_sub_block = build.sub_blocks.items.len;
        const first_section = build.sections.items.len;
        // Child forms share one source location across every iteration. Drop
        // their normal pending writes and retain only the repeat form's anchor.
        const pending_id_len = self.pending_ids.items.len;
        const pending_child_id_len = self.pending_child_ids.items.len;
        evalBlockBodyForms(self, spec.body, &loop_env, build) catch |err| {
            self.pending_ids.items.len = pending_id_len;
            self.pending_child_ids.items.len = pending_child_id_len;
            return err;
        };
        self.pending_ids.items.len = pending_id_len;
        self.pending_child_ids.items.len = pending_child_id_len;

        const new_instances = build.instances.items[first_instance..];
        for (new_instances) |*inst| {
            const origin = if (inst.origin_key.len > 0) inst.origin_key else inst.ref_des;
            inst.id = try repeatChildId(self, repeat_id, &sidecar, origin, index);
        }
        for (build.sub_blocks.items[first_sub_block..]) |*sb| {
            const subblock_uuid = try repeatChildId(self, repeat_id, &sidecar, sb.name, index);
            try ids.reassignSubBlockIdsV4(self, sb.block, subblock_uuid);
        }
        // Sections retain value copies of their member instances. Mirror the
        // freshly-derived IDs into those copies so every renderer/export path
        // observes the same identity as the top-level instance slice.
        syncRepeatedSectionIds(build.sections.items[first_section..], new_instances);
    }
}

fn repeatChildId(
    self: *Evaluator,
    repeat_id: []const u8,
    sidecar: *const ids.ChildIdSidecar,
    origin_key: []const u8,
    index: i64,
) EvalError![]const u8 {
    const indexed_key = std.fmt.allocPrint(self.allocator, "{s}@{d}", .{ origin_key, index }) catch
        return EvalError.OutOfMemory;
    if (sidecar.map.get(indexed_key)) |migration_id| return migration_id;
    return ids.deriveChildId(self, repeat_id, indexed_key, 0);
}

fn syncRepeatedSectionIds(sections: []env_mod.Section, instances: []const Instance) void {
    for (sections) |*section| {
        for (@as([]Instance, @constCast(section.instances))) |*copy| {
            for (instances) |inst| {
                if (std.mem.eql(u8, copy.ref_des, inst.ref_des)) {
                    copy.id = inst.id;
                    break;
                }
            }
        }
        syncRepeatedSectionIds(@constCast(section.sub_sections), instances);
    }
}

fn evalBlockBodyForm(
    self: *Evaluator,
    form: Node,
    env: *Env,
    build: *BlockBuildState,
) EvalError!void {
    const form_children = form.asList() orelse return;
    if (form_children.len == 0) return;
    const form_name = form_children[0].asAtom() orelse return;

    // Setup special forms may appear inline in a raw `(block …)` body —
    // evaluate `(let …)`/`(assert …)`/`(import …)`/`(id …)` for their
    // binding/effect, then continue. (A `(design-block …)` body never holds
    // these; in the wrapped form they precede the inner block.)
    if (forms_mod.SpecialForm.fromAtom(form_name)) |special| switch (special) {
        .let, .assert_, .assert_range, .import, .id_, .implements => {
            _ = try self.evalNode(form, env);
            return;
        },
        .repeat => {
            try evalBlockRepeat(self, form_children, env, build);
            return;
        },
        else => {},
    };

    const sf = ScopeForm.fromAtom(form_name) orelse {
        if (!isInertFormHead(form_name))
            self.warnFmt(form.span, "unknown sub-form ({s} …) in (design-block …)", .{form_name});
        return;
    };
    switch (sf) {
        .instance => {
            const result = try instance_mod.buildInstance(self, form_children, env);
            ids.registerRefDes(self, result.instance.ref_des);
            try build.instances.append(self.allocator, result.instance);
            for (result.pin_nets) |pn| try build.all_pin_nets.append(self.allocator, pn);
            for (result.inline_notes) |note| try build.notes.append(self.allocator, note);
            try appendAutoAliases(self, result.instance, result.pin_nets, build.net_ties);
        },
        .port => {
            const port = try builders.buildPort(self, form_children[1..], env);
            try build.ports.append(self.allocator, port);
        },
        .bus_port => try builders.expandTopLevelBusPort(self, form_children, env, build.ports),
        .note => try build.notes.append(self.allocator, try builders.buildNote(self, form_children[1..], env)),
        .group => {
            const group = try builders.buildGroup(self, form_children[1..], env);
            try build.groups.append(self.allocator, group);
        },
        .function => {
            const f = try builders.buildFunction(self, form_children[1..], env);
            try build.functions.append(self.allocator, f);
        },
        .sub_block => {
            const sb = try builders.buildSubBlock(self, form_children, env);
            try evalSubBlockBridges(self, form_children, sb.name, build.net_ties);
            try build.sub_blocks.append(self.allocator, sb);
        },
        .section => try evalSection(self, form_children, env, .{
            .instances = build.instances,
            .pin_nets = build.all_pin_nets,
            .notes = build.notes,
            .test_points = build.test_points,
        }, build.net_ties, build.sections, build.sub_blocks),
        .net => {
            try evalNetForm(self, form_children, env, build.net_ties);
            validate.trackNetFormSource(self, form_children, env, build.net_form_sources);
        },
        .bus_net => try evalBusNetForm(self, form_children, env, build.net_ties),
        .series => try instance_mod.evalSeriesForm(self, form_children, env, build.instances, build.all_pin_nets, build.notes),
        .fanout => try instance_mod.evalFanoutForm(self, form_children, env, build.instances, build.all_pin_nets),
        .decouple => try evalDecoupleForm(self, form_children, env, build.instances, build.all_pin_nets),
        .decouple_defaults => try parseDecoupleDefaults(self, form_children, env),
        .verifies => if (parseVerifies(self, form_children, env)) |v| try build.verifications.append(self.allocator, v),
        .test_point => _ = try test_point_mod.evalForm(self, form_children, env, .{
            .instances = build.instances,
            .pin_nets = build.all_pin_nets,
            .notes = build.notes,
            .test_points = build.test_points,
        }),
        .pullup => try micro_forms.emit(self, .pullup, form_children, env, build.instances, build.all_pin_nets),
        .pulldown => try micro_forms.emit(self, .pulldown, form_children, env, build.instances, build.all_pin_nets),
        .divider => try micro_forms.emit(self, .divider, form_children, env, build.instances, build.all_pin_nets),
        .led => try micro_forms.emit(self, .led, form_children, env, build.instances, build.all_pin_nets),
        .kicad_pcb => {
            if (parseKicadPcbPath(form_children)) |p| build.kicad_pcb_path.* = p;
        },
        .stub => if (try parseStub(self, form_children)) |p| {
            ids.registerRefDes(self, p.part.ref_des);
            try build.instances.append(self.allocator, p.instance);
            for (p.pin_nets) |pn| try build.all_pin_nets.append(self.allocator, pn);
            try build.parts.append(self.allocator, p.part);
        },
        .layout => {
            build.layout_spec.* = try parseLayout(self, form_children);
            build.has_explicit_layout = true;
        },
        .board => {
            // `(board …)` owns physical geometry, not fabrication identity.
            // Preserve an explicit role already encountered earlier in the
            // design body so form order cannot turn a board back into the
            // BoardSpec default (`subcircuit`).
            const role = build.board_spec.role;
            const power_plane = build.board_spec.power_plane;
            build.board_spec.* = try parseBoard(self, form_children);
            build.board_spec.role = role;
            build.board_spec.power_plane = power_plane;
        },
        .board_role => build.board_spec.role = board_role_mod.parse(self, form_children),
        .power_plane => build.board_spec.power_plane = board_role_mod.parsePowerPlane(self, form_children),
        .revision => build.revision_spec.* = try parseRevision(self, form_children),
        .rough => build.rough_spec.* = try parseRough(self, form_children),
        .stackup => build.stackup_spec.* = try parseStackup(self, form_children),
        .pdn => if (parsePdnIntent(self, form_children)) |intent|
            build.pdn_intents.append(self.allocator, intent) catch return EvalError.OutOfMemory,
        .net_envelope => if (parseNetEnvelope(self, form_children)) |decl|
            build.envelope_decls.append(self.allocator, decl) catch return EvalError.OutOfMemory,
        .fabrication_layer => if (try parseFabricationLayer(self, form_children)) |layer|
            build.fabrication_layers.append(self.allocator, layer) catch return EvalError.OutOfMemory,
        .net_class => if (try parseNetClass(self, form_children)) |nc|
            build.net_class_specs.append(self.allocator, nc) catch return EvalError.OutOfMemory,
        .pll_loop => {
            const spec = pll_loop.parse(form_children) catch {
                self.setError(form.span, "malformed (pll-loop …); see `netlisp reference pll-loop`");
                return EvalError.InvalidForm;
            };
            build.pll_loop_specs.append(self.allocator, spec) catch return EvalError.OutOfMemory;
        },
        .frequency_plan => {
            const spec = frequency_plan.parse(form_children) catch |err| {
                self.setError(form.span, switch (err) {
                    error.SumMixingUnsupported => "(frequency-plan …) models difference mixing only; (mixer sum) has no analysis here and is refused rather than approximated",
                    error.SpurOrderTooHigh => "(frequency-plan …) (spurs (max-order M)) admits 1 through 9; a higher order enumerates arithmetic rather than mixer behaviour",
                    error.InvalidForm => "malformed (frequency-plan …); see `netlisp reference frequency-plan`",
                });
                return EvalError.InvalidForm;
            };
            build.frequency_plan_specs.append(self.allocator, spec) catch return EvalError.OutOfMemory;
        },
        .design_rules => build.design_rules_spec.* = parseDesignRules(self, form_children),
        .pcb_plan => build.pcb_plan_spec.* = try takeFirstPcbPlan(self, form_children, form.span, build.pcb_plan_spec.*),
        // Section-only forms are ignored at the top level — a
        // design-block body shouldn't carry status/description/pins
        // directly. The exhaustive switch is the contract; the warning
        // makes the silent skip visible.
        .pins => {
            var pin_groups: std.ArrayList(env_mod.PinGroup) = .empty;
            try evalPinsForm(self, form_children, build.name, env, build.instances, build.all_pin_nets, build.net_ties, &pin_groups);
        },
        .protocol, .calc, .description, .role, .diagram, .hosts, .category => {
            self.warnFmt(form.span, "({s} …) is section-only — ignored at design-block top level", .{form_name});
        },
    }
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
    var changes: std.ArrayList(env_mod.RevisionChange) = .empty;

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
    net_ties: *std.ArrayList(NetTie),
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
fn evalNetForm(self: *Evaluator, form_children: []const Node, env: *Env, net_ties: *std.ArrayList(NetTie)) EvalError!void {
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
fn evalBusNetForm(self: *Evaluator, form_children: []const Node, env: *Env, net_ties: *std.ArrayList(NetTie)) EvalError!void {
    if (form_children.len < 5) return;
    const prefix = (try self.evalNode(form_children[1], env)).asString() orelse return;
    const start = numberAsUsize(try self.evalNode(form_children[2], env)) orelse return;
    const end = numberAsUsize(try self.evalNode(form_children[3], env)) orelse return;
    if (end < start) return;
    if (end - start >= max_bus_expansion) {
        self.warnFmt(form_children[0].span, "(bus-net …) index range {d}..{d} exceeds the {d}-lane cap — ignored", .{ start, end, max_bus_expansion });
        return;
    }

    // Mapped mode names one sub-block plus an indexed child port family:
    // `(suffix "_MCU") (over "shift" (port-base "B" 1))`.
    var mapped_suffix: []const u8 = "";
    var mapped_sub: ?[]const u8 = null;
    var mapped_port_base: ?[]const u8 = null;
    var mapped_port_start: usize = 0;
    for (form_children[4..]) |c| {
        if (c.isForm("suffix")) {
            const sc = c.asList().?;
            if (sc.len >= 2) mapped_suffix = literalText(sc[1]) orelse "";
        }
        if (c.isForm("over")) {
            const oc = c.asList().?;
            if (oc.len >= 3 and oc[2].isForm("port-base")) {
                const pc = oc[2].asList().?;
                if (pc.len >= 3) {
                    mapped_sub = literalText(oc[1]);
                    mapped_port_base = literalText(pc[1]);
                    mapped_port_start = numberAsUsize(try self.evalNode(pc[2], env)) orelse 0;
                }
            }
        }
    }
    if (mapped_sub != null and mapped_port_base != null) {
        var k = start;
        while (k <= end) : (k += 1) {
            const parent = std.fmt.allocPrint(self.allocator, "{s}{d}{s}", .{ prefix, k, mapped_suffix }) catch
                return EvalError.OutOfMemory;
            const child = std.fmt.allocPrint(self.allocator, "{s}/{s}{d}", .{
                mapped_sub.?, mapped_port_base.?, mapped_port_start + (k - start),
            }) catch return EvalError.OutOfMemory;
            try net_ties.append(self.allocator, .{ .a = parent, .b = child });
        }
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
    net_ties: *std.ArrayList(NetTie),
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
    net_ties: *std.ArrayList(NetTie),
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
    net_ties: *std.ArrayList(NetTie),
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
    net_ties: *std.ArrayList(NetTie),
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
    instances: *std.ArrayList(Instance),
    all_pin_nets: *std.ArrayList(PinNetDecl),
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

        // Compact rail form: each `(per-pin COMPONENT FUNCTION…)` emits one
        // bypass per named pin function, while `(bulk COMPONENT COUNT)` emits
        // shared rail capacitors. The host is inferred only when every named
        // function resolves on exactly one already-declared instance.
        var has_sub_forms = false;
        for (form_children[2..]) |sf| {
            if (sf.isForm("per-pin") or sf.isForm("bulk") or sf.isForm("bypass")) {
                has_sub_forms = true;
                break;
            }
        }

        if (has_sub_forms) {
            for (form_children[2..]) |sf| {
                const sub = sf.asList() orelse continue;
                if (sf.isForm("per-pin")) {
                    if (sub.len < 3) return EvalError.ArityError;
                    const host = try inferCompactDecoupleHost(self, sub[2..], net_name, instances.items, all_pin_nets.items, sf.span);
                    var expanded: std.ArrayList(Node) = .empty;
                    try expanded.append(self.allocator, sub[1]);
                    try expanded.append(self.allocator, Node.int(sf.span, 1));
                    try expanded.append(self.allocator, Node.atom(sf.span, "per-pin"));
                    try expanded.append(self.allocator, Node.string(sf.span, host));
                    for (sub[2..]) |pin| try expanded.append(self.allocator, pin);
                    try builders.emitDecoupleItems(self, expanded.items, net_name, env, instances, all_pin_nets, form_id, &sidecar);
                } else if (sf.isForm("bulk")) {
                    if (sub.len < 3) return EvalError.ArityError;
                    try builders.emitBulkDecouples(self, sub[1], sub[2], net_name, env, .{
                        .instances = instances,
                        .pin_nets = all_pin_nets,
                        .form_id = form_id,
                        .sidecar = &sidecar,
                    });
                } else if (sf.isForm("bypass")) {
                    try builders.emitDecoupleItems(self, sub[1..], net_name, env, instances, all_pin_nets, form_id, &sidecar);
                }
            }
        } else {
            try builders.emitDecoupleItems(self, form_children[2..], net_name, env, instances, all_pin_nets, form_id, &sidecar);
        }
    }
}

fn inferCompactDecoupleHost(
    self: *Evaluator,
    functions: []const Node,
    net_name: []const u8,
    instances: []const Instance,
    pin_nets: []const PinNetDecl,
    span: ast.Span,
) EvalError![]const u8 {
    if (self.decouple_defaults.ic.len > 0) return self.decouple_defaults.ic;
    var match: ?[]const u8 = null;
    for (instances) |inst| {
        const pinout = builders.findPinFuncMap(self, instances, inst.ref_des) orelse continue;
        var all_match = true;
        for (functions) |function_node| {
            const function = ids.pinId(self, function_node) orelse {
                all_match = false;
                break;
            };
            const pad = instance_mod.resolvePinName(self, pinout, function, function_node.span) orelse {
                all_match = false;
                break;
            };
            var declared = false;
            for (pin_nets) |pn| if (std.mem.eql(u8, pn.ref_des, inst.ref_des) and
                std.mem.eql(u8, pn.pin, pad) and std.mem.eql(u8, pn.net, net_name))
            {
                declared = true;
                break;
            };
            if (!declared) {
                all_match = false;
                break;
            }
        }
        if (!all_match) continue;
        if (match != null) {
            self.setErrorFmt(span, "compact decouple host is ambiguous for rail '{s}'; add (decouple-defaults (ic \"REF\"))", .{net_name});
            return EvalError.InvalidForm;
        }
        match = inst.ref_des;
    }
    return match orelse {
        self.setErrorFmt(span, "compact decouple could not infer a host for rail '{s}'; declare the IC pins first or add (decouple-defaults (ic \"REF\"))", .{net_name});
        return EvalError.InvalidForm;
    };
}

/// Mutable bag of pointers to the per-section accumulators that
/// `processSharedSectionForm` writes into. Bundling them lets both
/// `evalSection` and `evalSubSection` reuse the exact same handler for
/// the forms whose semantics are identical between the two scopes
/// (`description`, `note`, `port`, `protocol`, `calc`).
const SectionScope = struct {
    description: *[]const u8,
    notes: *std.ArrayList(env_mod.SectionNote),
    ports: *std.ArrayList(env_mod.SectionPort),
    protocols: *std.ArrayList([]const u8),
    calcs: *std.ArrayList(env_mod.CalcBlock),
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

fn parseSectionRole(self: *Evaluator, children: []const Node) env_mod.BlockRole {
    if (children.len < 2) return .auto;
    const role = children[1].asAtom() orelse return .auto;
    if (std.mem.eql(u8, role, "input")) return .input;
    if (std.mem.eql(u8, role, "output")) return .output;
    self.warnFmt(children[1].span, "unknown role '{s}' in (role …) — expected input|output", .{role});
    return .auto;
}

fn parseDiagramHidden(self: *Evaluator, children: []const Node) bool {
    if (children.len < 2) return false;
    const mode = children[1].asAtom() orelse return false;
    if (std.mem.eql(u8, mode, "hidden")) return true;
    self.warnFmt(children[1].span, "unknown diagram mode '{s}' in (diagram …) — expected hidden", .{mode});
    return false;
}

/// Evaluate a section form and its children.
fn evalSection(
    self: *Evaluator,
    form_children: []const Node,
    env: *Env,
    test_point_ctx: test_point_mod.EvalContext,
    net_ties: *std.ArrayList(NetTie),
    sections: *std.ArrayList(env_mod.Section),
    sub_blocks: *std.ArrayList(SubBlock),
) EvalError!void {
    const instances = test_point_ctx.instances;
    const all_pin_nets = test_point_ctx.pin_nets;
    const notes = test_point_ctx.notes;
    if (form_children.len < 2) return;
    const sec_name_val = try self.evalNode(form_children[1], env);
    const sec_name = sec_name_val.asString() orelse return;
    var sec_instances: std.ArrayList(Instance) = .empty;
    var sec_pin_groups: std.ArrayList(env_mod.PinGroup) = .empty;
    var sec_description: []const u8 = "";
    var sec_notes: std.ArrayList(env_mod.SectionNote) = .empty;
    var sec_ports: std.ArrayList(env_mod.SectionPort) = .empty;
    var sec_protocols: std.ArrayList([]const u8) = .empty;
    var sec_calcs: std.ArrayList(env_mod.CalcBlock) = .empty;
    var sec_sub_sections: std.ArrayList(env_mod.Section) = .empty;
    var block_role: env_mod.BlockRole = .auto;
    var diagram_hidden = false;
    var sec_category: []const u8 = "";
    var sec_hosts: std.ArrayList([]const u8) = .empty;

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
            .role => block_role = parseSectionRole(self, sf_children),
            .diagram => diagram_hidden = parseDiagramHidden(self, sf_children),
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
            .section => try evalSubSection(self, sf_children, env, test_point_ctx, net_ties, &sec_instances, &sec_sub_sections, sub_blocks),
            .test_point => if (try test_point_mod.evalForm(self, sf_children, env, test_point_ctx)) |inst|
                try sec_instances.append(self.allocator, inst),
            .sub_block => {
                const sb = try builders.buildSubBlock(self, sf_children, env);
                try evalSubBlockBridges(self, sf_children, sb.name, net_ties);
                try sec_hosts.append(self.allocator, sb.name);
                try sub_blocks.append(self.allocator, sb);
            },
            .pullup, .pulldown, .divider, .led => {
                const first = instances.items.len;
                try evalMicroForm(self, sft, sf_children, env, instances, all_pin_nets);
                for (instances.items[first..]) |new_inst| try sec_instances.append(self.allocator, new_inst);
            },
            // Shared-form variants are consumed above by
            // `processSharedSectionForm`; top-level-only forms are
            // ignored inside a section body (with a lint warning so the
            // silent skip is visible).
            .description, .note, .port, .protocol, .calc => {},
            .group,
            .function,
            .verifies,
            .decouple_defaults,
            .kicad_pcb,
            .stub,
            .layout,
            .board,
            .board_role,
            .power_plane,
            .revision,
            .rough,
            .stackup,
            .pdn,
            .net_envelope,
            .fabrication_layer,
            .net_class,
            .pll_loop,
            .frequency_plan,
            .design_rules,
            .pcb_plan,
            => self.warnFmt(sf.span, "({s} …) is top-level-only — ignored inside (section …)", .{sf_name}),
        }
    }

    const final_instances = sec_instances.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory;
    const final_pin_groups = sec_pin_groups.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory;
    const final_sub_sections = sec_sub_sections.toOwnedSlice(self.allocator) catch &.{};

    // Infer status: concept if no instances, no pin_groups, and no sub-sections with content
    const status = if (final_instances.len == 0 and final_pin_groups.len == 0 and sec_hosts.items.len == 0)
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
    instances: *std.ArrayList(Instance),
    all_pin_nets: *std.ArrayList(PinNetDecl),
    net_ties: *std.ArrayList(NetTie),
    sec_pin_groups: *std.ArrayList(env_mod.PinGroup),
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
    var pg_pins: std.ArrayList(env_mod.PartPin) = .empty;
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
    test_point_ctx: test_point_mod.EvalContext,
    net_ties: *std.ArrayList(NetTie),
    sec_instances: *std.ArrayList(Instance),
    sec_sub_sections: *std.ArrayList(env_mod.Section),
    sub_blocks: *std.ArrayList(SubBlock),
) EvalError!void {
    const instances = test_point_ctx.instances;
    const all_pin_nets = test_point_ctx.pin_nets;
    const notes = test_point_ctx.notes;
    if (sf_children.len < 2) return;
    const sub_name_val = try self.evalNode(sf_children[1], env);
    const sub_name = sub_name_val.asString() orelse return;
    var sub_instances: std.ArrayList(Instance) = .empty;
    var sub_pin_groups: std.ArrayList(env_mod.PinGroup) = .empty;
    var sub_description: []const u8 = "";
    var sub_notes: std.ArrayList(env_mod.SectionNote) = .empty;
    var sub_ports: std.ArrayList(env_mod.SectionPort) = .empty;
    var sub_protocols: std.ArrayList([]const u8) = .empty;
    var sub_calcs: std.ArrayList(env_mod.CalcBlock) = .empty;
    var sub_hosts: std.ArrayList([]const u8) = .empty;

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
                var pg_pins2: std.ArrayList(env_mod.PartPin) = .empty;
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
            .test_point => if (try test_point_mod.evalForm(self, ssf_children, env, test_point_ctx)) |inst| {
                try sec_instances.append(self.allocator, inst);
                try sub_instances.append(self.allocator, inst);
            },
            .sub_block => {
                const sb = try builders.buildSubBlock(self, ssf_children, env);
                try evalSubBlockBridges(self, ssf_children, sb.name, net_ties);
                try sub_hosts.append(self.allocator, sb.name);
                try sub_blocks.append(self.allocator, sb);
            },
            .pullup, .pulldown, .divider, .led => {
                const first = instances.items.len;
                try evalMicroForm(self, sft, ssf_children, env, instances, all_pin_nets);
                for (instances.items[first..]) |new_inst| {
                    try sec_instances.append(self.allocator, new_inst);
                    try sub_instances.append(self.allocator, new_inst);
                }
            },
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

    const status = if (final_sub_instances.len == 0 and final_sub_pin_groups.len == 0 and sub_hosts.items.len == 0)
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
        .hosts = sub_hosts.toOwnedSlice(self.allocator) catch &.{},
    });
}

fn evalMicroForm(
    self: *Evaluator,
    form: ScopeForm,
    children: []const Node,
    env: *Env,
    instances: *std.ArrayList(Instance),
    pin_nets: *std.ArrayList(PinNetDecl),
) EvalError!void {
    return switch (form) {
        .pullup => micro_forms.emit(self, .pullup, children, env, instances, pin_nets),
        .pulldown => micro_forms.emit(self, .pulldown, children, env, instances, pin_nets),
        .divider => micro_forms.emit(self, .divider, children, env, instances, pin_nets),
        .led => micro_forms.emit(self, .led, children, env, instances, pin_nets),
        else => return EvalError.InvalidForm,
    };
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
fn buildNets(self: *Evaluator, all_pin_nets: *std.ArrayList(PinNetDecl), net_ties: *std.ArrayList(NetTie)) EvalError![]Net {
    var net_map: std.StringHashMapUnmanaged(std.ArrayList(PinRef)) = .empty;
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
        var merge_keys: std.ArrayList([]const u8) = .empty;
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
        var rename_keys: std.ArrayList([]const u8) = .empty;
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
    var nets: std.ArrayList(Net) = .empty;
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
/// an optional `(anchor "REF")`, `(group "name" "REF"…)` priority tiers, and
/// `(critical-loop "name" "REF"…)` closed-chain sets. Member tokens stay raw
/// (ref-des or origin name) — `placement/optimizer.zig` matches them leniently.
/// A `(group …)` with no members is dropped; `(rough)` alone ⇒ `present=false`.
fn parseRough(self: *Evaluator, form_children: []const Node) EvalError!env_mod.RoughSpec {
    var anchor: []const u8 = "";
    var groups: std.ArrayList(env_mod.RoughGroup) = .empty;
    var critical_loops: std.ArrayList(env_mod.RoughGroup) = .empty;
    for (form_children[1..]) |child| {
        const cl = child.asList() orelse continue;
        if (cl.len == 0) continue;
        const head = cl[0].asAtom() orelse continue;
        if (std.mem.eql(u8, head, "anchor")) {
            if (cl.len >= 2) anchor = cl[1].asString() orelse cl[1].asAtom() orelse "";
        } else if (std.mem.eql(u8, head, "group")) {
            try parseRoughGroup(self, cl, &groups);
        } else if (std.mem.eql(u8, head, "critical-loop")) {
            try parseRoughMemberSet(env_mod.RoughGroup, self, cl, &critical_loops);
        } else {
            self.warnFmt(child.span, "unknown (rough …) item ({s} …) — expected (anchor …), (group …), or (critical-loop …)", .{head});
        }
    }
    const grp = groups.toOwnedSlice(self.allocator) catch &.{};
    const loops = critical_loops.toOwnedSlice(self.allocator) catch &.{};
    return .{ .anchor = anchor, .groups = grp, .critical_loops = loops, .present = anchor.len > 0 or grp.len > 0 or loops.len > 0 };
}

/// Parse one `(group "name" "REF"…)` child of a `(rough …)` form: the first
/// token is the cosmetic label, the rest are member ref-des / origin tokens.
/// A group with no members after the label is dropped (the caller never sees it).
fn parseRoughGroup(
    self: *Evaluator,
    cl: []const Node,
    out: *std.ArrayList(env_mod.RoughGroup),
) EvalError!void {
    return parseRoughMemberSet(env_mod.RoughGroup, self, cl, out);
}

fn parseRoughMemberSet(
    comptime T: type,
    self: *Evaluator,
    cl: []const Node,
    out: *std.ArrayList(T),
) EvalError!void {
    if (cl.len < 2) return;
    const name = cl[1].asString() orelse cl[1].asAtom() orelse "";
    var members: std.ArrayList([]const u8) = .empty;
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
    var signals: std.ArrayList(env_mod.PartSignal) = .empty;

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
                if (nf >= 1 and nf <= 255) channels = numeric.checkedInt(u8, nf) orelse channels;
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
    var pin_nets: std.ArrayList(PinNetDecl) = .empty;
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
    var placements: std.ArrayList(env_mod.Placement) = .empty;
    var rows: std.ArrayList(env_mod.LayoutRow) = .empty;
    var groups: std.ArrayList(env_mod.LayoutGroup) = .empty;
    var edges: std.ArrayList(env_mod.LayoutEdge) = .empty;
    for (form_children[1..]) |child| {
        const c = child.asList() orelse continue;
        if (c.len < 2) continue;
        const head = c[0].asAtom() orelse continue;
        // (edge left|right "a" "b" …) — pin blocks to the diagram's L/R edge.
        if (std.mem.eql(u8, head, "edge")) {
            const side_atom = c[1].asAtom() orelse c[1].asString() orelse continue;
            const side: env_mod.EdgeSide = if (std.mem.eql(u8, side_atom, "right")) .right else .left;
            var members: std.ArrayList([]const u8) = .empty;
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
            var members: std.ArrayList([]const u8) = .empty;
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
            var members: std.ArrayList([]const u8) = .empty;
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
        var constraints: std.ArrayList(env_mod.PlaceConstraint) = .empty;
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

const GridSection = struct { row: i32, col: i32, name: []const u8 };

fn lessGridSection(_: void, a: GridSection, b: GridSection) bool {
    return a.row < b.row or (a.row == b.row and a.col < b.col);
}

/// Seed an omitted diagram layout from authored section `(row N)` / `(col N)`
/// hints. Only fully-coordinated, visible sections participate; other diagram
/// blocks retain the renderer's normal automatic placement.
fn seedLayoutFromSectionGrid(
    self: *Evaluator,
    body_forms: []const Node,
    env: *Env,
    layout: *env_mod.LayoutSpec,
) EvalError!void {
    var grid: std.ArrayList(GridSection) = .empty;
    for (body_forms) |form| {
        const section = form.asList() orelse continue;
        if (section.len < 2 or !form.isForm("section")) continue;
        var row: ?i32 = null;
        var col: ?i32 = null;
        var hidden = false;
        for (section[2..]) |child| {
            const c = child.asList() orelse continue;
            if (c.len < 2) continue;
            if (child.isForm("diagram") and std.mem.eql(u8, c[1].asText() orelse "", "hidden")) hidden = true;
            const value = c[1].asNumber() orelse continue;
            const coordinate = numeric.checkedInt(i32, value) orelse continue;
            if (child.isForm("row")) row = coordinate;
            if (child.isForm("col")) col = coordinate;
        }
        if (hidden or row == null or col == null) continue;
        const name = (try self.evalNode(section[1], env)).asString() orelse continue;
        try grid.append(self.allocator, .{ .row = row.?, .col = col.?, .name = name });
    }
    if (grid.items.len == 0) return;
    std.mem.sort(GridSection, grid.items, {}, lessGridSection);

    var rows: std.ArrayList(env_mod.LayoutRow) = .empty;
    var start: usize = 0;
    while (start < grid.items.len) {
        var end = start + 1;
        while (end < grid.items.len and grid.items[end].row == grid.items[start].row) : (end += 1) {}
        var members: std.ArrayList([]const u8) = .empty;
        for (grid.items[start..end]) |entry| try members.append(self.allocator, entry.name);
        try rows.append(self.allocator, .{ .members = members.toOwnedSlice(self.allocator) catch &.{} });
        start = end;
    }
    layout.rows = rows.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory;
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
    var sides: std.ArrayList(env_mod.PlacementSideSpec) = .empty;
    for (form_children[1..]) |child| {
        const c = child.asList() orelse continue;
        if (c.len < 1) continue;
        const head = c[0].asAtom() orelse continue;
        const side = placementSideFromAtom(head) orelse continue;
        var items: std.ArrayList(env_mod.PlacementItem) = .empty;
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

/// Parse the typed policy nested under `(perimeter-fence … (keepout …))`.
/// A declaration blocks every supported physical family unless `(blocks …)`
/// narrows it; `(allow-nets …)` admits named copper through the reserved band.
fn parsePerimeterKeepout(
    self: *Evaluator,
    rule: []const Node,
    fence: *env_mod.PerimeterFenceSpec,
) EvalError!void {
    if (rule.len < 2 or (rule[1].asNumber() orelse 0) <= 0) {
        self.warnFmt(
            rule[0].span,
            "(perimeter-fence … (keepout CLEARANCE …)) needs a positive clearance",
            .{},
        );
        return;
    }
    fence.keepout.clearance = rule[1].asNumber().?;
    fence.keepout.blocks = .{ .components = true, .tracks = true, .vias = true };
    var allow_nets: std.ArrayList([]const u8) = .empty;
    for (rule[2..]) |option_node| {
        const option = option_node.asList() orelse continue;
        if (option.len < 1) continue;
        const option_head = option[0].asAtom() orelse continue;
        if (std.mem.eql(u8, option_head, "blocks")) {
            fence.keepout.blocks = .{};
            for (option[1..]) |feature_node| {
                const feature = feature_node.asString() orelse feature_node.asAtom() orelse continue;
                if (std.mem.eql(u8, feature, "components")) {
                    fence.keepout.blocks.components = true;
                } else if (std.mem.eql(u8, feature, "tracks")) {
                    fence.keepout.blocks.tracks = true;
                } else if (std.mem.eql(u8, feature, "vias")) {
                    fence.keepout.blocks.vias = true;
                } else {
                    self.warnFmt(
                        feature_node.span,
                        "unknown perimeter keepout feature '{s}' — expected components, tracks, or vias",
                        .{feature},
                    );
                }
            }
        } else if (std.mem.eql(u8, option_head, "allow-nets")) {
            for (option[1..]) |net_node| {
                const net = net_node.asString() orelse net_node.asAtom() orelse continue;
                allow_nets.append(self.allocator, net) catch return EvalError.OutOfMemory;
            }
        } else {
            self.warnFmt(option[0].span, "unknown perimeter (keepout …) sub-form ({s} …)", .{option_head});
        }
    }
    fence.keepout.allow_nets = allow_nets.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory;
}

/// Parse one board-derived via fence and its optional generic keepout policy.
fn parsePerimeterFence(
    self: *Evaluator,
    children: []const Node,
) EvalError!env_mod.PerimeterFenceSpec {
    var fence: env_mod.PerimeterFenceSpec = .{};
    for (children) |rule_node| {
        const rule = rule_node.asList() orelse continue;
        if (rule.len < 1) continue;
        const head = rule[0].asAtom() orelse continue;
        if (std.mem.eql(u8, head, "via") and rule.len >= 3) {
            fence.via_dia = @max(rule[1].asNumber() orelse 0, 0);
            fence.via_drill = @max(rule[2].asNumber() orelse 0, 0);
        } else if (std.mem.eql(u8, head, "spacing") and rule.len >= 2) {
            fence.spacing = @max(rule[1].asNumber() orelse 0, 0);
        } else if (std.mem.eql(u8, head, "edge-offset") and rule.len >= 2) {
            fence.edge_offset = @max(rule[1].asNumber() orelse 0, 0);
        } else if (std.mem.eql(u8, head, "mask-width") and rule.len >= 2) {
            fence.mask_width = @max(rule[1].asNumber() orelse 0, 0);
        } else if (std.mem.eql(u8, head, "net") and rule.len >= 2) {
            fence.net = rule[1].asString() orelse rule[1].asAtom() orelse fence.net;
        } else if (std.mem.eql(u8, head, "keepout")) {
            try parsePerimeterKeepout(self, rule, &fence);
        }
    }
    return fence;
}

/// Parse a top-level `(board …)` form: `(size W H)` outline (mm) + per-edge item
/// lists (`(left|right|top|bottom …)`, the words naming physical board edges) +
/// `(corners "REF" …)` mounting hardware. The edge lists are parsed by
/// `parseBoardSides`; this adds the size and corners on top.
fn parseBoard(self: *Evaluator, form_children: []const Node) EvalError!env_mod.BoardSpec {
    const board_sides = try parseBoardSides(self, form_children);
    var part_number: []const u8 = "";
    var w: f64 = 0;
    var h: f64 = 0;
    var corner_radius: f64 = 0;
    var outline_approved: []const u8 = "";
    var perimeter_fence: env_mod.PerimeterFenceSpec = .{};
    var corners: std.ArrayList(env_mod.PlacementItem) = .empty;
    for (form_children[1..]) |child| {
        const c = child.asList() orelse continue;
        if (c.len < 1) continue;
        const head = c[0].asAtom() orelse continue;
        if (std.mem.eql(u8, head, "part-number")) {
            if (c.len >= 2) {
                part_number = c[1].asString() orelse c[1].asAtom() orelse "";
            }
            continue;
        }
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
        if (std.mem.eql(u8, head, "outline-approved")) {
            if (c.len >= 2) outline_approved = parseOutlineApproval(self, c[1]);
            continue;
        }
        if (std.mem.eql(u8, head, "perimeter-fence")) {
            perimeter_fence = try parsePerimeterFence(self, c[1..]);
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
        .part_number = part_number,
        .w = w,
        .h = h,
        .corner_radius = corner_radius,
        .outline_approved = outline_approved,
        .sides = board_sides,
        .corners = corners.toOwnedSlice(self.allocator) catch &.{},
        .perimeter_fence = perimeter_fence,
        .present = true,
    };
}

/// Parse `(outline-approved "DIGEST")` — the author's content-bound
/// acceptance of a saved outline profile the `(board …)` rectangle cannot
/// describe. Only the exact hex digest shape the `outline-drift` finding
/// prints is accepted; anything else warns and is dropped, so a typo can
/// never read as an approval of geometry nobody looked at.
fn parseOutlineApproval(self: *Evaluator, node: Node) []const u8 {
    const text = node.asString() orelse node.asAtom() orelse "";
    if (text.len == outline_mod.digest_len and hexOnly(text)) return text;
    self.warnFmt(
        node.span,
        "(outline-approved …) needs the {d}-character hex outline digest the fab-readiness outline-drift finding prints",
        .{outline_mod.digest_len},
    );
    return "";
}

fn hexOnly(text: []const u8) bool {
    for (text) |c| {
        if (!std.ascii.isHex(c)) return false;
    }
    return true;
}

fn fabricationBasenameSafe(name: []const u8) bool {
    if (name.len <= 4 or !std.mem.endsWith(u8, name, ".gbr")) return false;
    for (name) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.') continue;
        return false;
    }
    return std.mem.indexOf(u8, name, "..") == null;
}

fn parseFabricationPolygon(self: *Evaluator, node: Node) EvalError!?[]const [2]f64 {
    const poly = node.asList() orelse return null;
    if (poly.len == 0 or !std.mem.eql(u8, poly[0].asAtom() orelse "", "polygon")) return null;
    var points: std.ArrayList([2]f64) = .empty;
    for (poly[1..]) |point_node| {
        const point = point_node.asList() orelse continue;
        if (point.len != 3 or !std.mem.eql(u8, point[0].asAtom() orelse "", "xy")) continue;
        const x = point[1].asNumber() orelse continue;
        const y = point[2].asNumber() orelse continue;
        points.append(self.allocator, .{ x, y }) catch return EvalError.OutOfMemory;
    }
    if (points.items.len < 3) {
        self.warnFmt(node.span, "fabrication-layer polygon needs at least three (xy X Y) vertices", .{});
        return null;
    }
    return points.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory;
}

/// Parse separately fabricated backing artwork. Unlike `(stackup …)`, this
/// owns positive application regions plus optional courtyard cutouts and an
/// explicit board face. Geometry stays in world mm so a saved layout and the
/// fabrication preview/export all see the same result.
fn parseFabricationLayer(self: *Evaluator, form_children: []const Node) EvalError!?env_mod.FabricationLayerSpec {
    if (form_children.len < 2) {
        self.warnFmt(form_children[0].span, "(fabrication-layer …) needs a .gbr basename", .{});
        return null;
    }
    const name = form_children[1].asString() orelse {
        self.warnFmt(form_children[1].span, "fabrication-layer basename must be a quoted string", .{});
        return null;
    };
    if (!fabricationBasenameSafe(name)) {
        self.warnFmt(form_children[1].span, "fabrication-layer basename must be a safe filename ending in .gbr", .{});
        return null;
    }

    var kind: []const u8 = "adhesive";
    var material: []const u8 = "";
    var thickness: f64 = 0;
    var side: ?env_mod.FabricationSide = null;
    var regions: std.ArrayList(env_mod.FabricationRegion) = .empty;
    var exclusion: env_mod.FabricationFootprintExclusion = .{};

    for (form_children[2..]) |child_node| {
        const child = child_node.asList() orelse continue;
        if (child.len == 0) continue;
        const head = child[0].asAtom() orelse continue;
        if (std.mem.eql(u8, head, "kind") and child.len >= 2) {
            kind = child[1].asAtom() orelse child[1].asString() orelse kind;
        } else if (std.mem.eql(u8, head, "side") and child.len >= 2) {
            const value = child[1].asAtom() orelse "";
            if (std.mem.eql(u8, value, "top")) side = .top else if (std.mem.eql(u8, value, "bottom")) side = .bottom else self.warnFmt(child[1].span, "fabrication-layer side must be top or bottom", .{});
        } else if (std.mem.eql(u8, head, "material") and child.len >= 2) {
            material = child[1].asString() orelse "";
        } else if (std.mem.eql(u8, head, "thickness") and child.len >= 2) {
            thickness = @max(child[1].asNumber() orelse 0, 0);
        } else if (std.mem.eql(u8, head, "region") and child.len >= 2) {
            if (std.mem.eql(u8, child[1].asAtom() orelse "", "board")) {
                regions.append(self.allocator, .board) catch return EvalError.OutOfMemory;
            } else if (try parseFabricationPolygon(self, child[1])) |points| {
                regions.append(self.allocator, .{ .polygon = points }) catch return EvalError.OutOfMemory;
            } else {
                self.warnFmt(child_node.span, "fabrication-layer region must be board or (polygon (xy X Y) …)", .{});
            }
        } else if (std.mem.eql(u8, head, "exclude-footprints")) {
            exclusion.enabled = true;
            var refs: std.ArrayList([]const u8) = .empty;
            for (child[1..]) |item| {
                if (item.asAtom()) |mode| {
                    if (std.mem.eql(u8, mode, "all-sides")) exclusion.all_sides = true else if (!std.mem.eql(u8, mode, "same-side"))
                        self.warnFmt(item.span, "exclude-footprints mode must be same-side or all-sides", .{});
                } else if (item.asString()) |ref| {
                    refs.append(self.allocator, ref) catch return EvalError.OutOfMemory;
                } else if (item.asList()) |modifier| {
                    if (modifier.len >= 2 and std.mem.eql(u8, modifier[0].asAtom() orelse "", "clearance"))
                        exclusion.clearance = @max(modifier[1].asNumber() orelse 0, 0);
                }
            }
            exclusion.refs = refs.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory;
        } else {
            self.warnFmt(child_node.span, "unknown fabrication-layer option ({s} …)", .{head});
        }
    }

    if (side == null) {
        self.warnFmt(form_children[0].span, "fabrication-layer requires an explicit (side top|bottom)", .{});
        return null;
    }
    if (material.len == 0 or !(thickness > 0) or regions.items.len == 0) {
        self.warnFmt(form_children[0].span, "fabrication-layer requires material, positive thickness, and at least one region", .{});
        return null;
    }
    const expected_prefix = if (side.? == .bottom) "psb_" else "pst_";
    if (std.mem.eql(u8, kind, "adhesive") and !std.mem.startsWith(u8, name, expected_prefix))
        self.warnFmt(form_children[1].span, "{s} adhesive layer names conventionally start with {s}", .{ @tagName(side.?), expected_prefix });

    return .{
        .name = name,
        .kind = kind,
        .side = side.?,
        .material = material,
        .thickness = thickness,
        .regions = regions.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
        .exclude_footprints = exclusion,
    };
}

/// Parse one board-level PDN target. Required positive ripple is what makes a
/// target-impedance verdict meaningful; all other fields may be inferred by
/// the post-route screen or left out of the applicable bandwidth.
fn parsePdnIntent(self: *Evaluator, c: []const Node) ?env_mod.PdnIntent {
    if (c.len < 3) {
        self.warnFmt(c[0].span, "(pdn …) needs a net and (ripple-v V)", .{});
        return null;
    }
    const net = c[1].asString() orelse {
        self.warnFmt(c[1].span, "(pdn …) net must be a string", .{});
        return null;
    };
    var out = env_mod.PdnIntent{ .net = net, .ripple_v = 0 };
    for (c[2..]) |node| {
        const sc = node.asList() orelse continue;
        if (sc.len < 2) continue;
        const name = sc[0].asAtom() orelse continue;
        if (std.mem.eql(u8, name, "ripple-v")) out.ripple_v = sc[1].asNumber() orelse 0 else if (std.mem.eql(u8, name, "step-current-a")) out.step_current_a = sc[1].asNumber() else if (std.mem.eql(u8, name, "rise-time-s")) out.rise_time_s = sc[1].asNumber() else if (std.mem.eql(u8, name, "source-resistance-ohm")) out.source_resistance_ohm = sc[1].asNumber() else if (std.mem.eql(u8, name, "source-inductance-h")) out.source_inductance_h = sc[1].asNumber() else if (std.mem.eql(u8, name, "frequency") and sc.len >= 3) {
            out.f_min_hz = sc[1].asNumber() orelse out.f_min_hz;
            out.f_max_hz = sc[2].asNumber() orelse out.f_max_hz;
        } else self.warnFmt(node.span, "unknown (pdn …) sub-form ({s} …)", .{name});
    }
    if (!(out.ripple_v > 0)) {
        self.warnFmt(c[1].span, "(pdn \"{s}\" …) needs a positive (ripple-v V)", .{net});
        return null;
    }
    if (out.step_current_a != null and !(out.step_current_a.? > 0)) out.step_current_a = null;
    if (out.rise_time_s != null and !(out.rise_time_s.? > 0)) out.rise_time_s = null;
    if (out.source_resistance_ohm != null and out.source_resistance_ohm.? < 0) out.source_resistance_ohm = null;
    if (out.source_inductance_h != null and out.source_inductance_h.? < 0) out.source_inductance_h = null;
    if (!(out.f_min_hz > 0 and out.f_max_hz > out.f_min_hz)) {
        self.warnFmt(c[1].span, "(pdn \"{s}\" …) frequency range must satisfy 0 < min < max", .{net});
        return null;
    }
    return out;
}

/// Parse `(net-envelope "NET" (rated LO HI) ["why"])` — the author's statement
/// of the worst-case DC potential range a net's copper reaches, for the nets no
/// topology walk can derive: a GPIO-driven enable, a divider tap between two
/// declared rails, a bus a 3.3 V transceiver holds.
///
/// The net name is matched the way rail names are — against the FLATTENED,
/// net-tie-canonicalised name — so a board-level `(net-envelope "EN_BUCK3V75" …)`
/// covers the module-local net bridged onto it, and a sub-block-internal node is
/// nameable as `"sub-block/NET"`.
///
/// A malformed form is a warning and no declaration, matching every other
/// declaration parser here: a typo must not silently narrow a proof.
fn parseNetEnvelope(self: *Evaluator, c: []const Node) ?net_envelopes.Declaration {
    if (c.len < 3) {
        self.warnFmt(c[0].span, "(net-envelope …) needs a net and (rated LO HI)", .{});
        return null;
    }
    const net = c[1].asString() orelse {
        self.warnFmt(c[1].span, "(net-envelope …) net must be a string", .{});
        return null;
    };
    var out: ?net_envelopes.Declaration = null;
    var rationale: []const u8 = "";
    for (c[2..]) |node| {
        if (node.asString()) |text| {
            rationale = text;
            continue;
        }
        const sc = node.asList() orelse continue;
        const name = if (sc.len > 0) sc[0].asAtom() orelse "" else "";
        if (std.mem.eql(u8, name, "rated") and sc.len >= 3) {
            const lo = sc[1].asNumber();
            const hi = sc[2].asNumber();
            if (lo == null or hi == null or !(hi.? >= lo.?)) {
                self.warnFmt(node.span, "(net-envelope \"{s}\" (rated LO HI)) needs two numbers with HI >= LO", .{net});
                return null;
            }
            out = .{ .net = net, .min = lo.?, .max = hi.? };
        } else self.warnFmt(node.span, "unknown (net-envelope …) sub-form ({s} …)", .{name});
    }
    if (out) |*decl| {
        decl.rationale = rationale;
        return decl.*;
    }
    self.warnFmt(c[1].span, "(net-envelope \"{s}\" …) needs a (rated LO HI) envelope", .{net});
    return null;
}

/// Parse a top-level `(stackup N …)` custom construction or
/// `(stackup "PRESET" …)` fabricator construction into a `StackupSpec`. N
/// (total copper layers) is required and must be ≥1 for a custom stack; a
/// malformed count leaves the spec absent (warned) so a typo can't silently
/// change the routing model. `(plane …)` entries with a bad index (0 or > N)
/// are skipped with a warning. An optional `(thickness MM)` sets the finished
/// board thickness reported in the Gerber `.gbrjob` (default 1.6 mm).
fn parseStackup(self: *Evaluator, form_children: []const Node) EvalError!env_mod.StackupSpec {
    if (form_children.len < 2) {
        self.warnFmt(form_children[0].span, "(stackup …) needs a copper layer count or preset name", .{});
        return .{};
    }
    var preset_name: []const u8 = "";
    var preset: ?env_mod.StackupSpec = null;
    const layers: u8 = if (form_children[1].asString()) |name| blk: {
        preset = stackup_presets.resolve(self.allocator, name) catch return EvalError.OutOfMemory;
        const resolved = preset orelse {
            self.warnFmt(form_children[1].span, "unknown stackup preset \"{s}\"", .{name});
            return .{};
        };
        preset_name = resolved.preset;
        break :blk resolved.layers;
    } else blk: {
        const n_raw = form_children[1].asNumber() orelse {
            self.warnFmt(form_children[1].span, "(stackup …) first argument must be a layer count or preset string", .{});
            return .{};
        };
        if (n_raw < 1 or n_raw > 32 or n_raw != @floor(n_raw)) {
            self.warnFmt(form_children[1].span, "(stackup …) layer count must be a whole number 1–32", .{});
            return .{};
        }
        break :blk numeric.checkedInt(u8, n_raw) orelse return .{};
    };
    var thickness: f64 = 0;
    var planes: std.ArrayList(env_mod.StackupPlane) = .empty;
    var copper: std.ArrayList(env_mod.StackupCopper) = .empty;
    var dielectrics: std.ArrayList(env_mod.StackupDielectric) = .empty;
    var soldermasks: std.ArrayList(env_mod.StackupSoldermask) = .empty;
    if (preset) |resolved| {
        thickness = resolved.thickness;
        copper.appendSlice(self.allocator, resolved.copper) catch return EvalError.OutOfMemory;
        dielectrics.appendSlice(self.allocator, resolved.dielectrics) catch return EvalError.OutOfMemory;
        soldermasks.appendSlice(self.allocator, resolved.soldermasks) catch return EvalError.OutOfMemory;
    }
    for (form_children[2..]) |child| {
        const c = child.asList() orelse continue;
        if (c.len < 1) continue;
        const head = c[0].asAtom() orelse continue;
        if (std.mem.eql(u8, head, "thickness")) {
            // (thickness MM) — finished board thickness, flowed to .gbrjob.
            if (c.len >= 2) {
                if (c[1].asNumber()) |t| {
                    if (t > 0) thickness = t else self.warnFmt(c[1].span, "(thickness …) must be a positive millimetre value", .{});
                } else self.warnFmt(c[1].span, "(thickness …) must be a number (mm)", .{});
            } else self.warnFmt(c[0].span, "(thickness …) needs a millimetre value, e.g. (thickness 1.6)", .{});
            continue;
        }
        if (std.mem.eql(u8, head, "copper")) {
            if (parseCopperEntry(self, c, layers)) |entry| {
                var duplicate = false;
                for (copper.items) |old| if (old.index == entry.index) {
                    duplicate = true;
                    break;
                };
                if (duplicate) {
                    self.warnFmt(
                        c[1].span,
                        "duplicate physical copper details for layer {d} — first kept",
                        .{entry.index},
                    );
                } else copper.append(self.allocator, entry) catch return EvalError.OutOfMemory;
            }
            continue;
        }
        if (std.mem.eql(u8, head, dielectric_form)) {
            if (parseDielectricEntry(self, c, layers)) |entry| {
                var duplicate = false;
                for (dielectrics.items) |old| if (old.after_layer == entry.after_layer) {
                    duplicate = true;
                    break;
                };
                if (duplicate) {
                    self.warnFmt(
                        c[1].span,
                        "duplicate dielectric details after layer {d} — first kept",
                        .{entry.after_layer},
                    );
                } else dielectrics.append(self.allocator, entry) catch return EvalError.OutOfMemory;
            }
            continue;
        }
        if (std.mem.eql(u8, head, "soldermask")) {
            try appendSoldermaskEntry(self, c, &soldermasks);
            continue;
        }
        const entry = if (std.mem.eql(u8, head, "plane"))
            parsePlaneEntry(self, c, layers)
        else if (std.mem.eql(u8, head, "pour"))
            parsePourEntry(self, c, layers)
        else blk: {
            self.warnFmt(
                c[0].span,
                "unknown (stackup …) sub-form ({s} …) — expected plane, pour, copper, dielectric, soldermask, or thickness",
                .{head},
            );
            break :blk null;
        };
        if (entry) |pl| planes.append(self.allocator, pl) catch return EvalError.OutOfMemory;
    }
    return .{
        .layers = layers,
        .planes = planes.toOwnedSlice(self.allocator) catch &.{},
        .copper = copper.toOwnedSlice(self.allocator) catch &.{},
        .dielectrics = dielectrics.toOwnedSlice(self.allocator) catch &.{},
        .soldermasks = soldermasks.toOwnedSlice(self.allocator) catch &.{},
        .present = true,
        .thickness = thickness,
        .preset = preset_name,
    };
}

fn stackIndex(self: *Evaluator, node: Node, layers: u8, what: []const u8, last: u8) ?u8 {
    const raw = node.asNumber() orelse {
        self.warnFmt(node.span, "({s} …) layer index must be a number", .{what});
        return null;
    };
    if (raw < 1 or raw > @as(f64, @floatFromInt(last)) or raw != @floor(raw)) {
        self.warnFmt(node.span, "({s} …) layer index out of range for this {d}-layer stackup", .{ what, layers });
        return null;
    }
    return numeric.checkedInt(u8, raw);
}

const StackMaterial = struct { thickness: f64 = 0, material: []const u8 = "", er: f64 = 0 };
const dielectric_form = "dielectric";

fn parseStackMaterial(self: *Evaluator, nodes: []const Node, owner: []const u8) StackMaterial {
    var result: StackMaterial = .{};
    for (nodes) |node| {
        const c = node.asList() orelse continue;
        if (c.len == 0) continue;
        const head = c[0].asAtom() orelse continue;
        if (std.mem.eql(u8, head, "thickness")) {
            if (c.len < 2) {
                self.warnFmt(c[0].span, "({s} …) (thickness MM) needs a value", .{owner});
            } else if (c[1].asNumber()) |value| {
                if (value > 0) {
                    result.thickness = value;
                } else self.warnFmt(c[1].span, "({s} …) thickness must be positive", .{owner});
            } else self.warnFmt(c[1].span, "({s} …) thickness must be a number (mm)", .{owner});
        } else if (std.mem.eql(u8, head, "material")) {
            if (c.len < 2) {
                self.warnFmt(c[0].span, "({s} …) (material \"NAME\") needs a name", .{owner});
            } else result.material = c[1].asString() orelse c[1].asAtom() orelse "";
        } else if (std.mem.eql(u8, head, "er")) {
            parseStackEr(self, c, owner, &result.er);
        } else self.warnFmt(
            c[0].span,
            "unknown ({s} …) property ({s} …) — expected material, thickness, or er",
            .{ owner, head },
        );
    }
    return result;
}

/// `(er X)` — relative permittivity. Bounded by the impedance model's own
/// published validity range, so an obviously-mistyped value is rejected at
/// author time rather than producing a plausible-looking width later.
fn parseStackEr(self: *Evaluator, c: []const Node, owner: []const u8, out: *f64) void {
    if (c.len < 2) {
        self.warnFmt(c[0].span, "({s} …) (er X) needs a dielectric constant, e.g. (er 4.4)", .{owner});
        return;
    }
    const value = c[1].asNumber() orelse {
        self.warnFmt(c[1].span, "({s} …) (er X) must be a number", .{owner});
        return;
    };
    if (value < 1.0 or value > 128.0) {
        self.warnFmt(c[1].span, "({s} …) (er {d}) is outside 1-128 — FR-4 is about 4.4", .{ owner, value });
        return;
    }
    out.* = value;
}

fn parseCopperEntry(self: *Evaluator, c: []const Node, layers: u8) ?env_mod.StackupCopper {
    if (c.len < 2) {
        self.warnFmt(c[0].span, "(copper …) needs a layer index and (thickness MM)", .{});
        return null;
    }
    const index = stackIndex(self, c[1], layers, "copper", layers) orelse return null;
    var props: StackMaterial = .{};
    var width_reduction: f64 = 0;
    var narrow_side: @TypeOf((env_mod.StackupCopper{ .index = 1, .thickness = 1 }).narrow_side) = .up;
    for (c[2..]) |node| {
        const p = node.asList() orelse continue;
        if (p.len == 0) continue;
        const head = p[0].asAtom() orelse continue;
        if (std.mem.eql(u8, head, "width-reduction")) {
            if (p.len < 2) {
                self.warnFmt(p[0].span, "(width-reduction MM) needs a value", .{});
            } else if (p[1].asNumber()) |value| {
                if (value >= 0) width_reduction = value else self.warnFmt(p[1].span, "(width-reduction …) cannot be negative", .{});
            } else self.warnFmt(p[1].span, "(width-reduction …) must be a number (mm)", .{});
        } else if (std.mem.eql(u8, head, "narrow-side")) {
            if (p.len < 2) {
                self.warnFmt(p[0].span, "(narrow-side up|down) needs a board-normal side", .{});
            } else if (p[1].asAtom()) |side| {
                if (std.meta.stringToEnum(@TypeOf(narrow_side), side)) |parsed| {
                    narrow_side = parsed;
                } else {
                    self.warnFmt(p[1].span, "(narrow-side …) must be up or down", .{});
                }
            } else self.warnFmt(p[1].span, "(narrow-side …) must be up or down", .{});
        } else {
            const one = [_]Node{node};
            const parsed = parseStackMaterial(self, &one, "copper");
            if (parsed.thickness > 0) props.thickness = parsed.thickness;
            if (parsed.material.len > 0) props.material = parsed.material;
            if (parsed.er > 0) props.er = parsed.er;
        }
    }
    if (!(props.thickness > 0)) {
        self.warnFmt(c[0].span, "(copper …) needs a positive (thickness MM)", .{});
        return null;
    }
    if (props.er > 0) {
        // Copper is a conductor: (er …) belongs on the (dielectric …) either
        // side of it. Accepting it silently would put a number in the file
        // that nothing can ever read.
        self.warnFmt(c[0].span, "(copper …) has no (er …) — declare it on the (dielectric …) instead", .{});
    }
    return .{
        .index = index,
        .thickness = props.thickness,
        .material = if (props.material.len > 0) props.material else "Copper",
        .width_reduction = width_reduction,
        .narrow_side = narrow_side,
    };
}

fn parseSoldermaskEntry(self: *Evaluator, c: []const Node) ?env_mod.StackupSoldermask {
    if (c.len < 2) {
        self.warnFmt(c[0].span, "(soldermask …) needs top|bottom and its process properties", .{});
        return null;
    }
    const side_name = c[1].asAtom() orelse {
        self.warnFmt(c[1].span, "(soldermask …) side must be top or bottom", .{});
        return null;
    };
    const side = std.meta.stringToEnum(env_mod.FabricationSide, side_name) orelse {
        self.warnFmt(c[1].span, "(soldermask …) side must be top or bottom", .{});
        return null;
    };
    var material: []const u8 = "Soldermask";
    var er: f64 = 0;
    var substrate_thickness: f64 = 0;
    var copper_thickness: f64 = 0;
    for (c[2..]) |node| {
        const p = node.asList() orelse continue;
        if (p.len == 0) continue;
        const head = p[0].asAtom() orelse continue;
        if (std.mem.eql(u8, head, "material")) {
            if (p.len >= 2) material = p[1].asString() orelse p[1].asAtom() orelse material;
        } else if (std.mem.eql(u8, head, "er")) {
            parseStackEr(self, p, "soldermask", &er);
        } else if (std.mem.eql(u8, head, "substrate-thickness") or std.mem.eql(u8, head, "copper-thickness")) {
            if (p.len < 2) {
                self.warnFmt(p[0].span, "({s} MM) needs a value", .{head});
            } else if (p[1].asNumber()) |value| {
                if (value > 0) {
                    if (std.mem.eql(u8, head, "substrate-thickness")) substrate_thickness = value else copper_thickness = value;
                } else self.warnFmt(p[1].span, "({s} …) must be positive", .{head});
            } else self.warnFmt(p[1].span, "({s} …) must be a number (mm)", .{head});
        } else self.warnFmt(
            p[0].span,
            "unknown (soldermask …) property ({s} …) — expected material, er, substrate-thickness, or copper-thickness",
            .{head},
        );
    }
    if (!(er > 0 and substrate_thickness > 0 and copper_thickness > 0)) {
        self.warnFmt(c[0].span, "(soldermask …) needs (er X), (substrate-thickness MM), and (copper-thickness MM)", .{});
        return null;
    }
    return .{
        .side = side,
        .material = material,
        .er = er,
        .substrate_thickness = substrate_thickness,
        .copper_thickness = copper_thickness,
    };
}

fn appendSoldermaskEntry(
    self: *Evaluator,
    c: []const Node,
    soldermasks: *std.ArrayList(env_mod.StackupSoldermask),
) EvalError!void {
    const entry = parseSoldermaskEntry(self, c) orelse return;
    for (soldermasks.items) |old| {
        if (old.side != entry.side) continue;
        self.warnFmt(c[1].span, "duplicate soldermask details for {s} face — first kept", .{@tagName(entry.side)});
        return;
    }
    soldermasks.append(self.allocator, entry) catch return EvalError.OutOfMemory;
}

fn parseDielectricEntry(self: *Evaluator, c: []const Node, layers: u8) ?env_mod.StackupDielectric {
    if (c.len < 3) {
        self.warnFmt(
            c[0].span,
            "(dielectric …) needs an after-layer index, core|prepreg, material, and thickness",
            .{},
        );
        return null;
    }
    const last_gap: u8 = if (layers > 0) layers - 1 else 0;
    const index = stackIndex(self, c[1], layers, dielectric_form, last_gap) orelse return null;
    const kind_name = c[2].asAtom() orelse {
        self.warnFmt(c[2].span, "(dielectric …) type must be core or prepreg", .{});
        return null;
    };
    const kind = std.meta.stringToEnum(env_mod.StackupDielectricKind, kind_name) orelse {
        self.warnFmt(c[2].span, "(dielectric …) type must be core or prepreg, got {s}", .{kind_name});
        return null;
    };
    const props = parseStackMaterial(self, c[3..], dielectric_form);
    if (!(props.thickness > 0) or props.material.len == 0) {
        self.warnFmt(c[0].span, "(dielectric …) needs (material \"NAME\") and a positive (thickness MM)", .{});
        return null;
    }
    return .{
        .after_layer = index,
        .kind = kind,
        .material = props.material,
        .thickness = props.thickness,
        .er = props.er,
    };
}

/// Parse one `(plane IDX "NET")` entry of a `(stackup …)` form. Null (with a
/// warning) when the index is malformed / out of range or the net unnamed.
fn parsePlaneEntry(self: *Evaluator, c: []const Node, layers: u8) ?env_mod.StackupPlane {
    if (c.len < 3) {
        self.warnFmt(c[0].span, "(plane …) needs a layer index and a net name", .{});
        return null;
    }
    const idx_raw = c[1].asNumber() orelse {
        self.warnFmt(c[1].span, "(plane …) layer index must be a number", .{});
        return null;
    };
    if (idx_raw < 1 or idx_raw > @as(f64, @floatFromInt(layers)) or idx_raw != @floor(idx_raw)) {
        self.warnFmt(c[1].span, "(plane …) layer index out of range for this stackup", .{});
        return null;
    }
    const net = c[2].asString() orelse c[2].asAtom() orelse {
        self.warnFmt(c[2].span, "(plane …) net must be a name", .{});
        return null;
    };
    return .{ .index = numeric.checkedInt(u8, idx_raw) orelse return null, .net = net };
}

/// Parse one `(pour top|bottom "NET")` entry — sugar for a `(plane …)` on the
/// matching OUTER copper layer (top = 1, bottom = the stackup's layer count),
/// so a 2-layer board can say `(pour bottom "GND")` instead of counting
/// indices. Null (with a warning) on a malformed side/net.
fn parsePourEntry(self: *Evaluator, c: []const Node, layers: u8) ?env_mod.StackupPlane {
    if (c.len < 3) {
        self.warnFmt(c[0].span, "(pour …) needs a side (top|bottom) and a net name", .{});
        return null;
    }
    const side = c[1].asAtom() orelse {
        self.warnFmt(c[1].span, "(pour …) side must be top or bottom", .{});
        return null;
    };
    var index: ?u8 = null;
    if (std.mem.eql(u8, side, "top")) index = 1;
    if (std.mem.eql(u8, side, "bottom")) index = layers;
    const idx = index orelse {
        self.warnFmt(c[1].span, "(pour …) side must be top or bottom, got {s}", .{side});
        return null;
    };
    const net = c[2].asString() orelse c[2].asAtom() orelse {
        self.warnFmt(c[2].span, "(pour …) net must be a name", .{});
        return null;
    };
    return .{ .index = idx, .net = net };
}

/// Parse a `(fence [(pitch MM)] [(layers N)] [(mask-layers N)] [(offset MM)] [(via DIA DRILL)] [(net "N")])`
/// sub-form of a `(net-class …)` into `out`. Presence alone is the opt-in, so a
/// bare `(fence)` is valid and leaves every field at its derive-me sentinel; a
/// non-positive number or an unknown child is warned and dropped.
fn parseClassFence(self: *Evaluator, out: *env_mod.ClassFence, c: []const Node) void {
    out.declared = true;
    for (c[1..]) |child| {
        const f = child.asList() orelse continue;
        if (f.len < 1) continue;
        const head = f[0].asAtom() orelse continue;
        if (std.mem.eql(u8, head, "pitch")) {
            if (f.len >= 2) out.pitch_mm = f[1].asNumber() orelse 0;
            if (out.pitch_mm <= 0)
                self.warnFmt(f[0].span, "(fence (pitch MM)) needs a positive spacing, e.g. (pitch 1.0)", .{});
        } else if (std.mem.eql(u8, head, "layers")) {
            const raw = if (f.len >= 2) f[1].asNumber() orelse 0 else 0;
            const whole = std.math.isFinite(raw) and raw == @floor(raw);
            const in_range = raw >= 1 and raw <= 32;
            if (!whole or !in_range) {
                self.warnFmt(f[0].span, "(fence (layers N)) needs a whole number from 1 to 32, e.g. (layers 2)", .{});
            } else {
                out.rows.generated = numeric.checkedInt(u8, raw) orelse 1;
            }
        } else if (std.mem.eql(u8, head, "mask-layers")) {
            const raw = if (f.len >= 2) f[1].asNumber() orelse 0 else 0;
            const whole = std.math.isFinite(raw) and raw == @floor(raw);
            const in_range = raw >= 1 and raw <= 32;
            if (!whole or !in_range) {
                self.warnFmt(f[0].span, "(fence (mask-layers N)) needs a whole number from 1 to 32, e.g. (mask-layers 1)", .{});
            } else {
                out.rows.mask_open = numeric.checkedInt(u8, raw) orelse 0;
            }
        } else if (std.mem.eql(u8, head, "offset")) {
            if (f.len >= 2) out.offset_mm = f[1].asNumber() orelse 0;
            if (out.offset_mm <= 0)
                self.warnFmt(f[0].span, "(fence (offset MM)) needs a positive distance, e.g. (offset 0.65)", .{});
        } else if (std.mem.eql(u8, head, "via")) {
            if (f.len >= 2) out.via_dia = f[1].asNumber() orelse 0;
            if (f.len >= 3) out.via_drill = f[2].asNumber() orelse 0;
        } else if (std.mem.eql(u8, head, "net")) {
            if (f.len >= 2) out.net = f[1].asString() orelse f[1].asAtom() orelse "";
        } else {
            self.warnFmt(f[0].span, "unknown (fence …) sub-form ({s} …)", .{head});
        }
    }
    if (out.rows.mask_open > out.rows.generated) {
        self.warnFmt(c[0].span, "(fence (mask-layers N)) cannot exceed the generated (layers N); clamping {d} to {d}", .{ out.rows.mask_open, out.rows.generated });
        out.rows.mask_open = out.rows.generated;
    }
}

/// Parse a `(keepout MM [(escape MM)])` sub-form of a `(net-class …)` into
/// `out`. The halo distance is the leading number (not a nested form), so the
/// child scan skips it naturally — only `(escape MM)` is a recognized child.
fn parseClassKeepout(self: *Evaluator, out: *env_mod.ClassRf, c: []const Node) void {
    if (c.len >= 2) out.keepout_mm = c[1].asNumber() orelse 0;
    if (out.keepout_mm <= 0)
        self.warnFmt(c[0].span, "(keepout MM …) needs a positive halo, e.g. (keepout 0.5)", .{});
    for (c[1..]) |child| {
        const f = child.asList() orelse continue; // the leading MM is not a list
        if (f.len < 1) continue;
        const head = f[0].asAtom() orelse continue;
        if (std.mem.eql(u8, head, "escape")) {
            if (f.len >= 2) out.keepout_escape_mm = f[1].asNumber() orelse -1;
            if (out.keepout_escape_mm < 0)
                self.warnFmt(f[0].span, "(keepout … (escape MM)) needs a non-negative radius, e.g. (escape 1.5)", .{});
        } else {
            self.warnFmt(f[0].span, "unknown (keepout …) sub-form ({s} …)", .{head});
        }
    }
}

/// Parse a `(match-group "NAME" [(tolerance MM)])` sub-form of a `(net-class …)`
/// into `spec`. The group NAME is the leading string (not a nested form), so the
/// child scan starts past it — `(tolerance MM)` is the only recognized child. A
/// missing/empty name is warned and leaves the class ungrouped, since a group
/// with no name is a join key nothing else can name.
fn parseClassMatchGroup(self: *Evaluator, out: *env_mod.ClassMatch, c: []const Node) void {
    if (c.len >= 2) out.group = c[1].asString() orelse c[1].asAtom() orelse "";
    if (out.group.len == 0) {
        self.warnFmt(c[0].span, "(match-group \"NAME\" …) needs a group name, e.g. (match-group \"ddr-addr\")", .{});
        return;
    }
    for (c[2..]) |child| {
        const f = child.asList() orelse continue;
        if (f.len < 1) continue;
        const head = f[0].asAtom() orelse continue;
        if (std.mem.eql(u8, head, "tolerance")) {
            if (f.len >= 2) out.tolerance_mm = f[1].asNumber() orelse 0;
            if (out.tolerance_mm <= 0)
                self.warnFmt(f[0].span, "(match-group … (tolerance MM)) needs a positive spread, e.g. (tolerance 0.5)", .{});
        } else {
            self.warnFmt(f[0].span, "unknown (match-group …) sub-form ({s} …)", .{head});
        }
    }
}

/// Parse one RF-discipline sub-form of a `(net-class …)` — `(max-freq HZ)`,
/// `(escape MM)`, `(min-bend-radius N)`, `(fence …)`, `(keepout MM …)` — into
/// `rf`. Returns false when `head` names none of them, so the caller's ladder
/// continues to the geometry fields. Split from `parseNetClassField` so the RF
/// half and the trace-geometry half each stay a readable ladder.
fn parseNetClassRfField(
    self: *Evaluator,
    rf: *env_mod.ClassRf,
    head: []const u8,
    c: []const Node,
) bool {
    if (std.mem.eql(u8, head, "max-freq")) {
        // (max-freq HZ) — opts the class into RF bend discipline (routed
        // corners become arcs with radius >= 3x the trace width).
        if (c.len >= 2) rf.max_freq_hz = c[1].asNumber() orelse 0;
        if (rf.max_freq_hz <= 0)
            self.warnFmt(c[0].span, "(max-freq HZ) needs a positive frequency, e.g. (max-freq 12G)", .{});
    } else if (std.mem.eql(u8, head, "band")) {
        // (band MIN_HZ MAX_HZ) — electrical return-loss evaluation range.
        if (c.len >= 3) {
            rf.electrical.band_start_hz = c[1].asNumber() orelse 0;
            rf.max_freq_hz = c[2].asNumber() orelse 0;
        }
        if (rf.electrical.band_start_hz <= 0 or rf.max_freq_hz <= rf.electrical.band_start_hz)
            self.warnFmt(c[0].span, "(band MIN_HZ MAX_HZ) needs positive increasing frequencies, e.g. (band 100M 6G)", .{});
    } else if (std.mem.eql(u8, head, "return-loss")) {
        // (return-loss DB) — minimum worst-case RL over the declared band.
        if (c.len >= 2) rf.electrical.return_loss_target_db = c[1].asNumber() orelse 0;
        if (rf.electrical.return_loss_target_db <= 0)
            self.warnFmt(c[0].span, "(return-loss DB) needs a positive target, e.g. (return-loss 20)", .{});
    } else if (std.mem.eql(u8, head, "escape")) {
        // (escape MM) — straight pad-escape distance before the first bend.
        // Explicit 0 disables the max-freq default.
        if (c.len >= 2) rf.escape_mm = c[1].asNumber() orelse -1;
        if (rf.escape_mm < 0)
            self.warnFmt(c[0].span, "(escape MM) needs a non-negative distance, e.g. (escape 1.0)", .{});
    } else if (std.mem.eql(u8, head, "min-bend-radius")) {
        // (min-bend-radius N) — bend-radius floor as a multiple of the trace
        // width (floor = N × width), overriding the 3× default on a max-freq
        // class. Must be positive; ≤0 is warned and leaves the default.
        if (c.len >= 2) rf.min_bend_ratio = c[1].asNumber() orelse 0;
        if (rf.min_bend_ratio <= 0)
            self.warnFmt(c[0].span, "(min-bend-radius N) needs a positive width multiple, e.g. (min-bend-radius 5)", .{});
    } else if (std.mem.eql(u8, head, "mask-relief")) {
        // (mask-relief MM) — per-side solder-mask pullback from this class's
        // routed copper (bare-copper trace). Explicit 0 keeps a max-freq
        // class tented; undeclared stays the -1 derive-me sentinel.
        if (c.len >= 2) rf.mask_relief_mm = c[1].asNumber() orelse -1;
        if (rf.mask_relief_mm < 0)
            self.warnFmt(c[0].span, "(mask-relief MM) needs a non-negative pullback, e.g. (mask-relief 0.05)", .{});
    } else if (std.mem.eql(u8, head, "fence")) {
        // (fence …) — opt this class's traces into a flanking row of ground
        // stitching vias, generated on demand (not by the autorouter).
        parseClassFence(self, &rf.fence, c);
    } else if (std.mem.eql(u8, head, "keepout")) {
        // (keepout MM [(escape MM)]) — same-layer halo foreign copper must
        // respect around this class's copper, relaxed near its own pads.
        parseClassKeepout(self, rf, c);
    } else if (std.mem.eql(u8, head, "impedance")) {
        // (impedance OHMS [(layer N)]) — target single-ended Z0. Alone it
        // derives the width; alongside (width …) it is a check.
        parseClassImpedance(self, rf, c, false);
    } else if (std.mem.eql(u8, head, "diff-impedance")) {
        // (diff-impedance OHMS [(layer N)]) — impedance across a diff pair.
        parseClassImpedance(self, rf, c, true);
    } else if (std.mem.eql(u8, head, "ground-gap")) {
        // (ground-gap MM [(max MM)]) — edge-to-edge slot between the trace and
        // same-layer ground copper. A max opts tapered sections into a wider
        // locally synthesized slot while preserving the backing plane.
        parseClassGroundGap(self, rf, c);
    } else {
        return false;
    }
    return true;
}

fn parseClassGroundGap(self: *Evaluator, rf: *env_mod.ClassRf, c: []const Node) void {
    if (c.len >= 2) rf.impedance.ground_gap_mm = c[1].asNumber() orelse 0;
    if (rf.impedance.ground_gap_mm <= 0)
        self.warnFmt(c[0].span, "(ground-gap MM) needs a positive distance, e.g. (ground-gap 0.127)", .{});
    for (c[2..]) |child| {
        const f = child.asList() orelse continue;
        if (f.len < 1) continue;
        const head = f[0].asAtom() orelse continue;
        if (!std.mem.eql(u8, head, "max")) {
            self.warnFmt(f[0].span, "unknown (ground-gap …) sub-form ({s} …)", .{head});
            continue;
        }
        if (f.len >= 2) rf.impedance.ground_gap_max_mm = f[1].asNumber() orelse 0;
        if (rf.impedance.ground_gap_max_mm <= 0)
            self.warnFmt(f[0].span, "(ground-gap … (max MM)) needs a positive upper limit, e.g. (max 1.75)", .{});
        if (rf.impedance.ground_gap_mm > 0 and rf.impedance.ground_gap_max_mm < rf.impedance.ground_gap_mm)
            self.warnFmt(f[0].span, "(ground-gap … (max MM)) cannot be smaller than the base gap", .{});
    }
}

/// `(impedance OHMS)` — the class's target characteristic impedance. Bounded
/// to the span a PCB transmission line can plausibly occupy so a typo (a width
/// in millimetres written here, say) is caught at author time.
fn parseClassImpedance(self: *Evaluator, rf: *env_mod.ClassRf, c: []const Node, differential: bool) void {
    const form_name = if (differential) "diff-impedance" else "impedance";
    if (c.len < 2) {
        self.warnFmt(c[0].span, "({s} OHMS) needs a target", .{form_name});
        return;
    }
    const value = c[1].asNumber() orelse {
        self.warnFmt(c[1].span, "({s} OHMS) must be a number", .{form_name});
        return;
    };
    if (value < 10.0 or value > 300.0) {
        self.warnFmt(c[1].span, "({s} {d}) is outside 10-300 ohms — 50 and 100 are the usual targets", .{ form_name, value });
        return;
    }
    if (differential) {
        rf.impedance.diff_ohms = value;
        rf.impedance.ohms = 0;
    } else {
        rf.impedance.ohms = value;
        rf.impedance.diff_ohms = 0;
    }
    rf.impedance.layer = 0;
    for (c[2..]) |child| {
        const field = child.asList() orelse continue;
        if (field.len != 2) continue;
        const head = field[0].asAtom() orelse continue;
        if (!std.mem.eql(u8, head, "layer")) continue;
        const raw = field[1].asNumber() orelse {
            self.warnFmt(field[1].span, "({s} … (layer N)) needs a 1-based copper-layer number", .{form_name});
            continue;
        };
        if (raw < 1 or raw > 32 or @floor(raw) != raw) {
            self.warnFmt(field[1].span, "({s} … (layer {d})) is outside the supported 1-32 copper-layer range", .{ form_name, raw });
            continue;
        }
        rf.impedance.layer = numeric.checkedInt(u8, raw) orelse 0;
    }
}

/// Parse one `(net-class …)` routing-profile sub-form `(head …)` into `spec`.
/// Returns true when `head` names a known profile field (so the caller marks
/// the class a profile), false for an unrecognized head (the caller warns) or
/// `nets` (the caller handles membership). Split out of `parseNetClass` so
/// neither the loop nor this ladder carries the whole form's complexity; the RF
/// discipline heads live in `parseNetClassRfField`.
fn parseNetClassField(
    self: *Evaluator,
    spec: *env_mod.NetClassSpec,
    head: []const u8,
    c: []const Node,
) bool {
    if (parsePadNeckField(self, &spec.pad_neck, head, c)) {
        return true;
    } else if (std.mem.eql(u8, head, "width")) {
        if (c.len >= 2) spec.width = c[1].asNumber() orelse 0;
    } else if (std.mem.eql(u8, head, "power-branch-width")) {
        if (c.len >= 2) spec.pad_neck.power_branch_width = c[1].asNumber() orelse 0;
        if (spec.pad_neck.power_branch_width <= 0)
            self.warnFmt(c[0].span, "(power-branch-width MM) needs a positive width", .{});
    } else if (std.mem.eql(u8, head, "clearance")) {
        if (c.len >= 2) spec.clearance = c[1].asNumber() orelse 0;
    } else if (std.mem.eql(u8, head, "via")) {
        if (c.len >= 2) spec.via_dia = c[1].asNumber() orelse 0;
        if (c.len >= 3) spec.via_drill = c[2].asNumber() orelse 0;
    } else if (std.mem.eql(u8, head, "priority")) {
        if (c.len >= 2) {
            const n = c[1].asNumber() orelse 0;
            if (n < 0 or n > 7) self.warnFmt(c[1].span, "(net-class …) (priority …) is 0-7; clamping {d}", .{n});
            spec.priority = numeric.checkedInt(u32, std.math.clamp(n, 0, 7)) orelse 0;
        }
    } else if (std.mem.eql(u8, head, "diff-pair")) {
        // (diff-pair) → couple at the class clearance; (diff-pair GAP) → an
        // explicit edge-to-edge gap (mm). Marks the class's nets differential.
        spec.diff_gap = if (c.len >= 2) (c[1].asNumber() orelse 0) else 0;
    } else if (std.mem.eql(u8, head, "resolution")) {
        // (resolution MM) — bounded-window raster pitch for this class's nets.
        if (c.len >= 2) spec.resolution_mm = c[1].asNumber() orelse 0;
        if (spec.resolution_mm <= 0)
            self.warnFmt(c[0].span, "(resolution MM) needs a positive pitch, e.g. (resolution 0.05)", .{});
    } else if (std.mem.eql(u8, head, "match-group")) {
        // (match-group "NAME" [(tolerance MM)]) — join this class's nets to a
        // length-matched set measured (and warned about) after routing.
        parseClassMatchGroup(self, &spec.match, c);
    } else if (std.mem.eql(u8, head, "return-path")) {
        parseClassReturnPath(self, &spec.return_path, c);
    } else {
        return parseNetClassRfField(self, &spec.rf, head, c);
    }
    return true;
}

fn parsePadNeckField(
    self: *Evaluator,
    profile: *env_mod.NetClassSpec.PadNeck,
    head: []const u8,
    c: []const Node,
) bool {
    const target: *f64 = if (std.mem.eql(u8, head, "pad-escape-width"))
        &profile.width
    else if (std.mem.eql(u8, head, "pad-escape-max-length"))
        &profile.max_length
    else if (std.mem.eql(u8, head, "taper-length"))
        &profile.taper_length
    else
        return false;
    if (c.len >= 2) target.* = c[1].asNumber() orelse 0;
    if (target.* <= 0) self.warnFmt(c[0].span, "({s} MM) needs a positive value", .{head});
    return true;
}

/// Parse `(return-path [(reference "NET")] [(stitch-radius MM)]
/// [(max-loop-area MM2)])`. The form is deliberately independent of RF:
/// clocks and switching nodes need return-current discipline too.
fn parseClassReturnPath(self: *Evaluator, out: *env_mod.ClassReturnPath, c: []const Node) void {
    out.declared = true;
    for (c[1..]) |child| {
        const f = child.asList() orelse continue;
        if (f.len < 1) continue;
        const head = f[0].asAtom() orelse continue;
        if (std.mem.eql(u8, head, "reference")) {
            if (f.len >= 2) out.reference_net = f[1].asString() orelse f[1].asAtom() orelse "";
            if (out.reference_net.len == 0)
                self.warnFmt(f[0].span, "(return-path … (reference \"NET\")) needs a net name", .{});
        } else if (std.mem.eql(u8, head, "stitch-radius")) {
            if (f.len >= 2) out.stitch_radius_mm = f[1].asNumber() orelse 0;
            if (out.stitch_radius_mm <= 0)
                self.warnFmt(f[0].span, "(return-path … (stitch-radius MM)) needs a positive radius", .{});
        } else if (std.mem.eql(u8, head, "max-loop-area")) {
            if (f.len >= 2) out.max_loop_area_mm2 = f[1].asNumber() orelse 0;
            if (out.max_loop_area_mm2 <= 0)
                self.warnFmt(f[0].span, "(return-path … (max-loop-area MM2)) needs a positive area", .{});
        } else self.warnFmt(f[0].span, "unknown (return-path …) sub-form ({s} …)", .{head});
    }
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
    var nets: std.ArrayList([]const u8) = .empty;
    var has_profile = false;
    for (form_children[2..]) |child| {
        const c = child.asList() orelse continue;
        if (c.len < 1) continue;
        const head = c[0].asAtom() orelse continue;
        if (std.mem.eql(u8, head, "nets")) {
            for (c[1..]) |net_node| {
                const net = net_node.asString() orelse net_node.asAtom() orelse continue;
                nets.append(self.allocator, net) catch return EvalError.OutOfMemory;
            }
        } else if (parseNetClassField(self, &spec, head, c)) {
            has_profile = true;
        } else {
            self.warnFmt(c[0].span, "unknown (net-class …) sub-form ({s} …)", .{head});
        }
    }
    if (nets.items.len == 0 and !has_profile) {
        self.warnFmt(
            form_children[0].span,
            "(net-class \"{s}\" …) is empty — add routing fields and/or (nets \"A\" …)",
            .{name},
        );
        return null;
    }
    spec.nets = nets.toOwnedSlice(self.allocator) catch &.{};
    return spec;
}

/// Parse a top-level `(design-rules (clearance MM) (min-drill MM)
/// (mask-margin MM) (mask-relief-corner-radius MM) (copper-edge MM)
/// (component-edge MM) (hole-to-hole MM) (via-to-via MM)
/// (min-annular MM) (mask-web MM) (min-width MM) (pour-min-width MM)
/// (pour-corner-radius MM) (ground-via-max MM) (track-width MM)
/// (via-plating MM)
/// (via DIA DRILL))` form into
/// a `DesignRulesSpec`. Every sub-form is optional; an unset field stays 0 so
/// the consumer falls back to its built-in default. `present` is set whenever
/// the form appears (even empty), so a bare `(design-rules)` is a harmless
/// no-op rather than an error. `(track-width …)` and `(via …)` are the
/// board's default routing geometry — they seed the autorouter's
/// `RouteParams` (clearance/track/via).
fn parseDesignRules(self: *Evaluator, form_children: []const Node) env_mod.DesignRulesSpec {
    var spec = env_mod.DesignRulesSpec{ .present = true };
    // Judged after the loop, not inside it: `(pour-clearance …)` is checked
    // against `(clearance …)`, which may be authored on either side of it.
    var pour_span: ?ast.Span = null;
    for (form_children[1..]) |child| {
        const c = child.asList() orelse continue;
        if (c.len < 1) continue;
        const head = c[0].asAtom() orelse continue;
        const val: ?f64 = if (c.len >= 2) c[1].asNumber() else null;
        if (std.mem.eql(u8, head, "clearance")) {
            spec.clearance = val orelse 0;
        } else if (std.mem.eql(u8, head, "min-drill")) {
            spec.min_drill = val orelse 0;
        } else if (std.mem.eql(u8, head, "mask-margin")) {
            spec.mask.margin = val orelse 0;
        } else if (std.mem.eql(u8, head, "mask-relief-corner-radius")) {
            spec.mask.relief_corner_radius = val orelse 0;
        } else if (std.mem.eql(u8, head, "copper-edge")) {
            spec.edge.copper = val orelse 0;
        } else if (std.mem.eql(u8, head, "component-edge")) {
            spec.edge.component = val orelse 0;
        } else if (std.mem.eql(u8, head, "hole-to-hole")) {
            spec.hole_to_hole = val orelse 0;
        } else if (std.mem.eql(u8, head, "via-to-via")) {
            spec.via_to_via = val orelse 0;
        } else if (std.mem.eql(u8, head, "min-annular")) {
            spec.min_annular = val orelse 0;
        } else if (std.mem.eql(u8, head, "mask-web")) {
            spec.mask.web = val orelse 0;
        } else if (std.mem.eql(u8, head, "min-width")) {
            spec.min_width = val orelse 0;
        } else if (std.mem.eql(u8, head, "pour-clearance")) {
            spec.pour_clearance = val orelse 0;
            pour_span = c[0].span;
        } else if (std.mem.eql(u8, head, "pour-min-width")) {
            spec.pour.min_width = val orelse 0;
        } else if (std.mem.eql(u8, head, "pour-corner-radius")) {
            spec.pour.corner_radius = val orelse 0;
        } else if (std.mem.eql(u8, head, "ground-via-max")) {
            spec.pour.ground_via_max = val orelse 0;
        } else if (std.mem.eql(u8, head, "track-width")) {
            spec.track_width = val orelse 0;
        } else if (std.mem.eql(u8, head, "via")) {
            // (via DIA DRILL) — the board-default via geometry (both mm).
            spec.via.dia = val orelse 0;
            if (c.len >= 3) spec.via.drill = c[2].asNumber() orelse 0;
        } else if (std.mem.eql(u8, head, "via-plating")) {
            spec.via.plating = val orelse 0;
        } else {
            self.warnFmt(c[0].span, "unknown (design-rules …) sub-form ({s} …) — expected " ++
                "clearance/min-drill/mask-margin/mask-relief-corner-radius/copper-edge/component-edge/hole-to-hole/via-to-via/min-annular/mask-web/min-width/pour-clearance/pour-min-width/pour-corner-radius/ground-via-max/track-width/via/via-plating", .{head});
        }
    }
    warnTightPourClearance(self, spec, pour_span);
    return spec;
}

/// Warn when an authored pour gap is TIGHTER than the copper clearance the same
/// form resolves to. A pour is etched to a ragged boundary, so a gap below the
/// drawn-copper rule buys no isolation and only trades it for DRC failures. The
/// value is still ACCEPTED as authored — an expert who knows their fab may mean
/// it — so this says so rather than clamping. `span` is null when the form
/// authored no `(pour-clearance …)` at all, which is the silent case.
fn warnTightPourClearance(self: *Evaluator, spec: env_mod.DesignRulesSpec, span: ?ast.Span) void {
    const at = span orelse return;
    if (!(spec.pour_clearance > 0)) return;
    const clearance = if (spec.clearance > 0) spec.clearance else env_mod.default_clearance_mm;
    if (spec.pour_clearance >= clearance) return;
    self.warnFmt(at, "(design-rules (pour-clearance {d})) is below the copper clearance ({d}) — " ++
        "a pour cannot hold a gap the board's own copper rule forbids; accepted as authored", .{ spec.pour_clearance, clearance });
}

/// Filter block-local auto-aliases out of the collected net ties, returning the
/// real cross-block ties for storage. Auto-aliases (symbol pin-function matches)
/// are block-local and would wrongly bridge unrelated nets in the cross-block
/// flatten (`export_kicad_netlist.applyNetTies`), so they're dropped here.
fn collectBlockTies(self: *Evaluator, net_ties: std.ArrayList(NetTie)) EvalError![]const env_mod.NetTie {
    var block_ties: std.ArrayList(env_mod.NetTie) = .empty;
    for (net_ties.items) |nt| {
        if (nt.is_auto) continue;
        try block_ties.append(self.allocator, .{ .a = nt.a, .b = nt.b });
    }
    return block_ties.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory;
}

/// Store the first `(pcb-plan …)` and warn on any later duplicate — zero or one
/// plan per design. Returns `prior` unchanged (with a warning) when a plan is
/// already set, else the newly parsed spec.
fn takeFirstPcbPlan(
    self: *Evaluator,
    form_children: []const Node,
    span: ast.Span,
    prior: ?env_mod.PcbPlanSpec,
) EvalError!?env_mod.PcbPlanSpec {
    if (prior != null) {
        self.warnFmt(span, "duplicate (pcb-plan …) — first kept, this one ignored", .{});
        return prior;
    }
    return try parsePcbPlan(self, form_children);
}

/// The routing-criticality class atoms a `(pcb-plan (route (wave … (classes …))))`
/// selector accepts — the field names of `placement/module_policy.NetClass`,
/// mirrored here so the eval layer need not depend on the placement layer. A
/// `(classes …)` atom outside this set is a typo, warned and dropped.
const plan_route_classes = [_][]const u8{
    "ground", "power",    "input_rail", "switch_node", "clock",
    "rf",     "feedback", "analog",     "control",     "signal",
};

/// Mutable accumulator for one `(wave …)`'s selector member lists while parsing;
/// `finalize` freezes them onto the `PlanWave`. Grouping the lists keeps the
/// per-selector dispatch and the wave parser small.
const PlanWaveLists = struct {
    refs: std.ArrayList([]const u8) = .empty,
    sections: std.ArrayList([]const u8) = .empty,
    sub_blocks: std.ArrayList([]const u8) = .empty,
    classes: std.ArrayList([]const u8) = .empty,
    net_classes: std.ArrayList([]const u8) = .empty,
    nets: std.ArrayList([]const u8) = .empty,
    preferred_layers: std.ArrayList([]const u8) = .empty,
    allowed_layers: std.ArrayList([]const u8) = .empty,
    waypoints: std.ArrayList(env_mod.PlanWaypoint) = .empty,
    repair_waypoints: std.ArrayList(env_mod.PlanWaypoint) = .empty,
    branches: std.ArrayList(env_mod.PlanBranch) = .empty,

    fn finalize(self: *PlanWaveLists, alloc: std.mem.Allocator, wave: *env_mod.PlanWave) void {
        wave.refs = self.refs.toOwnedSlice(alloc) catch &.{};
        wave.sections = self.sections.toOwnedSlice(alloc) catch &.{};
        wave.sub_blocks = self.sub_blocks.toOwnedSlice(alloc) catch &.{};
        wave.classes = self.classes.toOwnedSlice(alloc) catch &.{};
        wave.net_classes = self.net_classes.toOwnedSlice(alloc) catch &.{};
        wave.nets = self.nets.toOwnedSlice(alloc) catch &.{};
        wave.preferred_layers = self.preferred_layers.toOwnedSlice(alloc) catch &.{};
        wave.allowed_layers = self.allowed_layers.toOwnedSlice(alloc) catch &.{};
        wave.corridor.waypoints = self.waypoints.toOwnedSlice(alloc) catch &.{};
        wave.corridor.repair_waypoints = self.repair_waypoints.toOwnedSlice(alloc) catch &.{};
        wave.corridor.branches = self.branches.toOwnedSlice(alloc) catch &.{};
    }
};

/// True when `atom` names a `placement/module_policy.NetClass` field.
fn isPlanRouteClass(atom: []const u8) bool {
    for (plan_route_classes) |c| {
        if (std.mem.eql(u8, atom, c)) return true;
    }
    return false;
}

/// Append every string/atom member of a selector's children into `out` (used by
/// refs/sections/sub-blocks/net-classes/nets — free-form name selectors).
fn collectPlanNames(self: *Evaluator, members: []const Node, out: *std.ArrayList([]const u8)) EvalError!void {
    for (members) |m| {
        const name = m.asString() orelse m.asAtom() orelse continue;
        out.append(self.allocator, name) catch return EvalError.OutOfMemory;
    }
}

/// Append the valid `(classes …)` atoms into `out`; an atom that isn't a
/// module-policy NetClass name is warned and dropped, the rest kept.
fn collectPlanClasses(self: *Evaluator, members: []const Node, out: *std.ArrayList([]const u8)) EvalError!void {
    for (members) |m| {
        const atom = m.asAtom() orelse m.asString() orelse continue;
        if (!isPlanRouteClass(atom)) {
            self.warnFmt(m.span, "unknown (classes …) atom '{s}' in (pcb-plan …) — " ++
                "expected a module-policy net-class name", .{atom});
            continue;
        }
        out.append(self.allocator, atom) catch return EvalError.OutOfMemory;
    }
}

fn collectPlanWaypoints(
    self: *Evaluator,
    members: []const Node,
    out: *std.ArrayList(env_mod.PlanWaypoint),
) EvalError!void {
    for (members) |member| {
        const item = member.asList() orelse {
            self.warnFmt(member.span, "waypoint must be (at X Y \"layer\") — skipped", .{});
            continue;
        };
        const valid_head = item.len > 0 and item[0].asAtom() != null and
            std.mem.eql(u8, item[0].asAtom().?, "at");
        if (!valid_head or item.len != 4) {
            self.warnFmt(member.span, "waypoint must be (at X Y \"layer\") — skipped", .{});
            continue;
        }
        const x = item[1].asNumber() orelse continue;
        const y = item[2].asNumber() orelse continue;
        const layer = item[3].asString() orelse item[3].asAtom() orelse continue;
        out.append(self.allocator, .{ .x = x, .y = y, .layer = layer }) catch return EvalError.OutOfMemory;
    }
}

/// Parse `(branches (branch (at X Y "layer")…)…)` — one hard corridor per limb
/// of a route wave's guide tree. A member that is not a `(branch …)` list, and
/// a `(branch)` that carries no usable `(at …)` point, are warned and skipped;
/// the wave survives with the branches that did parse, because a tree that
/// cannot be matched to a net's terminals is refused whole at route time
/// rather than half-applied.
fn collectPlanBranches(
    self: *Evaluator,
    members: []const Node,
    out: *std.ArrayList(env_mod.PlanBranch),
) EvalError!void {
    for (members) |member| {
        const item = member.asList() orelse {
            self.warnFmt(member.span, "branch must be (branch (at X Y \"layer\")…) — skipped", .{});
            continue;
        };
        const head = if (item.len > 0) item[0].asAtom() else null;
        if (head == null or !std.mem.eql(u8, head.?, "branch")) {
            self.warnFmt(member.span, "branch must be (branch (at X Y \"layer\")…) — skipped", .{});
            continue;
        }
        var points: std.ArrayList(env_mod.PlanWaypoint) = .empty;
        try collectPlanWaypoints(self, item[1..], &points);
        if (points.items.len == 0) {
            self.warnFmt(member.span, "(branch …) needs at least one (at X Y \"layer\") point — skipped", .{});
            continue;
        }
        const owned = points.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory;
        out.append(self.allocator, .{ .waypoints = owned }) catch return EvalError.OutOfMemory;
    }
}

fn collectPlanGuides(
    self: *Evaluator,
    members: []const Node,
    out: *std.ArrayList(env_mod.PlanWaypoint),
) EvalError!void {
    for (members) |member| {
        const item = member.asList() orelse {
            self.warnFmt(member.span, "guide must be (escape-from …), (between-pins …), or (beside …) — skipped", .{});
            continue;
        };
        const head = if (item.len > 0) item[0].asAtom() else null;
        if (head == null) {
            self.warnFmt(member.span, "guide must be (escape-from …), (between-pins …), or (beside …) — skipped", .{});
            continue;
        }
        if (std.mem.eql(u8, head.?, "escape-from") and item.len == 4) {
            const ref = item[1].asString() orelse item[1].asAtom() orelse continue;
            const pin = item[2].asString() orelse item[2].asAtom() orelse continue;
            const layer = item[3].asString() orelse item[3].asAtom() orelse continue;
            out.append(self.allocator, .{ .guide = .{ .escape_from = .{
                .ref = ref,
                .pin = pin,
                .layer = layer,
            } } }) catch return EvalError.OutOfMemory;
            continue;
        }
        if (std.mem.eql(u8, head.?, "between-pins") and item.len == 6) {
            const from_ref = item[1].asString() orelse item[1].asAtom() orelse continue;
            const from_pin = item[2].asString() orelse item[2].asAtom() orelse continue;
            const to_ref = item[3].asString() orelse item[3].asAtom() orelse continue;
            const to_pin = item[4].asString() orelse item[4].asAtom() orelse continue;
            const layer = item[5].asString() orelse item[5].asAtom() orelse continue;
            out.append(self.allocator, .{ .guide = .{ .between_pins = .{
                .from_ref = from_ref,
                .from_pin = from_pin,
                .to_ref = to_ref,
                .to_pin = to_pin,
                .layer = layer,
            } } }) catch return EvalError.OutOfMemory;
            continue;
        }
        if (std.mem.eql(u8, head.?, "beside") and item.len == 4) {
            const ref = item[1].asString() orelse item[1].asAtom() orelse continue;
            const side_name = item[2].asString() orelse item[2].asAtom() orelse continue;
            const side = std.meta.stringToEnum(env_mod.PlanGuideSide, side_name) orelse {
                self.warnFmt(item[2].span, "(beside REF SIDE LAYER) side must be north, south, east, or west — skipped", .{});
                continue;
            };
            const layer = item[3].asString() orelse item[3].asAtom() orelse continue;
            out.append(self.allocator, .{ .guide = .{ .beside = .{
                .ref = ref,
                .side = side,
                .layer = layer,
            } } }) catch return EvalError.OutOfMemory;
            continue;
        }
        self.warnFmt(member.span, "guide must be (escape-from REF PIN LAYER), (between-pins REF PIN REF PIN LAYER), or (beside REF SIDE LAYER) — skipped", .{});
    }
}

/// Parse `(assign-escapes ["LAYER"] ["HUBREF"] [(reserve)])` — the wave-level
/// opt-in that hands this wave's nets to the joint escape assigner instead of
/// letting them contend for the same corridor one at a time. Both positional
/// strings are optional overrides (layer, then hub ref); a bare `(reserve)`
/// sub-form makes the assigned lanes hard reservations as well as soft guides.
/// Extra members are warned and ignored, and the form still applies with its
/// defaults.
fn parseAssignEscapes(self: *Evaluator, selector: []const Node) env_mod.PlanEscapeSpec {
    var spec = env_mod.PlanEscapeSpec{};
    var names: usize = 0;
    for (selector[1..]) |member| {
        if (member.asList()) |sub| {
            if (sub.len > 0 and std.mem.eql(u8, sub[0].asAtom() orelse "", "reserve")) {
                spec.reserve = true;
                continue;
            }
        } else {
            const name = member.asString() orelse member.asAtom() orelse "";
            if (names == 0) spec.layer = name else if (names == 1) spec.hub = name;
            names += 1;
            if (names <= 2) continue;
        }
        self.warnFmt(selector[0].span, "(assign-escapes [\"LAYER\"] [\"HUBREF\"] [(reserve)]) takes at most two names — extras ignored", .{});
    }
    return spec;
}

fn setPlanMaxVias(self: *Evaluator, selector: []const Node, wave: *env_mod.PlanWave) void {
    const value = if (selector.len == 2) selector[1].asNumber() else null;
    const valid = value != null and std.math.isFinite(value.?) and value.? >= 0 and
        value.? <= std.math.maxInt(u16) and @floor(value.?) == value.?;
    if (!valid) {
        self.warnFmt(selector[0].span, "(max-vias N) requires one integer from 0 to 65535 — skipped", .{});
        return;
    }
    wave.max_vias = @intFromFloat(value.?);
}

/// The member list a selector `head` targets, or null when the head isn't a
/// valid selector for this wave's section (place: refs/sections/sub-blocks;
/// route: classes/net-classes/nets). The vocabulary split is what rejects a
/// route selector in a place wave (and vice versa).
fn planSelectorList(head: []const u8, is_route: bool, lists: *PlanWaveLists) ?*std.ArrayList([]const u8) {
    if (is_route) {
        if (std.mem.eql(u8, head, "classes")) return &lists.classes;
        if (std.mem.eql(u8, head, "net-classes")) return &lists.net_classes;
        if (std.mem.eql(u8, head, "nets")) return &lists.nets;
        const preferred = std.mem.eql(u8, head, "preferred-layers") or std.mem.eql(u8, head, "prefer-layers");
        if (preferred) return &lists.preferred_layers;
        const allowed = std.mem.eql(u8, head, "allowed-layers") or std.mem.eql(u8, head, "allow-layers");
        if (allowed) return &lists.allowed_layers;
        return null;
    }
    if (std.mem.eql(u8, head, "refs")) return &lists.refs;
    if (std.mem.eql(u8, head, "sections")) return &lists.sections;
    if (std.mem.eql(u8, head, "sub-blocks")) return &lists.sub_blocks;
    return null;
}

/// Route one selector form inside a `(wave …)` to its member list (or the
/// wave's `reason` / `rest` flag), enforcing the place/route vocabulary split.
/// `rest_seen` is the per-section duplicate-`(rest)` guard.
fn applyPlanSelector(
    self: *Evaluator,
    sel: Node,
    is_route: bool,
    rest_seen: *bool,
    wave: *env_mod.PlanWave,
    lists: *PlanWaveLists,
) EvalError!void {
    const sc = sel.asList() orelse return;
    if (sc.len == 0) return;
    const head = sc[0].asAtom() orelse return;
    if (std.mem.eql(u8, head, "reason")) {
        if (sc.len >= 2) wave.reason = sc[1].asString() orelse sc[1].asAtom();
        return;
    }
    if (std.mem.eql(u8, head, "rest")) {
        if (rest_seen.*) {
            self.warnFmt(sc[0].span, "duplicate (rest) in this (pcb-plan …) section — first kept, ignored", .{});
            return;
        }
        rest_seen.* = true;
        wave.rest = true;
        return;
    }
    if (is_route and std.mem.eql(u8, head, "waypoints")) {
        try collectPlanWaypoints(self, sc[1..], &lists.waypoints);
        return;
    }
    if (is_route and std.mem.eql(u8, head, "repair-waypoints")) {
        try collectPlanWaypoints(self, sc[1..], &lists.repair_waypoints);
        return;
    }
    if (is_route and std.mem.eql(u8, head, "branches")) {
        try collectPlanBranches(self, sc[1..], &lists.branches);
        return;
    }
    if (is_route and std.mem.eql(u8, head, "guides")) {
        try collectPlanGuides(self, sc[1..], &lists.waypoints);
        return;
    }
    if (is_route and std.mem.eql(u8, head, "max-vias")) {
        setPlanMaxVias(self, sc, wave);
        return;
    }
    if (is_route and std.mem.eql(u8, head, "assign-escapes")) {
        wave.corridor.assign_escapes = parseAssignEscapes(self, sc);
        return;
    }
    if (is_route and std.mem.eql(u8, head, "topology")) {
        wave.corridor.topology = true;
        return;
    }
    if (is_route and std.mem.eql(u8, head, "seed-first")) {
        wave.corridor.seed_first = true;
        return;
    }
    const dest = planSelectorList(head, is_route, lists) orelse {
        self.warnFmt(sc[0].span, "({s} …) is not a valid {s}-wave selector in (pcb-plan …) — skipped", .{
            head, if (is_route) "route" else "place",
        });
        return;
    };
    if (std.mem.eql(u8, head, "classes")) {
        try collectPlanClasses(self, sc[1..], dest);
    } else {
        try collectPlanNames(self, sc[1..], dest);
    }
}

/// Parse one `(wave "name" selector…)` entry into a `PlanWave`, or null when the
/// wave is malformed enough to drop: a non-`(wave …)` head, or no leading name
/// string. `is_route` selects the selector vocabulary. Cross-section selectors,
/// unknown selector heads, and a duplicate `(rest)` are warned and skipped
/// while the wave survives.
fn parsePlanWave(self: *Evaluator, wave_node: Node, is_route: bool, rest_seen: *bool) EvalError!?env_mod.PlanWave {
    const wc = wave_node.asList() orelse return null;
    if (wc.len == 0) return null;
    const head = wc[0].asAtom() orelse return null;
    if (!std.mem.eql(u8, head, "wave")) {
        self.warnFmt(wc[0].span, "unknown (pcb-plan …) entry ({s} …) — expected (wave \"name\" …)", .{head});
        return null;
    }
    const name = if (wc.len >= 2) wc[1].asString() else null;
    if (name == null) {
        self.warnFmt(wave_node.span, "(wave …) must start with a name string — skipped", .{});
        return null;
    }
    var wave = env_mod.PlanWave{ .name = name.? };
    var lists = PlanWaveLists{};
    for (wc[2..]) |sel| try applyPlanSelector(self, sel, is_route, rest_seen, &wave, &lists);
    lists.finalize(self.allocator, &wave);
    return wave;
}

/// Parse a top-level `(pcb-plan (place (wave …)…) (route (wave …)…))` form into
/// a `PcbPlanSpec`. `(place …)`/`(route …)` sections collect their waves in
/// authored order; a `(rest)` catch-all is tracked per section so a duplicate is
/// warned. A bare `(topology)` sets the plan-level flag; any other unknown
/// top-level sub-form (not place/route) is warned. Malformed waves are warned
/// and skipped, never a hard error.
/// Recognise `(effort one-shot|standard)` inside `(route …)`, returning null
/// when `node` is not an effort form at all (so the caller parses it as a wave).
/// An effort under `(place …)` or an unknown word is a lint warning, never a
/// hard error — the same forgiving posture the rest of the plan parser takes.
fn parsePlanEffort(self: *Evaluator, node: Node, is_route: bool) EvalError!?env_mod.PlanEffort {
    const c = node.asList() orelse return null;
    if (c.len == 0) return null;
    const head = c[0].asAtom() orelse return null;
    if (!std.mem.eql(u8, head, "effort")) return null;
    if (!is_route) {
        self.warnFmt(c[0].span, "(effort …) applies to (route …), not (place …)", .{});
        return null;
    }
    const word = if (c.len > 1) c[1].asAtom() orelse "" else "";
    if (std.mem.eql(u8, word, "one-shot")) return .one_shot;
    if (std.mem.eql(u8, word, "standard")) return .standard;
    self.warnFmt(c[0].span, "unknown (effort {s}) — expected one-shot|standard", .{word});
    return null;
}

const PlanRouteSecondsArg = union(enum) {
    not_form,
    invalid,
    value: u32,
};

/// Recognise the route-section wall-clock budget. Invalid or misplaced forms
/// are consumed after warning so they cannot also fall through as malformed
/// waves; a missing form is the only `not_form` result.
fn parsePlanRouteSeconds(self: *Evaluator, node: Node, is_route: bool) PlanRouteSecondsArg {
    const c = node.asList() orelse return .not_form;
    if (c.len == 0) return .not_form;
    const head = c[0].asAtom() orelse return .not_form;
    if (!std.mem.eql(u8, head, "max-route-seconds")) return .not_form;
    if (!is_route) {
        self.warnFmt(c[0].span, "(max-route-seconds …) applies to (route …), not (place …)", .{});
        return .invalid;
    }
    const seconds = if (c.len == 2) c[1].asNumber() else null;
    const valid = seconds != null and std.math.isFinite(seconds.?) and seconds.? >= 1 and
        seconds.? <= 86_400 and @floor(seconds.?) == seconds.?;
    if (!valid) {
        self.warnFmt(c[0].span, "(max-route-seconds N) requires one integer from 1 to 86400 — skipped", .{});
        return .invalid;
    }
    return .{ .value = @intCast(numeric.toCount(seconds.?)) };
}

fn parsePcbPlan(self: *Evaluator, form_children: []const Node) EvalError!env_mod.PcbPlanSpec {
    var place: std.ArrayList(env_mod.PlanWave) = .empty;
    var route: std.ArrayList(env_mod.PlanWave) = .empty;
    var place_rest = false;
    var route_rest = false;
    var effort: ?env_mod.PlanEffort = null;
    var max_route_seconds: ?u32 = null;
    var topology = false;
    for (form_children[1..]) |child| {
        const c = child.asList() orelse continue;
        if (c.len == 0) continue;
        const head = c[0].asAtom() orelse continue;
        // Plan-level `(topology)`: the same opt-in every route wave can author
        // for itself, applied to all of them at once (see `resolveAuthored`).
        if (std.mem.eql(u8, head, "topology")) {
            topology = true;
            continue;
        }
        const is_route = std.mem.eql(u8, head, "route");
        if (!is_route and !std.mem.eql(u8, head, "place")) {
            self.warnFmt(c[0].span, "unknown (pcb-plan …) sub-form ({s} …) — expected place|route", .{head});
            continue;
        }
        const dest = if (is_route) &route else &place;
        const rest_seen = if (is_route) &route_rest else &place_rest;
        for (c[1..]) |wave_node| {
            switch (parsePlanRouteSeconds(self, wave_node, is_route)) {
                .not_form => {},
                .invalid => continue,
                .value => |seconds| {
                    max_route_seconds = seconds;
                    continue;
                },
            }
            if (try parsePlanEffort(self, wave_node, is_route)) |e| {
                effort = e;
                continue;
            }
            if (try parsePlanWave(self, wave_node, is_route, rest_seen)) |w|
                dest.append(self.allocator, w) catch return EvalError.OutOfMemory;
        }
    }
    return .{
        .place = place.toOwnedSlice(self.allocator) catch &.{},
        .route = route.toOwnedSlice(self.allocator) catch &.{},
        .effort = effort,
        .max_route_seconds = max_route_seconds,
        .topology = topology,
    };
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

// spec: eval/design_block - fabrication backing parses an explicit face, editable regions, thickness metadata, and side-scoped footprint cutouts
test "design-block parses side-aware fabrication backing geometry" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (fabrication-layer "psb_tesa8854.gbr"
        \\    (kind adhesive)
        \\    (side bottom)
        \\    (material "tesa8854")
        \\    (thickness 0.10)
        \\    (region board)
        \\    (region (polygon (xy 1 2) (xy 4 2) (xy 4 6) (xy 1 6)))
        \\    (exclude-footprints same-side "U1" "U2" (clearance 0.2))))
    ;
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;
    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var scope = env_mod.Env.init(a, null);
    defer scope.deinit();
    const block = (try evalDesignBlock(&eval, form_children[1..], &scope)).design_block;
    try testing.expectEqual(@as(usize, 1), block.fabrication_layers.len);
    const layer = block.fabrication_layers[0];
    try testing.expectEqualStrings("psb_tesa8854.gbr", layer.name);
    try testing.expectEqual(env_mod.FabricationSide.bottom, layer.side);
    try testing.expectEqualStrings("tesa8854", layer.material);
    try testing.expectApproxEqAbs(@as(f64, 0.10), layer.thickness, 1e-9);
    try testing.expectEqual(@as(usize, 2), layer.regions.len);
    try testing.expect(layer.regions[0] == .board);
    try testing.expectEqual(@as(usize, 4), layer.regions[1].polygon.len);
    try testing.expect(layer.exclude_footprints.enabled);
    try testing.expect(!layer.exclude_footprints.all_sides);
    try testing.expectEqual(@as(usize, 2), layer.exclude_footprints.refs.len);
    try testing.expectApproxEqAbs(@as(f64, 0.2), layer.exclude_footprints.clearance, 1e-9);
}

// spec: placement/route-effort - (effort ...) under (place ...) or with an unknown word warns and leaves the default in place
test "route effort parses one-shot and refuses misplaced or unknown words" {
    const a = std.heap.page_allocator;
    // Authored on (route …): taken.
    try testing.expectEqual(
        env_mod.PlanEffort.one_shot,
        (try planFor(a,
            \\(design-block "t" (pcb-plan (route (effort one-shot) (wave "rest" (rest)))))
        )).effort.?,
    );
    // Authored on (place …): wrong scope, so the default survives.
    try testing.expect((try planFor(a,
        \\(design-block "t" (pcb-plan (place (effort one-shot)) (route (wave "rest" (rest)))))
    )).effort == null);
    // Unknown word: warned, default survives.
    try testing.expect((try planFor(a,
        \\(design-block "t" (pcb-plan (route (effort turbo) (wave "rest" (rest)))))
    )).effort == null);
}

// spec: placement/route-deadline - max-route-seconds parses only in the route section and rejects non-positive or fractional budgets
test "route wall time budget parses only a positive whole second value" {
    const a = std.heap.page_allocator;
    try testing.expectEqual(@as(u32, 300), (try planFor(a,
        \\(design-block "t" (pcb-plan (route (max-route-seconds 300) (wave "rest" (rest)))))
    )).max_route_seconds.?);
    try testing.expect((try planFor(a,
        \\(design-block "t" (pcb-plan (place (max-route-seconds 300)) (route (wave "rest" (rest)))))
    )).max_route_seconds == null);
    try testing.expect((try planFor(a,
        \\(design-block "t" (pcb-plan (route (max-route-seconds 0) (wave "rest" (rest)))))
    )).max_route_seconds == null);
    try testing.expect((try planFor(a,
        \\(design-block "t" (pcb-plan (route (max-route-seconds 1.5) (wave "rest" (rest)))))
    )).max_route_seconds == null);
}

/// Evaluate a one-line design source and hand back its parsed `(pcb-plan …)`.
fn planFor(a: std.mem.Allocator, src: []const u8) !env_mod.PcbPlanSpec {
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;
    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();
    const value = try evalDesignBlock(&eval, form_children[1..], &env);
    return value.design_block.pcb_plan orelse .{};
}

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

// spec: eval/design_block - a frequency-plan declaration is collected during the block body and evaluated after it, publishing its typed report on the evaluator beside the loop-filter ones
test "design-block collects and evaluates (frequency-plan …)" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (frequency-plan "Band 1"
        \\    (mode advisory)
        \\    (output-band 50M 1500M)
        \\    (source (range 10G 20G) (delivered 10.5G 12.9G))
        \\    (lo 10.95G (drive 21) (drive-window 17 23))
        \\    (mixer difference (sideband high))
        \\    (if-filter (low-pass 6G))))
    ;
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;
    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();
    _ = try evalDesignBlock(&eval, form_children[1..], &env);

    try testing.expectEqual(@as(usize, 1), eval.frequency_plan_reports.items.len);
    const report = eval.frequency_plan_reports.items[0];
    try testing.expectEqualStrings("Band 1", report.name);
    try testing.expectEqual(frequency_plan.Mode.advisory, report.mode);
    try testing.expectEqual(@as(usize, 1), report.plans.len);
    // Every verdict message is one of the assertions the same evaluation
    // appended — the parity a document renderer relies on.
    try testing.expect(eval.assertions.items.len >= report.plans[0].verdicts.len);
    for (report.plans[0].verdicts) |verdict| {
        var found = false;
        for (eval.assertions.items) |assertion| {
            if (assertion.message.ptr == verdict.message.ptr) found = true;
        }
        try testing.expect(found);
    }
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

// spec: eval/design_block - stackup process entries capture stepped soldermask and per-layer trapezoidal etch geometry
test "stackup captures soldermask and copper etch profile" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (stackup 2
        \\    (copper 1 (thickness 0.035) (width-reduction 0.01778) (narrow-side up))
        \\    (dielectric 1 core (material "FR4") (thickness 1.5) (er 4.4))
        \\    (copper 2 (thickness 0.035) (width-reduction 0.01778) (narrow-side down))
        \\    (soldermask top (material "JLC green") (er 3.8)
        \\      (substrate-thickness 0.03048) (copper-thickness 0.01524))))
    ;
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;
    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var scope = env_mod.Env.init(a, null);
    defer scope.deinit();
    const block = (try evalDesignBlock(&eval, form_children[1..], &scope)).design_block;
    try testing.expectEqual(@as(usize, 2), block.stackup.copper.len);
    try testing.expectApproxEqAbs(@as(f64, 0.01778), block.stackup.copper[0].width_reduction, 1e-12);
    try testing.expectEqual(.up, block.stackup.copper[0].narrow_side);
    try testing.expectEqual(.down, block.stackup.copper[1].narrow_side);
    try testing.expectEqual(@as(usize, 1), block.stackup.soldermasks.len);
    const mask = block.stackup.soldermasks[0];
    try testing.expectEqual(env_mod.FabricationSide.top, mask.side);
    try testing.expectApproxEqAbs(@as(f64, 3.8), mask.er, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.03048), mask.substrate_thickness, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.01524), mask.copper_thickness, 1e-12);
}

// spec: eval/design_block - net-envelope form publishes an authored voltage envelope on the design block
test "design-block captures (net-envelope …)" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (instance "R1" fakeres (pin 1 "EN_BUCK") (pin 2 "GND"))
        \\  (net-envelope "EN_BUCK" (rated 0.0 3.3) "driven by a 3.3 V GPIO")
        \\  (net-envelope "EN_BUCK" (rated 3.3)))
    ;
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;
    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    try eval.component_cache.put(a, "fakeres", .{
        .name = "fakeres",
        .symbol_name = "",
        .footprint_name = "",
        .is_family = false,
        .param_type = "",
    });
    var scope = env_mod.Env.init(a, null);
    defer scope.deinit();
    const block = (try evalDesignBlock(&eval, form_children[1..], &scope)).design_block;
    // The second form is malformed — a warning and no declaration, so exactly
    // one envelope reaches the block and the typo cannot narrow a proof.
    try testing.expectEqual(@as(usize, 1), block.net_envelopes.len);
    try testing.expectEqualStrings("EN_BUCK", block.net_envelopes[0].net);
    try testing.expectEqual(@as(f64, 3.3), block.net_envelopes[0].max);
    try testing.expectEqual(env_mod.NetEnvelope.Origin.declared, block.net_envelopes[0].origin);
    try testing.expectEqualStrings("driven by a 3.3 V GPIO", block.net_envelopes[0].rationale);
}

// spec: eval/design_block - pdn form captures an explicit AC-domain target and source model
test "design-block captures PDN transient intent" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (pdn "VDD" (ripple-v 0.033) (step-current-a 0.45)
        \\    (rise-time-s 2n) (source-resistance-ohm 0.02)
        \\    (source-inductance-h 800p) (frequency 1k 500M)))
    ;
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;
    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var scope = env_mod.Env.init(a, null);
    defer scope.deinit();
    const value = try evalDesignBlock(&eval, form_children[1..], &scope);
    const block = value.design_block;
    try testing.expectEqual(@as(usize, 1), block.pdn_intents.len);
    const intent = block.pdn_intents[0];
    try testing.expectEqualStrings("VDD", intent.net);
    try testing.expectApproxEqAbs(@as(f64, 0.033), intent.ripple_v, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.45), intent.step_current_a.?, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 5e8), intent.f_max_hz, 1e-3);
}

// spec: eval/design_block - stackup captures per-layer copper foil and core/prepreg construction details
test "design-block captures detailed physical stackup construction" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (stackup 4
        \\    (copper 1 (thickness 0.035))
        \\    (dielectric 1 prepreg (material "7628*1") (thickness 0.2104))
        \\    (copper 2 (material "Copper foil") (thickness 0.0152))
        \\    (dielectric 2 core (material "1.1mm H/H oz with copper") (thickness 1.065))
        \\    (copper 3 (thickness 0.0152))
        \\    (dielectric 3 prepreg (material "7628*1") (thickness 0.2104))
        \\    (copper 4 (thickness 0.035))
        \\    (thickness 1.6)))
    ;
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;
    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();
    const block = (try evalDesignBlock(&eval, form_children[1..], &env)).design_block;
    try testing.expectEqual(@as(usize, 4), block.stackup.copper.len);
    try testing.expectEqual(@as(usize, 3), block.stackup.dielectrics.len);
    try testing.expectEqual(@as(u8, 2), block.stackup.copper[1].index);
    try testing.expectApproxEqAbs(@as(f64, 0.0152), block.stackup.copper[1].thickness, 1e-9);
    try testing.expectEqualStrings("Copper foil", block.stackup.copper[1].material);
    try testing.expectEqual(env_mod.StackupDielectricKind.core, block.stackup.dielectrics[1].kind);
    try testing.expectEqualStrings("1.1mm H/H oz with copper", block.stackup.dielectrics[1].material);
    try testing.expectApproxEqAbs(@as(f64, 1.5862), block.stackup.constructionThickness(), 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.6), block.stackup.thickness, 1e-9);
}

// spec: eval/design_block - a named fabricator stackup expands to physical construction while board plane and pour roles remain authored locally
test "design-block resolves a stackup preset with board electrical roles" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (stackup "JLC04161H-7628"
        \\    (plane 2 "GND")
        \\    (plane 3 "GND")
        \\    (pour top "GND")))
    ;
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;
    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var scope = env_mod.Env.init(a, null);
    defer scope.deinit();
    const block = (try evalDesignBlock(&eval, form_children[1..], &scope)).design_block;
    try testing.expectEqualStrings("JLC04161H-7628", block.stackup.preset);
    try testing.expectEqual(@as(u8, 4), block.stackup.layers);
    try testing.expectEqual(@as(usize, 4), block.stackup.copper.len);
    try testing.expectEqual(@as(usize, 3), block.stackup.dielectrics.len);
    try testing.expectEqual(@as(usize, 3), block.stackup.planes.len);
    try testing.expectApproxEqAbs(@as(f64, 1.6), block.stackup.thickness, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.04064), block.stackup.copper[0].thickness, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 0.01524), block.stackup.copper[1].thickness, 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 4.4), block.stackup.dielectrics[0].er, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 4.43), block.stackup.dielectrics[1].er, 1e-9);
}

// spec: eval/design_block - a stackup dielectric captures its (er X) permittivity and defaults it when absent
test "design-block captures (dielectric … (er X))" {
    const a = std.heap.page_allocator;
    // Barracuda's real stackup, with (er …) added to two of its three gaps —
    // the third is left bare to prove an undeclared interval stays 0 (the
    // sentinel the impedance model reads as "use generic FR-4").
    const src =
        \\(design-block "test"
        \\  (stackup 4
        \\    (copper 1 (thickness 0.035))
        \\    (dielectric 1 prepreg (material "7628*1") (thickness 0.2104) (er 4.35))
        \\    (copper 2 (thickness 0.0152))
        \\    (dielectric 2 core (material "1.1mm H/H oz with copper") (thickness 1.065) (er 4.5))
        \\    (copper 3 (thickness 0.0152))
        \\    (dielectric 3 prepreg (material "7628*1") (thickness 0.2104))
        \\    (copper 4 (thickness 0.035))
        \\    (plane 2 "GND")
        \\    (thickness 1.6)))
    ;
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;
    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();
    const block = (try evalDesignBlock(&eval, form_children[1..], &env)).design_block;
    try testing.expectEqual(@as(usize, 3), block.stackup.dielectrics.len);
    try testing.expectApproxEqAbs(@as(f64, 4.35), block.stackup.dielectrics[0].er, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 4.5), block.stackup.dielectrics[1].er, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), block.stackup.dielectrics[2].er, 1e-9);
    // Everything the form already captured is untouched by the new property.
    try testing.expectEqualStrings("7628*1", block.stackup.dielectrics[0].material);
    try testing.expectApproxEqAbs(@as(f64, 1.065), block.stackup.dielectrics[1].thickness, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.5862), block.stackup.constructionThickness(), 1e-9);
}

// spec: eval/design_block - an out-of-range or misplaced (er X) is warned and dropped rather than stored
test "design-block rejects a nonsense (er …)" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (stackup 2
        \\    (copper 1 (thickness 0.035) (er 4.4))
        \\    (dielectric 1 core (material "FR4") (thickness 1.5) (er 900))
        \\    (copper 2 (thickness 0.035))))
    ;
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;
    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();
    const block = (try evalDesignBlock(&eval, form_children[1..], &env)).design_block;
    // The copper foil keeps no permittivity (it is a conductor) and the
    // out-of-range dielectric value is dropped back to the "unset" sentinel.
    try testing.expectEqual(@as(usize, 1), block.stackup.dielectrics.len);
    try testing.expectApproxEqAbs(@as(f64, 0), block.stackup.dielectrics[0].er, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.5), block.stackup.dielectrics[0].thickness, 1e-9);
}

// spec: eval/design_block - a net class captures its impedance target and grounded-coplanar gap while rejecting invalid values
test "design-block captures impedance and grounded-coplanar gap" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (net-class "rf" (impedance 50) (ground-gap 0.127 (max 1.75)) (max-freq 6G) (nets "RF_IN"))
        \\  (net-class "usb" (diff-pair 0.2) (diff-impedance 90 (layer 3)) (width 0.2) (nets "USB_DP" "USB_DM"))
        \\  (net-class "bogus" (impedance 5) (nets "X"))
        \\  (net-class "words" (impedance ohms) (ground-gap nope) (nets "Y")))
    ;
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;
    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();
    const block = (try evalDesignBlock(&eval, form_children[1..], &env)).design_block;
    try testing.expectEqual(@as(usize, 4), block.net_classes.len);
    try testing.expectApproxEqAbs(@as(f64, 50), block.net_classes[0].rf.impedance.ohms, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.127), block.net_classes[0].rf.impedance.ground_gap_mm, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.75), block.net_classes[0].rf.impedance.ground_gap_max_mm, 1e-9);
    // Target AND width may be declared together — the width wins, the target
    // becomes the check.
    try testing.expectApproxEqAbs(@as(f64, 90), block.net_classes[1].rf.impedance.diff_ohms, 1e-9);
    try testing.expectEqual(@as(u8, 3), block.net_classes[1].rf.impedance.layer);
    try testing.expectApproxEqAbs(@as(f64, 0.2), block.net_classes[1].width, 1e-9);
    // 5 ohms is not a PCB transmission line, and a non-number is not a target.
    try testing.expectApproxEqAbs(@as(f64, 0), block.net_classes[2].rf.impedance.ohms, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), block.net_classes[3].rf.impedance.ohms, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0), block.net_classes[3].rf.impedance.ground_gap_mm, 1e-9);
}

// spec: eval/design_block - (pour top|bottom "NET") is stackup sugar for a plane on the matching outer layer
test "design-block maps (pour …) onto outer-layer planes" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (stackup 2 (pour bottom "GND") (pour top "VDD") (pour sideways "X")))
    ;
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;
    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();
    const value = try evalDesignBlock(&eval, form_children[1..], &env);
    const block = value.design_block;
    try testing.expect(block.stackup.present);
    try testing.expectEqual(@as(u8, 2), block.stackup.layers);
    // The malformed side is warned + dropped; the two pours land on the
    // outer indices (bottom = layer count, top = 1).
    try testing.expectEqual(@as(usize, 2), block.stackup.planes.len);
    try testing.expectEqual(@as(u8, 2), block.stackup.planes[0].index);
    try testing.expectEqualStrings("GND", block.stackup.planes[0].net);
    try testing.expectEqual(@as(u8, 1), block.stackup.planes[1].index);
    try testing.expectEqualStrings("VDD", block.stackup.planes[1].net);
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

/// The `DesignBlock` inside an evaluated `(design-block …)` value — a test
/// helper so a test body needn't unwrap the union itself.
fn designBlockOf(value: env_mod.Value) !*env_mod.DesignBlock {
    return switch (value) {
        .design_block => |b| b,
        else => error.TestUnexpectedResult,
    };
}

// spec: eval/design_block - a net-class match-group sub-form records the group name and its tolerance, warning on a nameless group
test "design-block captures (net-class … (match-group …))" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (net-class "addr" (match-group "ddr-addr" (tolerance 0.25)) (nets "A0" "A1"))
        \\  (net-class "data" (match-group "ddr-data") (nets "D0"))
        \\  (net-class "bad" (match-group) (nets "X")))
    ;
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;
    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();
    const block = try designBlockOf(try evalDesignBlock(&eval, form_children[1..], &env));
    try testing.expectEqual(@as(usize, 3), block.net_classes.len);
    try testing.expectEqualStrings("ddr-addr", block.net_classes[0].match.group);
    try testing.expectEqual(@as(f64, 0.25), block.net_classes[0].match.tolerance_mm);
    // A group with no tolerance keeps 0 — the measurement module supplies the
    // default, so the spec never carries a number the author did not write.
    try testing.expectEqualStrings("ddr-data", block.net_classes[1].match.group);
    try testing.expectEqual(@as(f64, 0), block.net_classes[1].match.tolerance_mm);
    // A nameless group joins nothing and is warned about rather than accepted.
    try testing.expectEqualStrings("", block.net_classes[2].match.group);
    try testing.expect(eval.warnings.items.len > 0);
}

test "design-block captures (net-class … (return-path …))" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (net-class "clock" (return-path (reference "GND") (stitch-radius 1.25) (max-loop-area 4.5)) (nets "CLK"))
        \\  (net-class "switch" (return-path) (nets "SW")))
    ;
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;
    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();
    const block = (try evalDesignBlock(&eval, form_children[1..], &env)).design_block;
    const clock = block.net_classes[0].return_path;
    try testing.expect(clock.declared);
    try testing.expectEqualStrings("GND", clock.reference_net);
    try testing.expectEqual(@as(f64, 1.25), clock.stitch_radius_mm);
    try testing.expectEqual(@as(f64, 4.5), clock.max_loop_area_mm2);
    try testing.expect(block.net_classes[1].return_path.declared);
}

// spec: eval/design_block - net-class profiles and memberships can be declared independently
test "design-block captures (net-class …) rules" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (net-class "power" (width 0.3) (power-branch-width 0.15) (clearance 0.2) (via 0.5 0.3) (nets "VBUS" "+5V"))
        \\  (net-class "hot" (priority 3) (nets "SW"))
        \\  (net-class "over" (priority 99) (nets "CLK"))
        \\  (net-class "profile-only" (width 1.0)))
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
    try testing.expectEqual(@as(usize, 4), block.net_classes.len);
    const nc = block.net_classes[0];
    try testing.expectEqualStrings("power", nc.name);
    try testing.expectEqual(@as(f64, 0.3), nc.width);
    try testing.expectEqual(@as(f64, 0.15), nc.pad_neck.power_branch_width);
    try testing.expectEqual(@as(f64, 0.2), nc.clearance);
    try testing.expectEqual(@as(f64, 0.5), nc.via_dia);
    try testing.expectEqual(@as(f64, 0.3), nc.via_drill);
    try testing.expectEqual(@as(u32, 0), nc.priority); // no (priority …) ⇒ baseline tier
    try testing.expectEqual(@as(usize, 2), nc.nets.len);
    try testing.expectEqualStrings("VBUS", nc.nets[0]);
    // Routing-order tier is captured, and an out-of-range value clamps to 7.
    try testing.expectEqual(@as(u32, 3), block.net_classes[1].priority);
    try testing.expectEqual(@as(u32, 7), block.net_classes[2].priority);
    try testing.expectEqualStrings("profile-only", block.net_classes[3].name);
    try testing.expectEqual(@as(f64, 1.0), block.net_classes[3].width);
    try testing.expectEqual(@as(usize, 0), block.net_classes[3].nets.len);
}

test "design-block captures pad escape neck and taper geometry" {
    const arena = std.heap.page_allocator;
    const src =
        \\(design-block "neck"
        \\  (net-class "power" (width 0.2532) (pad-escape-width 0.1524)
        \\    (pad-escape-max-length 0.75) (taper-length 0.35) (nets "VDD")))
    ;
    const nodes = try sexpr_parser.parse(arena, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;
    var eval = Evaluator.init(arena, "");
    defer eval.deinit();
    var test_env = env_mod.Env.init(arena, null);
    defer test_env.deinit();
    const value = try evalDesignBlock(&eval, form_children[1..], &test_env);
    try std.testing.expect(value == .design_block);
    const block = value.design_block;
    try std.testing.expectEqual(@as(usize, 1), block.net_classes.len);
    const spec = block.net_classes[0];
    try std.testing.expectEqual(@as(f64, 0.2532), spec.width);
    try std.testing.expectEqual(@as(f64, 0.1524), spec.pad_neck.width);
    try std.testing.expectEqual(@as(f64, 0.75), spec.pad_neck.max_length);
    try std.testing.expectEqual(@as(f64, 0.35), spec.pad_neck.taper_length);
}

// spec: eval/design_block - net-class diff-pair sub-form flags the class and captures an explicit or default gap
test "design-block captures (net-class … (diff-pair …)) flags" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (net-class "usb" (diff-pair 0.2) (nets "USB_DP" "USB_DM"))
        \\  (net-class "clk" (diff-pair) (nets "CLK_P" "CLK_N"))
        \\  (net-class "plain" (width 0.3) (nets "VBUS")))
    ;
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;
    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();
    const block = (try evalDesignBlock(&eval, form_children[1..], &env)).design_block;
    try testing.expectEqual(@as(usize, 3), block.net_classes.len);
    // (diff-pair GAP) records the explicit gap.
    try testing.expectEqual(@as(f64, 0.2), block.net_classes[0].diff_gap);
    // Bare (diff-pair) records 0 → "couple at the class clearance".
    try testing.expectEqual(@as(f64, 0), block.net_classes[1].diff_gap);
    // A class with no (diff-pair) stays a non-pair (sentinel < 0).
    try testing.expect(block.net_classes[2].diff_gap < 0);
}

// spec: eval/design_block - net-class min-bend-radius sub-form captures the per-class bend-radius floor multiple
test "design-block captures (net-class … (min-bend-radius N)) floor" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (net-class "gentle" (max-freq 12G) (min-bend-radius 5) (nets "RF_A"))
        \\  (net-class "tight" (max-freq 12G) (min-bend-radius 2) (nets "RF_B"))
        \\  (net-class "bad" (max-freq 12G) (min-bend-radius 0) (nets "RF_C"))
        \\  (net-class "plain" (max-freq 12G) (nets "RF_D")))
    ;
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;
    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();
    const block = (try evalDesignBlock(&eval, form_children[1..], &env)).design_block;
    try testing.expectEqual(@as(usize, 4), block.net_classes.len);
    // A positive N is captured verbatim (a width multiple, gentler or tighter).
    try testing.expectEqual(@as(f64, 5), block.net_classes[0].rf.min_bend_ratio);
    try testing.expectEqual(@as(f64, 2), block.net_classes[1].rf.min_bend_ratio);
    // N ≤ 0 is warned and ignored → stays the 0 (use-the-default) sentinel.
    try testing.expectEqual(@as(f64, 0), block.net_classes[2].rf.min_bend_ratio);
    // A class with no (min-bend-radius) also stays at the 0 sentinel.
    try testing.expectEqual(@as(f64, 0), block.net_classes[3].rf.min_bend_ratio);
}

// spec: eval/design_block - net-class mask-relief sub-form captures the pullback and an explicit zero keeps the class tented
test "design-block captures (net-class … (mask-relief MM))" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (net-class "bare" (max-freq 12G) (mask-relief 0.1) (nets "RF_A"))
        \\  (net-class "tented" (max-freq 12G) (mask-relief 0) (nets "RF_B"))
        \\  (net-class "plain" (max-freq 12G) (nets "RF_C")))
    ;
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;
    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();
    const block = (try evalDesignBlock(&eval, form_children[1..], &env)).design_block;
    try testing.expectEqual(@as(usize, 3), block.net_classes.len);
    // A positive pullback is captured verbatim.
    try testing.expectEqual(@as(f64, 0.1), block.net_classes[0].rf.mask_relief_mm);
    // Explicit 0 is a real answer — this max-freq class stays tented.
    try testing.expectEqual(@as(f64, 0), block.net_classes[1].rf.mask_relief_mm);
    // Undeclared keeps the -1 derive-me sentinel (max-freq default applies later).
    try testing.expectEqual(@as(f64, -1), block.net_classes[2].rf.mask_relief_mm);
}

// spec: placement/rf-port-frame-routing - eval/design_block - RF band and return-loss target are captured by net-class
test "design-block captures RF band and return-loss target" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (net-class "rf" (band 100M 6G) (return-loss 23) (impedance 50) (nets "RF")))
    ;
    const nodes = try sexpr_parser.parse(a, src);
    const children = nodes[0].asList() orelse return error.TestUnexpectedResult;
    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();
    const block = (try evalDesignBlock(&eval, children[1..], &env)).design_block;
    try testing.expectEqual(@as(f64, 100e6), block.net_classes[0].rf.electrical.band_start_hz);
    try testing.expectEqual(@as(f64, 6e9), block.net_classes[0].rf.max_freq_hz);
    try testing.expectEqual(@as(f64, 23), block.net_classes[0].rf.electrical.return_loss_target_db);
}

// spec: eval/design_block - net-class fence sub-form captures its pitch, layer count, offset, via and stitch net, and a bare (fence) opts in at every default
// spec: eval/design_block - net-class fence sub-form captures a mask-open layer count independently of its generated layer count
test "design-block captures (net-class … (fence …)) declarations" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (net-class "rf" (width 0.3124) (max-freq 12G)
        \\    (fence (pitch 1.0) (layers 2) (mask-layers 1) (offset 0.65) (via 0.4 0.2) (net "GND"))
        \\    (nets "RF1_VCO"))
        \\  (net-class "rf-bare" (max-freq 12G) (fence) (nets "RF2_VCO"))
        \\  (net-class "plain" (width 0.3) (nets "VBUS")))
    ;
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;
    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();
    const block = (try evalDesignBlock(&eval, form_children[1..], &env)).design_block;
    try testing.expectEqual(@as(usize, 3), block.net_classes.len);
    // Every child is captured verbatim — these are measured numbers, not hints.
    const fenced = block.net_classes[0].rf.fence;
    try testing.expect(fenced.declared);
    try testing.expectEqual(@as(f64, 1.0), fenced.pitch_mm);
    try testing.expectEqual(@as(u8, 2), fenced.rows.generated);
    try testing.expectEqual(@as(u8, 1), fenced.rows.mask_open);
    try testing.expectEqual(@as(f64, 0.65), fenced.offset_mm);
    try testing.expectEqual(@as(f64, 0.4), fenced.via_dia);
    try testing.expectEqual(@as(f64, 0.2), fenced.via_drill);
    try testing.expectEqualStrings("GND", fenced.net);
    // A bare (fence) is the opt-in alone: declared, every number left at its
    // derive-me sentinel and the stitched net left to the first ground plane.
    const bare = block.net_classes[1].rf.fence;
    try testing.expect(bare.declared);
    try testing.expectEqual(@as(f64, 0), bare.pitch_mm);
    try testing.expectEqual(@as(u8, 1), bare.rows.generated);
    try testing.expectEqual(@as(u8, 0), bare.rows.mask_open);
    try testing.expectEqual(@as(f64, 0), bare.offset_mm);
    try testing.expectEqual(@as(f64, 0), bare.via_dia);
    try testing.expectEqual(@as(f64, 0), bare.via_drill);
    try testing.expectEqualStrings("", bare.net);
    // No (fence …) at all ⇒ the class is never fenced.
    try testing.expect(!block.net_classes[2].rf.fence.declared);
}

// spec: eval/design_block - net-class keepout sub-form captures the halo distance and leaves its escape radius at the inherit sentinel unless authored
test "design-block captures (net-class … (keepout …)) halos" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (net-class "rf" (max-freq 12G) (keepout 0.5 (escape 1.5)) (nets "RF_A"))
        \\  (net-class "rf-inherit" (max-freq 12G) (keepout 0.4) (nets "RF_B"))
        \\  (net-class "rf-strict" (max-freq 12G) (keepout 0.4 (escape 0)) (nets "RF_C"))
        \\  (net-class "plain" (width 0.3) (nets "VBUS")))
    ;
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;
    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();
    const block = (try evalDesignBlock(&eval, form_children[1..], &env)).design_block;
    try testing.expectEqual(@as(usize, 4), block.net_classes.len);
    // Halo distance + an authored pad-escape exemption radius.
    try testing.expectEqual(@as(f64, 0.5), block.net_classes[0].rf.keepout_mm);
    try testing.expectEqual(@as(f64, 1.5), block.net_classes[0].rf.keepout_escape_mm);
    // No (escape …) ⇒ the −1 "inherit the class's rf escape" sentinel survives.
    try testing.expectEqual(@as(f64, 0.4), block.net_classes[1].rf.keepout_mm);
    try testing.expectEqual(@as(f64, -1), block.net_classes[1].rf.keepout_escape_mm);
    // An explicit (escape 0) is a real value — exempt nothing — not the sentinel.
    try testing.expectEqual(@as(f64, 0), block.net_classes[2].rf.keepout_escape_mm);
    // No (keepout …) ⇒ no halo, sentinel untouched.
    try testing.expectEqual(@as(f64, 0), block.net_classes[3].rf.keepout_mm);
    try testing.expectEqual(@as(f64, -1), block.net_classes[3].rf.keepout_escape_mm);
}

// spec: eval/design_block - design-rules form captures the board-level default rules on the design block
// spec: eval/design_block - design-rules captures an optional ground-via maximum distance for SMD ground-pad plane stitching
// spec: eval/design_block - design-rules captures an optional finished via-wall plating thickness for power-capacity analysis
test "design-block captures (design-rules …)" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (design-rules (clearance 0.15) (min-drill 0.25) (mask-margin 0.06)
        \\    (mask-relief-corner-radius 0.22)
        \\    (copper-edge 0.4) (component-edge 1.25) (hole-to-hole 0.3) (min-annular 0.13)
        \\    (pour-min-width 0.5) (pour-corner-radius 0.8) (ground-via-max 1.0)
        \\    (track-width 0.2) (via 0.5 0.25) (via-plating 0.02)))
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
    const dr = block.design_rules;
    try testing.expect(dr.present);
    try testing.expectEqual(@as(f64, 0.15), dr.clearance);
    try testing.expectEqual(@as(f64, 0.25), dr.min_drill);
    try testing.expectEqual(@as(f64, 0.06), dr.mask.margin);
    try testing.expectEqual(@as(f64, 0.22), dr.mask.relief_corner_radius);
    try testing.expectEqual(@as(f64, 0.4), dr.edge.copper);
    try testing.expectEqual(@as(f64, 1.25), dr.edge.component);
    try testing.expectEqual(@as(f64, 0.3), dr.hole_to_hole);
    try testing.expectEqual(@as(f64, 0.13), dr.min_annular);
    try testing.expectEqual(@as(f64, 0.5), dr.pour.min_width);
    try testing.expectEqual(@as(f64, 0.8), dr.pour.corner_radius);
    try testing.expectEqual(@as(f64, 1.0), dr.pour.ground_via_max);
    // Board-default routing geometry: (track-width) + (via DIA DRILL).
    try testing.expectEqual(@as(f64, 0.2), dr.track_width);
    try testing.expectEqual(@as(f64, 0.5), dr.via.dia);
    try testing.expectEqual(@as(f64, 0.25), dr.via.drill);
    try testing.expectEqual(@as(f64, 0.02), dr.via.plating);
}

/// The `(design-rules …)` a source snippet's design block resolves to — a test
/// helper, so the `Value` unwrap stays out of the test body.
fn testDesignRules(a: std.mem.Allocator, eval: *Evaluator, env: *env_mod.Env, src: []const u8) !env_mod.DesignRulesSpec {
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;
    const value = try evalDesignBlock(eval, form_children[1..], env);
    return switch (value) {
        .design_block => |b| b.design_rules,
        else => error.TestUnexpectedResult,
    };
}

// spec: eval/design_block - design-rules via-to-via sub-form captures the same-net via spacing rule
test "design-block captures (design-rules (via-to-via …))" {
    const a = std.heap.page_allocator;
    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();
    const dr = try testDesignRules(a, &eval, &env, "(design-block \"t\" (design-rules (hole-to-hole 0.2) (via-to-via 0.3)))");
    // The same-net via rule is its OWN number, not the drill wall beside it.
    try testing.expectEqual(@as(f64, 0.3), dr.via_to_via);
    try testing.expectEqual(@as(f64, 0.2), dr.hole_to_hole);
    // Unset, it stays at the zero sentinel, which resolves to "the net's own
    // clearance" rather than to any hard-coded millimetre value.
    const bare = try testDesignRules(a, &eval, &env, "(design-block \"t\" (design-rules (clearance 0.1)))");
    try testing.expectEqual(@as(f64, 0), bare.via_to_via);
}

// spec: eval/design_block - design-rules pour-clearance sets the base copper-pour isolation gap and warns when it undercuts the copper clearance
test "design-block captures (design-rules (pour-clearance …))" {
    const a = std.heap.page_allocator;
    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();
    // Authored: the base gap every ordinary pour holds off foreign copper.
    const authored = try testDesignRules(a, &eval, &env, "(design-block \"t\" (design-rules (pour-clearance 0.2)))");
    try testing.expectEqual(@as(f64, 0.2), authored.pour_clearance);
    // 0.2 clears the built-in copper clearance, so nothing is said about it.
    try testing.expect(!hasWarningContaining(&eval, "pour-clearance"));
    // Absent ⇒ the zero sentinel, which `optimizer.designRulesOf` resolves to
    // the fab-safe pour default — 0.3 mm, unchanged for every existing board.
    const bare = try testDesignRules(a, &eval, &env, "(design-block \"t\" (design-rules (clearance 0.1)))");
    try testing.expectEqual(@as(f64, 0), bare.pour_clearance);
    try testing.expectEqual(@as(f64, 0.3), env_mod.default_pour_clearance_mm);

    var warned = Evaluator.init(a, "");
    defer warned.deinit();
    var warned_env = env_mod.Env.init(a, null);
    defer warned_env.deinit();
    // Below the form's OWN clearance — kept as authored (an expert override
    // stays possible), but warned, and judged against a (clearance …) written
    // after it, which is why the check runs once the whole form is parsed.
    const under = try testDesignRules(a, &warned, &warned_env, "(design-block \"t\" (design-rules (pour-clearance 0.1) (clearance 0.2)))");
    try testing.expectEqual(@as(f64, 0.1), under.pour_clearance);
    try testing.expect(hasWarningContaining(&warned, "(pour-clearance 0.1)) is below the copper clearance (0.2)"));
    // With no (clearance …) the comparison uses the built-in 0.127 default.
    _ = try testDesignRules(a, &warned, &warned_env, "(design-block \"t\" (design-rules (pour-clearance 0.05)))");
    try testing.expect(hasWarningContaining(&warned, "(pour-clearance 0.05)) is below the copper clearance (0.127)"));
}

// spec: eval/design_block - a design with no design-rules form leaves every rule at its zero (default) sentinel
test "design-block without (design-rules …) has no rules present" {
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
    const value = try evalDesignBlock(&eval, form_children[1..], &env);
    const block = switch (value) {
        .design_block => |b| b,
        else => return error.TestUnexpectedResult,
    };
    // No form ⇒ not present, every field the zero sentinel — the consumer
    // (`optimizer.designRulesOf`) then fills in the built-in defaults.
    try testing.expect(!block.design_rules.present);
    try testing.expectEqual(@as(f64, 0), block.design_rules.clearance);
    try testing.expectEqual(@as(f64, 0), block.design_rules.min_drill);
}

/// Evaluate a bare `(design-block …)` source through the full evaluator and
/// return its block. Shared by the pcb-plan tests; page_allocator per the
/// project's never-free evaluator convention.
fn evalPlanFixture(a: std.mem.Allocator, eval: *Evaluator, src: []const u8) !*DesignBlock {
    const nodes = try sexpr_parser.parse(a, src);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;
    eval.* = Evaluator.init(a, "");
    var env = env_mod.Env.init(a, null);
    defer env.deinit();
    const value = try evalDesignBlock(eval, form_children[1..], &env);
    return switch (value) {
        .design_block => |b| b,
        else => error.TestUnexpectedResult,
    };
}

// spec: placement/optimizer - an authored rough critical-loop parses as a named closed-chain member set and contributes whole-loop compactness to placement ranking
test "rough captures an authored critical closed chain" {
    const a = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    const block = try evalPlanFixture(a, &eval,
        \\(design-block "test"
        \\  (rough
        \\    (anchor "U1")
        \\    (critical-loop "feedback" "R_FB" "C_FB" "C_FF")))
    );
    try testing.expect(block.rough.present);
    try testing.expectEqualStrings("U1", block.rough.anchor);
    try testing.expectEqual(@as(usize, 1), block.rough.critical_loops.len);
    try testing.expectEqualStrings("feedback", block.rough.critical_loops[0].name);
    try testing.expectEqual(@as(usize, 3), block.rough.critical_loops[0].members.len);
    try testing.expectEqualStrings("C_FB", block.rough.critical_loops[0].members[1]);
}

// spec: eval/pcb-plan - An (assign-escapes) route selector records its optional layer and hub overrides
test "a route wave records its (assign-escapes) opt-in" {
    const a = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    const block = try evalPlanFixture(a, &eval,
        \\(design-block "test"
        \\  (pcb-plan
        \\    (route
        \\      (wave "bare" (nets "A" "B") (assign-escapes))
        \\      (wave "aimed" (nets "C" "D") (assign-escapes "B.Cu" "J1"))
        \\      (wave "none" (nets "E")))))
    );
    const plan = block.pcb_plan.?;
    const bare = plan.route[0].corridor.assign_escapes.?;
    try testing.expectEqualStrings("", bare.layer);
    try testing.expectEqualStrings("", bare.hub);
    const aimed = plan.route[1].corridor.assign_escapes.?;
    try testing.expectEqualStrings("B.Cu", aimed.layer);
    try testing.expectEqualStrings("J1", aimed.hub);
    try testing.expect(plan.route[2].corridor.assign_escapes == null);
}

// spec: eval/pcb-plan - A pcb-plan form captures each place and route wave's selectors, reason, and rest flag
// spec: eval/pcb-plan - Relative route guides parse as ordered pin- and part-relative instructions
test "design-block captures a full (pcb-plan …)" {
    const a = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    const block = try evalPlanFixture(a, &eval,
        \\(design-block "test"
        \\  (pcb-plan
        \\    (place
        \\      (wave "Connectors & mechanical"
        \\        (refs "J1" "J2" "MH1")
        \\        (sections "USB")
        \\        (sub-blocks "buck5v")
        \\        (reason "positions fixed by enclosure ICD"))
        \\      (wave "Everything else" (rest)))
        \\    (route
        \\      (wave "High-speed"
        \\        (classes rf clock)
        \\        (net-classes "hs")
        \\        (nets "USB_DP" "USB_DM")
        \\        (preferred-layers "F.Cu")
        \\        (allowed-layers "F.Cu" "B.Cu")
        \\        (max-vias 1)
        \\        (waypoints (at 12.5 7.25 "F.Cu") (at 18 7.25 "B.Cu"))
        \\        (guides
        \\          (escape-from "U1" "7" "F.Cu")
        \\          (between-pins "J1" "2" "U1" "7" "B.Cu")
        \\          (beside "J1" east "F.Cu")))
        \\      (wave "Signals" (rest)))))
    );
    try testing.expect(block.pcb_plan != null);
    const plan = block.pcb_plan.?;
    try testing.expectEqual(@as(usize, 2), plan.place.len);
    const pw = plan.place[0];
    try testing.expectEqualStrings("Connectors & mechanical", pw.name);
    try testing.expectEqual(@as(usize, 3), pw.refs.len);
    try testing.expectEqualStrings("J1", pw.refs[0]);
    try testing.expectEqualStrings("MH1", pw.refs[2]);
    try testing.expectEqual(@as(usize, 1), pw.sections.len);
    try testing.expectEqualStrings("USB", pw.sections[0]);
    try testing.expectEqualStrings("buck5v", pw.sub_blocks[0]);
    try testing.expect(pw.reason != null);
    try testing.expectEqualStrings("positions fixed by enclosure ICD", pw.reason.?);
    try testing.expect(!pw.rest);
    try testing.expectEqualStrings("Everything else", plan.place[1].name);
    try testing.expect(plan.place[1].rest);
    // Route section: class atoms stored as strings, net-classes + one-off nets.
    try testing.expectEqual(@as(usize, 2), plan.route.len);
    const rw = plan.route[0];
    try testing.expectEqualStrings("High-speed", rw.name);
    try testing.expectEqual(@as(usize, 2), rw.classes.len);
    try testing.expectEqualStrings("rf", rw.classes[0]);
    try testing.expectEqualStrings("clock", rw.classes[1]);
    try testing.expectEqualStrings("hs", rw.net_classes[0]);
    try testing.expectEqual(@as(usize, 2), rw.nets.len);
    try testing.expectEqualStrings("USB_DP", rw.nets[0]);
    try testing.expectEqual(@as(usize, 1), rw.preferred_layers.len);
    try testing.expectEqualStrings("F.Cu", rw.preferred_layers[0]);
    try testing.expectEqual(@as(usize, 2), rw.allowed_layers.len);
    try testing.expectEqualStrings("F.Cu", rw.allowed_layers[0]);
    try testing.expectEqualStrings("B.Cu", rw.allowed_layers[1]);
    try testing.expectEqual(@as(u16, 1), rw.max_vias.?);
    try testing.expectEqual(@as(usize, 5), rw.corridor.waypoints.len);
    try testing.expectEqual(@as(f64, 12.5), rw.corridor.waypoints[0].x);
    try testing.expectEqual(@as(f64, 7.25), rw.corridor.waypoints[0].y);
    try testing.expectEqualStrings("F.Cu", rw.corridor.waypoints[0].layer);
    try testing.expectEqualStrings("B.Cu", rw.corridor.waypoints[1].layer);
    const escape = rw.corridor.waypoints[2].guide.?.escape_from;
    try testing.expectEqualStrings("U1", escape.ref);
    try testing.expectEqualStrings("7", escape.pin);
    const between = rw.corridor.waypoints[3].guide.?.between_pins;
    try testing.expectEqualStrings("J1", between.from_ref);
    try testing.expectEqualStrings("U1", between.to_ref);
    try testing.expectEqualStrings("7", between.to_pin);
    const beside = rw.corridor.waypoints[4].guide.?.beside;
    try testing.expectEqual(env_mod.PlanGuideSide.east, beside.side);
    try testing.expectEqualStrings("F.Cu", beside.layer);
    try testing.expect(plan.route[1].rest);
}

test "pcb-plan route layer-policy selectors and aliases" {
    const a = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    const block = try evalPlanFixture(a, &eval,
        \\(design-block "test"
        \\  (pcb-plan
        \\    (route (wave "RF" (prefer-layers F.Cu) (allow-layers F.Cu In2.Cu)))))
    );
    const wave = block.pcb_plan.?.route[0];
    try testing.expectEqual(@as(usize, 1), wave.preferred_layers.len);
    try testing.expectEqualStrings("F.Cu", wave.preferred_layers[0]);
    try testing.expectEqual(@as(usize, 2), wave.allowed_layers.len);
    try testing.expectEqualStrings("F.Cu", wave.allowed_layers[0]);
    try testing.expectEqualStrings("In2.Cu", wave.allowed_layers[1]);
}

// spec: eval/pcb-plan - A design with no pcb-plan form leaves DesignBlock.pcb_plan null
test "design-block without a (pcb-plan …) has null pcb_plan" {
    const a = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    const block = try evalPlanFixture(a, &eval, "(design-block \"test\")");
    try testing.expect(block.pcb_plan == null);
}

// spec: eval/pcb-plan - A duplicate pcb-plan form keeps the first and warns
test "design-block keeps the first of two (pcb-plan …) forms and warns" {
    const a = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    const block = try evalPlanFixture(a, &eval,
        \\(design-block "test"
        \\  (pcb-plan (place (wave "First" (refs "J1"))))
        \\  (pcb-plan (place (wave "Second" (refs "J2")))))
    );
    try testing.expect(block.pcb_plan != null);
    // First wins: the surviving plan is the first form's single "First" wave.
    try testing.expectEqual(@as(usize, 1), block.pcb_plan.?.place.len);
    try testing.expectEqualStrings("First", block.pcb_plan.?.place[0].name);
    try testing.expect(hasWarningContaining(&eval, "duplicate (pcb-plan …) — first kept"));
}

// spec: eval/pcb-plan - (pcb-plan (topology)) - A wave-level (topology) is a known route selector and is not warned as an unknown word
test "a route wave's (topology) parses without an unknown-word warning" {
    const a = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    const block = try evalPlanFixture(a, &eval,
        \\(design-block "test"
        \\  (pcb-plan (topology)
        \\    (route
        \\      (wave "planned" (nets "A") (topology))
        \\      (wave "plain" (rest)))))
    );
    const plan = block.pcb_plan.?;
    // Both spellings land, and neither is mistaken for an unknown sub-form.
    try testing.expect(plan.topology);
    try testing.expect(plan.route[0].corridor.topology);
    try testing.expect(!plan.route[1].corridor.topology);
    try testing.expect(!hasWarningContaining(&eval, "topology"));
}

// spec: eval/pcb-plan - (pcb-plan (topology)) - A wave-level (seed-first) is a known route selector and records a deferred bounded repair request against frozen completed copper
test "a route wave's seed-first flag parses without an unknown-word warning" {
    const a = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    const block = try evalPlanFixture(a, &eval,
        \\(design-block "test"
        \\  (pcb-plan (route
        \\    (wave "seeded" (nets "A") (seed-first)
        \\      (repair-waypoints (at 1 2 "In2.Cu")))
        \\    (wave "plain" (rest)))))
    );
    const plan = block.pcb_plan.?;
    try testing.expect(plan.route[0].corridor.seed_first);
    try testing.expectEqual(@as(usize, 1), plan.route[0].corridor.repair_waypoints.len);
    try testing.expectEqualStrings("In2.Cu", plan.route[0].corridor.repair_waypoints[0].layer);
    try testing.expect(!plan.route[1].corridor.seed_first);
    try testing.expect(!hasWarningContaining(&eval, "seed-first"));
    try testing.expect(!hasWarningContaining(&eval, "repair-waypoints"));
}

// spec: eval/pcb-plan - A route wave's (branches) records one ordered corridor per limb and skips a malformed or pointless limb with a warning
test "a route wave's branches parse one waypoint list per limb" {
    const a = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    const block = try evalPlanFixture(a, &eval,
        \\(design-block "test"
        \\  (pcb-plan (route
        \\    (wave "clock" (nets "SCK")
        \\      (branches
        \\        (branch (at 160.0 100.0 "In2.Cu") (at 170.0 104.0 "B.Cu"))
        \\        (branch (at 160.0 100.0 "In2.Cu"))
        \\        (branch)
        \\        (at 1 2 "F.Cu")))
        \\    (wave "plain" (rest)))))
    );
    const plan = block.pcb_plan.?;
    const branches = plan.route[0].corridor.branches;
    try testing.expectEqual(@as(usize, 2), branches.len);
    try testing.expectEqual(@as(usize, 2), branches[0].waypoints.len);
    try testing.expectEqualStrings("B.Cu", branches[0].waypoints[1].layer);
    try testing.expectEqual(@as(f64, 170.0), branches[0].waypoints[1].x);
    try testing.expectEqual(@as(usize, 1), branches[1].waypoints.len);
    try testing.expectEqual(@as(usize, 0), plan.route[1].corridor.branches.len);
    // The pointless and the non-(branch …) members are reported, not silent.
    try testing.expect(hasWarningContaining(&eval, "at least one (at X Y"));
    try testing.expect(hasWarningContaining(&eval, "branch must be (branch"));
    try testing.expect(!hasWarningContaining(&eval, "not a valid route-wave selector"));
}

// spec: eval/pcb-plan - A wave with no leading name string is skipped with a warning
test "pcb-plan wave without a name string is skipped with a warning" {
    const a = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    const block = try evalPlanFixture(a, &eval,
        \\(design-block "test"
        \\  (pcb-plan (place (wave (refs "J1")))))
    );
    try testing.expect(block.pcb_plan != null);
    try testing.expectEqual(@as(usize, 0), block.pcb_plan.?.place.len);
    try testing.expect(hasWarningContaining(&eval, "(wave …) must start with a name string"));
}

// spec: eval/pcb-plan - A route-only selector inside a place wave is skipped with a warning
test "pcb-plan route selector inside a place wave is skipped with a warning" {
    const a = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    const block = try evalPlanFixture(a, &eval,
        \\(design-block "test"
        \\  (pcb-plan (place (wave "W" (nets "USB_DP")))))
    );
    try testing.expect(block.pcb_plan != null);
    try testing.expectEqual(@as(usize, 1), block.pcb_plan.?.place.len);
    // The wave survives but the mis-scoped (nets …) is dropped, not stored.
    try testing.expectEqual(@as(usize, 0), block.pcb_plan.?.place[0].nets.len);
    try testing.expect(hasWarningContaining(&eval, "(nets …) is not a valid place-wave selector"));
}

// spec: eval/pcb-plan - A pcb-plan form inside a section is rejected by the scope table with a warning
test "pcb-plan inside a (section …) is rejected by the scope table" {
    const a = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    const block = try evalPlanFixture(a, &eval,
        \\(design-block "test"
        \\  (section "S" "desc"
        \\    (pcb-plan (place (wave "W" (refs "J1"))))))
    );
    // The form is top-level-only: dropped inside the section, so no plan lands.
    try testing.expect(block.pcb_plan == null);
    try testing.expect(hasWarningContaining(&eval, "(pcb-plan …) is top-level-only — ignored inside (section …)"));
}

// spec: eval/design_block - net ties merge transitively so a chained tie collapses all three nets into one
test "buildNets merges chained ties into a single net" {
    const a = std.heap.page_allocator;
    var eval = Evaluator.init(a, "");
    defer eval.deinit();

    // One pin on each of A, B, C, then chain-tie A=B and B=C. All three must
    // collapse into ONE net — the old pairwise merge re-created net B.
    var pins: std.ArrayList(PinNetDecl) = .empty;
    try pins.append(a, .{ .ref_des = "U1", .pin = "1", .net = "A" });
    try pins.append(a, .{ .ref_des = "U2", .pin = "1", .net = "B" });
    try pins.append(a, .{ .ref_des = "U3", .pin = "1", .net = "C" });
    var ties: std.ArrayList(NetTie) = .empty;
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

    var pins: std.ArrayList(PinNetDecl) = .empty;
    try pins.append(a, .{ .ref_des = "U1", .pin = "1", .net = "A" });
    try pins.append(a, .{ .ref_des = "U2", .pin = "1", .net = "B" });
    try pins.append(a, .{ .ref_des = "U3", .pin = "1", .net = "C" });
    // (net "A" "B") then (net "C" "B") — remove side (B) already merged away.
    var ties: std.ArrayList(NetTie) = .empty;
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

    var pins: std.ArrayList(PinNetDecl) = .empty;
    try pins.append(a, .{ .ref_des = "U1", .pin = "1", .net = "X" });
    try pins.append(a, .{ .ref_des = "U2", .pin = "2", .net = "X" });
    var ties: std.ArrayList(NetTie) = .empty;
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
    var pins: std.ArrayList(PinNetDecl) = .empty;
    try pins.append(a, .{ .ref_des = "C1", .pin = "1", .net = "VDD3V3.U1.24" });
    try pins.append(a, .{ .ref_des = "U1", .pin = "24", .net = "3V3" });
    var ties: std.ArrayList(NetTie) = .empty;
    try ties.append(a, .{ .a = "3V3", .b = "VDD3V3" });

    const nets = try buildNets(&eval, &pins, &ties);
    var found_stub = false;
    for (nets) |n| {
        if (std.mem.eql(u8, n.name, "3V3.U1.24")) found_stub = true;
        try testing.expect(!std.mem.startsWith(u8, n.name, "VDD3V3."));
    }
    try testing.expect(found_stub);
}

// spec: eval/design_block - board form parses outline size, corner radius, edge lists, corners, and typed perimeter keepouts
test "design-block parses a (board ...) form" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "test"
        \\  (board (part-number "CTRL-1001") (size 80 55)
        \\    (corner-radius 3)
        \\    (perimeter-fence (via 0.4 0.2) (spacing 1.0)
        \\      (edge-offset 0.5) (mask-width 0.7) (net "GND")
        \\      (keepout 0.3 (blocks components tracks vias) (allow-nets "GND")))
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
    try testing.expectEqualStrings("CTRL-1001", block.board.part_number);
    try testing.expectApproxEqAbs(@as(f64, 80), block.board.w, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 55), block.board.h, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 3), block.board.corner_radius, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.4), block.board.perimeter_fence.via_dia, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.2), block.board.perimeter_fence.via_drill, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 1.0), block.board.perimeter_fence.spacing, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.5), block.board.perimeter_fence.edge_offset, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 0.7), block.board.perimeter_fence.mask_width, 1e-9);
    try testing.expectEqualStrings("GND", block.board.perimeter_fence.net);
    try testing.expectApproxEqAbs(@as(f64, 0.3), block.board.perimeter_fence.keepout.clearance, 1e-9);
    try testing.expect(block.board.perimeter_fence.keepout.blocks.components);
    try testing.expect(block.board.perimeter_fence.keepout.blocks.tracks);
    try testing.expect(block.board.perimeter_fence.keepout.blocks.vias);
    try testing.expectEqual(@as(usize, 1), block.board.perimeter_fence.keepout.allow_nets.len);
    try testing.expectEqualStrings("GND", block.board.perimeter_fence.keepout.allow_nets[0]);
    try testing.expectEqual(@as(usize, 2), block.board.sides.len);
    try testing.expectEqualStrings("usbc", block.board.sides[0].items[0].ref);
    try testing.expectEqual(@as(f64, 90), block.board.sides[1].items[0].rot.?);
    try testing.expectEqual(@as(usize, 4), block.board.corners.len);
    try testing.expectEqualStrings("MK3", block.board.corners[2].ref);
}

// spec: eval/design_block - board form accepts an outline-approved digest only in the exact hex shape the drift finding prints, warning and dropping anything else
test "design-block parses (outline-approved ...) and refuses a malformed digest" {
    const a = std.heap.page_allocator;
    const good =
        \\(design-block "test"
        \\  (board (size 40 20) (outline-approved "8eb1d63442ff9e8f")))
    ;
    const nodes = try sexpr_parser.parse(a, good);
    const form_children = nodes[0].asList() orelse return error.TestUnexpectedResult;
    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();
    const block = (try evalDesignBlock(&eval, form_children[1..], &env)).design_block;
    try testing.expectEqualStrings("8eb1d63442ff9e8f", block.board.outline_approved);
    try testing.expectEqual(@as(usize, 0), eval.warnings.items.len);

    // A truncated / non-hex pin is a typo, not an approval: it warns and is
    // dropped, so the outline-drift finding keeps firing with the real digest.
    const bad =
        \\(design-block "test"
        \\  (board (size 40 20) (outline-approved "not-a-digest")))
    ;
    const bad_nodes = try sexpr_parser.parse(a, bad);
    const bad_children = bad_nodes[0].asList() orelse return error.TestUnexpectedResult;
    var bad_eval = Evaluator.init(a, "");
    defer bad_eval.deinit();
    var bad_env = env_mod.Env.init(a, null);
    defer bad_env.deinit();
    const bad_block = (try evalDesignBlock(&bad_eval, bad_children[1..], &bad_env)).design_block;
    try testing.expectEqualStrings("", bad_block.board.outline_approved);
    try testing.expectEqual(@as(usize, 1), bad_eval.warnings.items.len);
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

    var net_ties: std.ArrayList(NetTie) = .empty;
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

    var net_ties: std.ArrayList(NetTie) = .empty;
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

// spec: eval/design_block - bus-net mapped form applies a parent suffix and an offset child port base
test "evalBusNetForm maps suffixed lanes to offset child ports" {
    const a = std.heap.page_allocator;
    const nodes = try sexpr_parser.parse(a, "(bus-net \"DUT_A\" 0 2 (suffix \"_MCU\") (over \"shift\" (port-base \"B\" 1)))");
    var eval = Evaluator.init(a, "");
    defer eval.deinit();
    var env = env_mod.Env.init(a, null);
    defer env.deinit();
    var ties: std.ArrayList(NetTie) = .empty;
    try evalBusNetForm(&eval, nodes[0].asList().?, &env, &ties);
    try testing.expectEqual(@as(usize, 3), ties.items.len);
    try testing.expectEqualStrings("DUT_A0_MCU", ties.items[0].a);
    try testing.expectEqualStrings("shift/B1", ties.items[0].b);
    try testing.expectEqualStrings("shift/B3", ties.items[2].b);
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

    var net_ties: std.ArrayList(NetTie) = .empty;
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

    var ports: std.ArrayList(env_mod.SectionPort) = .empty;
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
const test_cap_family = "cap-0402";

fn evalWarningFixture(alloc: std.mem.Allocator, eval: *Evaluator, source: []const u8) !void {
    eval.* = Evaluator.init(alloc, ".");
    try eval.component_cache.put(alloc, test_cap_family, .{
        .name = test_cap_family,
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

// spec: eval/design_block - an unknown child of a net-class fence or keepout records a lint warning naming it
// spec: eval/design_block - a fence layer count outside 1–32 or not a whole number is warned and keeps the one-row default
// spec: eval/design_block - a fence mask-layer count outside 1–32 or not a whole number is warned and keeps the expose-all default
// spec: eval/design_block - a fence mask-layer count above the generated layer count is warned and clamped
test "unknown fence and keepout sub-forms record warnings" {
    const alloc = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    try evalWarningFixture(alloc, &eval,
        \\(design-block "T"
        \\  (net-class "rf" (max-freq 12G)
        \\    (fence (spacing 1.0) (layers 2.5) (mask-layers 2.5))
        \\    (keepout 0.5 (margin 1.5))
        \\    (nets "RF1_VCO")))
    );
    try testing.expect(hasWarningContaining(&eval, "unknown (fence …) sub-form (spacing …)"));
    try testing.expect(hasWarningContaining(&eval, "(fence (layers N)) needs a whole number from 1 to 32"));
    try testing.expect(hasWarningContaining(&eval, "(fence (mask-layers N)) needs a whole number from 1 to 32"));
    try testing.expect(hasWarningContaining(&eval, "unknown (keepout …) sub-form (margin …)"));

    try evalWarningFixture(alloc, &eval,
        \\(design-block "T"
        \\  (net-class "rf" (max-freq 12G)
        \\    (fence (mask-layers 3) (layers 2))
        \\    (nets "RF1_VCO")))
    );
    try testing.expect(hasWarningContaining(&eval, "cannot exceed the generated (layers N); clamping 3 to 2"));
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

// spec: eval/design_block - section row and col hints seed diagram-layout rows when no explicit layout exists
test "section grid seeds the default diagram layout" {
    const alloc = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    const block = try evalRepeatFixture(alloc, &eval,
        \\(design-block "Grid"
        \\  (section "C" (row 1) (col 0))
        \\  (section "B" (row 0) (col 1))
        \\  (section "A" (row 0) (col 0)))
    );
    defer eval.deinit();
    try testing.expectEqual(@as(usize, 2), block.layout.rows.len);
    try testing.expectEqualStrings("A", block.layout.rows[0].members[0]);
    try testing.expectEqualStrings("B", block.layout.rows[0].members[1]);
    try testing.expectEqualStrings("C", block.layout.rows[1].members[0]);
}

fn evalRepeatFixture(alloc: std.mem.Allocator, eval: *Evaluator, source: []const u8) !*DesignBlock {
    eval.* = Evaluator.init(alloc, ".");
    try eval.component_cache.put(alloc, test_cap_family, .{
        .name = test_cap_family,
        .symbol_name = "",
        .footprint_name = "",
        .is_family = true,
        .param_type = "",
    });
    var env = env_mod.Env.init(alloc, null);
    defer env.deinit();
    const nodes = try sexpr_parser.parse(alloc, source);
    return switch (try eval.evalNodes(nodes, &env)) {
        .design_block => |block| block,
        else => error.TestUnexpectedResult,
    };
}

fn hasNetNamed(nets: []const Net, name: []const u8) bool {
    for (nets) |net| if (std.mem.eql(u8, net.name, name)) return true;
    return false;
}

// spec: eval/design_block - repeat materializes its design-scope body for every integer in the inclusive range
// spec: eval/design_block - repeat bodies compose with arithmetic and lowercase fmt generic display
test "repeat materializes computed instances and nets inclusively" {
    const alloc = std.heap.page_allocator;
    const source =
        \\(design-block "Repeated channels"
        \\  (hierarchical-ids)
        \\  (repeat ch 1 3
        \\    (instance (fmt "C~a" ch) (cap-0402 "100nF")
        \\      (pin 1 (fmt "RF~a" (+ ch 1)))
        \\      (pin 2 "GND"))
        \\    (id abcd1234)))
    ;
    var eval: Evaluator = undefined;
    const block = try evalRepeatFixture(alloc, &eval, source);
    defer eval.deinit();

    try testing.expectEqual(@as(usize, 3), block.instances.len);
    try testing.expectEqualStrings("C1", block.instances[0].ref_des);
    try testing.expectEqualStrings("C3", block.instances[2].ref_des);
    try testing.expectEqualStrings("C1", block.instances[0].origin_key);
    try testing.expectEqualStrings("C3", block.instances[2].origin_key);
    try testing.expect(hasNetNamed(block.nets, "RF2"));
    try testing.expect(hasNetNamed(block.nets, "RF4"));
    // Only the repeat's pinned anchor is source-resident; its body must not
    // queue three impossible `(id …)` writes against one AST offset.
    try testing.expectEqual(@as(usize, 0), eval.pending_ids.items.len);
}

// spec: eval/design_block - repeat derives distinct stable child ids from its anchor origin key and lexical index
test "repeat hierarchical ids are stable across evaluations" {
    const alloc = std.heap.page_allocator;
    const source =
        \\(design-block "Repeated channels"
        \\  (hierarchical-ids)
        \\  (repeat ch 1 3
        \\    (instance (fmt "C~a" ch) (cap-0402 "100nF")
        \\      (pin 1 (fmt "RF~a" ch)) (pin 2 "GND"))
        \\    (id bcde2345)))
    ;
    var eval_a: Evaluator = undefined;
    const block_a = try evalRepeatFixture(alloc, &eval_a, source);
    defer eval_a.deinit();
    var eval_b: Evaluator = undefined;
    const block_b = try evalRepeatFixture(alloc, &eval_b, source);
    defer eval_b.deinit();

    try testing.expectEqual(@as(usize, 3), block_a.instances.len);
    try testing.expect(!std.mem.eql(u8, block_a.instances[0].id, block_a.instances[1].id));
    for (block_a.instances, block_b.instances) |a, b| {
        try testing.expectEqualStrings(a.ref_des, b.ref_des);
        try testing.expectEqualStrings(a.id, b.id);
    }
}

// spec: eval/design_block - repeat ids sidecars override indexed child derivation for UUID-preserving migrations
test "repeat ids sidecar preserves migrated instance ids" {
    const alloc = std.heap.page_allocator;
    const source =
        \\(design-block "Migrated channels"
        \\  (hierarchical-ids)
        \\  (repeat ch 1 2
        \\    (instance (fmt "C~a" ch) (cap-0402 "100nF")
        \\      (pin 1 (fmt "RF~a" ch)) (pin 2 "GND"))
        \\    (id defa4567)
        \\    (ids ("C1@1" deadbeef) ("C2@2" face1234))))
    ;
    var eval: Evaluator = undefined;
    const block = try evalRepeatFixture(alloc, &eval, source);
    defer eval.deinit();

    try testing.expectEqual(@as(usize, 2), block.instances.len);
    try testing.expectEqualStrings("deadbeef", block.instances[0].id);
    try testing.expectEqualStrings("face1234", block.instances[1].id);
    try testing.expectEqual(@as(usize, 0), eval.pending_child_ids.items.len);
}

// spec: eval/design_block - repeat composes with sub-block calls and gives each repeated module a distinct stable hierarchy
test "repeat materializes sub-block arrays with stable child ids" {
    const alloc = std.heap.page_allocator;
    const source =
        \\(defmodule channel ()
        \\  (design-block "Channel"
        \\    (instance "C_LOCAL" (cap-0402 "100nF")
        \\      (pin 1 "RF") (pin 2 "GND"))))
        \\(design-block "Repeated modules"
        \\  (hierarchical-ids)
        \\  (repeat ch 1 2
        \\    (sub-block (fmt "channel~a" ch) (channel))
        \\    (id cdef3456)))
    ;
    var eval_a: Evaluator = undefined;
    const block_a = try evalRepeatFixture(alloc, &eval_a, source);
    defer eval_a.deinit();
    var eval_b: Evaluator = undefined;
    const block_b = try evalRepeatFixture(alloc, &eval_b, source);
    defer eval_b.deinit();

    try testing.expectEqual(@as(usize, 2), block_a.sub_blocks.len);
    try testing.expectEqualStrings("channel1", block_a.sub_blocks[0].name);
    try testing.expectEqualStrings("channel2", block_a.sub_blocks[1].name);
    const id_a0 = block_a.sub_blocks[0].block.instances[0].id;
    const id_a1 = block_a.sub_blocks[1].block.instances[0].id;
    try testing.expect(!std.mem.eql(u8, id_a0, id_a1));
    try testing.expectEqualStrings(id_a0, block_b.sub_blocks[0].block.instances[0].id);
    try testing.expectEqualStrings(id_a1, block_b.sub_blocks[1].block.instances[0].id);
}

// spec: eval/design_block - sub-block inside a section materializes globally and records syntactic section ownership
test "section owns an inline sub-block" {
    const alloc = std.heap.page_allocator;
    const source =
        \\(defmodule channel ()
        \\  (design-block "Channel"
        \\    (instance "C_LOCAL" (cap-0402 "100nF") "RF" "GND")))
        \\(design-block "Inline module"
        \\  (section "Channel"
        \\    (sub-block "ch1" (channel))))
    ;
    var eval: Evaluator = undefined;
    const block = try evalRepeatFixture(alloc, &eval, source);
    defer eval.deinit();
    try testing.expectEqual(@as(usize, 1), block.sub_blocks.len);
    try testing.expectEqual(@as(usize, 1), block.sections.len);
    try testing.expectEqualStrings("ch1", block.sections[0].hosts[0]);
    try testing.expectEqual(env_mod.SectionStatus.implemented, block.sections[0].status);
}

// spec: eval/design_block - compact decouple infers one host from pin functions and mixes per-pin with bulk capacitors
test "compact decouple emits named per-pin and bulk capacitors" {
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    try eval.component_cache.put(alloc, "fakeic", .{
        .name = "fakeic",
        .symbol_name = "fakepin",
        .footprint_name = "",
        .is_family = false,
        .param_type = "",
    });
    inline for (.{ "cap-0201", "cap-0402" }) |family| try eval.component_cache.put(alloc, family, .{
        .name = family,
        .symbol_name = "",
        .footprint_name = "",
        .is_family = true,
        .param_type = "",
    });
    var pinout: std.StringHashMapUnmanaged([]const u8) = .empty;
    try pinout.put(alloc, "7", "VCCDIG");
    try pinout.put(alloc, "11", "VCCCP");
    try eval.symbol_pin_cache.put(alloc, "fakepin", pinout);
    const source =
        \\(design-block "Compact decouple"
        \\  (instance "U1" fakeic (pin 7 11 "VDD"))
        \\  (decouple "VDD"
        \\    (per-pin (cap-0201 "100nF") VCCDIG VCCCP)
        \\    (bulk (cap-0402 "10uF") 2)))
    ;
    var env = env_mod.Env.init(alloc, null);
    defer env.deinit();
    const nodes = try sexpr_parser.parse(alloc, source);
    const block = try designBlockOf(try eval.evalNodes(nodes, &env));
    try testing.expectEqual(@as(usize, 5), block.instances.len);
    try testing.expectEqualStrings("C_VCCDIG", block.instances[1].label);
    try testing.expectEqualStrings("C_VCCCP", block.instances[2].label);
    try testing.expect(block.instances[3].bind.decouple.rail);
    try testing.expect(block.instances[4].bind.decouple.rail);
}

// spec: eval/design_block - bare top-level pins forms attach electrical pins instead of silently no-oping
test "top-level pins form attaches pins to its instance" {
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    try eval.component_cache.put(alloc, "fakeic", .{
        .name = "fakeic",
        .symbol_name = "",
        .footprint_name = "",
        .is_family = false,
        .param_type = "",
    });
    var env = env_mod.Env.init(alloc, null);
    defer env.deinit();
    const nodes = try sexpr_parser.parse(alloc, "(design-block \"Pins\" (instance \"U1\" fakeic) (pins \"U1\" (pin 1 \"SIG\")))");
    const block = try designBlockOf(try eval.evalNodes(nodes, &env));
    try testing.expect(hasNetNamed(block.nets, "SIG"));
    try testing.expectEqual(@as(usize, 1), block.instances[0].parts.len);
    try testing.expectEqual(@as(usize, 1), block.instances[0].parts[0].pins.len);
}

/// Find the first cap-0402 instance in a block, or null.
fn findCapInstance(block: *const DesignBlock) ?Instance {
    for (block.instances) |inst| {
        if (std.mem.eql(u8, inst.component, test_cap_family)) return inst;
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

/// Evaluate a one-block source with a `fakeic` whose pinout maps VIN→4 and
/// EN→5, returning the block. The shared fixture for the decoupling-binding
/// resolution tests, which differ only in declaration order.
fn evalDecoupleBindingFixture(alloc: std.mem.Allocator, eval: *Evaluator, source: []const u8) !*DesignBlock {
    try eval.component_cache.put(alloc, "fakeic", .{
        .name = "fakeic",
        .symbol_name = "fakepin",
        .footprint_name = "",
        .is_family = false,
        .param_type = "",
    });
    try eval.component_cache.put(alloc, "cap-0402", .{
        .name = "cap-0402",
        .symbol_name = "",
        .footprint_name = "",
        .is_family = true,
        .param_type = "",
    });
    // The `(near …)` twin of this fixture declares a resistor rather than a cap,
    // since adjacency is a passive-wide form while decoupling is a cap's.
    try eval.component_cache.put(alloc, "res-0402", .{
        .name = "res-0402",
        .symbol_name = "",
        .footprint_name = "",
        .is_family = true,
        .param_type = "",
    });
    var pinout: std.StringHashMapUnmanaged([]const u8) = .empty;
    try pinout.put(alloc, "4", "VIN");
    try pinout.put(alloc, "5", "EN");
    try pinout.put(alloc, "9", "GND");
    try eval.symbol_pin_cache.put(alloc, "fakepin", pinout);
    var env = env_mod.Env.init(alloc, null);
    defer env.deinit();
    const nodes = try sexpr_parser.parse(alloc, source);
    return designBlockOf(try eval.evalNodes(nodes, &env));
}

/// The cap in a `evalDecoupleBindingFixture` block (the only `cap-0402`).
fn decoupleFixtureCap(block: *const DesignBlock) !Instance {
    for (block.instances) |inst| {
        if (std.mem.eql(u8, inst.component, "cap-0402")) return inst;
    }
    return error.TestUnexpectedResult;
}

// spec: eval/design_block - a decoupling binding resolves its pin through the target IC's pinout whichever of the two is declared first
test "decouples resolves a function name against the target's pinout in either order" {
    const alloc = std.heap.page_allocator;

    // IC first — the ordinary spelling. `(decouples "U1" VIN)` must land on the
    // pad U1's OWN pinout calls VIN (4), not on the raw token: a capacitor has
    // no pinout, so resolving against the cap could never have found it.
    var eval_a = Evaluator.init(alloc, ".");
    defer eval_a.deinit();
    const ic_first = try evalDecoupleBindingFixture(alloc, &eval_a,
        \\(design-block "IC first"
        \\  (instance "U1" fakeic (pin 4 "VIN") (pin 9 "GND"))
        \\  (instance "C1" (cap-0402 "100nF") (pin 1 "VIN") (pin 2 "GND")
        \\    (decouples "U1" VIN)))
    );
    const cap_a = try decoupleFixtureCap(ic_first);
    try testing.expectEqualStrings("U1", cap_a.bind.decouple.ic);
    try testing.expectEqualStrings("4", cap_a.bind.decouple.pin);

    // Cap first — the target does not exist yet when the cap is built, which is
    // exactly why this cannot be eval-time work. Same answer.
    var eval_b = Evaluator.init(alloc, ".");
    defer eval_b.deinit();
    const cap_first = try evalDecoupleBindingFixture(alloc, &eval_b,
        \\(design-block "Cap first"
        \\  (instance "C1" (cap-0402 "100nF") (pin 1 "VIN") (pin 2 "GND")
        \\    (decouples "U1" VIN))
        \\  (instance "U1" fakeic (pin 4 "VIN") (pin 9 "GND")))
    );
    const cap_b = try decoupleFixtureCap(cap_first);
    try testing.expectEqualStrings("4", cap_b.bind.decouple.pin);

    // A numeric pad passes through untouched, and an unknown token is left
    // exactly as written for the ERC validity check to report.
    var eval_c = Evaluator.init(alloc, ".");
    defer eval_c.deinit();
    const literal = try evalDecoupleBindingFixture(alloc, &eval_c,
        \\(design-block "Literal"
        \\  (instance "U1" fakeic (pin 4 "VIN") (pin 9 "GND"))
        \\  (instance "C1" (cap-0402 "100nF") (pin 1 "VIN") (pin 2 "GND")
        \\    (decouples "U1" 4))
        \\  (instance "C2" (cap-0402 "100nF") (pin 1 "VIN") (pin 2 "GND")
        \\    (decouples "U1" VOUT)))
    );
    try testing.expectEqualStrings("4", (try decoupleFixtureCap(literal)).bind.decouple.pin);
    for (literal.instances) |inst| {
        if (std.mem.eql(u8, inst.ref_des, "C2")) try testing.expectEqualStrings("VOUT", inst.bind.decouple.pin);
    }
}

/// The near-bound resistor in a `evalDecoupleBindingFixture` block.
fn nearFixtureResistor(block: *const DesignBlock) !Instance {
    for (block.instances) |inst| {
        if (std.mem.eql(u8, inst.component, "res-0402")) return inst;
    }
    return error.TestUnexpectedResult;
}

// spec: eval/design_block - an adjacency binding resolves its pin through the target's pinout whichever of the two is declared first
test "near resolves a function name against the target's pinout in either order" {
    const alloc = std.heap.page_allocator;

    // Target first. `(near "U1" VIN)` must land on the pad U1's OWN pinout calls
    // VIN (4) — a resistor has no pinout, so resolving against the resistor
    // could never have found it.
    var eval_a = Evaluator.init(alloc, ".");
    defer eval_a.deinit();
    const ic_first = try evalDecoupleBindingFixture(alloc, &eval_a,
        \\(design-block "IC first"
        \\  (instance "U1" fakeic (pin 4 "VIN") (pin 9 "GND"))
        \\  (instance "R1" (res-0402 "10k") (pin 1 "VIN") (pin 2 "TAP")
        \\    (near "U1" VIN)))
    );
    const r_a = try nearFixtureResistor(ic_first);
    try testing.expectEqualStrings("U1", r_a.bind.near.ref);
    try testing.expectEqualStrings("4", r_a.bind.near.pin);

    // Passive first — the target does not exist yet when the resistor is built,
    // which is exactly why this cannot be eval-time work. Same answer.
    var eval_b = Evaluator.init(alloc, ".");
    defer eval_b.deinit();
    const part_first = try evalDecoupleBindingFixture(alloc, &eval_b,
        \\(design-block "Passive first"
        \\  (instance "R1" (res-0402 "10k") (pin 1 "VIN") (pin 2 "TAP")
        \\    (near "U1" VIN))
        \\  (instance "U1" fakeic (pin 4 "VIN") (pin 9 "GND")))
    );
    try testing.expectEqualStrings("4", (try nearFixtureResistor(part_first)).bind.near.pin);

    // A numeric pad passes through untouched; an unknown token stays exactly as
    // written for the `invalid_near_binding` ERC check to report.
    var eval_c = Evaluator.init(alloc, ".");
    defer eval_c.deinit();
    const literal_near = try evalDecoupleBindingFixture(alloc, &eval_c,
        \\(design-block "Literal"
        \\  (instance "U1" fakeic (pin 4 "VIN") (pin 9 "GND"))
        \\  (instance "R1" (res-0402 "10k") (pin 1 "VIN") (pin 2 "TAP") (near "U1" 4))
        \\  (instance "R2" (res-0402 "10k") (pin 1 "VIN") (pin 2 "TAP") (near "U1" VOUT)))
    );
    for (literal_near.instances) |inst| {
        if (std.mem.eql(u8, inst.ref_des, "R1")) try testing.expectEqualStrings("4", inst.bind.near.pin);
        if (std.mem.eql(u8, inst.ref_des, "R2")) try testing.expectEqualStrings("VOUT", inst.bind.near.pin);
    }
}

// spec: eval/design_block - a decouple per-pin child records its host ref and resolved pad as a binding for pad and function-name spellings alike
test "decouple per-pin children carry a first-class host ref and pad" {
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    // Two caps on one rail: one declared by PAD (4) and one by FUNCTION (EN).
    // Only the pad spelling ever reached the placer, because the function
    // spelling replaces the structural origin key with a readable label.
    const block = try evalDecoupleBindingFixture(alloc, &eval,
        \\(design-block "Per-pin"
        \\  (instance "U1" fakeic (pin 4 "VDD") (pin 5 "VDD") (pin 9 "GND"))
        \\  (decouple "VDD" (cap-0402 "100nF") 1 per-pin U1 4)
        \\  (decouple "VDD" (cap-0402 "100nF") 1 per-pin U1 EN))
    );
    var by_pad: usize = 0;
    var by_function: usize = 0;
    for (block.instances) |inst| {
        if (!std.mem.eql(u8, inst.component, "cap-0402")) continue;
        try testing.expectEqualStrings("U1", inst.bind.decouple.ic);
        if (std.mem.eql(u8, inst.bind.decouple.pin, "4")) by_pad += 1;
        if (std.mem.eql(u8, inst.bind.decouple.pin, "5")) by_function += 1;
    }
    try testing.expectEqual(@as(usize, 1), by_pad);
    // The function name resolved to EN's pad, and the binding survives even
    // though this child's origin key is the label `C_EN`, not `100nF@5#0`.
    try testing.expectEqual(@as(usize, 1), by_function);
}
