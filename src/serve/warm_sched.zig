//! Scheduling primitives shared by the startup warm-up and the design scan.
//!
//! The server listens within milliseconds of exec — the socket is bound before
//! any design is read — so everything expensive at boot is *behind* the port,
//! not in front of it. What used to make a restart look like a ten-second
//! outage was the first request instead: `GET /api/designs` (and `GET /`)
//! evaluate every design under `src/`, one after another, and a corpus with one
//! multi-second board pays that board's cost with every other core idle. Worse,
//! nothing coalesced: a poller retrying every few seconds started a SECOND full
//! scan over the same files, then a third, each racing the first.
//!
//! Three primitives fix both halves, and both the boot warm-up and the request
//! path use the same ones:
//!
//!   * `runIndexed` — a bounded parallel-for. The calling thread is a worker, so
//!     a failed spawn degrades to the serial behaviour rather than dropping
//!     work.
//!   * `Flight` — a per-key single-flight latch, the same shape
//!     `serve/pcb_page_cache.zig` uses for page renders: the second caller for a
//!     key WAITS for the first and then re-checks the cache the first was
//!     filling, instead of duplicating it.
//!   * `yieldToInteractive` — the background sweep's brake. A warm-up exists to
//!     make requests faster; when one is actually in flight the sweep pauses
//!     briefly before claiming its next board.
//!
//! ## Why the concurrency is bounded, and at what
//!
//! Half the host's cores, capped at four. The cap is not about the scan — it is
//! about what the scan shares the machine with. Every worker here owns an
//! evaluator, an arena and (in the board sweep) a board-sized render, so an
//! unbounded fan-out would put process-lifetime peaks on every core exactly
//! when a reader is loading the page the sweep is warming. Four is also past
//! the useful point: this corpus's critical path is its single slowest design,
//! and the remaining two dozen fit under that design's own wall at two workers.

const std = @import("std");
const infra_fs = @import("../infra/fs.zig");
const clock = @import("../infra/clock.zig");

/// Ceiling on the workers any one sweep may run, and therefore the size of the
/// spawn array below. Callers pass their own cap to `workerCount`; this is the
/// hard limit no cap can exceed.
const max_workers: usize = 8;

/// Process-lifetime store for the in-flight key set. The keys outlive the
/// request arena of whoever claimed them.
// allocator-ok: process-lifetime latch keys, deliberately not request-scoped.
const store = std.heap.page_allocator;

/// How many workers a sweep should use: half the host's cores, never more than
/// `cap`, never fewer than one. Half rather than all because the server is
/// serving while this runs (see the module header).
pub fn workerCount(cap: usize) usize {
    const cores = std.Thread.getCpuCount() catch 1;
    return @max(1, @min(@min(cap, max_workers), cores / 2));
}

/// Run `body(ctx, i)` for every `i` in `0..count` across at most `workers`
/// threads, and return once every index has been processed.
///
/// Work is claimed from one atomic counter rather than sliced up front, so a
/// corpus whose costs differ by two orders of magnitude (this one: milliseconds
/// to seconds per design) still finishes near its critical path instead of
/// waiting on whichever worker drew the expensive slice. The CALLING thread
/// drains too, which is what makes a spawn failure merely slower.
pub fn runIndexed(
    comptime Ctx: type,
    ctx: *Ctx,
    count: usize,
    comptime body: fn (*Ctx, usize) void,
    workers: usize,
) void {
    if (count == 0) return;
    const Shared = struct {
        ctx: *Ctx,
        count: usize,
        next: std.atomic.Value(usize) = .init(0),

        fn drain(self: *@This()) void {
            while (true) {
                const i = self.next.fetchAdd(1, .monotonic);
                if (i >= self.count) return;
                body(self.ctx, i);
            }
        }
    };
    var shared = Shared{ .ctx = ctx, .count = count };
    var threads: [max_workers - 1]std.Thread = undefined;
    const want = @min(@min(workers, count), max_workers);
    var spawned: usize = 0;
    while (spawned + 1 < want and spawned < threads.len) : (spawned += 1) {
        threads[spawned] = std.Thread.spawn(.{}, Shared.drain, .{&shared}) catch break;
    }
    shared.drain();
    for (threads[0..spawned]) |thread| thread.join();
}

/// A per-key single-flight latch: at most one thread computes for a key, and
/// everyone else waits for it rather than repeating the work.
///
/// The contract is deliberately the smaller half of `pcb_page_cache`'s: this
/// holds no results, only the right to produce them. A caller pairs it with
/// whatever cache it is filling —
///
///     if (fresh(key)) return;                 // already there
///     const leading = flight.claim(key);      // waits out any current leader
///     defer if (leading) flight.release(key);
///     if (fresh(key)) return;                 // the leader we waited for landed it
///     …compute and cache…
///
/// — so the join costs one re-check and the failure mode (the leader could not
/// cache what it built) is a second attempt rather than a missing answer.
pub const Flight = struct {
    mutex: infra_fs.Mutex = .{},
    changed: infra_fs.Condition = .{},
    keys: std.StringHashMapUnmanaged(void) = .empty,

    /// Wait until no one holds `key`, then take it. Returns true when the
    /// caller now holds it and must `release`; false only when the latch could
    /// not record the claim, in which case the caller proceeds uncoalesced
    /// (slower, never wrong).
    pub fn claim(self: *Flight, key: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        while (self.keys.contains(key)) self.changed.wait(&self.mutex);
        const owned = store.dupe(u8, key) catch return false;
        self.keys.put(store, owned, {}) catch {
            store.free(owned);
            return false;
        };
        return true;
    }

    /// Release `key` and wake every waiter so the next one may claim it.
    pub fn release(self: *Flight, key: []const u8) void {
        self.mutex.lock();
        if (self.keys.fetchRemove(key)) |removed| store.free(removed.key);
        self.changed.broadcast();
        self.mutex.unlock();
    }

    /// Whether `key` is currently claimed. For tests; the claim/release pair is
    /// the only thing production code needs.
    fn heldForTest(self: *Flight, key: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.keys.contains(key);
    }

    /// Drop every outstanding claim. Only a test that abandoned a leader needs
    /// this; a running server releases what it claims.
    fn deinitForTest(self: *Flight) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.keys.keyIterator();
        while (it.next()) |k| store.free(k.*);
        self.keys.deinit(store);
        self.keys = .empty;
    }
};

// ── Interactive-request pressure ───────────────────────────────────────
//
// The startup sweep and a reader want the same cores. The reader wins: a warm
// that finishes a second later costs nobody anything, while a page render
// queued behind four board solves is exactly the wait the sweep exists to
// prevent. The signal is one atomic incremented around request dispatch; the
// brake is a BOUNDED pause between boards, never a gate — a server under
// steady load must still finish warming.

/// Namespaced like `paths.SrcIndex`: process-wide by nature (the counter is
/// written by every request thread and read by every sweep worker), with one
/// named home rather than a loose module-level `var`.
const Interactive = struct {
    var count: std.atomic.Value(usize) = .init(0);
};

/// Longest a background sweep pauses for in-flight requests before claiming its
/// next unit of work. Deliberately short: this hands the reader the head start,
/// it does not hand them the machine.
const yield_budget_ns: u64 = 250 * std.time.ns_per_ms;

/// Granularity of that pause — small enough that the sweep resumes promptly
/// when the request finishes.
const yield_slice_ns: u64 = 25 * std.time.ns_per_ms;

/// Mark a request as being served. Paired with `leaveInteractive`.
pub fn enterInteractive() void {
    _ = Interactive.count.fetchAdd(1, .monotonic);
}

/// Mark a request as finished.
pub fn leaveInteractive() void {
    _ = Interactive.count.fetchSub(1, .monotonic);
}

/// Requests currently in flight.
pub fn interactiveInFlight() usize {
    return Interactive.count.load(.monotonic);
}

/// Pause for up to `yield_budget_ns` while any request is in flight. Called by
/// background sweeps between units of work — never inside one, because
/// abandoning a half-finished board render would waste the very work it is
/// protecting.
pub fn yieldToInteractive() void {
    var waited: u64 = 0;
    while (waited < yield_budget_ns and interactiveInFlight() > 0) : (waited += yield_slice_ns) {
        clock.sleep(yield_slice_ns) catch return;
    }
}

// ── Boot clock ─────────────────────────────────────────────────────────

/// Nanosecond timestamp taken at process entry, so every startup line can say
/// how far into the boot it happened. Zero until `markProcessStart` runs, which
/// is what makes `sinceStartMs` report 0 for a process that never marked one
/// (every CLI command).
const Boot = struct {
    var start_ns: i128 = 0;
};

/// Record process entry. Called once by `main`, immediately after it installs
/// the process I/O capability — never before it (see `recordProcessStart`).
pub fn markProcessStart() void {
    recordProcessStart(clock.nanoTimestamp());
}

/// Take `now_ns` as the process start, unless the clock could not answer.
///
/// Split out from the read above so the refusal is testable. `infra/clock.zig`
/// reads the time through `root.process_io`, which is `.failing` until `main`
/// installs the real capability — and a failing read yields 0, not an error. A
/// mark taken one line too early therefore records a start of zero, which
/// `sinceStartMs` cannot distinguish from a CLI process that never marked one,
/// and every startup line then reports `0 ms` while looking perfectly healthy.
/// Refusing it keeps that failure honest: the line reports the truth or nothing.
fn recordProcessStart(now_ns: i128) void {
    if (now_ns == 0) return;
    Boot.start_ns = now_ns;
}

/// Microseconds since `markProcessStart`, or 0 when it was never called.
///
/// Microseconds rather than milliseconds because the number this exists to
/// report — exec to bound socket — is SUB-MILLISECOND once the boot does no
/// work, and a startup line that says `0 ms` reads exactly like a broken clock.
pub fn sinceStartUs() i64 {
    if (Boot.start_ns == 0) return 0;
    return @intCast(@divTrunc(clock.nanoTimestamp() - Boot.start_ns, std.time.ns_per_us));
}

/// `sinceStartUs` as fractional milliseconds, for a log line a human reads.
pub fn sinceStartMs() f64 {
    return @as(f64, @floatFromInt(sinceStartUs())) / @as(f64, @floatFromInt(std.time.us_per_ms));
}

// spec: Web Server - Background warm concurrency is bounded at half the host's cores so a startup sweep cannot occupy the machine it is warming
test "worker count is half the cores, clamped by the caller's cap and never zero" {
    const cores = std.Thread.getCpuCount() catch 1;
    const half = @max(1, cores / 2);
    try std.testing.expectEqual(@min(half, @as(usize, 4)), workerCount(4));
    // A cap of one is honoured even on a large host…
    try std.testing.expectEqual(@as(usize, 1), workerCount(1));
    // …and no cap can raise the fan-out past the spawn array.
    try std.testing.expect(workerCount(1000) <= max_workers);
    try std.testing.expect(workerCount(0) >= 1);
}

const CountWork = struct {
    seen: [64]std.atomic.Value(u8) = @splat(.init(0)),
    total: std.atomic.Value(usize) = .init(0),

    fn bump(self: *CountWork, i: usize) void {
        _ = self.seen[i].fetchAdd(1, .monotonic);
        _ = self.total.fetchAdd(1, .monotonic);
    }
};

// spec: Web Server - A parallel warm sweep processes every design exactly once regardless of how many workers it runs
test "runIndexed covers every index exactly once at any worker count" {
    for ([_]usize{ 1, 2, 4, 8 }) |workers| {
        var work = CountWork{};
        runIndexed(CountWork, &work, 40, CountWork.bump, workers);
        try std.testing.expectEqual(@as(usize, 40), work.total.load(.monotonic));
        for (work.seen[0..40]) |*s| try std.testing.expectEqual(@as(u8, 1), s.load(.monotonic));
        // Nothing past the count is touched.
        for (work.seen[40..]) |*s| try std.testing.expectEqual(@as(u8, 0), s.load(.monotonic));
    }
    // An empty sweep spawns nothing and returns.
    var empty = CountWork{};
    runIndexed(CountWork, &empty, 0, CountWork.bump, 4);
    try std.testing.expectEqual(@as(usize, 0), empty.total.load(.monotonic));
}

const FlightRace = struct {
    flight: *Flight,
    computed: std.atomic.Value(usize) = .init(0),
    ready: std.atomic.Value(bool) = .init(false),

    /// The exact shape production code uses: check, claim, re-check, compute.
    fn ensure(self: *FlightRace, _: usize) void {
        if (self.ready.load(.acquire)) return;
        const leading = self.flight.claim("demo");
        defer if (leading) self.flight.release("demo");
        if (self.ready.load(.acquire)) return;
        _ = self.computed.fetchAdd(1, .monotonic);
        self.ready.store(true, .release);
    }
};

// spec: Web Server - Concurrent design scans coalesce onto one evaluation per design instead of each starting its own
test "a single-flight key is computed once however many callers race for it" {
    var flight = Flight{};
    defer flight.deinitForTest();
    var race = FlightRace{ .flight = &flight };
    runIndexed(FlightRace, &race, 16, FlightRace.ensure, 8);
    try std.testing.expectEqual(@as(usize, 1), race.computed.load(.monotonic));
    // Every claim was released, so a later caller is not locked out.
    try std.testing.expect(!flight.heldForTest("demo"));
    try std.testing.expect(flight.claim("demo"));
    try std.testing.expect(flight.heldForTest("demo"));
    flight.release("demo");
    try std.testing.expect(!flight.heldForTest("demo"));
}

// spec: Web Server - Two different designs never block each other in the scan's single-flight latch
test "single-flight keys are independent" {
    var flight = Flight{};
    defer flight.deinitForTest();
    try std.testing.expect(flight.claim("alpha"));
    try std.testing.expect(flight.claim("beta"));
    try std.testing.expect(flight.heldForTest("alpha"));
    flight.release("alpha");
    try std.testing.expect(!flight.heldForTest("alpha"));
    try std.testing.expect(flight.heldForTest("beta"));
    flight.release("beta");
}

// spec: Web Server - A background warm sweep pauses for in-flight requests and still proceeds when the server stays busy
test "the interactive brake is bounded, not a gate" {
    try std.testing.expectEqual(@as(usize, 0), interactiveInFlight());
    // Idle: no pause at all.
    yieldToInteractive();
    enterInteractive();
    try std.testing.expectEqual(@as(usize, 1), interactiveInFlight());
    // Busy: bounded by the budget rather than by the request finishing, so a
    // server under steady load still finishes warming.
    const started = clock.nanoTimestamp();
    yieldToInteractive();
    const waited_ms = @divTrunc(clock.nanoTimestamp() - started, clock.ns_per_ms);
    try std.testing.expect(waited_ms >= 1);
    try std.testing.expect(waited_ms < 2 * @divTrunc(yield_budget_ns, std.time.ns_per_ms));
    leaveInteractive();
    try std.testing.expectEqual(@as(usize, 0), interactiveInFlight());
}

// spec: Web Server - A process that never marked a start reports no boot elapsed, so CLI commands carry no server timing
// spec: Web Server - A process-start mark taken before the I/O capability is installed is refused rather than recorded, so the startup line reports real elapsed milliseconds or none at all
test "boot elapsed is zero until a usable process start is marked" {
    const saved = Boot.start_ns;
    defer Boot.start_ns = saved;
    Boot.start_ns = 0;
    try std.testing.expectEqual(@as(i64, 0), sinceStartUs());

    // What `clock.nanoTimestamp()` yields on the `.failing` capability every
    // process carries until `main` installs the real one. Recording it would
    // make every startup line say `0 ms` while looking healthy.
    recordProcessStart(0);
    try std.testing.expectEqual(@as(i128, 0), Boot.start_ns);
    try std.testing.expectEqual(@as(i64, 0), sinceStartUs());

    markProcessStart();
    try std.testing.expect(Boot.start_ns != 0);
    try std.testing.expect(sinceStartUs() >= 0);
}
