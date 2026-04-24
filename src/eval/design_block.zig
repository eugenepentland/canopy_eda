const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const env_mod = @import("env.zig");
const Evaluator = @import("evaluator.zig").Evaluator;
const EvalError = @import("evaluator.zig").EvalError;
const PinNetDecl = @import("evaluator.zig").PinNetDecl;
const NetTie = Evaluator.NetTie;
const ids = @import("ids.zig");
const validate = @import("validate.zig");
const instance_mod = @import("instance.zig");
const builders = @import("builders.zig");

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
    var net_form_sources: std.StringHashMapUnmanaged(u32) = .empty;

    // Pre-scan: register all explicit ref-des to avoid auto-counter collisions
    ids.prescanRefDes(self, args[1..]);

    for (args[1..]) |form| {
        const form_children = form.asList() orelse continue;
        if (form_children.len == 0) continue;
        const form_name = form_children[0].asAtom() orelse continue;

        if (std.mem.eql(u8, form_name, "instance")) {
            const result = try instance_mod.buildInstance(self, form_children, env);
            ids.registerRefDes(self, result.instance.ref_des);
            try instances.append(self.allocator, result.instance);
            for (result.pin_nets) |pn| {
                try all_pin_nets.append(self.allocator, pn);
            }
            for (result.inline_notes) |note| {
                try notes.append(self.allocator, note);
            }
            // Auto pin aliases: if package/symbol has pin names, create net-ties
            appendAutoAliases(self, result.instance, result.pin_nets, &net_ties);
        } else if (std.mem.eql(u8, form_name, "port")) {
            const port = try builders.buildPort(self, form_children[1..], env);
            try ports.append(self.allocator, port);
        } else if (std.mem.eql(u8, form_name, "note")) {
            const note = try builders.buildNote(self, form_children[1..], env);
            try notes.append(self.allocator, note);
        } else if (std.mem.eql(u8, form_name, "group")) {
            const group = try builders.buildGroup(self, form_children[1..], env);
            try groups.append(self.allocator, group);
        } else if (std.mem.eql(u8, form_name, "sub-block")) {
            const sb = try builders.buildSubBlock(self, form_children[1..], env);
            try sub_blocks.append(self.allocator, sb);
        } else if (std.mem.eql(u8, form_name, "section")) {
            try evalSection(self, form_children, env, &instances, &all_pin_nets, &notes, &net_ties, &sections);
        } else if (std.mem.eql(u8, form_name, "net")) {
            try evalNetForm(self, form_children, env, &net_ties);
            validate.trackNetFormSource(self, form_children, env, &net_form_sources);
        } else if (std.mem.eql(u8, form_name, "series")) {
            try instance_mod.evalSeriesForm(self, form_children, env, &instances, &all_pin_nets, &notes);
        } else if (std.mem.eql(u8, form_name, "decouple")) {
            try evalDecoupleForm(self, form_children, env, &instances, &all_pin_nets);
        }
        // Ignore config and other unknown forms for now
    }

    validate.warnCombinableNets(self, &net_form_sources);
    const nets_slice = try buildNets(self, &all_pin_nets, &net_ties);

    // Convert net ties to env NetTie format for storage on the block.
    // Skip auto-aliases: they're block-local helpers (symbol pin-function
    // matching) and would otherwise bridge unrelated nets in the cross-block
    // flatten done by export_kicad_netlist.applyNetTies.
    var block_ties: std.ArrayListUnmanaged(env_mod.NetTie) = .empty;
    for (net_ties.items) |nt| {
        if (nt.is_auto) continue;
        block_ties.append(self.allocator, .{ .a = nt.a, .b = nt.b }) catch {};
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
    };

    // Auto-assign ref_des for instances with descriptive labels
    ids.autoAssignRefDes(self, block) catch {};

    // Auto-assign global ref_des for sub-block instances
    ids.autoAssignSubBlockRefDes(self, block) catch {};

    // Validate: warn about dead-end nets, etc.
    validate.validateDesign(self, block);

    return .{ .design_block = block };
}

/// Append auto pin aliases (net-ties) for an instance based on its pinout.
fn appendAutoAliases(self: *Evaluator, inst: Instance, pin_nets: []const PinNetDecl, net_ties: *std.ArrayListUnmanaged(NetTie)) void {
    const comp_data = self.component_cache.get(inst.component);
    const pin_lookup_name = if (comp_data) |cd| (if (cd.pinout_name.len > 0) cd.pinout_name else cd.symbol_name) else inst.symbol;
    if (pin_lookup_name.len > 0) {
        if (ids.getSymbolPins(self, pin_lookup_name)) |sym_pins| {
            for (pin_nets) |pn| {
                if (sym_pins.get(pn.pin)) |func_name| {
                    if (pn.net.len > 0 and !std.mem.eql(u8, pn.net, func_name)) {
                        net_ties.append(self.allocator, .{ .a = pn.net, .b = func_name, .is_auto = true }) catch {};
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
    const tl_dec_id = try ids.getOrCreateFormId(self, form_children);
    var tl_dec_counter: usize = 0;

    // Multi-net form: (decouple (comp "val") COUNT per-pin REF "NET1" "NET2" ...)
    if (first_val == .component or first_val == .component_instance) {
        if (form_children.len < 6) return;
        for (form_children[5..]) |mn_node| {
            if (mn_node.isForm("id")) continue;
            const mn_val = try self.evalNode(mn_node, env);
            const mn_net = mn_val.asString() orelse continue;
            try builders.emitDecoupleItems(self, form_children[1..5], mn_net, env, instances, all_pin_nets, tl_dec_id, &tl_dec_counter);
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
                    try builders.emitDecoupleItems(self, sub[1..], net_name, env, instances, all_pin_nets, tl_dec_id, &tl_dec_counter);
                }
            }
        } else {
            try builders.emitDecoupleItems(self, form_children[2..], net_name, env, instances, all_pin_nets, tl_dec_id, &tl_dec_counter);
        }
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
    var sec_notes: std.ArrayListUnmanaged([]const u8) = .empty;
    var sec_ports: std.ArrayListUnmanaged(env_mod.SectionPort) = .empty;
    var sec_protocols: std.ArrayListUnmanaged([]const u8) = .empty;
    var sec_calcs: std.ArrayListUnmanaged(env_mod.CalcBlock) = .empty;
    var sec_sub_sections: std.ArrayListUnmanaged(env_mod.Section) = .empty;
    var explicit_status: ?env_mod.SectionStatus = null;
    var block_role: env_mod.BlockRole = .auto;

    // Check for optional description as 2nd positional string arg
    var child_start: usize = 2;
    if (form_children.len > 2) {
        if (form_children[2].asString()) |desc| {
            sec_description = desc;
            child_start = 3;
        }
    }

    for (form_children[child_start..]) |sf| {
        const sf_children = sf.asList() orelse continue;
        if (sf_children.len == 0) continue;
        const sf_name = sf_children[0].asAtom() orelse continue;

        if (std.mem.eql(u8, sf_name, "status")) {
            if (sf_children.len >= 2) {
                if (sf_children[1].asAtom()) |status_str| {
                    explicit_status = parseSectionStatus(status_str);
                }
            }
        } else if (std.mem.eql(u8, sf_name, "role")) {
            if (sf_children.len >= 2) {
                if (sf_children[1].asAtom()) |role_str| {
                    if (std.mem.eql(u8, role_str, "input")) block_role = .input else if (std.mem.eql(u8, role_str, "output")) block_role = .output;
                }
            }
        } else if (std.mem.eql(u8, sf_name, "description")) {
            if (sf_children.len >= 2) {
                const desc_val = try self.evalNode(sf_children[1], env);
                sec_description = desc_val.asString() orelse "";
            }
        } else if (std.mem.eql(u8, sf_name, "note")) {
            if (sf_children.len >= 2) {
                const note_val = try self.evalNode(sf_children[1], env);
                if (note_val.asString()) |text| {
                    sec_notes.append(self.allocator, text) catch {};
                }
            }
        } else if (std.mem.eql(u8, sf_name, "port")) {
            const port = try builders.parseSectionPort(self, sf_children, env);
            if (port) |p| try sec_ports.append(self.allocator, p);
        } else if (std.mem.eql(u8, sf_name, "protocol")) {
            if (sf_children.len >= 2) {
                if (sf_children[1].asAtom()) |proto| {
                    try sec_protocols.append(self.allocator, proto);
                }
            }
        } else if (std.mem.eql(u8, sf_name, "calc")) {
            const calc = try builders.parseSectionCalc(self, sf_children, env);
            if (calc) |c| try sec_calcs.append(self.allocator, c);
        } else if (std.mem.eql(u8, sf_name, "instance")) {
            const result = try instance_mod.buildInstance(self, sf_children, env);
            ids.registerRefDes(self, result.instance.ref_des);
            try instances.append(self.allocator, result.instance);
            try sec_instances.append(self.allocator, result.instance);
            for (result.pin_nets) |pn| try all_pin_nets.append(self.allocator, pn);
            for (result.inline_notes) |note| try notes.append(self.allocator, note);
            // Auto pin aliases
            appendAutoAliases(self, result.instance, result.pin_nets, net_ties);
        } else if (std.mem.eql(u8, sf_name, "pins")) {
            try evalPinsForm(self, sf_children, sec_name, env, instances, all_pin_nets, net_ties, &sec_pin_groups);
        } else if (std.mem.eql(u8, sf_name, "decouple")) {
            const pre_count = instances.items.len;
            try evalSectionDecouple(self, sf_children, env, instances, all_pin_nets);
            // Add newly created instances to section
            for (instances.items[pre_count..]) |new_inst| {
                try sec_instances.append(self.allocator, new_inst);
            }
        } else if (std.mem.eql(u8, sf_name, "series")) {
            const pre_s = instances.items.len;
            try instance_mod.evalSeriesForm(self, sf_children, env, instances, all_pin_nets, notes);
            for (instances.items[pre_s..]) |new_inst| try sec_instances.append(self.allocator, new_inst);
        } else if (std.mem.eql(u8, sf_name, "net")) {
            try evalNetForm(self, sf_children, env, net_ties);
        } else if (std.mem.eql(u8, sf_name, "section")) {
            // Nested sub-section
            try evalSubSection(self, sf_children, env, instances, all_pin_nets, notes, net_ties, &sec_instances, &sec_sub_sections);
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
    const dec_id = try ids.getOrCreateFormId(self, sf_children);
    var dec_counter: usize = 0;

    // Multi-net form: (decouple (comp "val") COUNT per-pin REF "NET1" "NET2" ...)
    if (dec_first_val == .component or dec_first_val == .component_instance) {
        if (sf_children.len < 6) return;
        for (sf_children[5..]) |mn_node| {
            if (mn_node.isForm("id")) continue;
            const mn_val = try self.evalNode(mn_node, env);
            const mn_net = mn_val.asString() orelse continue;
            try builders.emitDecoupleItems(self, sf_children[1..5], mn_net, env, instances, all_pin_nets, dec_id, &dec_counter);
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
                    try builders.emitDecoupleItems(self, sub[1..], net_name, env, instances, all_pin_nets, dec_id, &dec_counter);
                }
            }
        } else {
            try builders.emitDecoupleItems(self, sf_children[2..], net_name, env, instances, all_pin_nets, dec_id, &dec_counter);
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
    var sub_notes: std.ArrayListUnmanaged([]const u8) = .empty;
    var sub_ports: std.ArrayListUnmanaged(env_mod.SectionPort) = .empty;
    var sub_protocols: std.ArrayListUnmanaged([]const u8) = .empty;
    var sub_calcs: std.ArrayListUnmanaged(env_mod.CalcBlock) = .empty;

    var explicit_status: ?env_mod.SectionStatus = null;

    for (sf_children[2..]) |ssf| {
        const ssf_children = ssf.asList() orelse continue;
        if (ssf_children.len == 0) continue;
        const ssf_name = ssf_children[0].asAtom() orelse continue;

        if (std.mem.eql(u8, ssf_name, "status")) {
            if (ssf_children.len >= 2) {
                if (ssf_children[1].asAtom()) |status_str| {
                    explicit_status = parseSectionStatus(status_str);
                }
            }
        } else if (std.mem.eql(u8, ssf_name, "description")) {
            if (ssf_children.len >= 2) {
                const dv = try self.evalNode(ssf_children[1], env);
                sub_description = dv.asString() orelse "";
            }
        } else if (std.mem.eql(u8, ssf_name, "note")) {
            if (ssf_children.len >= 2) {
                const nv = try self.evalNode(ssf_children[1], env);
                if (nv.asString()) |text| sub_notes.append(self.allocator, text) catch {};
            }
        } else if (std.mem.eql(u8, ssf_name, "port")) {
            const port = try builders.parseSectionPort(self, ssf_children, env);
            if (port) |p| try sub_ports.append(self.allocator, p);
        } else if (std.mem.eql(u8, ssf_name, "protocol")) {
            if (ssf_children.len >= 2) {
                if (ssf_children[1].asAtom()) |proto| {
                    try sub_protocols.append(self.allocator, proto);
                }
            }
        } else if (std.mem.eql(u8, ssf_name, "calc")) {
            const calc = try builders.parseSectionCalc(self, ssf_children, env);
            if (calc) |c| try sub_calcs.append(self.allocator, c);
        } else if (std.mem.eql(u8, ssf_name, "instance")) {
            const result = try instance_mod.buildInstance(self, ssf_children, env);
            ids.registerRefDes(self, result.instance.ref_des);
            try instances.append(self.allocator, result.instance);
            try sec_instances.append(self.allocator, result.instance);
            try sub_instances.append(self.allocator, result.instance);
            for (result.pin_nets) |pn| try all_pin_nets.append(self.allocator, pn);
            for (result.inline_notes) |note| try notes.append(self.allocator, note);
        } else if (std.mem.eql(u8, ssf_name, "pins")) {
            // Reuse parent section's pins handling
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
        } else if (std.mem.eql(u8, ssf_name, "decouple")) {
            const pre_count = instances.items.len;
            try evalSectionDecouple(self, ssf_children, env, instances, all_pin_nets);
            for (instances.items[pre_count..]) |new_inst| {
                try sec_instances.append(self.allocator, new_inst);
                try sub_instances.append(self.allocator, new_inst);
            }
        } else if (std.mem.eql(u8, ssf_name, "series")) {
            const pre_s = instances.items.len;
            try instance_mod.evalSeriesForm(self, ssf_children, env, instances, all_pin_nets, notes);
            for (instances.items[pre_s..]) |new_inst| {
                try sec_instances.append(self.allocator, new_inst);
                try sub_instances.append(self.allocator, new_inst);
            }
        } else if (std.mem.eql(u8, ssf_name, "net")) {
            try evalNetForm(self, ssf_children, env, net_ties);
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
            .asserted_fn = pn.asserted_fn,
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
