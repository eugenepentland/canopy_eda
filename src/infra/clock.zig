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

/// Seconds since the Unix epoch.
pub const timestamp = std.time.timestamp;

/// Milliseconds since the Unix epoch.
pub const milliTimestamp = std.time.milliTimestamp;

/// Nanoseconds since the Unix epoch.
pub const nanoTimestamp = std.time.nanoTimestamp;

/// Re-exported so callers can convert between time units without
/// reaching back to `std.time`.
pub const ns_per_s = std.time.ns_per_s;

/// Nanoseconds per millisecond — for interval math without reaching to `std.time`.
pub const ns_per_ms = std.time.ns_per_ms;

/// Block the current thread for `nanoseconds`. Routed here so the rate limiter
/// (the one place that intentionally waits) has a single whitelisted entry.
pub fn sleep(nanoseconds: u64) void {
    std.Thread.sleep(nanoseconds);
}

/// Re-exported so callers building ISO timestamps from a Unix epoch
/// don't need to reach back to `std.time.epoch`.
pub const epoch = std.time.epoch;
