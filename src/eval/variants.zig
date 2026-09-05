//! Assembly variants: one PCB, one netlist, one set of footprints — several
//! build configurations differing only in which parts are populated and what
//! value a populated part carries.
//!
//! A design declares its variant space with repeatable design-block-scope
//! `(variant "NAME" ["doc"] [(default)])` forms, and each instance opts into
//! it with `(only-in …)`, `(dnp-in …)` and `(value-in …)`. Selecting one
//! (`--variant NAME`, `?variant=NAME`, a tool's `variant` argument) is what
//! turns those clauses into the `dnp` flag and the `value` every downstream
//! surface already reads, so ERC exemptions, the BOM badge, the KiCad
//! `dnp`/`exclude_from_bom` attributes, the schematic strike-through and the
//! layout need no variant awareness of their own.
//!
//! **Why the variant space is design-level.** A module is a circuit, not an
//! assembly: the same regulator module is embedded in boards whose variant
//! names have nothing in common, so a module that declared its own variants
//! would either collide with its host's or need a mapping layer nobody wants
//! to author. Instead an instance inside a `(sub-block …)` names the ROOT
//! design's variants directly, and a name the root never declared is an error
//! that points at the module's own line.
//!
//! **What is deliberately NOT expressible.** Nothing structural — no
//! per-variant net, footprint, or instance that exists in one variant and not
//! another as a *different part*. `(only-in …)` leaves the footprint and its
//! pads on the board in every variant; it only stops the pick-and-place. A
//! difference that changes copper is a different board, and a variant system
//! that blurs that line is how the wrong stackup gets fabricated.

const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const env_mod = @import("env.zig");
const evaluator_mod = @import("evaluator.zig");
const suggest = @import("suggest.zig");
const value_kind = @import("value_kind.zig");

const Node = ast.Node;
const Env = env_mod.Env;
const Evaluator = evaluator_mod.Evaluator;
const EvalError = evaluator_mod.EvalError;
const VariantDecl = env_mod.VariantDecl;
const VariantRule = env_mod.VariantRule;
const VariantScope = env_mod.VariantScope;

/// Head atom of the declaration form.
pub const decl_form = "variant";

/// The three instance body sub-forms this module owns. `instance.zig`
/// dispatches on them; `forms.zig` documents them.
pub const only_in_form = "only-in";
pub const dnp_in_form = "dnp-in";
pub const value_in_form = "value-in";

/// A variant name longer than this cannot be a typo of anything (the
/// did-you-mean scan is capped at the same length), and is refused so the
/// diagnostic path has a bounded input.
pub const max_name_len: usize = suggest.max_name_len;

// ── Declaration ────────────────────────────────────────────────────────

/// True when `node` is a `(variant …)` declaration form.
pub fn isDeclaration(node: Node) bool {
    return node.isForm(decl_form);
}

/// Collect the `(variant …)` declarations among `body_forms` and resolve which
/// one this evaluation selected, producing the scope `materializeBlock`
/// installs for the whole root materialization.
///
/// Declarations are read LITERALLY (like `(revision "A")` and `(id …)`): the
/// name is a quoted string, never an expression. A variant name is an identity
/// the CLI, the URL and the BOM all spell out, so it must be readable straight
/// off the source without evaluating anything.
///
/// `span` is the fallback location for a diagnostic that has no form of its
/// own — an unselectable `--variant` name.
pub fn install(
    self: *Evaluator,
    body_forms: []const Node,
    span: ast.Span,
) EvalError!VariantScope {
    var decls: std.ArrayList(VariantDecl) = .empty;
    var default_at: ?ast.Span = null;
    for (body_forms) |form| {
        if (!isDeclaration(form)) continue;
        const children = form.asList() orelse continue;
        const decl = try parseDecl(self, children, decls.items);
        if (decl.is_default) {
            if (default_at) |first| {
                self.setErrorFmt(
                    children[0].span,
                    "a design declares at most one (default) variant — \"{s}\" is the second (the first is at line {d})",
                    .{ decl.name, first.line },
                );
                return EvalError.InvalidForm;
            }
            default_at = children[0].span;
        }
        decls.append(self.allocator, decl) catch return EvalError.OutOfMemory;
    }

    var scope = VariantScope{
        .decls = decls.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
    };
    scope.active = try selectActive(self, scope, span);
    return scope;
}

/// Parse one `(variant "NAME" ["doc"] [(default)])` form.
fn parseDecl(
    self: *Evaluator,
    children: []const Node,
    already: []const VariantDecl,
) EvalError!VariantDecl {
    if (children.len < 2) {
        self.setError(children[0].span, "(variant …) needs a name, e.g. (variant \"Lite\" \"no radio\" (default))");
        return EvalError.ArityError;
    }
    const name = children[1].asString() orelse {
        self.setError(children[1].span, "(variant …) name must be a quoted string, e.g. (variant \"Lite\")");
        return EvalError.TypeError;
    };
    if (name.len == 0 or name.len > max_name_len) {
        self.setErrorFmt(
            children[1].span,
            "(variant …) name must be 1–{d} characters",
            .{max_name_len},
        );
        return EvalError.InvalidForm;
    }
    for (already) |prior| {
        if (std.mem.eql(u8, prior.name, name)) {
            self.setErrorFmt(children[1].span, "variant \"{s}\" is declared twice", .{name});
            return EvalError.InvalidForm;
        }
    }

    var decl = VariantDecl{ .name = name };
    for (children[2..]) |child| {
        if (child.asString()) |doc| {
            decl.doc = doc;
            continue;
        }
        if (child.isForm("default")) {
            decl.is_default = true;
            continue;
        }
        self.setErrorFmt(
            child.span,
            "(variant \"{s}\" …) accepts a doc string and (default); got something else",
            .{name},
        );
        return EvalError.InvalidForm;
    }
    return decl;
}

/// Resolve the selected variant: the caller's `--variant` when given, else the
/// `(default)` declaration, else the base variant.
fn selectActive(self: *Evaluator, scope: VariantScope, span: ast.Span) EvalError!?usize {
    const requested = self.variants.requested orelse return scope.defaultIndex();
    if (requested.len == 0) return scope.defaultIndex();
    if (scope.find(requested)) |i| return i;
    if (scope.decls.len == 0) {
        self.setErrorFmt(
            span,
            "--variant \"{s}\": this design declares no variants — add (variant \"{s}\") at design-block scope",
            .{ requested, requested },
        );
        return EvalError.InvalidForm;
    }
    self.setError(span, try unknownMessage(self, requested, scope, "--variant"));
    return EvalError.InvalidForm;
}

// ── Instance sub-forms ─────────────────────────────────────────────────

/// The source spelling of a rule's head atom, so a diagnostic quotes the form
/// the author wrote rather than the enum's Zig identifier.
pub fn formName(kind: env_mod.VariantRuleKind) []const u8 {
    return switch (kind) {
        .only_in => only_in_form,
        .dnp_in => dnp_in_form,
        .value_in => value_in_form,
    };
}

/// True when `form`'s head is one of the three instance-level variant clauses.
pub fn isInstanceForm(form: Node) bool {
    return form.isForm(only_in_form) or form.isForm(dnp_in_form) or form.isForm(value_in_form);
}

/// Parse one `(only-in …)` / `(dnp-in …)` / `(value-in …)` clause on an
/// instance and append the rules it declares.
///
/// Unlike the declaration, the arguments here ARE evaluated, so a `(let …)`
/// bound name or an `(fmt …)` works exactly as it does for a net name. Every
/// name is checked against the root design's declarations on the spot, which
/// is what makes the diagnostic point at the offending line — inside a module
/// body, at the module's own file and line.
///
/// `family` is the instance's component family, used to apply the family's
/// declared value-kind to a `(value-in …)` override exactly as it applies to
/// the authored value.
pub fn parseInstanceForm(
    self: *Evaluator,
    form: Node,
    ref_des: []const u8,
    family: []const u8,
    env: *Env,
    rules: *std.ArrayList(VariantRule),
) EvalError!void {
    const children = form.asList().?;
    const head = children[0].asAtom().?;
    if (std.mem.eql(u8, head, value_in_form))
        return parseValueIn(self, children, ref_des, family, env, rules);

    const kind: env_mod.VariantRuleKind = if (std.mem.eql(u8, head, only_in_form)) .only_in else .dnp_in;
    if (children.len < 2) {
        self.setErrorFmt(
            children[0].span,
            "({s} …) on \"{s}\" needs at least one variant name, e.g. ({s} \"Lite\")",
            .{ head, ref_des, head },
        );
        return EvalError.ArityError;
    }
    for (children[1..]) |arg| {
        const name = try evalVariantName(self, arg, ref_des, head, env);
        rules.append(self.allocator, .{ .kind = kind, .variant = name }) catch
            return EvalError.OutOfMemory;
    }
}

/// Parse `(value-in "VARIANT" "VALUE")`.
fn parseValueIn(
    self: *Evaluator,
    children: []const Node,
    ref_des: []const u8,
    family: []const u8,
    env: *Env,
    rules: *std.ArrayList(VariantRule),
) EvalError!void {
    if (children.len != 3) {
        self.setErrorFmt(
            children[0].span,
            "(value-in …) on \"{s}\" takes a variant and a value, e.g. (value-in \"Lite\" \"4.7k\")",
            .{ref_des},
        );
        return EvalError.ArityError;
    }
    const name = try evalVariantName(self, children[1], ref_des, value_in_form, env);
    const value_val = try self.evalNode(children[2], env);
    const value = value_val.asString() orelse {
        self.setErrorFmt(
            children[2].span,
            "(value-in \"{s}\" …) on \"{s}\" needs a quoted value, e.g. (value-in \"{s}\" \"4.7k\")",
            .{ name, ref_des, name },
        );
        return EvalError.TypeError;
    };
    // The override is a value like any other, so the family's declared
    // value-kind applies to it too: a variant is not a way past the check that
    // stops `(cap-0402 "4.7k")`.
    if (self.component_cache.get(family)) |comp| {
        if (!value_kind.accepts(comp.param_type, value)) {
            self.setError(
                children[2].span,
                value_kind.mismatchMessage(self.allocator, family, comp.param_type, value),
            );
            return EvalError.TypeError;
        }
    }
    for (rules.items) |prior| {
        if (prior.kind == .value_in and std.mem.eql(u8, prior.variant, name)) {
            self.setErrorFmt(
                children[1].span,
                "(value-in \"{s}\" …) is declared twice on \"{s}\"",
                .{ name, ref_des },
            );
            return EvalError.InvalidForm;
        }
    }
    rules.append(self.allocator, .{ .kind = .value_in, .variant = name, .value = value }) catch
        return EvalError.OutOfMemory;
}

/// Evaluate one variant-name argument and check it against the root design's
/// declarations.
fn evalVariantName(
    self: *Evaluator,
    node: Node,
    ref_des: []const u8,
    head: []const u8,
    env: *Env,
) EvalError![]const u8 {
    const val = try self.evalNode(node, env);
    const name = val.asString() orelse {
        self.setErrorFmt(
            node.span,
            "({s} …) on \"{s}\" takes quoted variant names, e.g. ({s} \"Lite\")",
            .{ head, ref_des, head },
        );
        return EvalError.TypeError;
    };
    if (self.variants.scope.find(name) != null) return name;
    if (self.variants.scope.decls.len == 0) {
        self.setErrorFmt(
            node.span,
            "({s} \"{s}\") on \"{s}\": this design declares no variants — add (variant \"{s}\") at design-block scope",
            .{ head, name, ref_des, name },
        );
        return EvalError.InvalidForm;
    }
    const context = std.fmt.allocPrint(self.allocator, "({s} …) on \"{s}\"", .{ head, ref_des }) catch
        return EvalError.OutOfMemory;
    self.setError(node.span, try unknownMessage(self, name, self.variants.scope, context));
    return EvalError.InvalidForm;
}

/// `unknown variant "X" in <context> — did you mean "Y"?`, falling back to the
/// full list of declared names when nothing is close enough to suggest.
fn unknownMessage(
    self: *Evaluator,
    name: []const u8,
    scope: VariantScope,
    context: []const u8,
) EvalError![]const u8 {
    var names = self.allocator.alloc([]const u8, scope.decls.len) catch return EvalError.OutOfMemory;
    for (scope.decls, 0..) |d, i| names[i] = d.name;
    if (suggest.nearestOf(name, names, .advisory)) |candidate| {
        return std.fmt.allocPrint(
            self.allocator,
            "unknown variant \"{s}\" in {s} — did you mean \"{s}\"?",
            .{ name, context, candidate },
        ) catch EvalError.OutOfMemory;
    }
    var list: std.Io.Writer.Allocating = .init(self.allocator);
    const w = &list.writer;
    w.print("unknown variant \"{s}\" in {s}; this design declares ", .{ name, context }) catch
        return EvalError.OutOfMemory;
    for (names, 0..) |n, i| {
        if (i > 0) w.writeAll(", ") catch return EvalError.OutOfMemory;
        w.print("\"{s}\"", .{n}) catch return EvalError.OutOfMemory;
    }
    return list.written();
}

/// Reject the two clause combinations that have no coherent reading, and
/// return the rules unchanged when they are consistent.
///
///   * `(dnp)` is unconditional; pairing it with `(only-in …)`/`(dnp-in …)`
///     asks for two different population answers at once.
///   * one variant named by both `(only-in …)` and `(dnp-in …)` says the part
///     is populated only there AND not populated there.
pub fn validateInstance(
    self: *Evaluator,
    span: ast.Span,
    ref_des: []const u8,
    has_dnp: bool,
    rules: []const VariantRule,
) EvalError!void {
    for (rules) |rule| {
        if (rule.kind == .value_in) continue;
        if (has_dnp) {
            self.setErrorFmt(
                span,
                "\"{s}\" combines (dnp) with ({s} \"{s}\") — (dnp) is unconditional; drop it and let the variant clauses decide",
                .{ ref_des, formName(rule.kind), rule.variant },
            );
            return EvalError.InvalidForm;
        }
        if (rule.kind != .only_in) continue;
        for (rules) |other| {
            if (other.kind != .dnp_in or !std.mem.eql(u8, other.variant, rule.variant)) continue;
            self.setErrorFmt(
                span,
                "\"{s}\" is both (only-in \"{s}\") and (dnp-in \"{s}\") — a variant cannot populate and depopulate the same part",
                .{ ref_des, rule.variant, rule.variant },
            );
            return EvalError.InvalidForm;
        }
    }
}

// ── Selection ──────────────────────────────────────────────────────────

/// What the selected variant makes of one instance's clauses.
pub const Applied = struct {
    /// True when the selected variant leaves this part unpopulated.
    dnp: bool = false,
    /// The selected variant's value override, or null to keep the authored one.
    value: ?[]const u8 = null,
};

/// Resolve `rules` against the selected variant. The base variant (nothing
/// selected) populates everything except the parts an `(only-in …)` reserves
/// for a named variant, and overrides nothing.
pub fn apply(scope: VariantScope, rules: []const VariantRule) Applied {
    return applyFor(scope.activeName(), rules);
}

/// The single reading of a rule set, against one variant name ("" = base).
/// Every per-variant answer — the selected variant's effect, the population
/// matrix, the per-variant value — comes through here, so the three can never
/// disagree about what a clause means.
pub fn applyFor(variant: []const u8, rules: []const VariantRule) Applied {
    var out: Applied = .{};
    var only_in_seen = false;
    var only_in_matched = false;
    for (rules) |rule| switch (rule.kind) {
        .only_in => {
            only_in_seen = true;
            if (std.mem.eql(u8, rule.variant, variant)) only_in_matched = true;
        },
        .dnp_in => {
            if (std.mem.eql(u8, rule.variant, variant)) out.dnp = true;
        },
        .value_in => {
            if (std.mem.eql(u8, rule.variant, variant)) out.value = rule.value;
        },
    };
    if (only_in_seen and !only_in_matched) out.dnp = true;
    return out;
}

/// True when any clause decides POPULATION rather than value. Because `(dnp)`
/// may not be combined with a population clause, this is also what separates a
/// resolved `dnp` the selected variant produced from an unconditional one.
pub fn hasPopulationRule(rules: []const VariantRule) bool {
    for (rules) |rule| {
        if (rule.kind != .value_in) return true;
    }
    return false;
}

/// The unconditional `(dnp)` behind an instance's already-resolved `dnp` flag:
/// true only when no clause could have set it. A part that is DNP everywhere is
/// populated in no variant, which is what the population matrix must report.
pub fn unconditionalDnp(dnp: bool, rules: []const VariantRule) bool {
    return dnp and !hasPopulationRule(rules);
}

/// True when two parts carry the same variant clauses in the same order, so a
/// BOM may roll them onto one line: they are populated in the same variants and
/// carry the same value in each, which is exactly what a purchase order asks.
pub fn rulesEqual(a: []const VariantRule, b: []const VariantRule) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.kind != y.kind) return false;
        if (!std.mem.eql(u8, x.variant, y.variant)) return false;
        if (!std.mem.eql(u8, x.value, y.value)) return false;
    }
    return true;
}

/// Whether a part with these clauses is populated in `variant` ("" = base).
/// `base_dnp` is the unconditional `(dnp)` flag, which depopulates everywhere.
pub fn populatedIn(rules: []const VariantRule, base_dnp: bool, variant: []const u8) bool {
    if (base_dnp) return false;
    return !applyFor(variant, rules).dnp;
}

/// The value a part carries in `variant` ("" = base), given its base value.
pub fn valueIn(rules: []const VariantRule, base_value: []const u8, variant: []const u8) []const u8 {
    return applyFor(variant, rules).value orelse base_value;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: eval/variants - The base variant populates everything except parts reserved by only-in
test "base variant depopulates only-in parts and leaves the rest alone" {
    const rules = [_]VariantRule{.{ .kind = .only_in, .variant = "Pro" }};
    const base = apply(.{}, &rules);
    try testing.expect(base.dnp);
    try testing.expect(base.value == null);

    const none = apply(.{}, &.{});
    try testing.expect(!none.dnp);
}

// spec: eval/variants - The selected variant drives population and the value override
test "selected variant applies only-in, dnp-in and value-in" {
    const decls = [_]VariantDecl{ .{ .name = "Lite" }, .{ .name = "Pro" } };
    const rules = [_]VariantRule{
        .{ .kind = .only_in, .variant = "Pro" },
        .{ .kind = .value_in, .variant = "Pro", .value = "4.7k" },
    };
    const pro = apply(.{ .decls = &decls, .active = 1 }, &rules);
    try testing.expect(!pro.dnp);
    try testing.expectEqualStrings("4.7k", pro.value.?);

    const lite = apply(.{ .decls = &decls, .active = 0 }, &rules);
    try testing.expect(lite.dnp);
    try testing.expect(lite.value == null);

    const dnp_rules = [_]VariantRule{.{ .kind = .dnp_in, .variant = "Lite" }};
    try testing.expect(apply(.{ .decls = &decls, .active = 0 }, &dnp_rules).dnp);
    try testing.expect(!apply(.{ .decls = &decls, .active = 1 }, &dnp_rules).dnp);
}

// spec: eval/variants - populatedIn reports the population matrix without re-evaluating the design
test "populatedIn answers per variant and obeys an unconditional dnp" {
    const rules = [_]VariantRule{
        .{ .kind = .only_in, .variant = "Pro" },
        .{ .kind = .dnp_in, .variant = "Pro" },
    };
    // Contradictory input is rejected by validateInstance; the reporter still
    // has to answer, and dnp-in wins so nothing is reported as populated.
    try testing.expect(!populatedIn(&rules, false, "Pro"));
    try testing.expect(!populatedIn(&.{}, true, ""));
    try testing.expect(populatedIn(&.{}, false, "Lite"));
    try testing.expect(!populatedIn(&[_]VariantRule{.{ .kind = .only_in, .variant = "Pro" }}, false, ""));
}

// spec: eval/variants - An unconditional dnp is the one no population clause could have set
test "unconditionalDnp separates a variant's answer from a permanent do-not-populate" {
    const pop = [_]VariantRule{.{ .kind = .only_in, .variant = "Pro" }};
    const val = [_]VariantRule{.{ .kind = .value_in, .variant = "Pro", .value = "4.7k" }};
    try testing.expect(unconditionalDnp(true, &.{}));
    try testing.expect(!unconditionalDnp(false, &.{}));
    // Resolved DNP that a clause produced is not permanent.
    try testing.expect(!unconditionalDnp(true, &pop));
    // `(dnp)` may pair with a value override, and stays permanent when it does.
    try testing.expect(unconditionalDnp(true, &val));
    try testing.expect(hasPopulationRule(&pop));
    try testing.expect(!hasPopulationRule(&val));
}

// spec: eval/variants - Two parts roll onto one BOM line only when their variant clauses agree
test "rulesEqual separates parts whose population or per-variant value differs" {
    const a = [_]VariantRule{.{ .kind = .only_in, .variant = "Pro" }};
    const b = [_]VariantRule{.{ .kind = .dnp_in, .variant = "Pro" }};
    const c = [_]VariantRule{.{ .kind = .only_in, .variant = "Lite" }};
    const d = [_]VariantRule{.{ .kind = .value_in, .variant = "Pro", .value = "4.7k" }};
    const e = [_]VariantRule{.{ .kind = .value_in, .variant = "Pro", .value = "10k" }};
    try testing.expect(rulesEqual(&a, &a));
    try testing.expect(rulesEqual(&.{}, &.{}));
    try testing.expect(!rulesEqual(&a, &b));
    try testing.expect(!rulesEqual(&a, &c));
    try testing.expect(!rulesEqual(&a, &.{}));
    try testing.expect(!rulesEqual(&d, &e));
}

// spec: eval/variants - valueIn reports the per-variant value without re-evaluating the design
test "valueIn returns the override for its variant and the base value elsewhere" {
    const rules = [_]VariantRule{.{ .kind = .value_in, .variant = "Pro", .value = "4.7k" }};
    try testing.expectEqualStrings("4.7k", valueIn(&rules, "10k", "Pro"));
    try testing.expectEqualStrings("10k", valueIn(&rules, "10k", "Lite"));
    try testing.expectEqualStrings("10k", valueIn(&rules, "10k", ""));
}

// spec: eval/variants - A variant scope reports its active name and finds declarations by name
test "variant scope lookup and active name" {
    const decls = [_]VariantDecl{ .{ .name = "Lite" }, .{ .name = "Pro", .is_default = true } };
    const scope = VariantScope{ .decls = &decls, .active = null };
    try testing.expectEqualStrings("", scope.activeName());
    try testing.expectEqual(@as(?usize, 1), scope.defaultIndex());
    try testing.expectEqual(@as(?usize, 0), scope.find("Lite"));
    try testing.expect(scope.find("Nope") == null);
    try testing.expectEqualStrings("Pro", (VariantScope{ .decls = &decls, .active = 1 }).activeName());
}
