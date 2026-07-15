//! Resolves a Component Search Engine `connect.sid` for the MCP part-sourcing
//! tools. Preference: a `CSE_CONNECT_SID` manual override when set, else a
//! fresh auto-login from `CSE_EMAIL`/`CSE_PASSWORD`. Kept out of `mcp_tools`
//! so the session policy lives in one place. No caching: a download is
//! infrequent, so each call logs in fresh rather than holding process-global
//! session state.
const std = @import("std");
const config = @import("../config.zig");
const component_search = @import("component_search.zig");
const json_writer = @import("../json_writer.zig");

/// Why a session couldn't be resolved: no configured auth, or a login failure.
pub const ResolveError = error{
    NoAuthConfigured,
    NoPassword,
} || component_search.LoginError;

const no_auth_msg = "set CSE_EMAIL + CSE_PASSWORD (or CSE_CONNECT_SID) for part sourcing";
const no_password_msg = "CSE_PASSWORD is set empty; provide the account password";

/// Stable, user-facing message for a `ResolveError`, for the MCP envelope.
pub fn resolveErrorMessage(err: ResolveError) []const u8 {
    return switch (err) {
        error.NoAuthConfigured => no_auth_msg,
        error.NoPassword => no_password_msg,
        error.LoginRequestFailed,
        error.NoCsrfSecret,
        error.InvalidCredentials,
        error.NoSession,
        error.OutOfMemory,
        => component_search.loginErrorMessage(@errorCast(err)),
    };
}

/// Resolve a CSE `connect.sid` using `allocator` (request-scoped). Returns the
/// `CSE_CONNECT_SID` override when set, else logs in with the account
/// credentials. The returned slice is owned by `allocator`.
pub fn resolve(allocator: std.mem.Allocator) ResolveError![]const u8 {
    // Credentials win: an account can always mint a fresh session, so having
    // CSE_EMAIL configured commits to auto-login (a stale leftover
    // CSE_CONNECT_SID must not silently shadow it). CSE_CONNECT_SID is only the
    // fallback when no credentials are set — a bare sid wrapped as a Cookie
    // header (sent verbatim by the transport; lacks __cf_bm, so downloads may
    // still fail — auto-login is the reliable path).
    if (config.cseEmail(allocator)) |email| {
        const password = config.csePassword(allocator) orelse return error.NoPassword;
        return component_search.login(allocator, email, password);
    }
    if (config.cseConnectSid(allocator)) |s|
        return try std.fmt.allocPrint(allocator, "connect.sid={s}", .{s});
    return error.NoAuthConfigured;
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
