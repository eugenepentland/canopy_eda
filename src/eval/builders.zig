//! Design-block sub-form builders, called by the evaluator while it
//! materializes a `(design-block …)` body: `(port …)`, `(note …)`, `(group …)`,
//! `(sub-block …)`, section `(port …)`/`(calc …)`, `(pins …)`/`(pin …)` forms,
//! and the `(decouple …)` per-pin/series expansions. Methods on `*Evaluator`;
//! failures propagate as `EvalError` (no panics) and unknown sub-forms warn
//! rather than abort. Produces the DesignBlock's structural children.

const std = @import("std");
const infra_fs = @import("../infra/fs.zig");
const log = @import("../infra/log.zig");
const ast = @import("../sexpr/ast.zig");
const numeric = @import("../numeric.zig");
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
const assert_range_arity: usize = 5;
/// Sanity cap on the index count a single `(bus-port …)` form may expand to —
/// mirrors `design_block.max_bus_expansion`. Guards against a design-file typo
/// (or hostile input) turning a huge index range into a runaway allocation the
/// HTTP server evaluates on every push/page-load.
const max_bus_port_expansion: i64 = 4096;

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
    var group_list: std.ArrayList([]const u8) = .empty;
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
    out: *std.ArrayList(env_mod.SectionPort),
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
    out: *std.ArrayList(Port),
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
    // Reject NaN/±inf/out-of-range before narrowing (UB in ReleaseSmall).
    const start_i = numeric.checkedInt(i64, start_f) orelse return null;
    const end_i = numeric.checkedInt(i64, end_f) orelse return null;
    // Bus lanes are non-negative signal indices — the sibling `(bus-net …)`
    // path narrows both endpoints through `numberAsUsize`, which rejects a
    // negative outright, and the documented ranges (`0 7`, `1 10`) mirror
    // hardware bit numbering. Enforcing the same rule here is also what keeps
    // the span below from wrapping: an i64 `end - start` with a large-negative
    // start and a large-positive end overflows, and with runtime safety off it
    // wraps *negative*, slipping past the lane cap and turning the expansion
    // loops into ~2^64 port-allocating iterations on any push/validate/build.
    if (start_i < 0) {
        self.warnFmt(bp_children[0].span, "(bus-port …) index range {d}..{d} has a negative start index — ignored", .{ start_i, end_i });
        return null;
    }
    // Widen to i128 so the span is exact for every i64 endpoint pair, even if
    // the non-negative rule above is ever relaxed.
    const span: i128 = @as(i128, end_i) - @as(i128, start_i);
    if (span >= @as(i128, max_bus_port_expansion)) {
        self.warnFmt(bp_children[0].span, "(bus-port …) index range {d}..{d} exceeds the {d}-lane cap — ignored", .{ start_i, end_i, max_bus_port_expansion });
        return null;
    }

    var rest_start: usize = 4;
    var suffixes: []const []const u8 = &.{""};
    if (bp_children.len > 4 and bp_children[4].isForm("suffixes")) {
        const sf = bp_children[4].asList().?;
        var suf_buf: std.ArrayList([]const u8) = .empty;
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
        .start = start_i,
        .end = end_i,
        .suffixes = suffixes,
        .rest = bp_children[rest_start..],
    };
}

/// Build a children slice for `parseSectionPort`: leading dummy `port`
/// atom (the parser skips index 0), then the synthesized name, then the
/// shared modifier children.
fn synthesizeSectionPortChildren(allocator: std.mem.Allocator, name: []const u8, rest: []const Node) EvalError![]Node {
    var buf: std.ArrayList(Node) = .empty;
    try buf.append(allocator, Node.atom(ast.Span.zero, "port"));
    try buf.append(allocator, Node.string(ast.Span.zero, name));
    for (rest) |n| try buf.append(allocator, n);
    return buf.toOwnedSlice(allocator) catch EvalError.OutOfMemory;
}

/// Build an args slice for `buildPort`: the synthesized name at args[0]
/// (no leading `port` atom — buildPort's contract differs from
/// parseSectionPort's), then the shared modifier children.
fn synthesizeBuildPortArgs(allocator: std.mem.Allocator, name: []const u8, rest: []const Node) EvalError![]Node {
    var buf: std.ArrayList(Node) = .empty;
    try buf.append(allocator, Node.string(ast.Span.zero, name));
    for (rest) |n| try buf.append(allocator, n);
    return buf.toOwnedSlice(allocator) catch EvalError.OutOfMemory;
}

// ── (diff-port …) ──────────────────────────────────────────────────
// Every differential boundary signal in the corpus is two hand-written
// `(port …)` lines that must stay byte-identical apart from one suffix
// letter. `(diff-port …)` writes the pair once, and — unlike two hand-written
// ports — records that the lanes belong together (`Port.diff_pair_of`) so ERC
// can hold them to a both-or-neither connection rule.

/// Lane suffixes used when the form declares no `(suffixes …)` override —
/// the spelling hand-written pairs in the design corpus already use.
const default_diff_suffixes = [2][]const u8{ "_P", "_N" };

/// Signal-type word stamped on both lanes when the author names none, so a
/// `(diff-port …)` expansion is indistinguishable from the two `(port "…_P"
/// in differential)` lines it replaces. An explicit kind (`rf`, `clock`, …)
/// still wins — the pairing lives in `diff_pair_of`, not in this word.
const diff_port_kind = "differential";

/// Parsed shape of one `(diff-port …)` form: the shared base name, the
/// optional long-form net base, the two lane suffixes, and the modifier
/// children replayed verbatim onto both lanes.
const DiffPortExpansion = struct {
    base: []const u8,
    /// Long form `(diff-port "NAME" "NET" dir …)` — each lane's net becomes
    /// `NET<suffix>`. Null for the short form, where net follows name.
    net_base: ?[]const u8,
    suffixes: [2][]const u8,
    /// Port modifiers shared by both lanes, with `(suffixes …)` removed.
    rest: []const Node,
};

/// Expand `(diff-port "BASE" [net] dir …)` into the two top-level `Port`s it
/// stands for. Both lanes are built by `buildPort` from synthesized children,
/// so every modifier (`optional`, `(rated …)`, `(side …)`, `(electrical …)`,
/// …) behaves exactly as it would on a hand-written port.
pub fn expandTopLevelDiffPort(
    self: *Evaluator,
    dp_children: []const Node,
    env: *Env,
    out: *std.ArrayList(Port),
) EvalError!void {
    const exp = try parseDiffPortHeader(self, dp_children, env) orelse return;
    for (exp.suffixes) |suffix| {
        const args = try synthesizeDiffPortArgs(self.allocator, exp, suffix);
        var port = try buildPort(self, args, env);
        if (port.kind.len == 0) port.kind = diff_port_kind;
        port.diff_pair_of = exp.base;
        try out.append(self.allocator, port);
    }
}

/// Section-scope variant of `expandTopLevelDiffPort`: the same two lanes as
/// `SectionPort`s for the block diagram. `parseSectionPort` defaults an
/// unstated signal type to `.signal`; a diff-port lane defaults to
/// `.differential` instead.
pub fn expandSectionDiffPort(
    self: *Evaluator,
    dp_children: []const Node,
    env: *env_mod.Env,
    out: *std.ArrayList(env_mod.SectionPort),
) EvalError!void {
    const exp = try parseDiffPortHeader(self, dp_children, env) orelse return;
    for (exp.suffixes) |suffix| {
        const args = try synthesizeDiffPortArgs(self.allocator, exp, suffix);
        const children = try synthesizeSectionPortChildrenFromArgs(self.allocator, args);
        if (try parseSectionPort(self, children, env)) |p| {
            var sp = p;
            if (sp.signal_type == .signal) sp.signal_type = .differential;
            try out.append(self.allocator, sp);
        }
    }
}

fn parseDiffPortHeader(self: *Evaluator, dp_children: []const Node, env: *Env) EvalError!?DiffPortExpansion {
    // dp_children[0] is the `diff-port` atom; [1] is the base name and [2] is
    // either the long-form net base or the direction keyword.
    if (dp_children.len < 3) {
        const span = if (dp_children.len > 0) dp_children[0].span else ast.Span.zero;
        self.setError(span, "(diff-port …) expects at least a base name and a direction, e.g. (diff-port \"AINA_EXT\" in)");
        return EvalError.ArityError;
    }
    const base_val = try self.evalNode(dp_children[1], env);
    const base = base_val.asString() orelse {
        self.setError(dp_children[1].span, "(diff-port …) base name must be a string");
        return EvalError.TypeError;
    };
    var rest = dp_children[2..];
    var net_base: ?[]const u8 = null;
    if (try diffPortNetBase(self, rest[0], env)) |nb| {
        net_base = nb;
        rest = rest[1..];
    }
    return .{
        .base = base,
        .net_base = net_base,
        .suffixes = diffPortSuffixes(self, rest),
        .rest = try stripSuffixesForm(self.allocator, rest),
    };
}

/// The long-form net base, when the child right after the name is one (a
/// string, or a non-direction atom that evaluates to one). Null means the
/// short form, where each lane's net is its own name.
fn diffPortNetBase(self: *Evaluator, node: Node, env: *Env) EvalError!?[]const u8 {
    if (node.asString()) |s| return s;
    const atom = node.asAtom() orelse return null;
    if (isDirectionKeyword(atom)) return null;
    const value = try self.evalNode(node, env);
    return value.asString() orelse {
        self.setError(node.span, "(diff-port …) net must be a string");
        return EvalError.TypeError;
    };
}

/// The lane suffixes: an explicit `(suffixes P N)` anywhere among the
/// modifiers, else `_P`/`_N`. A malformed override warns and falls back.
fn diffPortSuffixes(self: *Evaluator, rest: []const Node) [2][]const u8 {
    for (rest) |node| {
        if (!node.isForm("suffixes")) continue;
        const sf = node.asList().?;
        if (sf.len >= 3) {
            const p = sf[1].asText();
            const n = sf[2].asText();
            if (p != null and n != null) return .{ p.?, n.? };
        }
        self.warnFmt(node.span, "(suffixes …) in (diff-port …) expects exactly two lane suffixes — using {s}/{s}", .{ default_diff_suffixes[0], default_diff_suffixes[1] });
    }
    return default_diff_suffixes;
}

/// `rest` with any `(suffixes …)` child removed — that form configures the
/// expansion and is not a port modifier `buildPort` would recognise.
fn stripSuffixesForm(allocator: std.mem.Allocator, rest: []const Node) EvalError![]const Node {
    var has = false;
    for (rest) |node| has = has or node.isForm("suffixes");
    if (!has) return rest;
    var buf: std.ArrayList(Node) = .empty;
    for (rest) |node| {
        if (node.isForm("suffixes")) continue;
        try buf.append(allocator, node);
    }
    return buf.toOwnedSlice(allocator) catch EvalError.OutOfMemory;
}

/// One lane's `buildPort` args: suffixed name, the suffixed net when the long
/// form gave a net base, then the shared modifiers.
fn synthesizeDiffPortArgs(allocator: std.mem.Allocator, exp: DiffPortExpansion, suffix: []const u8) EvalError![]Node {
    var buf: std.ArrayList(Node) = .empty;
    const name = std.fmt.allocPrint(allocator, "{s}{s}", .{ exp.base, suffix }) catch return EvalError.OutOfMemory;
    try buf.append(allocator, Node.string(ast.Span.zero, name));
    if (exp.net_base) |nb| {
        const net = std.fmt.allocPrint(allocator, "{s}{s}", .{ nb, suffix }) catch return EvalError.OutOfMemory;
        try buf.append(allocator, Node.string(ast.Span.zero, net));
    }
    for (exp.rest) |n| try buf.append(allocator, n);
    return buf.toOwnedSlice(allocator) catch EvalError.OutOfMemory;
}

/// Re-front `buildPort`-shaped args with the dummy `port` head atom
/// `parseSectionPort` skips.
fn synthesizeSectionPortChildrenFromArgs(allocator: std.mem.Allocator, args: []const Node) EvalError![]Node {
    var buf: std.ArrayList(Node) = .empty;
    try buf.append(allocator, Node.atom(ast.Span.zero, "port"));
    for (args) |n| try buf.append(allocator, n);
    return buf.toOwnedSlice(allocator) catch EvalError.OutOfMemory;
}

/// Parse (calc "name" (let ...) ...) block.
pub fn parseSectionCalc(self: *Evaluator, sf_children: []const Node, env: *env_mod.Env) EvalError!?env_mod.CalcBlock {
    if (sf_children.len < 2) return null;
    const calc_name_val = try self.evalNode(sf_children[1], env);
    const calc_name = calc_name_val.asString() orelse return null;
    var calc_env = env_mod.Env.init(self.allocator, env);
    var calc_results: std.ArrayList(env_mod.CalcResult) = .empty;

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
            if (cf_children.len >= assert_range_arity) {
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

/// Resolve every `(decouples "IC" PIN)` binding's PIN against the pinout of the
/// IC it names, once the whole block's instances exist.
///
/// This must be a post-build pass, not instance-time work, for two reasons. The
/// map that gives a function name meaning belongs to the TARGET, and a capacitor
/// cannot see it — a cap has no pinout of its own, so resolving the token
/// against the CAP's map (what `buildInstance` used to do) could never succeed
/// and every function-name spelling silently degraded to the raw token and then
/// to the hub's default pad. And the target may be declared *after* the cap in
/// the block, so at instance time it need not exist yet. Running here makes
/// declaration order irrelevant: `(decouples "U1" VIN)` finds U1's VIN pad
/// whether U1 is written above or below the cap.
///
/// A token that is already a physical pad passes through untouched — checked
/// FIRST, so a connector pinout that names contact 4 "4" can never re-point a
/// pad binding — a function name maps to its pad, and a token that is neither
/// stays exactly as written: `erc.checkDecouplingBindingValidity` reports those,
/// and rewriting them here would only hide the typo.
pub fn resolveDecoupleTargets(self: *Evaluator, instances: []Instance) void {
    for (instances) |*inst| {
        const bd = inst.bind.decouple;
        if (bd.ic.len == 0 or bd.pin.len == 0) continue;
        inst.bind.decouple.pin = resolveTargetPin(self, instances, inst.ref_des, "decouples", bd.ic, bd.pin);
    }
}

/// Resolve every `(near "REF" PIN)` binding's PIN against the pinout of the part
/// it names — the same post-build pass, for the same reasons, as
/// `resolveDecoupleTargets` above (which documents them): the map that gives a
/// function name meaning belongs to the TARGET, a two-terminal passive has no
/// pinout of its own to resolve it against, and the target may be declared after
/// the passive in the block. `(own PAD)` is NOT resolved here — it names a pad of
/// the declaring part, which `buildInstance` already resolved against that part's
/// own pinout.
pub fn resolveNearTargets(self: *Evaluator, instances: []Instance) void {
    for (instances) |*inst| {
        const nb = inst.bind.near;
        if (nb.ref.len == 0 or nb.pin.len == 0) continue;
        inst.bind.near.pin = resolveTargetPin(self, instances, inst.ref_des, "near", nb.ref, nb.pin);
    }
}

/// One binding's PIN token resolved against `target_ref`'s pinout, shared by the
/// `(decouples …)` and `(near …)` passes so the two can never drift.
///
/// A token that is already a physical pad passes through untouched — checked
/// FIRST, so a connector pinout that names contact 4 "4" can never re-point a
/// pad binding — a function name maps to its pad, and a token that is neither
/// stays exactly as written: the ERC binding-validity checks report those, and
/// rewriting them here would only hide the typo. A function name repeated on
/// several pads resolves to the lowest and warns, naming the duplicates.
fn resolveTargetPin(
    self: *Evaluator,
    instances: []const Instance,
    ref_des: []const u8,
    form: []const u8,
    target_ref: []const u8,
    token: []const u8,
) []const u8 {
    const pinout = findPinFuncMap(self, instances, target_ref) orelse return token;
    if (pinout.contains(token)) return token; // already a physical pad
    const m = instance_mod.matchPinName(pinout, token) orelse return token;
    if (m.matches == 1) return m.pad;
    // No source span survives to this pass, so the ambiguity goes on the
    // span-less warning channel (`assertions`, as `validate.warnCombinableNets`
    // does) and names the parts instead of a line and column.
    const msg = std.fmt.allocPrint(
        self.allocator,
        "({s} \"{s}\" {s}) on {s}: that function names {d} pads on {s} — bound to '{s}'; write the pad id to pick another",
        .{ form, target_ref, token, ref_des, m.matches, target_ref, m.pad },
    ) catch return m.pad;
    self.assertions.append(self.allocator, .{ .passed = false, .message = msg, .is_warning = true }) catch return m.pad;
    return m.pad;
}

/// Process a single pin or bus form inside a (pins ...) block.
pub fn processPinForm(
    self: *Evaluator,
    pin_form: Node,
    pins_ref: []const u8,
    pin_func_map: ?*const std.StringHashMapUnmanaged([]const u8),
    env: *env_mod.Env,
    all_pin_nets: *std.ArrayList(PinNetDecl),
    pg_pins: *std.ArrayList(env_mod.PartPin),
    net_ties: *std.ArrayList(NetTie),
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
            const pn = if (pin_func_map) |pm| (instance_mod.resolvePinName(self, pm, raw, pin_node.span) orelse raw) else raw;
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
        // Grouped pin lists `((A B) (C D))` and bare lane tokens `A B` share
        // one emitter so the function-name auto-tie (which must carry
        // `is_auto = true` — a non-auto tie bypasses the both-sides-populated
        // guard in buildNets and can hard-merge two user-declared nets across
        // a series element) can't drift between the two shapes.
        var bus_idx: u32 = 0;
        for (bus_children[2..]) |bus_node| {
            if (bus_node.isForm("as-prefix")) continue;
            if (bus_node.asList()) |bus_list| {
                for (bus_list) |bp| {
                    try emitBusLane(self, bp, pins_ref, bus_prefix, as_prefix, &bus_idx, pin_func_map, all_pin_nets, pg_pins, net_ties);
                }
            } else {
                try emitBusLane(self, bus_node, pins_ref, bus_prefix, as_prefix, &bus_idx, pin_func_map, all_pin_nets, pg_pins, net_ties);
            }
        }
    }
}

/// Emit one bus lane: resolve the pin token, add its `<prefix><idx>` net
/// membership + part-pin, optionally auto-assert `<as_prefix><idx>`, and add
/// the pin-function-name auto-alias tie. `bus_idx` is advanced by one on
/// success (and left unchanged when the token doesn't resolve to a pin). The
/// single emitter used by both the grouped and bare-token branches — folding
/// them here is what keeps `.is_auto = true` from silently going missing on
/// one path (the exact drift that let a bare bus token hard-merge two nets).
fn emitBusLane(
    self: *Evaluator,
    node: Node,
    pins_ref: []const u8,
    bus_prefix: []const u8,
    as_prefix: []const u8,
    bus_idx: *u32,
    pin_func_map: ?*const std.StringHashMapUnmanaged([]const u8),
    all_pin_nets: *std.ArrayList(PinNetDecl),
    pg_pins: *std.ArrayList(env_mod.PartPin),
    net_ties: *std.ArrayList(NetTie),
) EvalError!void {
    const raw = ids.pinId(self, node) orelse return;
    const pn = if (pin_func_map) |pm| (instance_mod.resolvePinName(self, pm, raw, node.span) orelse raw) else raw;
    const bus_net = std.fmt.allocPrint(self.allocator, "{s}{d}", .{ bus_prefix, bus_idx.* }) catch return;
    const asserted: []const []const u8 = if (as_prefix.len > 0) blk: {
        const name = std.fmt.allocPrint(self.allocator, "{s}{d}", .{ as_prefix, bus_idx.* }) catch break :blk &.{};
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
    bus_idx.* += 1;
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
    instances: *std.ArrayList(Instance),
    all_pin_nets: *std.ArrayList(PinNetDecl),
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
        // Reject NaN/negative/out-of-range COUNT before narrowing (a bare
        // `@intFromFloat` on those is UB in the safety-off prod build) — e.g.
        // `(decouple "VDD" (comp) -1 per-pin U1 7)`.
        const count: u32 = numeric.checkedInt(u32, count_val) orelse {
            self.warnFmt(items[c].span, "decouple count '{d}' is not a valid non-negative integer (net: {s}) — skipped", .{ count_val, net_name });
            return EvalError.InvalidForm;
        };
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
        const DecoupleTarget = struct {
            pad: []const u8,
            /// Function-name token from the source when reverse pinout lookup
            /// succeeded. It becomes the generated cap's readable label.
            function_name: []const u8 = "",
        };
        var target_pins: std.ArrayList(DecoupleTarget) = .empty;
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
                    var expanded: std.ArrayList([]const u8) = .empty;
                    defer expanded.deinit(self.allocator);
                    try expandPinsOf(self, all_pin_nets, host, net_name, items[pin_idx].span, &expanded);
                    for (expanded.items) |pad| try target_pins.append(self.allocator, .{ .pad = pad });
                    continue;
                }
            }
            const raw = ids.pinId(self, items[pin_idx]) orelse break;
            const resolved_function = if (pin_func_map) |pm| instance_mod.resolvePinName(self, pm, raw, items[pin_idx].span) else null;
            try target_pins.append(self.allocator, .{
                .pad = resolved_function orelse raw,
                .function_name = if (resolved_function != null) raw else "",
            });
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

        for (target_pins.items) |target| {
            const target_pin = target.pad;
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
                const identity = try decoupleIdentity(self, sidecar, form_id, .{
                    .child_key = child_key,
                    .function_name = target.function_name,
                    .replica = ci,
                    .fallback_ref = ref,
                });
                try instances.append(self.allocator, .{
                    .ref_des = ref,
                    .label = identity.label,
                    .origin_key = identity.origin,
                    .component = resolved.family,
                    .value = resolved.value,
                    .footprint = resolved.footprint,
                    .symbol = resolved.symbol,
                    .attrs = resolved.attrs,
                    .source_offset = dec_comp_offset,
                    .id = identity.id,
                    // The binding this shorthand IS — the host ref and the pad
                    // it resolved — recorded as first-class fields rather than
                    // left implicit in `origin_key`. The key stays exactly as it
                    // was (hierarchical child ids derive from it, so any change
                    // would re-stamp every adopted board), but it can only carry
                    // the pad when the pin was spelled as a NUMBER: a
                    // function-name spelling turns the key into the readable
                    // label (`C_VDD_1`), so the pad vanished and the cap read as
                    // unbound to the placer, the lint and the exporter alike.
                    .bind = .{ .decouple = .{ .ic = ref_str, .pin = target_pin } },
                });
                try all_pin_nets.append(self.allocator, .{ .ref_des = ref, .pin = "1", .net = sub_net });
                try all_pin_nets.append(self.allocator, .{ .ref_des = ref, .pin = "2", .net = "GND" });
            }

            // Reassign the target component's pin to the split sub-net. If no
            // `(ref_str, target_pin, net_name)` entry exists — the host pin
            // wasn't declared on this net (pins declared after the decouple, a
            // typo'd pin, or a pad/function-name mismatch) — the caps end up on
            // a stub net with no IC pad, silently disconnecting them from the
            // pin they "serve". Warn instead of splitting the net silently
            // (the `auto` path already errors loudly on zero matches).
            var reassigned = false;
            for (all_pin_nets.items) |*pn| {
                if (std.mem.eql(u8, pn.ref_des, ref_str) and
                    std.mem.eql(u8, pn.pin, target_pin) and
                    std.mem.eql(u8, pn.net, net_name))
                {
                    pn.net = sub_net;
                    reassigned = true;
                    break;
                }
            }
            if (!reassigned) {
                self.warnFmt(items[idx].span, "(decouple \"{s}\" … per-pin {s} …) pin '{s}' is not on net \"{s}\" — the cap is on a stub net with no IC pad (declare the pin first, or check the pad/function name)", .{ net_name, ref_str, target_pin, net_name });
            }
        }
        idx = pin_idx;
    }
}

const DecoupleIdentity = struct { id: []const u8, label: []const u8, origin: []const u8 };
const DecoupleIdentitySpec = struct {
    child_key: []const u8,
    function_name: []const u8,
    replica: u32,
    fallback_ref: []const u8,
};

fn decoupleIdentity(
    self: *Evaluator,
    sidecar: *ids.ChildIdSidecar,
    form_id: []const u8,
    spec: DecoupleIdentitySpec,
) EvalError!DecoupleIdentity {
    const label = if (spec.function_name.len > 0)
        try decoupleLabel(self, spec.function_name, spec.replica)
    else
        spec.fallback_ref;
    const id = if (sidecar.map.get(spec.child_key)) |existing|
        existing
    else if (self.hierarchical_ids)
        try ids.deriveChildId(self, form_id, spec.child_key, 0)
    else
        try ids.getOrCreateChildId(self, sidecar, spec.child_key);
    return .{ .id = id, .label = label, .origin = if (spec.function_name.len > 0) label else spec.child_key };
}

/// Turn a pin-function token into the readable name promised by compact
/// per-pin decoupling: `VCCCP` -> `C_VCCCP`; replicas gain `_2`, `_3`, ….
/// Non-refdes punctuation is normalized so generated labels remain portable to
/// KiCad and every report surface.
fn decoupleLabel(self: *Evaluator, function_name: []const u8, replica: u32) EvalError![]const u8 {
    var clean = std.ArrayList(u8).empty;
    clean.appendSlice(self.allocator, "C_") catch return EvalError.OutOfMemory;
    for (function_name) |c| {
        clean.append(self.allocator, if (std.ascii.isAlphanumeric(c)) std.ascii.toUpper(c) else '_') catch
            return EvalError.OutOfMemory;
    }
    if (replica > 0) {
        const suffix = std.fmt.allocPrint(self.allocator, "_{d}", .{replica + 1}) catch return EvalError.OutOfMemory;
        clean.appendSlice(self.allocator, suffix) catch return EvalError.OutOfMemory;
    }
    return clean.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory;
}

/// Emit shared rail-to-ground capacitors for the compact `(bulk (cap …) N)`
/// clause of `(decouple "RAIL" …)`. Bulk parts deliberately do not split an
/// IC pad onto a stub net; they are annotated `(decouples rail)` exactly like a
/// hand-written `(instance … (decouples rail))`.
pub const DecoupleEmitContext = struct {
    instances: *std.ArrayList(Instance),
    pin_nets: *std.ArrayList(PinNetDecl),
    form_id: []const u8,
    sidecar: *ids.ChildIdSidecar,
};

/// Emit the shared rail-to-ground capacitors in one compact `(bulk …)` clause.
pub fn emitBulkDecouples(
    self: *Evaluator,
    component_node: Node,
    count_node: Node,
    net_name: []const u8,
    env: *Env,
    ctx: DecoupleEmitContext,
) EvalError!void {
    const comp_val = try self.evalNode(component_node, env);
    const resolved = instance_mod.resolveComponent(self, comp_val) orelse {
        self.setError(component_node.span, "(bulk …) first argument must be a capacitor component");
        return EvalError.TypeError;
    };
    const count_value = (try self.evalNode(count_node, env)).asNumber() orelse {
        self.setError(count_node.span, "(bulk …) count must be a non-negative integer");
        return EvalError.TypeError;
    };
    const count = numeric.checkedInt(u32, count_value) orelse {
        self.setError(count_node.span, "(bulk …) count must be a non-negative integer");
        return EvalError.InvalidForm;
    };
    const source_offset = ids.componentSourceOffset(component_node);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const ref = try ids.nextRefDes(self, 'C');
        const label_seed = std.fmt.allocPrint(self.allocator, "{s}_BULK", .{net_name}) catch return EvalError.OutOfMemory;
        const label = try decoupleLabel(self, label_seed, i);
        const child_key = std.fmt.allocPrint(self.allocator, "bulk:{s}#{d}", .{ resolved.value, i }) catch return EvalError.OutOfMemory;
        const cap_id = if (ctx.sidecar.map.get(child_key)) |existing|
            existing
        else if (self.hierarchical_ids)
            try ids.deriveChildId(self, ctx.form_id, child_key, 0)
        else
            try ids.getOrCreateChildId(self, ctx.sidecar, child_key);
        try ctx.instances.append(self.allocator, .{
            .ref_des = ref,
            .label = label,
            .origin_key = label,
            .component = resolved.family,
            .value = resolved.value,
            .footprint = resolved.footprint,
            .symbol = resolved.symbol,
            .attrs = resolved.attrs,
            .source_offset = source_offset,
            .id = cap_id,
            .bind = .{ .decouple = .{ .rail = true } },
        });
        try ctx.pin_nets.append(self.allocator, .{ .ref_des = ref, .pin = "1", .net = net_name });
        try ctx.pin_nets.append(self.allocator, .{ .ref_des = ref, .pin = "2", .net = "GND" });
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
    all_pin_nets: *std.ArrayList(PinNetDecl),
    ref: []const u8,
    net: []const u8,
    span: ast.Span,
    target_pins: *std.ArrayList([]const u8),
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

fn isBoardSideKeyword(s: []const u8) bool {
    return std.mem.eql(u8, s, "left") or std.mem.eql(u8, s, "right") or
        std.mem.eql(u8, s, "top") or std.mem.eql(u8, s, "bottom");
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
    var kind: []const u8 = "";
    var side: []const u8 = "";
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
        } else if (arg.isForm("side")) {
            // (side left|right|top|bottom) — where this port's net enters or
            // leaves the module; the PCB rough placer's explicit flow hint.
            const sc = arg.asList().?;
            const word = if (sc.len >= 2) sc[1].asAtom() orelse "" else "";
            if (isBoardSideKeyword(word)) {
                side = word;
            } else {
                self.warnFmt(arg.span, "(side …) in (port \"{s}\" …) expects left|right|top|bottom", .{name});
            }
        } else if (arg.asAtom()) |kw| {
            if (std.mem.eql(u8, kw, "optional")) {
                is_optional = true;
            } else if (std.mem.eql(u8, kw, "role") or std.mem.eql(u8, kw, "protocol") or std.mem.eql(u8, kw, "class")) {
                // Metadata keywords mirror the section-port form; consume their
                // following value token (parsePort doesn't store them on Port).
                skip_kw_value = true;
            } else if (isSignalTypeKeyword(kw)) {
                // Signal-type words (power/clock/rf/…): kept as the port's kind
                // so the placer can read flow context off power/rf ports.
                kind = kw;
            } else {
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
        .kind = kind,
        .side = side,
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
        self.setError(args[1].span, "(group …) members must be a ref-des LIST; (diagram-layout …) group takes blocks");
        return EvalError.InvalidForm;
    };

    var members: std.ArrayList([]const u8) = .empty;
    for (members_node) |m| {
        const s = m.asString() orelse {
            self.setError(m.span, "(group …) members must be ref-des strings; (diagram-layout …) group takes blocks");
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

/// Build a `(function "name" ["caption"] [(stack N)] (hosts "A" "B" …))` form
/// into a `FunctionSpec` — the hand-authored top-level system-view block. The
/// bare string after the name is the what-it-does caption; `hosts` members
/// name authored sections / sheet titles (matched by the editor's bands).
pub fn buildFunction(self: *Evaluator, args: []const Node, env: *Env) EvalError!env_mod.FunctionSpec {
    if (args.len == 0) {
        self.setError(ast.Span.zero, "(function …) expects a name — (function \"PSU\" \"0-18V, 3A\" (hosts \"Channel 1 PSU\"))");
        return EvalError.ArityError;
    }
    const name_val = try self.evalNode(args[0], env);
    var spec = env_mod.FunctionSpec{
        .name = name_val.asString() orelse {
            self.setError(args[0].span, "(function …) name must be a string");
            return EvalError.TypeError;
        },
    };
    var hosts: std.ArrayList([]const u8) = .empty;
    for (args[1..]) |arg| {
        const sub = arg.asList() orelse {
            const cap_val = try self.evalNode(arg, env);
            spec.caption = cap_val.asString() orelse {
                self.setError(arg.span, "(function …) caption must be a string");
                return EvalError.TypeError;
            };
            continue;
        };
        if (sub.len == 0) continue;
        const head = sub[0].asAtom() orelse "";
        if (std.mem.eql(u8, head, "stack")) {
            if (sub.len != 2) {
                self.setError(arg.span, "(stack N) expects one count");
                return EvalError.ArityError;
            }
            const v = try self.evalNode(sub[1], env);
            const n = v.asNumber() orelse {
                self.setError(sub[1].span, "(stack N) count must be a number");
                return EvalError.TypeError;
            };
            spec.stack = if (n < 1) 1 else if (n > 99) 99 else (numeric.checkedInt(u8, n) orelse 1);
        } else if (std.mem.eql(u8, head, "hosts")) {
            for (sub[1..]) |m| {
                const s = m.asString() orelse {
                    self.setError(m.span, "(hosts …) members must be section-name strings");
                    return EvalError.TypeError;
                };
                try hosts.append(self.allocator, s);
            }
        } else {
            self.warnFmt(arg.span, "unknown sub-form ({s} …) in (function …)", .{head});
        }
    }
    spec.hosts = hosts.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory;
    return spec;
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
            var existing_parts: std.ArrayList(env_mod.Part) = .empty;
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
    // Note: we don't free source because AST references slices into it.
    var diag: parser_mod.ParseDiagnostic = .{};
    const nodes = parser_mod.parseDiag(self.allocator, source, &diag) catch {
        // Stash the located syntax error so callers render file:line:col + caret.
        self.setError(diag.span, diag.message);
        return null;
    };
    // Key on a dup owned by `self.allocator`, never on the caller's slice: the
    // read-set outlives the call, and every caller of note frees its path right
    // afterwards (`resolveBlock` does so in a `defer` inside its own `if`). A
    // borrowed key therefore left a DANGLING path in `loaded_files` — the one
    // entry naming the design's own source file — so every mtime-based cache
    // built from that read-set (`serve/page_cache.zig` and both its users)
    // stamped poison bytes, recorded them "absent", and then never invalidated
    // when the design itself was edited. Mirrors the import path's own dup in `eval/modules.zig`.
    if (self.allocator.dupe(u8, path)) |key| {
        self.loaded_files.put(self.allocator, key, nodes) catch {
            self.allocator.free(key);
            return null;
        };
    } else |_| return null;
    return nodes;
}

/// Load a top-level design file: `loadFile` plus an autoloader that splices a
/// sibling `<name>.checks.sexp`'s forms into the trailing `(design-block …)`.
/// Library imports call `loadFile` directly, so module files aren't spliced.
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

test "parseSectionPort reads the class keyword value" {
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var env = env_mod.Env.init(alloc, null);
    defer env.deinit();

    // `class KEY` steps forward past the keyword to read its value; the `si += 1`
    // advance is what makes that terminate. (A `-=` flip re-reads "class" forever,
    // so a parse that terminates with class="diff" pins the operator.)
    const nodes = try parser_mod.parse(alloc, "(port \"NET\" in class \"diff\")");
    const port = (try parseSectionPort(&eval, nodes[0].asList().?, &env)).?;
    try testing.expectEqualStrings("diff", port.class);
}

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
    var instances: std.ArrayList(Instance) = .empty;
    var all_pin_nets: std.ArrayList(PinNetDecl) = .empty;
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
    var instances: std.ArrayList(Instance) = .empty;
    var all_pin_nets: std.ArrayList(PinNetDecl) = .empty;
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
    var instances: std.ArrayList(Instance) = .empty;
    var all_pin_nets: std.ArrayList(PinNetDecl) = .empty;
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
    var instances: std.ArrayList(Instance) = .empty;
    var all_pin_nets: std.ArrayList(PinNetDecl) = .empty;
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
    var instances: std.ArrayList(Instance) = .empty;
    var all_pin_nets: std.ArrayList(PinNetDecl) = .empty;
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
    var instances: std.ArrayList(Instance) = .empty;
    var all_pin_nets: std.ArrayList(PinNetDecl) = .empty;
    var sidecar = ids.ChildIdSidecar{ .map = .empty, .parent_offset = 0 };

    try emitDecoupleItems(&eval, nodes, "VDD", &env, &instances, &all_pin_nets, "abcd1234", &sidecar);

    try testing.expectEqual(@as(usize, 2), instances.items.len);
    try testing.expectEqualStrings("100nF@7#0", instances.items[0].origin_key);
    try testing.expectEqualStrings("VDD.U1.7", all_pin_nets.items[0].net);
}

/// Shared fixture for the per-pin decouple tests: an evaluator in
/// hierarchical-ids mode (deterministic child ids), a cap family, and U1's
/// J14/K14 pins pre-declared on VDD the way an earlier (pins …) form would have.
fn pinsOfFixture(alloc: std.mem.Allocator, eval: *Evaluator, all_pin_nets: *std.ArrayList(PinNetDecl)) !void {
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
    var nets: std.ArrayList(PinNetDecl) = .empty;
    try pinsOfFixture(alloc, &eval, &nets);
    eval.decouple_defaults.ic = "U1";
    var env = env_mod.Env.init(alloc, null);
    defer env.deinit();
    var instances: std.ArrayList(Instance) = .empty;
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
    var nets: std.ArrayList(PinNetDecl) = .empty;
    try pinsOfFixture(alloc, &eval, &nets);
    var env = env_mod.Env.init(alloc, null);
    defer env.deinit();
    var instances: std.ArrayList(Instance) = .empty;
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
    var nets: std.ArrayList(PinNetDecl) = .empty;
    try pinsOfFixture(alloc, &eval, &nets);
    eval.decouple_defaults.ic = "U1";
    var env = env_mod.Env.init(alloc, null);
    defer env.deinit();
    var instances: std.ArrayList(Instance) = .empty;
    var sidecar = ids.ChildIdSidecar{ .map = .empty, .parent_offset = 0 };

    // U1 has no pins on VDDA — the (pins …) for that rail hasn't run yet.
    const items = try parser_mod.parse(alloc, "(cap-0201 \"100nF\") 1 per-pin auto");
    const r = emitDecoupleItems(&eval, items, "VDDA", &env, &instances, &nets, "abcd1234", &sidecar);
    try testing.expectError(error.InvalidForm, r);
    const diag = eval.last_error orelse return error.TestExpectedDiagnostic;
    try testing.expect(std.mem.indexOf(u8, diag.message, "no pins of \"U1\" on net \"VDDA\"") != null);
    try testing.expect(std.mem.indexOf(u8, diag.message, "(pins …) declarations must appear before (decouple …)") != null);
}

// spec: eval/design_block - a bus-port index range whose lane span would overflow the i64 subtraction is diagnosed and expands nothing
test "bus-port rejects an index range whose span overflows i64" {
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var env = env_mod.Env.init(alloc, null);
    defer env.deinit();

    // The endpoints are individually in i64 range, but they are ~1.8e19 apart:
    // an i64 `end - start` wraps *negative*, which used to slip past the
    // `>= max_bus_port_expansion` cap and run the expansion loop ~2^64 times,
    // allocating a port per iteration. Reachable over HTTP via push/validate.
    const src = "(bus-port \"X\" -9000000000000000000 9000000000000000000 (suffixes A))";
    const children = (try parser_mod.parse(alloc, src))[0].asList().?;

    var section_ports: std.ArrayList(env_mod.SectionPort) = .empty;
    try expandSectionBusPort(&eval, children, &env, &section_ports);
    try testing.expectEqual(@as(usize, 0), section_ports.items.len);

    var top_ports: std.ArrayList(Port) = .empty;
    try expandTopLevelBusPort(&eval, children, &env, &top_ports);
    try testing.expectEqual(@as(usize, 0), top_ports.items.len);

    // Both attempts diagnose rather than dropping the form silently.
    try testing.expectEqual(@as(usize, 2), eval.warnings.items.len);
    try testing.expect(std.mem.indexOf(u8, eval.warnings.items[0].message, "negative start index") != null);
    try testing.expect(std.mem.indexOf(u8, eval.warnings.items[1].message, "negative start index") != null);

    // A non-negative range far past the cap still trips the lane cap itself.
    const wide = (try parser_mod.parse(alloc, "(bus-port \"Y\" 0 9000000000000000000 in)"))[0].asList().?;
    var wide_ports: std.ArrayList(Port) = .empty;
    try expandTopLevelBusPort(&eval, wide, &env, &wide_ports);
    try testing.expectEqual(@as(usize, 0), wide_ports.items.len);
    try testing.expectEqual(@as(usize, 3), eval.warnings.items.len);
    try testing.expect(std.mem.indexOf(u8, eval.warnings.items[2].message, "exceeds the 4096-lane cap") != null);
}

// spec: eval/design_block - a zero-based bus-port range still expands and the lane cap admits a span of exactly 4095
test "bus-port still expands an ordinary index range" {
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var env = env_mod.Env.init(alloc, null);
    defer env.deinit();

    // Zero-based range: the guard rejects negatives, never a legitimate 0 start.
    const children = (try parser_mod.parse(alloc, "(bus-port \"D\" 0 3 (suffixes P N) in)"))[0].asList().?;

    var section_ports: std.ArrayList(env_mod.SectionPort) = .empty;
    try expandSectionBusPort(&eval, children, &env, &section_ports);
    try testing.expectEqual(@as(usize, 8), section_ports.items.len);
    try testing.expectEqualStrings("D0P", section_ports.items[0].name);
    try testing.expectEqualStrings("D3N", section_ports.items[7].name);

    var top_ports: std.ArrayList(Port) = .empty;
    try expandTopLevelBusPort(&eval, children, &env, &top_ports);
    try testing.expectEqual(@as(usize, 8), top_ports.items.len);
    try testing.expectEqualStrings("D0P", top_ports.items[0].name);
    try testing.expectEqualStrings("D3N", top_ports.items[7].name);

    // Nothing above warned.
    try testing.expectEqual(@as(usize, 0), eval.warnings.items.len);

    // Cap boundary, asserted on the header alone so the test doesn't allocate
    // thousands of ports: a 4095 span is admitted, a 4096 span is not.
    const at_cap = (try parser_mod.parse(alloc, "(bus-port \"E\" 0 4095 in)"))[0].asList().?;
    const admitted = (try parseBusPortHeader(&eval, at_cap, &env)).?;
    try testing.expectEqual(@as(i64, 0), admitted.start);
    try testing.expectEqual(@as(i64, 4095), admitted.end);
    try testing.expectEqual(@as(usize, 0), eval.warnings.items.len);

    const over_cap = (try parser_mod.parse(alloc, "(bus-port \"E\" 0 4096 in)"))[0].asList().?;
    try testing.expect((try parseBusPortHeader(&eval, over_cap, &env)) == null);
    try testing.expectEqual(@as(usize, 1), eval.warnings.items.len);
    try testing.expect(std.mem.indexOf(u8, eval.warnings.items[0].message, "exceeds the 4096-lane cap") != null);
}

// spec: eval/design_block - diff-port expands one base name into a paired _P and _N port carrying the differential kind
// spec: eval/design_block - diff-port replays every trailing port modifier onto both lanes
test "diff-port expands both lanes with the differential kind and shared modifiers" {
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var env = env_mod.Env.init(alloc, null);
    defer env.deinit();

    const nodes = try parser_mod.parse(alloc, "(diff-port \"AINA_EXT\" in optional (rated -2.5 2.5) (side left))");
    var ports: std.ArrayList(Port) = .empty;
    try expandTopLevelDiffPort(&eval, nodes[0].asList().?, &env, &ports);

    try testing.expectEqual(@as(usize, 2), ports.items.len);
    try testing.expectEqualStrings("AINA_EXT_P", ports.items[0].name);
    try testing.expectEqualStrings("AINA_EXT_N", ports.items[1].name);
    for (ports.items) |p| {
        // Short form: each lane's net is its own name, exactly as the two
        // hand-written (port "AINA_EXT_P" in differential) lines produced.
        try testing.expectEqualStrings(p.name, p.net);
        try testing.expectEqualStrings("in", p.direction);
        try testing.expectEqualStrings("differential", p.kind);
        try testing.expectEqualStrings("AINA_EXT", p.diff_pair_of);
        try testing.expect(p.optional);
        try testing.expectEqual(@as(f64, -2.5), p.rated_min.?);
        try testing.expectEqual(@as(f64, 2.5), p.rated_max.?);
        try testing.expectEqualStrings("left", p.side);
    }
}

// spec: eval/design_block - a diff-port suffixes override renames both lanes and a long-form net base is suffixed per lane
test "diff-port honours a suffixes override and a long-form net base" {
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var env = env_mod.Env.init(alloc, null);
    defer env.deinit();

    const nodes = try parser_mod.parse(alloc, "(diff-port \"RFIN1\" \"LNA_IN\" in rf (suffixes \"+\" \"-\"))");
    var ports: std.ArrayList(Port) = .empty;
    try expandTopLevelDiffPort(&eval, nodes[0].asList().?, &env, &ports);

    try testing.expectEqual(@as(usize, 2), ports.items.len);
    try testing.expectEqualStrings("RFIN1+", ports.items[0].name);
    try testing.expectEqualStrings("LNA_IN+", ports.items[0].net);
    try testing.expectEqualStrings("RFIN1-", ports.items[1].name);
    try testing.expectEqualStrings("LNA_IN-", ports.items[1].net);
    // An explicit signal-type word wins; the pairing lives in diff_pair_of.
    try testing.expectEqualStrings("rf", ports.items[0].kind);
    try testing.expectEqualStrings("RFIN1", ports.items[1].diff_pair_of);
}

// spec: eval/design_block - a section-scope diff-port expands two section ports typed differential
test "expandSectionDiffPort types both lanes differential" {
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var env = env_mod.Env.init(alloc, null);
    defer env.deinit();

    const nodes = try parser_mod.parse(alloc, "(diff-port \"ADF_CH1\" out)");
    var ports: std.ArrayList(env_mod.SectionPort) = .empty;
    try expandSectionDiffPort(&eval, nodes[0].asList().?, &env, &ports);

    try testing.expectEqual(@as(usize, 2), ports.items.len);
    try testing.expectEqualStrings("ADF_CH1_P", ports.items[0].name);
    try testing.expectEqualStrings("ADF_CH1_N", ports.items[1].name);
    for (ports.items) |p| {
        try testing.expectEqual(env_mod.PortDirection.out, p.direction);
        try testing.expectEqual(env_mod.SignalType.differential, p.signal_type);
    }
}

// spec: eval/design_block - a diff-port missing its direction is an arity error naming the form
test "diff-port without a direction is an arity error" {
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var env = env_mod.Env.init(alloc, null);
    defer env.deinit();

    const nodes = try parser_mod.parse(alloc, "(diff-port \"AINA_EXT\")");
    var ports: std.ArrayList(Port) = .empty;
    try testing.expectError(EvalError.ArityError, expandTopLevelDiffPort(&eval, nodes[0].asList().?, &env, &ports));
    const diag = eval.last_error orelse return error.TestExpectedDiagnostic;
    try testing.expect(std.mem.indexOf(u8, diag.message, "(diff-port …)") != null);
}
