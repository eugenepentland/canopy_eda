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
pub fn warn(comptime fmt: []const u8, args: anytype) void {
    const stderr = std.fs.File.stderr();
    var buf: [4096]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, "[W] " ++ fmt ++ "\n", args) catch return;
    stderr.writeAll(msg) catch return;
}
