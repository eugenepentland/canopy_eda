//! Single funnel for every hand-rolled fatal termination in the CLI.
//!
//! Zig core routes all unrecoverable exits through one helper
//! (`std.process.fatal`) and Guardian carries its own `reporter.fatal`, both so
//! the failure path stays consistent and greppable. This module is netlisp's
//! equivalent: the `build` / `check` / `export-kicad` / `import-kicad` command
//! handlers and the query commands terminate through `fatal` / `failure` here
//! instead of scattering `std.debug.print(...) + std.process.exit(1)` pairs.
//! Designated to Guardian's fatal-exit check via a `[[allow]]` path entry in
//! guardian.toml, so its own `std.process.exit` calls are the sanctioned ones.

const std = @import("std");
const log = @import("infra/log.zig");

/// The process exit status shared by every fatal termination: a nonzero
/// (failure) code so CI and calling agents can gate on it.
pub const failure_status: u8 = 1;

/// Best-effort diagnostic write to stderr, through the same last-resort channel
/// every other netlisp diagnostic uses (`infra/log.zig`) so it sidesteps the
/// `debug-print-ban` chain and truncates rather than drops a message longer than
/// the shared 4 KiB scratch buffer. This module used to carry its own copy of
/// that write-or-truncate tail; one funnel for fatal exits deserves one funnel
/// for the sentence the exit prints.
fn writeStderr(comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    log.emitLine(&buf, std.fmt.bufPrint(&buf, fmt, args));
}

/// Print the diagnostic `fmt`/`args` to stderr, then terminate the process with
/// `failure_status`. The replacement for a `std.debug.print(...)` immediately
/// followed by `std.process.exit(1)`.
pub fn fatal(comptime fmt: []const u8, args: anytype) noreturn {
    writeStderr(fmt, args);
    std.process.exit(failure_status);
}

/// Terminate with `failure_status` without printing — for a control-flow exit
/// whose diagnostic was already emitted (e.g. an ERC run that printed its own
/// errors, or an operation that reported failure internally).
pub fn failure() noreturn {
    std.process.exit(failure_status);
}

// spec: Fatal Exit Helper - fatal and failure terminate with a nonzero failure status
test "failure_status is the nonzero failure exit code" {
    try std.testing.expect(failure_status != 0);
    try std.testing.expectEqual(@as(u8, 1), failure_status);
}
