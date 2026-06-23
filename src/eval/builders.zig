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

/// The head atom of a list form, for warning messages — `"?"` when the
/// node isn't a list or its head isn't an atom.
fn formHeadName(node: Node) []const u8 {
    const l = node.asList() orelse return "?";
    if (l.len == 0) return "?";
    return l[0].asAtom() orelse "?";
}

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
    var class_key: []const u8 = "";
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
                if (si < sf_children.len) role = sf_children[si].asText() orelse "";
                continue;
            } else if (std.mem.eql(u8, atom, "protocol")) {
                si += 1;
                if (si < sf_children.len) protocol = sf_children[si].asText() orelse "";
                continue;
            } else if (std.mem.eql(u8, atom, "class")) {
                si += 1;
                if (si < sf_children.len) class_key = sf_children[si].asText() orelse "";
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
            // `bidi` is the documented synonym for `io` (bidirectional) — accept
            // it here too so section ports match the design-block port form.
            if (std.mem.eql(u8, atom, "bidi")) {
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
            if (std.mem.eql(u8, atom, "rf")) {
                sig_type = .rf;
                continue;
            }
            if (std.mem.eql(u8, atom, "optional")) {
                is_optional = true;
                continue;
            }
            self.warnFmt(arg.span, "unknown port option '{s}' in (port …)", .{atom});
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
        } else if (arg.asList() != null) {
            self.warnFmt(arg.span, "unknown sub-form ({s} …) in (port …)", .{formHeadName(arg)});
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
        .class = class_key,
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
            const text = s.asText() orelse continue;
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

        // Trailing (i-typ …)/(i-max …)/(load …) annotations + (as …) assertions
        // are parsed by the shared helpers so this `(pins …)` path and the inline
        // `(instance … (pin …))` path can't drift.
        const t = try instance_mod.parsePinTail(self, pin_children, env);
        const tail = t.tail;
        const i_typ = t.i_typ;
        const i_max = t.i_max;
        const load_label = t.load_label;
        if (tail < 3) return;

        const net_val = try self.evalNode(pin_children[tail - 1], env);
        const net_name = net_val.asString() orelse return;

        const asserted_fns = try instance_mod.scanAssertedFns(self, pin_children[1 .. tail - 1], env);

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
                .load_label = if (first_pin) load_label else "",
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

/// True when a child of a `(pins …)` block is one of the recognised forms
/// (`pin`/`bus`/`group`). Callers warn-and-skip anything else — those forms
/// used to be silently dead.
pub fn isKnownPinsChild(node: Node) bool {
    return node.isForm("pin") or node.isForm("bus") or node.isForm("group");
}

/// Record the unknown-sub-form warning for a non-pin/bus/group child of a
/// `(pins …)` block.
pub fn warnUnknownPinsChild(self: *Evaluator, node: Node) void {
    self.warnFmt(node.span, "unknown sub-form ({s} …) in (pins …) — expected (pin …) or (bus …)", .{formHeadName(node)});
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
    while (idx < items.len) {
        // ── Component ── an explicit `(comp …)`/atom, or the per-design bypass
        // default when a bare count leads (component omitted). The default is
        // consulted only when one was set via `(decouple-defaults (bypass …))`.
        const comp_omitted = items[idx].asNumber() != null;
        const comp_node = if (comp_omitted)
            (self.decouple_defaults.bypass orelse {
                log.warn("decouple omits its component but no (decouple-defaults (bypass …)) is set (net: {s})", .{net_name});
                return EvalError.InvalidForm;
            })
        else
            items[idx];
        const comp_val = try self.evalNode(comp_node, env);
        const dec_comp_offset = ids.componentSourceOffset(comp_node);
        const resolved = instance_mod.resolveComponent(self, comp_val) orelse {
            // Unresolvable leading token. A trailing (id …)/(ids …) anchor is
            // expected residue; anything else is a silently-dropped group.
            if (!items[idx].isForm("id") and !items[idx].isForm("ids")) {
                self.warnFmt(items[idx].span, "ignored item in (decouple \"{s}\" …) — expected (comp \"val\") COUNT per-pin REF PIN…", .{net_name});
            }
            idx += 1;
            continue;
        };
        var c: usize = if (comp_omitted) idx else idx + 1;

        // ── COUNT (required) ──
        // Syntax: [(comp "val")] COUNT per-pin [REF] PIN…
        if (c >= items.len) break;
        const count_val = items[c].asNumber() orelse {
            log.warn("decouple requires a count after component (net: {s})", .{net_name});
            log.warn("  Use: (decouple \"{s}\" (comp \"val\") COUNT per-pin REF)", .{net_name});
            return EvalError.InvalidForm;
        };
        const count: u32 = @intFromFloat(count_val);
        c += 1;

        // ── per-pin keyword (required) ──
        if (c >= items.len) {
            idx = c;
            continue;
        }
        const per_pin_kw = items[c].asAtom() orelse {
            log.warn("decouple expects 'per-pin' keyword (net: {s})", .{net_name});
            return EvalError.InvalidForm;
        };
        if (!std.mem.eql(u8, per_pin_kw, "per-pin")) {
            log.warn("decouple expects 'per-pin', got '{s}' (net: {s})", .{ per_pin_kw, net_name });
            return EvalError.InvalidForm;
        }
        c += 1;

        // ── Host ref ── an explicit ref, or the per-design default IC. With a
        // default IC declared, the first post-per-pin token is taken as a pin
        // unless it equals that ref; with no default the token is always the
        // ref (legacy positional form, unchanged for designs that set none).
        // A leading `auto` defers to the decouple-defaults IC — it is not
        // consumed here; the pin-collection loop below expands it.
        if (c >= items.len) {
            idx = c;
            continue;
        }
        const first_tok: ?[]const u8 = items[c].asText();
        const first_is_auto = first_tok != null and std.mem.eql(u8, first_tok.?, "auto");
        var ref_str: []const u8 = undefined;
        if (first_is_auto) {
            ref_str = try autoHostRef(self, items[c].span, net_name);
        } else if (self.decouple_defaults.ic.len > 0) {
            if (first_tok != null and std.mem.eql(u8, first_tok.?, self.decouple_defaults.ic)) {
                ref_str = first_tok.?;
                c += 1; // explicit ref consumed
            } else {
                ref_str = self.decouple_defaults.ic; // token is a pin; ref defaults in
            }
        } else {
            ref_str = first_tok orelse {
                idx = c + 1;
                continue;
            };
            c += 1;
        }

        // Explicit pin list after REF: one cap (×COUNT) per listed pin. Pins
        // are atoms or bare ints; collection stops at the next (comp …) group
        // or a trailing (id …)/(ids …) form. per-pin no longer auto-discovers
        // every pin on the net — a power rail shared with a mode-strap or an
        // SMPS feedback-sense pin (e.g. VFB tied to the core rail) must not
        // silently get a bypass cap, so the pins are required to be spelled out.
        // Resolve listed pins the way (pin …) declarations do: a function name
        // (e.g. "VCC" on a BGA part) maps to its pad via the component pinout;
        // a bare pad designator (e.g. "J14", "7") isn't a function name so it
        // passes through unchanged. Keeps the decouple pin list consistent with
        // how the IC's own pins are declared.
        const pin_func_map = findPinFuncMap(self, instances.items, ref_str);
        var target_pins: std.ArrayListUnmanaged([]const u8) = .empty;
        defer target_pins.deinit(self.allocator);
        var pin_idx = c;
        while (pin_idx < items.len) : (pin_idx += 1) {
            // Bare `auto` expands to every already-declared pin of the
            // decouple-defaults IC on this decouple's own net. Mixed use with
            // literal pins is OK.
            if (items[pin_idx].asList() != null) break; // next (comp …) group / (id …)
            if (items[pin_idx].asAtom()) |a| {
                if (std.mem.eql(u8, a, "auto")) {
                    const host = try autoHostRef(self, items[pin_idx].span, net_name);
                    try expandPinsOf(self, all_pin_nets, host, net_name, items[pin_idx].span, &target_pins);
                    continue;
                }
            }
            const raw = ids.pinId(self, items[pin_idx]) orelse break;
            const pid = if (pin_func_map) |pm| (instance_mod.resolvePinName(self, pm, raw) orelse raw) else raw;
            try target_pins.append(self.allocator, pid);
        }
        if (target_pins.items.len == 0) {
            log.warn("decouple per-pin requires an explicit pin list (net {s}, ref {s})", .{ net_name, ref_str });
            log.warn("  e.g. (decouple \"{s}\" (comp \"val\") COUNT per-pin {s} PIN1 PIN2 …)", .{ net_name, ref_str });
            return EvalError.InvalidForm;
        }
        // A zero count emits no caps; advance past the parsed group and skip.
        if (count == 0) {
            idx = pin_idx;
            continue;
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
        idx = pin_idx;
    }
}

/// The host ref a bare `auto` per-pin marker resolves to: the
/// `(decouple-defaults (ic "REF"))` value. Diagnoses a missing default.
fn autoHostRef(self: *Evaluator, span: ast.Span, net_name: []const u8) EvalError![]const u8 {
    if (self.decouple_defaults.ic.len == 0) {
        self.setErrorFmt(span, "(decouple \"{s}\" … per-pin auto) requires (decouple-defaults (ic \"REF\")) to be set first", .{net_name});
        return EvalError.InvalidForm;
    }
    return self.decouple_defaults.ic;
}

/// Append every pin of instance `ref` currently declared on net `net` to
/// `target_pins` — the expansion of the `auto` per-pin marker. Nets build
/// incrementally, so only pins from forms evaluated before the decouple are
/// visible; zero matches is an error pointing at that ordering contract.
fn expandPinsOf(
    self: *Evaluator,
    all_pin_nets: *std.ArrayListUnmanaged(PinNetDecl),
    ref: []const u8,
    net: []const u8,
    span: ast.Span,
    target_pins: *std.ArrayListUnmanaged([]const u8),
) EvalError!void {
    const before = target_pins.items.len;
    for (all_pin_nets.items) |pn| {
        if (std.mem.eql(u8, pn.ref_des, ref) and std.mem.eql(u8, pn.net, net)) {
            try target_pins.append(self.allocator, pn.pin);
        }
    }
    if (target_pins.items.len == before) {
        self.setErrorFmt(span, "no pins of \"{s}\" on net \"{s}\" — (pins …) declarations must appear before (decouple …)", .{ ref, net });
        return EvalError.InvalidForm;
    }
}

fn isDirectionKeyword(s: []const u8) bool {
    return std.mem.eql(u8, s, "in") or std.mem.eql(u8, s, "out") or
        std.mem.eql(u8, s, "io") or std.mem.eql(u8, s, "bidi");
}

fn isSignalTypeKeyword(s: []const u8) bool {
    return std.mem.eql(u8, s, "power") or std.mem.eql(u8, s, "signal") or
        std.mem.eql(u8, s, "clock") or std.mem.eql(u8, s, "data") or
        std.mem.eql(u8, s, "differential") or std.mem.eql(u8, s, "rf");
}

/// Parse a `(port "NAME" [net] dir ...)` form into a `Port`. Accepts the
/// short form (net = name) and the long form with explicit net string, plus
/// the optional `(rated …)`, `(nominal …)`, `(current …)`, `(efficiency …)`,
/// and `(enable …)` sub-clauses that drive the power-budget analyzer. A bare
/// trailing number (e.g. `(port "X" out power 2.5)`) is read as the nominal
/// voltage — matching `parseSectionPort` — with an explicit `(nominal …)`
/// taking precedence.
pub fn buildPort(self: *Evaluator, args: []const Node, env: *Env) EvalError!Port {
    if (args.len < 2) {
        const span = if (args.len > 0) args[0].span else ast.Span.zero;
        self.setError(span, "(port …) expects at least a name and a direction, e.g. (port \"VDD\" in)");
        return EvalError.ArityError;
    }
    const name_val = try self.evalNode(args[0], env);
    const name = name_val.asString() orelse {
        self.setError(args[0].span, "(port …) name must be a string");
        return EvalError.TypeError;
    };

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
            net = net_val.asString() orelse {
                self.setError(args[1].span, "(port …) net must be a string");
                return EvalError.TypeError;
            };
            dir_idx = 2;
        }
    } else if (args[1].asString()) |s| {
        // Long form: args[1] is net name string
        net = s;
        dir_idx = 2;
    } else {
        self.setError(args[1].span, "(port …) expects a direction or net after the name");
        return EvalError.InvalidForm;
    }

    if (dir_idx >= args.len) {
        self.setErrorFmt(args[0].span, "(port \"{s}\" …) is missing its direction (in|out|io|bidi)", .{name});
        return EvalError.ArityError;
    }
    const dir = args[dir_idx].asAtom() orelse {
        self.setErrorFmt(args[dir_idx].span, "(port \"{s}\" …) direction must be a bare word: in|out|io|bidi", .{name});
        return EvalError.InvalidForm;
    };

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
    // `role`/`protocol`/`class` take the following token as their value (as in
    // the section-port form); skip it so it isn't flagged as an unknown option.
    var skip_kw_value = false;
    for (args[dir_idx + 1 ..]) |arg| {
        if (skip_kw_value) {
            skip_kw_value = false;
            continue;
        }
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
                // Evaluate the expression so a *computed* nominal resolves — e.g.
                // `(nominal vout)` on a parameterized regulator module whose output
                // voltage is derived from its feedback-divider params — not just a
                // literal. A bare literal still evaluates to itself.
                nominal = (try self.evalNode(nom_children[1], env)).asNumber() orelse nom_children[1].asNumber();
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
            if (std.mem.eql(u8, kw, "optional")) {
                is_optional = true;
            } else if (std.mem.eql(u8, kw, "role") or std.mem.eql(u8, kw, "protocol") or std.mem.eql(u8, kw, "class")) {
                // Metadata keywords mirror the section-port form; consume their
                // following value token (parsePort doesn't store them on Port).
                skip_kw_value = true;
            } else if (!isSignalTypeKeyword(kw)) {
                // Signal-type words (power/clock/rf/…) are valid in the section
                // twin and tolerated here; anything else is a likely typo.
                self.warnFmt(arg.span, "unknown port option '{s}' in (port …)", .{kw});
            }
        } else if (arg.asNumber()) |n| {
            // Bare trailing number is the nominal voltage, matching
            // parseSectionPort; an explicit (nominal …) form still wins.
            if (nominal == null) nominal = n;
        } else if (arg.asList() != null) {
            // None of the known sub-forms (rated/nominal/current/efficiency/
            // enable/electrical) matched above.
            self.warnFmt(arg.span, "unknown sub-form ({s} …) in (port …)", .{formHeadName(arg)});
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
    if (args.len != 2) {
        const span = if (args.len > 0) args[0].span else ast.Span.zero;
        self.setErrorFmt(span, "(note …) expects 2 arguments, got {d} — (note \"REF\" \"text\")", .{args.len});
        return EvalError.ArityError;
    }
    const rd_val = try self.evalNode(args[0], env);
    const text_val = try self.evalNode(args[1], env);
    return Note{
        .ref_des = rd_val.asString() orelse {
            self.setError(args[0].span, "(note …) ref-des must be a string");
            return EvalError.TypeError;
        },
        .text = text_val.asString() orelse {
            self.setError(args[1].span, "(note …) text must be a string");
            return EvalError.TypeError;
        },
    };
}

/// Build a `(group "name" ("R1" "R2" ...))` form into a `Group` that bundles
/// a set of ref-deses for the schematic renderer's visual grouping pass.
pub fn buildGroup(self: *Evaluator, args: []const Node, env: *Env) EvalError!Group {
    if (args.len != 2) {
        const span = if (args.len > 0) args[0].span else ast.Span.zero;
        self.setErrorFmt(span, "(group …) expects 2 arguments, got {d} — (group \"name\" (\"R1\" \"R2\"))", .{args.len});
        return EvalError.ArityError;
    }
    const name_val = try self.evalNode(args[0], env);
    const members_node = args[1].asList() orelse {
        self.setError(args[1].span, "(group …) members must be a list of ref-des strings");
        return EvalError.InvalidForm;
    };

    var members: std.ArrayListUnmanaged([]const u8) = .empty;
    for (members_node) |m| {
        const s = m.asString() orelse {
            self.setError(m.span, "(group …) members must be ref-des strings");
            return EvalError.TypeError;
        };
        try members.append(self.allocator, s);
    }

    return Group{
        .name = name_val.asString() orelse {
            self.setError(args[0].span, "(group …) name must be a string");
            return EvalError.TypeError;
        },
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
    if (args.len < 2) {
        self.setError(form_children[0].span, "(sub-block …) expects a name and a module call: (sub-block \"pwr\" (tpsm84338 …))");
        return EvalError.ArityError;
    }
    const name_val = try self.evalNode(args[0], env);
    const name = name_val.asString() orelse {
        self.setError(args[0].span, "(sub-block …) name must be a string");
        return EvalError.TypeError;
    };

    // Trailing children after the module call: (id …)/(ids …) identity
    // anchors and (bridge …) net shorthands are consumed elsewhere;
    // (reflow) opts out of module-layout composition. Anything else is
    // silently dead — flag it.
    var reflow = false;
    for (args[2..]) |extra| {
        if (extra.isForm("id") or extra.isForm("ids") or extra.isForm("bridge")) continue;
        if (extra.isForm("reflow")) {
            reflow = true;
            continue;
        }
        self.warnFmt(extra.span, "unknown sub-form ({s} …) in (sub-block …)", .{formHeadName(extra)});
    }

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
            else => {
                self.setErrorFmt(args[1].span, "(sub-block \"{s}\" …) call must return a design-block", .{name});
                return EvalError.TypeError;
            },
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
        .reflow = reflow,
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

// spec: eval/evaluator - decouple per-pin emits one cap per explicitly listed pin
test "decouple per-pin emits a cap for each listed pin" {
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var env = env_mod.Env.init(alloc, null);
    defer env.deinit();
    try putTestFamily(&eval, alloc, "cap-0201");

    const nodes = try parser_mod.parse(alloc, "(cap-0201 \"100nF\") 1 per-pin U1 7 8 9");
    var instances: std.ArrayListUnmanaged(Instance) = .empty;
    var all_pin_nets: std.ArrayListUnmanaged(PinNetDecl) = .empty;
    var sidecar = ids.ChildIdSidecar{ .map = .empty, .parent_offset = 0 };

    try emitDecoupleItems(&eval, nodes, "VDD", &env, &instances, &all_pin_nets, "abcd1234", &sidecar);
    try testing.expectEqual(@as(usize, 3), instances.items.len);
    // one cap per listed pad, in listed order
    try testing.expectEqualStrings("100nF@7#0", instances.items[0].origin_key);
    try testing.expectEqualStrings("100nF@8#0", instances.items[1].origin_key);
    try testing.expectEqualStrings("100nF@9#0", instances.items[2].origin_key);
}

// spec: eval/evaluator - decouple per-pin without an explicit pin list is an error
test "decouple per-pin with no pins errors" {
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var env = env_mod.Env.init(alloc, null);
    defer env.deinit();
    try putTestFamily(&eval, alloc, "cap-0201");

    const nodes = try parser_mod.parse(alloc, "(cap-0201 \"100nF\") 1 per-pin U1");
    var instances: std.ArrayListUnmanaged(Instance) = .empty;
    var all_pin_nets: std.ArrayListUnmanaged(PinNetDecl) = .empty;
    var sidecar = ids.ChildIdSidecar{ .map = .empty, .parent_offset = 0 };

    try testing.expectError(error.InvalidForm, emitDecoupleItems(&eval, nodes, "VDD", &env, &instances, &all_pin_nets, "abcd1234", &sidecar));
}

// spec: eval/design_block - buildPort reads a bare trailing number as the port nominal voltage with an explicit nominal form overriding it
test "buildPort reads a bare trailing number as nominal, (nominal) overrides" {
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var env = env_mod.Env.init(alloc, null);
    defer env.deinit();

    // Bare positional number after direction + signal-type → nominal voltage.
    const bare = try parser_mod.parse(alloc, "(port \"V_RX_2P5\" out power 2.5)");
    const bare_port = try buildPort(&eval, bare[0].asList().?[1..], &env);
    try testing.expect(bare_port.nominal != null);
    try testing.expectEqual(@as(f64, 2.5), bare_port.nominal.?);

    // An explicit (nominal 3.3) still wins over a bare number on the same port.
    const override = try parser_mod.parse(alloc, "(port \"V_RX_2P5\" out power 2.5 (nominal 3.3))");
    const override_port = try buildPort(&eval, override[0].asList().?[1..], &env);
    try testing.expectEqual(@as(f64, 3.3), override_port.nominal.?);
}

// spec: eval/design_block - decouple-defaults lets decouple omit its component and host ref
test "decouple uses default bypass and default ic when both omitted" {
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    eval.hierarchical_ids = true;
    var env = env_mod.Env.init(alloc, null);
    defer env.deinit();
    try putTestFamily(&eval, alloc, "cap-0201");

    // (decouple-defaults (ic "U1") (bypass (cap-0201 "100nF"))) recorded.
    const bypass_nodes = try parser_mod.parse(alloc, "(cap-0201 \"100nF\")");
    eval.decouple_defaults = .{ .ic = "U1", .bypass = bypass_nodes[0] };

    // Component omitted (leading count) and host ref omitted (J14 is a pin).
    const nodes = try parser_mod.parse(alloc, "1 per-pin J14 K14");
    var instances: std.ArrayListUnmanaged(Instance) = .empty;
    var all_pin_nets: std.ArrayListUnmanaged(PinNetDecl) = .empty;
    var sidecar = ids.ChildIdSidecar{ .map = .empty, .parent_offset = 0 };

    try emitDecoupleItems(&eval, nodes, "VDD", &env, &instances, &all_pin_nets, "abcd1234", &sidecar);

    // One cap per pin, from the default bypass; key excludes the host ref so
    // the id stays stable whether or not the ref was spelled out.
    try testing.expectEqual(@as(usize, 2), instances.items.len);
    try testing.expectEqualStrings("100nF@J14#0", instances.items[0].origin_key);
    try testing.expectEqualStrings("100nF@K14#0", instances.items[1].origin_key);
    // The per-pin split net embeds the defaulted host ref (cap pin 1 side).
    try testing.expectEqualStrings("VDD.U1.J14", all_pin_nets.items[0].net);
}

// spec: eval/design_block - decouple with no defaults keeps its legacy explicit form
test "decouple without defaults treats the post-per-pin token as the ref" {
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var env = env_mod.Env.init(alloc, null);
    defer env.deinit();
    try putTestFamily(&eval, alloc, "cap-0201");

    // No decouple-defaults declared: U1 is the explicit ref, 7/8 are pins.
    const nodes = try parser_mod.parse(alloc, "(cap-0201 \"100nF\") 1 per-pin U1 7 8");
    var instances: std.ArrayListUnmanaged(Instance) = .empty;
    var all_pin_nets: std.ArrayListUnmanaged(PinNetDecl) = .empty;
    var sidecar = ids.ChildIdSidecar{ .map = .empty, .parent_offset = 0 };

    try emitDecoupleItems(&eval, nodes, "VDD", &env, &instances, &all_pin_nets, "abcd1234", &sidecar);

    try testing.expectEqual(@as(usize, 2), instances.items.len);
    try testing.expectEqualStrings("100nF@7#0", instances.items[0].origin_key);
    try testing.expectEqualStrings("VDD.U1.7", all_pin_nets.items[0].net);
}

/// Shared fixture for the per-pin decouple tests: an evaluator in
/// hierarchical-ids mode (deterministic child ids), a cap family, and U1's
/// J14/K14 pins pre-declared on VDD the way an earlier (pins …) form would have.
fn pinsOfFixture(alloc: std.mem.Allocator, eval: *Evaluator, all_pin_nets: *std.ArrayListUnmanaged(PinNetDecl)) !void {
    eval.* = Evaluator.init(alloc, ".");
    eval.hierarchical_ids = true;
    try putTestFamily(eval, alloc, "cap-0201");
    try all_pin_nets.append(alloc, .{ .ref_des = "U1", .pin = "J14", .net = "VDD" });
    try all_pin_nets.append(alloc, .{ .ref_des = "U1", .pin = "K14", .net = "VDD" });
}

// spec: eval/design_block - decouple per-pin auto expands the decouple-defaults IC's pins on the decoupled net
test "decouple per-pin auto expands the defaults ic pins" {
    const alloc = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    var nets: std.ArrayListUnmanaged(PinNetDecl) = .empty;
    try pinsOfFixture(alloc, &eval, &nets);
    eval.decouple_defaults.ic = "U1";
    var env = env_mod.Env.init(alloc, null);
    defer env.deinit();
    var instances: std.ArrayListUnmanaged(Instance) = .empty;
    var sidecar = ids.ChildIdSidecar{ .map = .empty, .parent_offset = 0 };

    const items = try parser_mod.parse(alloc, "(cap-0201 \"100nF\") 1 per-pin auto");
    try emitDecoupleItems(&eval, items, "VDD", &env, &instances, &nets, "abcd1234", &sidecar);

    try testing.expectEqual(@as(usize, 2), instances.items.len);
    try testing.expectEqualStrings("100nF@J14#0", instances.items[0].origin_key);
    try testing.expectEqualStrings("100nF@K14#0", instances.items[1].origin_key);
    try testing.expectEqualStrings("VDD.U1.J14", nets.items[0].net);
}

// spec: eval/design_block - decouple per-pin auto without a decouple-defaults ic is diagnosed
test "decouple per-pin auto without defaults ic errors" {
    const alloc = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    var nets: std.ArrayListUnmanaged(PinNetDecl) = .empty;
    try pinsOfFixture(alloc, &eval, &nets);
    var env = env_mod.Env.init(alloc, null);
    defer env.deinit();
    var instances: std.ArrayListUnmanaged(Instance) = .empty;
    var sidecar = ids.ChildIdSidecar{ .map = .empty, .parent_offset = 0 };

    const items = try parser_mod.parse(alloc, "(cap-0201 \"100nF\") 1 per-pin auto");
    const r = emitDecoupleItems(&eval, items, "VDD", &env, &instances, &nets, "abcd1234", &sidecar);
    try testing.expectError(error.InvalidForm, r);
    const diag = eval.last_error orelse return error.TestExpectedDiagnostic;
    try testing.expect(std.mem.indexOf(u8, diag.message, "per-pin auto) requires (decouple-defaults (ic") != null);
}

// spec: eval/design_block - decouple per-pin auto with no matching declared pins is diagnosed with the declaration-order contract
test "decouple per-pin auto with zero matches errors" {
    const alloc = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    var nets: std.ArrayListUnmanaged(PinNetDecl) = .empty;
    try pinsOfFixture(alloc, &eval, &nets);
    eval.decouple_defaults.ic = "U1";
    var env = env_mod.Env.init(alloc, null);
    defer env.deinit();
    var instances: std.ArrayListUnmanaged(Instance) = .empty;
    var sidecar = ids.ChildIdSidecar{ .map = .empty, .parent_offset = 0 };

    // U1 has no pins on VDDA — the (pins …) for that rail hasn't run yet.
    const items = try parser_mod.parse(alloc, "(cap-0201 \"100nF\") 1 per-pin auto");
    const r = emitDecoupleItems(&eval, items, "VDDA", &env, &instances, &nets, "abcd1234", &sidecar);
    try testing.expectError(error.InvalidForm, r);
    const diag = eval.last_error orelse return error.TestExpectedDiagnostic;
    try testing.expect(std.mem.indexOf(u8, diag.message, "no pins of \"U1\" on net \"VDDA\"") != null);
    try testing.expect(std.mem.indexOf(u8, diag.message, "(pins …) declarations must appear before (decouple …)") != null);
}
