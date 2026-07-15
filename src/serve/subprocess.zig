//! Bounded, timeout-guarded subprocess capture.
//!
//! `std.process.Child.run` is unsuitable for shelling out to hostile-input
//! tools like `ps2ascii` (a `/bin/sh` wrapper around `gs`, which streams its
//! text straight to stdout): it caps output at 50 KB and, when a limit or
//! error trips, its errdefer only `kill()`s the DIRECT child. A shell wrapper
//! whose grandchild blocks writing a large stdout is left alive, and the
//! caller's thread is pinned — a trivial denial of service.
//!
//! `runCaptured` drains stdout AND stderr concurrently under an explicit byte
//! cap (so a large writer can never deadlock), enforces a wall-clock deadline,
//! and spawns the child in its OWN process group so that on timeout or
//! overflow the whole group is SIGKILLed — reaping any grandchildren the
//! direct child spawned, not just the child itself. Linux/posix only.

const std = @import("std");
const clock = @import("../infra/clock.zig");
const log = @import("../infra/log.zig");

/// How a `runCaptured` invocation ended.
pub const Outcome = enum {
    /// The process ran to completion on its own — inspect `exit_code`.
    ok,
    /// The deadline elapsed first; the process group was killed.
    timed_out,
    /// Output exceeded `max_output_bytes`; the process group was killed.
    output_too_long,
    /// The process could not be spawned at all.
    spawn_failed,
};

/// Outcome of a captured run, plus any stdout the caller must free.
pub const Result = struct {
    outcome: Outcome,
    /// Captured stdout, owned by the caller's allocator. Empty for every
    /// non-`ok` outcome. Release with `deinit`.
    stdout: []const u8,
    /// Exit status when `outcome == .ok` and the process exited normally,
    /// else null (killed, signaled, or never ran).
    exit_code: ?u8,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        if (self.stdout.len != 0) allocator.free(self.stdout);
    }
};

/// Run `argv`, draining both pipes concurrently (so a large writer cannot
/// deadlock), capped at `max_output_bytes` and bounded by `timeout_ms`. The
/// child runs in its own process group; on timeout or overflow the entire
/// group is SIGKILLed, reaping any grandchildren the direct child spawned.
/// Only OOM propagates as an error — spawn failure, timeout, and overflow are
/// reported via `Result.outcome`.
pub fn runCaptured(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    max_output_bytes: usize,
    timeout_ms: u64,
) std.mem.Allocator.Error!Result {
    var child = std.process.Child.init(argv, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    // pgid = 0 makes the child call setpgid(0, 0): it leads a new process
    // group (id == pid), so signalling the negative pid reaches its whole
    // subtree — a shell wrapper's grandchildren, not just the child.
    child.pgid = 0;

    child.spawn() catch return failedResult(.spawn_failed);

    var poller = std.Io.poll(allocator, enum { stdout, stderr }, .{
        .stdout = child.stdout.?,
        .stderr = child.stderr.?,
    });
    defer poller.deinit();

    const status = drain(&poller, max_output_bytes, timeout_ms);
    if (status != .ok) killGroup(&child);

    // Always reap so the child can't linger as a zombie.
    const term = child.wait() catch |e| {
        log.warn("subprocess: wait failed: {s}", .{@errorName(e)});
        return failedResult(if (status == .ok) .spawn_failed else status);
    };
    if (status != .ok) return failedResult(status);

    const stdout_owned = try poller.toOwnedSlice(.stdout);
    return .{
        .outcome = .ok,
        .stdout = stdout_owned,
        .exit_code = if (term == .Exited) term.Exited else null,
    };
}

fn failedResult(outcome: Outcome) Result {
    return .{ .outcome = outcome, .stdout = "", .exit_code = null };
}

/// Poll both pipes until EOF (`.ok`), the byte cap trips (`.output_too_long`),
/// or the deadline passes (`.timed_out`). `poller` is the `*Poller` value.
fn drain(poller: anytype, max_output_bytes: usize, timeout_ms: u64) Outcome {
    const stdout_r = poller.reader(.stdout);
    const stderr_r = poller.reader(.stderr);
    const deadline_ms = clock.milliTimestamp() +| @as(i64, @intCast(timeout_ms));

    while (true) {
        const remaining_ms = deadline_ms - clock.milliTimestamp();
        if (remaining_ms <= 0) return .timed_out;
        const remaining_ns: u64 = @as(u64, @intCast(remaining_ms)) *| clock.ns_per_ms;

        // pollTimeout returns false only when every stream has hit EOF; it
        // returns true both after reading data and when the timeout expires,
        // so the wall-clock deadline above is what actually bounds the wait.
        const still_open = poller.pollTimeout(remaining_ns) catch return .timed_out;
        if (!still_open) return .ok;
        if (stdout_r.bufferedLen() > max_output_bytes) return .output_too_long;
        if (stderr_r.bufferedLen() > max_output_bytes) return .output_too_long;
    }
}

/// SIGKILL the child's whole process group. Kill errors are benign here — the
/// group is already gone or we are tearing it down regardless.
fn killGroup(child: *std.process.Child) void {
    const pgid: std.posix.pid_t = child.id;
    std.posix.kill(-pgid, std.posix.SIG.KILL) catch |e|
        log.warn("subprocess: group kill failed: {s}", .{@errorName(e)});
}

// ── Tests ─────────────────────────────────────────────────────────

test "runCaptured captures stdout and exit code within budget" {
    // spec: serve/subprocess - runCaptured captures stdout and a zero exit code for an in-budget run
    const alloc = std.testing.allocator;
    var res = try runCaptured(alloc, &.{ "sh", "-c", "printf 'hello world'" }, 1 << 20, 5_000);
    defer res.deinit(alloc);
    try std.testing.expectEqual(Outcome.ok, res.outcome);
    try std.testing.expectEqualStrings("hello world", res.stdout);
    try std.testing.expectEqual(@as(?u8, 0), res.exit_code);
}

test "runCaptured times out and kills a slow child promptly" {
    // spec: serve/subprocess - runCaptured reports timed_out and kills a child that overruns the deadline
    const alloc = std.testing.allocator;
    const started = clock.milliTimestamp();
    // A sh parent with a backgrounded `sleep` child mirrors the ps2ascii→gs
    // shape: the whole subtree is what we SIGKILL, not just the direct child.
    var res = try runCaptured(alloc, &.{ "sh", "-c", "sleep 30 & wait" }, 1 << 20, 300);
    defer res.deinit(alloc);
    const elapsed = clock.milliTimestamp() - started;
    try std.testing.expectEqual(Outcome.timed_out, res.outcome);
    try std.testing.expectEqualStrings("", res.stdout);
    // Must abandon the wait far short of the 30 s sleep — proves the deadline
    // and kill fired rather than blocking on the child.
    try std.testing.expect(elapsed < 5_000);
}

test "runCaptured stops draining when output exceeds the byte cap" {
    // spec: serve/subprocess - runCaptured reports output_too_long when a child exceeds the byte cap
    const alloc = std.testing.allocator;
    // `yes` streams unboundedly; a tiny cap must trip before it can wedge the
    // pipe, and the group kill stops `yes` however much it wanted to write.
    var res = try runCaptured(alloc, &.{ "sh", "-c", "yes" }, 4_096, 5_000);
    defer res.deinit(alloc);
    try std.testing.expectEqual(Outcome.output_too_long, res.outcome);
    try std.testing.expectEqualStrings("", res.stdout);
}
