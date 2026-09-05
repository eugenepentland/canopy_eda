//! Request middleware — `requireUser` composes the allowlist, verdict cache, and
//! an injected verifier into the action a protected app takes for a request.
//!
//! Order: allowlisted paths bypass verification; otherwise the session cookie is
//! extracted, the cache is consulted, and on a miss the injected verifier is
//! called. Only authorized verdicts are cached; unauthorized redirects to login
//! and unavailable fails closed. The verifier is any value exposing
//! `verify(allocator, token) !Verdict` (a fake in tests, the `HttpVerifier` in
//! production), so the pipeline stays network-free under unit test.

const std = @import("std");
const verdict_mod = @import("verdict.zig");
const cache_mod = @import("cache.zig");
const allowlist_mod = @import("allowlist.zig");

const Verdict = verdict_mod.Verdict;
const Action = verdict_mod.Action;
const decide = verdict_mod.decide;
const Cache = cache_mod.Cache;
const Allowlist = allowlist_mod.Allowlist;

/// Name of the session cookie the ward server issues and the middleware reads.
pub const session_cookie_name = "ward_session";

/// Request header an app sends to name itself so /verify records service activity.
pub const service_header_name = "x-ward-service";
/// Request header an app sends to declare its browsable URL, so the home page can
/// link to it instead of guessing a subdomain from the service name.
pub const service_url_header_name = "x-ward-service-url";
/// Request header an app sends to bind the request to an org by slug, so /verify
/// answers with the user's role in that org rather than the global role.
pub const org_header_name = "x-ward-org";
/// Response header /verify tags a success with, carrying the user's role.
pub const role_header_name = "x-ward-role";

/// The request facts `requireUser` inspects.
pub const Request = struct {
    /// Raw value of the request's `Cookie` header, or null when absent.
    cookie_header: ?[]const u8,
    /// Request path, matched against the public-route allowlist.
    path: []const u8,
    /// Absolute URL of the current request, encoded into the login redirect.
    url: []const u8,
};

/// The policy `requireUser` enforces a request against.
pub const Gate = struct {
    /// Public-route allowlist; matching paths bypass verification.
    allowlist: Allowlist,
    /// Login URL a rejected request is redirected to.
    login_url: []const u8,
    /// Verdict cache shared across requests, keyed by hashed token.
    cache: *Cache,
    /// Current time in whole unix-epoch seconds (injected clock reading).
    now: i64,
};

/// Resolves the action for `request` under `gate`, calling `verifier` only on a
/// cache miss for a cookie-bearing, non-public path. The returned `Action` owns
/// any string it carries; release it with `Action.deinit`.
pub fn requireUser(
    allocator: std.mem.Allocator,
    gate: Gate,
    request: Request,
    verifier: anytype,
) std.mem.Allocator.Error!Action {
    if (gate.allowlist.isPublic(request.path)) return .public;
    const token = sessionToken(request.cookie_header) orelse
        return decide(allocator, .unauthorized, gate.login_url, request.url);
    if (gate.cache.get(token, gate.now)) |hit| {
        return .{ .allow = try allocator.dupe(u8, hit.username) };
    }
    const verdict = try verifier.verify(allocator, token);
    return applyVerdict(allocator, gate, request, token, verdict);
}

/// Applies a freshly fetched verdict: caches and serves an authorized user,
/// otherwise defers to `decide` (redirect for unauthorized, fail-closed for
/// unavailable). The verifier's owned username is released here.
fn applyVerdict(
    allocator: std.mem.Allocator,
    gate: Gate,
    request: Request,
    token: []const u8,
    verdict: Verdict,
) std.mem.Allocator.Error!Action {
    switch (verdict) {
        .authorized => |auth| {
            defer allocator.free(auth.username);
            // A session verdict carries no scope; the empty string keeps the
            // shared cache entry shape while the bearer path stores a real scope.
            try gate.cache.put(token, auth.username, auth.role, "", gate.now);
            return .{ .allow = try allocator.dupe(u8, auth.username) };
        },
        else => return decide(allocator, verdict, gate.login_url, request.url),
    }
}

/// Extracts the ward session token from a raw `Cookie` header value, or null
/// when the header is absent or carries no non-empty session cookie.
fn sessionToken(cookie_header: ?[]const u8) ?[]const u8 {
    const header = cookie_header orelse return null;
    var it = std.mem.splitScalar(u8, header, ';');
    while (it.next()) |pair| {
        const trimmed = std.mem.trim(u8, pair, " ");
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        if (std.mem.eql(u8, trimmed[0..eq], session_cookie_name)) {
            const value = trimmed[eq + 1 ..];
            return if (value.len == 0) null else value;
        }
    }
    return null;
}

/// Test double: answers every verify call with a preset verdict and counts calls,
/// standing in for the network-backed `HttpVerifier` in the pure-pipeline tests.
const FakeVerifier = struct {
    verdict: Verdict,
    calls: u32 = 0,

    fn verify(
        self: *FakeVerifier,
        allocator: std.mem.Allocator,
        token: []const u8,
    ) std.mem.Allocator.Error!Verdict {
        _ = token;
        self.calls += 1;
        return switch (self.verdict) {
            .authorized => |auth| .{
                .authorized = .{ .username = try allocator.dupe(u8, auth.username), .role = auth.role },
            },
            else => self.verdict,
        };
    }
};

const empty_list = [_][]const u8{};
const public_list = [_][]const u8{"/healthz"};
const mw_cookie = "ward_session=abc123def456";
const mw_path = "/dashboard";
const encoded_url = "https%3A%2F%2Fwiki.apps.example%2Fdashboard";

/// Builds a `Gate` for the tests from patterns, login URL, cache, and clock.
fn testGate(patterns: []const []const u8, login_url: []const u8, cache: *Cache, now: i64) Gate {
    return .{ .allowlist = .{ .patterns = patterns }, .login_url = login_url, .cache = cache, .now = now };
}

// spec: Request middleware - An allowlisted request is served without consulting the verifier
test "allowlisted request bypasses the verifier" {
    const login = "https://auth.apps.example/login";
    const app_url = "https://wiki.apps.example/dashboard";
    var cache = Cache.init(std.testing.allocator, 30);
    defer cache.deinit();
    var verifier = FakeVerifier{ .verdict = .unavailable };
    const gate = testGate(&public_list, login, &cache, 100);
    const request = Request{ .cookie_header = null, .path = "/healthz", .url = app_url };
    const action = try requireUser(std.testing.allocator, gate, request, &verifier);
    try std.testing.expect(std.meta.activeTag(action) == .public);
    try std.testing.expectEqual(@as(u32, 0), verifier.calls);
}

// spec: Request middleware - A request without a session cookie is redirected without consulting the verifier
test "cookieless request is redirected to login" {
    const login = "https://auth.apps.example/login";
    const app_url = "https://wiki.apps.example/dashboard";
    var cache = Cache.init(std.testing.allocator, 30);
    defer cache.deinit();
    var verifier = FakeVerifier{ .verdict = .{ .authorized = .{ .username = "alice", .role = .member } } };
    const gate = testGate(&empty_list, login, &cache, 100);
    const request = Request{ .cookie_header = null, .path = mw_path, .url = app_url };
    const action = try requireUser(std.testing.allocator, gate, request, &verifier);
    defer action.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(login ++ "?rd=" ++ encoded_url, action.redirect);
    try std.testing.expectEqual(@as(u32, 0), verifier.calls);
}

// spec: Request middleware - An authorized token is verified once and then served from the cache
test "authorized token is verified once then cached" {
    const login = "https://auth.apps.example/login";
    const app_url = "https://wiki.apps.example/dashboard";
    var cache = Cache.init(std.testing.allocator, 30);
    defer cache.deinit();
    var verifier = FakeVerifier{ .verdict = .{ .authorized = .{ .username = "alice", .role = .member } } };
    var gate = testGate(&empty_list, login, &cache, 100);
    const request = Request{ .cookie_header = mw_cookie, .path = mw_path, .url = app_url };
    const first = try requireUser(std.testing.allocator, gate, request, &verifier);
    defer first.deinit(std.testing.allocator);
    gate.now = 120;
    const second = try requireUser(std.testing.allocator, gate, request, &verifier);
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("alice", first.allow);
    try std.testing.expectEqualStrings("alice", second.allow);
    try std.testing.expectEqual(@as(u32, 1), verifier.calls);
}

// spec: Request middleware - An unauthorized verdict leaves the cache empty so a later login is seen immediately
test "unauthorized verdict is not cached" {
    const login = "https://auth.apps.example/login";
    const app_url = "https://wiki.apps.example/dashboard";
    var cache = Cache.init(std.testing.allocator, 30);
    defer cache.deinit();
    var verifier = FakeVerifier{ .verdict = .unauthorized };
    const gate = testGate(&empty_list, login, &cache, 100);
    const request = Request{ .cookie_header = mw_cookie, .path = mw_path, .url = app_url };
    const action = try requireUser(std.testing.allocator, gate, request, &verifier);
    defer action.deinit(std.testing.allocator);
    try std.testing.expect(std.meta.activeTag(action) == .redirect);
    try std.testing.expect(cache.entries.count() == 0);
}

// spec: Request middleware - An unavailable verifier makes the request fail closed with a 503
test "unavailable verifier fails closed" {
    const login = "https://auth.apps.example/login";
    const app_url = "https://wiki.apps.example/dashboard";
    var cache = Cache.init(std.testing.allocator, 30);
    defer cache.deinit();
    var verifier = FakeVerifier{ .verdict = .unavailable };
    const gate = testGate(&empty_list, login, &cache, 100);
    const request = Request{ .cookie_header = mw_cookie, .path = mw_path, .url = app_url };
    const action = try requireUser(std.testing.allocator, gate, request, &verifier);
    try std.testing.expect(std.meta.activeTag(action) == .fail_closed);
}

// spec: Middleware org - The middleware names the org binding request header X-Ward-Org
test "org header is named x-ward-org" {
    try std.testing.expectEqualStrings("x-ward-org", org_header_name);
}
