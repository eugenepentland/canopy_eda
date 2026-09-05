//! The typed-attribute vocabulary of a component-family instantiation.
//!
//! A family call carries a value plus trailing attributes:
//!
//! ```
//! (cap-0402 "1uF" x7r "10%" "25V")                       ; bare
//! (cap-0402 "1uF" (dielectric x7r) (tolerance 10%) (rating 25V))  ; keyed
//! ```
//!
//! Both spellings mean the same thing and this module is what makes that true.
//! It maps a keyed sub-form's head (`rating`, `voltage`, `dielectric`, …) and
//! an unkeyed attribute's TEXT (`"25V"`, `x7r`, `"10%"`) onto the same small
//! set of `Slot`s, each of which owns exactly one instance property key.
//!
//! Why one owner matters: before this existed, an authored `"25V"` was inert
//! text in `Instance.attrs`, and every consumer that wanted the rating
//! re-derived it with its own regex — `req_physical_checks.capVoltageRating`
//! scanned for a volts-shaped attribute, `pll_loop.toleranceFor` scanned for a
//! `%`-shaped one, the parts table matched on raw strings, and the KiCad export
//! saw none of it. Each had its own idea of which spellings counted. Landing
//! the classified value on `Instance.properties` gives all of them one source
//! and leaves the regexes as the fallback for attributes nothing can place.
//!
//! Classification is deliberately CONSERVATIVE, for the same reason
//! `value_kind` is one-sided: an attribute is claimed only when its shape
//! cannot be anything else. `DNP`, `green`, `jumper`, `tantalum`,
//! `rf-termination`, `600R@100MHz`, `100MHz` all stay raw attributes and reach
//! the schematic and the parts table exactly as they did before.

const std = @import("std");
const tokenizer = @import("../sexpr/tokenizer.zig");

/// One typed attribute slot. Names follow the `lib/parts/*.sexp` column they
/// select on (`voltage`, `dielectric`, `tolerance`, `power`, `current`) so a
/// design and a parts row talk about a rating with the same word; `tempco`,
/// `esr` and `esl` are analysis inputs with no selection column of their own.
pub const Slot = enum {
    voltage,
    dielectric,
    tolerance,
    power,
    current,
    tempco,
    esr,
    esl,

    /// The `Instance.properties` key this slot owns. This is THE spelling
    /// every consumer reads; a slot with a different property key would
    /// re-create the many-readers-many-spellings problem the slots exist to
    /// remove.
    pub fn propertyKey(self: Slot) []const u8 {
        return @tagName(self);
    }

    /// True when a parts-table row can be selected on this slot. Selection
    /// columns also stay in `Instance.attrs` so `PartsDb.lookup` narrows on a
    /// keyed attribute exactly as it does on the bare spelling; `esr`/`esl`
    /// are model overrides that no row is keyed by, and adding them to `attrs`
    /// would make `lookupStrict` reject every row and fail the fab gate.
    pub fn isSelectionColumn(self: Slot) bool {
        return switch (self) {
            .voltage, .dielectric, .tolerance, .power, .current, .tempco => true,
            .esr, .esl => false,
        };
    }
};

/// One accepted keyed spelling and the slot it names. Several spellings may
/// share a slot: `(rating 25V)` is the human phrasing and `(voltage "25V")`
/// the parts-column phrasing, and both must work because a design reads
/// better with one and diffs against the library better with the other.
pub const KeyedSpelling = struct { key: []const u8, slot: Slot };

/// Every keyed attribute sub-form head this language accepts. Single source
/// of truth for evaluation, the did-you-mean suggestion, and the generated
/// language reference.
pub const keyed_spellings = [_]KeyedSpelling{
    .{ .key = "rating", .slot = .voltage },
    .{ .key = "voltage", .slot = .voltage },
    .{ .key = "dielectric", .slot = .dielectric },
    .{ .key = "tolerance", .slot = .tolerance },
    .{ .key = "power", .slot = .power },
    .{ .key = "current", .slot = .current },
    .{ .key = "tempco", .slot = .tempco },
    .{ .key = "tcr", .slot = .tempco },
    .{ .key = "esr", .slot = .esr },
    .{ .key = "esl", .slot = .esl },
};

/// The accepted keyed spellings as one comma-separated line, for the
/// diagnostic that lists them when a typo is too far off to suggest.
pub const key_list: []const u8 = blk: {
    var line: []const u8 = "";
    for (keyed_spellings, 0..) |spelling, index| {
        line = line ++ (if (index > 0) ", " else "") ++ spelling.key;
    }
    break :blk line;
};

/// The slot a keyed attribute sub-form names, or null when the head is not a
/// known attribute key at all (the caller then reports it with `suggestKey`).
pub fn slotForKey(key: []const u8) ?Slot {
    for (keyed_spellings) |spelling| {
        if (std.ascii.eqlIgnoreCase(spelling.key, key)) return spelling.slot;
    }
    return null;
}

/// The `lib/parts/*.sexp` column spellings a slot is selected on, in the order
/// a row is searched. More than one spelling exists where the library grew two
/// names for one rating (`tempco` and the older `tcr`, `current` and
/// `rated-current`); an empty list means the slot has no selection column, so
/// no row can agree or disagree with it.
pub fn rowColumns(slot: Slot) []const []const u8 {
    return switch (slot) {
        .voltage => &.{"voltage"},
        .dielectric => &.{"dielectric"},
        .tolerance => &.{"tolerance"},
        .power => &.{"power"},
        .current => &.{ "current", "rated-current" },
        .tempco => &.{ "tempco", "tcr" },
        .esr, .esl => &.{},
    };
}

/// The dielectric codes a ceramic capacitor is authored with. EIA class-II
/// temperature characteristics plus the two class-I spellings (`np0` is the
/// industry name, `c0g` the EIA one) — a closed vocabulary, which is why a
/// bare `x7r` can be claimed with no ambiguity.
pub const dielectric_codes = [_][]const u8{
    "np0", "c0g", "x5r", "x6s", "x7r", "x7s", "x8r", "x8l", "y5v", "z5u",
};

/// The slot an UNKEYED attribute belongs to, or null to leave it a raw
/// attribute. Only shapes that can mean one thing are claimed:
///
///   * `x7r`, `np0`, …            → dielectric (closed vocabulary)
///   * `10%`, `0.1%`, `±15%`      → tolerance
///   * `25V`, `6.3V`, `150 V`     → voltage
///   * `0.063W`, `250mW`          → power
///   * `1A`, `0.3A`, `250mA`      → current
///   * `25ppm/C`, `100ppm`        → tempco
///
/// Everything else — a sentinel (`DNP`), an LED colour (`green`), a process
/// word (`jumper`, `tantalum`), a frequency (`100MHz`), a bead's
/// `600R@100MHz` — returns null and is untouched.
pub fn classify(text: []const u8) ?Slot {
    const trimmed = std.mem.trim(u8, text, " \t");
    if (trimmed.len == 0) return null;
    for (dielectric_codes) |code| {
        if (std.ascii.eqlIgnoreCase(code, trimmed)) return .dielectric;
    }
    const rest = afterMagnitude(trimmed) orelse return null;
    const unit = std.mem.trim(u8, rest, " \t");
    if (unit.len == 0) return null;
    if (std.mem.eql(u8, unit, "%")) return .tolerance;
    if (isTempcoUnit(unit)) return .tempco;
    if (std.ascii.eqlIgnoreCase(unit, "V") or std.ascii.eqlIgnoreCase(unit, "mV") or
        std.mem.eql(u8, unit, "kV")) return .voltage;
    if (std.ascii.eqlIgnoreCase(unit, "W") or std.mem.eql(u8, unit, "mW")) return .power;
    if (std.mem.eql(u8, unit, "A") or std.mem.eql(u8, unit, "mA") or
        std.mem.eql(u8, unit, "uA")) return .current;
    return null;
}

/// A temperature-coefficient unit: `ppm`, `ppm/C`, `ppm/°C`, `ppm/K`. Case
/// matters only on the `ppm` stem; the `/C` tail is optional because designs
/// write both.
fn isTempcoUnit(unit: []const u8) bool {
    if (unit.len < 3) return false;
    if (!std.ascii.eqlIgnoreCase(unit[0..3], "ppm")) return false;
    const tail = unit[3..];
    if (tail.len == 0) return true;
    if (tail[0] != '/') return false;
    const degree = std.mem.trimStart(u8, tail[1..], "\u{00b0}");
    return std.ascii.eqlIgnoreCase(degree, "C") or std.ascii.eqlIgnoreCase(degree, "K");
}

/// What follows the numeric magnitude of `text`, or null when `text` does not
/// begin with a number. A leading `±` (either the two-byte UTF-8 sign or a
/// bare `+`/`-`) is a tolerance's own decoration and is skipped first.
fn afterMagnitude(text: []const u8) ?[]const u8 {
    var i: usize = 0;
    if (std.mem.startsWith(u8, text, "\u{00b1}")) i += "\u{00b1}".len;
    if (i < text.len and (text[i] == '+' or text[i] == '-')) i += 1;
    const digits_start = i;
    while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
    if (i < text.len and text[i] == '.') {
        i += 1;
        while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
    }
    if (i == digits_start) return null;
    return text[i..];
}

/// The known key closest to `key`, or null when nothing is close enough to be
/// worth suggesting. Bounded edit distance: a typo is one or two keystrokes
/// off, and suggesting `esl` for `dielectric` would be noise.
pub fn suggestKey(key: []const u8) ?[]const u8 {
    var best: ?[]const u8 = null;
    var best_distance: usize = std.math.maxInt(usize);
    for (keyed_spellings) |spelling| {
        const distance = editDistance(spelling.key, key);
        if (distance < best_distance) {
            best_distance = distance;
            best = spelling.key;
        }
    }
    const budget: usize = if (key.len <= 4) 1 else 2;
    return if (best_distance <= budget) best else null;
}

/// Levenshtein distance over two short ASCII keys, case-insensitive. Bounded
/// by the vocabulary above (longest key is 10 chars), so the fixed row buffer
/// cannot overflow — a longer candidate simply reports "far away".
fn editDistance(a: []const u8, b: []const u8) usize {
    const max_key_len = 16;
    if (a.len >= max_key_len or b.len >= max_key_len) return std.math.maxInt(usize);
    var previous: [max_key_len]usize = undefined;
    var current: [max_key_len]usize = undefined;
    for (0..b.len + 1) |j| previous[j] = j;
    for (a, 0..) |ac, i| {
        current[0] = i + 1;
        for (b, 0..) |bc, j| {
            const substitution = previous[j] + @intFromBool(std.ascii.toLower(ac) != std.ascii.toLower(bc));
            const deletion = previous[j + 1] + 1;
            const insertion = current[j] + 1;
            current[j + 1] = @min(substitution, @min(deletion, insertion));
        }
        @memcpy(previous[0 .. b.len + 1], current[0 .. b.len + 1]);
    }
    return previous[b.len];
}

/// The PDN model property a slot feeds, plus the SI value in base units, or
/// null when the slot has no model column or the text is not decodable.
/// `(esr 10mR)` therefore reaches `placement/pdn_impedance` as the number it
/// already reads (`pdn-esr-ohm`) rather than as a second spelling nobody
/// taught it.
pub const ModelProperty = struct { key: []const u8, value: f64 };

pub fn modelProperty(slot: Slot, text: []const u8) ?ModelProperty {
    const key = switch (slot) {
        .esr => "pdn-esr-ohm",
        .esl => "pdn-esl-h",
        else => return null,
    };
    const value = siValue(text) orelse return null;
    if (!(std.math.isFinite(value) and value > 0)) return null;
    return .{ .key = key, .value = value };
}

/// Decode `10mR` / `0.4nH` / `25V` / `0.05` into its base-unit magnitude, or
/// null when the suffix is not a scale-and-unit shape this can read.
///
/// The shape rule matches the tokenizer's: an optional scale letter followed
/// by at most one unit letter. Anything longer (`ppm/C`, `ohm`, `MHz`) returns
/// null rather than reading its first letter as a scale — `100ppm/C` decoded
/// as "100 pico" would make every tempco comparison nonsense.
fn siValue(text: []const u8) ?f64 {
    const trimmed = std.mem.trim(u8, text, " \t");
    const rest = afterMagnitude(trimmed) orelse return null;
    const magnitude = std.fmt.parseFloat(f64, trimmed[0 .. trimmed.len - rest.len]) catch return null;
    const suffix = std.mem.trim(u8, rest, " \t");
    if (suffix.len == 0) return magnitude;
    // `ppm` is a unit of its own — parts-per-million, already dimensionless —
    // so a tempco decodes to its bare magnitude and two of them compare. It is
    // tested BEFORE the scale table because `ppm` starts with `p`, and reading
    // that as pico is exactly the nonsense this function must not produce.
    if (isTempcoUnit(suffix)) return magnitude;
    // `K` folds to `k` for the same reason `value_kind` accepts both: designs
    // write `100K` and `10k` interchangeably.
    const head = if (suffix[0] == 'K') 'k' else suffix[0];
    const scale: ?f64 = for (tokenizer.si_scales) |entry| {
        if (entry.letter == head) break entry.multiplier;
    } else null;
    if (scale) |multiplier| {
        if (suffix.len == 1) return magnitude * multiplier;
        if (suffix.len == 2 and isUnitLetter(suffix[1])) return magnitude * multiplier;
        return null;
    }
    if (suffix.len == 1 and (isUnitLetter(suffix[0]) or suffix[0] == tokenizer.percent_sign)) return magnitude;
    return null;
}

/// A unit letter for ATTRIBUTE decoding: the tokenizer's literal set plus
/// `W`. No numeric literal spells watts (`0.063W` is a quoted attribute, not a
/// token), but a `(power …)` rating is written that way and has to decode or
/// the power comparison silently passes everything.
fn isUnitLetter(c: u8) bool {
    if (std.ascii.toUpper(c) == 'W') return true;
    return std.mem.indexOfScalar(u8, tokenizer.si_unit_letters, std.ascii.toUpper(c)) != null;
}

/// Does the rating a `lib/parts/` row carries meet what the design asked for?
///
/// Not equality — a row is allowed to be BETTER. A 50 V part where 25 V was
/// asked, a 1% resistor where 5% was asked, a 0.1 W part where 0.063 W was
/// asked: all satisfy the requirement, and reporting them would bury the one
/// case that matters under noise nobody would read.
///
/// Two shapes are never satisfied by a different value: `dielectric` is
/// categorical (an x5r is not a worse x7r, it is a different part, with a
/// different capacitance-vs-bias curve), and a rating neither side can decode
/// is left alone rather than guessed at.
pub fn satisfies(slot: Slot, authored: []const u8, selected: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, authored, " \t"), std.mem.trim(u8, selected, " \t"))) return true;
    if (slot == .dielectric) return false;
    const want = siValue(authored) orelse return true;
    const got = siValue(selected) orelse return true;
    return switch (slot) {
        // A headroom rating: more is better.
        .voltage, .power, .current => got >= want,
        // A deviation budget: less is better. `dielectric` never reaches this
        // arm (it returned above) and is listed only to keep the switch total.
        .tolerance, .tempco, .esr, .esl, .dielectric => got <= want,
    };
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: eval/attrs - Bare component-family attributes classify into typed slots and leave unplaceable spellings raw
test "bare attribute classification table" {
    // A null slot means "leave it a raw attribute" — every one of those rows
    // is a spelling the corpus actually writes on a family call today.
    const table = [_]struct { text: []const u8, slot: ?Slot }{
        .{ .text = "25V", .slot = .voltage },
        .{ .text = "50V", .slot = .voltage },
        .{ .text = "6.3V", .slot = .voltage },
        .{ .text = "25 V", .slot = .voltage },
        .{ .text = "10%", .slot = .tolerance },
        .{ .text = "0.1%", .slot = .tolerance },
        .{ .text = "\u{00b1}15%", .slot = .tolerance },
        .{ .text = "x5r", .slot = .dielectric },
        .{ .text = "X7R", .slot = .dielectric },
        .{ .text = "np0", .slot = .dielectric },
        .{ .text = "c0g", .slot = .dielectric },
        .{ .text = "x6s", .slot = .dielectric },
        .{ .text = "y5v", .slot = .dielectric },
        .{ .text = "0.063W", .slot = .power },
        .{ .text = "250mW", .slot = .power },
        .{ .text = "25ppm/C", .slot = .tempco },
        .{ .text = "100ppm", .slot = .tempco },
        .{ .text = "1A", .slot = .current },
        .{ .text = "0.3A", .slot = .current },
        .{ .text = "DNP", .slot = null },
        .{ .text = "green", .slot = null },
        .{ .text = "jumper", .slot = null },
        .{ .text = "tantalum", .slot = null },
        .{ .text = "rf-termination", .slot = null },
        .{ .text = "ultra-broadband-ceramic", .slot = null },
        .{ .text = "100MHz", .slot = null },
        .{ .text = "600R@100MHz", .slot = null },
        .{ .text = "0.2ohm", .slot = null },
        .{ .text = "5m", .slot = null },
        .{ .text = "1uF", .slot = null },
        .{ .text = "0R", .slot = null },
        .{ .text = "", .slot = null },
    };
    for (table) |row| try testing.expectEqual(row.slot, classify(row.text));
}

// spec: eval/attrs - Keyed attribute heads resolve to their slot and an unknown key gets a did-you-mean suggestion
test "keyed attribute spellings and suggestions" {
    try testing.expectEqual(Slot.voltage, slotForKey("rating").?);
    try testing.expectEqual(Slot.voltage, slotForKey("voltage").?);
    try testing.expectEqual(Slot.tempco, slotForKey("tcr").?);
    try testing.expectEqual(Slot.esl, slotForKey("esl").?);
    try testing.expectEqual(@as(?Slot, null), slotForKey("colour"));

    try testing.expectEqualStrings("voltage", suggestKey("voltag").?);
    try testing.expectEqualStrings("tolerance", suggestKey("tolerence").?);
    try testing.expectEqualStrings("esr", suggestKey("est").?);
    try testing.expectEqual(@as(?[]const u8, null), suggestKey("manufacturer"));
}

// spec: eval/attrs - Only parts-table selection slots stay in the raw attribute list and esr/esl decode into their PDN model properties
test "selection columns and model properties" {
    try testing.expect(Slot.voltage.isSelectionColumn());
    try testing.expect(Slot.tempco.isSelectionColumn());
    try testing.expect(!Slot.esr.isSelectionColumn());
    try testing.expect(!Slot.esl.isSelectionColumn());
    try testing.expectEqualStrings("dielectric", Slot.dielectric.propertyKey());

    const esr = modelProperty(.esr, "10mR").?;
    try testing.expectEqualStrings("pdn-esr-ohm", esr.key);
    try testing.expectApproxEqRel(@as(f64, 0.01), esr.value, 1e-12);
    const esl = modelProperty(.esl, "0.4nH").?;
    try testing.expectEqualStrings("pdn-esl-h", esl.key);
    try testing.expectApproxEqRel(@as(f64, 4e-10), esl.value, 1e-12);
    try testing.expectEqual(@as(?ModelProperty, null), modelProperty(.voltage, "25V"));
}

// spec: eval/attrs - A selected rating satisfies an authored one when it is at least as good, and a different dielectric never is
test "a row rating satisfies an authored one only when it is no worse" {
    // Spelling alone is never a disagreement.
    try testing.expect(satisfies(.voltage, "25V", "25 V"));
    try testing.expect(satisfies(.voltage, "25V", "25.0V"));
    try testing.expect(satisfies(.dielectric, "X7R", "x7r"));
    // Headroom ratings: more is fine, less is not.
    try testing.expect(satisfies(.voltage, "25V", "50V"));
    try testing.expect(!satisfies(.voltage, "50V", "25V"));
    try testing.expect(satisfies(.power, "0.063W", "0.1W"));
    try testing.expect(!satisfies(.power, "0.1W", "63mW"));
    try testing.expect(!satisfies(.current, "1A", "0.3A"));
    // Deviation budgets: tighter is fine, looser is not.
    try testing.expect(satisfies(.tolerance, "10%", "1%"));
    try testing.expect(!satisfies(.tolerance, "1%", "10%"));
    try testing.expect(!satisfies(.tempco, "25ppm/C", "100ppm/C"));
    try testing.expect(satisfies(.tempco, "100ppm/C", "25ppm"));
    // A different dielectric is never satisfied, and a rating neither side can
    // decode is left alone rather than guessed at.
    try testing.expect(!satisfies(.dielectric, "x7r", "x5r"));
    try testing.expect(satisfies(.voltage, "25V", "see datasheet"));
}
