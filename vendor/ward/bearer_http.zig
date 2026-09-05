//! Bearer introspection transport — the production bearer verifier the MCP
//! resource-server middleware injects.
//!
//! `BearerHttpVerifier` implements the `verify(allocator, token)` port over
//! `std.http.Client`: it POSTs `token=<token>` (form-encoded) to the configured
//! `WARD_INTROSPECT_URL` and parses the RFC 7662 introspection JSON. `active:true`
//! with an identity is an authorized verdict; `active:false` (or an active
//! response missing its identity) is inactive; a non-200 status, a transport
//! error, or a malformed body is unavailable, so the middleware fails closed.
//! Unknown JSON fields are ignored. This is one of the two library files
//! permitted `std.http` (see the `src/ward/bearer_http*` ban-net carve-out in
//! guardian.toml); the pure `parseIntrospection` core carries the unit-test
//! weight, and the tool runs on the LAN (no `CF-Connecting-IP`, so wardd does not
//! refuse it as a tunnel caller).

const std = @import("std");
const timeout = @import("timeout.zig");
const verdict_mod = @import("verdict.zig");
const bearer = @import("bearer.zig");
const http = @import("http.zig");

const BearerVerdict = bearer.BearerVerdict;

/// `Content-Type` sent with the form-encoded introspection request body.
const form_content_type = "application/x-www-form-urlencoded";
/// Upper bound on accepted introspection response bytes (a small JSON object).
const max_resp_bytes: usize = 1024;
/// JSON parse options: tolerate the fields wardd emits that this transport does
/// not read (`aud`, `exp`, …) rather than failing the parse.
const parse_opts: std.json.ParseOptions = .{ .ignore_unknown_fields = true };

/// The introspection JSON fields this transport reads; every other field wardd
/// emits (`aud`, `exp`, …) is ignored. `active` defaults false so a body that
/// omits it is treated as inactive rather than trusted.
const Introspection = struct {
    active: bool = false,
    username: ?[]const u8 = null,
    role: ?[]const u8 = null,
    scope: ?[]const u8 = null,
};

/// Parses an RFC 7662 introspection response body into a `BearerVerdict`.
/// `active:false`, or an active response missing its username or scope, is
/// `inactive` (a 401 to the caller); a body that is not valid JSON is
/// `unavailable` (fail closed). Unknown fields are ignored. The authorized
/// identity's strings are duplicated into `allocator`; only allocation failure
/// is surfaced as an error.
pub fn parseIntrospection(allocator: std.mem.Allocator, body: []const u8) std.mem.Allocator.Error!BearerVerdict {
    const parsed = std.json.parseFromSlice(Introspection, allocator, body, parse_opts) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .unavailable,
    };
    defer parsed.deinit();
    const doc = parsed.value;
    if (!doc.active) return .inactive;
    const username_raw = doc.username orelse return .inactive;
    const scope_raw = doc.scope orelse return .inactive;
    const username = try allocator.dupe(u8, username_raw);
    errdefer allocator.free(username);
    const scope = try allocator.dupe(u8, scope_raw);
    return .{ .authorized = .{
        .username = username,
        .role = verdict_mod.roleFromText(doc.role),
        .scope = scope,
    } };
}

/// A bearer verifier backed by a live `std.http.Client`, calling wardd's token
/// introspection endpoint. Inject a pointer to one as the middleware's `verifier`.
pub const BearerHttpVerifier = struct {
    /// HTTP client used for the introspection request (borrowed; caller owns it).
    client: *std.http.Client,
    /// Absolute introspection endpoint URL, e.g. `http://127.0.0.1:9000/oauth/introspect`.
    introspect_url: []const u8,
    /// Seconds the entire introspection exchange may take before it fails
    /// and the middleware fails closed; zero keeps the socket blocking unbounded.
    io_timeout_secs: u31 = http.default_io_timeout_secs,

    /// Introspects `token` at the configured endpoint: a 200 body is parsed by
    /// `parseIntrospection`; any other status or a transport failure is
    /// `unavailable`. Only allocation failure is surfaced as an error.
    pub fn verify(
        self: *BearerHttpVerifier,
        allocator: std.mem.Allocator,
        token: []const u8,
    ) std.mem.Allocator.Error!BearerVerdict {
        return timeout.run(std.mem.Allocator.Error!BearerVerdict, self.client.io, self.io_timeout_secs, verifyUnbounded, .{ self, allocator, token });
    }

    fn verifyUnbounded(self: *BearerHttpVerifier, allocator: std.mem.Allocator, token: []const u8) std.mem.Allocator.Error!BearerVerdict {
        const body = try std.fmt.allocPrint(allocator, "token={s}", .{token});
        defer allocator.free(body);
        const uri = std.Uri.parse(self.introspect_url) catch return .unavailable;
        var req = self.client.request(.POST, uri, .{
            .redirect_behavior = .unhandled,
            .extra_headers = &.{.{ .name = "content-type", .value = form_content_type }},
        }) catch return .unavailable;
        defer req.deinit();
        req.sendBodyComplete(body) catch return .unavailable;
        var response = req.receiveHead(&.{}) catch return .unavailable;
        if (response.head.status != .ok) return .unavailable;
        var transfer_buffer: [256]u8 = undefined;
        const body_reader = response.reader(&transfer_buffer);
        const resp_body = body_reader.allocRemaining(allocator, .limited(max_resp_bytes)) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .unavailable;
        };
        defer allocator.free(resp_body);
        return parseIntrospection(allocator, resp_body);
    }
};

const active_body =
    "{\"active\":true,\"username\":\"alice\",\"role\":\"admin\"," ++
    "\"scope\":\"files:read\",\"aud\":\"mcp-files\",\"exp\":100000}";

// spec: Bearer transport - An active introspection response parses into an authorized verdict with its role and scope
test "parseIntrospection reads an active token's role and scope" {
    const v = try parseIntrospection(std.testing.allocator, active_body);
    defer {
        std.testing.allocator.free(v.authorized.username);
        std.testing.allocator.free(v.authorized.scope);
    }
    try std.testing.expectEqualStrings("alice", v.authorized.username);
    try std.testing.expectEqual(bearer.Role.admin, v.authorized.role);
    try std.testing.expectEqualStrings("files:read", v.authorized.scope);
}

// spec: Bearer transport - An inactive introspection response parses as an inactive verdict
test "parseIntrospection maps active false to inactive" {
    const v = try parseIntrospection(std.testing.allocator, "{\"active\":false}");
    try std.testing.expect(v == .inactive);
}

// spec: Bearer transport - An active introspection response missing a required field parses as inactive
test "parseIntrospection maps an active response missing a field to inactive" {
    const v = try parseIntrospection(std.testing.allocator, "{\"active\":true,\"scope\":\"files:read\"}");
    try std.testing.expect(v == .inactive);
}

// spec: Bearer transport - A malformed introspection body fails closed as unavailable
test "parseIntrospection fails closed on a malformed body" {
    const v = try parseIntrospection(std.testing.allocator, "not json");
    try std.testing.expect(v == .unavailable);
}

// spec: Bearer transport - The bearer HTTP verifier satisfies the verify port the middleware calls
test "bearer http verifier exposes the verify port" {
    try std.testing.expect(@hasDecl(BearerHttpVerifier, "verify"));
}
