//! Checks a component-family value string against the kind the family
//! declares with `(parameter "value" <kind>)`.
//!
//! A family like `cap-0402` declares `capacitance`; until this module existed
//! the kind was cached on `ComponentData.param_type` and never read, so
//! `(cap-0402 "4.7k")` built a 4.7 kΩ-labelled capacitor without a word.
//!
//! **The rule is deliberately one-sided.** A value is rejected only when it
//! positively parses as a *different* physical quantity — a number followed by
//! a unit/SI-prefix suffix that cannot belong to the declared kind. Anything
//! the parser cannot place (a bare number `10`, a sentinel `DNP`, a part
//! number `LFCN-400D+`, a frequency `100kHz`) is accepted in silence. That
//! keeps the check a wrong-kind detector rather than a value-spelling
//! grammar, so it cannot reject a legal value nobody thought to enumerate.
//!
//! Accepted shapes per declared kind (prefix = SI multiplier, unit = F/H/Ω):
//!
//! | kind                  | with a unit | bare prefix (no unit) |
//! |-----------------------|-------------|-----------------------|
//! | capacitance           | `…F`        | `f p n u m`  (`100n`) |
//! | inductance            | `…H`        | `p n u m`             |
//! | resistance, impedance | `…R`/`…Ω`   | `m k K M G` (`4.7k`)  |
//!
//! `milli` is plausible for every kind (a 5 mΩ shunt, a 1 mH choke), so it is
//! accepted everywhere rather than guessed at.

const std = @import("std");

/// The physical quantity a `(parameter "value" …)` word names. `unknown`
/// covers `string`, an absent kind word, and any future word — all of which
/// switch the check off rather than failing closed.
const Kind = enum { capacitance, resistance, inductance, unknown };

/// SI multiplier written as a single letter. `none` means the value carried a
/// unit with no prefix (`0R`, `100F`) or no suffix letters at all.
const Prefix = enum { none, femto, pico, nano, micro, milli, kilo, mega, giga, tera };

/// The physical unit letter. `none` means the suffix was a bare SI prefix
/// (`4.7k`, `100n`) — idiomatic in schematics and the reason the prefix alone
/// has to carry the classification.
const Unit = enum { none, farad, henry, ohm };

/// A value's suffix decoded into (prefix, unit). `null` from `parseSuffix`
/// means "not decodable", which the caller reads as "accept".
const Shape = struct { prefix: Prefix, unit: Unit };

/// Map a `(parameter "value" <word>)` word to the quantity it names.
/// `impedance` (ferrite beads, declared `600R@100MHz`) is an ohm value and
/// shares the resistance rule.
fn fromParamType(param_type: []const u8) Kind {
    if (std.mem.eql(u8, param_type, "capacitance")) return .capacitance;
    if (std.mem.eql(u8, param_type, "resistance")) return .resistance;
    if (std.mem.eql(u8, param_type, "impedance")) return .resistance;
    if (std.mem.eql(u8, param_type, "inductance")) return .inductance;
    return .unknown;
}

/// True when `value` may be written for a family declaring `param_type`.
/// False is the only signal that warrants an error; see the module header for
/// why silence is the default.
pub fn accepts(param_type: []const u8, value: []const u8) bool {
    const kind = fromParamType(param_type);
    if (kind == .unknown) return true;
    const shape = parseSuffix(magnitudeSuffix(value) orelse return true) orelse return true;
    return shapeFits(kind, shape);
}

/// Does a decoded suffix belong to `kind`? The unit letter decides on its own
/// when there is one; a bare SI prefix is judged by whether that magnitude is
/// ever written for the quantity.
fn shapeFits(kind: Kind, shape: Shape) bool {
    if (shape.unit != .none) return switch (kind) {
        .capacitance => shape.unit == .farad,
        .inductance => shape.unit == .henry,
        .resistance => shape.unit == .ohm,
        .unknown => true,
    };
    return switch (kind) {
        .capacitance => switch (shape.prefix) {
            .femto, .pico, .nano, .micro, .milli => true,
            else => false,
        },
        .inductance => switch (shape.prefix) {
            .pico, .nano, .micro, .milli => true,
            else => false,
        },
        .resistance => switch (shape.prefix) {
            .milli, .kilo, .mega, .giga, .tera => true,
            else => false,
        },
        .unknown => true,
    };
}

/// The suffix letters of the value's magnitude token, or null when there is
/// nothing to classify. Three normalizations happen here, each one a spelling
/// the corpus actually uses:
///   * only the FIRST whitespace token counts — `"10uF 25V"` is a capacitor
///     with a voltage rating, not a voltage;
///   * a trailing `@frequency` is dropped — `"600R@100MHz"` is a bead;
///   * a letter used as a decimal point keeps only its letters — `"24R9"`.
fn magnitudeSuffix(value: []const u8) ?[]const u8 {
    var token = value;
    if (std.mem.indexOfAny(u8, token, " \t")) |sp| token = token[0..sp];
    if (std.mem.indexOfScalar(u8, token, '@')) |at| token = token[0..at];
    const after_digits = skipMagnitude(token) orelse return null;
    const letters = std.mem.trimEnd(u8, after_digits, "0123456789");
    return if (letters.len == 0) null else letters;
}

/// Consume `[+-]?digits[.digits]` off the front of `token` and return the
/// rest. Null when the token does not start with a number at all, which is
/// how sentinels (`DNP`), colours (`green`) and part numbers opt out.
fn skipMagnitude(token: []const u8) ?[]const u8 {
    var i: usize = 0;
    if (i < token.len and (token[i] == '+' or token[i] == '-')) i += 1;
    const digits_start = i;
    while (i < token.len and std.ascii.isDigit(token[i])) i += 1;
    if (i < token.len and token[i] == '.') {
        i += 1;
        while (i < token.len and std.ascii.isDigit(token[i])) i += 1;
    }
    if (i == digits_start) return null;
    return token[i..];
}

/// Decode a letters-only suffix into (prefix, unit). Null whenever the letters
/// are not an SI prefix and/or a unit — `"Hz"`, `"V"`, `"mm"`, `"ppm"` all
/// land here and switch the check off for that value.
fn parseSuffix(raw: []const u8) ?Shape {
    if (stripMicro(raw)) |rest| {
        if (rest.len == 0) return .{ .prefix = .micro, .unit = .none };
        if (rest.len == 1) return .{ .prefix = .micro, .unit = unitOf(rest[0]) orelse return null };
        return null;
    }
    const suffix = if (std.mem.eql(u8, raw, "\u{03a9}")) "R" else raw;
    if (std.ascii.eqlIgnoreCase(suffix, "ohm") or std.ascii.eqlIgnoreCase(suffix, "ohms"))
        return .{ .prefix = .none, .unit = .ohm };
    if (suffix.len == 1) {
        if (unitOf(suffix[0])) |u| return .{ .prefix = .none, .unit = u };
        if (prefixOf(suffix[0])) |p| return .{ .prefix = p, .unit = .none };
        return null;
    }
    if (suffix.len != 2) return null;
    const p = prefixOf(suffix[0]) orelse return null;
    return .{ .prefix = p, .unit = unitOf(suffix[1]) orelse return null };
}

/// What follows a leading micro sign, for either of its two Unicode
/// spellings (MICRO SIGN and GREEK SMALL LETTER MU, both two UTF-8 bytes).
/// Null when the suffix does not start with one.
fn stripMicro(raw: []const u8) ?[]const u8 {
    inline for ([_][]const u8{ "\u{00b5}", "\u{03bc}" }) |sign| {
        if (std.mem.startsWith(u8, raw, sign)) return raw[sign.len..];
    }
    return null;
}

/// The unit a single letter names. `f` is read as farad here because the
/// femto-prefix reading only ever occurs in a two-letter suffix (`fF`), where
/// this function sees the second letter instead.
fn unitOf(c: u8) ?Unit {
    return switch (c) {
        'F', 'f' => .farad,
        'H', 'h' => .henry,
        'R', 'r' => .ohm,
        else => null,
    };
}

/// The SI multiplier a single letter names. Case is load-bearing: `M` is mega
/// and `m` is milli, while `K` and `k` both spell kilo because designs use
/// both (`100K`, `10k`).
fn prefixOf(c: u8) ?Prefix {
    return switch (c) {
        'f' => .femto,
        'p' => .pico,
        'n' => .nano,
        'u' => .micro,
        'm' => .milli,
        'k', 'K' => .kilo,
        'M' => .mega,
        'G' => .giga,
        'T' => .tera,
        else => null,
    };
}

/// The diagnostic for a rejected value: the family, the value it was given,
/// and the kind word the family's `(parameter "value" …)` declares. Allocated
/// (never freed — project memory convention); falls back to a static line if
/// the allocation fails.
pub fn mismatchMessage(
    allocator: std.mem.Allocator,
    family: []const u8,
    param_type: []const u8,
    value: []const u8,
) []const u8 {
    return std.fmt.allocPrint(
        allocator,
        "({s} \"{s}\") — \"{s}\" is not a {s} value; {s} declares (parameter \"value\" {s})",
        .{ family, value, value, param_type, family, param_type },
    ) catch "component value does not match the kind its family declares";
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// Assert every value in `values` is accepted for `param_type`.
fn expectAllAccepted(param_type: []const u8, values: []const []const u8) !void {
    for (values) |v| try testing.expect(accepts(param_type, v));
}

/// Assert every value in `values` is rejected for `param_type`.
fn expectAllRejected(param_type: []const u8, values: []const []const u8) !void {
    for (values) |v| try testing.expect(!accepts(param_type, v));
}

// spec: eval/value-kind - every value spelling the design corpus passes to a typed family is accepted
test "corpus value spellings are accepted" {
    try expectAllAccepted("capacitance", &.{ "100nF", "1uF", "4.7uF", "0.01uF", "1000pF", "61.9pF", "0.1pF", "10uF 25V", "1nF 2kV", "DNP", "100n", "10p", "4.7\u{00b5}F", "1\u{03bc}F" });
    try expectAllAccepted("resistance", &.{ "4.7k", "33R", "0R", "1M", "10", "100k", "100K", "24R9", "61R9", "11.5R", "5m", "0.01", "300", "49.9R", "1K" });
    try expectAllAccepted("inductance", &.{ "0.47uH", "1.5nH", "330nH", "10uH", "82nH", "900nH" });
    try expectAllAccepted("impedance", &.{ "120R", "1K", "220R@100MHz", "2.2k", "600R" });
    // Untyped families keep taking anything.
    try expectAllAccepted("string", &.{ "green", "LFCN-400D+", "4.7k" });
    try expectAllAccepted("", &.{ "jumper", "" });
}

// spec: eval/value-kind - a value carrying another quantity's unit or magnitude is rejected for the declared kind
test "wrong-kind values are rejected" {
    try expectAllRejected("capacitance", &.{ "4.7k", "10R", "1uH", "1M" });
    try expectAllRejected("resistance", &.{ "100nF", "100n", "4.7uH", "10p" });
    try expectAllRejected("inductance", &.{ "10uF", "10k", "100R" });
    try expectAllRejected("impedance", &.{ "100nF", "1uH" });
}

// spec: eval/value-kind - a value the unit decoder cannot place is accepted rather than guessed at
test "undecodable values opt out of the check" {
    const opaque_values = [_][]const u8{ "DNP", "jumper", "", "10", "0.01", "100kHz", "2N7002", "1206", "25V", "NC", "?" };
    try expectAllAccepted("capacitance", &opaque_values);
    try expectAllAccepted("resistance", &opaque_values);
    try expectAllAccepted("inductance", &opaque_values);
}
