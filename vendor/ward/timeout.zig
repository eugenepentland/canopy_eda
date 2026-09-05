//! Bound the entire verification exchange using cancellable Zig IO tasks.
//! SO_RCVTIMEO produces EAGAIN, which Zig 0.17 Threaded treats as a programmer
//! error on blocking streams. Cancellation instead interrupts connect/read/write
//! through the IO implementation and lets the verifier return unavailable.
const std = @import("std");

pub fn run(
    comptime Result: type,
    io: std.Io,
    seconds: u31,
    function: anytype,
    args: std.meta.ArgsTuple(@TypeOf(function)),
) Result {
    if (seconds == 0) return @call(.auto, function, args);
    const Event = union(enum) { done: void, timer: std.Io.Cancelable!void };
    const Task = struct {
        fn invoke(out: *Result, arguments: @TypeOf(args)) void {
            out.* = @call(.auto, function, arguments);
        }
    };
    var result: Result = .unavailable;
    var buffer: [2]Event = undefined;
    var select = std.Io.Select(Event).init(io, &buffer);
    select.concurrent(.timer, std.Io.sleep, .{ io, std.Io.Duration.fromSeconds(seconds), .awake }) catch return .unavailable;
    select.concurrent(.done, Task.invoke, .{ &result, args }) catch {
        select.cancelDiscard();
        return .unavailable;
    };
    _ = select.await() catch {};
    // Join BEFORE reading result. A verification that completed at the deadline
    // still owns its verdict; returning it avoids leaking allocated identities.
    select.cancelDiscard();
    return result;
}

const TestResult = error{OutOfMemory}!enum { allowed, unavailable };
fn stalled(io: std.Io) TestResult {
    std.Io.sleep(io, .fromSeconds(30), .awake) catch return .unavailable;
    return .allowed;
}
fn immediate() TestResult {
    return .allowed;
}

test "verification deadline cancels a stalled exchange" {
    try std.testing.expectEqual(.unavailable, try run(TestResult, std.testing.io, 1, stalled, .{std.testing.io}));
    try std.testing.expectEqual(.allowed, try run(TestResult, std.testing.io, 1, immediate, .{}));
}
