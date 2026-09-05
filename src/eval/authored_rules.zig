//! Parsing for **design-owned rules** — the `(requirement … (on "REF") (check
//! …))` and `(net-rule … (nets …) predicate…)` forms a design-block, a
//! `(section …)`, a nested sub-section or a `(defmodule …)` body may author
//! about itself.
//!
//! Library requirements answer "does every design placing this part follow the
//! datasheet"; these answer "does THIS board hold to the rule its author wrote
//! down". Both end up in one requirement-result pipeline
//! (`req_design_rules.zig` evaluates these; `preflight.zig` gates both), so
//! only the parse belongs here — deliberately a sibling of
//! `design_block.zig` rather than more lines inside it.
//!
//! Text, the `(on …)` target and every net glob are EVALUATED (not read as
//! literals) so a rule inside a module can name what its caller passed in:
//! `(net-rule (fmt "~S must stay bounded" rail) (nets rail) (declared-envelope))`.

const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const env_mod = @import("env.zig");
const check_grammar = @import("check_grammar.zig");
const numeric = @import("../numeric.zig");

const Node = ast.Node;
const Env = env_mod.Env;
const DesignRule = env_mod.DesignRule;
const NetPredicate = env_mod.NetPredicate;
const Evaluator = @import("evaluator.zig").Evaluator;
const EvalError = @import("evaluator.zig").EvalError;

/// Head atom of the instance-targeting sub-form on a design `(requirement …)`.
const on_form = "on";
/// Head atom of the net-selector sub-form on a `(net-rule …)`.
const nets_form = "nets";

/// One documented `(net-rule …)` predicate: the source template, what it
/// asserts, and the parser that turns its body into a `NetPredicate`. The
/// dispatch, the accepted-keyword list and the generated reference all read
/// this one table, exactly as `check_grammar.check_docs` does for `(check …)`.
pub const PredicateDoc = struct {
    /// Source-form template, e.g. `(min-bulk-uf F)`. Its leading keyword is
    /// the string `parsePredicate` dispatches on (a test asserts this).
    syntax: []const u8,
    /// What the predicate asserts about one matched net.
    summary: []const u8,
    /// Parse the `(<keyword> …)` body, or null on an arity/range mismatch.
    parse: *const fn ([]const Node) ?NetPredicate,
};

fn parseMinBulk(body: []const Node) ?NetPredicate {
    if (body.len < 2) return null;
    const uf = body[1].asNumber() orelse return null;
    if (!std.math.isFinite(uf) or uf <= 0) return null;
    return .{ .min_bulk_uf = uf };
}

fn parseDeclaredEnvelope(body: []const Node) ?NetPredicate {
    // A zero-argument marker: extra children are a typo, not a parameter.
    if (body.len != 1) return null;
    return .declared_envelope;
}

fn parseInNetClass(body: []const Node) ?NetPredicate {
    if (body.len != 1) return null;
    return .in_net_class;
}

fn parseMaxFanout(body: []const Node) ?NetPredicate {
    if (body.len < 2) return null;
    const n = body[1].asNumber() orelse return null;
    // Reject NaN / negative / non-representable before narrowing: a bare
    // @intFromFloat is UB in the safety-off production build.
    const count = numeric.checkedInt(u32, n) orelse return null;
    if (count == 0) return null;
    return .{ .max_fanout = count };
}

/// Doc + parse-dispatch table, indexed by the `NetPredicate` tag so a variant
/// with no row is a compile error.
pub const predicate_docs = blk: {
    const Tag = std.meta.Tag(NetPredicate);
    const N = @typeInfo(Tag).@"enum".field_names.len;
    var t: [N]?PredicateDoc = @splat(null);
    t[@backingInt(Tag.min_bulk_uf)] = .{
        .syntax = "(min-bulk-uf F)",
        .summary = "Capacitance summed over every capacitor bridging this net and a ground net " ++
            "must be ≥ F µF. A capacitor whose value cannot be parsed contributes nothing.",
        .parse = parseMinBulk,
    };
    t[@backingInt(Tag.declared_envelope)] = .{
        .syntax = "(declared-envelope)",
        .summary = "This net must carry a DC voltage envelope — authored with (net-envelope …) " ++
            "or derived by the evaluator from the rails and ports around it.",
        .parse = parseDeclaredEnvelope,
    };
    t[@backingInt(Tag.in_net_class)] = .{
        .syntax = "(in-net-class)",
        .summary = "Some (net-class … (nets …)) must list this net, so the router has a width, " ++
            "clearance and priority for it rather than the board default.",
        .parse = parseInNetClass,
    };
    t[@backingInt(Tag.max_fanout)] = .{
        .syntax = "(max-fanout N)",
        .summary = "The net may land on at most N pins.",
        .parse = parseMaxFanout,
    };
    var out: [N]PredicateDoc = undefined;
    for (t, 0..) |entry, i| {
        out[i] = entry orelse @compileError("missing predicate_docs row for NetPredicate." ++
            @typeInfo(Tag).@"enum".field_names[i]);
    }
    break :blk out;
};

/// Comma-separated keyword list for every `(net-rule …)` predicate, derived
/// from `predicate_docs` so a rejection message can never name a stale set.
pub const predicate_keyword_list: []const u8 = blk: {
    var s: []const u8 = "";
    for (predicate_docs, 0..) |doc, i| {
        const end = std.mem.indexOfScalar(u8, doc.syntax, ' ') orelse doc.syntax.len - 1;
        s = s ++ (if (i > 0) ", " else "") ++ doc.syntax[1..end];
    }
    break :blk s;
};

/// Parse one `(<keyword> …)` predicate body. Null when the head atom is not a
/// documented predicate or its arguments do not fit.
pub fn parsePredicate(node: Node) ?NetPredicate {
    const body = node.asList() orelse return null;
    if (body.len < 1) return null;
    const head = body[0].asAtom() orelse return null;
    inline for (predicate_docs) |doc| {
        const end = comptime std.mem.indexOfScalar(u8, doc.syntax, ' ') orelse doc.syntax.len - 1;
        if (std.mem.eql(u8, head, doc.syntax[1..end])) return doc.parse(body);
    }
    return null;
}

/// Parse a design-scope `(requirement "text" (on "REF") (check …) [(ref …)]
/// [(id "…")])`. Returns null (after warning) when the form is missing its
/// text, its `(on …)` target or its `(check …)` — a design requirement with no
/// executable half would be indistinguishable from a `(note …)`, and silently
/// accepting one is how a rule stops being checked without anyone noticing.
pub fn parseRequirement(
    self: *Evaluator,
    children: []const Node,
    env: *Env,
    scope: []const u8,
) EvalError!?DesignRule {
    if (children.len < 2) {
        self.warnFmt(children[0].span, "(requirement …) needs rule text, e.g. (requirement \"VBUS stays below 5.5 V\" (on \"U1\") (check …))", .{});
        return null;
    }
    const text = (try evalText(self, children[1], env)) orelse {
        self.warnFmt(children[1].span, "(requirement …) rule text must be a string", .{});
        return null;
    };

    var target: []const u8 = "";
    var check: ?env_mod.Check = null;
    var ref: ?env_mod.NoteRef = null;
    var explicit_id: []const u8 = "";
    for (children[2..]) |extra| {
        if (env_mod.parseNoteRef(extra)) |parsed| {
            ref = parsed;
        } else if (check_grammar.parseCheck(self.allocator, extra)) |parsed| {
            check = parsed;
        } else if (extra.isForm("check")) {
            self.warnFmt(
                extra.span,
                "malformed or unknown requirement (check …); recognised checks: {s}",
                .{check_grammar.check_keyword_list},
            );
        } else if (extra.asList()) |sub| {
            if (sub.len < 2) continue;
            const head = sub[0].asAtom() orelse continue;
            if (std.mem.eql(u8, head, on_form)) {
                target = (try evalText(self, sub[1], env)) orelse "";
            } else if (std.mem.eql(u8, head, "id")) {
                explicit_id = sub[1].asText() orelse explicit_id;
            }
        }
    }

    if (target.len == 0) {
        self.warnFmt(children[0].span, "design (requirement \"{s}\" …) needs an (on \"REF\") naming the instance it judges — ignored", .{text});
        return null;
    }
    if (check == null) {
        self.warnFmt(children[0].span, "design (requirement \"{s}\" …) needs a (check …); prose-only rules belong in (note …) — ignored", .{text});
        return null;
    }
    return .{
        .text = text,
        .ref = ref,
        .id = try ruleId(self, explicit_id, text),
        .scope = scope,
        .body = .{ .on_instance = .{ .target = target, .check = check.? } },
    };
}

/// Parse `(net-rule "text" (nets GLOB…) predicate… [(id "…")])`. Returns null
/// (after warning) when the selector or every predicate is missing: a net rule
/// that asserts nothing would read as a pass forever.
pub fn parseNetRule(
    self: *Evaluator,
    children: []const Node,
    env: *Env,
    scope: []const u8,
) EvalError!?DesignRule {
    if (children.len < 2) {
        self.warnFmt(children[0].span, "(net-rule …) needs rule text, e.g. (net-rule \"every rail is bounded\" (nets \"V_*\") (declared-envelope))", .{});
        return null;
    }
    const text = (try evalText(self, children[1], env)) orelse {
        self.warnFmt(children[1].span, "(net-rule …) rule text must be a string", .{});
        return null;
    };

    var globs: std.ArrayList([]const u8) = .empty;
    var predicates: std.ArrayList(NetPredicate) = .empty;
    var explicit_id: []const u8 = "";
    for (children[2..]) |extra| {
        const sub = extra.asList() orelse continue;
        if (sub.len < 1) continue;
        const head = sub[0].asAtom() orelse continue;
        if (std.mem.eql(u8, head, nets_form)) {
            for (sub[1..]) |g| {
                const glob = (try evalText(self, g, env)) orelse continue;
                if (glob.len > 0) globs.append(self.allocator, glob) catch return EvalError.OutOfMemory;
            }
        } else if (std.mem.eql(u8, head, "id")) {
            if (sub.len >= 2) explicit_id = sub[1].asText() orelse explicit_id;
        } else if (parsePredicate(extra)) |p| {
            predicates.append(self.allocator, p) catch return EvalError.OutOfMemory;
        } else {
            self.warnFmt(
                extra.span,
                "unknown or malformed (net-rule …) predicate ({s} …); recognised predicates: {s}",
                .{ head, predicate_keyword_list },
            );
        }
    }

    if (globs.items.len == 0) {
        self.warnFmt(children[0].span, "(net-rule \"{s}\" …) needs a (nets GLOB…) selector — ignored", .{text});
        return null;
    }
    if (predicates.items.len == 0) {
        self.warnFmt(children[0].span, "(net-rule \"{s}\" …) asserts nothing; add a predicate ({s}) — ignored", .{ text, predicate_keyword_list });
        return null;
    }
    return .{
        .text = text,
        .id = try ruleId(self, explicit_id, text),
        .scope = scope,
        .body = .{ .net_scoped = .{
            .globs = globs.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
            .predicates = predicates.toOwnedSlice(self.allocator) catch return EvalError.OutOfMemory,
        } },
    };
}

/// An explicit `(id "…")` wins; otherwise the id is the CRC32 of the rule
/// text, byte-for-byte the derivation `Requirement.id` uses for library rules.
/// That is what keeps a `(verifies …)` sign-off attached across every edit
/// that leaves the rule's own sentence alone.
fn ruleId(self: *Evaluator, explicit_id: []const u8, text: []const u8) EvalError![]const u8 {
    if (explicit_id.len > 0) return explicit_id;
    return env_mod.requirementIdForText(self.allocator, text) catch return EvalError.OutOfMemory;
}

/// Evaluate `node` and read the result as a string. A bare atom that names no
/// binding is an evaluation error inside the evaluator, so this reports null
/// rather than propagating: the caller's warning names the offending form.
fn evalText(self: *Evaluator, node: Node, env: *Env) EvalError!?[]const u8 {
    const value = self.evalNode(node, env) catch return null;
    return value.asString();
}

/// Does `name` match `glob`? The glob language is deliberately the smallest
/// one that covers the cases a net selector needs: `*` matches any run of
/// characters (including none) and every other byte matches itself, so `V_*`,
/// `*_RF`, `buck/*` and an exact name all work. Matching is ASCII
/// case-insensitive, like every other net selector in the DSL.
pub fn globMatches(glob: []const u8, name: []const u8) bool {
    // Iterative two-pointer backtracking: O(len) memory-free, and it cannot
    // recurse into a stack overflow on a pathological `*`-heavy pattern.
    var g: usize = 0;
    var n: usize = 0;
    var star: ?usize = null;
    var star_n: usize = 0;
    while (n < name.len) {
        if (g < glob.len and glob[g] == '*') {
            star = g;
            g += 1;
            star_n = n;
            continue;
        }
        if (g < glob.len and std.ascii.toUpper(glob[g]) == std.ascii.toUpper(name[n])) {
            g += 1;
            n += 1;
            continue;
        }
        const s = star orelse return false;
        g = s + 1;
        star_n += 1;
        n = star_n;
    }
    while (g < glob.len and glob[g] == '*') g += 1;
    return g == glob.len;
}

// ── Tests ──────────────────────────────────────────────────────────────

const parser_mod = @import("../sexpr/parser.zig");

// spec: eval/authored_rules - net-rule glob matching accepts prefix, suffix, hierarchy and exact selectors
test "globMatches covers the documented selector shapes" {
    try std.testing.expect(globMatches("V_*", "V_3V3"));
    try std.testing.expect(globMatches("*_RF", "LO_RF"));
    try std.testing.expect(globMatches("buck/*", "buck/VOUT"));
    try std.testing.expect(globMatches("VBUS", "VBUS"));
    try std.testing.expect(globMatches("*", "anything/at/all"));
    // Case-insensitive, like every other net selector in the DSL.
    try std.testing.expect(globMatches("v_*", "V_3V3"));
    // A `*` matches an EMPTY run, so a trailing star still matches the stem.
    try std.testing.expect(globMatches("V_3V3*", "V_3V3"));

    try std.testing.expect(!globMatches("V_*", "GND"));
    try std.testing.expect(!globMatches("*_RF", "RF_IN"));
    // A hierarchy glob does not leak across the slash it names.
    try std.testing.expect(!globMatches("buck/*", "ldo/VOUT"));
    // An exact selector is exact: no implicit prefix match.
    try std.testing.expect(!globMatches("VBUS", "VBUS_SENSE"));
    // Backtracking case: the first `*` must give back characters so the
    // literal tail can land. A greedy non-backtracking matcher fails this.
    try std.testing.expect(globMatches("*A*B", "xAyAzB"));
}

// spec: eval/authored_rules - every net-rule predicate keyword parses to its NetPredicate variant and rejects out-of-range arguments
test "parsePredicate dispatches every documented predicate" {
    const alloc = std.testing.allocator;
    const Case = struct { src: []const u8, tag: std.meta.Tag(NetPredicate) };
    const cases = [_]Case{
        .{ .src = "(min-bulk-uf 10)", .tag = .min_bulk_uf },
        .{ .src = "(declared-envelope)", .tag = .declared_envelope },
        .{ .src = "(in-net-class)", .tag = .in_net_class },
        .{ .src = "(max-fanout 12)", .tag = .max_fanout },
    };
    // One case per documented predicate keeps the table and its coverage locked.
    try std.testing.expectEqual(predicate_docs.len, cases.len);
    for (cases) |c| {
        const nodes = try parser_mod.parse(alloc, c.src);
        defer parser_mod.freeNodes(alloc, nodes);
        const p = parsePredicate(nodes[0]) orelse return error.NotRecognized;
        try std.testing.expectEqual(c.tag, std.meta.activeTag(p));
    }

    // Out-of-range / malformed arguments are refused rather than clamped.
    try expectPredicateRejected(alloc, "(min-bulk-uf 0)");
    try expectPredicateRejected(alloc, "(min-bulk-uf -1)");
    try expectPredicateRejected(alloc, "(max-fanout 0)");
    try expectPredicateRejected(alloc, "(max-fanout -3)");
    // A zero-arg marker with an argument is a typo, not a parameterisation.
    try expectPredicateRejected(alloc, "(declared-envelope 3)");
    try expectPredicateRejected(alloc, "(in-net-class \"rf\")");
    try expectPredicateRejected(alloc, "(min-bulk 10)");
}

fn expectPredicateRejected(alloc: std.mem.Allocator, src: []const u8) !void {
    const nodes = try parser_mod.parse(alloc, src);
    defer parser_mod.freeNodes(alloc, nodes);
    try std.testing.expect(parsePredicate(nodes[0]) == null);
}

// spec: eval/authored_rules - every predicate_docs row's syntax leads with the keyword parsePredicate dispatches on
test "predicate_docs syntax keyword matches the tag dispatch" {
    const Tag = std.meta.Tag(NetPredicate);
    inline for (@typeInfo(Tag).@"enum".field_names) |f| {
        const doc = predicate_docs[@backingInt(@field(Tag, f))];
        try std.testing.expectEqual(@as(u8, '('), doc.syntax[0]);
        // The variant's own `sourceName` is what diagnostics print; it must be
        // the same keyword the documented template opens with.
        const value: NetPredicate = switch (@field(Tag, f)) {
            .min_bulk_uf => .{ .min_bulk_uf = 1 },
            .declared_envelope => .declared_envelope,
            .in_net_class => .in_net_class,
            .max_fanout => .{ .max_fanout = 1 },
        };
        const kw = value.sourceName();
        try std.testing.expectEqualStrings(kw, doc.syntax[1 .. 1 + kw.len]);
        const after = doc.syntax[1 + kw.len];
        try std.testing.expect(after == ' ' or after == ')');
    }
}
