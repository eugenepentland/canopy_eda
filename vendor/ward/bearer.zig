//! Bearer middleware — `requireBearer` composes the allowlist, verdict cache,
//! and an injected introspection verifier into the action an MCP resource server
//! takes for a request carrying an OAuth access token.
//!
//! Order mirrors `requireUser`: allowlisted paths (e.g. the protected-resource
//! metadata document) bypass verification; otherwise the bearer token is pulled
//! from the `Authorization` header, the cache is consulted, and on a miss the
//! injected verifier is called. Only authorized verdicts are cached; an inactive
//! token yields a 401 challenge and an unavailable verifier fails closed with a
//! 503 — never open. The verifier is any value exposing
//! `verify(allocator, token) !BearerVerdict` (a fake in tests, the
//! `BearerHttpVerifier` in production), so the pipeline stays network-free under
//! unit test. `hasScope` / `audienceMatches` are the pure gates an app enforces
//! on the granted identity before serving a tool.

const std = @import("std");
const verdict_mod = @import("verdict.zig");
const cache_mod = @import("cache.zig");
const allowlist_mod = @import("allowlist.zig");

const Cache = cache_mod.Cache;
const Allowlist = allowlist_mod.Allowlist;

/// A user's access role, reused from the verdict module so a bearer identity
/// stays role-complete.
pub const Role = verdict_mod.Role;

/// Case-insensitive `Authorization` scheme a bearer token is presented under.
const bearer_scheme = "bearer";
/// Length in hex characters of a well-formed access token (16 bytes, like a
/// session token), matching the `token=<32-hex>` the introspection endpoint reads.
const token_hex_len: usize = 32;

/// The identity behind an authorized bearer verdict: the resolved username, the
/// user's role, and the space-separated scope the grant carries. On a
/// `BearerVerdict.authorized` the strings are owned by the verifier; on a
/// `BearerAction.allow` they are owned by the caller's allocator.
pub const BearerIdentity = struct {
    /// The authenticated username the token maps to.
    username: []const u8,
    /// The user's access role (`unknown` for an unrecognized role string).
    role: Role,
    /// Canonical space-separated scope the grant was issued for.
    scope: []const u8,
};

/// An introspection verifier's answer about a presented bearer token.
pub const BearerVerdict = union(enum) {
    /// The token is a live access grant (identity owned by the verifier).
    authorized: BearerIdentity,
    /// The token is absent, unknown, expired, or otherwise not active.
    inactive,
    /// The ward server was unreachable or answered with a server error.
    unavailable,
};

/// The action an MCP resource server takes for a bearer request. The caller
/// frames the HTTP response: `unauthorized` carries the `WWW-Authenticate`
/// challenge value to return with a 401; `fail_closed` is a 503.
pub const BearerAction = union(enum) {
    /// The route is public; serve it with no authenticated identity.
    public,
    /// Serve the request as this authenticated identity (owned strings).
    allow: BearerIdentity,
    /// Reject with 401; the payload is the `WWW-Authenticate` header value
    /// (borrowed from the gate, so it is not freed by `deinit`).
    unauthorized: []const u8,
    /// Fail closed: respond 503 rather than admit an unverifiable request.
    fail_closed,

    /// Releases the owned strings an `allow` action carries; other variants no-op.
    pub fn deinit(self: BearerAction, allocator: std.mem.Allocator) void {
        switch (self) {
            .allow => |id| freeIdentity(allocator, id),
            .public, .unauthorized, .fail_closed => {},
        }
    }
};

/// The request facts `requireBearer` inspects.
pub const BearerRequest = struct {
    /// Raw value of the request's `Authorization` header, or null when absent.
    authorization: ?[]const u8,
    /// Request path, matched against the public-route allowlist.
    path: []const u8,
};

/// The policy `requireBearer` enforces a request against.
pub const BearerGate = struct {
    /// Public-route allowlist; matching paths bypass verification.
    allowlist: Allowlist,
    /// Pre-built `WWW-Authenticate` challenge returned on an unauthorized request
    /// (borrowed for the request's lifetime; build it with `resource.bearerChallenge`).
    challenge: []const u8,
    /// Verdict cache shared across requests, keyed by hashed token.
    cache: *Cache,
    /// Current time in whole unix-epoch seconds (injected clock reading).
    now: i64,
};

/// Resolves the action for `request` under `gate`, calling `verifier` only on a
/// cache miss for a token-bearing, non-public path. The returned action owns any
/// identity strings it carries; release them with `BearerAction.deinit`.
pub fn requireBearer(
    allocator: std.mem.Allocator,
    gate: BearerGate,
    request: BearerRequest,
    verifier: anytype,
) std.mem.Allocator.Error!BearerAction {
    if (gate.allowlist.isPublic(request.path)) return .public;
    const token = extractBearer(request.authorization) orelse return .{ .unauthorized = gate.challenge };
    if (gate.cache.get(token, gate.now)) |hit| {
        const cached: BearerIdentity = .{ .username = hit.username, .role = hit.role, .scope = hit.scope };
        return .{ .allow = try dupeIdentity(allocator, cached) };
    }
    const verdict = try verifier.verify(allocator, token);
    return applyBearerVerdict(allocator, gate, token, verdict);
}

/// Applies a freshly fetched verdict: an authorized grant is cached and served;
/// anything else defers to `decideBearer`. The verifier's owned identity strings
/// are released here after they have been copied into the cache and the action.
fn applyBearerVerdict(
    allocator: std.mem.Allocator,
    gate: BearerGate,
    token: []const u8,
    verdict: BearerVerdict,
) std.mem.Allocator.Error!BearerAction {
    switch (verdict) {
        .authorized => |id| {
            defer freeIdentity(allocator, id);
            try gate.cache.put(token, id.username, id.role, id.scope, gate.now);
            return .{ .allow = try dupeIdentity(allocator, id) };
        },
        else => return decideBearer(allocator, verdict, gate.challenge),
    }
}

/// Maps a bearer verdict to the action a resource server takes: an authorized
/// grant yields an allocator-owned identity; an inactive token yields the 401
/// `challenge`; an unavailable verifier fails closed. Owned strings are released
/// via `BearerAction.deinit`.
pub fn decideBearer(
    allocator: std.mem.Allocator,
    verdict: BearerVerdict,
    challenge: []const u8,
) std.mem.Allocator.Error!BearerAction {
    return switch (verdict) {
        .authorized => |id| .{ .allow = try dupeIdentity(allocator, id) },
        .inactive => .{ .unauthorized = challenge },
        .unavailable => .fail_closed,
    };
}

/// Extracts the bearer token from a raw `Authorization` header value: the scheme
/// must be `Bearer` (case-insensitive) followed by exactly one space and a
/// strict 32-character lowercase-hex token. Anything else — absent header, wrong
/// scheme, extra spaces, or a malformed token — yields null before any lookup.
pub fn extractBearer(header_value: ?[]const u8) ?[]const u8 {
    const value = header_value orelse return null;
    const space = std.mem.indexOfScalar(u8, value, ' ') orelse return null;
    if (!std.ascii.eqlIgnoreCase(value[0..space], bearer_scheme)) return null;
    const candidate = value[space + 1 ..];
    return if (isHexToken(candidate)) candidate else null;
}

/// Reports whether `candidate` is a well-formed access token: exactly
/// `token_hex_len` lowercase-hex characters.
fn isHexToken(candidate: []const u8) bool {
    if (candidate.len != token_hex_len) return false;
    for (candidate) |ch| {
        const is_digit = ch >= '0' and ch <= '9';
        const is_lower_hex = ch >= 'a' and ch <= 'f';
        if (!is_digit and !is_lower_hex) return false;
    }
    return true;
}

/// Reports whether `scope` (space-separated) grants `needed` as a whole entry —
/// a prefix or substring of an entry does not count. Apps enforce a tool's
/// required scope with `if (!hasScope(auth.scope, "...")) ...`.
pub fn hasScope(scope: []const u8, needed: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, scope, ' ');
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry, needed)) return true;
    }
    return false;
}

/// Reports whether a token's audience exactly equals the resource the app
/// expects — an MCP tool rejects a token minted for a different audience.
pub fn audienceMatches(aud: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, aud, expected);
}

/// Copies an identity's owned strings into `allocator`, leaving the source intact.
fn dupeIdentity(allocator: std.mem.Allocator, id: BearerIdentity) std.mem.Allocator.Error!BearerIdentity {
    const username = try allocator.dupe(u8, id.username);
    errdefer allocator.free(username);
    const scope = try allocator.dupe(u8, id.scope);
    return .{ .username = username, .role = id.role, .scope = scope };
}

/// Frees the owned strings of one bearer identity.
fn freeIdentity(allocator: std.mem.Allocator, id: BearerIdentity) void {
    allocator.free(id.username);
    allocator.free(id.scope);
}

/// Test double: answers every verify call with a preset verdict and counts calls,
/// standing in for the network-backed `BearerHttpVerifier` in the pure tests.
const FakeBearerVerifier = struct {
    verdict: BearerVerdict,
    calls: u32 = 0,

    fn verify(
        self: *FakeBearerVerifier,
        allocator: std.mem.Allocator,
        token: []const u8,
    ) std.mem.Allocator.Error!BearerVerdict {
        _ = token;
        self.calls += 1;
        return switch (self.verdict) {
            .authorized => |id| .{ .authorized = .{
                .username = try allocator.dupe(u8, id.username),
                .role = id.role,
                .scope = try allocator.dupe(u8, id.scope),
            } },
            else => self.verdict,
        };
    }
};

const access_hex = "0011223344556677889900aabbccddee";
const bearer_prefix = "Bearer ";
const scope_pair = "files:read files:write";
/// A stand-in challenge string the pipeline passes through unchanged.
const test_challenge = "Bearer resource_metadata=absent";
/// The authorized verdict the middleware tests hand their fake verifier.
const authed_verdict: BearerVerdict =
    .{ .authorized = .{ .username = "alice", .role = .member, .scope = scope_pair } };
const empty_list = [_][]const u8{};
const public_list = [_][]const u8{"/.well-known/oauth-protected-resource"};
const mw_path = "/mcp";

/// Builds a `BearerGate` for the tests from patterns, cache, and clock.
fn testGate(patterns: []const []const u8, cache: *Cache, now: i64) BearerGate {
    return .{ .allowlist = .{ .patterns = patterns }, .challenge = test_challenge, .cache = cache, .now = now };
}

// spec: Bearer extraction - A Bearer authorization header yields its token under a case-insensitive scheme
test "extractBearer yields the token for a case-insensitive scheme" {
    try std.testing.expectEqualStrings(access_hex, extractBearer(bearer_prefix ++ access_hex).?);
    try std.testing.expectEqualStrings(access_hex, extractBearer("bEaReR " ++ access_hex).?);
}

// spec: Bearer extraction - A malformed Bearer authorization header yields no token before any lookup
test "extractBearer rejects a malformed authorization header" {
    try std.testing.expect(extractBearer(null) == null);
    try std.testing.expect(extractBearer("Basic " ++ access_hex) == null);
    try std.testing.expect(extractBearer("Bearer  " ++ access_hex) == null);
    try std.testing.expect(extractBearer(bearer_prefix ++ access_hex ++ "ff") == null);
    try std.testing.expect(extractBearer(bearer_prefix ++ "00112233") == null);
    try std.testing.expect(extractBearer(bearer_prefix ++ "0011223344556677889900AABBCCDDEE") == null);
    try std.testing.expect(extractBearer("Bearer") == null);
}

// spec: Bearer verdicts - An authorized bearer verdict resolves to the user identity role and scope
test "decideBearer resolves an authorized identity" {
    const verdict: BearerVerdict = .{ .authorized = .{ .username = "alice", .role = .admin, .scope = "files:read" } };
    const action = try decideBearer(std.testing.allocator, verdict, test_challenge);
    defer action.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("alice", action.allow.username);
    try std.testing.expectEqual(Role.admin, action.allow.role);
    try std.testing.expectEqualStrings("files:read", action.allow.scope);
}

// spec: Bearer verdicts - An inactive bearer verdict yields the challenge action
test "decideBearer yields the challenge for an inactive verdict" {
    const action = try decideBearer(std.testing.allocator, .inactive, test_challenge);
    defer action.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(test_challenge, action.unauthorized);
}

// spec: Bearer verdicts - An unavailable bearer verdict fails closed instead of admitting the request
test "decideBearer fails closed for an unavailable verdict" {
    const action = try decideBearer(std.testing.allocator, .unavailable, test_challenge);
    defer action.deinit(std.testing.allocator);
    try std.testing.expect(std.meta.activeTag(action) == .fail_closed);
}

// spec: Scope and audience checks - A scope check matches a whole space-separated entry not a prefix or absent one
test "hasScope matches a whole entry only" {
    try std.testing.expect(hasScope(scope_pair, "files:write"));
    try std.testing.expect(!hasScope(scope_pair, "files"));
    try std.testing.expect(!hasScope(scope_pair, "admin"));
    try std.testing.expect(!hasScope("", "files:read"));
}

// spec: Scope and audience checks - An audience check accepts only an exact match
test "audienceMatches accepts only an exact match" {
    try std.testing.expect(audienceMatches("mcp-files", "mcp-files"));
    try std.testing.expect(!audienceMatches("mcp-files", "mcp-file"));
    try std.testing.expect(!audienceMatches("mcp-files", "mcp-files-x"));
}

// spec: Bearer middleware - An allowlisted bearer request is served without consulting the verifier
test "requireBearer serves an allowlisted path without the verifier" {
    var cache = Cache.init(std.testing.allocator, 30);
    defer cache.deinit();
    var verifier = FakeBearerVerifier{ .verdict = .unavailable };
    const gate = testGate(&public_list, &cache, 100);
    const request = BearerRequest{ .authorization = null, .path = "/.well-known/oauth-protected-resource" };
    const action = try requireBearer(std.testing.allocator, gate, request, &verifier);
    try std.testing.expect(std.meta.activeTag(action) == .public);
    try std.testing.expectEqual(@as(u32, 0), verifier.calls);
}

// spec: Bearer middleware - A bearer request with no token is challenged without consulting the verifier
test "requireBearer challenges a request with no token" {
    var cache = Cache.init(std.testing.allocator, 30);
    defer cache.deinit();
    var verifier = FakeBearerVerifier{ .verdict = authed_verdict };
    const gate = testGate(&empty_list, &cache, 100);
    const request = BearerRequest{ .authorization = null, .path = mw_path };
    const action = try requireBearer(std.testing.allocator, gate, request, &verifier);
    defer action.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings(test_challenge, action.unauthorized);
    try std.testing.expectEqual(@as(u32, 0), verifier.calls);
}

// spec: Bearer middleware - An authorized bearer token is verified once and then served from the cache
test "requireBearer verifies once then serves from the cache" {
    var cache = Cache.init(std.testing.allocator, 30);
    defer cache.deinit();
    var verifier = FakeBearerVerifier{ .verdict = authed_verdict };
    var gate = testGate(&empty_list, &cache, 100);
    const request = BearerRequest{ .authorization = bearer_prefix ++ access_hex, .path = mw_path };
    const first = try requireBearer(std.testing.allocator, gate, request, &verifier);
    defer first.deinit(std.testing.allocator);
    gate.now = 120;
    const second = try requireBearer(std.testing.allocator, gate, request, &verifier);
    defer second.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("alice", first.allow.username);
    try std.testing.expectEqualStrings(scope_pair, second.allow.scope);
    try std.testing.expectEqual(@as(u32, 1), verifier.calls);
}

// spec: Bearer middleware - An inactive bearer verdict leaves the cache empty so a later grant is seen immediately
test "requireBearer does not cache an inactive verdict" {
    var cache = Cache.init(std.testing.allocator, 30);
    defer cache.deinit();
    var verifier = FakeBearerVerifier{ .verdict = .inactive };
    const gate = testGate(&empty_list, &cache, 100);
    const request = BearerRequest{ .authorization = bearer_prefix ++ access_hex, .path = mw_path };
    const action = try requireBearer(std.testing.allocator, gate, request, &verifier);
    defer action.deinit(std.testing.allocator);
    try std.testing.expect(std.meta.activeTag(action) == .unauthorized);
    try std.testing.expect(cache.entries.count() == 0);
}

// spec: Bearer middleware - An unavailable bearer verifier makes the request fail closed
test "requireBearer fails closed on an unavailable verifier" {
    var cache = Cache.init(std.testing.allocator, 30);
    defer cache.deinit();
    var verifier = FakeBearerVerifier{ .verdict = .unavailable };
    const gate = testGate(&empty_list, &cache, 100);
    const request = BearerRequest{ .authorization = bearer_prefix ++ access_hex, .path = mw_path };
    const action = try requireBearer(std.testing.allocator, gate, request, &verifier);
    try std.testing.expect(std.meta.activeTag(action) == .fail_closed);
}
