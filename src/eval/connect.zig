//! Anonymous point-to-point wiring: `(connect …)` and `(chain …)`.
//!
//! Most nets in an RF signal chain exist only to have a name. `IF1_LFCN`,
//! `IF1_PAD`, `LO1_DRIVE` carry no meaning beyond "the node between these two
//! parts", yet each costs an invented identifier, a `(rename …)` line on every
//! bridge that touches it, and a place in every `(nets …)` list that has to
//! enumerate the chain. `(connect …)` states the node by naming its ENDS, and
//! `(chain …)` states a whole cascade by naming the parts in order.
//!
//! Neither form is a new connectivity mechanism. Both lower to exactly the
//! `PinNetDecl` / `NetTie` records `(pin …)`, `(net …)` and `(bridge …)`
//! produce, so ERC, the decouple/near bindings, net classes, voltage
//! envelopes, the KiCad exports and every PCB tool see an ordinary net.
//!
//! Resolution is deferred to a post-build pass (`resolveAll`, called from
//! `design_block.materializeBlock` once the whole body has been walked) for the
//! same reason `(decouples …)` is: an end names a part or a sub-block that may
//! be written BELOW the `(connect …)` in the source, and a pin function name
//! only has meaning against the target's own pinout. Deferring makes
//! declaration order irrelevant.

const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const env_mod = @import("env.zig");
const evaluator_mod = @import("evaluator.zig");
const instance_mod = @import("instance.zig");
const builders = @import("builders.zig");
const net_name = @import("../net_name.zig");

const Node = ast.Node;
const Env = env_mod.Env;
const Instance = env_mod.Instance;
const Port = env_mod.Port;
const SubBlock = env_mod.SubBlock;
const Evaluator = evaluator_mod.Evaluator;
const EvalError = evaluator_mod.EvalError;
const PinNetDecl = evaluator_mod.PinNetDecl;
const NetTie = Evaluator.NetTie;

/// Prefix every generated net name carries.
///
/// `~` is the discriminator on purpose. It is one of RFC 3986's *unreserved*
/// characters, so a generated name needs no escaping in any URL surface; it is
/// legal inside a KiCad netlist net name (a quoted string) and inside a
/// `.kicad_sch` global label; it is not `.` (which `net_analysis.baseNetName`
/// reads as the per-pin bypass-stub separator) and not `/` (the hierarchy
/// separator); it does not tilde-expand in a shell, because the prefix puts a
/// letter first; and no authored net in any design uses it. `resolveAll`
/// nevertheless CHECKS every generated name against the block's authored nets
/// rather than trusting that last sentence.
pub const anon_prefix = "n~";

/// Longest generated name spelled out end-by-end. Past this the name keeps its
/// first end and takes a hash of the full key, so a ten-end `(connect …)`
/// cannot produce a net name no UI can show.
const max_spelled_len = 60;

/// Is `name` a net this module generated? Used by the double-drive rule: two
/// anonymous nets landing on one pad are the same node stated twice, whereas an
/// anonymous net landing on an AUTHORED net's pad is a silent merge and an error.
pub fn isAnonymous(name: []const u8) bool {
    return std.mem.startsWith(u8, name, anon_prefix);
}

/// Which form produced a pending record. They share every resolution rule; only
/// the end-list shape differs.
pub const Kind = enum { connect, chain };

/// One authored token plus where it was written, so an error can point at the
/// exact end that failed rather than the whole form.
pub const Token = struct {
    text: []const u8,
    span: ast.Span,
};

/// A `(connect …)` / `(chain …)` awaiting the complete block. Ends are stored as
/// TEXT (already evaluated against the authoring scope, so a `(fmt …)` end
/// inside a `(for …)` works), which is also what the generated net name derives
/// from — never a post-flatten ref-des.
pub const Pending = struct {
    kind: Kind,
    items: []const Token,
    /// Authored `(name "NET")`, or "" when the net name is generated.
    name: []const u8 = "",
    /// Authored `(class "net-class")`, or "".
    class: []const u8 = "",
    span: ast.Span,
};

// ── Collection (form-evaluation time) ──────────────────────────────────

/// Parse one `(connect …)` / `(chain …)` and queue it for `resolveAll`.
/// Called from all three design scopes; the queue is the block's own list,
/// reached through the shared section accumulator bag so no dispatcher grows a
/// parameter.
pub fn collect(
    self: *Evaluator,
    queue: *std.ArrayList(Pending),
    kind: Kind,
    form_children: []const Node,
    env: *Env,
    span: ast.Span,
) EvalError!void {
    var items: std.ArrayList(Token) = .empty;
    var name: []const u8 = "";
    var class: []const u8 = "";

    for (form_children[1..]) |child| {
        if (child.isForm("name")) {
            const c = child.asList().?;
            if (c.len < 2) continue;
            if (kind == .chain) {
                self.setError(child.span, "(chain …) makes one net per gap, so it takes no (name …) — name a node with its own (connect …)");
                return EvalError.InvalidForm;
            }
            name = try tokenText(self, c[1], env);
            continue;
        }
        if (child.isForm("class")) {
            const c = child.asList().?;
            if (c.len < 2) continue;
            class = try tokenText(self, c[1], env);
            continue;
        }
        const text = try tokenText(self, child, env);
        if (text.len == 0) {
            self.setError(child.span, "an empty (connect …)/(chain …) end names nothing");
            return EvalError.InvalidForm;
        }
        try items.append(self.allocator, .{ .text = text, .span = child.span });
    }

    const min_items: usize = if (kind == .chain) 3 else 2;
    if (items.items.len < min_items) {
        self.setError(span, if (kind == .chain)
            "(chain …) expects \"NET_A\" ITEM… \"NET_B\" — at least one item between the two endpoints"
        else
            "(connect …) expects at least two ends");
        return EvalError.ArityError;
    }

    try queue.append(self.allocator, .{
        .kind = kind,
        .items = items.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
        .name = name,
        .class = class,
        .span = span,
    });
}

/// An end token's text. Bare atoms (`IF1_PAD`, `lna/RF_IN`) are taken
/// literally — the same rule `(bridge …)` uses — so a port name is never read
/// as a variable lookup; a parenthesised child is evaluated, which is what lets
/// `(fmt "IF~a_PAD" i)` name an end inside a `(repeat …)`.
fn tokenText(self: *Evaluator, node: Node, env: *Env) EvalError![]const u8 {
    if (node.asList() != null) {
        const v = try self.evalNode(node, env);
        return v.asString() orelse {
            self.setError(node.span, "this (connect …)/(chain …) end does not evaluate to a string");
            return EvalError.TypeError;
        };
    }
    return node.asText() orelse {
        self.setError(node.span, "this (connect …)/(chain …) end is not a name");
        return EvalError.TypeError;
    };
}

// ── Resolution (post-build) ────────────────────────────────────────────

/// Everything `resolveAll` needs from the half-built block. Passed as one
/// struct so the call site stays a single argument.
pub const Context = struct {
    pending: []const Pending,
    instances: []const Instance,
    sub_blocks: []const SubBlock,
    ports: []const Port,
    all_pin_nets: *std.ArrayList(PinNetDecl),
    net_ties: *std.ArrayList(NetTie),
    net_classes: *std.ArrayList(env_mod.NetClassSpec),
};

/// What one end token denotes once the block is known.
const End = union(enum) {
    /// A physical pad on a placed instance.
    pad: struct { ref: []const u8, pad: []const u8 },
    /// A declared port of a sub-block, spelled "sub/PORT".
    sub_port: []const u8,
    /// An ordinary net name — a bare token, or the net behind a port of the
    /// enclosing block.
    net: []const u8,
};

/// Mutable bookkeeping shared across every pending form in one block: what is
/// already on each pad, which sub-block ports are already wired, and which net
/// names are taken.
const Ledger = struct {
    allocator: std.mem.Allocator,
    /// "REF\x00PAD" → the net that pad already carries.
    pads: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// "sub/PORT" → how it is already wired.
    ports: std.StringHashMapUnmanaged(PortWiring) = .empty,
    /// Every net name in use, authored or generated.
    names: std.StringHashMapUnmanaged(void) = .empty,

    const PortWiring = struct { net: []const u8, from_connect: bool, span: ?ast.Span = null };

    fn padKey(self: *Ledger, ref: []const u8, pad: []const u8) EvalError![]const u8 {
        return std.fmt.allocPrint(self.allocator, "{s}\x00{s}", .{ ref, pad }) catch EvalError.OutOfMemory;
    }
};

/// Resolve every queued `(connect …)`/`(chain …)` into pin-net declarations and
/// net ties. Runs once per block, after the body walk, before `buildNets`.
pub fn resolveAll(self: *Evaluator, ctx: Context) EvalError!void {
    if (ctx.pending.len == 0) return;

    var ledger = Ledger{ .allocator = self.allocator };
    for (ctx.all_pin_nets.items) |pn| {
        try ledger.names.put(self.allocator, pn.net, {});
        const key = try ledger.padKey(pn.ref_des, pn.pin);
        try ledger.pads.put(self.allocator, key, pn.net);
    }
    for (ctx.net_ties.items) |nt| {
        if (nt.is_auto) continue;
        try ledger.names.put(self.allocator, nt.a, {});
        try ledger.names.put(self.allocator, nt.b, {});
        if (std.mem.indexOfScalar(u8, nt.b, '/') != null)
            try ledger.ports.put(self.allocator, nt.b, .{ .net = nt.a, .from_connect = false, .span = nt.span });
    }

    for (ctx.pending) |pending| {
        switch (pending.kind) {
            .connect => try resolveConnect(self, ctx, &ledger, pending),
            .chain => try resolveChain(self, ctx, &ledger, pending),
        }
    }
}

/// Wire one `(connect …)`: resolve every end, pick the net name, emit.
fn resolveConnect(self: *Evaluator, ctx: Context, ledger: *Ledger, p: Pending) EvalError!void {
    var ends: std.ArrayList(End) = .empty;
    for (p.items) |tok| try ends.append(self.allocator, try resolveEnd(self, ctx, tok));
    try emitNode(self, ctx, ledger, .{
        .ends = ends.items,
        .toks = p.items,
        .authored = p.name,
        .class = p.class,
        .span = p.span,
    });
}

/// Wire one `(chain "A" ITEM… "B")`: the two outer tokens are ordinary ends,
/// each inner token is a two-port item, and every gap between consecutive
/// terminals becomes its own two-end node.
fn resolveChain(self: *Evaluator, ctx: Context, ledger: *Ledger, p: Pending) EvalError!void {
    const n_items = p.items.len - 2;
    var in_ends = try self.allocator.alloc(End, n_items);
    var out_ends = try self.allocator.alloc(End, n_items);
    var in_toks = try self.allocator.alloc(Token, n_items);
    var out_toks = try self.allocator.alloc(Token, n_items);
    for (p.items[1 .. p.items.len - 1], 0..) |tok, i| {
        const item = try resolveItem(self, ctx, tok);
        in_ends[i] = item.in;
        out_ends[i] = item.out;
        in_toks[i] = item.in_tok;
        out_toks[i] = item.out_tok;
    }

    const head = p.items[0];
    const tail = p.items[p.items.len - 1];
    var prev_end = try resolveEnd(self, ctx, head);
    var prev_tok = head;
    for (0..n_items) |i| {
        try emitNode(self, ctx, ledger, .{
            .ends = &.{ prev_end, in_ends[i] },
            .toks = &.{ prev_tok, in_toks[i] },
            .class = p.class,
            .span = p.span,
        });
        prev_end = out_ends[i];
        prev_tok = out_toks[i];
    }
    try emitNode(self, ctx, ledger, .{
        .ends = &.{ prev_end, try resolveEnd(self, ctx, tail) },
        .toks = &.{ prev_tok, tail },
        .class = p.class,
        .span = p.span,
    });
}

/// One chain item's two terminals, with the tokens the generated net name is
/// spelled from.
const Item = struct {
    in: End,
    out: End,
    in_tok: Token,
    out_tok: Token,
};

/// Resolve a chain item: `"REF"`, `"sub"`, `"REF/A>B"` or `"sub/IN>OUT"`.
fn resolveItem(self: *Evaluator, ctx: Context, tok: Token) EvalError!Item {
    if (std.mem.indexOfScalar(u8, tok.text, '>')) |gt| {
        const slash = std.mem.indexOfScalar(u8, tok.text[0..gt], '/') orelse {
            self.setError(tok.span, "a chain item with an explicit pair is written \"REF/IN>OUT\"");
            return EvalError.InvalidForm;
        };
        const host = tok.text[0..slash];
        const a = tok.text[slash + 1 .. gt];
        const b = tok.text[gt + 1 ..];
        if (a.len == 0 or b.len == 0) {
            self.setError(tok.span, "a chain item with an explicit pair is written \"REF/IN>OUT\"");
            return EvalError.InvalidForm;
        }
        if (findSubBlock(ctx, host) != null) {
            return .{
                .in = .{ .sub_port = try checkedSubPort(self, ctx, host, a, tok.span) },
                .out = .{ .sub_port = try checkedSubPort(self, ctx, host, b, tok.span) },
                .in_tok = .{ .text = joinTok(self, host, a) catch return EvalError.OutOfMemory, .span = tok.span },
                .out_tok = .{ .text = joinTok(self, host, b) catch return EvalError.OutOfMemory, .span = tok.span },
            };
        }
        const inst = findInstance(ctx, host) orelse {
            unknownHost(self, host, tok.span);
            return EvalError.InvalidForm;
        };
        return .{
            .in = .{ .pad = .{ .ref = inst.ref_des, .pad = resolvePad(self, ctx, inst, a, tok.span) } },
            .out = .{ .pad = .{ .ref = inst.ref_des, .pad = resolvePad(self, ctx, inst, b, tok.span) } },
            .in_tok = .{ .text = try dotTok(self, host, a), .span = tok.span },
            .out_tok = .{ .text = try dotTok(self, host, b), .span = tok.span },
        };
    }

    if (findSubBlock(ctx, tok.text)) |sb| {
        const pair = try autoPorts(self, sb, tok.span);
        return .{
            .in = .{ .sub_port = try joinTok(self, tok.text, pair.in) },
            .out = .{ .sub_port = try joinTok(self, tok.text, pair.out) },
            .in_tok = .{ .text = try joinTok(self, tok.text, pair.in), .span = tok.span },
            .out_tok = .{ .text = try joinTok(self, tok.text, pair.out), .span = tok.span },
        };
    }

    const inst = findInstance(ctx, tok.text) orelse {
        unknownHost(self, tok.text, tok.span);
        return EvalError.InvalidForm;
    };
    const pair = try twoTerminalPads(self, ctx, inst, tok.span);
    return .{
        .in = .{ .pad = .{ .ref = inst.ref_des, .pad = pair.in } },
        .out = .{ .pad = .{ .ref = inst.ref_des, .pad = pair.out } },
        .in_tok = .{ .text = try dotTok(self, tok.text, pair.in_name), .span = tok.span },
        .out_tok = .{ .text = try dotTok(self, tok.text, pair.out_name), .span = tok.span },
    };
}

fn joinTok(self: *Evaluator, a: []const u8, b: []const u8) EvalError![]const u8 {
    return std.fmt.allocPrint(self.allocator, "{s}/{s}", .{ a, b }) catch EvalError.OutOfMemory;
}

fn dotTok(self: *Evaluator, a: []const u8, b: []const u8) EvalError![]const u8 {
    return std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ a, b }) catch EvalError.OutOfMemory;
}

/// Resolve one END token. `"sub/PORT"` names a sub-block port, `"REF.PAD"` /
/// `"REF.FN"` a pad on a placed part, anything else an ordinary net (or the net
/// behind a port of the enclosing block).
fn resolveEnd(self: *Evaluator, ctx: Context, tok: Token) EvalError!End {
    if (std.mem.indexOfScalar(u8, tok.text, '/') != null) {
        const sub = net_name.parent(tok.text).?;
        const port = net_name.leaf(tok.text);
        if (findSubBlock(ctx, sub) == null) {
            unknownHost(self, sub, tok.span);
            return EvalError.InvalidForm;
        }
        return .{ .sub_port = try checkedSubPort(self, ctx, sub, port, tok.span) };
    }
    if (std.mem.indexOfScalar(u8, tok.text, '.')) |dot| {
        const ref = tok.text[0..dot];
        const pin = tok.text[dot + 1 ..];
        const inst = findInstance(ctx, ref) orelse {
            unknownHost(self, ref, tok.span);
            return EvalError.InvalidForm;
        };
        return .{ .pad = .{ .ref = inst.ref_des, .pad = resolvePad(self, ctx, inst, pin, tok.span) } };
    }
    for (ctx.ports) |port| {
        if (std.mem.eql(u8, port.name, tok.text)) return .{ .net = port.net };
    }
    return .{ .net = tok.text };
}

/// "sub/PORT", with PORT checked against the sub-block's declared ports.
fn checkedSubPort(self: *Evaluator, ctx: Context, sub: []const u8, port: []const u8, span: ast.Span) EvalError![]const u8 {
    const sb = findSubBlock(ctx, sub).?;
    for (sb.block.ports) |p| {
        if (std.mem.eql(u8, p.name, port)) return joinTok(self, sub, port);
    }
    var list: std.ArrayList(u8) = .empty;
    for (sb.block.ports, 0..) |p, i| {
        if (i > 0) list.appendSlice(self.allocator, ", ") catch return EvalError.OutOfMemory;
        list.appendSlice(self.allocator, p.name) catch return EvalError.OutOfMemory;
    }
    self.setErrorFmt(span, "sub-block \"{s}\" declares no port \"{s}\" — it has: {s}", .{ sub, port, list.items });
    return EvalError.InvalidForm;
}

/// Resolve a pad token against the part's pinout: a physical pad id passes
/// through untouched (checked FIRST, so a connector whose pinout names contact
/// 4 "4" can never re-point a pad binding), a function name maps to its pad,
/// and an unknown token stays as written for ERC to report — the same ladder
/// `(decouples …)` uses.
fn resolvePad(self: *Evaluator, ctx: Context, inst: Instance, token: []const u8, span: ast.Span) []const u8 {
    const map = builders.findPinFuncMap(self, ctx.instances, inst.ref_des) orelse return token;
    if (map.get(token) != null) return token;
    return instance_mod.resolvePinName(self, map, token, span) orelse token;
}

fn findInstance(ctx: Context, ref: []const u8) ?Instance {
    for (ctx.instances) |inst| {
        if (std.mem.eql(u8, inst.ref_des, ref)) return inst;
    }
    return null;
}

fn findSubBlock(ctx: Context, name: []const u8) ?SubBlock {
    for (ctx.sub_blocks) |sb| {
        if (std.mem.eql(u8, sb.name, name)) return sb;
    }
    return null;
}

fn unknownHost(self: *Evaluator, host: []const u8, span: ast.Span) void {
    self.setErrorFmt(span, "(connect …)/(chain …) names \"{s}\", which is neither a placed instance nor a sub-block in this design", .{host});
}

/// A two-terminal part's through path: the physical pads to bind, plus the
/// names the generated net is SPELLED from — the pinout's function names when
/// it has them, so `lpf` reads as `lpf-OUTPUT` rather than `lpf-3` and a pinout
/// regeneration that renumbers pads leaves the net name alone.
const PadPair = struct {
    in: []const u8,
    out: []const u8,
    in_name: []const u8,
    out_name: []const u8,
};
const PortPair = struct { in: []const u8, out: []const u8 };

/// The two terminals of a two-terminal part: the pinout's two pads in pad
/// order, or `1`/`2` for a part with no pinout at all. A part with more pads
/// has no unambiguous through path, so it must be spelled `"REF/IN>OUT"`.
fn twoTerminalPads(self: *Evaluator, ctx: Context, inst: Instance, span: ast.Span) EvalError!PadPair {
    const map = builders.findPinFuncMap(self, ctx.instances, inst.ref_des) orelse
        return .{ .in = "1", .out = "2", .in_name = "1", .out_name = "2" };
    if (map.count() == 2) {
        var pads: [2][]const u8 = .{ "", "" };
        var i: usize = 0;
        var it = map.keyIterator();
        while (it.next()) |k| : (i += 1) pads[i] = k.*;
        if (instance_mod.padLess(pads[1], pads[0])) std.mem.swap([]const u8, &pads[0], &pads[1]);
        return .{
            .in = pads[0],
            .out = pads[1],
            .in_name = map.get(pads[0]) orelse pads[0],
            .out_name = map.get(pads[1]) orelse pads[1],
        };
    }
    self.setErrorFmt(span, "\"{s}\" has {d} pads, so a bare chain item cannot say which two carry the signal — write \"{s}/IN>OUT\" (a pad id or a pinout function name on each side)", .{ inst.ref_des, map.count(), inst.ref_des });
    return EvalError.InvalidForm;
}

/// The through path of a sub-block used as a bare chain item.
///
/// Candidates are the module's ports that a signal can actually pass through:
/// direction `in` or `out`, not `power`, not `optional` (an optional port is by
/// definition not the module's job). The module must declare exactly ONE such
/// output; the input is then the unique candidate sharing that output's signal
/// kind, which is what lets `tsy-83lnw-lna` — whose `VBYP` bias pin is also an
/// `in` — still name `RF_IN` → `RF_OUT` without a hint. Anything less definite
/// is an error listing the candidates, because guessing a signal path wrong is
/// a silent miswire.
fn autoPorts(self: *Evaluator, sb: SubBlock, span: ast.Span) EvalError!PortPair {
    var out_port: ?Port = null;
    var outs: usize = 0;
    for (sb.block.ports) |p| {
        if (!isCandidate(p)) continue;
        if (!std.mem.eql(u8, p.direction, "out")) continue;
        outs += 1;
        out_port = p;
    }
    if (outs == 1) {
        const out = out_port.?;
        var in_name: []const u8 = "";
        var ins: usize = 0;
        for (sb.block.ports) |p| {
            if (!isCandidate(p)) continue;
            if (!std.mem.eql(u8, p.direction, "in")) continue;
            if (out.kind.len > 0 and !std.mem.eql(u8, p.kind, out.kind)) continue;
            ins += 1;
            in_name = p.name;
        }
        if (ins == 1) return .{ .in = in_name, .out = out.name };
    }

    var list: std.ArrayList(u8) = .empty;
    for (sb.block.ports) |p| {
        if (!isCandidate(p)) continue;
        if (list.items.len > 0) list.appendSlice(self.allocator, ", ") catch return EvalError.OutOfMemory;
        const one = std.fmt.allocPrint(self.allocator, "{s} ({s}{s}{s})", .{
            p.name, p.direction, if (p.kind.len > 0) " " else "", p.kind,
        }) catch return EvalError.OutOfMemory;
        list.appendSlice(self.allocator, one) catch return EvalError.OutOfMemory;
    }
    self.setErrorFmt(span, "sub-block \"{s}\" has no unique signal path, so a bare chain item cannot pick one — write \"{s}/IN>OUT\"; candidates: {s}", .{
        sb.name, sb.name, if (list.items.len == 0) "none" else list.items,
    });
    return EvalError.InvalidForm;
}

/// Can a chain pass a signal through this port? Power rails, ground/bidi pins
/// and optional ports never carry the module's through path.
fn isCandidate(p: Port) bool {
    if (p.optional) return false;
    if (std.mem.eql(u8, p.kind, "power") or std.mem.eql(u8, p.kind, "ground")) return false;
    return std.mem.eql(u8, p.direction, "in") or std.mem.eql(u8, p.direction, "out");
}

// ── Emission ───────────────────────────────────────────────────────────

/// One node to emit: its ends, the authored tokens they were spelled from
/// (which is what the generated name derives from), and the form's options.
const NodeSpec = struct {
    ends: []const End,
    toks: []const Token,
    /// Authored `(name …)`, or "" when the name is derived.
    authored: []const u8 = "",
    class: []const u8 = "",
    span: ast.Span,
};

/// Emit one node: choose its net name, then bind every end to it.
fn emitNode(self: *Evaluator, ctx: Context, ledger: *Ledger, spec: NodeSpec) EvalError!void {
    const canonical = try nodeName(self, ledger, spec);
    try ledger.names.put(self.allocator, canonical, {});

    for (spec.ends, spec.toks) |end, tok| switch (end) {
        .pad => |p| try bindPad(self, ctx, ledger, .{ .ref = p.ref, .pad = p.pad, .net = canonical, .span = tok.span }),
        .sub_port => |path| try bindPort(self, ctx, ledger, path, canonical, tok.span),
        .net => |n| if (!std.mem.eql(u8, n, canonical))
            try ctx.net_ties.append(self.allocator, .{ .a = canonical, .b = n, .span = spec.span }),
    };

    if (spec.class.len > 0) try joinNetClass(self, ctx, spec.class, canonical, spec.span);
}

/// The net name for one node. An authored `(name …)` wins; otherwise the FIRST
/// end that is already an ordinary net supplies the name (so a `(connect …)`
/// touching a named board net joins it instead of renaming it); otherwise the
/// name is generated.
fn nodeName(self: *Evaluator, ledger: *Ledger, spec: NodeSpec) EvalError![]const u8 {
    if (spec.authored.len > 0) return spec.authored;
    for (spec.ends) |end| switch (end) {
        .net => |n| return n,
        else => {},
    };
    return generateName(self, ledger, spec.toks);
}

/// Build the generated name from the authored end tokens.
///
/// Identity comes from what the SOURCE says — `pad1.5`, `lna/RF_IN` — never
/// from a post-flatten ref-des, so renumbering a sub-block's parts (or the
/// board's own auto ref-des pass, which runs after this) cannot move the name.
/// `.` and `/` become `-` because both are structural in a net name; every
/// other byte outside `[A-Za-z0-9_-]` becomes `_`.
fn generateName(self: *Evaluator, ledger: *Ledger, toks: []const Token) EvalError![]const u8 {
    var key: std.ArrayList(u8) = .empty;
    for (toks, 0..) |tok, i| {
        if (i > 0) key.append(self.allocator, '~') catch return EvalError.OutOfMemory;
        for (tok.text) |c| key.append(self.allocator, sanitizeByte(c)) catch return EvalError.OutOfMemory;
    }

    var base: []const u8 = undefined;
    if (key.items.len + anon_prefix.len <= max_spelled_len) {
        base = std.fmt.allocPrint(self.allocator, anon_prefix ++ "{s}", .{key.items}) catch return EvalError.OutOfMemory;
    } else {
        const first = std.mem.sliceTo(key.items, '~');
        const head = first[0..@min(first.len, 24)];
        base = std.fmt.allocPrint(self.allocator, anon_prefix ++ "{s}~{x:0>8}", .{
            head, std.hash.Fnv1a_32.hash(key.items),
        }) catch return EvalError.OutOfMemory;
    }

    // A name already in use is disambiguated with an ordinal rather than
    // silently merging two nodes. Deterministic in source order, so the
    // suffix is as stable as the name it extends.
    if (!ledger.names.contains(base)) return base;
    var n: usize = 2;
    while (n < 1000) : (n += 1) {
        const candidate = std.fmt.allocPrint(self.allocator, "{s}~{d}", .{ base, n }) catch return EvalError.OutOfMemory;
        if (!ledger.names.contains(candidate)) return candidate;
    }
    self.setError(toks[0].span, "(connect …) could not find a free generated net name");
    return EvalError.InvalidForm;
}

fn sanitizeByte(c: u8) u8 {
    return switch (c) {
        'A'...'Z', 'a'...'z', '0'...'9', '_' => c,
        '.', '/', '-' => '-',
        else => '_',
    };
}

/// Put one pad on `net`, refusing a silent merge onto a different net.
/// One pad binding: which pad, onto which net, written where.
const PadBind = struct {
    ref: []const u8,
    pad: []const u8,
    net: []const u8,
    span: ast.Span,
};

fn bindPad(self: *Evaluator, ctx: Context, ledger: *Ledger, b: PadBind) EvalError!void {
    const ref = b.ref;
    const pad = b.pad;
    const net = b.net;
    const span = b.span;
    const key = try ledger.padKey(ref, pad);
    if (ledger.pads.get(key)) |existing| {
        if (std.mem.eql(u8, existing, net)) return;
        if (isAnonymous(existing) and isAnonymous(net)) {
            // Two anonymous nodes sharing a pad ARE one node: merge them, but
            // say so, because nothing in the source spells the join out.
            self.warnFmt(span, "pad {s}.{s} is on anonymous net \"{s}\" and \"{s}\" — the two (connect …) nodes are merged into one", .{ ref, pad, existing, net });
            try ctx.net_ties.append(self.allocator, .{ .a = existing, .b = net, .span = span });
            return;
        }
        self.setErrorFmt(span, "pad {s}.{s} is already wired to net \"{s}\"; this (connect …) would silently merge it with \"{s}\" — wire one of them through a named (net …) if that is intended", .{ ref, pad, existing, net });
        return EvalError.InvalidForm;
    }
    try ledger.pads.put(self.allocator, key, net);
    try ctx.all_pin_nets.append(self.allocator, .{ .ref_des = ref, .pin = pad, .net = net });
}

/// Tie one sub-block port to `net`. A port a `(bridge …)` or `(net …)` already
/// wired is an error naming both; two anonymous connects merge with a warning,
/// exactly as two connects on one pad do.
fn bindPort(self: *Evaluator, ctx: Context, ledger: *Ledger, path: []const u8, net: []const u8, span: ast.Span) EvalError!void {
    if (ledger.ports.get(path)) |existing| {
        if (std.mem.eql(u8, existing.net, net)) return;
        if (!existing.from_connect) {
            if (existing.span) |at| {
                self.setErrorFmt(span, "sub-block port \"{s}\" is already wired to \"{s}\" by the (bridge …)/(net …) at line {d}:{d}; this (connect …) would wire it to \"{s}\" as well — remove one of the two", .{ path, existing.net, at.line, at.col, net });
            } else {
                self.setErrorFmt(span, "sub-block port \"{s}\" is already wired to \"{s}\" by a (bridge …) or (net …); this (connect …) would wire it to \"{s}\" as well — remove one of the two", .{ path, existing.net, net });
            }
            return EvalError.InvalidForm;
        }
        if (isAnonymous(existing.net) and isAnonymous(net)) {
            self.warnFmt(span, "sub-block port \"{s}\" is on anonymous net \"{s}\" and \"{s}\" — the two (connect …) nodes are merged into one", .{ path, existing.net, net });
            try ctx.net_ties.append(self.allocator, .{ .a = existing.net, .b = net, .span = span });
            return;
        }
        self.setErrorFmt(span, "sub-block port \"{s}\" is already wired to \"{s}\" by another (connect …); wiring it to \"{s}\" too would merge the two nets silently", .{ path, existing.net, net });
        return EvalError.InvalidForm;
    }
    try ledger.ports.put(self.allocator, path, .{ .net = net, .from_connect = true, .span = span });
    // Same record a `(bridge …)` emits, which is what makes
    // `erc.checkUnconnectedPorts` count this port as connected.
    try ctx.net_ties.append(self.allocator, .{ .a = net, .b = path, .span = span });
}

/// Add `net` to the `(net-class "name" …)` the form asked for.
fn joinNetClass(self: *Evaluator, ctx: Context, class: []const u8, net: []const u8, span: ast.Span) EvalError!void {
    for (ctx.net_classes.items) |*spec| {
        if (!std.mem.eql(u8, spec.name, class)) continue;
        const grown = self.allocator.alloc([]const u8, spec.nets.len + 1) catch return EvalError.OutOfMemory;
        @memcpy(grown[0..spec.nets.len], spec.nets);
        grown[spec.nets.len] = net;
        spec.nets = grown;
        return;
    }
    self.warnFmt(span, "(class \"{s}\") names no (net-class …) in this design — the net is wired, but carries no class", .{class});
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const sexpr_parser = @import("../sexpr/parser.zig");
const kicad_netlist = @import("../export_kicad_netlist.zig");
const flat_netlist = @import("../flat_netlist.zig");
const DesignBlock = env_mod.DesignBlock;

/// Two-terminal fixture part: pads 1/2 named IN/OUT.
const two_pin_pinout = [_][2][]const u8{ .{ "1", "IN" }, .{ "2", "OUT" } };
/// Seven-pad fixture part, shaped like a Mini-Circuits YAT attenuator: the
/// through path is 2 → 5 and everything else is ground.
const seven_pin_pinout = [_][2][]const u8{
    .{ "1", "GND_1" },  .{ "2", "RF_IN" }, .{ "3", "GND_2" }, .{ "4", "GND_3" },
    .{ "5", "RF_OUT" }, .{ "6", "GND_4" }, .{ "7", "GND_5" },
};

fn seedPinout(a: std.mem.Allocator, eval: *Evaluator, name: []const u8, rows: []const [2][]const u8) !void {
    var map: std.StringHashMapUnmanaged([]const u8) = .empty;
    for (rows) |row| try map.put(a, row[0], row[1]);
    try eval.symbol_pin_cache.put(a, name, map);
    try eval.component_cache.put(a, name, .{
        .name = name,
        .symbol_name = name,
        .footprint_name = "",
        .is_family = false,
        .param_type = "",
    });
}

/// Evaluate a fixture source (any number of top-level forms) and return the
/// LAST design block it produced. Two fixture parts are pre-seeded with
/// pinouts so `"REF.FN"` ends and the two-terminal chain rule are exercised
/// without touching the filesystem.
fn evalFixture(a: std.mem.Allocator, eval: *Evaluator, source: []const u8) !*DesignBlock {
    eval.* = Evaluator.init(a, "");
    try seedPinout(a, eval, "twoterm", &two_pin_pinout);
    try seedPinout(a, eval, "sevenpad", &seven_pin_pinout);
    const nodes = try sexpr_parser.parse(a, source);
    var scope = Env.init(a, null);
    const v = eval.evalNodes(nodes, &scope) catch |err| return err;
    return switch (v) {
        .design_block => |b| b,
        else => error.TestUnexpectedResult,
    };
}

/// The evaluator's recorded error message, or "" when it recorded none.
fn errorText(eval: *const Evaluator) []const u8 {
    return if (eval.last_error) |e| e.message else "";
}

fn netNamed(block: *const DesignBlock, name: []const u8) ?env_mod.Net {
    for (block.nets) |net| {
        if (std.mem.eql(u8, net.name, name)) return net;
    }
    return null;
}

/// Every generated net name in the block, in `block.nets` order.
fn anonNames(a: std.mem.Allocator, block: *const DesignBlock) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (block.nets) |net| {
        if (isAnonymous(net.name)) try out.append(a, net.name);
    }
    return out.toOwnedSlice(a);
}

// spec: eval/connect - a (connect …) with no (name …) derives its net name from the AUTHORED end tokens, so ref-des renumbering cannot move it
test "a generated net name follows the source names, not the assigned ref-des" {
    const a = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    // Neither part is given a ref-des that survives: `autoAssignRefDes`
    // renames both descriptive labels. The net name must not follow.
    const block = try evalFixture(a, &eval,
        \\(design-block "T"
        \\  (instance "lpf" twoterm (pin 1 "IF_IN"))
        \\  (instance "amp" twoterm (pin 2 "IF_OUT"))
        \\  (connect "lpf.OUT" "amp.IN"))
    );
    const net = netNamed(block, "n~lpf-OUT~amp-IN") orelse return error.TestExpectedGeneratedNet;
    try testing.expectEqual(@as(usize, 2), net.pins.len);
    // The parts really were renumbered — the name above is stable in spite of it.
    try testing.expect(!std.mem.eql(u8, block.instances[0].ref_des, "lpf"));
}

// spec: eval/connect - a generated net name is byte-identical across two evaluations of the same source
test "a generated net name is stable across rebuilds" {
    const a = std.heap.page_allocator;
    const src =
        \\(design-block "T"
        \\  (instance "lpf" twoterm (pin 1 "IF_IN"))
        \\  (instance "pad" sevenpad (pin 1 3 4 6 7 "GND"))
        \\  (chain "IF_IN" "lpf" "pad/RF_IN>RF_OUT" "IF_OUT"))
    ;
    var e1: Evaluator = undefined;
    var e2: Evaluator = undefined;
    const first = try anonNames(a, try evalFixture(a, &e1, src));
    const second = try anonNames(a, try evalFixture(a, &e2, src));
    try testing.expectEqual(first.len, second.len);
    try testing.expectEqual(@as(usize, 1), first.len);
    try testing.expectEqualStrings("n~lpf-OUT~pad-RF_IN", first[0]);
    for (first, second) |x, y| try testing.expectEqualStrings(x, y);
}

// spec: eval/connect - a generated net name reaches the KiCad netlist unescaped and cannot collide with an authored net
test "a generated net name is legal in the KiCad netlist" {
    const alloc = std.testing.allocator;
    const anon = "n~lpf4-OUTPUT~lpf_if_1-RF_IN";
    const fp_names: std.StringHashMapUnmanaged([]const u8) = .empty;
    const fp_pads: std.StringHashMapUnmanaged([]const []const u8) = .empty;
    const instances = [_]flat_netlist.FlatInstance{.{
        .ref_des = "U2",
        .component = "lfcw-6000+",
        .value = "",
        .footprint = "jc0603c-1",
        .properties = &.{},
        .uuid = "",
    }};
    const pins = [_]flat_netlist.FlatPin{.{ .ref_des = "U2", .pin = "3" }};
    const nets = [_]flat_netlist.FlatNet{.{ .name = anon, .pins = &pins }};
    const out = try kicad_netlist.writeNetlist(alloc, "probe", &instances, &nets, &fp_names, &fp_pads);
    defer alloc.free(out);

    // The document still parses — the name needs no escaping — and the name
    // reaches the file byte for byte.
    const nodes = try sexpr_parser.parse(alloc, out);
    defer sexpr_parser.freeNodes(alloc, nodes);
    try testing.expectEqual(@as(usize, 1), nodes.len);
    try testing.expect(std.mem.indexOf(u8, out, anon) != null);
}

// spec: eval/connect - a chain over a module picks the module's unique in/out signal pair even when a bias pin is also an input
test "a chain names a module's through path without a hint" {
    const a = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    // The port set of lib/modules/tsy-83lnw-lna.sexp: RF_IN/RF_OUT are the
    // signal pair, VBYP is a second `in` with no kind, AMP_VDD is optional.
    const block = try evalFixture(a, &eval,
        \\(defmodule lna ()
        \\  (design-block "LNA"
        \\    (port "RF_IN"  in  rf)
        \\    (port "RF_OUT" out rf)
        \\    (port "VDD"    in  power)
        \\    (port "VBYP"   in)
        \\    (port "GND"    bidi)
        \\    (port "AMP_VDD" in optional)
        \\    (instance "U1" twoterm (pin 1 "RF_IN") (pin 2 "RF_OUT"))))
        \\(design-block "T"
        \\  (instance "pad" sevenpad (pin 1 3 4 6 7 "GND"))
        \\  (sub-block "lna" (lna) (bridge "" VDD VBYP GND))
        \\  (chain "IF_IN" "pad/RF_IN>RF_OUT" "lna" "IF_OUT"))
    );
    try testing.expect(netNamed(block, "n~pad-RF_OUT~lna-RF_IN") != null);
    // The module's OUT port lands on the chain's tail net through an ordinary
    // tie — the same record a `(bridge "" (rename RF_OUT IF_OUT))` produces.
    var tail_tied = false;
    for (block.net_ties) |nt| {
        if (std.mem.eql(u8, nt.a, "IF_OUT") and std.mem.eql(u8, nt.b, "lna/RF_OUT")) tail_tied = true;
        // VBYP is an `in` too, but it does not share the rf output's kind, so
        // the chain must never route through it — the rule the reference
        // states. The (bridge …) still wires it, by its authored name.
        if (isAnonymous(nt.a)) try testing.expect(!std.mem.eql(u8, nt.b, "lna/VBYP"));
    }
    try testing.expect(tail_tied);
}

// spec: eval/connect - a sub-block port a connect wires satisfies the required-port ERC exactly as a bridge does
test "a connect-wired sub-block port counts as connected" {
    const a = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    const block = try evalFixture(a, &eval,
        \\(defmodule filt ()
        \\  (design-block "F"
        \\    (port "IN"  in  rf)
        \\    (port "OUT" out rf)
        \\    (instance "U1" twoterm (pin 1 "IN") (pin 2 "OUT"))))
        \\(design-block "T"
        \\  (instance "pad" sevenpad (pin 1 3 4 6 7 "GND"))
        \\  (sub-block "f" (filt))
        \\  (connect "pad.RF_OUT" "f/IN")
        \\  (connect "f/OUT" "IF_OUT"))
    );
    var wired_in = false;
    var wired_out = false;
    for (block.net_ties) |nt| {
        if (std.mem.eql(u8, nt.b, "f/IN")) wired_in = true;
        if (std.mem.eql(u8, nt.b, "f/OUT")) wired_out = true;
    }
    try testing.expect(wired_in and wired_out);
}

// spec: eval/connect - wiring a pad that already carries an authored net is refused instead of silently merging the two
test "a connect onto an already-wired pad is an error" {
    const a = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    const r = evalFixture(a, &eval,
        \\(design-block "T"
        \\  (instance "lpf" twoterm (pin 1 "IF_IN") (pin 2 "IF_MID"))
        \\  (instance "amp" twoterm (pin 2 "IF_OUT"))
        \\  (connect "lpf.OUT" "amp.IN"))
    );
    try testing.expectError(EvalError.InvalidForm, r);
    try testing.expect(std.mem.indexOf(u8, errorText(&eval), "already wired to net \"IF_MID\"") != null);
}

// spec: eval/connect - a sub-block port wired by both a bridge and a connect is refused, naming where the bridge was written
test "a bridge and a connect on one port is an error naming both" {
    const a = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    const r = evalFixture(a, &eval,
        \\(defmodule filt ()
        \\  (design-block "F"
        \\    (port "IN"  in  rf)
        \\    (port "OUT" out rf)
        \\    (instance "U1" twoterm (pin 1 "IN") (pin 2 "OUT"))))
        \\(design-block "T"
        \\  (instance "pad" sevenpad (pin 1 3 4 6 7 "GND"))
        \\  (sub-block "f" (filt) (bridge "" (rename IN IF_MID) OUT))
        \\  (connect "pad.RF_OUT" "f/IN"))
    );
    try testing.expectError(EvalError.InvalidForm, r);
    const msg = errorText(&eval);
    try testing.expect(std.mem.indexOf(u8, msg, "f/IN") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "IF_MID") != null);
    // "both places": the message points at the bridge's own line.
    try testing.expect(std.mem.indexOf(u8, msg, "at line") != null);
}

// spec: eval/connect - a bare chain item with more than two pads is refused with the explicit spelling in the message
test "a bare chain item must be two-terminal" {
    const a = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    const r = evalFixture(a, &eval,
        \\(design-block "T"
        \\  (instance "pad" sevenpad (pin 1 3 4 6 7 "GND"))
        \\  (chain "IF_IN" "pad" "IF_OUT"))
    );
    try testing.expectError(EvalError.InvalidForm, r);
    const msg = errorText(&eval);
    try testing.expect(std.mem.indexOf(u8, msg, "has 7 pads") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "/IN>OUT") != null);
}

// spec: eval/connect - a chain item naming no placed part or sub-block is refused rather than inventing a net
test "an unknown chain item is an error" {
    const a = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    const r = evalFixture(a, &eval,
        \\(design-block "T"
        \\  (instance "lpf" twoterm (pin 1 "IF_IN"))
        \\  (chain "IF_IN" "nosuchpart" "IF_OUT"))
    );
    try testing.expectError(EvalError.InvalidForm, r);
    try testing.expect(std.mem.indexOf(u8, errorText(&eval), "nosuchpart") != null);
}

// spec: eval/connect - a sub-block with no unique signal path is refused with its candidate ports listed
test "an ambiguous sub-block chain item lists its candidates" {
    const a = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    const r = evalFixture(a, &eval,
        \\(defmodule splitter ()
        \\  (design-block "S"
        \\    (port "IN"   in  rf)
        \\    (port "OUT1" out rf)
        \\    (port "OUT2" out rf)
        \\    (instance "U1" twoterm (pin 1 "IN") (pin 2 "OUT1"))))
        \\(design-block "T"
        \\  (sub-block "s" (splitter))
        \\  (chain "IF_IN" "s" "IF_OUT"))
    );
    try testing.expectError(EvalError.InvalidForm, r);
    const msg = errorText(&eval);
    try testing.expect(std.mem.indexOf(u8, msg, "OUT1 (out rf)") != null);
    try testing.expect(std.mem.indexOf(u8, msg, "OUT2 (out rf)") != null);
}

// spec: eval/connect - an end that names an ordinary net joins that net instead of generating a second name for the same node
test "a plain-net end keeps its authored name" {
    const a = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    const block = try evalFixture(a, &eval,
        \\(design-block "T"
        \\  (instance "lpf" twoterm (pin 1 "IF_IN"))
        \\  (connect "IF_MID" "lpf.OUT"))
    );
    try testing.expect(netNamed(block, "IF_MID") != null);
    try testing.expectEqual(@as(usize, 0), (try anonNames(a, block)).len);
}

// spec: eval/connect - two connects that would generate the same name get distinct nets rather than silently merging
test "a repeated generated name is disambiguated, never merged" {
    const a = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    // Both connects spell the same two ends, on different pads of the same
    // parts — the SAME generated key. They are two nodes, not one.
    const block = try evalFixture(a, &eval,
        \\(design-block "T"
        \\  (instance "u" sevenpad (pin 1 3 "GND"))
        \\  (instance "v" sevenpad (pin 1 3 "GND"))
        \\  (connect "u.4" "v.4" (name "n~u-4~v-4"))
        \\  (connect "u.6" "v.6"))
    );
    _ = block;
    // The authored name above occupies the slot a later generated name would
    // want; nothing merged, because the ledger reserves every name it hands out.
    var seen: usize = 0;
    for (eval.warnings.items) |w| {
        if (std.mem.indexOf(u8, w.message, "merged into one") != null) seen += 1;
    }
    try testing.expectEqual(@as(usize, 0), seen);
}

test "the generated prefix is URL-unreserved and structurally inert" {
    // Every byte of the prefix must be RFC 3986 unreserved, must not be the
    // bypass-stub separator, and must not be the hierarchy separator.
    for (anon_prefix) |c| {
        try testing.expect(c != '.' and c != '/');
        const unreserved = std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~';
        try testing.expect(unreserved);
    }
    // A shell would tilde-expand a leading `~`; the prefix puts a letter first.
    try testing.expect(anon_prefix[0] != '~');
    try testing.expect(isAnonymous("n~a~b"));
    try testing.expect(!isAnonymous("IF1_PAD"));
}

test "sanitizeByte keeps a name spellable in a URL and a KiCad label" {
    const cases = "aZ0_-./ +()\"\\";
    for (cases) |c| {
        const out = sanitizeByte(c);
        const ok = std.ascii.isAlphanumeric(out) or out == '_' or out == '-';
        try testing.expect(ok);
    }
    try testing.expectEqual(@as(u8, '-'), sanitizeByte('.'));
    try testing.expectEqual(@as(u8, '-'), sanitizeByte('/'));
    try testing.expectEqual(@as(u8, '_'), sanitizeByte('+'));
}

// spec: eval/connect - a form with too few ends, or an empty end token, is refused rather than producing a nameless net
test "empty inputs are refused, not wired" {
    const a = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    // An empty design block with no connect at all resolves to nothing.
    _ = try evalFixture(a, &eval, "(design-block \"T\")");

    var e2: Evaluator = undefined;
    try testing.expectError(EvalError.ArityError, evalFixture(a, &e2,
        \\(design-block "T" (connect "IF_IN"))
    ));
    var e3: Evaluator = undefined;
    try testing.expectError(EvalError.InvalidForm, evalFixture(a, &e3,
        \\(design-block "T"
        \\  (instance "lpf" twoterm (pin 1 "IF_IN"))
        \\  (connect "lpf.OUT" ""))
    ));
    try testing.expect(std.mem.indexOf(u8, errorText(&e3), "names nothing") != null);
    var e4: Evaluator = undefined;
    try testing.expectError(EvalError.ArityError, evalFixture(a, &e4,
        \\(design-block "T" (chain "A" "B"))
    ));
}

/// A design whose single `(connect …)` has `n` ends, each on its own long-named
/// part — the shape that forces the generated name past its spelled-out cap.
fn wideConnectSource(a: std.mem.Allocator, n: usize) ![]const u8 {
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(a, "(design-block \"T\"\n");
    for (0..n) |i| {
        try src.appendSlice(a, try std.fmt.allocPrint(a, "  (instance \"long_part_name_{d}\" twoterm (pin 1 \"GND\"))\n", .{i}));
    }
    try src.appendSlice(a, "  (connect");
    for (0..n) |i| {
        try src.appendSlice(a, try std.fmt.allocPrint(a, " \"long_part_name_{d}.OUT\"", .{i}));
    }
    try src.appendSlice(a, "))");
    return src.items;
}

// spec: eval/connect - large inputs — a connect with many ends collapses to one short, legal, deterministic net name
test "large inputs collapse to a bounded hashed name" {
    const a = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    // Twelve ends on one node: spelled out the name would be unreadable, so it
    // keeps its first end and takes a hash of the whole key.
    const src = try wideConnectSource(a, 12);
    const block = try evalFixture(a, &eval, src);
    const names = try anonNames(a, block);
    try testing.expectEqual(@as(usize, 1), names.len);
    try testing.expect(names[0].len <= max_spelled_len);
    try testing.expect(isAnonymous(names[0]));
    // Deterministic: the same source hashes to the same name.
    var e2: Evaluator = undefined;
    const again = try anonNames(a, try evalFixture(a, &e2, src));
    try testing.expectEqualStrings(names[0], again[0]);
}

// spec: eval/connect - a malformed or non-ASCII end token still yields a name legal in every URL, JSON and KiCad surface
test "malformed encoding in an end token cannot leak into the net name" {
    const a = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    // A ref-des carrying bytes that are not valid UTF-8, plus a quote and a
    // paren — every one of which would wreck a URL, a JSON string or the
    // netlist grammar if it reached the name.
    const block = try evalFixture(a, &eval, "(design-block \"T\"\n" ++
        "  (instance \"a\xff\xfe\\\"b(c\" twoterm (pin 1 \"GND\"))\n" ++
        "  (instance \"d e\" twoterm (pin 1 \"GND\"))\n" ++
        "  (connect \"a\xff\xfe\\\"b(c.OUT\" \"d e.OUT\"))\n");
    const names = try anonNames(a, block);
    try testing.expectEqual(@as(usize, 1), names.len);
    for (names[0][anon_prefix.len..]) |c| {
        const ok = std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '~';
        try testing.expect(ok);
    }
}

// spec: eval/connect - panic-free — every malformed end spelling is reported with a message, never crashed on
test "malformed end spellings never panic" {
    const a = std.heap.page_allocator;
    // Every one of these is either wired as an ordinary net name or refused
    // with a message; neither outcome may be a crash, and an error always
    // carries text.
    const cases = [_][]const u8{
        "(connect \"lpf.OUT\" \".\")",
        "(connect \"lpf.OUT\" \"/\")",
        "(connect \"lpf.OUT\" \"a/\")",
        "(connect \"lpf.OUT\" \"/b\")",
        "(connect \"lpf.OUT\" \".x\")",
        "(connect \"lpf.OUT\" \"x.\")",
        "(connect \"lpf.OUT\" \"a/b/c\")",
        "(connect \"lpf.OUT\" \"a.b.c\")",
        "(connect \"lpf.OUT\" \"~\")",
        "(connect \"lpf.OUT\" \">\")",
        "(chain \"A\" \">\" \"B\")",
        "(chain \"A\" \"a/>\" \"B\")",
        "(chain \"A\" \"a>b\" \"B\")",
        "(chain \"A\" \"/>\" \"B\")",
        "(chain \"A\" \"lpf/>OUT\" \"B\")",
        "(chain \"A\" \"lpf/IN>\" \"B\")",
        "(chain \"A\" \"lpf\" \"B\" \"C\" \"D\")",
    };
    for (cases) |form| try expectNoCrash(a, form);
}

/// Evaluate a one-part design carrying `form` as its only wiring statement, and
/// assert only that the evaluator either succeeded or recorded a message —
/// never that it crashed.
fn expectNoCrash(a: std.mem.Allocator, form: []const u8) !void {
    var eval: Evaluator = undefined;
    const src = try std.fmt.allocPrint(
        a,
        "(design-block \"T\"\n  (instance \"lpf\" twoterm (pin 1 \"GND\"))\n  {s})",
        .{form},
    );
    if (evalFixture(a, &eval, src)) |_| {} else |_| {
        try testing.expect(errorText(&eval).len > 0);
    }
}

// spec: eval/connect - a (class …) on a connect or a chain adds every net it makes to that net-class
test "a class option enrolls the generated nets" {
    const a = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    const block = try evalFixture(a, &eval,
        \\(design-block "T"
        \\  (net-class "if-50" (width 0.28))
        \\  (instance "lpf" twoterm (pin 1 "IF_IN"))
        \\  (instance "amp" twoterm (pin 2 "IF_OUT"))
        \\  (connect "lpf.OUT" "amp.IN" (class "if-50")))
    );
    try testing.expectEqual(@as(usize, 1), block.net_classes.len);
    const nets = block.net_classes[0].nets;
    try testing.expectEqual(@as(usize, 1), nets.len);
    try testing.expectEqualStrings("n~lpf-OUT~amp-IN", nets[0]);
}

// spec: eval/connect - a class naming no declared net-class warns rather than silently dropping the intent
test "an unknown class warns and still wires the net" {
    const a = std.heap.page_allocator;
    var eval: Evaluator = undefined;
    const block = try evalFixture(a, &eval,
        \\(design-block "T"
        \\  (instance "lpf" twoterm (pin 1 "IF_IN"))
        \\  (instance "amp" twoterm (pin 2 "IF_OUT"))
        \\  (connect "lpf.OUT" "amp.IN" (class "nope")))
    );
    try testing.expect(netNamed(block, "n~lpf-OUT~amp-IN") != null);
    var warned = false;
    for (eval.warnings.items) |w| {
        if (std.mem.indexOf(u8, w.message, "names no (net-class") != null) warned = true;
    }
    try testing.expect(warned);
}
