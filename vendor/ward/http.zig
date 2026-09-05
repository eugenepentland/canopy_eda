//! HTTP verify transport — the production verifier the middleware injects.
//!
//! `HttpVerifier` implements the `verify(allocator, token)` port over
//! `std.http.Client`: it GETs the configured verify URL, forwarding the session
//! token as the ward cookie. A 200 body is the authenticated username; 401 is
//! unauthorized; any other status or a transport error is unavailable (the
//! middleware then fails closed). This is the one library file permitted
//! `std.http` (see the `src/ward/http*` ban-net carve-out in guardian.toml);
//! the pure decision pipeline carries the unit-test weight.
//!
//! Timeouts cover the entire exchange through cancellable Zig IO; see timeout.zig.

const std = @import("std");
const verdict_mod = @import("verdict.zig");
const middleware = @import("middleware.zig");
const timeout = @import("timeout.zig");

const Verdict = verdict_mod.Verdict;
const Role = verdict_mod.Role;

/// Header name used to forward the session cookie to the ward server.
const cookie_header_name = "cookie";
/// Header name carrying this app's service label so /verify records activity.
const service_header_name = middleware.service_header_name;
/// Header name carrying this app's browsable URL so the home page can link to it.
const service_url_header_name = middleware.service_url_header_name;
/// Header name binding the verify request to an org by slug, so the server
/// answers with the user's role in that org instead of the global role.
const org_header_name = middleware.org_header_name;
/// Response header the ward server tags a verify success with the user's role.
const role_header_name = middleware.role_header_name;
/// Characters trimmed from the verify response body before reading the username.
const body_trim = " \t\r\n";
/// Upper bound on accepted verify response body bytes (usernames are short).
const max_body_len = 256;
/// Total verification deadline unless a caller overrides the field.
pub const default_io_timeout_secs: u31 = 5;

/// A verifier backed by a live `std.http.Client`, calling the ward server's
/// verify endpoint. Inject a pointer to one as the middleware's `verifier`.
pub const HttpVerifier = struct {
    /// HTTP client used for the verify request (borrowed; caller owns it).
    client: *std.http.Client,
    /// Absolute verify endpoint URL, e.g. `http://127.0.0.1:9000/verify`.
    verify_url: []const u8,
    /// Optional service label sent as `X-Ward-Service` so the server records
    /// this app in the session's activity; null omits the header entirely.
    service_name: ?[]const u8 = null,
    /// Optional browsable URL sent as `X-Ward-Service-Url` so the home page links
    /// to this app instead of guessing a subdomain; null omits the header.
    service_url: ?[]const u8 = null,
    /// Optional org slug sent as `X-Ward-Org` so the server answers with the
    /// user's role in that org; null omits the header entirely, leaving the
    /// verify request byte-for-byte as it was before org binding existed.
    org: ?[]const u8 = null,
    /// Seconds the entire verification exchange may take before it fails and the
    /// middleware fails closed; zero keeps the socket blocking without bound.
    io_timeout_secs: u31 = default_io_timeout_secs,

    /// Asks the ward server about `token`: 200 → authorized (body is the owned
    /// username, tagged with the `X-Ward-Role` the response carries), 401 →
    /// unauthorized, any other status or transport failure → unavailable. Only
    /// allocation failure is surfaced as an error.
    pub fn verify(
        self: *HttpVerifier,
        allocator: std.mem.Allocator,
        token: []const u8,
    ) std.mem.Allocator.Error!Verdict {
        return timeout.run(std.mem.Allocator.Error!Verdict, self.client.io, self.io_timeout_secs, verifyUnbounded, .{ self, allocator, token });
    }

    fn verifyUnbounded(self: *HttpVerifier, allocator: std.mem.Allocator, token: []const u8) std.mem.Allocator.Error!Verdict {
        const cookie = try std.fmt.allocPrint(allocator, "{s}={s}", .{ middleware.session_cookie_name, token });
        defer allocator.free(cookie);
        const uri = std.Uri.parse(self.verify_url) catch return .unavailable;
        var headers: [4]std.http.Header = undefined;
        const extra_headers = buildVerifyHeaders(&headers, cookie, self.service_name, self.service_url, self.org);
        var req = self.client.request(.GET, uri, .{
            .redirect_behavior = .unhandled,
            .extra_headers = extra_headers,
        }) catch return .unavailable;
        defer req.deinit();
        req.sendBodiless() catch return .unavailable;
        var response = req.receiveHead(&.{}) catch return .unavailable;
        const role = roleFromResponse(response.head);
        var transfer_buffer: [64]u8 = undefined;
        const body_reader = response.reader(&transfer_buffer);
        const body = body_reader.allocRemaining(allocator, .limited(max_body_len)) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ReadFailed, error.StreamTooLong => return .unavailable,
        };
        defer allocator.free(body);
        return statusVerdict(allocator, response.head.status, body, role);
    }
};

/// Fills `buf` with the verify request's extra headers and returns the populated
/// prefix: always the session `cookie`, then `X-Ward-Service`, `X-Ward-Service-Url`,
/// and `X-Ward-Org`, each only when configured. An unset field adds no header, so
/// an app with none set sends exactly the single cookie header it always did.
fn buildVerifyHeaders(
    buf: *[4]std.http.Header,
    cookie: []const u8,
    service_name: ?[]const u8,
    service_url: ?[]const u8,
    org: ?[]const u8,
) []std.http.Header {
    var count: usize = 0;
    buf[count] = .{ .name = cookie_header_name, .value = cookie };
    count += 1;
    if (service_name) |service| {
        buf[count] = .{ .name = service_header_name, .value = service };
        count += 1;
    }
    if (service_url) |url| {
        buf[count] = .{ .name = service_url_header_name, .value = url };
        count += 1;
    }
    if (org) |slug| {
        buf[count] = .{ .name = org_header_name, .value = slug };
        count += 1;
    }
    return buf[0..count];
}

/// Reads the `X-Ward-Role` response header into a `Role`, folding an absent or
/// unrecognized value onto `unknown`.
fn roleFromResponse(head: std.http.Client.Response.Head) Role {
    var it = head.iterateHeaders();
    while (it.next()) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, role_header_name)) return verdict_mod.roleFromText(header.value);
    }
    return verdict_mod.roleFromText(null);
}

/// Maps an HTTP status, response body, and parsed role to a verdict, duplicating
/// the trimmed body as the owned username (tagged with `role`) on success.
fn statusVerdict(
    allocator: std.mem.Allocator,
    status: std.http.Status,
    body: []const u8,
    role: Role,
) std.mem.Allocator.Error!Verdict {
    return switch (status) {
        .ok => .{ .authorized = .{
            .username = try allocator.dupe(u8, std.mem.trim(u8, body, body_trim)),
            .role = role,
        } },
        .unauthorized => .unauthorized,
        else => .unavailable,
    };
}

// spec: Verify transport - The HTTP verifier satisfies the verify port the middleware calls
test "http verifier exposes the verify port" {
    try std.testing.expect(@hasDecl(HttpVerifier, "verify"));
}

// spec: Middleware org - A configured org binding is sent to the verify endpoint as the X-Ward-Org header
test "a configured org is sent as the x-ward-org header" {
    var buf: [4]std.http.Header = undefined;
    const headers = buildVerifyHeaders(&buf, "ward_session=t", "wiki", null, "acme");
    try std.testing.expectEqual(@as(usize, 3), headers.len);
    var org_value: ?[]const u8 = null;
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, org_header_name)) org_value = header.value;
    }
    try std.testing.expectEqualStrings("acme", org_value.?);
}

// spec: Middleware org - An unset org binding sends no org header, leaving the verify request unchanged
test "an unset org sends only the cookie header" {
    var buf: [4]std.http.Header = undefined;
    const headers = buildVerifyHeaders(&buf, "ward_session=t", null, null, null);
    try std.testing.expectEqual(@as(usize, 1), headers.len);
    try std.testing.expectEqualStrings(cookie_header_name, headers[0].name);
    for (headers) |header| {
        try std.testing.expect(!std.ascii.eqlIgnoreCase(header.name, org_header_name));
    }
}

// spec: Verify transport - A configured service url is sent to the verify endpoint as the X-Ward-Service-Url header
test "a configured service url is sent as the x-ward-service-url header" {
    var buf: [4]std.http.Header = undefined;
    const headers = buildVerifyHeaders(&buf, "ward_session=t", "wiki", "https://wiki.example", null);
    try std.testing.expectEqual(@as(usize, 3), headers.len); // cookie + service + service-url
    var url_value: ?[]const u8 = null;
    for (headers) |header| {
        if (std.ascii.eqlIgnoreCase(header.name, service_url_header_name)) url_value = header.value;
    }
    try std.testing.expectEqualStrings("https://wiki.example", url_value.?);
}

// spec: Verify transport hardening - A verify response with status 200 yields an authorized verdict of the trimmed body
test "status 200 maps to an authorized trimmed username" {
    const verdict = try statusVerdict(std.testing.allocator, .ok, "  alice\r\n", .admin);
    defer std.testing.allocator.free(verdict.authorized.username);
    try std.testing.expectEqualStrings("alice", verdict.authorized.username);
    try std.testing.expectEqual(Role.admin, verdict.authorized.role);
}

// spec: Verify transport hardening - A verify response with status 401 yields the unauthorized verdict
test "status 401 maps to unauthorized" {
    const verdict = try statusVerdict(std.testing.allocator, .unauthorized, "", .member);
    try std.testing.expect(verdict == .unauthorized);
}

// spec: Verify transport hardening - A verify response with any other status yields the unavailable verdict
test "any other status maps to unavailable" {
    const service_down = try statusVerdict(std.testing.allocator, .bad_gateway, "", .member);
    try std.testing.expect(service_down == .unavailable);
    const server_error = try statusVerdict(std.testing.allocator, .internal_server_error, "oops", .member);
    try std.testing.expect(server_error == .unavailable);
}
