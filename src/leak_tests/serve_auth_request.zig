//! Request-path auth tests: drive the real middleware (`auth.authMiddleware`)
//! through faked httpz request/response pairs (`httpz.testing`), asserting the
//! exact status codes and routing the local-first model promises — loopback
//! admits as admin, any proxy hint or a public peer is refused 403, the
//! `--allow-remote` deployment switch admits everything, and the plugin-token
//! sync path is unchanged. Network-free by construction: netlisp has no auth
//! backend to call.

const std = @import("std");
const httpz = @import("httpz");

const serve = @import("../serve.zig");
const auth = @import("../serve/auth.zig");
const auth_store = @import("../serve/auth_store.zig");

const project_dir = "netlisp-authtest";
const auth_dir = "netlisp-authtest-auth";

/// Assert `haystack` contains `needle`.
fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

/// Per-test server state holder. Nothing here needs teardown — the local model
/// keeps no verdict caches or clients — but the struct keeps the `ServerState`
/// alive next to the `Server` that borrows it.
const TestEnv = struct {
    a: std.mem.Allocator,
    state: serve.ServerState = .{},

    fn server(self: *TestEnv, allow_remote: bool) serve.Server {
        return self.serverWithAuthDir(allow_remote, auth_dir);
    }

    fn serverWithAuthDir(self: *TestEnv, allow_remote: bool, dir: []const u8) serve.Server {
        return .{
            .allocator = self.a,
            .project_dir = project_dir,
            .auth_dir = dir,
            .allow_remote = allow_remote,
            .state = &self.state,
        };
    }
};

/// The raw plugin token the sync tests present. Assembled from short pieces so
/// no long token literal appears in source.
const raw_plugin_token = "netlisp_p_" ++ "deadbeefdeadbeefdeadbeefdeadbeef";

/// Write a `plugin_tokens.json` into `tmp` holding the sha256 of
/// `raw_plugin_token` (the store's on-disk format), and return the directory's
/// absolute path. Caller owns the path and passes the allocator it will free
/// against.
fn seedPluginTokenStore(gpa: std.mem.Allocator, tmp: *std.testing.TmpDir) ![:0]u8 {
    const dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    errdefer gpa.free(dir);
    const hash = try auth_store.sha256Hex(gpa, raw_plugin_token);
    defer gpa.free(hash);
    const json = try std.fmt.allocPrint(
        gpa,
        "[{{\"hash\":\"{s}\",\"label\":\"t\",\"created_at\":0}}]",
        .{hash},
    );
    defer gpa.free(json);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "plugin_tokens.json", .data = json });
    return dir;
}

// ── Loopback is admin ────────────────────────────────────────────────────────

// spec: serve - A loopback unproxied request is admitted as a local admin
test "auth-request: a loopback request is admitted as admin" {
    var env = TestEnv{ .a = std.testing.allocator };
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.url("/schematics/x"); // default peer 127.0.0.200, no proxy header
    var srv = env.server(false);
    try std.testing.expect(try auth.authMiddleware(&srv, ht.req, ht.res));
    try std.testing.expectEqual(auth.Role.admin, srv.request_auth.role);
    try std.testing.expect(srv.request_auth.username != null);
}

// spec: serve - An ipv6 loopback peer is admitted while a non-loopback ipv6 peer is refused
test "auth-request: ipv6 loopback is admitted and a non-loopback ipv6 peer is not" {
    // ::1 (loopback) → admin.
    {
        var env = TestEnv{ .a = std.testing.allocator };
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.url("/schematics/x");
        const v6_loopback = [16]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
        ht.req.address = .{ .ip6 = .{ .bytes = v6_loopback, .port = 0 } };
        var srv = env.server(false);
        try std.testing.expect(try auth.authMiddleware(&srv, ht.req, ht.res));
    }
    // 2001:db8::1 (non-loopback) → 403.
    {
        var env = TestEnv{ .a = std.testing.allocator };
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.url("/");
        const v6_public = [16]u8{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
        ht.req.address = .{ .ip6 = .{ .bytes = v6_public, .port = 0 } };
        var srv = env.server(false);
        try std.testing.expect(!try auth.authMiddleware(&srv, ht.req, ht.res));
        try std.testing.expectEqual(@as(u16, 403), ht.res.status);
    }
}

// spec: serve - A request from a non-loopback peer is forbidden rather than admitted as local
test "auth-request: a non-loopback peer is refused" {
    var env = TestEnv{ .a = std.testing.allocator };
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.url("/");
    ht.req.address = .{ .ip4 = .{ .bytes = .{ 8, 8, 8, 8 }, .port = 0 } };
    var srv = env.server(false);
    try std.testing.expect(!try auth.authMiddleware(&srv, ht.req, ht.res));
    try std.testing.expectEqual(@as(u16, 403), ht.res.status);
    try expectContains(ht.res.body, "--allow-remote");
    // Nothing was granted: the refused request carries no identity.
    try std.testing.expect(srv.request_auth.username == null);
    try std.testing.expectEqual(auth.Role.reader, srv.request_auth.role);
}

// spec: serve - A loopback request carrying any proxy header is refused rather than treated as local
test "auth-request: every proxy header defeats the loopback admission" {
    // A same-host reverse proxy relays internet traffic over loopback, so the
    // peer address alone is not enough — each of these headers means "this did
    // not originate here" and must refuse. Locality is never header-derived,
    // and these are the headers that say a header-derived answer would lie.
    const proxy_headers = [_][]const u8{
        "x-forwarded-for",
        "x-forwarded-host",
        "x-forwarded-proto",
        "x-forwarded-port",
        "x-real-ip",
        "forwarded",
    };
    for (proxy_headers) |h| {
        var env = TestEnv{ .a = std.testing.allocator };
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.url("/");
        ht.header(h, "198.51.100.7");
        var srv = env.server(false); // loopback peer, but proxied
        try std.testing.expect(!try auth.authMiddleware(&srv, ht.req, ht.res));
        try std.testing.expectEqual(@as(u16, 403), ht.res.status);
    }
}

// spec: serve - A refused api request answers json while a refused page answers plain text
test "auth-request: the refusal is json for an api route and text for a page" {
    {
        var env = TestEnv{ .a = std.testing.allocator };
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.url("/api/designs");
        ht.header("x-forwarded-for", "198.51.100.7");
        var srv = env.server(false);
        try std.testing.expect(!try auth.authMiddleware(&srv, ht.req, ht.res));
        try std.testing.expectEqual(@as(u16, 403), ht.res.status);
        try std.testing.expectEqual(httpz.ContentType.JSON, ht.res.content_type.?);
        try expectContains(ht.res.body, "\"error\":\"forbidden\"");
    }
    {
        var env = TestEnv{ .a = std.testing.allocator };
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.url("/schematics/x");
        ht.header("x-forwarded-for", "198.51.100.7");
        var srv = env.server(false);
        try std.testing.expect(!try auth.authMiddleware(&srv, ht.req, ht.res));
        try std.testing.expectEqual(@as(u16, 403), ht.res.status);
        try std.testing.expectEqual(httpz.ContentType.TEXT, ht.res.content_type.?);
        try expectContains(ht.res.body, "loopback requests only");
    }
}

// ── --allow-remote hands auth to the operator's proxy ────────────────────────

// spec: serve - Allow-remote admits a proxied request from a public peer as admin
test "auth-request: allow-remote admits a proxied public-peer request as admin" {
    var env = TestEnv{ .a = std.testing.allocator };
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.url("/api/designs");
    ht.header("x-forwarded-for", "198.51.100.7");
    ht.req.address = .{ .ip4 = .{ .bytes = .{ 8, 8, 8, 8 }, .port = 0 } };
    var srv = env.server(true);
    try std.testing.expect(try auth.authMiddleware(&srv, ht.req, ht.res));
    try std.testing.expectEqual(auth.Role.admin, srv.request_auth.role);
    // The identity says where the trust came from: netlisp verified nothing.
    try std.testing.expectEqualStrings("remote", srv.request_auth.username.?);
}

// spec: serve - Allow-remote admits a mutating request because the proxy in front owns the auth
test "auth-request: allow-remote admits a mutating request too" {
    var env = TestEnv{ .a = std.testing.allocator };
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.url("/api/edit-value/x");
    ht.req.method = .POST;
    ht.req.address = .{ .ip4 = .{ .bytes = .{ 8, 8, 8, 8 }, .port = 0 } };
    var srv = env.server(true);
    try std.testing.expect(try auth.authMiddleware(&srv, ht.req, ht.res));
    try std.testing.expect(srv.request_auth.role.canWrite());
}

// ── Public routes ────────────────────────────────────────────────────────────

// spec: serve - The health probe and static assets are served to a remote peer without a credential
test "auth-request: public routes are served without any credential" {
    const public_paths = [_][]const u8{ "/healthz", "/static/app.css" };
    for (public_paths) |p| {
        var env = TestEnv{ .a = std.testing.allocator };
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.url(p);
        // A genuinely remote, proxied peer: nothing about this request is local.
        ht.header("x-forwarded-for", "198.51.100.7");
        ht.req.address = .{ .ip4 = .{ .bytes = .{ 8, 8, 8, 8 }, .port = 0 } };
        var srv = env.server(false);
        try std.testing.expect(try auth.authMiddleware(&srv, ht.req, ht.res));
        // Public means unauthenticated, not privileged — no identity is granted.
        try std.testing.expect(srv.request_auth.username == null);
    }
}

// ── Sync path: the plugin token ──────────────────────────────────────────────

// spec: serve - A valid plugin token admits a remote sync request while a bogus one is refused
test "auth-request: a plugin token admits the sync path and a bogus one does not" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try seedPluginTokenStore(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(dir);

    // The plugin-token store reads its json file through the Server allocator on
    // the arena contract (production passes the per-request arena, `res.arena`),
    // so drive it through an arena so scratch is reclaimed like production.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = TestEnv{ .a = arena.allocator() };

    // Case A — the valid plugin token admits a request that is in every other
    // respect remote (public peer, proxy header): the KiCad sync helper is a
    // machine somewhere else, which is the token's whole reason to exist.
    {
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.url("/api/sync-kicad-pcb/x");
        ht.req.method = .POST;
        ht.header("authorization", "Bearer " ++ raw_plugin_token);
        ht.header("x-forwarded-for", "198.51.100.7");
        ht.req.address = .{ .ip4 = .{ .bytes = .{ 8, 8, 8, 8 }, .port = 0 } };
        var srv = env.serverWithAuthDir(false, dir);
        try std.testing.expect(try auth.authMiddleware(&srv, ht.req, ht.res));
        // The token authorizes the route, not an identity — unchanged from the
        // behaviour every sync client already relies on.
        try std.testing.expect(srv.request_auth.username == null);
    }
    // Case B — a bogus token is no plugin token and nothing else admits it.
    {
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.url("/api/sync-kicad-pcb/x");
        ht.req.method = .POST;
        ht.header("authorization", "Bearer not-a-real-plugin-token");
        ht.header("x-forwarded-for", "198.51.100.7");
        ht.req.address = .{ .ip4 = .{ .bytes = .{ 8, 8, 8, 8 }, .port = 0 } };
        var srv = env.serverWithAuthDir(false, dir);
        try std.testing.expect(!try auth.authMiddleware(&srv, ht.req, ht.res));
        try std.testing.expectEqual(@as(u16, 403), ht.res.status);
    }
    // Case C — a valid plugin token buys exactly ONE route family. The same
    // token on any other path is refused like any other remote request.
    {
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.url("/api/edit-value/x");
        ht.req.method = .POST;
        ht.header("authorization", "Bearer " ++ raw_plugin_token);
        ht.header("x-forwarded-for", "198.51.100.7");
        ht.req.address = .{ .ip4 = .{ .bytes = .{ 8, 8, 8, 8 }, .port = 0 } };
        var srv = env.serverWithAuthDir(false, dir);
        try std.testing.expect(!try auth.authMiddleware(&srv, ht.req, ht.res));
        try std.testing.expectEqual(@as(u16, 403), ht.res.status);
    }
}

// spec: serve - A sync request whose bearer header is empty or blank is not admitted by the plugin path
test "auth-request: an empty bearer header admits nothing on the sync path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try seedPluginTokenStore(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(dir);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = TestEnv{ .a = arena.allocator() };

    // A live token exists in the store — the only thing missing is a value on
    // the header. An empty, blank or absent credential must never be read as
    // "no check required".
    const empty_headers = [_]?[]const u8{ null, "Bearer ", "Bearer    ", "Bearer" };
    for (empty_headers) |h| {
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.url("/api/sync-kicad-pcb/x");
        ht.req.method = .POST;
        if (h) |v| ht.header("authorization", v);
        ht.header("x-forwarded-for", "198.51.100.7");
        ht.req.address = .{ .ip4 = .{ .bytes = .{ 8, 8, 8, 8 }, .port = 0 } };
        var srv = env.serverWithAuthDir(false, dir);
        try std.testing.expect(!try auth.authMiddleware(&srv, ht.req, ht.res));
        try std.testing.expectEqual(@as(u16, 403), ht.res.status);
    }
}

// spec: serve - A malformed authorization header is not a plugin token while a lowercase scheme still is
test "auth-request: a malformed authorization header does not admit the sync path" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try seedPluginTokenStore(std.testing.allocator, &tmp);
    defer std.testing.allocator.free(dir);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = TestEnv{ .a = arena.allocator() };

    // Corrupt or wrong-scheme headers: the token bytes may even be present, but
    // the header is malformed and nothing is extracted from it.
    const malformed = [_][]const u8{
        raw_plugin_token, // no scheme at all
        "Basic " ++ raw_plugin_token,
        "Bearer\t" ++ raw_plugin_token, // tab is not the single space of the scheme
        "\xff\xfe garbage input",
    };
    for (malformed) |h| {
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.url("/api/sync-kicad-pcb/x");
        ht.req.method = .POST;
        ht.header("authorization", h);
        ht.header("x-forwarded-for", "198.51.100.7");
        ht.req.address = .{ .ip4 = .{ .bytes = .{ 8, 8, 8, 8 }, .port = 0 } };
        var srv = env.serverWithAuthDir(false, dir);
        try std.testing.expect(!try auth.authMiddleware(&srv, ht.req, ht.res));
        try std.testing.expectEqual(@as(u16, 403), ht.res.status);
    }
    // The scheme itself is case-insensitive, though — a well-formed header that
    // merely spells it lowercase is the same credential.
    {
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.url("/api/sync-kicad-pcb/x");
        ht.req.method = .POST;
        ht.header("authorization", "bearer " ++ raw_plugin_token);
        ht.header("x-forwarded-for", "198.51.100.7");
        ht.req.address = .{ .ip4 = .{ .bytes = .{ 8, 8, 8, 8 }, .port = 0 } };
        var srv = env.serverWithAuthDir(false, dir);
        try std.testing.expect(try auth.authMiddleware(&srv, ht.req, ht.res));
    }
}
