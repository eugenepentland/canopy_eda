//! Shared, thread-safe rate limiters for outbound API calls. Each external API
//! (Component Search Engine, DigiKey) has one process-global limiter so that
//! many concurrent lookups — e.g. a parallel BOM resolve that fans out one
//! request per part — are throttled to a safe rate instead of being rejected
//! with HTTP 429. `acquire()` blocks the caller until both the in-flight cap and
//! the minimum-interval gate allow the call; `release()` frees the slot and
//! wakes one waiter. The limiter shapes traffic by making callers *wait* rather
//! than fail, so naive parallel fan-out becomes safe.

const std = @import("std");
const clock = @import("../infra/clock.zig");
const config = @import("../config.zig");

/// A minimum-interval + max-in-flight gate. Conservative compile-time defaults
/// apply until `configureFromEnv` overrides them at server startup.
pub const RateLimiter = struct {
    mutex: std.Thread.Mutex = .{},
    cond: std.Thread.Condition = .{},
    /// Minimum spacing between successive call *starts*.
    min_interval_ns: u64,
    /// Maximum number of calls allowed in flight at once.
    max_in_flight: u32,
    in_flight: u32 = 0,
    /// Monotonic-ish timestamp (ns) at which the next call may start. Each
    /// `acquire()` reserves a staggered slot here so concurrent callers space
    /// out even though the interval wait happens off-lock.
    next_allowed_ns: i128 = 0,

    pub fn init(min_interval_ms: u64, max_in_flight: u32) RateLimiter {
        return .{
            .min_interval_ns = min_interval_ms * clock.ns_per_ms,
            .max_in_flight = if (max_in_flight == 0) 1 else max_in_flight,
        };
    }

    /// Block until a slot is free and the minimum interval since the last start
    /// has elapsed, then claim the slot. Always paired with `release()`.
    pub fn acquire(self: *RateLimiter) void {
        self.mutex.lock();
        while (self.in_flight >= self.max_in_flight) self.cond.wait(&self.mutex);
        self.in_flight += 1;
        // Reserve this call's start time before unlocking so two concurrent
        // acquirers get staggered starts (t, t+interval) rather than colliding.
        const now = clock.nanoTimestamp();
        const start_at = if (now > self.next_allowed_ns) now else self.next_allowed_ns;
        self.next_allowed_ns = start_at + @as(i128, @intCast(self.min_interval_ns));
        const wait_ns: u64 = if (start_at > now) @intCast(start_at - now) else 0;
        self.mutex.unlock();
        // Wait off-lock so other callers can queue / release while we wait.
        if (wait_ns > 0) clock.sleep(wait_ns);
    }

    /// Free the slot claimed by `acquire()` and wake one waiter.
    pub fn release(self: *RateLimiter) void {
        self.mutex.lock();
        if (self.in_flight > 0) self.in_flight -= 1;
        self.mutex.unlock();
        self.cond.signal();
    }
};

/// Process-global limiter for Component Search Engine traffic. Conservative
/// default; overridden by `configureFromEnv`.
pub var cse: RateLimiter = RateLimiter.init(200, 2);

/// Process-global limiter for DigiKey traffic (free tier is the tightest budget,
/// so the default is the most conservative). Overridden by `configureFromEnv`.
pub var digikey: RateLimiter = RateLimiter.init(250, 2);

/// Re-read the per-API limits from the environment / `.env` and reset both
/// limiters. Called once at server startup (where an allocator is in hand)
/// before any request thread touches the limiters.
pub fn configureFromEnv(allocator: std.mem.Allocator) void {
    cse = RateLimiter.init(config.cseMinIntervalMs(allocator), config.cseMaxInFlight(allocator));
    digikey = RateLimiter.init(config.digikeyMinIntervalMs(allocator), config.digikeyMaxInFlight(allocator));
}

// ── Tests ─────────────────────────────────────────────────────────

const testing = std.testing;

// spec: serve/rate_limiter - acquire/release pair leaves no slots held
test "RateLimiter acquire/release balance to zero in flight" {
    var rl = RateLimiter.init(0, 2);
    rl.acquire();
    rl.acquire();
    rl.release();
    rl.release();
    try testing.expectEqual(@as(u32, 0), rl.in_flight);
}

// spec: serve/rate_limiter - acquire spaces successive call starts by the minimum interval
test "RateLimiter spaces sequential starts by the min interval" {
    var rl = RateLimiter.init(40, 1);
    const t0 = clock.nanoTimestamp();
    rl.acquire(); // first start: immediate
    rl.release();
    rl.acquire(); // second start: waits ~one interval
    rl.release();
    const elapsed_ms = @divTrunc(clock.nanoTimestamp() - t0, clock.ns_per_ms);
    try testing.expect(elapsed_ms >= 30); // generous lower bound (interval is 40ms)
}

// spec: serve/rate_limiter - acquire blocks a caller once max_in_flight is reached until a release
test "RateLimiter blocks when at capacity until a slot frees" {
    var rl = RateLimiter.init(0, 1);
    rl.acquire(); // hold the only slot
    var acquired_at: i128 = 0;
    const Worker = struct {
        fn run(limiter: *RateLimiter, out: *i128) void {
            limiter.acquire();
            out.* = clock.nanoTimestamp();
            limiter.release();
        }
    };
    const t = try std.Thread.spawn(.{}, Worker.run, .{ &rl, &acquired_at });
    clock.sleep(25 * clock.ns_per_ms);
    const released_at = clock.nanoTimestamp();
    rl.release(); // let the worker through
    t.join();
    // The worker could only acquire after we released the held slot.
    try testing.expect(acquired_at >= released_at);
}
