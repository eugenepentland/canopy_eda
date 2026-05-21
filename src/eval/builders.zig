const std = @import("std");
const infra_fs = @import("../infra/fs.zig");
const log = @import("../infra/log.zig");
const ast = @import("../sexpr/ast.zig");
const parser_mod = @import("../sexpr/parser.zig");
const env_mod = @import("env.zig");
const evaluator_mod = @import("evaluator.zig");
const Evaluator = evaluator_mod.Evaluator;
const EvalError = evaluator_mod.EvalError;
const PinNetDecl = evaluator_mod.PinNetDecl;
const NetTie = Evaluator.NetTie;
const ids = @import("ids.zig");
const instance_mod = @import("instance.zig");
const electrical = @import("electrical.zig");

const Node = ast.Node;
const Value = env_mod.Value;
const Env = env_mod.Env;
const Instance = env_mod.Instance;
const Port = env_mod.Port;
const Note = env_mod.Note;
const Group = env_mod.Group;
const SubBlock = env_mod.SubBlock;

// ── Constants ─────────────────────────────────────────────────────
const ASSERT_RANGE_ARITY: usize = 5;
const PIN_DECL_STRIDE_WITH_REF: usize = 5;

/// Parse (port "NET" in/out/io ...) section port declaration.
pub fn parseSectionPort(self: *Evaluator, sf_children: []const Node, _: *env_mod.Env) EvalError!?env_mod.SectionPort {
    // (port "NET" in/out/io [signal-type] [voltage] [role R] [protocol P])
    if (sf_children.len < 3) return null;
    var port_name: []const u8 = "";
    var direction: env_mod.PortDirection = .in;
    var sig_type: env_mod.SignalType = .signal;
    var voltage: ?f64 = null;
    var role: []const u8 = "";
    var protocol: []const u8 = "";
    var group_list: std.ArrayListUnmanaged([]const u8) = .empty;
    var is_optional: bool = false;

    var elec: ?env_mod.ElectricalDecl = null;
    var si: usize = 1;
    while (si < sf_children.len) : (si += 1) {
        const arg = sf_children[si];
        if (arg.isForm("electrical")) {
            const ec = arg.asList().?;
            // The port form has no positional pin-name argument — the port's
            // own name fills that role for ERC purposes. Caller sets `.pin`
            // below once we know `port_name`.
            var decl = env_mod.ElectricalDecl{ .pin = "" };
            electrical.parseSubForms(&decl, ec[1..]);
            elec = decl;
            continue;
        }
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
            if (std.mem.eql(u8, atom, "optional")) {
                is_optional = true;
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
    if (elec) |*d| d.pin = port_name;
    return .{
        .name = port_name,
        .direction = direction,
        .signal_type = sig_type,
        .voltage = voltage,
        .group = group_list.toOwnedSlice(self.allocator) catch &.{},
        .role = role,
        .protocol = protocol,
        .optional = is_optional,
        .electrical = elec,
    };
}

/// Expand `(bus-port "PREFIX" START END [(suffixes A B)] …)` into a list
/// of fully-built `SectionPort`s. The trailing modifiers (direction,
/// signal-type, voltage, role, etc.) are reused verbatim across every
/// generated port so the user pays one line for what used to be N×M
/// `(port …)` declarations. When the optional `(suffixes …)` form is
/// missing, one port per index is generated.
pub fn expandSectionBusPort(
    self: *Evaluator,
    bp_children: []const Node,
    env: *env_mod.Env,
    out: *std.ArrayListUnmanaged(env_mod.SectionPort),
) EvalError!void {
    const exp = try parseBusPortHeader(self, bp_children, env) orelse return;
    var idx: i64 = exp.start;
    while (idx <= exp.end) : (idx += 1) {
        for (exp.suffixes) |suf| {
            const name = std.fmt.allocPrint(self.allocator, "{s}{d}{s}", .{ exp.prefix, idx, suf }) catch return EvalError.OutOfMemory;
            // parseSectionPort treats children[0] as the leading form
            // atom (`port`) and skips it; prepend a dummy atom to match.
            const children = try synthesizeSectionPortChildren(self.allocator, name, exp.rest);
            if (try parseSectionPort(self, children, env)) |p| {
                try out.append(self.allocator, p);
            }
        }
    }
}

/// Top-level variant of `expandSectionBusPort` — calls `buildPort` per
/// synthesized name so the resulting ports plug into a design-block
/// top-level `ports` list.
pub fn expandTopLevelBusPort(
    self: *Evaluator,
    bp_children: []const Node,
    env: *Env,
    out: *std.ArrayListUnmanaged(Port),
) EvalError!void {
    const exp = try parseBusPortHeader(self, bp_children, env) orelse return;
    var idx: i64 = exp.start;
    while (idx <= exp.end) : (idx += 1) {
        for (exp.suffixes) |suf| {
            const name = std.fmt.allocPrint(self.allocator, "{s}{d}{s}", .{ exp.prefix, idx, suf }) catch return EvalError.OutOfMemory;
            // buildPort takes `args` with the name at args[0], no
            // leading `port` atom.
            const args = try synthesizeBuildPortArgs(self.allocator, name, exp.rest);
            const port = try buildPort(self, args, env);
            try out.append(self.allocator, port);
        }
    }
}

const BusPortExpansion = struct {
    prefix: []const u8,
    start: i64,
    end: i64,
    /// Suffix list — single empty string when caller omitted `(suffixes …)`
    /// so the expansion loop emits one port per index.
    suffixes: []const []const u8,
    /// All port modifier children (direction, signal-type, voltage, etc.)
    /// to splice in after the synthesized name.
    rest: []const Node,
};

fn parseBusPortHeader(self: *Evaluator, bp_children: []const Node, env: *Env) EvalError!?BusPortExpansion {
    // bp_children[0] is the "bus-port" atom; positional 1..3 are prefix,
    // start, end. Position 4 is the optional `(suffixes A B)` form OR
    // the first port modifier.
    if (bp_children.len < 4) return null;
    const prefix_val = try self.evalNode(bp_children[1], env);
    const prefix = prefix_val.asString() orelse return null;
    const start_val = try self.evalNode(bp_children[2], env);
    const end_val = try self.evalNode(bp_children[3], env);
    const start_f = start_val.asNumber() orelse return null;
    const end_f = end_val.asNumber() orelse return null;
    if (end_f < start_f) return null;

    var rest_start: usize = 4;
    var suffixes: []const []const u8 = &.{""};
    if (bp_children.len > 4 and bp_children[4].isForm("suffixes")) {
        const sf = bp_children[4].asList().?;
        var suf_buf: std.ArrayListUnmanaged([]const u8) = .empty;
        for (sf[1..]) |s| {
            const text = s.asAtom() orelse s.asString() orelse continue;
            try suf_buf.append(self.allocator, text);
        }
        if (suf_buf.items.len > 0) {
            suffixes = suf_buf.toOwnedSlice(self.allocator) catch &.{""};
        }
        rest_start = 5;
    }
    return .{
        .prefix = prefix,
        .start = @intFromFloat(start_f),
        .end = @intFromFloat(end_f),
        .suffixes = suffixes,
        .rest = bp_children[rest_start..],
    };
}

/// Build a children slice for `parseSectionPort`: leading dummy `port`
/// atom (the parser skips index 0), then the synthesized name, then the
/// shared modifier children.
fn synthesizeSectionPortChildren(allocator: std.mem.Allocator, name: []const u8, rest: []const Node) EvalError![]Node {
    var buf: std.ArrayListUnmanaged(Node) = .empty;
    try buf.append(allocator, Node.atom(ast.Span.zero, "port"));
    try buf.append(allocator, Node.string(ast.Span.zero, name));
    for (rest) |n| try buf.append(allocator, n);
    return buf.toOwnedSlice(allocator) catch EvalError.OutOfMemory;
}

/// Build an args slice for `buildPort`: the synthesized name at args[0]
/// (no leading `port` atom — buildPort's contract differs from
/// parseSectionPort's), then the shared modifier children.
fn synthesizeBuildPortArgs(allocator: std.mem.Allocator, name: []const u8, rest: []const Node) EvalError![]Node {
    var buf: std.ArrayListUnmanaged(Node) = .empty;
    try buf.append(allocator, Node.string(ast.Span.zero, name));
    for (rest) |n| try buf.append(allocator, n);
    return buf.toOwnedSlice(allocator) catch EvalError.OutOfMemory;
}

/// Parse (calc "name" (let ...) ...) block.
pub fn parseSectionCalc(self: *Evaluator, sf_children: []const Node, env: *env_mod.Env) EvalError!?env_mod.CalcBlock {
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
            if (cf_children.len >= ASSERT_RANGE_ARITY) {
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
) EvalError!void {
    if (pin_form.isForm("pin")) {
        const pin_children = pin_form.asList() orelse return;
        if (pin_children.len < 3) return;

        // Trailing (i-typ …)/(i-max …) annotations sit after the net name.
        var tail: usize = pin_children.len;
        var i_typ: ?f64 = null;
        var i_max: ?f64 = null;
        while (tail > 0) {
            const last = pin_children[tail - 1];
            if (last.isForm("i-typ")) {
                const cc = last.asList().?;
                if (cc.len >= 2) i_typ = cc[1].asNumber();
                tail -= 1;
            } else if (last.isForm("i-max")) {
                const cc = last.asList().?;
                if (cc.len >= 2) i_max = cc[1].asNumber();
                tail -= 1;
            } else break;
        }
        if (tail < 3) return;

        const net_val = try self.evalNode(pin_children[tail - 1], env);
        const net_name = net_val.asString() orelse return;

        var asserted_buf: std.ArrayListUnmanaged([]const u8) = .empty;
        var pin_count: usize = 0;
        for (pin_children[1 .. tail - 1]) |child| {
            if (child.isForm("as")) {
                const ac = child.asList().?;
                for (ac[1..]) |arg| {
                    const val = try self.evalNode(arg, env);
                    const name = val.asString() orelse (arg.asAtom() orelse "");
                    if (name.len == 0) continue;
                    try asserted_buf.append(self.allocator, name);
                }
            } else {
                pin_count += 1;
            }
        }
        const asserted_fns: []const []const u8 = if (pin_count == 1)
            (asserted_buf.toOwnedSlice(self.allocator) catch &.{})
        else
            &.{};

        var first_pin = true;
        for (pin_children[1 .. tail - 1]) |pin_node| {
            if (pin_node.isForm("as")) continue;
            const raw = ids.pinId(self, pin_node) orelse continue;
            const pn = if (pin_func_map) |pm| (instance_mod.resolvePinName(self, pm, raw) orelse raw) else raw;
            try all_pin_nets.append(self.allocator, .{
                .ref_des = pins_ref,
                .pin = pn,
                .net = net_name,
                .asserted_fns = asserted_fns,
                .i_typ = if (first_pin) i_typ else null,
                .i_max = if (first_pin) i_max else null,
            });
            try pg_pins.append(self.allocator, .{ .pin = pn, .net = net_name, .pin_name = if (pin_func_map) |m| (m.get(pn) orelse "") else "" });
            if (pin_func_map) |m| {
                if (m.get(pn)) |func_name| {
                    if (net_name.len > 0 and !std.mem.eql(u8, net_name, func_name))
                        try net_ties.append(self.allocator, .{ .a = net_name, .b = func_name, .is_auto = true });
                }
            }
            first_pin = false;
        }
    } else if (pin_form.isForm("bus")) {
        const bus_children = pin_form.asList() orelse return;
        if (bus_children.len < 3) return;
        const bus_prefix_val = try self.evalNode(bus_children[1], env);
        const bus_prefix = bus_prefix_val.asString() orelse return;
        // Optional `(as-prefix "XSPIM_P2_IO")` — auto-asserts each pin as
        // `<prefix><bus-idx>` so the design doesn't have to expand a wide bus
        // into one (pin ...) form per lane just to pass the pin-function check.
        var as_prefix: []const u8 = "";
        for (bus_children[2..]) |child| {
            if (child.isForm("as-prefix")) {
                const ac = child.asList().?;
                if (ac.len >= 2) {
                    const v = try self.evalNode(ac[1], env);
                    as_prefix = v.asString() orelse (ac[1].asAtom() orelse "");
                }
            }
        }
        var bus_idx: u32 = 0;
        for (bus_children[2..]) |bus_node| {
            if (bus_node.isForm("as-prefix")) continue;
            if (bus_node.asList()) |bus_list| {
                for (bus_list) |bp| {
                    const raw = ids.pinId(self, bp) orelse continue;
                    const pn = if (pin_func_map) |pm| (instance_mod.resolvePinName(self, pm, raw) orelse raw) else raw;
                    const bus_net = std.fmt.allocPrint(self.allocator, "{s}{d}", .{ bus_prefix, bus_idx }) catch continue;
                    const asserted: []const []const u8 = if (as_prefix.len > 0) blk: {
                        const name = std.fmt.allocPrint(self.allocator, "{s}{d}", .{ as_prefix, bus_idx }) catch break :blk &.{};
                        const slot = self.allocator.alloc([]const u8, 1) catch break :blk &.{};
                        slot[0] = name;
                        break :blk slot;
                    } else &.{};
                    try all_pin_nets.append(self.allocator, .{ .ref_des = pins_ref, .pin = pn, .net = bus_net, .asserted_fns = asserted });
                    try pg_pins.append(self.allocator, .{ .pin = pn, .net = bus_net, .pin_name = if (pin_func_map) |m| (m.get(pn) orelse "") else "" });
                    if (pin_func_map) |m| {
                        if (m.get(pn)) |func_name| {
                            if (bus_net.len > 0 and !std.mem.eql(u8, bus_net, func_name))
                                try net_ties.append(self.allocator, .{ .a = bus_net, .b = func_name, .is_auto = true });
                        }
                    }
                    bus_idx += 1;
                }
            } else {
                const raw = ids.pinId(self, bus_node) orelse continue;
                const pn = if (pin_func_map) |pm| (instance_mod.resolvePinName(self, pm, raw) orelse raw) else raw;
                const bus_net = std.fmt.allocPrint(self.allocator, "{s}{d}", .{ bus_prefix, bus_idx }) catch continue;
                const asserted: []const []const u8 = if (as_prefix.len > 0) blk: {
                    const name = std.fmt.allocPrint(self.allocator, "{s}{d}", .{ as_prefix, bus_idx }) catch break :blk &.{};
                    const slot = self.allocator.alloc([]const u8, 1) catch break :blk &.{};
                    slot[0] = name;
                    break :blk slot;
                } else &.{};
                try all_pin_nets.append(self.allocator, .{ .ref_des = pins_ref, .pin = pn, .net = bus_net, .asserted_fns = asserted });
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
///
/// Each cap's id is keyed on the renumber-proof structural key
/// `value@pad#replica`. How that key becomes an id depends on the design's
/// identity mode: under `(hierarchical-ids)` it is derived from the decouple
/// form's own `(id …)` (`form_id`) — one source uuid covers every child, no
/// `(ids …)` sidecar — mirroring the Option-4 sub-block path. Otherwise the
/// child token is taken from / minted into the enumerated `(ids …)` sidecar.
pub fn emitDecoupleItems(
    self: *Evaluator,
    items: []const Node,
    net_name: []const u8,
    env: *Env,
    instances: *std.ArrayListUnmanaged(Instance),
    all_pin_nets: *std.ArrayListUnmanaged(PinNetDecl),
    form_id: []const u8,
    sidecar: *ids.ChildIdSidecar,
) EvalError!void {
    var idx: usize = 0;
    while (idx + 1 < items.len) {
        const comp_val = try self.evalNode(items[idx], env);
        const dec_comp_offset = ids.componentSourceOffset(items[idx]);

        const resolved = instance_mod.resolveComponent(self, comp_val) orelse {
            idx += 2;
            continue;
        };

        // Syntax: (comp "val") COUNT per-pin REF [PIN]
        // COUNT is required, per-pin keyword is required
        const count_val = items[idx + 1].asNumber() orelse {
            log.warn("decouple requires a count after component (net: {s})", .{net_name});
            log.warn("  Use: (decouple \"{s}\" (comp \"val\") COUNT per-pin REF)", .{net_name});
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
            log.warn("decouple expects 'per-pin' keyword (net: {s})", .{net_name});
            return EvalError.InvalidForm;
        };
        if (!std.mem.eql(u8, per_pin_kw, "per-pin")) {
            log.warn("decouple expects 'per-pin', got '{s}' (net: {s})", .{ per_pin_kw, net_name });
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
                // Stable structural key: value @ host pad # replica. Pad names
                // don't churn on net rename, so the child token survives it.
                const child_key = try std.fmt.allocPrint(self.allocator, "{s}@{s}#{d}", .{ resolved.value, target_pin, ci });
                // Hierarchical designs derive every child id from the form's own
                // uuid + this stable key (no sidecar); legacy designs pin the
                // token in the enumerated (ids …) sidecar.
                const cap_id = if (self.hierarchical_ids)
                    try ids.deriveChildId(self, form_id, child_key, 0)
                else
                    try ids.getOrCreateChildId(self, sidecar, child_key);
                try instances.append(self.allocator, .{
                    .ref_des = ref,
                    .origin_key = child_key, // stable structural key for hierarchical sub-block ids
                    .component = resolved.family,
                    .value = resolved.value,
                    .footprint = resolved.footprint,
                    .symbol = resolved.symbol,
                    .attrs = resolved.attrs,
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
        idx += if (specific_pin != null) @as(usize, PIN_DECL_STRIDE_WITH_REF) else @as(usize, 4);
    }
}

fn isDirectionKeyword(s: []const u8) bool {
    return std.mem.eql(u8, s, "in") or std.mem.eql(u8, s, "out") or
        std.mem.eql(u8, s, "io") or std.mem.eql(u8, s, "bidi");
}

/// Parse a `(port "NAME" [net] dir ...)` form into a `Port`. Accepts the
/// short form (net = name) and the long form with explicit net string, plus
/// the optional `(rated …)`, `(nominal …)`, `(current …)`, `(efficiency …)`,
/// and `(enable …)` sub-clauses that drive the power-budget analyzer.
pub fn buildPort(self: *Evaluator, args: []const Node, env: *Env) EvalError!Port {
    if (args.len < 2) return EvalError.ArityError;
    const name_val = try self.evalNode(args[0], env);
    const name = name_val.asString() orelse return EvalError.TypeError;

    // Short form: (port "NAME" direction ...) — net = name
    // Long form:  (port "NAME" "NET" direction ...) — explicit net
    var net: []const u8 = name;
    var dir_idx: usize = 1;

    if (args[1].asAtom()) |atom| {
        if (isDirectionKeyword(atom)) {
            // Short form: args[1] is the direction
            dir_idx = 1;
        } else {
            // Could be a non-direction atom — treat as long form
            const net_val = try self.evalNode(args[1], env);
            net = net_val.asString() orelse return EvalError.TypeError;
            dir_idx = 2;
        }
    } else if (args[1].asString()) |s| {
        // Long form: args[1] is net name string
        net = s;
        dir_idx = 2;
    } else {
        return EvalError.InvalidForm;
    }

    if (dir_idx >= args.len) return EvalError.ArityError;
    const dir = args[dir_idx].asAtom() orelse return EvalError.InvalidForm;

    // Warn when long form is used with identical name and net
    if (dir_idx == 2 and std.mem.eql(u8, name, net)) {
        const msg = std.fmt.allocPrint(
            self.allocator,
            "Port \"{s}\" has identical name and net — use short form: (port \"{s}\" {s} ...)",
            .{ name, name, dir },
        ) catch "";
        if (msg.len > 0) try self.assertions.append(self.allocator, .{ .passed = false, .message = msg, .is_warning = true });
    }

    var rated_min: ?f64 = null;
    var rated_max: ?f64 = null;
    var nominal: ?f64 = null;
    var current_typ: ?f64 = null;
    var current_max: ?f64 = null;
    var efficiency: ?f64 = null;
    var efficiency_linear: bool = false;
    var enable_net: []const u8 = "";
    var is_optional: bool = false;
    var elec: ?env_mod.ElectricalDecl = null;
    for (args[dir_idx + 1 ..]) |arg| {
        if (arg.isForm("electrical")) {
            const ec = arg.asList().?;
            var decl = env_mod.ElectricalDecl{ .pin = name };
            electrical.parseSubForms(&decl, ec[1..]);
            elec = decl;
            continue;
        }
        if (arg.isForm("rated")) {
            const rated_children = arg.asList().?;
            if (rated_children.len >= 3) {
                rated_min = rated_children[1].asNumber();
                rated_max = rated_children[2].asNumber();
            }
        } else if (arg.isForm("nominal")) {
            const nom_children = arg.asList().?;
            if (nom_children.len >= 2) {
                nominal = nom_children[1].asNumber();
            }
        } else if (arg.isForm("current")) {
            const cc = arg.asList().?;
            if (cc.len >= 3) {
                current_typ = cc[1].asNumber();
                current_max = cc[2].asNumber();
            } else if (cc.len == 2) {
                current_typ = cc[1].asNumber();
            }
        } else if (arg.isForm("efficiency")) {
            const ec = arg.asList().?;
            if (ec.len >= 2) {
                if (ec[1].asAtom()) |atom| {
                    if (std.mem.eql(u8, atom, "linear")) efficiency_linear = true;
                } else {
                    efficiency = ec[1].asNumber();
                }
            }
        } else if (arg.isForm("enable")) {
            const ec = arg.asList().?;
            if (ec.len >= 2) {
                const en_val = try self.evalNode(ec[1], env);
                enable_net = en_val.asString() orelse (ec[1].asAtom() orelse "");
            }
        } else if (arg.asAtom()) |kw| {
            if (std.mem.eql(u8, kw, "optional")) is_optional = true;
        }
    }

    return Port{
        .name = name,
        .net = net,
        .direction = dir,
        .rated_min = rated_min,
        .rated_max = rated_max,
        .nominal = nominal,
        .current_typ = current_typ,
        .current_max = current_max,
        .efficiency = efficiency,
        .efficiency_linear = efficiency_linear,
        .enable_net = enable_net,
        .optional = is_optional,
        .electrical = elec,
    };
}

/// Build a `(note "REFDES" "text")` annotation that the schematic renderer
/// pins next to the named instance. Both arguments must evaluate to strings.
pub fn buildNote(self: *Evaluator, args: []const Node, env: *Env) EvalError!Note {
    if (args.len != 2) return EvalError.ArityError;
    const rd_val = try self.evalNode(args[0], env);
    const text_val = try self.evalNode(args[1], env);
    return Note{
        .ref_des = rd_val.asString() orelse return EvalError.TypeError,
        .text = text_val.asString() orelse return EvalError.TypeError,
    };
}

/// Build a `(group "name" ("R1" "R2" ...))` form into a `Group` that bundles
/// a set of ref-deses for the schematic renderer's visual grouping pass.
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

/// Build a `(sub-block "name" <expr>)` reference, evaluating the expression
/// either as a `.sexp` file path or a module call that returns a DesignBlock,
/// then re-deriving every nested instance ID from the sub-block's name so
/// IDs stay stable across rebuilds and never leak into the parent's pending
/// pending-ID write-back list.
pub fn buildSubBlock(self: *Evaluator, form_children: []const Node, env: *Env) EvalError!SubBlock {
    // form_children = the whole `(sub-block "name" (call …) [(ids …)])` form.
    // args drops the "sub-block" head; an optional trailing `(ids …)` sidecar
    // carries source-resident child ids (read by parseChildIdSidecar below).
    const args = form_children[1..];
    if (args.len < 2) return EvalError.ArityError;
    const name_val = try self.evalNode(args[0], env);
    const name = name_val.asString() orelse return EvalError.TypeError;

    // Second arg can be:
    //   1. A string literal = file path to a design-block .sexp file
    //   2. A module call expression = (module-name arg1 arg2 ...)
    //
    // Module / file evaluation generates random IDs for instances and appends
    // them to `pending_ids` with offsets that are in the sub-block's source
    // buffer (module file or sub-block .sexp), NOT the top-level board file.
    // commands.zig only knows how to write pending IDs back to the board
    // file, so those module-scope entries would silently drop or, worse,
    // land on matching `(` bytes in the board file and corrupt it.
    //
    // Track the length before/after the sub-block evaluates and discard any
    // entries it pushed. Then replace each instance's random ID with a
    // deterministic derivation from the sub-block's name and the instance's
    // module-local ref_des so UUIDs are stable across builds.
    const pending_pre = self.pending_ids.items.len;
    const pending_child_pre = self.pending_child_ids.items.len;
    // Track where the sub-block came from so the schematic page can offer a
    // "copy source" button and `/modules` can locate the file: a project-
    // relative path for the string form, or the module name for a call form.
    var source: []const u8 = "";
    const block = blk: {
        if (args[1].asString()) |file_path_raw| {
            source = file_path_raw;
            const full_path = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ self.project_dir, file_path_raw }) catch return EvalError.OutOfMemory;
            const result = self.evalFile(full_path) catch return EvalError.ImportError;
            switch (result) {
                .design_block => |b| break :blk b,
                else => return EvalError.TypeError,
            }
        }
        if (args[1].asList()) |call_children| {
            if (call_children.len > 0) {
                if (call_children[0].asAtom()) |mod_name| source = mod_name;
            }
        }
        const call_val = try self.evalNode(args[1], env);
        switch (call_val) {
            .design_block => |b| break :blk b,
            else => return EvalError.TypeError,
        }
    };
    // Discard the module-scope id writes the sub-block evaluation pushed (their
    // offsets point into the module file, which the board-file writer can't
    // safely touch). The reassign step below stamps deterministic ids instead.
    self.pending_ids.items.len = pending_pre;
    self.pending_child_ids.items.len = pending_child_pre;
    // Identity model:
    //   • design declared `(hierarchical-ids)` → Option 4: one auto-minted uuid
    //     per sub-block (written to the design file), each child id derived as
    //     deriveChildId(subblock_uuid, child.origin_key). Modules need no
    //     annotation — the child's stable key comes from its source.
    //   • otherwise → legacy `(ids …)` sidecar enumerating every child id at
    //     this call site (frozen, keyed on the seed-time ref-des).
    if (self.hierarchical_ids) {
        const subblock_uuid = try ids.getOrCreateFormId(self, form_children);
        try ids.reassignSubBlockIdsV4(self, block, subblock_uuid);
    } else {
        var sidecar = ids.parseChildIdSidecar(self, form_children);
        try ids.reassignSubBlockIds(self, block, name, &sidecar, "");
    }

    return SubBlock{
        .name = name,
        .block = block,
        .source = source,
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

/// Read and parse a `.sexp` file, returning its top-level AST nodes. Caches
/// by path so the same file evaluated from multiple `(import …)` sites only
/// hits disk once. The source buffer is intentionally never freed because
/// AST node strings reference slices into it.
pub fn loadFile(self: *Evaluator, path: []const u8) ?[]const Node {
    if (self.loaded_files.get(path)) |nodes| return nodes;

    const source = infra_fs.cwd().readFileAlloc(self.allocator, path, 10 * 1024 * 1024) catch return null;
    // Note: we don't free source because AST references slices into it
    const nodes = parser_mod.parse(self.allocator, source) catch return null;
    self.loaded_files.put(self.allocator, path, nodes) catch return null;
    return nodes;
}

/// Load a top-level design file. Wraps `loadFile` with an autoloader for a
/// sibling `<path-without-.sexp>.checks.sexp` file: when present, its
/// top-level forms are spliced into the trailing `(design-block …)` form's
/// body before evaluation. This lets a design's verification entries live
/// next to the schematic instead of inside it.
///
/// Library imports continue to call `loadFile` directly so module files
/// don't get checks-spliced.
pub fn loadDesignFile(self: *Evaluator, path: []const u8) ?[]const Node {
    const nodes = loadFile(self, path) orelse return null;
    if (!std.mem.endsWith(u8, path, ".sexp")) return nodes;

    const stem = path[0 .. path.len - ".sexp".len];
    const checks_path = std.fmt.allocPrint(self.allocator, "{s}.checks.sexp", .{stem}) catch return nodes;
    infra_fs.cwd().access(checks_path, .{}) catch {
        self.allocator.free(checks_path);
        return nodes;
    };

    const checks_nodes = loadFile(self, checks_path) orelse return nodes;

    return spliceChecksIntoDesignBlock(self, nodes, checks_nodes) orelse nodes;
}

/// Build a new top-level node slice where the design-block form's children
/// have the checks-file forms appended. Returns null when the file has no
/// design-block to splice into (e.g. a `(board …)` source) — the caller
/// should fall back to the original node list in that case.
fn spliceChecksIntoDesignBlock(
    self: *Evaluator,
    nodes: []const Node,
    checks_nodes: []const Node,
) ?[]const Node {
    var design_idx: ?usize = null;
    for (nodes, 0..) |n, i| if (n.isForm("design-block")) {
        design_idx = i;
        break;
    };
    const di = design_idx orelse return null;

    const original_children = nodes[di].asList() orelse return null;
    const merged_children = self.allocator.alloc(Node, original_children.len + checks_nodes.len) catch return null;
    @memcpy(merged_children[0..original_children.len], original_children);
    @memcpy(merged_children[original_children.len..], checks_nodes);

    const merged_top = self.allocator.alloc(Node, nodes.len) catch return null;
    @memcpy(merged_top, nodes);
    merged_top[di] = Node.list(nodes[di].span, merged_children);
    return merged_top;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// Register a minimal component family so `(name "val")` evaluates to a
/// `component_instance` without needing lib/components/ fixtures on disk.
fn putTestFamily(eval: *Evaluator, alloc: std.mem.Allocator, name: []const u8) !void {
    try eval.component_cache.put(alloc, name, .{
        .name = name,
        .symbol_name = "",
        .footprint_name = "",
        .is_family = true,
        .param_type = "",
    });
}

// spec: eval/evaluator - hierarchical-ids derives decouple child ids from the form id instead of the (ids ...) sidecar
test "hierarchical decouple derives child ids from form id" {
    // page_allocator: evaluator-allocated keys/ids are intentionally never freed.
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    eval.hierarchical_ids = true;
    var env = env_mod.Env.init(alloc, null);
    defer env.deinit();
    try putTestFamily(&eval, alloc, "cap-0201");

    const nodes = try parser_mod.parse(alloc, "(cap-0201 \"100nF\") 1 per-pin U1 7");
    var instances: std.ArrayListUnmanaged(Instance) = .empty;
    var all_pin_nets: std.ArrayListUnmanaged(PinNetDecl) = .empty;
    var sidecar = ids.ChildIdSidecar{ .map = .empty, .parent_offset = 0 };

    try emitDecoupleItems(&eval, nodes, "VDD", &env, &instances, &all_pin_nets, "abcd1234", &sidecar);

    try testing.expectEqual(@as(usize, 1), instances.items.len);
    const expected = try ids.deriveChildId(&eval, "abcd1234", "100nF@7#0", 0);
    try testing.expectEqualStrings(expected, instances.items[0].id);
    try testing.expectEqualStrings("100nF@7#0", instances.items[0].origin_key);
    // Hierarchical mode never consults or writes the sidecar.
    try testing.expectEqual(@as(usize, 0), eval.pending_child_ids.items.len);
}

// spec: eval/evaluator - without hierarchical-ids decouple child ids come from the (ids ...) sidecar
test "legacy decouple takes child ids from the sidecar" {
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var env = env_mod.Env.init(alloc, null);
    defer env.deinit();
    try putTestFamily(&eval, alloc, "cap-0201");

    const nodes = try parser_mod.parse(alloc, "(cap-0201 \"100nF\") 1 per-pin U1 7");
    var instances: std.ArrayListUnmanaged(Instance) = .empty;
    var all_pin_nets: std.ArrayListUnmanaged(PinNetDecl) = .empty;
    var sidecar = ids.ChildIdSidecar{ .map = .empty, .parent_offset = 0 };
    try sidecar.map.put(alloc, "100nF@7#0", "deadbeef");

    try emitDecoupleItems(&eval, nodes, "VDD", &env, &instances, &all_pin_nets, "abcd1234", &sidecar);

    try testing.expectEqual(@as(usize, 1), instances.items.len);
    // Legacy mode pins the token from the sidecar, not a derivation off the form id.
    try testing.expectEqualStrings("deadbeef", instances.items[0].id);
}
