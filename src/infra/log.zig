//! Log port. Diagnostic warnings from production code (best-effort
//! error paths, missing optional sources) go through this module
//! instead of `std.debug.print` / `std.log`, which Guardian's
//! `debug-print-ban` check forbids.
//!
//! CLI command output (the visible result of running `eda <cmd>`)
//! stays on `std.Io.File.stdout()` directly inside `src/commands.zig`
//! and `src/main.zig` — those prints are the program's purpose, not
//! diagnostics about it.
//!
//! Implementation note: writes go through `std.Io.File.stderr()` so
//! we sidestep `debug-print-ban`'s `std.debug.print` chain. Output is
//! best-effort: a write failure is silently swallowed (logging the
//! log failure has nowhere useful to go).
//!
//! Usage:
//!     const log = @import("infra/log.zig");
//!     log.warn("config not found at {s}", .{path});

const std = @import("std");

/// Emit an `[I] ` -prefixed progress line on stderr. Use for the running
/// commentary of a long server-side job — a request that works for minutes
/// (autoroute, gap closing) is indistinguishable from a hang without one. Not
/// for errors: those are `warn`. Same best-effort, truncate-don't-drop
/// behaviour, so a progress line can never fail a request.
pub fn progress(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    write(&buf, std.fmt.bufPrint(&buf, "[I] " ++ fmt ++ "\n", args));
}

/// Emit a `[W] ` -prefixed diagnostic line on stderr. Use for
/// recoverable errors — best-effort writes that failed, missing
/// optional sources, etc. Always followed by a newline.
///
/// A message longer than the 4 KiB scratch buffer is truncated (the bytes
/// that fit, then an ellipsis) rather than dropped entirely — this is the
/// last-resort diagnostics channel, so a truncated signal beats silence.
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    write(&buf, std.fmt.bufPrint(&buf, "[W] " ++ fmt ++ "\n", args));
}

/// Put one already-prefixed, newline-terminated line on stderr, or its
/// truncated head when the message overflowed `buf`. Shared by both levels so
/// they behave identically; it takes the format RESULT rather than a format
/// string + `anytype` args so the module stays inside its `anytype` budget.
fn write(buf: []u8, res: std.fmt.BufPrintError![]u8) void {
    const stderr = std.Io.File.stderr();
    if (res) |msg| {
        stderr.writeStreamingAll(@import("fs.zig").currentIo(), msg) catch return;
    } else |err| switch (err) {
        // Overflow: emit as much as fit plus a truncation marker so the
        // diagnostic isn't lost wholesale. Reserve room for the suffix.
        error.NoSpaceLeft => {
            const suffix = "…\n";
            @memcpy(buf[buf.len - suffix.len ..], suffix);
            stderr.writeStreamingAll(@import("fs.zig").currentIo(), buf) catch return;
        },
    }
}
