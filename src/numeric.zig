//! Safe float→int narrowing. The production server ships ReleaseSmall (runtime
//! safety OFF), so a bare `@intFromFloat` on a NaN/±inf or out-of-range value —
//! from a design-file number, an arithmetic result, or a layout sidecar pose —
//! is undefined behavior, not a clean panic. Use `checkedInt` at every narrowing
//! of a value that is not already provably finite and in range, and turn a null
//! result into a diagnostic + skip rather than a crash.
const std = @import("std");

/// Round `f` to the nearest integer of type `T`, returning null when `f` is
/// non-finite (NaN/±inf) or rounds outside `T`'s representable range. The
/// range check runs in float space *before* the `@intFromFloat`, so the
/// conversion itself is always well-defined — at every width, exactly.
///
/// The upper bound is the *exclusive* limit `maxInt(T) + 1`, not `maxInt(T)`
/// itself. Whenever T's value bits exceed the f64 mantissa (u64, i64, usize,
/// …) `@floatFromInt(maxInt(T))` cannot represent the max and rounds *up* to
/// exactly `maxInt(T) + 1`; an `r > hi` test then compares *equal* at that
/// bound and waves `maxInt(T) + 1` through to `@intFromFloat` — out of range,
/// i.e. UB in the safety-off production build. `maxInt(T) + 1` is a power of
/// two (2^bits unsigned, 2^(bits-1) signed) and is therefore exactly
/// representable in f64 at every width, so `r >= hi_excl` is precisely "above
/// T's range": `maxInt(T)` still passes, as does every representable f64
/// below the bound (for the wide types the largest such value is
/// `maxInt(T) + 1 - ulp`, comfortably in range). The low bound needs no such
/// care — `minInt(T)` is either 0 or `-2^(bits-1)`, both exact in f64 — so it
/// stays an inclusive `r < lo` rejection.
pub fn checkedInt(comptime T: type, f: f64) ?T {
    if (!std.math.isFinite(f)) return null;
    const r = @round(f);
    const lo: f64 = @floatFromInt(std.math.minInt(T));
    const hi_excl: f64 = @floatFromInt(std.math.maxInt(T) + 1);
    if (r < lo or r >= hi_excl) return null;
    return @intFromFloat(r);
}

/// Narrow `f` to a non-negative count/index, collapsing a non-finite or
/// out-of-range value to 0. Sugar for `checkedInt(usize, f) orelse 0` at the
/// many render/layout sites where a degenerate float should yield an empty
/// span (draw/allocate nothing) rather than crash — the counterpart to the
/// raster pxIndex clamp for values that index or size a buffer.
pub fn toCount(f: f64) usize {
    return checkedInt(usize, f) orelse 0;
}

test "checkedInt rejects NaN and infinities" {
    try std.testing.expect(checkedInt(i64, std.math.nan(f64)) == null);
    try std.testing.expect(checkedInt(i64, std.math.inf(f64)) == null);
    try std.testing.expect(checkedInt(i64, -std.math.inf(f64)) == null);
}

test "checkedInt rejects out-of-range and rounds in-range" {
    try std.testing.expect(checkedInt(u8, 300.0) == null);
    try std.testing.expect(checkedInt(u8, -1.0) == null);
    try std.testing.expectEqual(@as(u32, 220000), checkedInt(u32, 220000.4).?);
    try std.testing.expectEqual(@as(i64, -3), checkedInt(i64, -2.6).?);
    try std.testing.expectEqual(@as(u32, 0), checkedInt(u32, 0.0).?);
}

// spec: numeric - checkedInt admits exactly the values representable in T, rejecting the maxInt+1 overflow bound at every width
test "checkedInt is exact at each type's maximum" {
    // Narrow widths (value bits ≤ 53): maxInt is exactly representable in f64,
    // so the maximum itself converts and maxInt+1 is rejected.
    try std.testing.expectEqual(@as(u8, 255), checkedInt(u8, 255.0).?);
    try std.testing.expect(checkedInt(u8, 256.0) == null);
    try std.testing.expectEqual(@as(i8, 127), checkedInt(i8, 127.0).?);
    try std.testing.expect(checkedInt(i8, 128.0) == null);
    try std.testing.expectEqual(@as(i8, -128), checkedInt(i8, -128.0).?);
    try std.testing.expect(checkedInt(i8, -129.0) == null);
    try std.testing.expectEqual(@as(u32, 4294967295), checkedInt(u32, 4294967295.0).?);
    try std.testing.expect(checkedInt(u32, 4294967296.0) == null);
    try std.testing.expectEqual(@as(i32, 2147483647), checkedInt(i32, 2147483647.0).?);
    try std.testing.expect(checkedInt(i32, 2147483648.0) == null);

    // 64-bit: maxInt is NOT representable in f64. `@floatFromInt(maxInt(T))`
    // rounds *up* to maxInt+1, so the old inclusive `r > hi` bound compared
    // equal there and handed maxInt+1 to @intFromFloat — out of range, UB with
    // runtime safety off. The exclusive bound rejects it.
    try std.testing.expect(checkedInt(i64, 9223372036854775808.0) == null); // 2^63 = maxInt(i64)+1
    try std.testing.expect(checkedInt(u64, 18446744073709551616.0) == null); // 2^64 = maxInt(u64)+1
    try std.testing.expect(checkedInt(i64, @as(f64, @floatFromInt(std.math.maxInt(i64)))) == null);
    try std.testing.expect(checkedInt(u64, @as(f64, @floatFromInt(std.math.maxInt(u64)))) == null);

    // …and the largest f64 strictly below each bound must still convert, so the
    // exclusive bound does not over-reject legitimate in-range values.
    try std.testing.expectEqual(@as(i64, 9223372036854774784), checkedInt(i64, 9223372036854774784.0).?); // 2^63 − 2^10
    try std.testing.expectEqual(@as(u64, 18446744073709549568), checkedInt(u64, 18446744073709549568.0).?); // 2^64 − 2^11

    // The low bound is exact at every width: minInt is 0 or −2^(bits−1).
    try std.testing.expectEqual(@as(i64, std.math.minInt(i64)), checkedInt(i64, -9223372036854775808.0).?); // −2^63
    try std.testing.expect(checkedInt(i64, -9223372036854777856.0) == null); // next f64 below −2^63
    try std.testing.expect(checkedInt(u64, -1.0) == null);

    try expectUsizeBoundExact();
}

/// The `usize` half of the bound assertions, hoisted out of the test body.
/// `usize` is 32 bits on the wasm32 DRC target, where the 64-bit literals below
/// are not representable, so the block has to be comptime-selected — and a
/// comptime `if` inside a test body is what `test-no-conditional` forbids.
/// Keeping the `if` here preserves the dead-branch elimination while leaving the
/// test a flat list of assertions.
fn expectUsizeBoundExact() !void {
    if (comptime @bitSizeOf(usize) == 64) {
        try std.testing.expect(checkedInt(usize, 18446744073709551616.0) == null);
        try std.testing.expectEqual(@as(usize, 18446744073709549568), checkedInt(usize, 18446744073709549568.0).?);
        // toCount rides the same bound: a past-the-max float is an empty span.
        try std.testing.expectEqual(@as(usize, 0), toCount(18446744073709551616.0));
    }
}

test "toCount collapses non-finite and negative to zero, rounds valid counts" {
    try std.testing.expectEqual(@as(usize, 0), toCount(std.math.nan(f64)));
    try std.testing.expectEqual(@as(usize, 0), toCount(std.math.inf(f64)));
    try std.testing.expectEqual(@as(usize, 0), toCount(-4.0));
    try std.testing.expectEqual(@as(usize, 7), toCount(6.6));
}
