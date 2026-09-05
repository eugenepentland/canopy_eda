//! Verdict and access decision — the verify-port answer plus the pure mapping
//! from a token's verdict to the action a protected app must take.
//!
//! A verifier answers with a `Verdict` (authorized / unauthorized / unavailable);
//! `decide` turns that verdict, the login URL, and the current URL into an
//! `Action` the app carries out: serve the user, redirect to login with an
//! encoded return target, or fail closed. Pure — no clock, no I/O, no network.

const std = @import("std");

/// A user's access role as the middleware understands it. Mirrors the server's
/// member/admin roles plus an `unknown` fallback so the library never hard-fails
/// on a role string a newer server emits; `unknown` ranks below `member`, so an
/// unrecognized role is treated as the least privilege.
pub const Role = enum {
    /// Least-privileged known role.
    member,
    /// Elevated role admitted to the admin portal.
    admin,
    /// A role string this library version does not recognize (forward-compat).
    unknown,

    /// Orders roles by privilege for `roleAtLeast`; `unknown` sits below all.
    fn rank(self: Role) u8 {
        return switch (self) {
            .unknown => 0,
            .member => 1,
            .admin => 2,
        };
    }
};

/// The identity behind an authorized verdict: the resolved username and role.
pub const Authorized = struct {
    /// The authenticated username.
    username: []const u8,
    /// The user's access role (`unknown` for an unrecognized role string).
    role: Role,
};

/// A verifier's answer about a session token.
pub const Verdict = union(enum) {
    /// The token names an authenticated user (username plus resolved role).
    authorized: Authorized,
    /// The token is absent, unknown, or expired — no authenticated user.
    unauthorized,
    /// The ward server was unreachable or answered with a server error.
    unavailable,
};

/// Maps an `X-Ward-Role` header value to a `Role`, folding an absent or
/// unrecognized string onto `unknown` rather than failing.
pub fn roleFromText(text: ?[]const u8) Role {
    const value = text orelse return .unknown;
    if (std.mem.eql(u8, value, "member")) return .member;
    if (std.mem.eql(u8, value, "admin")) return .admin;
    return .unknown;
}

/// Reports whether `verdict` authorizes a user whose role meets `required`. A
/// non-authorized verdict, or an authorized one whose role ranks below the
/// requirement, is rejected — the pure gate an app calls to demand a role.
pub fn roleAtLeast(verdict: Verdict, required: Role) bool {
    return switch (verdict) {
        .authorized => |auth| auth.role.rank() >= required.rank(),
        else => false,
    };
}

/// The action a protected app takes for a request, chosen by `decide`.
pub const Action = union(enum) {
    /// The route is public; serve it with no authenticated user.
    public,
    /// Serve the request as this authenticated user (owned username).
    allow: []const u8,
    /// Redirect to this login location (owned `Location` header value).
    redirect: []const u8,
    /// Fail closed: respond 503 rather than admit an unverifiable request.
    fail_closed,

    /// Releases any owned string this action carries; other variants no-op.
    pub fn deinit(self: Action, allocator: std.mem.Allocator) void {
        switch (self) {
            .allow => |username| allocator.free(username),
            .redirect => |location| allocator.free(location),
            .public, .fail_closed => {},
        }
    }
};

/// Query-parameter prefix carrying the url-encoded return target.
const rd_prefix = "?rd=";

/// Maps a verdict to the action a protected app takes. `authorized` yields an
/// allocator-owned username; `unauthorized` yields an allocator-owned redirect
/// to `login_url` carrying the percent-encoded `current_url`; `unavailable`
/// fails closed. Owned strings are released via `Action.deinit`.
pub fn decide(
    allocator: std.mem.Allocator,
    verdict: Verdict,
    login_url: []const u8,
    current_url: []const u8,
) std.mem.Allocator.Error!Action {
    return switch (verdict) {
        .authorized => |auth| .{ .allow = try allocator.dupe(u8, auth.username) },
        .unauthorized => .{ .redirect = try loginRedirect(allocator, login_url, current_url) },
        .unavailable => .fail_closed,
    };
}

/// Builds `<login_url>?rd=<percent-encoded current_url>` into owned memory.
fn loginRedirect(
    allocator: std.mem.Allocator,
    login_url: []const u8,
    current_url: []const u8,
) std.mem.Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, login_url);
    try out.appendSlice(allocator, rd_prefix);
    try percentEncode(allocator, &out, current_url);
    return out.toOwnedSlice(allocator);
}

/// Percent-encodes `text` into `out`, escaping every byte outside the RFC 3986
/// unreserved set so the return target survives as one query-parameter value.
fn percentEncode(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(u8),
    text: []const u8,
) std.mem.Allocator.Error!void {
    for (text) |byte| {
        if (isUnreserved(byte)) {
            try out.append(allocator, byte);
        } else {
            const encoded = std.fmt.bytesToHex([_]u8{byte}, .upper);
            try out.append(allocator, '%');
            try out.appendSlice(allocator, &encoded);
        }
    }
}

/// Reports whether `byte` is an RFC 3986 unreserved character, left un-escaped.
fn isUnreserved(byte: u8) bool {
    if (std.ascii.isAlphanumeric(byte)) return true;
    return switch (byte) {
        '-', '.', '_', '~' => true,
        else => false,
    };
}

// spec: Access decision - An unauthorized verdict redirects to the login url carrying the return target
test "unauthorized decision redirects to login" {
    const login = "https://auth.apps.example/login";
    const action = try decide(std.testing.allocator, .unauthorized, login, "/dashboard");
    defer action.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(login ++ "?rd=%2Fdashboard", action.redirect);
}

// spec: Access decision - An authorized verdict resolves to the requesting user's username
test "authorized decision resolves the username" {
    const login = "https://auth.apps.example/login";
    const verdict: Verdict = .{ .authorized = .{ .username = "alice", .role = .member } };
    const action = try decide(std.testing.allocator, verdict, login, "/dashboard");
    defer action.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("alice", action.allow);
}

// spec: Middleware roles - An unrecognized or absent role string resolves to the unknown role ranked below member
test "roleFromText folds unknown and absent roles onto unknown" {
    try std.testing.expectEqual(Role.member, roleFromText("member"));
    try std.testing.expectEqual(Role.admin, roleFromText("admin"));
    try std.testing.expectEqual(Role.unknown, roleFromText("wizard"));
    try std.testing.expectEqual(Role.unknown, roleFromText(null));
    // unknown ranks below member, so it never satisfies a member-or-above demand.
    const unknown_role: Verdict = .{ .authorized = .{ .username = "x", .role = .unknown } };
    try std.testing.expect(!roleAtLeast(unknown_role, .member));
}

// spec: Middleware roles - Demanding a role admits a sufficient verdict and rejects a lesser or non-authorized one
test "roleAtLeast admits a sufficient role and rejects lesser or non-authorized verdicts" {
    const admin_v: Verdict = .{ .authorized = .{ .username = "a", .role = .admin } };
    const member_v: Verdict = .{ .authorized = .{ .username = "m", .role = .member } };
    try std.testing.expect(roleAtLeast(admin_v, .admin));
    try std.testing.expect(roleAtLeast(admin_v, .member));
    try std.testing.expect(!roleAtLeast(member_v, .admin));
    try std.testing.expect(roleAtLeast(member_v, .member));
    try std.testing.expect(!roleAtLeast(.unauthorized, .member));
    try std.testing.expect(!roleAtLeast(.unavailable, .admin));
}

// spec: Access decision - An unavailable verdict fails closed instead of admitting the request
test "unavailable decision fails closed" {
    const login = "https://auth.apps.example/login";
    const action = try decide(std.testing.allocator, .unavailable, login, "/dashboard");
    defer action.deinit(std.testing.allocator);
    try std.testing.expect(std.meta.activeTag(action) == .fail_closed);
}

// spec: Access decision - The redirect location percent-encodes the return target
test "redirect location percent-encodes the return target" {
    const login = "https://auth.apps.example/login";
    const action = try decide(std.testing.allocator, .unauthorized, login, "/dash board?x=1");
    defer action.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(login ++ "?rd=%2Fdash%20board%3Fx%3D1", action.redirect);
}
