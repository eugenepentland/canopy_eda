//! Resolves Component Search Engine HTTP Basic-auth credentials for the MCP
//! part-sourcing tools. The model-download endpoint (`ga/model.php`) takes
//! plain HTTP Basic auth — the `CSE_EMAIL`/`CSE_PASSWORD` account, no session
//! cookie / CSRF / Cloudflare dance. The suggestion API (search / part
//! resolution / datasheet lookup) needs no auth at all, so only
//! `download_footprint` routes through here. Kept out of `mcp_tools` so the
//! auth policy lives in one place.
const std = @import("std");
const config = @import("../config.zig");
const json_writer = @import("../json_writer.zig");

/// Why credentials couldn't be resolved: neither configured, or password empty.
const ResolveError = error{
    NoAuthConfigured,
    NoPassword,
} || std.mem.Allocator.Error;

const no_auth_msg = "set CSE_EMAIL + CSE_PASSWORD in .env for part sourcing";
const no_password_msg = "CSE_EMAIL is set but CSE_PASSWORD is empty; provide the account password";

/// Stable, user-facing message for a `ResolveError`, for the MCP envelope.
fn resolveErrorMessage(err: ResolveError) []const u8 {
    return switch (err) {
        error.NoAuthConfigured => no_auth_msg,
        error.NoPassword => no_password_msg,
        error.OutOfMemory => "out of memory",
    };
}

/// Resolve the CSE Basic-auth argument as the curl `-u` value
/// (`email:password`), owned by `allocator` (request-scoped). curl splits `-u`
/// on the FIRST colon, and an email can't contain a colon, so a password with
/// colons is preserved.
fn resolve(allocator: std.mem.Allocator) ResolveError![]const u8 {
    const email = config.cseEmail(allocator) orelse return error.NoAuthConfigured;
    const password = config.csePassword(allocator) orelse return error.NoPassword;
    return std.fmt.allocPrint(allocator, "{s}:{s}", .{ email, password });
}

/// `resolve`, but on failure write the standard `{"ok":false,"error":…}`
/// envelope to `w` and return null — the caller then just `orelse return false`.
pub fn resolveOrWrite(w: anytype, allocator: std.mem.Allocator) !?[]const u8 {
    return resolve(allocator) catch |err| {
        try w.writeAll("{\"ok\":false,\"error\":");
        try json_writer.writeString(w, resolveErrorMessage(err));
        try w.writeAll("}");
        return null;
    };
}
