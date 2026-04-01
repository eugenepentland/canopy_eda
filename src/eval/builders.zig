const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const parser_mod = @import("../sexpr/parser.zig");
const env_mod = @import("env.zig");
const Evaluator = @import("evaluator.zig").Evaluator;
const EvalError = @import("evaluator.zig").EvalError;
const PinNetDecl = @import("evaluator.zig").PinNetDecl;
const NetTie = Evaluator.NetTie;
const ids = @import("ids.zig");
const instance_mod = @import("instance.zig");

const Node = ast.Node;
const Value = env_mod.Value;
const Env = env_mod.Env;
const Instance = env_mod.Instance;
const Port = env_mod.Port;
const Note = env_mod.Note;
const Group = env_mod.Group;
const SubBlock = env_mod.SubBlock;

/// Parse (port "NET" in/out/io ...) section port declaration.
pub fn parseSectionPort(self: *Evaluator, sf_children: []const Node, _: *env_mod.Env) !?env_mod.SectionPort {
    // (port "NET" in/out/io [signal-type] [voltage] [role R] [protocol P])
    if (sf_children.len < 3) return null;
    var port_name: []const u8 = "";
    var direction: env_mod.PortDirection = .in;
    var sig_type: env_mod.SignalType = .signal;
    var voltage: ?f64 = null;
    var role: []const u8 = "";
    var protocol: []const u8 = "";
    var group_list: std.ArrayListUnmanaged([]const u8) = .empty;

    var si: usize = 1;
    while (si < sf_children.len) : (si += 1) {
        const arg = sf_children[si];
        if (arg.asAtom()) |atom| {
            if (std.mem.eql(u8, atom, "role")) {
                si += 1;
                if (si < sf_children.len) role = sf_children[si].asAtom() orelse (sf_children[si].asString() orelse "");
                continue;
            } else if (std.mem.eql(u8, atom, "protocol")) {
                si += 1;
                if (si < sf_children.len) protocol = sf_children[si].asAtom() orelse (sf_children[si].asString() orelse "");
                continue;
            }
            // Direction keywords
            if (std.mem.eql(u8, atom, "in")) {
                direction = .in;
                continue;
            }
            if (std.mem.eql(u8, atom, "out")) {
                direction = .out;
                continue;
            }
            if (std.mem.eql(u8, atom, "io")) {
                direction = .io;
                continue;
            }
            // Signal type keywords
            if (std.mem.eql(u8, atom, "power")) {
                sig_type = .power;
                continue;
            }
            if (std.mem.eql(u8, atom, "signal")) {
                sig_type = .signal;
                continue;
            }
            if (std.mem.eql(u8, atom, "clock")) {
                sig_type = .clock;
                continue;
            }
            if (std.mem.eql(u8, atom, "data")) {
                sig_type = .data;
                continue;
            }
            if (std.mem.eql(u8, atom, "differential")) {
                sig_type = .differential;
                continue;
            }
            continue;
        }
        if (arg.asString()) |s| {
            if (port_name.len == 0) {
                port_name = s;
            } else {
                try group_list.append(self.allocator, s);
            }
        } else if (arg.asNumber()) |n| {
            voltage = n;
        }
    }
    if (port_name.len == 0) return null;
    return .{
        .name = port_name,
        .direction = direction,
        .signal_type = sig_type,
        .voltage = voltage,
        .group = group_list.toOwnedSlice(self.allocator) catch &.{},
        .role = role,
        .protocol = protocol,
    };
}

/// Parse (calc "name" (let ...) ...) block.
pub fn parseSectionCalc(self: *Evaluator, sf_children: []const Node, env: *env_mod.Env) !?env_mod.CalcBlock {
    if (sf_children.len < 2) return null;
    const calc_name_val = try self.evalNode(sf_children[1], env);
    const calc_name = calc_name_val.asString() orelse return null;
    var calc_env = env_mod.Env.init(self.allocator, env);
    var calc_results: std.ArrayListUnmanaged(env_mod.CalcResult) = .empty;

    for (sf_children[2..]) |cf| {
        const cf_children = cf.asList() orelse continue;
        if (cf_children.len == 0) continue;
        const cf_name = cf_children[0].asAtom() orelse continue;
        if (std.mem.eql(u8, cf_name, "let")) {
            if (cf_children.len >= 3) {
                const var_name = cf_children[1].asAtom() orelse continue;
                const var_val = try self.evalNode(cf_children[2], &calc_env);
                try calc_env.put(var_name, var_val);
                if (var_val.asNumber()) |n| try calc_results.append(self.allocator, .{ .name = var_name, .value = n });
            }
        } else if (std.mem.eql(u8, cf_name, "assert-range")) {
            if (cf_children.len >= 5) {
                const val = try self.evalNode(cf_children[1], &calc_env);
                const lo = try self.evalNode(cf_children[2], &calc_env);
                const hi = try self.evalNode(cf_children[3], &calc_env);
                const label_val = try self.evalNode(cf_children[4], &calc_env);
                const v = val.asNumber() orelse continue;
                const lo_v = lo.asNumber() orelse continue;
                const hi_v = hi.asNumber() orelse continue;
                const label = label_val.asString() orelse "?";
                const msg = std.fmt.allocPrint(self.allocator, "{s}: {d:.3} in [{d:.3}, {d:.3}]", .{ label, v, lo_v, hi_v }) catch continue;
                try self.assertions.append(self.allocator, .{ .passed = v >= lo_v and v <= hi_v, .message = msg });
            }
        } else if (std.mem.eql(u8, cf_name, "assert")) {
            if (cf_children.len >= 3) {
                const cond_val = try self.evalNode(cf_children[1], &calc_env);
                const msg_val = try self.evalNode(cf_children[2], &calc_env);
                const msg = msg_val.asString() orelse "assertion";
                try self.assertions.append(self.allocator, .{ .passed = cond_val.isTruthy(), .message = msg });
            }
        }
    }
    calc_env.deinit();
    return .{ .name = calc_name, .results = calc_results.toOwnedSlice(self.allocator) catch &.{} };
}

/// Find pin function map for an instance ref_des.
pub fn findPinFuncMap(self: *Evaluator, inst_items: []const Instance, pins_ref: []const u8) ?*const std.StringHashMapUnmanaged([]const u8) {
    for (inst_items) |inst| {
        if (std.mem.eql(u8, inst.ref_des, pins_ref)) {
            const comp_data = self.component_cache.get(inst.component);
            const pln = if (comp_data) |cd| (if (cd.pinout_name.len > 0) cd.pinout_name else cd.symbol_name) else inst.symbol;
            if (pln.len > 0) return ids.getSymbolPins(self, pln);
            break;
        }
    }
    return null;
}

/// Process a single pin or bus form inside a (pins ...) block.
pub fn processPinForm(
    self: *Evaluator,
    pin_form: Node,
    pins_ref: []const u8,
    pin_func_map: ?*const std.StringHashMapUnmanaged([]const u8),
    env: *env_mod.Env,
    all_pin_nets: *std.ArrayListUnmanaged(PinNetDecl),
    pg_pins: *std.ArrayListUnmanaged(env_mod.PartPin),
    net_ties: *std.ArrayListUnmanaged(NetTie),
) !void {
    if (pin_form.isForm("pin")) {
        const pin_children = pin_form.asList() orelse return;
        if (pin_children.len < 3) return;
        const net_val = try self.evalNode(pin_children[pin_children.len - 1], env);
        const net_name = net_val.asString() orelse return;
        for (pin_children[1 .. pin_children.len - 1]) |pin_node| {
            const raw = ids.pinId(self, pin_node) orelse continue;
            const pn = if (pin_func_map) |pm| (instance_mod.resolvePinName(self, pm, raw) orelse raw) else raw;
            try all_pin_nets.append(self.allocator, .{ .ref_des = pins_ref, .pin = pn, .net = net_name });
            try pg_pins.append(self.allocator, .{ .pin = pn, .net = net_name, .pin_name = if (pin_func_map) |m| (m.get(pn) orelse "") else "" });
            if (pin_func_map) |m| {
                if (m.get(pn)) |func_name| {
                    if (net_name.len > 0 and !std.mem.eql(u8, net_name, func_name))
                        try net_ties.append(self.allocator, .{ .a = net_name, .b = func_name });
                }
            }
        }
    } else if (pin_form.isForm("bus")) {
        const bus_children = pin_form.asList() orelse return;
        if (bus_children.len < 3) return;
        const bus_prefix_val = try self.evalNode(bus_children[1], env);
        const bus_prefix = bus_prefix_val.asString() orelse return;
        var bus_idx: u32 = 0;
        for (bus_children[2..]) |bus_node| {
            if (bus_node.asList()) |bus_list| {
                for (bus_list) |bp| {
                    const raw = ids.pinId(self, bp) orelse continue;
                    const pn = if (pin_func_map) |pm| (instance_mod.resolvePinName(self, pm, raw) orelse raw) else raw;
                    const bus_net = std.fmt.allocPrint(self.allocator, "{s}{d}", .{ bus_prefix, bus_idx }) catch continue;
                    try all_pin_nets.append(self.allocator, .{ .ref_des = pins_ref, .pin = pn, .net = bus_net });
                    try pg_pins.append(self.allocator, .{ .pin = pn, .net = bus_net, .pin_name = if (pin_func_map) |m| (m.get(pn) orelse "") else "" });
                    if (pin_func_map) |m| {
                        if (m.get(pn)) |func_name| {
                            if (bus_net.len > 0 and !std.mem.eql(u8, bus_net, func_name))
                                try net_ties.append(self.allocator, .{ .a = bus_net, .b = func_name });
                        }
                    }
                    bus_idx += 1;
                }
            } else {
                const raw = ids.pinId(self, bus_node) orelse continue;
                const pn = if (pin_func_map) |pm| (instance_mod.resolvePinName(self, pm, raw) orelse raw) else raw;
                const bus_net = std.fmt.allocPrint(self.allocator, "{s}{d}", .{ bus_prefix, bus_idx }) catch continue;
                try all_pin_nets.append(self.allocator, .{ .ref_des = pins_ref, .pin = pn, .net = bus_net });
                try pg_pins.append(self.allocator, .{ .pin = pn, .net = bus_net, .pin_name = if (pin_func_map) |m| (m.get(pn) orelse "") else "" });
                if (pin_func_map) |m| {
                    if (m.get(pn)) |func_name| {
                        if (bus_net.len > 0 and !std.mem.eql(u8, bus_net, func_name))
                            try net_ties.append(self.allocator, .{ .a = bus_net, .b = func_name });
                    }
                }
                bus_idx += 1;
            }
        }
    }
}

/// Emit decoupling cap instances from (comp "val") count/ref pairs.
pub fn emitDecoupleItems(
    self: *Evaluator,
    items: []const Node,
    net_name: []const u8,
    env: *Env,
    instances: *std.ArrayListUnmanaged(Instance),
    all_pin_nets: *std.ArrayListUnmanaged(PinNetDecl),
    decouple_id: []const u8,
    child_counter: *usize,
) EvalError!void {
    var idx: usize = 0;
    while (idx + 1 < items.len) {
        const comp_val = try self.evalNode(items[idx], env);
        const dec_comp_offset = ids.componentSourceOffset(items[idx]);

        const CompInfo = struct { comp: []const u8, value: []const u8, fp: []const u8, sym: []const u8, attrs: []const []const u8 };
        const comp_info: CompInfo = switch (comp_val) {
            .component => |c| blk: {
                const cd = self.component_cache.get(c) orelse break :blk .{ .comp = c, .value = "", .fp = "", .sym = "", .attrs = &.{} };
                break :blk .{ .comp = c, .value = "", .fp = cd.footprint_name, .sym = cd.symbol_name, .attrs = &.{} };
            },
            .component_instance => |ci| blk: {
                const cd = self.component_cache.get(ci.family) orelse break :blk .{ .comp = ci.family, .value = ci.value, .fp = "", .sym = "", .attrs = ci.attrs };
                break :blk .{ .comp = ci.family, .value = ci.value, .fp = cd.footprint_name, .sym = cd.symbol_name, .attrs = ci.attrs };
            },
            else => {
                idx += 2;
                continue;
            },
        };

        // Syntax: (comp "val") COUNT per-pin REF [PIN]
        // COUNT is required, per-pin keyword is required
        const count_val = items[idx + 1].asNumber() orelse {
            std.debug.print("Error: decouple requires a count after component (net: {s})\n", .{net_name});
            std.debug.print("  Use: (decouple \"{s}\" (comp \"val\") COUNT per-pin REF)\n", .{net_name});
            return EvalError.InvalidForm;
        };
        const count: u32 = @intFromFloat(count_val);
        if (count == 0) {
            idx += 2;
            continue;
        }

        // Expect "per-pin" keyword
        if (idx + 2 >= items.len) {
            idx += 2;
            continue;
        }
        const per_pin_kw = items[idx + 2].asAtom() orelse {
            std.debug.print("Error: decouple expects 'per-pin' keyword (net: {s})\n", .{net_name});
            return EvalError.InvalidForm;
        };
        if (!std.mem.eql(u8, per_pin_kw, "per-pin")) {
            std.debug.print("Error: decouple expects 'per-pin', got '{s}' (net: {s})\n", .{ per_pin_kw, net_name });
            return EvalError.InvalidForm;
        }

        // REF
        if (idx + 3 >= items.len) {
            idx += 3;
            continue;
        }
        const ref_str = items[idx + 3].asAtom() orelse
            (items[idx + 3].asString() orelse {
                idx += 4;
                continue;
            });

        // Check for optional pin specifier: ... REF PIN
        var specific_pin: ?[]const u8 = null;
        if (idx + 4 < items.len) {
            if (items[idx + 4].asList() == null) {
                if (ids.pinId(self, items[idx + 4])) |pid| {
                    specific_pin = pid;
                }
            }
        }

        const sub_prefix = try std.fmt.allocPrint(self.allocator, "{s}.{s}.", .{ net_name, ref_str });
        var target_pins: std.ArrayListUnmanaged([]const u8) = .empty;
        defer target_pins.deinit(self.allocator);

        if (specific_pin) |pin| {
            try target_pins.append(self.allocator, pin);
        } else {
            for (all_pin_nets.items) |pn| {
                if (!std.mem.eql(u8, pn.ref_des, ref_str)) continue;
                if (std.mem.eql(u8, pn.net, net_name) or std.mem.startsWith(u8, pn.net, sub_prefix)) {
                    try target_pins.append(self.allocator, pn.pin);
                }
            }
        }

        for (target_pins.items) |target_pin| {
            const sub_net = try std.fmt.allocPrint(self.allocator, "{s}.{s}.{s}", .{ net_name, ref_str, target_pin });

            var ci: u32 = 0;
            while (ci < count) : (ci += 1) {
                const ref = try ids.nextRefDes(self, 'C');
                const cap_id = try ids.deriveChildId(self, decouple_id, "", child_counter.*);
                child_counter.* += 1;
                try instances.append(self.allocator, .{
                    .ref_des = ref,
                    .component = comp_info.comp,
                    .value = comp_info.value,
                    .footprint = comp_info.fp,
                    .symbol = comp_info.sym,
                    .attrs = comp_info.attrs,
                    .source_offset = dec_comp_offset,
                    .id = cap_id,
                });
                try all_pin_nets.append(self.allocator, .{ .ref_des = ref, .pin = "1", .net = sub_net });
                try all_pin_nets.append(self.allocator, .{ .ref_des = ref, .pin = "2", .net = "GND" });
            }

            // Reassign the target component's pin to sub-net
            for (all_pin_nets.items) |*pn| {
                if (std.mem.eql(u8, pn.ref_des, ref_str) and
                    std.mem.eql(u8, pn.pin, target_pin) and
                    std.mem.eql(u8, pn.net, net_name))
                {
                    pn.net = sub_net;
                    break;
                }
            }
        }
        idx += if (specific_pin != null) @as(usize, 5) else @as(usize, 4);
    }
}

pub fn buildPort(self: *Evaluator, args: []const Node, env: *Env) EvalError!Port {
    if (args.len < 3) return EvalError.ArityError;
    const name_val = try self.evalNode(args[0], env);
    const net_val = try self.evalNode(args[1], env);
    const dir = args[2].asAtom() orelse return EvalError.InvalidForm;

    var rated_min: ?f64 = null;
    var rated_max: ?f64 = null;
    if (args.len >= 4 and args[3].isForm("rated")) {
        const rated_children = args[3].asList().?;
        if (rated_children.len >= 3) {
            rated_min = rated_children[1].asNumber();
            rated_max = rated_children[2].asNumber();
        }
    }

    return Port{
        .name = name_val.asString() orelse return EvalError.TypeError,
        .net = net_val.asString() orelse return EvalError.TypeError,
        .direction = dir,
        .rated_min = rated_min,
        .rated_max = rated_max,
    };
}

pub fn buildNote(self: *Evaluator, args: []const Node, env: *Env) EvalError!Note {
    if (args.len != 2) return EvalError.ArityError;
    const rd_val = try self.evalNode(args[0], env);
    const text_val = try self.evalNode(args[1], env);
    return Note{
        .ref_des = rd_val.asString() orelse return EvalError.TypeError,
        .text = text_val.asString() orelse return EvalError.TypeError,
    };
}

pub fn buildGroup(self: *Evaluator, args: []const Node, env: *Env) EvalError!Group {
    if (args.len != 2) return EvalError.ArityError;
    const name_val = try self.evalNode(args[0], env);
    const members_node = args[1].asList() orelse return EvalError.InvalidForm;

    var members: std.ArrayListUnmanaged([]const u8) = .empty;
    for (members_node) |m| {
        const s = m.asString() orelse return EvalError.TypeError;
        try members.append(self.allocator, s);
    }

    return Group{
        .name = name_val.asString() orelse return EvalError.TypeError,
        .members = members.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
    };
}

pub fn buildSubBlock(self: *Evaluator, args: []const Node, env: *Env) EvalError!SubBlock {
    if (args.len != 2) return EvalError.ArityError;
    const name_val = try self.evalNode(args[0], env);
    const name = name_val.asString() orelse return EvalError.TypeError;

    // Second arg is a module call: (module-name arg1 arg2 ...)
    const call_val = try self.evalNode(args[1], env);
    const block = switch (call_val) {
        .design_block => |b| b,
        else => return EvalError.TypeError,
    };

    return SubBlock{
        .name = name,
        .block = block,
    };
}

/// Add a named Part to the instance matching ref_des.
pub fn addPartToInstance(self: *Evaluator, instances: []Instance, ref_des: []const u8, part_name: []const u8, pins: []const env_mod.PartPin) EvalError!void {
    for (instances) |*inst| {
        if (std.mem.eql(u8, inst.ref_des, ref_des)) {
            var existing_parts: std.ArrayListUnmanaged(env_mod.Part) = .empty;
            for (inst.parts) |p| try existing_parts.append(self.allocator, p);
            try existing_parts.append(self.allocator, .{ .name = part_name, .pins = pins });
            inst.parts = existing_parts.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory;
            break;
        }
    }
}

// ── File loading ────────────────────────────────────────────────────

pub fn loadFile(self: *Evaluator, path: []const u8) ?[]const Node {
    if (self.loaded_files.get(path)) |nodes| return nodes;

    const source = std.fs.cwd().readFileAlloc(self.allocator, path, 10 * 1024 * 1024) catch return null;
    // Note: we don't free source because AST references slices into it
    const nodes = parser_mod.parse(self.allocator, source) catch return null;
    self.loaded_files.put(self.allocator, path, nodes) catch return null;
    return nodes;
}
