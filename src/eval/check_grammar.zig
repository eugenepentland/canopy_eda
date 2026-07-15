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
    return .{ .decoupling = .{ .pin_a = a, .pin_b = b, .min_uf = min_uf } };
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

/// Doc + parse-dispatch table, one row per `Check` variant, indexed by the
/// union's tag. The comptime unwrap turns a newly-added variant with no row
/// into a compile error naming it — the checker's grammar cannot gain a case
/// that is undocumented or undispatched.
pub const check_docs = blk: {
    const Tag = std.meta.Tag(Check);
    const N = @typeInfo(Tag).@"enum".fields.len;
    var t: [N]?CheckDoc = @splat(null);
    t[@intFromEnum(Tag.connected)] = .{
        .syntax = "(connected (pin \"A\") (pin \"B\"))",
        .summary = "Both named pins of this instance must resolve to the same net.",
        .parse = parseConnected,
    };
    t[@intFromEnum(Tag.decoupling)] = .{
        .syntax = "(decoupling (pin \"A\") (pin \"B\") (min-uf F))",
        .summary = "At least one capacitor of value ≥ F µF must bridge the nets on pins A and B.",
        .parse = parseDecoupling,
    };
    t[@intFromEnum(Tag.pullup_range)] = .{
        .syntax = "(pullup-range (pin \"P\") (net \"N\") (min-ohms L) (max-ohms H))",
        .summary = "A resistor of value in [L, H] Ω must bridge pin P's net and net N.",
        .parse = parsePullupRange,
    };
    t[@intFromEnum(Tag.voltage_range)] = .{
        .syntax = "(voltage-range (pin \"V\") (min L) (max H))",
        .summary = "The voltage declared on pin V's net (via ports, walking " ++
            "DC-equivalent series parts) must lie in [L, H] V; a rated range " ++
            "must be a subset of it.",
        .parse = parseVoltageRange,
    };
    t[@intFromEnum(Tag.tied_to_net)] = .{
        .syntax = "(tied-to-net (pin \"P\") (net \"N\"))",
        .summary = "Pin P must resolve to net N (alias-aware) — a datasheet fixed-rail tie.",
        .parse = parseTiedToNet,
    };
    t[@intFromEnum(Tag.not_connected)] = .{
        .syntax = "(not-connected (pin \"P\"))",
        .summary = "Pin P must be left unconnected (no foreign co-pin, not a block port).",
        .parse = parseNotConnected,
    };
    t[@intFromEnum(Tag.pin_not_floating)] = .{
        .syntax = "(pin-not-floating (pin \"P\"))",
        .summary = "Pin P must be tied to a defined level: a net with a co-pin or a block port.",
        .parse = parsePinNotFloating,
    };
    t[@intFromEnum(Tag.pins_on_same_net)] = .{
        .syntax = "(pins-on-same-net (pins \"A\" \"B\" …))",
        .summary = "Every listed pin function must resolve to the same net (N-pin connected).",
        .parse = parsePinsOnSameNet,
    };
    t[@intFromEnum(Tag.decoupling_per_pin)] = .{
        .syntax = "(decoupling-per-pin (return-pin \"GND\") (pins \"VDD_1\" …) (min-uf F) (count N))",
        .summary = "At least N of the listed pins must each have a ≥ F µF cap to the return net.",
        .parse = parseDecouplingPerPin,
    };
    t[@intFromEnum(Tag.series_element)] = .{
        .syntax = "(series-element (kind R|L|C) (pin \"P\") (target-net \"N\") (min X) (max Y))",
        .summary = "An R/L/C of value in [X, Y] (Ω/µH/µF by kind) must bridge pin P's net and N.",
        .parse = parseSeriesElement,
    };
    // Exhaustiveness by construction: a variant with no row is a compile error.
    var out: [N]CheckDoc = undefined;
    for (t, 0..) |entry, i| {
        out[i] = entry orelse @compileError("missing check_docs row for Check." ++
            @typeInfo(Tag).@"enum".fields[i].name ++
            " — every requirement-check variant must be documented");
    }
    break :blk out;
};

/// Comma-separated kebab-case keyword list for every `Check` variant, e.g.
/// `connected, decoupling, …`. Comptime-derived from the tag enum so the
/// "recognized checks" a rejection surfaces can never drift from `parseCheck`.
pub const check_keyword_list: []const u8 = blk: {
    const Tag = std.meta.Tag(Check);
    var s: []const u8 = "";
    for (@typeInfo(Tag).@"enum".fields, 0..) |f, i| {
        s = s ++ (if (i > 0) ", " else "") ++ kebab(f.name);
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
    inline for (@typeInfo(Tag).@"enum".fields) |f| {
        if (std.mem.eql(u8, kind, comptime kebab(f.name))) {
            return check_docs[@intFromEnum(@field(Tag, f.name))].parse(allocator, body_children);
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

// spec: eval/check_grammar - every check_docs row's syntax leads with the kebab-case keyword parseCheck dispatches on
test "check_docs syntax keyword matches the tag dispatch" {
    const Tag = std.meta.Tag(Check);
    inline for (@typeInfo(Tag).@"enum".fields) |f| {
        const doc = check_docs[@intFromEnum(@field(Tag, f.name))];
        const kw = comptime kebab(f.name);
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
        .{ .src = "(check (tied-to-net (pin \"P\") (net \"N\")))", .tag = .tied_to_net },
        .{ .src = "(check (not-connected (pin \"5\")))", .tag = .not_connected },
        .{ .src = "(check (pin-not-floating (pin \"BOOT0\")))", .tag = .pin_not_floating },
        .{ .src = "(check (pins-on-same-net (pins \"VSS_1\" \"VSS_2\")))", .tag = .pins_on_same_net },
        .{ .src = "(check (decoupling-per-pin (return-pin \"GND\") " ++
            "(pins \"VDD_1\" \"VDD_2\") (min-uf 0.1) (count 2)))", .tag = .decoupling_per_pin },
        .{ .src = "(check (series-element (kind R) (pin \"P\") " ++
            "(target-net \"N\") (min 0) (max 10)))", .tag = .series_element },
    };
    // One case per documented variant — keeps the table and its coverage locked.
    try std.testing.expectEqual(@typeInfo(std.meta.Tag(Check)).@"enum".fields.len, cases.len);
    for (cases) |c| {
        const nodes = try parser_mod.parse(alloc, c.src);
        const chk = parseCheck(alloc, nodes[0]) orelse return error.NotRecognized;
        try std.testing.expectEqual(c.tag, std.meta.activeTag(chk));
    }
}
