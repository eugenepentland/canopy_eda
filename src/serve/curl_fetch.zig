//! One `curl` transport for every outbound vendor fetch.
//!
//! The vendor clients (`component_search`, `digikey`) each grew their own
//! wrapper around `curl -sS --max-time …`, and the copies had stopped agreeing
//! about the one thing that is a security property rather than a preference:
//! the `--` end-of-options guard in front of the URL. Without it a
//! vendor-supplied URL that begins with `-` is parsed by curl as a FLAG —
//! `-o /path` writes a file, `-K file` reads a config — which turns a search
//! result into argument injection. One copy had the guard; the other passed
//! the URL inline among its options, where no guard is possible.
//!
//! So the URL is a named field here, not one of the options: a caller cannot
//! express "URL somewhere in the middle" any more, and every URL this process
//! fetches goes through the guard by construction.
//!
//! Everything else the two copies already shared is unchanged: the caller's
//! rate limiter is held for the whole call, the body is returned whatever the
//! HTTP status (no `-f`, so a 401 body reaches the parser that can classify
//! it), and a spawn failure or non-zero exit is null.

const std = @import("std");
const infra_fs = @import("../infra/fs.zig");
const rate_limiter = @import("rate_limiter.zig");

/// One outbound fetch.
pub const Request = struct {
    /// curl OPTIONS — flags, headers, form fields, request method. Never a
    /// URL: those go in `url`, behind the `--` guard.
    options: []const []const u8 = &.{},
    /// The URL to fetch, appended last and after `--`. Null for a request
    /// whose options already carry everything (nothing does today; the field
    /// is optional so a caller cannot be forced to invent one).
    url: ?[]const u8 = null,
    /// `--max-time` value, in seconds, as curl spells it.
    timeout_secs: []const u8,
    /// Cap on both captured streams.
    max_bytes: usize,
};

/// The exact argv `run` would spawn. Separate from `run` so the guard is
/// testable without a network or a `curl` on the box.
pub fn buildArgv(
    allocator: std.mem.Allocator,
    req: Request,
) std.mem.Allocator.Error![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    errdefer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "curl", "-sS", "--max-time", req.timeout_secs });
    try argv.appendSlice(allocator, req.options);
    if (req.url) |u| try argv.appendSlice(allocator, &.{ "--", u });
    return argv.toOwnedSlice(allocator);
}

/// Run the request under `limiter`, returning the response body, or null on an
/// allocation, spawn, or non-zero-exit failure. Caller owns the body.
pub fn run(
    allocator: std.mem.Allocator,
    limiter: *rate_limiter.RateLimiter,
    req: Request,
) ?[]u8 {
    limiter.acquire() catch return null;
    defer limiter.release();
    const argv = buildArgv(allocator, req) catch return null;
    defer allocator.free(argv);

    const res = std.process.run(allocator, infra_fs.currentIo(), .{
        .argv = argv,
        .stdout_limit = .limited(req.max_bytes),
        .stderr_limit = .limited(req.max_bytes),
    }) catch return null;
    allocator.free(res.stderr);
    if (!res.term.success()) {
        allocator.free(res.stdout);
        return null;
    }
    return res.stdout;
}
