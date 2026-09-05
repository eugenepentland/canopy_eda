//! Structural control flow for design scopes: `(when …)`, `(unless …)`,
//! `(if …)`, `(for …)` and `(repeat …)` expanding into whatever the enclosing
//! scope accepts (design-block top level, `(section …)`, nested sub-section).
//!
//! The scope dispatchers in `design_block.zig` own the grammar; this module
//! owns everything structural control flow adds on top of it:
//!
//!   * **branch/iteration selection** — which body forms run, and the key
//!     segment that execution contributes (`@t`, `@f`, `@<ordinal>`);
//!   * **identity** — one source-resident `(id …)` anchor per OUTERMOST
//!     structural form, from which every child derives
//!     `deriveChildId(anchor, origin_key ++ path)`. `path` is the accumulated
//!     segment chain, so `for` inside `when` inside `for` composes instead of
//!     the outer form flattening the inner one's distinctions, and a
//!     condition flip can never alias a then-child with an else-child;
//!   * **write-back hygiene** — a body's forms share one source location
//!     across every execution, so their own pending `(id …)` writes are
//!     dropped and only the anchor (plus its `(ids …)` migration sidecar) is
//!     source-resident.
//!
//! The enclosing scope is reached back through a small adapter value it
//! supplies (`emit` = its own child-form dispatcher, `targets` = the
//! accumulators a stamped child lands in), taken as `anytype` so each scope
//! stays a concrete type. That keeps the three near-identical scope switches
//! in one file and this machinery in another.

const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const env_mod = @import("env.zig");
const ids = @import("ids.zig");
const forms = @import("forms.zig");
const special_forms = @import("special_forms.zig");
const evaluator_mod = @import("evaluator.zig");
const Evaluator = evaluator_mod.Evaluator;
const EvalError = evaluator_mod.EvalError;

const Node = ast.Node;
const Env = env_mod.Env;
const Instance = env_mod.Instance;
const SubBlock = env_mod.SubBlock;
const Section = env_mod.Section;

/// The identity anchor a structural form owns: one source-resident `(id …)`
/// plus its optional `(ids …)` migration sidecar.
pub const Anchor = struct {
    id: []const u8,
    sidecar: ids.ChildIdSidecar,
};

/// Structural state for one design-block materialization. It lives in
/// `design_block.BlockBuildState` — one per materialization, so a sub-block's
/// module body opens its own conditional/loop nest and cannot inherit the
/// caller's key path — and is reached through the scope adapter's `state()`.
pub const State = struct {
    /// How many structural forms are currently open. Only the outermost
    /// (depth 0 on entry) mints an anchor — an inner form's `(id …)` would be
    /// written at the same source offset once per execution.
    depth: usize = 0,
    /// Accumulated key segments of the open structural forms, e.g. `"@t@2"`.
    path: []const u8 = "",
    /// The outermost open form's anchor; every child derives from it.
    root: ?Anchor = null,
};

/// Saved structural state, restored when a structural form finishes.
const Frame = struct {
    depth: usize,
    path: []const u8,
    root: ?Anchor,
};

/// Which structural form is being expanded. `for`/`repeat` were already
/// design-scope statements at design-block top level; the conditionals and
/// the section-scope availability are what this module adds.
pub const Kind = enum {
    when_,
    unless_,
    if_,
    for_,
    repeat_,

    /// The head atom as written, for diagnostics.
    pub fn sourceName(self: Kind) []const u8 {
        return switch (self) {
            .when_ => "when",
            .unless_ => "unless",
            .if_ => "if",
            .for_ => "for",
            .repeat_ => "repeat",
        };
    }
};

/// Map a `SpecialForm` onto the structural kind it expands as, or null when
/// the form is not structural (`let`, `import`, …).
pub fn kindOf(sf: forms.SpecialForm) ?Kind {
    return switch (sf) {
        .when_ => .when_,
        .unless_ => .unless_,
        .if_ => .if_,
        .for_ => .for_,
        .repeat => .repeat_,
        else => null,
    };
}

/// True when `node` is a structural form, i.e. one that stamps the identity
/// of the children it emits itself. Its siblings' children are stamped by the
/// enclosing form; its own must not be re-stamped, or the segment it
/// contributed to the key path would be flattened away.
pub fn isStructuralNode(node: Node) bool {
    const children = node.asList() orelse return false;
    if (children.len == 0) return false;
    const head = children[0].asAtom() orelse return false;
    const sf = forms.SpecialForm.fromAtom(head) orelse return false;
    return kindOf(sf) != null;
}

/// How far each accumulator had advanced before a body form ran; the children
/// past these marks are what that form emitted.
const Mark = struct {
    instances: usize,
    sub_blocks: usize,
    sections: usize,
    mirrors: [2]usize,
};

/// Where a stamped child lands: the block-wide instance and sub-block lists,
/// plus the section containers that keep value COPIES of their members.
///
/// `sections` is a section list built inside the body (design-block scope, or
/// a section's nested sub-sections); `mirrors` are the section-local instance
/// copies section and sub-section scopes keep alongside the block-wide list.
/// Both are re-synced by ref-des after a stamp.
pub const Targets = struct {
    instances: *std.ArrayList(Instance),
    sub_blocks: *std.ArrayList(SubBlock),
    sections: ?*std.ArrayList(Section) = null,
    mirrors: [2]?*std.ArrayList(Instance) = .{ null, null },

    fn mark(self: Targets) Mark {
        return .{
            .instances = self.instances.items.len,
            .sub_blocks = self.sub_blocks.items.len,
            .sections = if (self.sections) |s| s.items.len else 0,
            .mirrors = .{
                if (self.mirrors[0]) |m| m.items.len else 0,
                if (self.mirrors[1]) |m| m.items.len else 0,
            },
        };
    }
};

/// Expand one structural form into `scope`. `form_children` is the whole form
/// including its head atom.
///
/// `scope` is the enclosing scope's adapter — any value exposing
/// `emit(*Evaluator, Node, *Env) EvalError!void` (its own child-form
/// dispatcher) and `targets() Targets`. Passing it as `anytype` keeps the
/// three scope adapters concrete: no type erasure, no pointer casts, and a
/// body form is dispatched by exactly the grammar its scope defines.
pub fn evalForm(
    self: *Evaluator,
    kind: Kind,
    form_children: []const Node,
    env: *Env,
    scope: anytype,
) EvalError!void {
    const st = scope.state();
    const frame = try push(self, st, form_children);
    defer pop(st, frame);
    switch (kind) {
        .repeat_ => {
            const spec = try special_forms.parseRepeat(self, form_children[1..], env);
            var it = spec.iterator();
            while (it.next()) |index| {
                var loop_env = Env.init(self.allocator, env);
                defer loop_env.deinit();
                try loop_env.put(spec.name, .{ .number = @floatFromInt(index) });
                var buf: [24]u8 = undefined;
                try runBranch(self, spec.body, &loop_env, scope, ordinalSegment(&buf, index));
            }
        },
        .for_ => {
            const spec = try special_forms.parseFor(self, form_children[1..]);
            for (spec.items, 0..) |item, ordinal| {
                const value = try self.evalNode(item, env);
                var loop_env = Env.init(self.allocator, env);
                defer loop_env.deinit();
                try loop_env.put(spec.name, value);
                var buf: [24]u8 = undefined;
                try runBranch(self, spec.body, &loop_env, scope, ordinalSegment(&buf, @intCast(ordinal)));
            }
        },
        .when_, .unless_ => {
            try special_forms.checkAritySpan(self, if (kind == .when_) .when_ else .unless_, form_children[1..], form_children[0].span);
            const cond = try condition(self, kind, form_children[1], env);
            const run = if (kind == .when_) cond else !cond;
            if (!run) return;
            try runBranch(self, form_children[2..], env, scope, branch_taken);
        },
        .if_ => {
            const arms = try ifArms(self, form_children);
            const cond = try condition(self, kind, arms.cond, env);
            const body: [1]Node = .{if (cond) arms.then_arm else arms.else_arm};
            try runBranch(self, &body, env, scope, if (cond) branch_taken else branch_else);
        },
    }
}

/// The key segment a taken `when`/`unless` body, or an `if`'s then-arm,
/// contributes; and the one an `if`'s else-arm contributes. Distinct so a
/// condition flip re-derives rather than re-uses the other arm's ids.
const branch_taken = "@t";
const branch_else = "@f";

/// The key segment one loop iteration contributes: `@<index>`, matching the
/// key an unrolled `(ids ("REF@2" hex8) …)` sidecar entry uses.
fn ordinalSegment(buf: []u8, index: i64) []const u8 {
    return std.fmt.bufPrint(buf, "@{d}", .{index}) catch "@0";
}

/// `(if cond then else)` as a design-scope statement: exactly one form per
/// branch, with the `(id …)`/`(ids …)` markers the build writes onto the form
/// filtered out first (they would otherwise read as a fourth argument).
const IfArms = struct { cond: Node, then_arm: Node, else_arm: Node };

fn ifArms(self: *Evaluator, form_children: []const Node) EvalError!IfArms {
    var kept: [4]Node = undefined;
    var n: usize = 0;
    for (form_children[1..]) |arg| {
        if (arg.isForm("id") or arg.isForm("ids")) continue;
        if (n < kept.len) kept[n] = arg;
        n += 1;
    }
    if (n != 3) {
        self.setErrorFmt(
            form_children[0].span,
            "(if …) in design scope takes exactly one form per branch, got {d} — use (when …)/(unless …) for multi-form branches",
            .{n},
        );
        return EvalError.ArityError;
    }
    return .{ .cond = kept[0], .then_arm = kept[1], .else_arm = kept[2] };
}

/// Evaluate a structural form's condition. Design scope is deliberately
/// stricter than expression-position truthiness: a number or a string here is
/// almost always a mis-typed comparison, and silently taking a branch would
/// drop or add real parts.
fn condition(self: *Evaluator, kind: Kind, node: Node, env: *Env) EvalError!bool {
    const value = try self.evalNode(node, env);
    return value.asBool() orelse {
        const name = kind.sourceName();
        self.setErrorFmt(
            node.span,
            "({s} …) condition must be a boolean, e.g. ({s} (== variant \"A\") …)",
            .{ name, name },
        );
        return EvalError.TypeError;
    };
}

/// Run a body with `segment` appended to the structural key path, then
/// restore the path. Each direct body form is materialized through the
/// enclosing scope's own dispatcher and its children stamped — except a
/// nested structural form, which stamped its own with a longer path.
fn runBranch(
    self: *Evaluator,
    body: []const Node,
    env: *Env,
    scope: anytype,
    segment: []const u8,
) EvalError!void {
    const st = scope.state();
    const outer_path = st.path;
    st.path = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ outer_path, segment }) catch
        return EvalError.OutOfMemory;
    defer st.path = outer_path;

    // Body forms share one source location across every execution: drop their
    // own pending id writes and keep only the anchor's, queued before entry.
    const pending_id_len = self.pending_ids.items.len;
    const pending_child_id_len = self.pending_child_ids.items.len;
    defer {
        self.pending_ids.items.len = pending_id_len;
        self.pending_child_ids.items.len = pending_child_id_len;
    }

    const targets = scope.targets();
    for (body) |form| {
        const mark = targets.mark();
        try scope.emit(self, form, env);
        if (isStructuralNode(form)) continue;
        try stamp(self, st, targets, mark);
    }
}

/// Open a structural form: the outermost one mints (or reads) the anchor every
/// descendant derives from; inner ones inherit it.
fn push(self: *Evaluator, st: *State, form_children: []const Node) EvalError!Frame {
    const frame = Frame{ .depth = st.depth, .path = st.path, .root = st.root };
    if (st.depth == 0) {
        st.root = .{
            .id = try ids.getOrCreateFormId(self, form_children),
            .sidecar = ids.parseChildIdSidecar(self, form_children),
        };
    }
    st.depth += 1;
    return frame;
}

fn pop(st: *State, frame: Frame) void {
    st.depth = frame.depth;
    st.path = frame.path;
    st.root = frame.root;
}

/// Stamp every child emitted past `mark` with an identity derived from the
/// root anchor, the child's own stable origin key, and the current key path.
fn stamp(self: *Evaluator, st: *const State, targets: Targets, mark: Mark) EvalError!void {
    const root = st.root orelse return;
    const new_instances = targets.instances.items[mark.instances..];
    for (new_instances) |*inst| {
        const origin = if (inst.origin_key.len > 0) inst.origin_key else inst.ref_des;
        inst.id = try childId(self, st, root, origin);
    }
    for (targets.sub_blocks.items[mark.sub_blocks..]) |*sb| {
        const subblock_uuid = try childId(self, st, root, sb.name);
        try ids.reassignSubBlockIdsV4(self, sb.block, subblock_uuid);
    }
    if (targets.sections) |sections| syncSectionIds(sections.items[mark.sections..], new_instances);
    for (targets.mirrors, mark.mirrors) |maybe_list, from| {
        const list = maybe_list orelse continue;
        syncInstanceIds(list.items[from..], new_instances);
    }
}

/// One child's derived id: the enumerated `(ids …)` sidecar wins (that is how
/// a hand-unrolled block migrates without changing its PCB uuids), otherwise
/// the id is derived from the anchor and the composed key.
fn childId(self: *Evaluator, st: *const State, root: Anchor, origin_key: []const u8) EvalError![]const u8 {
    const key = std.fmt.allocPrint(self.allocator, "{s}{s}", .{ origin_key, st.path }) catch
        return EvalError.OutOfMemory;
    if (root.sidecar.map.get(key)) |migration_id| return migration_id;
    return ids.deriveChildId(self, root.id, key, 0);
}

/// Sections hold value copies of their member instances. Mirror the freshly
/// derived ids into those copies so every renderer/export path observes the
/// same identity as the block-wide instance slice.
fn syncSectionIds(sections: []Section, instances: []const Instance) void {
    for (sections) |*section| {
        syncInstanceIds(@constCast(section.instances), instances);
        syncSectionIds(@constCast(section.sub_sections), instances);
    }
}

fn syncInstanceIds(copies: []Instance, instances: []const Instance) void {
    for (copies) |*copy| {
        for (instances) |inst| {
            if (std.mem.eql(u8, copy.ref_des, inst.ref_des)) {
                copy.id = inst.id;
                break;
            }
        }
    }
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;
const sexpr_parser = @import("../sexpr/parser.zig");
const DesignBlock = env_mod.DesignBlock;

/// Evaluate one design source with a stub capacitor family registered, and
/// return the resulting block. Mirrors the loop fixture in `design_block.zig`
/// so the control-flow tests read the same way.
fn evalFixture(alloc: std.mem.Allocator, eval: *Evaluator, source: []const u8) !*DesignBlock {
    eval.* = Evaluator.init(alloc, ".");
    try eval.component_cache.put(alloc, "cap-0402", .{
        .name = "cap-0402",
        .symbol_name = "",
        .footprint_name = "",
        .is_family = true,
        .param_type = "",
    });
    var env = Env.init(alloc, null);
    defer env.deinit();
    const nodes = try sexpr_parser.parse(alloc, source);
    return switch (try eval.evalNodes(nodes, &env)) {
        .design_block => |block| block,
        else => error.TestUnexpectedResult,
    };
}

/// The same, keeping whatever error `evalNodes` returned so a test can assert
/// on a rejected condition or an out-of-scope body form.
fn evalFixtureResult(alloc: std.mem.Allocator, eval: *Evaluator, source: []const u8) !EvalError!env_mod.Value {
    eval.* = Evaluator.init(alloc, ".");
    try eval.component_cache.put(alloc, "cap-0402", .{
        .name = "cap-0402",
        .symbol_name = "",
        .footprint_name = "",
        .is_family = true,
        .param_type = "",
    });
    var env = Env.init(alloc, null);
    defer env.deinit();
    const nodes = try sexpr_parser.parse(alloc, source);
    return eval.evalNodes(nodes, &env);
}

fn hasWarningContaining(eval: *const Evaluator, needle: []const u8) bool {
    for (eval.warnings.items) |w| {
        if (std.mem.indexOf(u8, w.message, needle) != null) return true;
    }
    return false;
}

/// Assert two evaluations of the same source produced the same identities.
fn expectSameIds(a: []const Instance, b: []const Instance) !void {
    try testing.expectEqual(a.len, b.len);
    for (a, b) |x, y| try testing.expectEqualStrings(x.id, y.id);
}

/// Assert a section's instance COPIES carry the block-wide derived ids.
fn expectMirroredIds(copies: []const Instance, instances: []const Instance) !void {
    try testing.expectEqual(copies.len, instances.len);
    for (copies, instances) |copy, inst| try testing.expectEqualStrings(inst.id, copy.id);
}

fn expectDistinctIds(instances: []const Instance) !void {
    for (instances, 0..) |a, i| {
        for (instances[i + 1 ..]) |b| try testing.expect(!std.mem.eql(u8, a.id, b.id));
    }
}

// spec: eval/scope_control - kindOf maps only the structural special forms and rejects the rest
test "kindOf recognises exactly the structural forms" {
    try testing.expectEqual(Kind.when_, kindOf(.when_).?);
    try testing.expectEqual(Kind.unless_, kindOf(.unless_).?);
    try testing.expectEqual(Kind.if_, kindOf(.if_).?);
    try testing.expectEqual(Kind.for_, kindOf(.for_).?);
    try testing.expectEqual(Kind.repeat_, kindOf(.repeat).?);
    try testing.expect(kindOf(.let) == null);
    try testing.expect(kindOf(.design_block) == null);
}

// spec: eval/scope_control - isStructuralNode is true for a control form and false for a scope form
test "isStructuralNode distinguishes control flow from scope forms" {
    const alloc = std.heap.page_allocator;
    const nodes = try sexpr_parser.parse(alloc, "((when c (instance \"R1\" res)) (instance \"R2\" res) (let x 1) atom)");
    const items = nodes[0].asList().?;
    try testing.expect(isStructuralNode(items[0]));
    try testing.expect(!isStructuralNode(items[1]));
    try testing.expect(!isStructuralNode(items[2]));
    try testing.expect(!isStructuralNode(items[3]));
}

// spec: eval/scope_control - the then and else branch key segments differ so a condition flip cannot alias children
test "branch key segments are distinct" {
    try testing.expect(!std.mem.eql(u8, branch_taken, branch_else));
}

// spec: eval/scope_control - when materializes its design-block-scope body only when the condition holds
test "when at design-block scope emits the body only when true" {
    const alloc = std.heap.page_allocator;
    const on =
        \\(design-block "Variant"
        \\  (hierarchical-ids)
        \\  (let fitted (== 1 1))
        \\  (when fitted
        \\    (instance "C_OPT" (cap-0402 "100nF") (pin 1 "VIN") (pin 2 "GND"))
        \\    (id abcd1234)))
    ;
    var eval_on: Evaluator = undefined;
    const block_on = try evalFixture(alloc, &eval_on, on);
    defer eval_on.deinit();
    try testing.expectEqual(@as(usize, 1), block_on.instances.len);
    try testing.expect(!hasWarningContaining(&eval_on, "unknown sub-form"));

    var eval_off: Evaluator = undefined;
    const block_off = try evalFixture(alloc, &eval_off, try std.mem.replaceOwned(u8, alloc, on, "(let fitted (== 1 1))", "(let fitted (== 1 2))"));
    defer eval_off.deinit();
    try testing.expectEqual(@as(usize, 0), block_off.instances.len);
}

// spec: eval/scope_control - unless is when's negation in design scope
test "unless at design-block scope emits the body only when false" {
    const alloc = std.heap.page_allocator;
    const source =
        \\(design-block "Variant"
        \\  (hierarchical-ids)
        \\  (unless (== 1 2)
        \\    (instance "C_OPT" (cap-0402 "100nF") (pin 1 "VIN") (pin 2 "GND"))
        \\    (id abcd1234)))
    ;
    var eval: Evaluator = undefined;
    const block = try evalFixture(alloc, &eval, source);
    defer eval.deinit();
    try testing.expectEqual(@as(usize, 1), block.instances.len);
    try testing.expectEqualStrings("C_OPT", block.instances[0].origin_key);
}

// spec: eval/scope_control - if at design-block scope selects one single-form branch instead of dropping both
test "if at design-block scope materializes the selected branch" {
    const alloc = std.heap.page_allocator;
    const source =
        \\(design-block "Variant"
        \\  (hierarchical-ids)
        \\  (if (== 1 1)
        \\    (instance "C_A" (cap-0402 "100nF") (pin 1 "VIN") (pin 2 "GND"))
        \\    (instance "C_B" (cap-0402 "1uF") (pin 1 "VIN") (pin 2 "GND"))
        \\    (id abcd1234)))
    ;
    var eval: Evaluator = undefined;
    const block = try evalFixture(alloc, &eval, source);
    defer eval.deinit();
    try testing.expectEqual(@as(usize, 1), block.instances.len);
    try testing.expectEqualStrings("C_A", block.instances[0].origin_key);
    try testing.expect(!hasWarningContaining(&eval, "unknown sub-form"));
}

// spec: eval/scope_control - an if's then-child and else-child never share an id, so flipping the condition re-derives
test "if branches derive distinct child identities" {
    const alloc = std.heap.page_allocator;
    const then_src =
        \\(design-block "Variant"
        \\  (hierarchical-ids)
        \\  (if (== 1 1)
        \\    (instance "C_OPT" (cap-0402 "100nF") (pin 1 "VIN") (pin 2 "GND"))
        \\    (instance "C_OPT" (cap-0402 "1uF") (pin 1 "VIN") (pin 2 "GND"))
        \\    (id abcd1234)))
    ;
    var eval_t: Evaluator = undefined;
    const block_t = try evalFixture(alloc, &eval_t, then_src);
    defer eval_t.deinit();
    var eval_f: Evaluator = undefined;
    const block_f = try evalFixture(alloc, &eval_f, try std.mem.replaceOwned(u8, alloc, then_src, "(if (== 1 1)", "(if (== 1 2)"));
    defer eval_f.deinit();

    try testing.expectEqual(@as(usize, 1), block_t.instances.len);
    try testing.expectEqual(@as(usize, 1), block_f.instances.len);
    // Same ref-des and same anchor — only the branch key differs, and that is
    // exactly what must keep the two identities apart.
    try testing.expectEqualStrings(block_t.instances[0].ref_des, block_f.instances[0].ref_des);
    try testing.expect(!std.mem.eql(u8, block_t.instances[0].id, block_f.instances[0].id));
}

// spec: eval/scope_control - conditional child identities are stable across rebuilds
test "when child ids reproduce across evaluations" {
    const alloc = std.heap.page_allocator;
    const source =
        \\(design-block "Variant"
        \\  (hierarchical-ids)
        \\  (when (> 3.3 1.8)
        \\    (instance "C_A" (cap-0402 "100nF") (pin 1 "VIN") (pin 2 "GND"))
        \\    (instance "C_B" (cap-0402 "1uF") (pin 1 "VIN") (pin 2 "GND"))
        \\    (id abcd1234)))
    ;
    var eval_a: Evaluator = undefined;
    const block_a = try evalFixture(alloc, &eval_a, source);
    defer eval_a.deinit();
    var eval_b: Evaluator = undefined;
    const block_b = try evalFixture(alloc, &eval_b, source);
    defer eval_b.deinit();

    try testing.expectEqual(@as(usize, 2), block_a.instances.len);
    try expectDistinctIds(block_a.instances);
    try expectSameIds(block_a.instances, block_b.instances);
    // Only the anchor is source-resident: no per-child id write-backs queued.
    try testing.expectEqual(@as(usize, 0), eval_a.pending_ids.items.len);
}

// spec: eval/scope_control - for inside a section emits into that section like a hand-written child
test "for inside a section hosts its instances in the section" {
    const alloc = std.heap.page_allocator;
    const source =
        \\(design-block "Filters"
        \\  (hierarchical-ids)
        \\  (section "Analog"
        \\    (for ch ("A" "B" "C")
        \\      (instance (fmt "C_F~a" ch) (cap-0402 "68pF")
        \\        (pin 1 (fmt "AIN~a" ch)) (pin 2 "GND"))
        \\      (id bcde2345))))
    ;
    var eval: Evaluator = undefined;
    const block = try evalFixture(alloc, &eval, source);
    defer eval.deinit();
    try testing.expectEqual(@as(usize, 3), block.instances.len);
    try testing.expectEqual(@as(usize, 1), block.sections.len);
    try testing.expectEqual(@as(usize, 3), block.sections[0].instances.len);
    try testing.expectEqual(env_mod.SectionStatus.implemented, block.sections[0].status);
    try testing.expect(!hasWarningContaining(&eval, "unknown sub-form"));
    // The section's instance copies carry the derived identities, not stale ones.
    try expectMirroredIds(block.sections[0].instances, block.instances);
    try expectDistinctIds(block.instances);
}

// spec: eval/scope_control - when inside a section and inside a nested sub-section materializes into that scope
test "when works in a section and in a nested sub-section" {
    const alloc = std.heap.page_allocator;
    const source =
        \\(design-block "Filters"
        \\  (hierarchical-ids)
        \\  (section "Analog"
        \\    (when (== "A" "A")
        \\      (instance "C_SEC" (cap-0402 "68pF") (pin 1 "VIN") (pin 2 "GND"))
        \\      (id bcde2345))
        \\    (section "Inner"
        \\      (unless (== "A" "B")
        \\        (instance "C_SUB" (cap-0402 "10nF") (pin 1 "VIN") (pin 2 "GND"))
        \\        (id cdef3456)))))
    ;
    var eval: Evaluator = undefined;
    const block = try evalFixture(alloc, &eval, source);
    defer eval.deinit();
    try testing.expectEqual(@as(usize, 2), block.instances.len);
    const analog = block.sections[0];
    // Both count toward the parent section; the nested one also lands in the
    // sub-section, exactly as a hand-written nested instance does.
    try testing.expectEqual(@as(usize, 2), analog.instances.len);
    try testing.expectEqual(@as(usize, 1), analog.sub_sections.len);
    try testing.expectEqual(@as(usize, 1), analog.sub_sections[0].instances.len);
    try testing.expectEqualStrings("C_SUB", analog.sub_sections[0].instances[0].origin_key);
    try expectDistinctIds(block.instances);
    try testing.expect(!hasWarningContaining(&eval, "unknown sub-form"));
}

// spec: eval/scope_control - a for nested inside a when inside a section composes and keeps every child identity distinct
test "for inside when inside a section composes identities" {
    const alloc = std.heap.page_allocator;
    const source =
        \\(design-block "Filters"
        \\  (hierarchical-ids)
        \\  (section "Analog"
        \\    (when (> 5 1)
        \\      (for ch ("A" "B" "C")
        \\        (instance (fmt "C_F~a" ch) (cap-0402 "68pF")
        \\          (pin 1 (fmt "AIN~a" ch)) (pin 2 "GND")))
        \\      (id bcde2345))))
    ;
    var eval_a: Evaluator = undefined;
    const block_a = try evalFixture(alloc, &eval_a, source);
    defer eval_a.deinit();
    var eval_b: Evaluator = undefined;
    const block_b = try evalFixture(alloc, &eval_b, source);
    defer eval_b.deinit();

    try testing.expectEqual(@as(usize, 3), block_a.instances.len);
    try testing.expectEqual(@as(usize, 3), block_a.sections[0].instances.len);
    try expectDistinctIds(block_a.instances);
    try expectSameIds(block_a.instances, block_b.instances);
    try expectMirroredIds(block_a.sections[0].instances, block_a.instances);
}

// spec: eval/scope_control - a non-boolean condition is an error naming the offending form
test "a non-boolean condition is rejected" {
    const alloc = std.heap.page_allocator;
    const source =
        \\(design-block "Variant"
        \\  (when "yes"
        \\    (instance "C_OPT" (cap-0402 "100nF") (pin 1 "VIN") (pin 2 "GND"))))
    ;
    var eval: Evaluator = undefined;
    try testing.expectError(EvalError.TypeError, try evalFixtureResult(alloc, &eval, source));
    defer eval.deinit();
    const diag = eval.last_error orelse return error.TestExpectedDiagnostic;
    try testing.expect(std.mem.indexOf(u8, diag.message, "(when …) condition must be a boolean") != null);
    try testing.expectEqual(@as(u32, 2), diag.span.line);
}

// spec: eval/scope_control - a form illegal in the enclosing scope is diagnosed at its own location inside a branch
test "an out-of-scope body form is reported at its own source location" {
    const alloc = std.heap.page_allocator;
    const source =
        \\(design-block "Filters"
        \\  (section "Analog"
        \\    (when (== 1 1)
        \\      (stackup (layers 4)))))
    ;
    var eval: Evaluator = undefined;
    _ = try evalFixture(alloc, &eval, source);
    defer eval.deinit();
    var found = false;
    for (eval.warnings.items) |w| {
        if (std.mem.indexOf(u8, w.message, "(stackup …) is top-level-only") == null) continue;
        found = true;
        // The branch body form's OWN line, not the (when …) head's.
        try testing.expectEqual(@as(u32, 4), w.span.line);
    }
    try testing.expect(found);
}

// spec: eval/scope_control - design-scope if rejects a multi-form branch by name instead of silently dropping it
test "design-scope if with more than three arms is an arity error" {
    const alloc = std.heap.page_allocator;
    const source =
        \\(design-block "Variant"
        \\  (if (== 1 1)
        \\    (instance "C_A" (cap-0402 "100nF") (pin 1 "VIN") (pin 2 "GND"))
        \\    (instance "C_B" (cap-0402 "1uF") (pin 1 "VIN") (pin 2 "GND"))
        \\    (instance "C_C" (cap-0402 "1uF") (pin 1 "VIN") (pin 2 "GND"))))
    ;
    var eval: Evaluator = undefined;
    try testing.expectError(EvalError.ArityError, try evalFixtureResult(alloc, &eval, source));
    defer eval.deinit();
    const diag = eval.last_error orelse return error.TestExpectedDiagnostic;
    try testing.expect(std.mem.indexOf(u8, diag.message, "one form per branch") != null);
}

// spec: eval/scope_control - expression-position when returns the last body value and unless its negation
test "expression when and unless return the body value or nil" {
    const alloc = std.heap.page_allocator;
    var eval = Evaluator.init(alloc, ".");
    defer eval.deinit();
    var env = Env.init(alloc, null);
    defer env.deinit();
    const nodes = try sexpr_parser.parse(alloc, "(when (== 1 1) 5 7) (when (== 1 2) 5) (unless (== 1 2) 9)");
    const first = try eval.evalNode(nodes[0], &env);
    try testing.expectEqual(@as(f64, 7), first.asNumber().?);
    const second = try eval.evalNode(nodes[1], &env);
    try testing.expect(second == .nil);
    const third = try eval.evalNode(nodes[2], &env);
    try testing.expectEqual(@as(f64, 9), third.asNumber().?);
}
