//! The two pure string rules every decoupling-binding consumer needs, in one
//! place: the pad a `(decouple … per-pin …)` child encodes in its structural
//! origin key, and the capacitance a value string names.
//!
//! Both used to be copy-pasted — `pinFromOrigin` into the placement optimizer,
//! the ERC pass and the KiCad-schematic exporter; `capFarads` into
//! `placement/module_policy.zig`, then copied again into `erc.zig`, then a
//! third time into `kicad_sch/bank.zig` — each carrying a comment explaining
//! that the copy existed only to avoid an import. The reason those copies were
//! made is real: the ERC pass and the schematic exporter must not pull in the
//! placement optimizer, and eval must not depend on `src/placement/`. This
//! module keeps that layering by depending on **nothing but `std`**, so every
//! one of those consumers can import it without acquiring a direction it is not
//! allowed to have.
//!
//! Three copies of one parser is three chances for the bulk-cap threshold to be
//! read differently in the lint, the exporter and the solver — which is exactly
//! the class of drift the `10µF` micro-sign fix had to be applied to twice.

const std = @import("std");

/// Bulk-reservoir threshold: a cap at or above 4.7 µF serves the whole rail
/// rather than one pin, so it is exempt from the per-pin binding requirement
/// (ERC `decoupling_unbound`) and reads as `.bulk_cap` to the module-policy
/// role detector. A stable physical convention, not a tuning knob.
pub const bulk_farads: f64 = 4.7e-6;

/// The IC pad a `(decouple … per-pin …)` cap decouples, read from its structural
/// origin key `value@PAD#replica` (built in `builders.emitDecoupleItems`). Null
/// when the key has no `@PAD#` segment — a non-per-pin decouple (`value#replica`),
/// a function-name-spelled child (whose origin key is its readable label), or any
/// named part (whose origin key is the source name).
pub fn pinFromOrigin(origin_key: []const u8) ?[]const u8 {
    const at = std.mem.indexOfScalar(u8, origin_key, '@') orelse return null;
    const hash = std.mem.indexOfScalarPos(u8, origin_key, at + 1, '#') orelse return null;
    const pin = origin_key[at + 1 .. hash];
    return if (pin.len > 0) pin else null;
}

/// Parse a capacitance string ("100nF", "4.7uF", "10µF") to farads; 0 when it is
/// unrecognised. Accepts the UTF-8 micro sign `µ` (0xC2 0xB5) as a `u`-equivalent
/// so a hand-typed or imported "10µF" bulk cap still clears `bulk_farads` instead
/// of reading 0 F (an HF cap) and producing a build-failing false positive.
pub fn capFarads(s: []const u8) f64 {
    var i: usize = 0;
    while (i < s.len and (std.ascii.isDigit(s[i]) or s[i] == '.')) i += 1;
    if (i == 0) return 0;
    const num = std.fmt.parseFloat(f64, s[0..i]) catch return 0;
    if (i >= s.len) return 0;
    // UTF-8 `µ` (U+00B5, bytes 0xC2 0xB5) — the micro sign — reads as `u`.
    if (s[i] == 0xC2 and i + 1 < s.len and s[i + 1] == 0xB5) return num * 1e-6;
    const mult: f64 = switch (s[i]) {
        'p', 'P' => 1e-12,
        'n', 'N' => 1e-9,
        'u', 'U' => 1e-6,
        'm' => 1e-3,
        else => return 0,
    };
    return num * mult;
}

const testing = std.testing;

// spec: decouple_key - the per-pin origin key yields the host pad it encodes and nothing else does
test "pinFromOrigin reads value@PAD#replica and rejects every other key shape" {
    try testing.expectEqualStrings("24", pinFromOrigin("100nF@24#0").?);
    try testing.expectEqualStrings("J14", pinFromOrigin("100nF@J14#2").?);
    // A non-per-pin decouple child (`value#replica`) encodes no pad.
    try testing.expectEqual(@as(?[]const u8, null), pinFromOrigin("100nF#1"));
    // A named part's origin key is its source name.
    try testing.expectEqual(@as(?[]const u8, null), pinFromOrigin("C_VIN"));
    // A function-name-spelled per-pin child carries its readable label instead.
    try testing.expectEqual(@as(?[]const u8, null), pinFromOrigin("C_VDD_1"));
    // Degenerate keys never yield an empty pad.
    try testing.expectEqual(@as(?[]const u8, null), pinFromOrigin("100nF@#0"));
    try testing.expectEqual(@as(?[]const u8, null), pinFromOrigin("100nF@24"));
    try testing.expectEqual(@as(?[]const u8, null), pinFromOrigin(""));
}

// spec: decouple_key - capacitance strings parse to farads across SI prefixes and the UTF-8 micro sign
test "capFarads parses SI prefixes including the micro sign and the bulk threshold" {
    try testing.expectApproxEqAbs(@as(f64, 100e-9), capFarads("100nF"), 1e-18);
    try testing.expectApproxEqAbs(@as(f64, 10e-12), capFarads("10pF"), 1e-18);
    try testing.expectApproxEqAbs(@as(f64, 4.7e-6), capFarads("4.7uF"), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 4.7e-6), capFarads("4.7U"), 1e-12);
    try testing.expectApproxEqAbs(@as(f64, 10e-6), capFarads("10µF"), 1e-12);
    // The micro-sign path must clear the bulk threshold, or a µF reservoir reads
    // as an HF cap and is wrongly required to name a pin.
    try testing.expect(capFarads("10µF") >= bulk_farads);
    try testing.expect(capFarads("100nF") < bulk_farads);
    // Unrecognised strings are 0 F, never an error.
    try testing.expectEqual(@as(f64, 0), capFarads("abc"));
    try testing.expectEqual(@as(f64, 0), capFarads("100"));
    try testing.expectEqual(@as(f64, 0), capFarads(""));
}
