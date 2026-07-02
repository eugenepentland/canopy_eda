//! Log port. Diagnostic warnings from production code (best-effort
//! error paths, missing optional sources) go through this module
//! instead of `std.debug.print` / `std.log`, which Guardian's
//! `debug-print-ban` check forbids.
//!
//! CLI command output (the visible result of running `eda <cmd>`)
//! stays on `std.fs.File.stdout()` directly inside `src/commands.zig`
//! and `src/main.zig` — those prints are the program's purpose, not
//! diagnostics about it.
//!
//! Implementation note: writes go through `std.fs.File.stderr()` so
//! we sidestep `debug-print-ban`'s `std.debug.print` chain. Output is
//! best-effort: a write failure is silently swallowed (logging the
//! log failure has nowhere useful to go).
//!
//! Usage:
//!     const log = @import("infra/log.zig");
//!     log.warn("config not found at {s}", .{path});

const std = @import("std");

/// Emit a `[W] ` -prefixed diagnostic line on stderr. Use for
/// recoverable errors — best-effort writes that failed, missing
/// optional sources, etc. Always followed by a newline.
///
/// A message longer than the 4 KiB scratch buffer is truncated (the bytes
/// that fit, then an ellipsis) rather than dropped entirely — this is the
/// last-resort diagnostics channel, so a truncated signal beats silence.
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    const stderr = std.fs.File.stderr();
    var buf: [4096]u8 = undefined;
    if (std.fmt.bufPrint(&buf, "[W] " ++ fmt ++ "\n", args)) |msg| {
        stderr.writeAll(msg) catch return;
    } else |err| switch (err) {
        // Overflow: emit as much as fit plus a truncation marker so the
        // diagnostic isn't lost wholesale. Reserve room for the suffix.
        error.NoSpaceLeft => {
            const suffix = "…\n";
            const head = buf[0 .. buf.len - suffix.len];
            @memcpy(buf[head.len..], suffix);
            stderr.writeAll(&buf) catch return;
        },
    }
}
