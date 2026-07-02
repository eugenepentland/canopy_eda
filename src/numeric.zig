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
/// conversion itself is always well-defined. (The f64 mantissa can't represent
/// every i64/u64 boundary exactly; for the counts/pins/coordinates this guards
/// the realistic inputs are nowhere near 2^53, so that boundary is immaterial.)
pub fn checkedInt(comptime T: type, f: f64) ?T {
    if (!std.math.isFinite(f)) return null;
    const r = @round(f);
    const lo: f64 = @floatFromInt(std.math.minInt(T));
    const hi: f64 = @floatFromInt(std.math.maxInt(T));
    if (r < lo or r > hi) return null;
    return @intFromFloat(r);
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
