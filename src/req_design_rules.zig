//! Evaluation of **design-owned rules** — the `(requirement … (on "REF")
//! (check …))` and `(net-rule …)` forms parsed by `eval/authored_rules.zig`.
//!
//! A library requirement asks "does every design placing this part follow the
//! datasheet"; a design rule asks "does this board hold to what its own author
//! wrote down". They are gated identically, so the outcome type here is the
//! same `req_checks.Status` the library pipeline produces and `preflight.zig`
//! turns both into findings that differ only by `source`.
//!
//! **Result model.** A rule produces one `TargetResult` per thing it judged —
//! the single instance an `(on …)` rule names, or **one per matched net** for a
//! net rule (plus one per glob that matched nothing, which is a failure, never
//! a silent pass) — and one rolled-up `Outcome.status`, the worst of them. Both
//! halves are load-bearing and neither could replace the other: the per-target
//! results are what `netlisp check` emits as findings, because a failure has to
//! name the net; the rollup is the rule's single identity, which is what a
//! `(verifies (req design-rule <id>) …)` sign-off addresses and what the review
//! document shows one row for. Reporting only per-net findings would give a
//! sign-off nothing to attach to; reporting only the rollup would hide which
//! net failed.

const std = @import("std");
const env_mod = @import("eval/env.zig");
const req_checks = @import("req_checks.zig");
const authored_rules = @import("eval/authored_rules.zig");
const flat_netlist = @import("flat_netlist.zig");
const na = @import("eval/net_analysis.zig");
const net_name = @import("net_name.zig");
const Evaluator = @import("eval/evaluator.zig").Evaluator;

const DesignBlock = env_mod.DesignBlock;
const DesignRule = env_mod.DesignRule;
const NetPredicate = env_mod.NetPredicate;
const Status = req_checks.Status;

/// Tolerance on the capacitance sum, in µF. Values parse through the same
/// `parseMicroFarads` the library `(decoupling …)` check uses, so the same
/// picofarad-scale slack applies to a sum of them.
const value_tolerance_uf: f64 = 1e-12;

/// One thing a design rule judged: the instance an `(on …)` rule named, the
/// flattened net a `(net-rule …)` glob matched, or the glob itself when it
/// matched nothing at all.
pub const TargetResult = struct {
    name: []const u8,
    status: Status,
    /// Human-readable verdict, owned by the allocator passed to `run`.
    message: []const u8 = "",
};

/// One evaluated design rule. `targets` and `block_path` are owned by the
/// allocator passed to `run`; everything reachable through `rule` is borrowed
/// from the design's AST.
pub const Outcome = struct {
    /// The rule as authored — its text, id, citation, section path and body.
    rule: DesignRule,
    /// Sub-block path of the block that owns the rule (`""` at the design
    /// root, `"buck"` for a rule authored inside a module instantiated there).
    block_path: []const u8 = "",
    targets: []const TargetResult,
    /// Worst status across `targets` — the rule's single verdict.
    status: Status,
    /// Set when a `(verifies (req design-rule <id>) …)` signed the rule off.
    verification: ?env_mod.Verification = null,

    /// True for a `(net-rule …)`, false for `(requirement … (on …))`.
    pub fn netScoped(self: Outcome) bool {
        return std.meta.activeTag(self.rule.body) == .net_scoped;
    }
};

/// Free every allocation `run` handed back.
pub fn deinit(allocator: std.mem.Allocator, outcomes: []const Outcome) void {
    for (outcomes) |outcome| {
        for (outcome.targets) |target| {
            if (target.name.len > 0) allocator.free(target.name);
            if (target.message.len > 0) allocator.free(target.message);
        }
        allocator.free(outcome.targets);
        if (outcome.block_path.len > 0) allocator.free(outcome.block_path);
    }
    allocator.free(outcomes);
}

/// Evaluate every design-owned rule in `root` and its sub-block tree. Results
/// come back in authored order, outermost block first. `eval` is needed for the
/// same reason the library checker needs it: resolving a pin FUNCTION name
/// through the target instance's pinout.
pub fn run(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    root: *const DesignBlock,
) std.mem.Allocator.Error![]Outcome {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var ctx = try Context.build(arena, root);
    var out: std.ArrayList(Outcome) = .empty;
    errdefer {
        deinit(allocator, out.items);
        out = .empty;
    }
    try walk(allocator, eval, &ctx, root, "", &out);
    return out.toOwnedSlice(allocator);
}

/// `run` + `applyVerifications` in one call, degrading to "no design rules"
/// when allocation fails. The rendering surfaces (review document, schematic
/// page, PDF) want exactly this: a design that ran out of memory building an
/// advisory table should still render, the way they already treat a failed
/// `runChecks` as an empty result map.
pub fn runVerified(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    root: *const DesignBlock,
) []const Outcome {
    const outcomes = run(allocator, eval, root) catch return &.{};
    applyVerifications(outcomes, root);
    return outcomes;
}

/// Overlay design-side `(verifies (req design-rule <id>) …)` sign-offs, exactly
/// as `req_checks.applyVerifications` does for library requirements: a rule
/// that reached no verdict becomes `verified`, a failing rule keeps its `fail`
/// and carries the rationale for the "overridden" badge, and a passing rule is
/// left alone. Sign-offs are read from every block in the tree, so a board can
/// close a rule its module authored.
pub fn applyVerifications(outcomes: []Outcome, root: *const DesignBlock) void {
    applyBlockVerifications(outcomes, root);
}

fn applyBlockVerifications(outcomes: []Outcome, block: *const DesignBlock) void {
    for (block.verifications) |v| {
        if (!v.design_rule) continue;
        for (outcomes) |*outcome| {
            if (!std.mem.eql(u8, outcome.rule.id, v.req_id)) continue;
            switch (outcome.status) {
                .na, .unproven, .layout_deferred => {
                    outcome.status = .verified;
                    outcome.verification = v;
                },
                .fail => outcome.verification = v,
                .pass, .verified => {},
            }
        }
    }
    for (block.sub_blocks) |sb| applyBlockVerifications(outcomes, sb.block);
}

// ── Flattened evidence the net predicates read ─────────────────────────────

/// The flattened design every net rule is judged against, built once per run.
/// Net rules speak in FLAT net names (`V_3V3`, `buck/VOUT`) because that is the
/// name the board, the router and the reviewer all use; the alias map is what
/// lets a rule inside a module still name its own local net.
const Context = struct {
    root: *const DesignBlock,
    nets: []const flat_netlist.FlatNet,
    /// Pre-merge (hierarchy-prefixed) net name → the canonical name it merged
    /// into. Contains unchanged names too.
    aliases: flat_netlist.CanonicalNetMap,
    /// Canonical net name → index into `nets`.
    net_index: std.StringHashMapUnmanaged(usize),
    /// Flat ref-des → the part's value string (for capacitance sums).
    values: std.StringHashMapUnmanaged([]const u8),
    /// Flat ref-des → every canonical net the part lands on.
    ref_nets: std.StringHashMapUnmanaged([]const []const u8),

    fn build(arena: std.mem.Allocator, root: *const DesignBlock) std.mem.Allocator.Error!Context {
        var nets: std.ArrayList(flat_netlist.FlatNet) = .empty;
        var aliases: flat_netlist.CanonicalNetMap = .empty;
        try flat_netlist.flattenAndMergeNetsMapped(arena, root, &nets, &aliases);

        var net_index: std.StringHashMapUnmanaged(usize) = .empty;
        var ref_lists: std.StringHashMapUnmanaged(std.ArrayList([]const u8)) = .empty;
        for (nets.items, 0..) |net, i| {
            try net_index.put(arena, net.name, i);
            for (net.pins) |pin| {
                const gop = try ref_lists.getOrPut(arena, pin.ref_des);
                if (!gop.found_existing) gop.value_ptr.* = .empty;
                var seen = false;
                for (gop.value_ptr.items) |existing| {
                    if (std.mem.eql(u8, existing, net.name)) seen = true;
                }
                if (!seen) try gop.value_ptr.append(arena, net.name);
            }
        }
        var ref_nets: std.StringHashMapUnmanaged([]const []const u8) = .empty;
        var it = ref_lists.iterator();
        while (it.next()) |entry| try ref_nets.put(arena, entry.key_ptr.*, entry.value_ptr.items);

        var instances: std.ArrayList(flat_netlist.FlatInstance) = .empty;
        try flat_netlist.collectInstances(arena, root, "", &instances);
        var values: std.StringHashMapUnmanaged([]const u8) = .empty;
        for (instances.items) |inst| try values.put(arena, inst.ref_des, inst.value);

        return .{
            .root = root,
            .nets = nets.items,
            .aliases = aliases,
            .net_index = net_index,
            .values = values,
            .ref_nets = ref_nets,
        };
    }

    /// The canonical flat name a hierarchy-local net merged into.
    fn canonical(self: Context, prefixed_name: []const u8) []const u8 {
        return self.aliases.get(prefixed_name) orelse prefixed_name;
    }

    fn netAt(self: Context, name: []const u8) ?flat_netlist.FlatNet {
        const i = self.net_index.get(name) orelse return null;
        return self.nets[i];
    }
};

// ── Walk ───────────────────────────────────────────────────────────────────

fn walk(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    ctx: *Context,
    block: *const DesignBlock,
    path: []const u8,
    out: *std.ArrayList(Outcome),
) std.mem.Allocator.Error!void {
    for (block.authored_rules) |rule| {
        const targets = switch (rule.body) {
            .on_instance => |body| try evalInstanceRule(allocator, eval, block, body),
            .net_scoped => |body| try evalNetRule(allocator, ctx, block, path, body),
        };
        errdefer freeTargets(allocator, targets);
        try out.append(allocator, .{
            .rule = rule,
            .block_path = if (path.len == 0) "" else try allocator.dupe(u8, path),
            .targets = targets,
            .status = rollup(targets),
        });
    }
    for (block.sub_blocks) |sb| {
        const child = if (path.len == 0)
            try std.fmt.allocPrint(allocator, "{s}", .{sb.name})
        else
            try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, sb.name });
        defer allocator.free(child);
        try walk(allocator, eval, ctx, sb.block, child, out);
    }
}

fn freeTargets(allocator: std.mem.Allocator, targets: []const TargetResult) void {
    for (targets) |t| {
        if (t.name.len > 0) allocator.free(t.name);
        if (t.message.len > 0) allocator.free(t.message);
    }
    allocator.free(targets);
}

/// Worst status across a rule's targets. `fail` dominates, then the two
/// ran-but-undecided outcomes, then reviewer judgement; a rule passes only when
/// every target it judged passed.
fn rollup(targets: []const TargetResult) Status {
    var worst: Status = .pass;
    for (targets) |t| {
        if (rank(t.status) > rank(worst)) worst = t.status;
    }
    return worst;
}

fn rank(status: Status) u8 {
    return switch (status) {
        .pass, .verified => 0,
        .layout_deferred => 1,
        .na => 2,
        .unproven => 3,
        .fail => 4,
    };
}

// ── (requirement … (on "REF") (check …)) ───────────────────────────────────

const InstanceBody = @FieldType(DesignRule.Body, "on_instance");

/// Judge one `(on "REF")` rule. The instance is looked up in the rule's own
/// block, or — for a `"sub/REF"` target — inside that sub-block, and the check
/// is then evaluated against THAT block. This is the same containing-block
/// contract a library requirement on the same part gets, which is what lets a
/// board reuse a primitive like `decoupling` without its pin names silently
/// resolving against the wrong net namespace.
fn evalInstanceRule(
    allocator: std.mem.Allocator,
    eval: *Evaluator,
    block: *const DesignBlock,
    body: InstanceBody,
) std.mem.Allocator.Error![]const TargetResult {
    const target = body.target;
    const name = try allocator.dupe(u8, target);
    errdefer allocator.free(name);

    const host = resolveBlock(block, net_name.parent(target)) orelse {
        return try one(allocator, name, .fail, "no sub-block '{s}' in this block", .{net_name.parent(target).?});
    };
    const leaf = net_name.leaf(target);
    for (host.instances) |inst| {
        if (!namesInstance(inst, leaf)) continue;
        const result = req_checks.evalCheck(allocator, eval, host, inst, body.check);
        const slice = try allocator.alloc(TargetResult, 1);
        slice[0] = .{ .name = name, .status = result.status, .message = result.message };
        return slice;
    }
    return try one(allocator, name, .fail, "(on \"{s}\") names no instance in this block", .{target});
}

/// Does `token` name this instance? The final ref-des is checked first, then
/// the instance's stable module-local identity and its descriptive label.
///
/// The last two are not a convenience: a sub-block's parts are RENUMBERED into
/// the board's global ref-des space (`ids.assignSubBlockRefDes`), so the `U9` a
/// module's author reads in their own source is `U2` by the time the board is
/// built. Matching only the final ref-des would make `(on "reg/U9")` a rule
/// nobody could write from inside the module — and one that silently broke
/// whenever an unrelated part was added ahead of it.
fn namesInstance(inst: env_mod.Instance, token: []const u8) bool {
    if (std.mem.eql(u8, inst.ref_des, token)) return true;
    if (inst.origin_key.len > 0 and std.mem.eql(u8, inst.origin_key, token)) return true;
    return inst.label.len > 0 and std.mem.eql(u8, inst.label, token);
}

/// Follow a `sub/nested` path from `block`, or return `block` itself for a
/// null path. Null when a segment names no sub-block.
fn resolveBlock(block: *const DesignBlock, path: ?[]const u8) ?*const DesignBlock {
    const p = path orelse return block;
    var current = block;
    var it = std.mem.splitScalar(u8, p, '/');
    outer: while (it.next()) |segment| {
        if (segment.len == 0) continue;
        for (current.sub_blocks) |sb| {
            if (std.mem.eql(u8, sb.name, segment)) {
                current = sb.block;
                continue :outer;
            }
        }
        return null;
    }
    return current;
}

fn one(
    allocator: std.mem.Allocator,
    name: []const u8,
    status: Status,
    comptime fmt: []const u8,
    args: anytype,
) std.mem.Allocator.Error![]const TargetResult {
    const slice = try allocator.alloc(TargetResult, 1);
    slice[0] = .{ .name = name, .status = status, .message = try std.fmt.allocPrint(allocator, fmt, args) };
    return slice;
}

// ── (net-rule …) ───────────────────────────────────────────────────────────

const NetBody = @FieldType(DesignRule.Body, "net_scoped");

/// One candidate net for a glob: the name as the rule's own block sees it, and
/// the canonical flattened name every predicate is judged against.
const Candidate = struct { local: []const u8, flat: []const u8 };

fn evalNetRule(
    allocator: std.mem.Allocator,
    ctx: *Context,
    block: *const DesignBlock,
    path: []const u8,
    body: NetBody,
) std.mem.Allocator.Error![]const TargetResult {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var candidates: std.ArrayList(Candidate) = .empty;
    try collectCandidates(arena, ctx, block, path, "", &candidates);

    var results: std.ArrayList(TargetResult) = .empty;
    errdefer freeTargets(allocator, results.items);
    var matched: std.StringHashMapUnmanaged(void) = .empty;
    for (body.globs) |glob| {
        var hits: usize = 0;
        for (candidates.items) |candidate| {
            if (!authored_rules.globMatches(glob, candidate.local) and
                !authored_rules.globMatches(glob, candidate.flat)) continue;
            hits += 1;
            if (matched.contains(candidate.flat)) continue;
            try matched.put(arena, candidate.flat, {});
            try results.append(allocator, try judgeNet(allocator, ctx, candidate.flat, body.predicates));
        }
        // A glob nothing matches is a FAILED rule naming the glob, never a
        // vacuous pass: the overwhelmingly likely cause is that the net was
        // renamed or never existed, which is exactly what the rule was written
        // to catch.
        if (hits == 0) {
            try results.append(allocator, .{
                .name = try allocator.dupe(u8, glob),
                .status = .fail,
                .message = try std.fmt.allocPrint(allocator, "(nets \"{s}\") matched no net in this block", .{glob}),
            });
        }
    }
    return results.toOwnedSlice(allocator);
}

/// Every net reachable from `block` (including its sub-block tree), named both
/// as the rule's own block sees it and by its canonical flattened name. A glob
/// matching either is a hit — which is what lets a module author write
/// `(nets "VOUT")` and the board that instantiates it write `(nets "buck/*")`
/// for the same copper.
fn collectCandidates(
    arena: std.mem.Allocator,
    ctx: *Context,
    block: *const DesignBlock,
    root_path: []const u8,
    local_path: []const u8,
    out: *std.ArrayList(Candidate),
) std.mem.Allocator.Error!void {
    for (block.nets) |net| {
        // Per-pin bypass stubs (`VDD.U1.5`) are an internal split of the rail
        // they hang off, not nets an author names; skipping them keeps a
        // `V_*` glob from reporting one result per decoupling capacitor.
        if (na.isSubNetName(net.name)) continue;
        const local = try join(arena, local_path, net.name);
        const prefixed = try join(arena, root_path, local);
        try out.append(arena, .{ .local = local, .flat = ctx.canonical(prefixed) });
    }
    for (block.sub_blocks) |sb| {
        try collectCandidates(arena, ctx, sb.block, root_path, try join(arena, local_path, sb.name), out);
    }
}

fn join(arena: std.mem.Allocator, prefix: []const u8, name: []const u8) std.mem.Allocator.Error![]const u8 {
    if (prefix.len == 0) return name;
    return std.fmt.allocPrint(arena, "{s}/{s}", .{ prefix, name });
}

/// Judge every predicate against one matched net, folding them into a single
/// result: the status is the worst outcome and the message names each
/// predicate's verdict, so a reviewer reads one line per net rather than one
/// line per (net, predicate) pair.
fn judgeNet(
    allocator: std.mem.Allocator,
    ctx: *Context,
    flat: []const u8,
    predicates: []const NetPredicate,
) std.mem.Allocator.Error!TargetResult {
    var message: std.Io.Writer.Allocating = .init(allocator);
    errdefer message.deinit();
    var worst: Status = .pass;
    for (predicates, 0..) |predicate, i| {
        // The only failure `Writer.Allocating` can raise is an allocation
        // failure, which is this function's own error set.
        if (i > 0) message.writer.writeAll("; ") catch return error.OutOfMemory;
        const verdict = judgeOne(ctx, flat, predicate);
        if (rank(verdict.status) > rank(worst)) worst = verdict.status;
        message.writer.print("{s}", .{verdict.detail}) catch return error.OutOfMemory;
        if (verdict.value) |value| message.writer.print(" {d:.3}", .{value}) catch return error.OutOfMemory;
    }
    return .{
        .name = try allocator.dupe(u8, flat),
        .status = worst,
        .message = try message.toOwnedSlice(),
    };
}

/// One predicate's verdict on one net. `detail` is a static sentence and
/// `value` the measurement it needs, kept apart so the message assembly above
/// needs no per-predicate allocation.
const Verdict = struct { status: Status, detail: []const u8, value: ?f64 = null };

fn judgeOne(ctx: *Context, flat: []const u8, predicate: NetPredicate) Verdict {
    return switch (predicate) {
        .min_bulk_uf => |want| blk: {
            const have = bulkMicroFarads(ctx, flat);
            break :blk if (have + value_tolerance_uf >= want)
                .{ .status = .pass, .detail = "bulk to ground, µF:", .value = have }
            else
                .{ .status = .fail, .detail = "bulk to ground below the floor, µF:", .value = have };
        },
        .declared_envelope => blk: {
            for (ctx.root.net_envelopes) |envelope| {
                if (std.mem.eql(u8, envelope.net, flat))
                    break :blk .{ .status = .pass, .detail = "envelope declared" };
            }
            // Unproven, not failed: the net exists and may well be safe — the
            // design just carries nothing that says so. Authoring a
            // `(net-envelope …)` or a `(port … (nominal …))` upstream closes it.
            break :blk .{ .status = .unproven, .detail = "no derivable DC envelope" };
        },
        .in_net_class => blk: {
            for (ctx.root.net_classes) |class| {
                for (class.nets) |member| {
                    if (netNameMatches(member, flat))
                        break :blk .{ .status = .pass, .detail = "in a net class" };
                }
            }
            break :blk .{ .status = .fail, .detail = "in no (net-class …)" };
        },
        .max_fanout => |limit| blk: {
            const net = ctx.netAt(flat) orelse
                break :blk .{ .status = .unproven, .detail = "net not present in the flattened design" };
            const pins: f64 = @floatFromInt(net.pins.len);
            break :blk if (net.pins.len <= limit)
                .{ .status = .pass, .detail = "pins:", .value = pins }
            else
                .{ .status = .fail, .detail = "over the fanout budget, pins:", .value = pins };
        },
    };
}

/// A `(net-class … (nets …))` member name matches a flat net by its full name
/// or by its bare leaf, ASCII case-insensitively — the same convention every
/// other `(nets …)` selector in the DSL uses, so class membership here means
/// exactly what it means to the router.
fn netNameMatches(member: []const u8, flat: []const u8) bool {
    return std.ascii.eqlIgnoreCase(member, flat) or
        std.ascii.eqlIgnoreCase(member, net_name.leaf(flat));
}

/// Capacitance, in µF, summed over every capacitor bridging `flat` and a
/// ground net other than `flat` itself. A capacitor whose value string does
/// not parse contributes nothing rather than being guessed at.
fn bulkMicroFarads(ctx: *Context, flat: []const u8) f64 {
    const net = ctx.netAt(flat) orelse return 0;
    var total: f64 = 0;
    // No de-duplication pass is needed: a capacitor counts only when one of
    // its OTHER nets is a ground, so a part reached twice through this net's
    // pin list would have both legs shorted onto `flat` and be skipped.
    for (net.pins) |pin| {
        if (na.refDesLocalPrefix(pin.ref_des) != 'C') continue;
        if (!touchesGround(ctx, pin.ref_des, flat)) continue;
        const value = ctx.values.get(pin.ref_des) orelse continue;
        total += req_checks.parseMicroFarads(value) orelse continue;
    }
    return total;
}

fn touchesGround(ctx: *Context, ref_des: []const u8, exclude: []const u8) bool {
    const nets = ctx.ref_nets.get(ref_des) orelse return false;
    for (nets) |name| {
        if (std.mem.eql(u8, name, exclude)) continue;
        if (na.isGroundName(net_name.leaf(name))) return true;
    }
    return false;
}

// ── Tests ──────────────────────────────────────────────────────────────

test "rollup reports the worst target status" {
    const cases = [_]TargetResult{
        .{ .name = "A", .status = .pass },
        .{ .name = "B", .status = .unproven },
        .{ .name = "C", .status = .pass },
    };
    try std.testing.expectEqual(Status.unproven, rollup(&cases));

    const with_fail = [_]TargetResult{
        .{ .name = "A", .status = .unproven },
        .{ .name = "B", .status = .fail },
    };
    try std.testing.expectEqual(Status.fail, rollup(&with_fail));

    // An all-pass rule passes; an empty target list is a pass by construction
    // (it cannot happen — a glob that matched nothing emits a failure).
    const all_pass = [_]TargetResult{.{ .name = "A", .status = .pass }};
    try std.testing.expectEqual(Status.pass, rollup(&all_pass));
    try std.testing.expectEqual(Status.pass, rollup(&.{}));
}

// spec: req_design_rules - a design rule targeting a sub-block instance is judged in that sub-block's own block
test "resolveBlock follows a sub-block path and refuses an unknown segment" {
    var inner: DesignBlock = .{
        .name = "inner",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &.{},
    };
    const subs = [_]env_mod.SubBlock{.{ .name = "buck", .block = &inner }};
    var outer: DesignBlock = .{
        .name = "outer",
        .instances = &.{},
        .nets = &.{},
        .ports = &.{},
        .notes = &.{},
        .groups = &.{},
        .sub_blocks = &subs,
    };
    // A null path is the rule's own block — the plain `(on "U1")` case.
    try std.testing.expectEqual(@as(?*const DesignBlock, &outer), resolveBlock(&outer, null));
    try std.testing.expectEqual(@as(?*const DesignBlock, &inner), resolveBlock(&outer, "buck"));
    try std.testing.expectEqual(@as(?*const DesignBlock, null), resolveBlock(&outer, "ldo"));
}

// ── Integration fixtures ───────────────────────────────────────────────────

/// A project directory holding the two library parts every design fixture
/// below places, plus an evaluator pointed at it. `tmp` must outlive the
/// evaluator; `deinit` releases both.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    eval: Evaluator,

    fn open(allocator: std.mem.Allocator) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        try tmp.dir.createDirPath(std.testing.io, "lib/components");
        try tmp.dir.createDirPath(std.testing.io, "lib/pinouts");
        try tmp.dir.writeFile(std.testing.io, .{
            .sub_path = "lib/pinouts/ldo.sexp",
            .data = "(pinout \"ldo\" (pin 1 \"VIN\") (pin 2 \"GND\") (pin 5 \"VOUT\"))",
        });
        try tmp.dir.writeFile(std.testing.io, .{
            .sub_path = "lib/components/ldo.sexp",
            .data =
            \\(component "ldo"
            \\  (pinout "ldo")
            \\  (footprint "sot23-5"))
            ,
        });
        try tmp.dir.writeFile(std.testing.io, .{
            .sub_path = "lib/components/cap-0402.sexp",
            .data =
            \\(component-family "cap-0402"
            \\  (symbol generic-cap)
            \\  (footprint c-0402)
            \\  (parameter "value" capacitance))
            ,
        });
        const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
        return .{ .tmp = tmp, .eval = Evaluator.init(allocator, project) };
    }

    fn deinit(self: *Fixture) void {
        self.eval.deinit();
        self.tmp.cleanup();
    }

    /// Evaluate `source` as a design and run every design-owned rule in it.
    fn rules(self: *Fixture, allocator: std.mem.Allocator, source: []const u8) ![]Outcome {
        const value = try self.eval.evalSource(source);
        const block = switch (value) {
            .design_block => |b| b,
            else => return error.TestNotADesign,
        };
        const out = try run(allocator, &self.eval, block);
        applyVerifications(out, block);
        return out;
    }
};

/// The rule whose text is `text`, so a fixture asserting on one rule of
/// several does not depend on evaluation order.
fn ruleNamed(outcomes: []const Outcome, text: []const u8) !Outcome {
    for (outcomes) |outcome| {
        if (std.mem.eql(u8, outcome.rule.text, text)) return outcome;
    }
    return error.NoSuchRule;
}

/// The per-target result named `name`, for the same reason `ruleNamed` exists:
/// a net rule's results follow the flatten's order, not the source's.
fn targetNamed(outcome: Outcome, name: []const u8) !TargetResult {
    for (outcome.targets) |target| {
        if (std.mem.eql(u8, target.name, name)) return target;
    }
    return error.NoSuchTarget;
}

// spec: req_design_rules - every predicate a net rule carries folds into one message per matched net
test "judgeNet folds every predicate into one result per net" {
    const allocator = std.heap.page_allocator;
    var fixture = try Fixture.open(allocator);
    defer fixture.deinit();

    const outcomes = try fixture.rules(allocator,
        \\(import ldo cap-0402)
        \\(design-block "board"
        \\  (instance "U1" ldo (pin 1 "V_5V0") (pin 2 "GND") (pin 5 "V_3V3"))
        \\  (net-rule "Two predicates, one line" (nets "V_3V3") (min-bulk-uf 1) (max-fanout 8)))
    );
    defer deinit(allocator, outcomes);

    const rule = try ruleNamed(outcomes, "Two predicates, one line");
    const target = try targetNamed(rule, "V_3V3");
    // One result per NET, not per (net, predicate) pair: both verdicts share
    // one message, joined by "; ", and the status is the worse of the two.
    try std.testing.expectEqual(Status.fail, target.status);
    try std.testing.expect(std.mem.indexOf(u8, target.message, "; ") != null);
    try std.testing.expect(std.mem.indexOf(u8, target.message, "bulk to ground") != null);
    try std.testing.expect(std.mem.indexOf(u8, target.message, "pins:") != null);

    // The fixture helpers report their own lookup failures rather than
    // silently asserting on the wrong rule or target.
    try std.testing.expectError(error.NoSuchRule, ruleNamed(outcomes, "not a rule in this design"));
    try std.testing.expectError(error.NoSuchTarget, targetNamed(rule, "V_NOPE"));
    try std.testing.expectError(error.TestNotADesign, fixture.rules(allocator, "(+ 1 2)"));
}

// spec: req_design_rules - a design-owned net rule reports one result per matched net and fails a glob that matched nothing
test "evalNetRule reports per-net results and fails an unmatched glob" {
    const allocator = std.heap.page_allocator;
    var fixture = try Fixture.open(allocator);
    defer fixture.deinit();

    const outcomes = try fixture.rules(allocator,
        \\(import ldo cap-0402)
        \\(design-block "board"
        \\  (net-class "power" (nets "V_3V3"))
        \\  (net-envelope "V_3V3" (rated 0 3.6) "board rail")
        \\  (instance "U1" ldo (pin 1 "V_5V0") (pin 2 "GND") (pin 5 "V_3V3"))
        \\  (instance "C1" (cap-0402 "10uF") (pin 1 "V_3V3") (pin 2 "GND"))
        \\  (instance "C2" (cap-0402 "100nF") (pin 1 "V_3V3") (pin 2 "GND"))
        \\  (net-rule "Every board rail is bounded, classed and reservoired"
        \\    (nets "V_*")
        \\    (min-bulk-uf 4.7) (declared-envelope) (in-net-class) (max-fanout 8))
        \\  (net-rule "The audio rail exists" (nets "V_AUDIO") (max-fanout 4)))
    );
    defer deinit(allocator, outcomes);

    const rail = try ruleNamed(outcomes, "Every board rail is bounded, classed and reservoired");
    // One result per matched net: V_3V3 and V_5V0 both match `V_*`.
    try std.testing.expectEqual(@as(usize, 2), rail.targets.len);
    const v3v3 = try targetNamed(rail, "V_3V3");
    const v5v0 = try targetNamed(rail, "V_5V0");
    // V_3V3 carries 10.1 µF to GND, an authored envelope, a net class and 3
    // pins — every predicate holds.
    try std.testing.expectEqual(Status.pass, v3v3.status);
    // V_5V0 has no bulk and no class, so the same rule fails there — and the
    // ROLLUP is that failure, which is what a (verifies …) would address.
    try std.testing.expectEqualStrings("V_5V0", v5v0.name);
    try std.testing.expectEqual(Status.fail, v5v0.status);
    try std.testing.expectEqual(Status.fail, rail.status);

    // A glob matching nothing is a failed rule that NAMES the glob — never a
    // vacuous pass, which is what an "all matched nets pass" reading would give.
    const missing = try ruleNamed(outcomes, "The audio rail exists");
    try std.testing.expectEqual(@as(usize, 1), missing.targets.len);
    try std.testing.expectEqualStrings("V_AUDIO", missing.targets[0].name);
    try std.testing.expectEqual(Status.fail, missing.targets[0].status);
    try std.testing.expect(std.mem.indexOf(u8, missing.targets[0].message, "matched no net") != null);
}

// spec: req_design_rules - a design-owned (on "sub/REF") rule resolves the instance in that sub-block and judges the check against that block's nets
test "evalInstanceRule judges a sub-block target in the sub-block's own block" {
    const allocator = std.heap.page_allocator;
    var fixture = try Fixture.open(allocator);
    defer fixture.deinit();

    const outcomes = try fixture.rules(allocator,
        \\(import ldo cap-0402)
        \\(defmodule reg ()
        \\  (block "reg"
        \\    (port "vin" "VIN" input)
        \\    (instance "U9" ldo (pin 1 "VIN") (pin 2 "GND") (pin 5 "VOUT"))
        \\    (instance "C9" (cap-0402 "1uF") (pin 1 "VIN") (pin 2 "GND"))))
        \\(design-block "board"
        \\  (sub-block "reg" (reg))
        \\  (instance "U1" ldo (pin 1 "V_5V0") (pin 2 "GND") (pin 5 "V_3V3"))
        \\  (requirement "The regulator input is decoupled"
        \\    (on "reg/U9")
        \\    (check (decoupling (pin "VIN") (pin "GND") (min-uf 0.9))))
        \\  (requirement "The board LDO input is decoupled"
        \\    (on "U1")
        \\    (check (decoupling (pin "VIN") (pin "GND") (min-uf 0.9))))
        \\  (requirement "A rule may name a part that is not there"
        \\    (on "U404")
        \\    (check (pin-not-floating (pin "VIN")))))
    );
    defer deinit(allocator, outcomes);

    // The sub-block's own C9 satisfies it: the check saw the MODULE's VIN/GND
    // nets, not the board's. Resolving `VIN` in the outer block would have
    // found the board's V_5V0 instead and reported no capacitor.
    const inner = try ruleNamed(outcomes, "The regulator input is decoupled");
    try std.testing.expectEqual(@as(usize, 1), inner.targets.len);
    try std.testing.expectEqualStrings("reg/U9", inner.targets[0].name);
    try std.testing.expectEqual(Status.pass, inner.status);

    // The board's own U1 has no input capacitor, so the same rule fails there.
    const outer = try ruleNamed(outcomes, "The board LDO input is decoupled");
    try std.testing.expectEqual(Status.fail, outer.status);

    // A target that names nothing FAILS naming itself rather than passing
    // silently — a renamed part must not quietly retire the rule about it.
    const absent = try ruleNamed(outcomes, "A rule may name a part that is not there");
    try std.testing.expectEqual(Status.fail, absent.status);
    try std.testing.expect(std.mem.indexOf(u8, absent.targets[0].message, "no instance") != null);
}

// spec: req_design_rules - a design rule's id is the CRC32 of its text unless an explicit (id …) pins it, so unrelated edits keep sign-offs attached
test "design rule ids are text-derived and a design-rule sign-off closes them" {
    const allocator = std.heap.page_allocator;
    var fixture = try Fixture.open(allocator);
    defer fixture.deinit();

    const text = "Every rail declares its envelope";
    const expected = try env_mod.requirementIdForText(allocator, text);

    const outcomes = try fixture.rules(allocator,
        \\(import ldo cap-0402)
        \\(design-block "board"
        \\  (instance "U1" ldo (pin 1 "V_5V0") (pin 2 "GND") (pin 5 "V_3V3"))
        \\  (net-rule "Every rail declares its envelope" (nets "V_3V3") (declared-envelope))
        \\  (net-rule "Pinned rule" (nets "V_5V0") (declared-envelope) (id "deadbeef"))
        \\  (verifies (req design-rule "deadbeef") "5 V comes in from the bench supply"))
    );
    defer deinit(allocator, outcomes);

    // Byte-identical to the library derivation, so a design rule and a library
    // requirement addressed by the same text resolve the same id.
    const derived = try ruleNamed(outcomes, text);
    try std.testing.expectEqualStrings(expected, derived.rule.id);
    // Undecidable, not failed: nothing in the design says what V_3V3 reaches.
    try std.testing.expectEqual(Status.unproven, derived.status);

    // An explicit id wins, and a `(verifies (req design-rule …) …)` closes the
    // rule it names exactly as a library sign-off closes an unproven check.
    const pinned = try ruleNamed(outcomes, "Pinned rule");
    try std.testing.expectEqualStrings("deadbeef", pinned.rule.id);
    try std.testing.expectEqual(Status.verified, pinned.status);
    try std.testing.expect(pinned.verification != null);
}

// spec: req_design_rules - a design rule authored inside a section is judged against the containing block and records the section path
test "a section-scoped design rule is judged against the block that holds the section" {
    const allocator = std.heap.page_allocator;
    var fixture = try Fixture.open(allocator);
    defer fixture.deinit();

    const outcomes = try fixture.rules(allocator,
        \\(import ldo cap-0402)
        \\(design-block "board"
        \\  (section "Power"
        \\    (instance "U1" ldo (pin 1 "V_5V0") (pin 2 "GND") (pin 5 "V_3V3"))
        \\    (instance "C1" (cap-0402 "4.7uF") (pin 1 "V_5V0") (pin 2 "GND"))
        \\    (requirement "The LDO input is decoupled"
        \\      (on "U1")
        \\      (check (decoupling (pin "VIN") (pin "GND") (min-uf 1))))
        \\    (section "Rails"
        \\      (net-rule "The input rail carries bulk" (nets "V_5V0") (min-bulk-uf 4)))))
    );
    defer deinit(allocator, outcomes);

    const decouple = try ruleNamed(outcomes, "The LDO input is decoupled");
    try std.testing.expectEqual(Status.pass, decouple.status);
    // A section is a presentation grouping, not a net namespace: the rule is
    // judged against the design block and only RECORDS where it was authored.
    try std.testing.expectEqualStrings("Power", decouple.rule.scope);
    try std.testing.expectEqualStrings("", decouple.block_path);

    const bulk = try ruleNamed(outcomes, "The input rail carries bulk");
    try std.testing.expectEqual(Status.pass, bulk.status);
    try std.testing.expectEqualStrings("Power/Rails", bulk.rule.scope);
}
