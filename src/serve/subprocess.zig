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
const infra_fs = @import("../infra/fs.zig");
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
    // pgid = 0 makes the child call setpgid(0, 0): it leads a new process
    // group (id == pid), so signalling the negative pid reaches its whole
    // subtree — a shell wrapper's grandchildren, not just the child.
    const io = infra_fs.currentIo();
    var child = std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .pgid = 0,
    }) catch return failedResult(.spawn_failed);
    var multi_reader_buffer: std.Io.File.MultiReader.Buffer(2) = undefined;
    var multi_reader: std.Io.File.MultiReader = undefined;
    multi_reader.init(allocator, io, multi_reader_buffer.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer multi_reader.deinit();

    const status = drain(&multi_reader, max_output_bytes, timeout_ms);
    if (status != .ok) killGroup(&child);

    // Always reap so the child can't linger as a zombie.
    const term = child.wait(io) catch |e| {
        log.warn("subprocess: wait failed: {s}", .{@errorName(e)});
        return failedResult(if (status == .ok) .spawn_failed else status);
    };
    if (status != .ok) return failedResult(status);

    const stdout_owned = try multi_reader.toOwnedSlice(0);
    return .{
        .outcome = .ok,
        .stdout = stdout_owned,
        .exit_code = switch (term) {
            .exited => |code| code,
            else => null,
        },
    };
}

fn failedResult(outcome: Outcome) Result {
    return .{ .outcome = outcome, .stdout = "", .exit_code = null };
}

/// Poll both pipes until EOF (`.ok`), the byte cap trips (`.output_too_long`),
/// or the deadline passes (`.timed_out`).
fn drain(multi_reader: *std.Io.File.MultiReader, max_output_bytes: usize, timeout_ms: u64) Outcome {
    const stdout_r = multi_reader.reader(0);
    const stderr_r = multi_reader.reader(1);
    const timeout: std.Io.Timeout = .{ .deadline = .fromNow(infra_fs.currentIo(), .{
        .clock = .awake,
        .raw = .fromMilliseconds(@intCast(timeout_ms)),
    }) };
    while (true) {
        multi_reader.fill(1, timeout) catch |err| switch (err) {
            error.EndOfStream => return .ok,
            error.Timeout => return .timed_out,
            else => return .timed_out,
        };
        if (stdout_r.buffered().len > max_output_bytes) return .output_too_long;
        if (stderr_r.buffered().len > max_output_bytes) return .output_too_long;
    }
}

/// SIGKILL the child's whole process group. Kill errors are benign here — the
/// group is already gone or we are tearing it down regardless.
fn killGroup(child: *std.process.Child) void {
    const pgid = child.id orelse return;
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
