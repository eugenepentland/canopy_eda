//! Name sanitising and uniqueness for the firmware / simulator exporters.
//!
//! `export-pinmap` writes C preprocessor macros and `export-spice` writes SPICE
//! node and element names, and neither target accepts the characters a design
//! is entitled to use: a hierarchical ref-des carries `/`, a per-pin bypass
//! stub carries `.`, a rail is called `+3V3` or `3.3V`. Both exporters
//! therefore fold a design name down to `[A-Za-z0-9_]`, and both then face the
//! SAME hazard — folding is many-to-one, so `usb/DP` and `usb.DP` land on the
//! identical spelling and one silently overwrites the other's macro (or, in
//! SPICE, shorts two nets together).
//!
//! One `Table` per output stream is what makes that impossible: a candidate
//! already held by a different design name is suffixed `_2`, `_3`, … in the
//! order the exporter offered it, and the collision is reported so the exporter
//! can print it into the file. Both exporters sort their rows before assigning,
//! so the suffixes — and therefore the whole file — are deterministic.
//!
//! Nothing here knows what a pin map or a netlist is; it is string work only,
//! which is why it can be shared by two exporters that have nothing else in
//! common.

const std = @import("std");

const Allocator = std.mem.Allocator;

/// The letter case a sanitised fragment is folded to.
///
/// C macros and SPICE names both use `upper` — SPICE is case-insensitive, so
/// folding one way is what lets a plain string comparison detect a collision
/// the simulator would see. `lower` spells the C table identifiers, which are
/// ordinary variables rather than macros.
pub const Style = enum { upper, lower };

/// The replacement character every byte outside `[A-Za-z0-9_]` folds to.
const separator: u8 = '_';

/// What a fragment that sanitises to nothing at all becomes, so a nameless
/// row still produces a legal identifier rather than an empty one.
const empty_fragment = "X";

/// Prefixed to a fragment that would otherwise start with a digit (`3V3`),
/// which is legal in neither C nor SPICE. A leading `_` would be legal C but
/// is reserved at file scope, so a letter is used instead.
const digit_guard: u8 = 'N';

/// Fold `raw` into a `[A-Za-z0-9_]` fragment under `style`.
///
/// Every byte outside the alphabet becomes `_`, runs of `_` collapse to one,
/// leading and trailing `_` are trimmed, an empty result becomes `X`, and a
/// leading digit is prefixed with `N`. The result is a legal C identifier and a
/// legal SPICE name on its own, and is safe to concatenate with `_` between
/// fragments. Allocated on `arena`.
pub fn sanitize(arena: Allocator, style: Style, raw: []const u8) Allocator.Error![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (raw) |c| {
        const mapped = mapByte(style, c);
        if (mapped == separator and dropSeparator(buf.items)) continue;
        try buf.append(arena, mapped);
    }
    while (buf.items.len > 0 and buf.items[buf.items.len - 1] == separator) _ = buf.pop();
    if (buf.items.len == 0) try buf.appendSlice(arena, empty_fragment);
    if (std.ascii.isDigit(buf.items[0])) try buf.insert(arena, 0, digit_guard);
    return buf.items;
}

/// One byte's folded spelling: kept (in `style`'s case) when it is already in
/// the alphabet, and `_` otherwise.
fn mapByte(style: Style, c: u8) u8 {
    if (!std.ascii.isAlphanumeric(c) and c != separator) return separator;
    return switch (style) {
        .upper => std.ascii.toUpper(c),
        .lower => std.ascii.toLower(c),
    };
}

/// Whether a separator arriving after `s` should be dropped rather than
/// appended: nothing has been written yet (so it would be a LEADING separator)
/// or the last byte is already one (so it would start a run).
fn dropSeparator(s: []const u8) bool {
    return s.len == 0 or s[s.len - 1] == separator;
}

/// The spelling a raw name was given, and the raw name it had to be moved off.
pub const Assignment = struct {
    /// The unique spelling to write into the exported file.
    name: []const u8,
    /// The design name that already owned the unsuffixed candidate, or null
    /// when the candidate was free. Exporters print this so a reader of the
    /// output can see WHY a name is spelled `FOO_2`.
    collided_with: ?[]const u8 = null,
};

/// The set of names one output stream has already handed out.
///
/// Keyed both ways on purpose: `by_raw` makes the assignment stable (the same
/// net asked for twenty pads answers with one spelling), and `by_name` is what
/// detects that two different design names folded together.
pub const Table = struct {
    by_raw: std.StringHashMapUnmanaged([]const u8) = .empty,
    by_name: std.StringHashMapUnmanaged([]const u8) = .empty,

    /// Claim `candidate` for `raw`, suffixing `_2`, `_3`, … until the spelling
    /// is free. Asking twice for one `raw` returns the first answer, so a name
    /// used on many rows is spelled identically on all of them. Allocations
    /// (the suffixed spellings and the map storage) are on `arena`.
    pub fn unique(
        self: *Table,
        arena: Allocator,
        raw: []const u8,
        candidate: []const u8,
    ) Allocator.Error!Assignment {
        if (self.by_raw.get(raw)) |existing| return .{ .name = existing };
        var name = candidate;
        var collided: ?[]const u8 = null;
        var attempt: usize = 2;
        while (self.by_name.get(name)) |owner| {
            collided = owner;
            name = try std.fmt.allocPrint(arena, "{s}_{d}", .{ candidate, attempt });
            attempt += 1;
        }
        try self.by_raw.put(arena, raw, name);
        try self.by_name.put(arena, name, raw);
        return .{ .name = name, .collided_with = collided };
    }
};

/// Order two pad ids the way a datasheet lists them: digit runs compare as
/// numbers, everything else byte for byte. Without it `10` sorts before `2`
/// and a QFN's pad list reads scrambled, while a BGA's `A1 … A19 B1` order —
/// which is a letter run followed by a digit run — comes out right either way.
/// Suitable as a `std.mem.sort` comparator.
pub fn padLessThan(_: void, a: []const u8, b: []const u8) bool {
    return padOrder(a, b) == .lt;
}

/// The natural-order comparison `padLessThan` reports the `.lt` half of.
fn padOrder(a: []const u8, b: []const u8) std.math.Order {
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len and j < b.len) {
        if (std.ascii.isDigit(a[i]) and std.ascii.isDigit(b[j])) {
            const ra = digitRunEnd(a, i);
            const rb = digitRunEnd(b, j);
            const numeric = numericOrder(a[i..ra], b[j..rb]);
            if (numeric != .eq) return numeric;
            i = ra;
            j = rb;
            continue;
        }
        if (a[i] != b[j]) return std.math.order(a[i], b[j]);
        i += 1;
        j += 1;
    }
    const remainder = std.math.order(a.len - i, b.len - j);
    if (remainder != .eq) return remainder;
    // Both ran out together and every run compared equal, so the ids differ (if
    // at all) only in leading zeros. Ordering the shorter spelling first keeps
    // the comparator TOTAL — without this `007` and `7` are mutually
    // not-less-than, which is the one shape `std.mem.sort` may not be given.
    return std.math.order(a.len, b.len);
}

/// The index one past the digit run starting at `from`.
fn digitRunEnd(s: []const u8, from: usize) usize {
    var k = from;
    while (k < s.len and std.ascii.isDigit(s[k])) k += 1;
    return k;
}

/// Compare two all-digit runs as numbers of unbounded width: leading zeros are
/// dropped, then the longer run is the larger and equal lengths compare
/// lexicographically. Done on the text so a 40-digit pad id cannot overflow.
fn numericOrder(a: []const u8, b: []const u8) std.math.Order {
    const ta = trimZeros(a);
    const tb = trimZeros(b);
    if (ta.len != tb.len) return std.math.order(ta.len, tb.len);
    return std.mem.order(u8, ta, tb);
}

/// A digit run with its leading zeros removed (`007` → `7`, `000` → ``).
fn trimZeros(s: []const u8) []const u8 {
    var k: usize = 0;
    while (k < s.len and s[k] == '0') k += 1;
    return s[k..];
}

// ── Tests ───────────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: export-names - a design name folds to a legal C and SPICE fragment, with separators collapsed, a leading digit guarded and an empty fold named
test "sanitize folds a design name into a legal identifier fragment" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    try testing.expectEqualStrings("USB_DP", try sanitize(arena, .upper, "usb/DP"));
    try testing.expectEqualStrings("usb_dp", try sanitize(arena, .lower, "usb/DP"));
    // A per-pin bypass stub and a hierarchical rail fold the same way, which is
    // exactly why `Table` has to exist.
    try testing.expectEqualStrings("VDD_U1_A3", try sanitize(arena, .upper, "VDD.U1.A3"));
    // Runs collapse and the ends are trimmed, so `+3V3 ` and `3V3` differ only
    // by the digit guard the leading digit forces.
    try testing.expectEqualStrings("N3V3", try sanitize(arena, .upper, "+3V3 "));
    try testing.expectEqualStrings("N3V3", try sanitize(arena, .upper, "3V3"));
    // A name with nothing left after folding still yields a legal identifier
    // rather than an empty one that would splice into `U1__PIN`.
    try testing.expectEqualStrings("X", try sanitize(arena, .upper, "///"));
    try testing.expectEqualStrings("X", try sanitize(arena, .upper, ""));
}

// spec: export-names - two design names that fold to one spelling are separated by a numeric suffix, the collision is reported, and one name keeps one spelling however often it is asked for
test "a name table separates folded collisions and answers stably" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var table: Table = .{};
    const first = try table.unique(arena, "usb/DP", "USB_DP");
    try testing.expectEqualStrings("USB_DP", first.name);
    try testing.expectEqual(@as(?[]const u8, null), first.collided_with);

    // A DIFFERENT design name folding onto the same spelling is moved, and the
    // name it collided with is reported so the exporter can say so in the file.
    const second = try table.unique(arena, "usb.DP", "USB_DP");
    try testing.expectEqualStrings("USB_DP_2", second.name);
    try testing.expectEqualStrings("usb/DP", second.collided_with.?);

    // A third collision keeps counting rather than reusing `_2`.
    try testing.expectEqualStrings("USB_DP_3", (try table.unique(arena, "USB DP", "USB_DP")).name);
    // …and asking again for a name already assigned answers identically, so a
    // net on twenty pads is spelled one way on all twenty.
    try testing.expectEqualStrings("USB_DP_2", (try table.unique(arena, "usb.DP", "USB_DP")).name);
}

// spec: export-names - pad ids sort in natural order so a numbered run reads 2 before 10 and a BGA row stays with its row letter
test "pad ids sort in natural order" {
    var pads = [_][]const u8{ "10", "2", "A19", "A2", "B1", "1", "007", "7" };
    std.mem.sort([]const u8, &pads, {}, padLessThan);
    const want = [_][]const u8{ "1", "2", "7", "007", "10", "A2", "A19", "B1" };
    // `007` and `7` are the same number, so their relative order is decided by
    // the total-length tie-break that keeps the comparator total, not by either
    // being numerically smaller.
    for (want, pads) |expected, got| try testing.expectEqualStrings(expected, got);
}

// spec: export-names - a digit run compares as a number of unbounded width, so a pad id longer than any integer type still orders correctly
test "digit runs compare as unbounded numbers" {
    // Forty-one digits: wider than any integer type, so a parse-then-compare
    // implementation would either overflow or silently wrap here.
    const big = "10000000000000000000000000000000000000000";
    const bigger = "20000000000000000000000000000000000000000";
    try testing.expect(padLessThan({}, big, bigger));
    try testing.expect(!padLessThan({}, bigger, big));
    // Leading zeros are not part of the number, and an equal number falls back
    // to the shorter spelling first so the order is total.
    try testing.expectEqual(std.math.Order.eq, numericOrder("007", "7"));
    try testing.expect(padLessThan({}, "7", "007"));
}
