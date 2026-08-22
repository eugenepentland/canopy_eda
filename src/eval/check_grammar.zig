//! The requirement-check grammar: the `(check …)` primitives that hang off a
//! library `(requirement …)` form, the parser that turns each into a `Check`
//! value, and the doc table `src/docgen.zig` renders the "Requirement checks"
//! language-reference section from. Keeping the parse dispatch, the accepted
//! keyword list, and the generated docs behind one table (`check_docs`) means
//! the checker's grammar cannot gain a case that is undocumented or
//! undispatched, and the reference cannot drift from the parser.

const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const numeric = @import("../numeric.zig");
const env = @import("env.zig");
const Check = env.Check;
const SeriesKind = env.SeriesKind;

// Arity floors for the multi-argument check bodies.
const pullup_range_min_children: usize = 5;
const decoupling_per_pin_min_children: usize = 5;
const series_element_min_children: usize = 6;
const series_element_max_index: usize = 5;
const feedback_divider_min_children: usize = 5;
const set_resistor_output_min_children: usize = 6;

/// One row of the requirement-check grammar: the source template a human
/// writes, a one-line description, and the parser that turns the inner
/// `(<keyword> …)` body into this `Check` variant. `parseCheck` dispatches
/// through this table and `src/docgen.zig` renders the "Requirement checks"
/// language-reference section from it, so the grammar docs, the parse
/// dispatch, and the accepted-keyword list can never drift apart.
pub const CheckDoc = struct {
    /// Source-form template, e.g. `(voltage-range (pin "V") (min L) (max H))`.
    /// Its leading keyword is the kebab-case tag name (a test asserts this).
    syntax: []const u8,
    /// What the check asserts, judged against the instance's containing block.
    summary: []const u8,
    /// Parse the body children (the `(<keyword> …)` list) into this variant,
    /// or null on an arity/shape mismatch. Pin-list slices share `allocator`'s
    /// lifetime, exactly as `parseCheck` documents.
    parse: *const fn (std.mem.Allocator, []const ast.Node) ?Check,
};

/// Kebab-case keyword a `Check` variant is written as in `.sexp` source: the
/// tag name with `_` → `-` (`pins_on_same_net` → `pins-on-same-net`). This is
/// the exact string `parseCheck` dispatches on. Built by comptime slice
/// concatenation so it never returns the address of a stack local.
fn kebab(comptime name: []const u8) []const u8 {
    comptime {
        var out: []const u8 = "";
        for (name) |c| out = out ++ &[_]u8{if (c == '_') '-' else c};
        return out;
    }
}

fn parseConnected(_: std.mem.Allocator, bc: []const ast.Node) ?Check {
    if (bc.len < 3) return null;
    const a = pinArg(bc[1]) orelse return null;
    const b = pinArg(bc[2]) orelse return null;
    return .{ .connected = .{ .pin_a = a, .pin_b = b } };
}

fn parseDecoupling(_: std.mem.Allocator, bc: []const ast.Node) ?Check {
    if (bc.len < 4) return null;
    const a = pinArg(bc[1]) orelse return null;
    const b = pinArg(bc[2]) orelse return null;
    const min_uf = namedNumberArg(bc[3], "min-uf") orelse return null;
    if (!std.math.isFinite(min_uf) or min_uf < 0) return null;
    var max_uf: ?f64 = null;
    if (bc.len >= 5) {
        const parsed_max = namedNumberArg(bc[4], "max-uf") orelse return null;
        if (!std.math.isFinite(parsed_max) or parsed_max < min_uf) return null;
        max_uf = parsed_max;
    }
    return .{ .decoupling = .{
        .pin_a = a,
        .pin_b = b,
        .min_uf = min_uf,
        .max_uf = max_uf,
    } };
}

fn parsePullupRange(_: std.mem.Allocator, bc: []const ast.Node) ?Check {
    if (bc.len < pullup_range_min_children) return null;
    const p = pinArg(bc[1]) orelse return null;
    const net_name = netArg(bc[2]) orelse return null;
    const lo = namedNumberArg(bc[3], "min-ohms") orelse return null;
    const hi = namedNumberArg(bc[4], "max-ohms") orelse return null;
    return .{ .pullup_range = .{
        .pin = p,
        .target_net = net_name,
        .min_ohms = lo,
        .max_ohms = hi,
    } };
}

fn parseVoltageRange(_: std.mem.Allocator, bc: []const ast.Node) ?Check {
    if (bc.len < 4) return null;
    const p = pinArg(bc[1]) orelse return null;
    const lo = namedNumberArg(bc[2], "min") orelse return null;
    const hi = namedNumberArg(bc[3], "max") orelse return null;
    return .{ .voltage_range = .{ .pin = p, .min_v = lo, .max_v = hi } };
}

fn parseVoltageNotAbove(_: std.mem.Allocator, bc: []const ast.Node) ?Check {
    if (bc.len < 4) return null;
    const a = pinArg(bc[1]) orelse return null;
    const b = pinArg(bc[2]) orelse return null;
    const margin = namedNumberArg(bc[3], "margin") orelse return null;
    if (!std.math.isFinite(margin) or margin < 0) return null;
    return .{ .voltage_range = .{
        .pin = a,
        .min_v = 0,
        .max_v = 0,
        .not_above_pin = b,
        .margin_v = margin,
    } };
}

fn parseTiedToNet(_: std.mem.Allocator, bc: []const ast.Node) ?Check {
    if (bc.len < 3) return null;
    const p = pinArg(bc[1]) orelse return null;
    const n = netArg(bc[2]) orelse return null;
    return .{ .tied_to_net = .{ .pin = p, .target_net = n } };
}

fn parseNotConnected(_: std.mem.Allocator, bc: []const ast.Node) ?Check {
    if (bc.len < 2) return null;
    const p = pinArg(bc[1]) orelse return null;
    return .{ .not_connected = .{ .pin = p } };
}

fn parsePinNotFloating(_: std.mem.Allocator, bc: []const ast.Node) ?Check {
    if (bc.len < 2) return null;
    const p = pinArg(bc[1]) orelse return null;
    return .{ .pin_not_floating = .{ .pin = p } };
}

fn parsePinsOnSameNet(allocator: std.mem.Allocator, bc: []const ast.Node) ?Check {
    if (bc.len < 2) return null;
    // Body: (pins-on-same-net (pins "A" "B" "C" ...))
    const pins_form = bc[1].asList() orelse return null;
    if (pins_form.len < 3) return null;
    const ph = pins_form[0].asAtom() orelse return null;
    if (!std.mem.eql(u8, ph, "pins")) return null;
    var list: std.ArrayList([]const u8) = .empty;
    for (pins_form[1..]) |pn| {
        const s = pn.asText() orelse continue;
        list.append(allocator, s) catch return null;
    }
    if (list.items.len < 2) return null;
    return .{ .pins_on_same_net = .{ .pins = list.toOwnedSlice(allocator) catch return null } };
}

fn parseDecouplingPerPin(allocator: std.mem.Allocator, bc: []const ast.Node) ?Check {
    if (bc.len < decoupling_per_pin_min_children) return null;
    // (decoupling-per-pin (return-pin "X") (pins "A" "B"...) (min-uf F) (count N))
    const rp_form = bc[1].asList() orelse return null;
    if (rp_form.len < 2) return null;
    const rp_head = rp_form[0].asAtom() orelse return null;
    if (!std.mem.eql(u8, rp_head, "return-pin")) return null;
    const return_pin = rp_form[1].asText() orelse return null;

    const pins_form = bc[2].asList() orelse return null;
    if (pins_form.len < 2) return null;
    const ph = pins_form[0].asAtom() orelse return null;
    if (!std.mem.eql(u8, ph, "pins")) return null;
    var list: std.ArrayList([]const u8) = .empty;
    for (pins_form[1..]) |pn| {
        const s = pn.asText() orelse continue;
        list.append(allocator, s) catch return null;
    }
    if (list.items.len == 0) return null;

    const min_uf = namedNumberArg(bc[3], "min-uf") orelse return null;
    const count_f = namedNumberArg(bc[4], "count") orelse return null;
    // Reject NaN/negative/out-of-range before narrowing (bare @intFromFloat
    // is UB in the safety-off prod build; the old `< 0 ? 0` guard missed
    // NaN and overflow). A non-representable count clamps to 0.
    const count: u32 = numeric.checkedInt(u32, count_f) orelse 0;
    return .{ .decoupling_per_pin = .{
        .return_pin = return_pin,
        .pins = list.toOwnedSlice(allocator) catch return null,
        .min_uf = min_uf,
        .count = count,
    } };
}

fn parseSeriesElement(_: std.mem.Allocator, bc: []const ast.Node) ?Check {
    if (bc.len < series_element_min_children) return null;
    // (series-element (kind R|L|C) (pin "P") (target-net "N") (min X) (max Y))
    const kind_form = bc[1].asList() orelse return null;
    if (kind_form.len < 2) return null;
    const kh = kind_form[0].asAtom() orelse return null;
    if (!std.mem.eql(u8, kh, "kind")) return null;
    const kind_atom = kind_form[1].asAtom() orelse return null;
    const sk: SeriesKind = if (std.mem.eql(u8, kind_atom, "R")) .R //
        else if (std.mem.eql(u8, kind_atom, "L")) .L //
        else if (std.mem.eql(u8, kind_atom, "C")) .C //
        else return null;
    const p = pinArg(bc[2]) orelse return null;
    const tn_form = bc[3].asList() orelse return null;
    if (tn_form.len < 2) return null;
    const tn_head = tn_form[0].asAtom() orelse return null;
    if (!std.mem.eql(u8, tn_head, "target-net")) return null;
    const target_net = tn_form[1].asText() orelse return null;
    const lo = namedNumberArg(bc[4], "min") orelse return null;
    const hi = namedNumberArg(bc[series_element_max_index], "max") orelse return null;
    return .{ .series_element = .{
        .kind = sk,
        .pin = p,
        .target_net = target_net,
        .min = lo,
        .max = hi,
    } };
}

fn parseFeedbackDivider(_: std.mem.Allocator, bc: []const ast.Node) ?Check {
    if (bc.len < feedback_divider_min_children) return null;
    const reference_v = positiveNumberArg(bc[3], "reference-v") orelse return null;
    const tolerance_pct = nonNegativeNumberArg(bc[4], "tolerance-pct") orelse return null;
    return .{ .feedback_divider = .{
        .pin = pinArg(bc[1]) orelse return null,
        .return_net = namedTextArg(bc[2], "return-net") orelse return null,
        .reference_v = reference_v,
        .tolerance_pct = tolerance_pct,
    } };
}

fn parseSetResistorOutput(_: std.mem.Allocator, bc: []const ast.Node) ?Check {
    if (bc.len < set_resistor_output_min_children) return null;
    const current_ua = positiveNumberArg(bc[4], "current-ua") orelse return null;
    const tolerance_pct = nonNegativeNumberArg(bc[5], "tolerance-pct") orelse return null;
    return .{ .set_resistor_output = .{
        .pin = pinArg(bc[1]) orelse return null,
        .return_net = namedTextArg(bc[2], "return-net") orelse return null,
        .output_pin = namedTextArg(bc[3], "output-pin") orelse return null,
        .current_ua = current_ua,
        .tolerance_pct = tolerance_pct,
    } };
}

/// Doc + parse-dispatch table. The first row for each `Check` variant is
/// indexed by the union tag; closely-related grammar aliases follow those
/// core rows and may share a variant implementation.
pub const check_docs = blk: {
    const Tag = std.meta.Tag(Check);
    const N = @typeInfo(Tag).@"enum".field_names.len;
    var t: [N + 1]?CheckDoc = @splat(null);
    t[@backingInt(Tag.connected)] = .{
        .syntax = "(connected (pin \"A\") (pin \"B\"))",
        .summary = "Both named pins of this instance must resolve to the same net.",
        .parse = parseConnected,
    };
    t[@backingInt(Tag.decoupling)] = .{
        .syntax = "(decoupling (pin \"A\") (pin \"B\") (min-uf F) [(max-uf H)])",
        .summary = "A capacitor of value ≥ F µF, and ≤ H when supplied, must bridge the nets on pins A and B.",
        .parse = parseDecoupling,
    };
    t[@backingInt(Tag.pullup_range)] = .{
        .syntax = "(pullup-range (pin \"P\") (net \"N\") (min-ohms L) (max-ohms H))",
        .summary = "A resistor of value in [L, H] Ω must bridge pin P's net and net N.",
        .parse = parsePullupRange,
    };
    t[@backingInt(Tag.voltage_range)] = .{
        .syntax = "(voltage-range (pin \"V\") (min L) (max H))",
        .summary = "The voltage declared on pin V's net (via ports, walking " ++
            "DC-equivalent series parts) must lie in [L, H] V; a rated range " ++
            "must be a subset of it.",
        .parse = parseVoltageRange,
    };
    t[@backingInt(Tag.tied_to_net)] = .{
        .syntax = "(tied-to-net (pin \"P\") (net \"N\"))",
        .summary = "Pin P must resolve to net N (alias-aware) — a datasheet fixed-rail tie.",
        .parse = parseTiedToNet,
    };
    t[@backingInt(Tag.not_connected)] = .{
        .syntax = "(not-connected (pin \"P\"))",
        .summary = "Pin P must be left unconnected (no foreign co-pin, not a block port).",
        .parse = parseNotConnected,
    };
    t[@backingInt(Tag.pin_not_floating)] = .{
        .syntax = "(pin-not-floating (pin \"P\"))",
        .summary = "Pin P must be tied to a defined level: a net with a co-pin or a block port.",
        .parse = parsePinNotFloating,
    };
    t[@backingInt(Tag.pins_on_same_net)] = .{
        .syntax = "(pins-on-same-net (pins \"A\" \"B\" …))",
        .summary = "Every listed pin function must resolve to the same net (N-pin connected).",
        .parse = parsePinsOnSameNet,
    };
    t[@backingInt(Tag.decoupling_per_pin)] = .{
        .syntax = "(decoupling-per-pin (return-pin \"GND\") (pins \"VDD_1\" …) (min-uf F) (count N))",
        .summary = "At least N of the listed pins must each have a ≥ F µF cap to the return net.",
        .parse = parseDecouplingPerPin,
    };
    t[@backingInt(Tag.series_element)] = .{
        .syntax = "(series-element (kind R|L|C) (pin \"P\") (target-net \"N\") (min X) (max Y))",
        .summary = "An R/L/C of value in [X, Y] (Ω/µH/µF by kind) must bridge pin P's net and N.",
        .parse = parseSeriesElement,
    };
    t[@backingInt(Tag.feedback_divider)] = .{
        .syntax = "(feedback-divider (pin \"FB\") (return-net \"GND\") (reference-v V) (tolerance-pct P))",
        .summary = "Calculate VOUT=VREF*(1+Rtop/Rbottom) and compare it " ++
            "with the declared or rail-named output voltage.",
        .parse = parseFeedbackDivider,
    };
    t[@backingInt(Tag.set_resistor_output)] = .{
        .syntax = "(set-resistor-output (pin \"SET\") (return-net \"GND\") " ++
            "(output-pin \"OUT\") (current-ua I) (tolerance-pct P))",
        .summary = "Calculate VOUT=ISET*RSET and compare it with the declared or rail-named output voltage.",
        .parse = parseSetResistorOutput,
    };
    t[N] = .{
        .syntax = "(voltage-not-above (pin \"A\") (pin \"B\") (margin M))",
        .summary = "The highest declared voltage on pin A's net must be no greater than " ++
            "the lowest declared voltage on pin B's net plus M volts.",
        .parse = parseVoltageNotAbove,
    };
    // Exhaustiveness by construction: a variant with no row is a compile error.
    var out: [N + 1]CheckDoc = undefined;
    for (t[0..N], 0..) |entry, i| {
        out[i] = entry orelse @compileError("missing check_docs row for Check." ++
            @typeInfo(Tag).@"enum".field_names[i] ++
            " — every requirement-check variant must be documented");
    }
    out[N] = t[N].?;
    break :blk out;
};

/// Comma-separated kebab-case keyword list for every `Check` variant, e.g.
/// `connected, decoupling, …`. Comptime-derived from the tag enum so the
/// "recognized checks" a rejection surfaces can never drift from `parseCheck`.
pub const check_keyword_list: []const u8 = blk: {
    var s: []const u8 = "";
    for (check_docs, 0..) |doc, i| {
        const end = std.mem.indexOfScalar(u8, doc.syntax, ' ') orelse doc.syntax.len - 1;
        s = s ++ (if (i > 0) ", " else "") ++ doc.syntax[1..end];
    }
    break :blk s;
};

/// Parse `(check (<primitive> ...))` nested inside a `(requirement ...)`
/// body. Returns null if the form isn't a recognized check. Dispatch and the
/// accepted keyword set come from `check_docs` (keyed on the `Check` tag's
/// kebab-case name), so this stays in lockstep with the generated grammar
/// reference. Pin-list slices are allocated from `allocator` and share its
/// lifetime (request arena in the serve path, evaluator allocator at build time).
pub fn parseCheck(allocator: std.mem.Allocator, node: ast.Node) ?Check {
    const children = node.asList() orelse return null;
    if (children.len < 2) return null;
    const head = children[0].asAtom() orelse return null;
    if (!std.mem.eql(u8, head, "check")) return null;
    const body = children[1];
    const body_children = body.asList() orelse return null;
    if (body_children.len < 1) return null;
    const kind = body_children[0].asAtom() orelse return null;

    const Tag = std.meta.Tag(Check);
    const core_count = @typeInfo(Tag).@"enum".field_names.len;
    inline for (check_docs[core_count..]) |doc| {
        const end = comptime std.mem.indexOfScalar(u8, doc.syntax, ' ') orelse doc.syntax.len - 1;
        if (std.mem.eql(u8, kind, doc.syntax[1..end])) return doc.parse(allocator, body_children);
    }

    inline for (@typeInfo(Tag).@"enum".field_names) |f| {
        if (std.mem.eql(u8, kind, comptime kebab(f))) {
            return check_docs[@backingInt(@field(Tag, f))].parse(allocator, body_children);
        }
    }
    return null;
}

fn pinArg(node: ast.Node) ?[]const u8 {
    const c = node.asList() orelse return null;
    if (c.len < 2) return null;
    const h = c[0].asAtom() orelse return null;
    if (!std.mem.eql(u8, h, "pin")) return null;
    return c[1].asText();
}

fn netArg(node: ast.Node) ?[]const u8 {
    const c = node.asList() orelse return null;
    if (c.len < 2) return null;
    const h = c[0].asAtom() orelse return null;
    if (!std.mem.eql(u8, h, "net")) return null;
    return c[1].asText();
}

fn namedNumberArg(node: ast.Node, name: []const u8) ?f64 {
    const c = node.asList() orelse return null;
    if (c.len < 2) return null;
    const h = c[0].asAtom() orelse return null;
    if (!std.mem.eql(u8, h, name)) return null;
    return c[1].asNumber();
}

fn positiveNumberArg(node: ast.Node, name: []const u8) ?f64 {
    const value = namedNumberArg(node, name) orelse return null;
    return if (std.math.isFinite(value) and value > 0) value else null;
}

fn nonNegativeNumberArg(node: ast.Node, name: []const u8) ?f64 {
    const value = namedNumberArg(node, name) orelse return null;
    return if (std.math.isFinite(value) and value >= 0) value else null;
}

fn namedTextArg(node: ast.Node, name: []const u8) ?[]const u8 {
    const c = node.asList() orelse return null;
    if (c.len < 2) return null;
    const h = c[0].asAtom() orelse return null;
    if (!std.mem.eql(u8, h, name)) return null;
    return c[1].asText();
}

// ── Tests ──────────────────────────────────────────────────────────────

const parser_mod = @import("../sexpr/parser.zig");

test "parseCheck accepts a two-child not-connected body" {
    const alloc = std.testing.allocator;
    // (not-connected (pin "5")) has exactly two children — the arity floor for
    // this kind. The `< 2` guard must accept it; a `<= 2` flip returns null.
    const nodes = try parser_mod.parse(alloc, "(check (not-connected (pin \"5\")))");
    defer parser_mod.freeNodes(alloc, nodes);
    const chk = parseCheck(alloc, nodes[0]).?;
    try std.testing.expectEqualStrings("5", chk.not_connected.pin);
}

// spec: eval/check_grammar - decoupling max-uf prevents bulk capacitors satisfying HF bypass rules
test "parseCheck decoupling accepts optional max-uf" {
    const alloc = std.testing.allocator;
    const nodes = try parser_mod.parse(
        alloc,
        "(check (decoupling (pin \"VIN\") (pin \"GND\") (min-uf 0.09) (max-uf 0.11)))",
    );
    defer parser_mod.freeNodes(alloc, nodes);
    const chk = parseCheck(alloc, nodes[0]).?;
    try std.testing.expectApproxEqAbs(@as(f64, 0.11), chk.decoupling.max_uf.?, 1e-9);
}

// spec: eval/check_grammar - decoupling rejects malformed or inverted capacitor bounds
test "parseCheck decoupling rejects invalid max-uf" {
    const alloc = std.testing.allocator;
    const malformed = try parser_mod.parse(
        alloc,
        "(check (decoupling (pin \"VIN\") (pin \"GND\") (min-uf 0.09) (maximum 0.11)))",
    );
    defer parser_mod.freeNodes(alloc, malformed);
    try std.testing.expect(parseCheck(alloc, malformed[0]) == null);
    const inverted = try parser_mod.parse(
        alloc,
        "(check (decoupling (pin \"VIN\") (pin \"GND\") (min-uf 1) (max-uf 0.1)))",
    );
    defer parser_mod.freeNodes(alloc, inverted);
    try std.testing.expect(parseCheck(alloc, inverted[0]) == null);
}

test "derived regulator checks reject non-physical numeric parameters" {
    const alloc = std.testing.allocator;
    const divider = try parser_mod.parse(
        alloc,
        "(check (feedback-divider (pin \"FB\") (return-net \"GND\") " ++
            "(reference-v 0) (tolerance-pct 2)))",
    );
    defer parser_mod.freeNodes(alloc, divider);
    try std.testing.expect(parseCheck(alloc, divider[0]) == null);

    const set = try parser_mod.parse(
        alloc,
        "(check (set-resistor-output (pin \"SET\") (return-net \"GND\") " ++
            "(output-pin \"OUT\") (current-ua 100) (tolerance-pct -1)))",
    );
    defer parser_mod.freeNodes(alloc, set);
    try std.testing.expect(parseCheck(alloc, set[0]) == null);
}

// spec: eval/check_grammar - every check_docs row's syntax leads with the kebab-case keyword parseCheck dispatches on
test "check_docs syntax keyword matches the tag dispatch" {
    const Tag = std.meta.Tag(Check);
    inline for (@typeInfo(Tag).@"enum".field_names) |f| {
        const doc = check_docs[@backingInt(@field(Tag, f))];
        const kw = comptime kebab(f);
        // The template opens with "(<keyword>" and the keyword is delimited by
        // a space or the closing paren — proving the documented form uses the
        // exact string parseCheck keys on.
        try std.testing.expect(doc.syntax.len > kw.len + 1);
        try std.testing.expectEqual(@as(u8, '('), doc.syntax[0]);
        try std.testing.expectEqualStrings(kw, doc.syntax[1 .. 1 + kw.len]);
        const after = doc.syntax[1 + kw.len];
        try std.testing.expect(after == ' ' or after == ')');
    }
}

// spec: eval/check_grammar - parseCheck dispatches every documented check keyword to its Check variant via check_docs
test "parseCheck dispatches every documented check keyword to its variant" {
    const alloc = std.heap.page_allocator;
    const Case = struct { src: []const u8, tag: std.meta.Tag(Check) };
    const cases = [_]Case{
        .{ .src = "(check (connected (pin \"A\") (pin \"B\")))", .tag = .connected },
        .{ .src = "(check (decoupling (pin \"A\") (pin \"B\") (min-uf 0.1)))", .tag = .decoupling },
        .{ .src = "(check (pullup-range (pin \"P\") (net \"N\") " ++
            "(min-ohms 2000) (max-ohms 67000)))", .tag = .pullup_range },
        .{ .src = "(check (voltage-range (pin \"V\") (min 3.0) (max 5.4)))", .tag = .voltage_range },
        .{ .src = "(check (voltage-not-above (pin \"EN\") (pin \"VIN\") (margin 0.3)))", .tag = .voltage_range },
        .{ .src = "(check (tied-to-net (pin \"P\") (net \"N\")))", .tag = .tied_to_net },
        .{ .src = "(check (not-connected (pin \"5\")))", .tag = .not_connected },
        .{ .src = "(check (pin-not-floating (pin \"BOOT0\")))", .tag = .pin_not_floating },
        .{ .src = "(check (pins-on-same-net (pins \"VSS_1\" \"VSS_2\")))", .tag = .pins_on_same_net },
        .{ .src = "(check (decoupling-per-pin (return-pin \"GND\") " ++
            "(pins \"VDD_1\" \"VDD_2\") (min-uf 0.1) (count 2)))", .tag = .decoupling_per_pin },
        .{ .src = "(check (series-element (kind R) (pin \"P\") " ++
            "(target-net \"N\") (min 0) (max 10)))", .tag = .series_element },
        .{ .src = "(check (feedback-divider (pin \"FB\") (return-net \"GND\") " ++
            "(reference-v 0.6) (tolerance-pct 2)))", .tag = .feedback_divider },
        .{ .src = "(check (set-resistor-output (pin \"SET\") (return-net \"GND\") " ++
            "(output-pin \"OUT\") (current-ua 100) (tolerance-pct 2)))", .tag = .set_resistor_output },
    };
    // One case per documented variant — keeps the table and its coverage locked.
    try std.testing.expectEqual(
        check_docs.len,
        cases.len,
    );
    for (cases) |c| {
        const nodes = try parser_mod.parse(alloc, c.src);
        const chk = parseCheck(alloc, nodes[0]) orelse return error.NotRecognized;
        try std.testing.expectEqual(c.tag, std.meta.activeTag(chk));
    }
}
