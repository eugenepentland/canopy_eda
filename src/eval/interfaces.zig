//! Interface bundles: named signal vocabularies for the buses that are NOT
//! numbered lanes.
//!
//! `bus-port`/`bus-net` already write a wide bus once, because a wide bus is a
//! prefix plus an integer. SPI, I²C, UART, SWD and JTAG are not: their lanes
//! have *names*, the names have variants (SCK/SCLK, MOSI/SDI, CS/CSN/NCS/SS),
//! and every module in the corpus re-spells them by hand — 269 `(rename …)`
//! forms on the boards, 36 of them for SPI/I²C alone. An `(interface …)`
//! definition states the vocabulary once; `(port-group …)` declares a module's
//! boundary from it; `(bridge-interface …)` wires a sub-block's group to board
//! nets in one line instead of one `(rename …)` per signal.
//!
//! Direction is always stated from the PERIPHERAL's point of view — a
//! peripheral is clocked (`SCK in`), receives (`MOSI in`) and answers
//! (`MISO out`). `(role controller)` flips every direction, so the same
//! definition serves both ends of the link. Bidirectional signals (I²C's two
//! open-drain lines, SWD's data line) are unchanged by the flip.
//!
//! Definitions resolve exactly the way library parts do (see `src/stdlib.zig`):
//! a project's own `lib/interfaces/<name>.sexp` wins, then `--lib-dir`, then
//! `NETLISP_STDLIB_DIR`, then the table `build.zig` embedded from
//! `stdlib/interfaces/`. A file need not exist at all — an `(interface …)`
//! written at the top level of a design or module file registers the same way.

const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const parser_mod = @import("../sexpr/parser.zig");
const env_mod = @import("env.zig");
const forms_mod = @import("forms.zig");
const stdlib_mod = @import("../stdlib.zig");
const lib_limits = @import("../lib_limits.zig");
const evaluator_mod = @import("evaluator.zig");
const builders = @import("builders.zig");
const modules = @import("modules.zig");
const infra_fs = @import("../infra/fs.zig");

const Node = ast.Node;
const Env = env_mod.Env;
const Port = env_mod.Port;
const PortGroup = env_mod.PortGroup;
const PortGroupMember = env_mod.PortGroupMember;
const Evaluator = evaluator_mod.Evaluator;
const EvalError = evaluator_mod.EvalError;

/// Where a definition file lives, relative to a project root. Same shape every
/// other library sub-path has, so `stdlib.open` resolves it with no new rules.
pub const lib_sub_dir = "lib/interfaces/";

/// The role a block plays on the bus. `peripheral` is the definition's own
/// point of view and needs no flip; `controller` mirrors every direction.
pub const Role = enum { peripheral, controller };

/// One named lane of an interface bundle.
pub const Signal = struct {
    /// Bare signal name as the vocabulary spells it (`SCK`, `MOSI`, `SDA`).
    name: []const u8,
    /// `in` / `out` / `bidi` / `io`, from the PERIPHERAL's point of view.
    direction: []const u8,
    /// Signal-type keyword replayed onto the expanded port (`clock`, `data`,
    /// …). Empty when the definition states none.
    kind: []const u8 = "",
    /// Lanes a link may legitimately leave unwired (UART's CTS/RTS, JTAG's
    /// TRST). ERC's both-or-neither rule never demands one of these.
    optional: bool = false,
};

/// A whole bundle: `(interface NAME ["doc"] (signal …)…)`.
pub const Def = struct {
    name: []const u8,
    doc: []const u8 = "",
    signals: []const Signal = &.{},

    /// The lane named `name`, or null. Case-sensitive: signal vocabularies are
    /// upper-case by convention and a near-miss should read as a typo.
    pub fn signal(self: Def, name: []const u8) ?Signal {
        for (self.signals) |s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }
};

/// `direction` as the opposite end of the link sees it. A bidirectional lane
/// is its own mirror — an open-drain I²C line and SWD's `SWDIO` are driven
/// from both ends whichever role a block plays.
pub fn flip(direction: []const u8) []const u8 {
    if (std.mem.eql(u8, direction, "in")) return "out";
    if (std.mem.eql(u8, direction, "out")) return "in";
    return direction;
}

/// `PREFIX` + `SIGNAL`, joined by exactly one underscore. An empty prefix
/// gives the bare signal name; a prefix that already ends in `_` — the
/// spelling `(bridge "IMU_" …)` established — does not gain a second one.
pub fn joinName(allocator: std.mem.Allocator, prefix: []const u8, signal: []const u8) EvalError![]const u8 {
    if (prefix.len == 0) return allocator.dupe(u8, signal) catch EvalError.OutOfMemory;
    const sep: []const u8 = if (prefix[prefix.len - 1] == '_') "" else "_";
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ prefix, sep, signal }) catch EvalError.OutOfMemory;
}

/// The group name a `(port-group "PREFIX" iface …)` takes: its prefix, or the
/// interface's own name when the prefix is empty (bare `SCK`/`MOSI` ports
/// still need something for `(bridge-interface "GROUP" …)` to address).
pub fn groupName(prefix: []const u8, iface: []const u8) []const u8 {
    return if (prefix.len > 0) prefix else iface;
}

// ── (interface …) definitions ─────────────────────────────────────────

/// Evaluate a top-level `(interface NAME ["doc"] (signal …)…)` and register it
/// under NAME. Re-registering the same name replaces the earlier definition —
/// a project file read after a bundled one is exactly that case.
pub fn evalDefinition(self: *Evaluator, args: []const Node) EvalError!env_mod.Value {
    const def = try parseDefinition(self, args);
    try register(self, def);
    return .nil;
}

/// Parse the body of an `(interface …)` form. `args` excludes the head atom.
pub fn parseDefinition(self: *Evaluator, args: []const Node) EvalError!Def {
    if (args.len < 2) {
        const span = if (args.len > 0) args[0].span else ast.Span.zero;
        self.setError(span, "(interface …) expects a name and at least one (signal …), e.g. (interface spi (signal SCK in clock))");
        return EvalError.ArityError;
    }
    const name = args[0].asText() orelse {
        self.setError(args[0].span, "(interface …) name must be a bare atom, e.g. (interface spi …)");
        return EvalError.InvalidForm;
    };
    var rest = args[1..];
    var doc: []const u8 = "";
    if (rest.len > 0) {
        if (rest[0].asString()) |s| {
            doc = s;
            rest = rest[1..];
        }
    }
    var signals: std.ArrayList(Signal) = .empty;
    for (rest) |child| {
        if (!child.isForm("signal")) {
            self.warnFmt(child.span, "unknown sub-form ({s} …) in (interface {s} …)", .{ formHead(child), name });
            continue;
        }
        if (try parseSignal(self, child)) |sig| try signals.append(self.allocator, sig);
    }
    if (signals.items.len == 0) {
        self.setErrorFmt(args[0].span, "(interface {s} …) declares no (signal …) lanes", .{name});
        return EvalError.InvalidForm;
    }
    return .{
        .name = name,
        .doc = doc,
        .signals = signals.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
    };
}

/// `(signal NAME dir [kind] [optional])`. A malformed row warns and is
/// skipped rather than failing the whole definition, so one bad lane cannot
/// take a library file's other four with it.
fn parseSignal(self: *Evaluator, node: Node) EvalError!?Signal {
    const children = node.asList().?;
    if (children.len < 3) {
        self.warnFmt(node.span, "(signal …) expects a name and a direction, e.g. (signal SCK in clock)", .{});
        return null;
    }
    const name = children[1].asText() orelse {
        self.warnFmt(children[1].span, "(signal …) name must be a bare atom or string", .{});
        return null;
    };
    const dir = children[2].asAtom() orelse {
        self.warnFmt(children[2].span, "(signal …) direction must be a bare word: in|out|io|bidi", .{});
        return null;
    };
    if (!isDirection(dir)) {
        self.warnFmt(children[2].span, "(signal {s} {s}) — direction must be in|out|io|bidi", .{ name, dir });
        return null;
    }
    var sig: Signal = .{ .name = name, .direction = dir };
    for (children[3..]) |extra| {
        const word = extra.asAtom() orelse continue;
        if (std.mem.eql(u8, word, "optional")) {
            sig.optional = true;
        } else {
            sig.kind = word;
        }
    }
    return sig;
}

fn isDirection(s: []const u8) bool {
    return std.mem.eql(u8, s, "in") or std.mem.eql(u8, s, "out") or
        std.mem.eql(u8, s, "io") or std.mem.eql(u8, s, "bidi");
}

fn formHead(node: Node) []const u8 {
    const children = node.asList() orelse return "?";
    if (children.len == 0) return "?";
    return children[0].asAtom() orelse "?";
}

/// Bind `def` into the evaluator's registry, replacing any same-named entry.
pub fn register(self: *Evaluator, def: Def) EvalError!void {
    const key = self.allocator.dupe(u8, def.name) catch return EvalError.OutOfMemory;
    const gop = self.interfaces.getOrPut(self.allocator, key) catch return EvalError.OutOfMemory;
    if (gop.found_existing) self.allocator.free(key);
    gop.value_ptr.* = def;
}

/// The definition named `name`: the registry first (an inline `(interface …)`
/// or an earlier load), then `lib/interfaces/<name>.sexp` through the standard
/// resolution order. Null when nothing carries it — the caller reports, so the
/// diagnostic can name the form that asked.
pub fn resolve(self: *Evaluator, name: []const u8) EvalError!?Def {
    if (self.interfaces.get(name)) |def| return def;
    const found = openDefinitionFile(self, name) orelse return null;
    const nodes = parser_mod.parse(self.allocator, found) catch {
        self.setErrorFmt(ast.Span.zero, "lib/interfaces/{s}.sexp does not parse", .{name});
        return EvalError.ImportError;
    };
    var wanted: ?Def = null;
    for (nodes) |node| {
        if (!node.isForm("interface")) continue;
        const def = try parseDefinition(self, node.asList().?[1..]);
        try register(self, def);
        if (std.mem.eql(u8, def.name, name)) wanted = def;
    }
    if (wanted == null) {
        self.setErrorFmt(ast.Span.zero, "lib/interfaces/{s}.sexp defines no (interface {s} …)", .{ name, name });
        return EvalError.ImportError;
    }
    return wanted;
}

/// The bytes of `lib/interfaces/<name>.sexp` from the first root that carries
/// it — the project, this evaluator's `lib_dir`, the `--lib-dir` root, exactly
/// the roots `(import …)` walks — then the standard library (a
/// `NETLISP_STDLIB_DIR` override, else the embedded table).
fn openDefinitionFile(self: *Evaluator, name: []const u8) ?[]u8 {
    var roots_buf: [3][]const u8 = undefined;
    for (modules.libSearchRoots(self, &roots_buf)) |root| {
        const path = std.fmt.allocPrint(self.allocator, "{s}/{s}{s}.sexp", .{ root, lib_sub_dir, name }) catch return null;
        defer self.allocator.free(path);
        if (infra_fs.cwd().readFileAlloc(self.allocator, path, lib_limits.max_lib_file_bytes)) |bytes| {
            return bytes;
        } else |_| {}
    }
    const sub_path = std.fmt.allocPrint(self.allocator, "{s}{s}.sexp", .{ lib_sub_dir, name }) catch return null;
    defer self.allocator.free(sub_path);
    const found = stdlib_mod.standard(self.allocator, sub_path, lib_limits.max_lib_file_bytes) orelse return null;
    self.allocator.free(found.path);
    return found.bytes;
}

// ── (port-group …) expansion ──────────────────────────────────────────

/// Parsed shape of one `(port-group …)` form.
const GroupSpec = struct {
    prefix: []const u8,
    def: Def,
    role: Role,
    /// Per-signal port-name overrides from `(rename SIGNAL "PORTNAME")`.
    renames: []const Rename,
    /// Signals dropped by `(omit SIGNAL…)` — a 3-wire SPI part with no MISO.
    omitted: []const []const u8,
    /// Trailing port modifiers replayed verbatim onto every lane, exactly the
    /// way `(diff-port …)` replays them onto both of its.
    rest: []const Node,
};

const Rename = struct { signal: []const u8, to: []const u8 };

/// Expand `(port-group "PREFIX" iface …)` into one `Port` per signal plus the
/// `PortGroup` record that keeps them a single thing for ERC and the UI.
pub fn expandPortGroup(
    self: *Evaluator,
    form_children: []const Node,
    env: *Env,
    ports: *std.ArrayList(Port),
    groups: *std.ArrayList(PortGroup),
) EvalError!void {
    const spec = try parseGroupSpec(self, form_children, env) orelse return;
    var members: std.ArrayList(PortGroupMember) = .empty;
    for (spec.def.signals) |sig| {
        if (contains(spec.omitted, sig.name)) continue;
        const port_name = try memberPortName(self, spec, sig.name);
        const args = try synthesizePortArgs(self, spec, sig, port_name);
        const port = try builders.buildPort(self, args, env);
        try ports.append(self.allocator, port);
        try members.append(self.allocator, .{
            .signal = sig.name,
            .port = port.name,
            .net = port.net,
            .optional = sig.optional or port.optional,
        });
    }
    if (members.items.len == 0) return;
    try groups.append(self.allocator, .{
        .name = groupName(spec.prefix, spec.def.name),
        .interface = spec.def.name,
        .role = @tagName(spec.role),
        .members = members.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
    });
}

fn memberPortName(self: *Evaluator, spec: GroupSpec, signal: []const u8) EvalError![]const u8 {
    for (spec.renames) |r| {
        if (std.mem.eql(u8, r.signal, signal)) return r.to;
    }
    return joinName(self.allocator, spec.prefix, signal);
}

/// One lane's `buildPort` args: the port name, the (possibly flipped)
/// direction, the interface's signal-type word, an `optional` marker for a
/// lane the vocabulary marks so, then the author's shared modifiers.
fn synthesizePortArgs(self: *Evaluator, spec: GroupSpec, sig: Signal, name: []const u8) EvalError![]Node {
    var buf: std.ArrayList(Node) = .empty;
    try buf.append(self.allocator, Node.string(ast.Span.zero, name));
    const dir = if (spec.role == .controller) flip(sig.direction) else sig.direction;
    try buf.append(self.allocator, Node.atom(ast.Span.zero, dir));
    if (sig.kind.len > 0) try buf.append(self.allocator, Node.atom(ast.Span.zero, sig.kind));
    if (sig.optional) try buf.append(self.allocator, Node.atom(ast.Span.zero, "optional"));
    for (spec.rest) |n| try buf.append(self.allocator, n);
    return buf.toOwnedSlice(self.allocator) catch EvalError.OutOfMemory;
}

fn parseGroupSpec(self: *Evaluator, form_children: []const Node, env: *Env) EvalError!?GroupSpec {
    if (form_children.len < 3) {
        const span = if (form_children.len > 0) form_children[0].span else ast.Span.zero;
        self.setError(span, "(port-group …) expects a prefix and an interface, e.g. (port-group \"IMU\" spi)");
        return EvalError.ArityError;
    }
    const prefix_val = try self.evalNode(form_children[1], env);
    const prefix = prefix_val.asString() orelse {
        self.setError(form_children[1].span, "(port-group …) prefix must be a string — write \"\" for bare signal names");
        return EvalError.TypeError;
    };
    const iface_name = form_children[2].asText() orelse {
        self.setError(form_children[2].span, "(port-group …) interface must be a bare atom, e.g. (port-group \"IMU\" spi)");
        return EvalError.InvalidForm;
    };
    const def = try resolve(self, iface_name) orelse {
        self.setErrorFmt(form_children[2].span, "unknown interface '{s}' — no (interface {s} …) in scope and no lib/interfaces/{s}.sexp", .{ iface_name, iface_name, iface_name });
        return EvalError.ImportError;
    };

    var role: Role = .peripheral;
    var renames: std.ArrayList(Rename) = .empty;
    var omitted: std.ArrayList([]const u8) = .empty;
    var rest: std.ArrayList(Node) = .empty;
    for (form_children[3..]) |child| {
        if (child.isForm("role")) {
            role = parseRole(self, child) orelse role;
        } else if (child.isForm("rename")) {
            try appendRename(self, child, def, &renames);
        } else if (child.isForm("omit")) {
            try appendOmits(self, child, def, &omitted);
        } else {
            try rest.append(self.allocator, child);
        }
    }
    return .{
        .prefix = prefix,
        .def = def,
        .role = role,
        .renames = renames.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
        .omitted = omitted.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
        .rest = rest.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
    };
}

fn parseRole(self: *Evaluator, node: Node) ?Role {
    const children = node.asList().?;
    const word = if (children.len >= 2) children[1].asText() else null;
    if (word) |w| {
        if (std.mem.eql(u8, w, "controller")) return .controller;
        if (std.mem.eql(u8, w, "peripheral")) return .peripheral;
    }
    self.warnFmt(node.span, "(role …) in (port-group …) expects controller or peripheral", .{});
    return null;
}

fn appendRename(self: *Evaluator, node: Node, def: Def, out: *std.ArrayList(Rename)) EvalError!void {
    const children = node.asList().?;
    if (children.len < 3) {
        self.warnFmt(node.span, "(rename …) in (port-group …) expects a signal and a port name", .{});
        return;
    }
    const signal = children[1].asText() orelse return;
    const to = children[2].asText() orelse return;
    if (def.signal(signal) == null) {
        self.warnFmt(children[1].span, "(rename {s} …) names no signal of interface '{s}'", .{ signal, def.name });
        return;
    }
    try out.append(self.allocator, .{ .signal = signal, .to = to });
}

fn appendOmits(self: *Evaluator, node: Node, def: Def, out: *std.ArrayList([]const u8)) EvalError!void {
    for (node.asList().?[1..]) |item| {
        const signal = item.asText() orelse continue;
        if (def.signal(signal) == null) {
            self.warnFmt(item.span, "(omit {s}) names no signal of interface '{s}'", .{ signal, def.name });
            continue;
        }
        try out.append(self.allocator, signal);
    }
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |s| {
        if (std.mem.eql(u8, s, needle)) return true;
    }
    return false;
}

// ── (bridge-interface …) on a sub-block ───────────────────────────────

/// A `(bridge-interface …)` child parsed but not yet resolved. Board-level
/// `(port-group …)` forms may be written after the `(sub-block …)` that binds
/// to them, so the ties are emitted in one pass at the end of the block body
/// rather than at the sub-block's own dispatch.
pub const PendingBridge = struct {
    sub_name: []const u8,
    block: *const env_mod.DesignBlock,
    group: []const u8,
    /// `(to "NET_PREFIX")` — board nets named `NET_PREFIX_SIGNAL`.
    to_prefix: ?[]const u8 = null,
    /// `(to-group "BOARDGROUP")` — the board's own group of the same bus.
    to_group: ?[]const u8 = null,
    renames: []const Rename = &.{},
    span: ast.Span,
};

/// Collect every `(bridge-interface …)` child of one `(sub-block …)`.
pub fn collectSubBlockBridges(
    self: *Evaluator,
    form_children: []const Node,
    sub: env_mod.SubBlock,
    out: *std.ArrayList(PendingBridge),
) EvalError!void {
    for (form_children[1..]) |child| {
        if (!child.isForm("bridge-interface")) continue;
        if (try parseBridge(self, child, sub)) |pending| try out.append(self.allocator, pending);
    }
}

fn parseBridge(self: *Evaluator, node: Node, sub: env_mod.SubBlock) EvalError!?PendingBridge {
    const children = node.asList().?;
    if (children.len < 2) {
        self.warnFmt(node.span, "(bridge-interface …) expects a group name, e.g. (bridge-interface \"SPI\" (to \"IMU\"))", .{});
        return null;
    }
    const group = children[1].asText() orelse {
        self.warnFmt(children[1].span, "(bridge-interface …) group name must be a string", .{});
        return null;
    };
    var pending: PendingBridge = .{
        .sub_name = sub.name,
        .block = sub.block,
        .group = group,
        .span = node.span,
    };
    var renames: std.ArrayList(Rename) = .empty;
    for (children[2..]) |child| {
        const head = formHead(child);
        if (!forms_mod.isDirectSubForm(forms_mod.bridge_interface_form_docs, head)) {
            self.warnFmt(child.span, "unknown sub-form ({s} …) in (bridge-interface …)", .{head});
            continue;
        }
        const cc = child.asList().?;
        if (cc.len < 2) continue;
        if (std.mem.eql(u8, head, "to")) {
            pending.to_prefix = cc[1].asText();
        } else if (std.mem.eql(u8, head, "to-group")) {
            pending.to_group = cc[1].asText();
        } else if (cc.len >= 3) {
            const signal = cc[1].asText() orelse continue;
            const to = cc[2].asText() orelse continue;
            try renames.append(self.allocator, .{ .signal = signal, .to = to });
        }
    }
    if (pending.to_prefix == null and pending.to_group == null and renames.items.len == 0) {
        self.warnFmt(node.span, "(bridge-interface \"{s}\" …) names no destination — add (to \"NET_PREFIX\") or (to-group \"BOARDGROUP\")", .{group});
        return null;
    }
    pending.renames = renames.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory;
    return pending;
}

/// Turn every collected `(bridge-interface …)` into the same net ties the
/// `(bridge …)` lines it replaces would have emitted. `board_groups` are the
/// enclosing block's own `(port-group …)` records, for `(to-group …)`.
pub fn resolveBridges(
    self: *Evaluator,
    pending: []const PendingBridge,
    board_groups: []const PortGroup,
    net_ties: *std.ArrayList(Evaluator.NetTie),
) EvalError!void {
    for (pending) |bridge| {
        const group = findGroup(bridge.block.port_groups, bridge.group) orelse {
            self.warnFmt(bridge.span, "(bridge-interface \"{s}\" …) — sub-block \"{s}\" declares no (port-group \"{s}\" …)", .{ bridge.group, bridge.sub_name, bridge.group });
            continue;
        };
        const board = if (bridge.to_group) |name| findGroup(board_groups, name) orelse {
            self.warnFmt(bridge.span, "(bridge-interface … (to-group \"{s}\")) — this block declares no (port-group \"{s}\" …)", .{ name, name });
            continue;
        } else null;
        for (group.members) |member| {
            const net = try bridgeNet(self, bridge, board, member) orelse continue;
            const far = std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ bridge.sub_name, member.port }) catch return EvalError.OutOfMemory;
            try net_ties.append(self.allocator, .{ .a = net, .b = far });
        }
    }
}

/// The board net one member ties to: an explicit `(rename SIGNAL "NET")`
/// first, then the board group's own port for that signal, then the
/// `(to "PREFIX")` join. Null when a `(to-group …)` peer has no such signal —
/// a 3-wire peripheral bridged onto a 4-wire board bus, which is fine.
fn bridgeNet(
    self: *Evaluator,
    bridge: PendingBridge,
    board: ?PortGroup,
    member: PortGroupMember,
) EvalError!?[]const u8 {
    for (bridge.renames) |r| {
        if (std.mem.eql(u8, r.signal, member.signal)) return r.to;
    }
    if (board) |g| {
        for (g.members) |peer| {
            if (std.mem.eql(u8, peer.signal, member.signal)) return peer.net;
        }
        return null;
    }
    const prefix = bridge.to_prefix orelse return null;
    return try joinName(self.allocator, prefix, member.signal);
}

fn findGroup(groups: []const PortGroup, name: []const u8) ?PortGroup {
    for (groups) |g| {
        if (std.mem.eql(u8, g.name, name)) return g;
    }
    return null;
}

// ── Naming vocabulary, for the advisory lint ──────────────────────────
//
// The `interface_naming` lint has to recognise the spellings the corpus
// already uses without an evaluator in hand, so the variants live here as
// data. A test below holds this table against the bundled definitions: every
// canonical signal of a shipped interface must appear as a `canonical` row, so
// the two cannot drift apart silently.

/// One recognised port-name token and the interface signal it stands for.
pub const Variant = struct {
    /// Token as it appears at the end of a port name (`SCLK`, `CSN`, `NCS`).
    token: []const u8,
    /// The interface signal it means (`SCK`, `CS`).
    canonical: []const u8,
};

/// One interface's naming vocabulary for the lint.
pub const Vocabulary = struct {
    interface: []const u8,
    variants: []const Variant,
};

pub const vocabularies = [_]Vocabulary{
    .{ .interface = "spi", .variants = &.{
        .{ .token = "SCK", .canonical = "SCK" },
        .{ .token = "SCLK", .canonical = "SCK" },
        .{ .token = "SPICLK", .canonical = "SCK" },
        .{ .token = "MOSI", .canonical = "MOSI" },
        .{ .token = "SDI", .canonical = "MOSI" },
        .{ .token = "SI", .canonical = "MOSI" },
        .{ .token = "MISO", .canonical = "MISO" },
        .{ .token = "SDO", .canonical = "MISO" },
        .{ .token = "SO", .canonical = "MISO" },
        .{ .token = "CS", .canonical = "CS" },
        .{ .token = "CSN", .canonical = "CS" },
        .{ .token = "NCS", .canonical = "CS" },
        .{ .token = "CSB", .canonical = "CS" },
        .{ .token = "SS", .canonical = "CS" },
        .{ .token = "NSS", .canonical = "CS" },
        .{ .token = "SCSN", .canonical = "CS" },
    } },
    .{ .interface = "i2c", .variants = &.{
        .{ .token = "SDA", .canonical = "SDA" },
        .{ .token = "SCL", .canonical = "SCL" },
    } },
    .{ .interface = "uart", .variants = &.{
        .{ .token = "RX", .canonical = "RX" },
        .{ .token = "RXD", .canonical = "RX" },
        .{ .token = "TX", .canonical = "TX" },
        .{ .token = "TXD", .canonical = "TX" },
        .{ .token = "CTS", .canonical = "CTS" },
        .{ .token = "RTS", .canonical = "RTS" },
    } },
    .{ .interface = "swd", .variants = &.{
        .{ .token = "SWCLK", .canonical = "SWCLK" },
        .{ .token = "SWDCLK", .canonical = "SWCLK" },
        .{ .token = "SWDIO", .canonical = "SWDIO" },
        .{ .token = "SWO", .canonical = "SWO" },
        .{ .token = "NRST", .canonical = "NRST" },
    } },
    .{ .interface = "jtag", .variants = &.{
        .{ .token = "TCK", .canonical = "TCK" },
        .{ .token = "TMS", .canonical = "TMS" },
        .{ .token = "TDI", .canonical = "TDI" },
        .{ .token = "TDO", .canonical = "TDO" },
        .{ .token = "TRST", .canonical = "TRST" },
    } },
};

/// The signal `port_name` ends with under `vocab`, plus the prefix in front of
/// it — `("SPI_DSA_SDI")` under the SPI vocabulary is `MOSI` with prefix
/// `SPI_DSA`. Null when the name ends in no recognised token. The token must
/// start the final underscore-separated segment or be the whole name, so
/// `LNA_BYPASS` never reads as an `SS` chip select.
pub fn matchSignal(vocab: Vocabulary, port_name: []const u8) ?struct { canonical: []const u8, prefix: []const u8 } {
    var best: ?Variant = null;
    for (vocab.variants) |v| {
        if (!std.mem.eql(u8, tailSegment(port_name), v.token)) continue;
        if (best == null or v.token.len > best.?.token.len) best = v;
    }
    const hit = best orelse return null;
    const cut = port_name.len - hit.token.len;
    const prefix = if (cut == 0) "" else port_name[0 .. cut - 1];
    return .{ .canonical = hit.canonical, .prefix = prefix };
}

/// The final `_`-separated segment of a port name.
fn tailSegment(name: []const u8) []const u8 {
    const at = std.mem.lastIndexOfScalar(u8, name, '_') orelse return name;
    return name[at + 1 ..];
}

// ── Tests ─────────────────────────────────────────────────────────────

const testing = std.testing;

/// One fixture evaluator plus its env, on the page allocator the rest of the
/// evaluator tests use (AST nodes and expanded names outlive any one call).
const Fixture = struct {
    alloc: std.mem.Allocator,
    eval: Evaluator,
    env: Env,

    fn init(alloc: std.mem.Allocator, project_dir: []const u8) Fixture {
        return .{ .alloc = alloc, .eval = Evaluator.init(alloc, project_dir), .env = Env.init(alloc, null) };
    }

    fn deinit(self: *Fixture) void {
        self.env.deinit();
        self.eval.deinit();
    }

    /// Expand one `(port-group …)` written as source.
    fn group(self: *Fixture, source: []const u8) !struct { ports: []const Port, groups: []const PortGroup } {
        const nodes = try parser_mod.parse(self.alloc, source);
        var ports: std.ArrayList(Port) = .empty;
        var groups: std.ArrayList(PortGroup) = .empty;
        try expandPortGroup(&self.eval, nodes[0].asList().?, &self.env, &ports, &groups);
        return .{ .ports = ports.items, .groups = groups.items };
    }

    /// Build the ports a hand-written `(port …)` list declares.
    fn handPorts(self: *Fixture, source: []const u8) ![]const Port {
        const nodes = try parser_mod.parse(self.alloc, source);
        var ports: std.ArrayList(Port) = .empty;
        for (nodes) |node| {
            try ports.append(self.alloc, try builders.buildPort(&self.eval, node.asList().?[1..], &self.env));
        }
        return ports.items;
    }
};

fn expectSamePorts(want: []const Port, got: []const Port) !void {
    try testing.expectEqual(want.len, got.len);
    for (want, got) |a, b| {
        try testing.expectEqualStrings(a.name, b.name);
        try testing.expectEqualStrings(a.net, b.net);
        try testing.expectEqualStrings(a.direction, b.direction);
        try testing.expectEqualStrings(a.kind, b.kind);
        try testing.expectEqual(a.optional, b.optional);
        try testing.expectEqual(a.rated_min, b.rated_min);
        try testing.expectEqual(a.rated_max, b.rated_max);
        try testing.expectEqualStrings(a.side, b.side);
    }
}

// spec: eval/interfaces - A port-group expansion is indistinguishable from the hand-written ports it replaces
test "a port group expands to exactly the ports it replaces" {
    var fx = Fixture.init(std.heap.page_allocator, ".");
    defer fx.deinit();

    // The bundled `spi` definition, resolved out of the embedded table because
    // this project carries no lib/interfaces of its own.
    const expanded = try fx.group("(port-group \"IMU\" spi)");
    const hand = try fx.handPorts(
        \\(port "IMU_SCK"  in  clock)
        \\(port "IMU_MOSI" in  data)
        \\(port "IMU_MISO" out data)
        \\(port "IMU_CS"   in)
    );
    try expectSamePorts(hand, expanded.ports);

    // …and, unlike four hand-written lines, it records the bundle.
    try testing.expectEqual(@as(usize, 1), expanded.groups.len);
    try testing.expectEqualStrings("IMU", expanded.groups[0].name);
    try testing.expectEqualStrings("spi", expanded.groups[0].interface);
    try testing.expectEqualStrings("peripheral", expanded.groups[0].role);
    try testing.expectEqual(@as(usize, 4), expanded.groups[0].members.len);
    try testing.expectEqualStrings("MOSI", expanded.groups[0].members[1].signal);
    try testing.expectEqualStrings("IMU_MOSI", expanded.groups[0].members[1].port);
}

// spec: eval/interfaces - A controller port-group flips its lanes and honours rename, omit and replayed port modifiers
test "role, rename, omit and trailing modifiers all reach the expansion" {
    var fx = Fixture.init(std.heap.page_allocator, ".");
    defer fx.deinit();

    const expanded = try fx.group(
        "(port-group \"SPI_DSA\" spi (role controller) (rename MOSI \"SPI_DSA_SDI\") " ++
            "(rename CS \"SPI_DSA_CSN\") (omit MISO) (rated 0.0 3.6) (side left))",
    );
    const hand = try fx.handPorts(
        \\(port "SPI_DSA_SCK" out clock (rated 0.0 3.6) (side left))
        \\(port "SPI_DSA_SDI" out data  (rated 0.0 3.6) (side left))
        \\(port "SPI_DSA_CSN" out       (rated 0.0 3.6) (side left))
    );
    try expectSamePorts(hand, expanded.ports);
    try testing.expectEqualStrings("controller", expanded.groups[0].role);

    // An empty prefix gives bare signal names and names the group after the
    // interface, so a board can still address it.
    const bare = try fx.group("(port-group \"\" i2c)");
    try testing.expectEqualStrings("SDA", bare.ports[0].name);
    try testing.expectEqualStrings("i2c", bare.groups[0].name);
    // I\u{b2}C is open-drain at both ends: the controller role changes nothing.
    try testing.expectEqualStrings("bidi", bare.ports[0].direction);
}

// spec: eval/interfaces - A project lib/interfaces file shadows the bundled interface of the same name
test "a project definition shadows the bundled one" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(testing.io, "lib/interfaces");
    try tmp.dir.writeFile(testing.io, .{
        .sub_path = "lib/interfaces/spi.sexp",
        .data = "(interface spi \"three-wire\" (signal SCLK in clock) (signal SDIO bidi data) (signal CSN in))",
    });
    const root = try tmp.dir.realPathFileAlloc(testing.io, ".", std.heap.page_allocator);

    var fx = Fixture.init(std.heap.page_allocator, root);
    defer fx.deinit();
    const expanded = try fx.group("(port-group \"IMU\" spi)");
    try testing.expectEqual(@as(usize, 3), expanded.ports.len);
    try testing.expectEqualStrings("IMU_SCLK", expanded.ports[0].name);
    try testing.expectEqualStrings("IMU_SDIO", expanded.ports[1].name);
    try testing.expectEqualStrings("IMU_CSN", expanded.ports[2].name);

    // An interface the project does NOT carry still resolves, out of the
    // bundle: pointing a project at its own definitions is an addition.
    var other = Fixture.init(std.heap.page_allocator, root);
    defer other.deinit();
    const jtag = try other.group("(port-group \"DBG\" jtag)");
    try testing.expectEqualStrings("DBG_TCK", jtag.ports[0].name);

    // A name nothing carries is an error naming the form that asked, not a
    // silently empty boundary.
    var missing = Fixture.init(std.heap.page_allocator, root);
    defer missing.deinit();
    try testing.expectError(EvalError.ImportError, missing.group("(port-group \"X\" nosuchbus)"));
    try testing.expect(std.mem.indexOf(u8, missing.eval.last_error.?.message, "nosuchbus") != null);
}

// spec: eval/interfaces - A bridge-interface emits exactly the net ties the bridge lines it replace would
test "bridge-interface emits the ties its bridge lines would" {
    var fx = Fixture.init(std.heap.page_allocator, ".");
    defer fx.deinit();
    const expanded = try fx.group("(port-group \"SPI_DSA\" spi (rename MOSI \"SPI_DSA_SDI\") (rename CS \"SPI_DSA_CSN\") (omit MISO))");

    var sub_block_body = env_mod.DesignBlock{
        .name = "dsa",
        .instances = &.{},
        .nets = &.{},
        .ports = expanded.ports,
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
        .port_groups = expanded.groups,
    };
    const nodes = try parser_mod.parse(fx.alloc, "(sub-block \"dsa\" (m) (bridge-interface \"SPI_DSA\" (to \"SPI\") (rename CS \"SPI_DSA_CSN\")))");
    var pending: std.ArrayList(PendingBridge) = .empty;
    try collectSubBlockBridges(&fx.eval, nodes[0].asList().?, .{ .name = "dsa", .block = &sub_block_body }, &pending);

    var ties: std.ArrayList(Evaluator.NetTie) = .empty;
    try resolveBridges(&fx.eval, pending.items, &.{}, &ties);

    // The exact three lines `(bridge "" (rename SPI_DSA_SCK SPI_SCK)
    // (rename SPI_DSA_SDI SPI_MOSI) SPI_DSA_CSN)` writes out by hand.
    const want = [_][2][]const u8{
        .{ "SPI_SCK", "dsa/SPI_DSA_SCK" },
        .{ "SPI_MOSI", "dsa/SPI_DSA_SDI" },
        .{ "SPI_DSA_CSN", "dsa/SPI_DSA_CSN" },
    };
    try testing.expectEqual(want.len, ties.items.len);
    for (want, ties.items) |pair, tie| {
        try testing.expectEqualStrings(pair[0], tie.a);
        try testing.expectEqualStrings(pair[1], tie.b);
    }
}

// spec: eval/interfaces - A prefix joins a signal name with exactly one underscore and an empty prefix gives the bare name
test "joinName normalises the separator" {
    const a = try joinName(testing.allocator, "IMU", "SCK");
    defer testing.allocator.free(a);
    try testing.expectEqualStrings("IMU_SCK", a);

    const b = try joinName(testing.allocator, "IMU_", "SCK");
    defer testing.allocator.free(b);
    try testing.expectEqualStrings("IMU_SCK", b);

    const c = try joinName(testing.allocator, "", "SCK");
    defer testing.allocator.free(c);
    try testing.expectEqualStrings("SCK", c);
}

// spec: eval/interfaces - The controller role mirrors in and out while a bidirectional lane stays bidirectional
test "role flipping mirrors only the directed lanes" {
    try testing.expectEqualStrings("out", flip("in"));
    try testing.expectEqualStrings("in", flip("out"));
    try testing.expectEqualStrings("bidi", flip("bidi"));
    try testing.expectEqualStrings("io", flip("io"));
}

// spec: eval/interfaces - The naming lint recognises a signal only as the final segment of a port name
test "the lint vocabulary matches whole trailing segments" {
    const spi = vocabularies[0];
    const hit = matchSignal(spi, "SPI_DSA_SDI").?;
    try testing.expectEqualStrings("MOSI", hit.canonical);
    try testing.expectEqualStrings("SPI_DSA", hit.prefix);

    const bare = matchSignal(spi, "SCLK").?;
    try testing.expectEqualStrings("SCK", bare.canonical);
    try testing.expectEqualStrings("", bare.prefix);

    // A word that merely ENDS in a token's letters is not a match: the token
    // has to be the whole final segment.
    try testing.expect(matchSignal(spi, "LNA_BYPASS") == null);
    try testing.expect(matchSignal(spi, "VBUSS") == null);
}

// spec: eval/interfaces - Every signal of a bundled interface definition is a canonical row of the naming vocabulary
test "the bundled definitions and the lint vocabulary agree" {
    for (vocabularies) |vocab| {
        var buf: [96]u8 = undefined;
        const sub = try std.fmt.bufPrint(&buf, "{s}{s}.sexp", .{ lib_sub_dir, vocab.interface });
        const bytes = stdlib_mod.bundled(sub) orelse return error.InterfaceNotBundled;
        const nodes = try parser_mod.parse(std.heap.page_allocator, bytes);
        var seen = false;
        for (nodes) |node| {
            if (!node.isForm("interface")) continue;
            seen = true;
            for (node.asList().?[2..]) |child| {
                if (!child.isForm("signal")) continue;
                const name = child.asList().?[1].asText().?;
                try testing.expect(hasCanonical(vocab, name));
            }
        }
        try testing.expect(seen);
    }
}

fn hasCanonical(vocab: Vocabulary, name: []const u8) bool {
    for (vocab.variants) |v| {
        if (std.mem.eql(u8, v.canonical, name) and std.mem.eql(u8, v.token, name)) return true;
    }
    return false;
}
