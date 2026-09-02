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
const DistanceKind = env.DistanceKind;

// Arity floors for the multi-argument check bodies.
const pullup_range_min_children: usize = 5;
const decoupling_per_pin_min_children: usize = 5;
const series_element_min_children: usize = 6;
const series_element_max_index: usize = 5;
const feedback_divider_min_children: usize = 5;
const set_resistor_output_min_children: usize = 6;
const cap_rating_min_children: usize = 3;
const max_distance_min_children: usize = 4;
const sequence_min_children: usize = 4;
/// Ceramic derating floor applied when `(cap-rating …)` names neither bound.
/// A 1.0x rule is wrong for the X5R/X7R parts these rules are written about:
/// their capacitance falls steeply with applied DC bias, so a cap sitting at
/// its own rating is well under its marked value. 1.5x is the conventional
/// "rate at 1.5x the working voltage" ceramic guidance and is what the
/// generated reference documents as the default.
const default_cap_rating_ratio: f64 = 1.5;

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

fn parseCapRating(_: std.mem.Allocator, bc: []const ast.Node) ?Check {
    if (bc.len < cap_rating_min_children) return null;
    const a = pinArg(bc[1]) orelse return null;
    const b = pinArg(bc[2]) orelse return null;
    var min_ratio: ?f64 = null;
    var min_v: ?f64 = null;
    for (bc[3..]) |node| {
        if (namedNumberArg(node, "min-ratio")) |r| {
            if (min_ratio != null or !std.math.isFinite(r) or r <= 0) return null;
            min_ratio = r;
        } else if (namedNumberArg(node, "min-v")) |v| {
            if (min_v != null or !std.math.isFinite(v) or v <= 0) return null;
            min_v = v;
        } else return null;
    }
    // Neither bound written: fall back to the documented ceramic derating
    // floor rather than the useless 1.0x "rated at least what it sees".
    if (min_ratio == null and min_v == null) min_ratio = default_cap_rating_ratio;
    return .{ .cap_rating = .{
        .pin_a = a,
        .pin_b = b,
        .min_ratio = min_ratio orelse 0,
        .min_v = min_v orelse 0,
    } };
}

fn parseMaxDistance(_: std.mem.Allocator, bc: []const ast.Node) ?Check {
    if (bc.len < max_distance_min_children) return null;
    const p = pinArg(bc[1]) orelse return null;
    const kind = distanceKindArg(bc[2]) orelse return null;
    const mm = namedNumberArg(bc[3], "mm") orelse return null;
    if (!std.math.isFinite(mm) or mm <= 0) return null;
    var min_value: ?f64 = null;
    var max_value: ?f64 = null;
    for (bc[4..]) |node| {
        if (namedNumberArg(node, "min-value")) |v| {
            if (min_value != null or !std.math.isFinite(v) or v < 0) return null;
            min_value = v;
        } else if (namedNumberArg(node, "max-value")) |v| {
            if (max_value != null or !std.math.isFinite(v) or v < 0) return null;
            max_value = v;
        } else return null;
    }
    if (min_value != null and max_value != null and max_value.? < min_value.?) return null;
    return .{ .max_distance = .{
        .pin = p,
        .kind = kind,
        .max_mm = mm,
        .min_value = min_value,
        .max_value = max_value,
    } };
}

fn parseSequence(_: std.mem.Allocator, bc: []const ast.Node) ?Check {
    if (bc.len < sequence_min_children) return null;
    const a = pinArg(bc[1]) orelse return null;
    // The relation word is spelled out so the form reads as the sentence the
    // datasheet writes. Only `before` exists: `(sequence B before A)` says the
    // reverse, so an `after` spelling would be two ways to write one rule.
    const relation = bc[2].asAtom() orelse return null;
    if (!std.mem.eql(u8, relation, "before")) return null;
    const b = pinArg(bc[3]) orelse return null;
    var margin_ms: f64 = 0;
    if (bc.len >= 5) {
        const parsed = namedNumberArg(bc[4], "margin-ms") orelse return null;
        if (!std.math.isFinite(parsed) or parsed < 0) return null;
        margin_ms = parsed;
    }
    return .{ .sequence = .{ .pin_a = a, .pin_b = b, .margin_ms = margin_ms } };
}

/// `(kind C|R|L|any)` — the passive class a `(max-distance …)` accepts.
fn distanceKindArg(node: ast.Node) ?DistanceKind {
    const c = node.asList() orelse return null;
    if (c.len < 2) return null;
    const h = c[0].asAtom() orelse return null;
    if (!std.mem.eql(u8, h, "kind")) return null;
    const word = c[1].asAtom() orelse return null;
    return std.meta.stringToEnum(DistanceKind, word);
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
    t[@backingInt(Tag.cap_rating)] = .{
        .syntax = "(cap-rating (pin \"A\") (pin \"B\") [(min-ratio X)] [(min-v V)])",
        .summary = "Every capacitor bridging pins A and B must be rated at least X times the " ++
            "derived worst-case DC potential across those nets and at least V volts; the " ++
            "default with neither bound is 1.5x for ceramic derating. An unrated cap or an " ++
            "underivable envelope is reported unproven, never passed.",
        .parse = parseCapRating,
    };
    t[@backingInt(Tag.max_distance)] = .{
        .syntax = "(max-distance (pin \"P\") (kind C|R|L|any) (mm D) [(min-value X)] [(max-value Y)])",
        .summary = "The nearest matching passive on pin P's net must sit within D mm of that " ++
            "pad in the saved layout. Netlist-time this is layout-deferred (it fails early only " ++
            "when no passive matches at all); the measurement is the req-distance-far layout lint.",
        .parse = parseMaxDistance,
    };
    t[@backingInt(Tag.sequence)] = .{
        .syntax = "(sequence (pin \"A\") before (pin \"B\") [(margin-ms N)])",
        .summary = "The rail on pin A must power up before the rail on pin B, judged against " ++
            "the derived enable-graph order. An undetermined order is unproven, not a pass. " ++
            "margin-ms is recorded and reported but not enforced: the sequencing model carries " ++
            "no timing yet.",
        .parse = parseSequence,
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
        .{ .src = "(check (cap-rating (pin \"IN\") (pin \"GND\") (min-ratio 1.5)))", .tag = .cap_rating },
        .{ .src = "(check (max-distance (pin \"VIN\") (kind C) (mm 3.0)))", .tag = .max_distance },
        .{ .src = "(check (sequence (pin \"VDD\") before (pin \"VDDIO\")))", .tag = .sequence },
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

// spec: eval/check_grammar - cap-rating defaults to the documented ceramic derating ratio when neither bound is written
test "parseCheck cap-rating supplies the ceramic default" {
    const alloc = std.testing.allocator;
    const nodes = try parser_mod.parse(alloc, "(check (cap-rating (pin \"IN\") (pin \"GND\")))");
    defer parser_mod.freeNodes(alloc, nodes);
    const chk = parseCheck(alloc, nodes[0]).?;
    try std.testing.expectApproxEqAbs(default_cap_rating_ratio, chk.cap_rating.min_ratio, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0), chk.cap_rating.min_v, 1e-9);

    // A written (min-v …) alone leaves the ratio arm disabled rather than
    // silently stacking the default on top of the author's absolute floor.
    const absolute = try parser_mod.parse(alloc, "(check (cap-rating (pin \"IN\") (pin \"GND\") (min-v 25)))");
    defer parser_mod.freeNodes(alloc, absolute);
    const only_v = parseCheck(alloc, absolute[0]).?;
    try std.testing.expectApproxEqAbs(@as(f64, 0), only_v.cap_rating.min_ratio, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 25), only_v.cap_rating.min_v, 1e-9);
}

// spec: eval/check_grammar - cap-rating rejects unknown, repeated or non-positive bounds
test "parseCheck cap-rating rejects malformed bounds" {
    const alloc = std.testing.allocator;
    try expectRejected(alloc, "(check (cap-rating (pin \"IN\") (pin \"GND\") (min-ratio 0)))");
    try expectRejected(alloc, "(check (cap-rating (pin \"IN\") (pin \"GND\") (min-volts 25)))");
    try expectRejected(alloc, "(check (cap-rating (pin \"IN\") (pin \"GND\") (min-v 6) (min-v 25)))");
}

// spec: eval/check_grammar - max-distance accepts the four passive kinds with an optional value window and rejects an inverted one
test "parseCheck max-distance accepts kinds and a value window" {
    const alloc = std.testing.allocator;
    const nodes = try parser_mod.parse(
        alloc,
        "(check (max-distance (pin \"VIN\") (kind any) (mm 2.5) (min-value 0.09) (max-value 0.11)))",
    );
    defer parser_mod.freeNodes(alloc, nodes);
    const chk = parseCheck(alloc, nodes[0]).?;
    try std.testing.expectEqual(DistanceKind.any, chk.max_distance.kind);
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), chk.max_distance.max_mm, 1e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 0.11), chk.max_distance.max_value.?, 1e-9);

    try expectRejected(alloc, "(check (max-distance (pin \"VIN\") (kind Q) (mm 2.5)))");
    try expectRejected(alloc, "(check (max-distance (pin \"VIN\") (kind C) (mm 0)))");
    try expectRejected(alloc, "(check (max-distance (pin \"VIN\") (kind C) (mm 2) (min-value 1) (max-value 0.5)))");
}

// spec: eval/check_grammar - sequence accepts only the before relation word and a non-negative margin
test "parseCheck sequence pins the relation word" {
    const alloc = std.testing.allocator;
    const nodes = try parser_mod.parse(
        alloc,
        "(check (sequence (pin \"VDD\") before (pin \"VDDIO\") (margin-ms 5)))",
    );
    defer parser_mod.freeNodes(alloc, nodes);
    const chk = parseCheck(alloc, nodes[0]).?;
    try std.testing.expectEqualStrings("VDD", chk.sequence.pin_a);
    try std.testing.expectEqualStrings("VDDIO", chk.sequence.pin_b);
    try std.testing.expectApproxEqAbs(@as(f64, 5), chk.sequence.margin_ms, 1e-9);

    try expectRejected(alloc, "(check (sequence (pin \"VDD\") after (pin \"VDDIO\")))");
    try expectRejected(alloc, "(check (sequence (pin \"VDD\") before (pin \"VDDIO\") (margin-ms -1)))");
}

/// Parse `src` and assert `parseCheck` refuses it — the shared shape of every
/// grammar rejection case above.
fn expectRejected(alloc: std.mem.Allocator, src: []const u8) !void {
    const nodes = try parser_mod.parse(alloc, src);
    defer parser_mod.freeNodes(alloc, nodes);
    try std.testing.expect(parseCheck(alloc, nodes[0]) == null);
}
