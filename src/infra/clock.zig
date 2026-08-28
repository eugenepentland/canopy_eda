//! Clock port. All wall-clock reads in production code go through this
//! module so Guardian's `ban-time` check has one whitelisted entry
//! point. The wrappers are intentionally thin re-exports — this is a
//! boundary marker, not an abstraction layer.
//!
//! Usage:
//!     const clock = @import("infra/clock.zig");
//!     const now = clock.timestamp();          // i64 seconds since epoch
//!     const ms  = clock.milliTimestamp();     // i64 ms
//!     const ns  = clock.nanoTimestamp();      // i128 ns

const std = @import("std");
const infra_fs = @import("fs.zig");

/// Seconds since the Unix epoch.
pub fn timestamp() i64 {
    return @intCast(@divFloor(nanoTimestamp(), std.time.ns_per_s));
}

/// Milliseconds since the Unix epoch.
pub fn milliTimestamp() i64 {
    return @intCast(@divFloor(nanoTimestamp(), std.time.ns_per_ms));
}

/// Nanoseconds since the Unix epoch.
pub fn nanoTimestamp() i128 {
    return @intCast(std.Io.Timestamp.now(infra_fs.currentIo(), .real).nanoseconds);
}

/// Nanoseconds on the monotonic clock — the one to subtract two readings of
/// when measuring how long something TOOK. `nanoTimestamp` is settable (NTP,
/// an administrator), so a wall-clock delta can come out negative or absurd;
/// this one cannot go backwards. The zero point is unspecified, so only
/// differences are meaningful.
pub fn monotonicNanos() i128 {
    return @intCast(std.Io.Timestamp.now(infra_fs.currentIo(), .awake).nanoseconds);
}

/// Re-exported so callers can convert between time units without
/// reaching back to `std.time`.
pub const ns_per_s = std.time.ns_per_s;

/// Nanoseconds per millisecond — for interval math without reaching to `std.time`.
pub const ns_per_ms = std.time.ns_per_ms;

/// Block the current thread for `nanoseconds`. Routed here so the rate limiter
/// (the one place that intentionally waits) has a single whitelisted entry.
pub fn sleep(nanoseconds: u64) std.Io.Cancelable!void {
    return std.Io.sleep(infra_fs.currentIo(), .{ .nanoseconds = @intCast(nanoseconds) }, .awake);
}

/// Re-exported so callers building ISO timestamps from a Unix epoch
/// don't need to reach back to `std.time.epoch`.
pub const epoch = std.time.epoch;
