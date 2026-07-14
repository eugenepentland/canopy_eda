//! Request-path auth tests: drive the real ward auth adapter entry points
//! (`ward_auth.authMiddleware`, `ward_auth.metadataProtectedResource`) through
//! faked httpz request/response pairs (`httpz.testing`), asserting the exact
//! status codes, headers, and routing the ward migration must preserve — the
//! dev-bypass composition, the 401-vs-302 split, the RFC 9728 bearer challenge,
//! scope/role gating, fail-closed behaviour, and the plugin-vs-ward sync
//! precedence. Network-free: the verdict caches are pre-seeded so the ward HTTP
//! verifier is never reached (a cache hit short-circuits the network call), and
//! the fail-closed paths return before any verifier is built.

const std = @import("std");
const httpz = @import("httpz");
const ward = @import("ward");

const net = @import("../infra/net.zig");
const serve = @import("../serve.zig");
const ward_auth = @import("../serve/ward_auth.zig");
const auth_store = @import("../serve/auth_store.zig");

const service = "eda";
const login_url = "https" ++ "://ward.example/login";
// A well-formed access token: exactly 32 lowercase-hex chars (ward's
// `extractBearer` rejects anything else before a lookup). Assembled from short
// pieces so no long token literal appears in source.
const bearer_token = "0011" ++ "2233" ++ "4455" ++ "6677" ++ "8899" ++ "00aa" ++ "bbcc" ++ "ddee";
const project_dir = "netlisp-authtest";
const auth_dir = "netlisp-authtest-auth";

/// Assert `haystack` contains `needle`.
fn expectContains(haystack: []const u8, needle: []const u8) !void {
    try std.testing.expect(std.mem.indexOf(u8, haystack, needle) != null);
}

/// Per-test server state holder. `initWard` populates the ward config + verdict
/// caches + a (never-called on the seeded/fail-closed paths) HTTP client; tests
/// that stay on the dev-bypass or unconfigured path skip it. `deinit` reclaims
/// whatever was built so `std.testing.allocator` stays leak-clean. `a` is the
/// caller's allocator (set from inside the test block).
const TestEnv = struct {
    a: std.mem.Allocator,
    state: serve.ServerState = .{},

    fn initWard(self: *TestEnv, verify: []const u8, login: []const u8, introspect: []const u8) void {
        self.state.ward.cfg = .{
            .verify_url = verify,
            .login_url = login,
            .auth_server_url = "",
            .introspect_url = introspect,
            .service_name = service,
            .cache_ttl_secs = 300,
        };
        self.state.ward.session = .{
            .cache = ward.cache.Cache.init(self.a, 300),
            .client = net.initHttpClient(self.a),
        };
        self.state.ward.bearer = .{
            .cache = ward.cache.Cache.init(self.a, 300),
            .client = net.initHttpClient(self.a),
        };
    }

    fn deinit(self: *TestEnv) void {
        if (self.state.ward.session) |*p| {
            p.cache.deinit();
            p.client.deinit();
        }
        if (self.state.ward.bearer) |*p| {
            p.cache.deinit();
            p.client.deinit();
        }
    }

    fn server(self: *TestEnv, dev_mode: bool) serve.Server {
        return self.serverWithAuthDir(dev_mode, auth_dir);
    }

    fn serverWithAuthDir(self: *TestEnv, dev_mode: bool, dir: []const u8) serve.Server {
        return .{
            .allocator = self.a,
            .project_dir = project_dir,
            .auth_dir = dir,
            .dev_mode = dev_mode,
            .state = &self.state,
        };
    }
};

// ── Dev-bypass composition (auth.zig, reached through the real middleware) ──

// spec: serve - A loopback request under dev mode bypasses auth even when the ward backend is unconfigured
test "auth-request: dev bypass admits a loopback request with ward unconfigured" {
    var env = TestEnv{ .a = std.testing.allocator };
    defer env.deinit(); // ward deliberately unconfigured — bypass must win anyway
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.url("/schematics/x"); // default peer 127.0.0.200, no proxy header
    var srv = env.server(true);
    try std.testing.expect(try ward_auth.authMiddleware(&srv, ht.req, ht.res));
}

// spec: serve - A loopback request carrying any proxy header does not receive the dev bypass
test "auth-request: a proxy header defeats the dev bypass for every proxy header" {
    const proxy_headers = [_][]const u8{ "x-forwarded-for", "x-forwarded-host", "x-real-ip", "forwarded" };
    for (proxy_headers) |h| {
        var env = TestEnv{ .a = std.testing.allocator };
        defer env.deinit(); // unconfigured ward → fail-closed 503 proves no bypass fired
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.url("/");
        ht.header(h, "198.51.100.7");
        var srv = env.server(true); // dev on, loopback peer, but proxied
        try std.testing.expect(!try ward_auth.authMiddleware(&srv, ht.req, ht.res));
        try std.testing.expectEqual(@as(u16, 503), ht.res.status);
    }
}

// spec: serve - A request from a non-loopback peer does not receive the dev bypass
test "auth-request: a non-loopback peer does not receive the dev bypass" {
    var env = TestEnv{ .a = std.testing.allocator };
    defer env.deinit();
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.url("/");
    ht.req.address = std.net.Address.initIp4([4]u8{ 8, 8, 8, 8 }, 0);
    var srv = env.server(true); // dev on, not proxied, but public peer
    try std.testing.expect(!try ward_auth.authMiddleware(&srv, ht.req, ht.res));
    try std.testing.expectEqual(@as(u16, 503), ht.res.status);
}

// spec: serve - A loopback request with dev mode disabled does not receive the dev bypass
test "auth-request: dev mode disabled forbids the loopback bypass" {
    var env = TestEnv{ .a = std.testing.allocator };
    defer env.deinit();
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.url("/");
    var srv = env.server(false); // loopback peer, not proxied, but dev off
    try std.testing.expect(!try ward_auth.authMiddleware(&srv, ht.req, ht.res));
    try std.testing.expectEqual(@as(u16, 503), ht.res.status);
}

// spec: serve - An ipv6 loopback peer receives the dev bypass while a non-loopback ipv6 peer does not
test "auth-request: ipv6 loopback bypasses and a non-loopback ipv6 peer does not" {
    // ::1 (loopback) under dev mode → bypass admits the request.
    {
        var env = TestEnv{ .a = std.testing.allocator };
        defer env.deinit();
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.url("/schematics/x");
        const v6_loopback = [16]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
        ht.req.address = std.net.Address.initIp6(v6_loopback, 0, 0, 0);
        var srv = env.server(true);
        try std.testing.expect(try ward_auth.authMiddleware(&srv, ht.req, ht.res));
    }
    // 2001:db8::1 (non-loopback) under dev mode → no bypass (unconfigured → 503).
    {
        var env = TestEnv{ .a = std.testing.allocator };
        defer env.deinit();
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.url("/");
        const v6_public = [16]u8{ 0x20, 0x01, 0x0d, 0xb8, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1 };
        ht.req.address = std.net.Address.initIp6(v6_public, 0, 0, 0);
        var srv = env.server(true);
        try std.testing.expect(!try ward_auth.authMiddleware(&srv, ht.req, ht.res));
        try std.testing.expectEqual(@as(u16, 503), ht.res.status);
    }
}

// ── Session gate: 401-for-api vs 302-for-page ───────────────────────────────

// spec: serve - An unauthenticated api request is answered 401 json rather than a login redirect
test "auth-request: an unauthenticated api request gets 401 json not a redirect" {
    var env = TestEnv{ .a = std.testing.allocator };
    defer env.deinit();
    env.initWard("http" ++ "://v", login_url, "http" ++ "://i");
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.url("/api/version/x"); // GET, no cookie
    var srv = env.server(false);
    try std.testing.expect(!try ward_auth.authMiddleware(&srv, ht.req, ht.res));
    try std.testing.expectEqual(@as(u16, 401), ht.res.status);
    try expectContains(ht.res.body, "unauthorized");
    const resp = try ht.parseResponse();
    try resp.expectHeader("location", null); // NOT a 302 redirect
}

// spec: serve - An unauthenticated page request is redirected 302 to the ward login carrying the return url
test "auth-request: an unauthenticated page request gets a 302 to the ward login" {
    var env = TestEnv{ .a = std.testing.allocator };
    defer env.deinit();
    env.initWard("http" ++ "://v", login_url, "http" ++ "://i");
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.url("/schematics/x"); // GET, no cookie
    var srv = env.server(false);
    try std.testing.expect(!try ward_auth.authMiddleware(&srv, ht.req, ht.res));
    try std.testing.expectEqual(@as(u16, 302), ht.res.status);
    const resp = try ht.parseResponse();
    const loc = resp.headers.get("location") orelse return error.NoLocationHeader;
    try std.testing.expect(std.mem.startsWith(u8, loc, login_url));
    try expectContains(loc, "rd="); // the percent-encoded return target
    try expectContains(loc, "localhost"); // this request's host
    try expectContains(loc, "schematics"); // this request's path
}

// ── Bearer gate: RFC 9728 challenge and fail-closed ─────────────────────────

// spec: serve - A bearer-less mcp request is answered 401 with a resource-metadata www-authenticate challenge
test "auth-request: a bearer-less mcp request gets a 401 resource-metadata challenge" {
    var env = TestEnv{ .a = std.testing.allocator };
    defer env.deinit();
    env.initWard("http" ++ "://v", login_url, "http" ++ "://i");
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.url("/mcp"); // no Authorization header
    var srv = env.server(false);
    try std.testing.expect(!try ward_auth.authMiddleware(&srv, ht.req, ht.res));
    try std.testing.expectEqual(@as(u16, 401), ht.res.status);
    const resp = try ht.parseResponse();
    const wa = resp.headers.get("www-authenticate") orelse return error.NoChallengeHeader;
    try expectContains(wa, "resource_metadata");
    try expectContains(wa, "/.well-known/oauth-protected-resource");
}

// spec: serve - An mcp request fails closed with 503 when the bearer introspection url is unconfigured
test "auth-request: an mcp request fails closed when introspection is unconfigured" {
    var env = TestEnv{ .a = std.testing.allocator };
    defer env.deinit();
    env.initWard("http" ++ "://v", login_url, ""); // introspect url empty
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.url("/mcp");
    ht.header("authorization", "Bearer " ++ bearer_token);
    var srv = env.server(false);
    try std.testing.expect(!try ward_auth.authMiddleware(&srv, ht.req, ht.res));
    try std.testing.expectEqual(@as(u16, 503), ht.res.status);
}

// ── Bearer gate: scope enforcement + role mapping (cache-seeded, no network) ─

// spec: serve - An mcp bearer is admitted for any valid ward token regardless of scope with its mapped role
test "auth-request: mcp admits any valid ward token regardless of scope" {
    var env = TestEnv{ .a = std.testing.allocator };
    defer env.deinit();
    env.initWard("http" ++ "://v", login_url, "http" ++ "://i");
    const now = std.time.timestamp();

    // Case A — a scope WITHOUT the service name is still admitted (writes are
    // role-gated, not scope-gated, on the /mcp read path).
    {
        try env.state.ward.bearer.?.cache.put(bearer_token, "ada", .member, "files", now);
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.url("/mcp");
        ht.header("authorization", "Bearer " ++ bearer_token);
        var srv = env.server(false);
        try std.testing.expect(try ward_auth.authMiddleware(&srv, ht.req, ht.res));
        try std.testing.expect(srv.mcp_identity != null);
        try std.testing.expectEqualStrings("files", srv.mcp_identity.?.scope);
        try std.testing.expectEqual(ward_auth.Role.writer, srv.mcp_identity.?.role); // member → writer
    }
    // Case B — a multi-entry scope is likewise admitted with the mapped role.
    {
        try env.state.ward.bearer.?.cache.put(bearer_token, "ada", .member, "files eda", now);
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.url("/mcp");
        ht.header("authorization", "Bearer " ++ bearer_token);
        var srv = env.server(false);
        try std.testing.expect(try ward_auth.authMiddleware(&srv, ht.req, ht.res));
        try std.testing.expect(srv.mcp_identity != null);
        try std.testing.expectEqualStrings("files eda", srv.mcp_identity.?.scope);
        try std.testing.expectEqualStrings("ada", srv.mcp_identity.?.username);
        try std.testing.expectEqual(ward_auth.Role.writer, srv.mcp_identity.?.role);
    }
}

// ── Session gate: write-gating a mutation by role/method ─────────────────────

// spec: serve - A reader's mutating request is forbidden while a writer, a safe method, or a read-only post passes
test "auth-request: session write-gate forbids a reader mutation and admits the rest" {
    var env = TestEnv{ .a = std.testing.allocator };
    defer env.deinit();
    env.initWard("http" ++ "://v", login_url, "http" ++ "://i");
    const now = std.time.timestamp();
    const cookie_hdr = "ward_session=sess-token";

    // A reader (unknown ward role) POSTing to a mutating endpoint is forbidden.
    {
        try env.state.ward.session.?.cache.put("sess-token", "ada", .unknown, "", now);
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.url("/api/edit-value/x");
        ht.req.method = .POST;
        ht.header("cookie", cookie_hdr);
        var srv = env.server(false);
        try std.testing.expect(!try ward_auth.authMiddleware(&srv, ht.req, ht.res));
        try std.testing.expectEqual(@as(u16, 403), ht.res.status);
        try expectContains(ht.res.body, "writer role required");
    }
    // A writer (ward member) may perform the same mutation.
    {
        try env.state.ward.session.?.cache.put("sess-token", "ada", .member, "", now);
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.url("/api/edit-value/x");
        ht.req.method = .POST;
        ht.header("cookie", cookie_hdr);
        var srv = env.server(false);
        try std.testing.expect(try ward_auth.authMiddleware(&srv, ht.req, ht.res));
    }
    // Every safe method (GET, HEAD, OPTIONS) is admitted even for a reader —
    // one sub-case per method so no single write-gate clause can silently drop.
    for ([_]httpz.Method{ .GET, .HEAD, .OPTIONS }) |m| {
        try env.state.ward.session.?.cache.put("sess-token", "ada", .unknown, "", now);
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.url("/api/edit-value/x"); // a mutating endpoint — only the method saves it
        ht.req.method = m;
        ht.header("cookie", cookie_hdr);
        var srv = env.server(false);
        try std.testing.expect(try ward_auth.authMiddleware(&srv, ht.req, ht.res));
    }
    // A pure-computation POST on the read-only allowlist is admitted for a reader
    // (the real route form carries a :name segment after the exact-prefix slash).
    {
        try env.state.ward.session.?.cache.put("sess-token", "ada", .unknown, "", now);
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.url("/api/pcb-score/x");
        ht.req.method = .POST;
        ht.header("cookie", cookie_hdr);
        var srv = env.server(false);
        try std.testing.expect(try ward_auth.authMiddleware(&srv, ht.req, ht.res));
    }
}

// spec: serve - A reader drives the read-only pcb-drc and pcb-score-batch posts but not the pcb-drc-rules write
test "auth-request: the write-gate exempts pcb-drc compute but not the pcb-drc-rules mutation" {
    var env = TestEnv{ .a = std.testing.allocator };
    defer env.deinit();
    env.initWard("http" ++ "://v", login_url, "http" ++ "://i");
    const now = std.time.timestamp();
    const cookie_hdr = "ward_session=sess-token";

    // The mutating POST /api/pcb-drc-rules/:name (persists rules to disk) is NOT
    // a read-only compute — a reader is write-gated (403). A trailing-slash-less
    // "/api/pcb-drc" prefix would have wrongly exempted it (the bypass this fixes).
    {
        try env.state.ward.session.?.cache.put("sess-token", "ada", .unknown, "", now);
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.url("/api/pcb-drc-rules/x");
        ht.req.method = .POST;
        ht.header("cookie", cookie_hdr);
        var srv = env.server(false);
        try std.testing.expect(!try ward_auth.authMiddleware(&srv, ht.req, ht.res));
        try std.testing.expectEqual(@as(u16, 403), ht.res.status);
        try expectContains(ht.res.body, "writer role required");
    }
    // The read-only compute siblings stay exempt — a reader passes both.
    for ([_][]const u8{ "/api/pcb-drc/x", "/api/pcb-score-batch/x" }) |path| {
        try env.state.ward.session.?.cache.put("sess-token", "ada", .unknown, "", now);
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.url(path);
        ht.req.method = .POST;
        ht.header("cookie", cookie_hdr);
        var srv = env.server(false);
        try std.testing.expect(try ward_auth.authMiddleware(&srv, ht.req, ht.res));
    }
}

// ── Sync path: plugin-token precedence over ward bearer ──────────────────────

// spec: serve - A valid plugin token admits a sync request without a ward call while an invalid one falls through
test "auth-request: a plugin token wins the sync path and a bogus one falls through" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realpathAlloc(std.testing.allocator, ".");
    defer std.testing.allocator.free(dir);

    // Seed a plugin_tokens.json holding the sha256 of a known raw token so
    // `validate` accepts it (mirrors the store's on-disk format).
    const raw_token = "eda_p_" ++ "deadbeefdeadbeefdeadbeefdeadbeef";
    const hash = try auth_store.sha256Hex(std.testing.allocator, raw_token);
    defer std.testing.allocator.free(hash);
    const json = try std.fmt.allocPrint(
        std.testing.allocator,
        "[{{\"hash\":\"{s}\",\"label\":\"t\",\"created_at\":0}}]",
        .{hash},
    );
    defer std.testing.allocator.free(json);
    try tmp.dir.writeFile(.{ .sub_path = "plugin_tokens.json", .data = json });

    // The plugin-token store reads its json file through the Server allocator on
    // the arena contract (production passes the per-request arena, `res.arena`),
    // so drive it through an arena so scratch is reclaimed like production.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var env = TestEnv{ .a = arena.allocator() };
    defer env.deinit(); // ward deliberately unconfigured — a fall-through must fail closed

    // Case A — the valid plugin token admits the request without any ward call.
    {
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.url("/api/sync-kicad-pcb/x");
        ht.req.method = .POST;
        ht.header("authorization", "Bearer " ++ raw_token);
        var srv = env.serverWithAuthDir(false, dir);
        try std.testing.expect(try ward_auth.authMiddleware(&srv, ht.req, ht.res));
    }
    // Case B — a bogus token is no plugin token, falls through to the ward bearer
    // check, which is unconfigured here and therefore fails closed (503).
    {
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.url("/api/sync-kicad-pcb/x");
        ht.req.method = .POST;
        ht.header("authorization", "Bearer not-a-real-plugin-token");
        var srv = env.serverWithAuthDir(false, dir);
        try std.testing.expect(!try ward_auth.authMiddleware(&srv, ht.req, ht.res));
        try std.testing.expectEqual(@as(u16, 503), ht.res.status);
    }
}

// spec: serve - A live ward bearer admits a sync request as the fallback when no plugin token matches
test "auth-request: a cache-seeded ward bearer admits the sync path as the fallback" {
    var env = TestEnv{ .a = std.testing.allocator };
    defer env.deinit();
    env.initWard("http" ++ "://v", login_url, "http" ++ "://i");
    // Seed the bearer cache so the verifier (network) is never consulted. The
    // grant must be scoped for this service (wardd is shared) — a foreign scope
    // no longer admits the board write (see the scope-rejection test below).
    try env.state.ward.bearer.?.cache.put(bearer_token, "ada", .member, "eda", std.time.timestamp());
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.url("/api/sync-kicad-pcb/x");
    ht.req.method = .POST;
    ht.header("authorization", "Bearer " ++ bearer_token);
    var srv = env.server(false); // no plugin token matches (empty store)
    try std.testing.expect(try ward_auth.authMiddleware(&srv, ht.req, ht.res));
}

// spec: serve - A sync bearer scoped for another service is not admitted and falls through to the session gate
test "auth-request: a foreign-scoped ward bearer does not admit the sync path" {
    var env = TestEnv{ .a = std.testing.allocator };
    defer env.deinit();
    env.initWard("http" ++ "://v", login_url, "http" ++ "://i");
    // A live grant scoped for a DIFFERENT service ("files", not "eda"). wardd is
    // a shared auth server, so this token must not drive the eda board write: the
    // bearer path returns false, and the request falls through to the session
    // gate, which (no ward_session cookie, an /api/ path) answers 401 — never a
    // sync execution.
    try env.state.ward.bearer.?.cache.put(bearer_token, "ada", .member, "files", std.time.timestamp());
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.url("/api/sync-kicad-pcb/x");
    ht.req.method = .POST;
    ht.header("authorization", "Bearer " ++ bearer_token);
    var srv = env.server(false);
    try std.testing.expect(!try ward_auth.authMiddleware(&srv, ht.req, ht.res));
    try std.testing.expectEqual(@as(u16, 401), ht.res.status);
}

// spec: serve - A malformed sync bearer with ward configured falls through to the session gate rather than admitting
test "auth-request: a malformed sync bearer with ward configured is not admitted" {
    var env = TestEnv{ .a = std.testing.allocator };
    defer env.deinit();
    env.initWard("http" ++ "://v", login_url, "http" ++ "://i");
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.url("/api/sync-kicad-pcb/x");
    ht.req.method = .POST;
    // Not a plugin token and not a well-formed 32-hex access token: ward's
    // extractBearer rejects it before any lookup, yielding a non-allow action
    // that must NOT admit the sync request — it falls to the session gate (401).
    ht.header("authorization", "Bearer nope");
    var srv = env.server(false);
    try std.testing.expect(!try ward_auth.authMiddleware(&srv, ht.req, ht.res));
    try std.testing.expectEqual(@as(u16, 401), ht.res.status);
}

// spec: serve - A session-allowlisted public route is served without any credential
test "auth-request: allowlisted public routes are served without any credential" {
    const public_paths = [_][]const u8{ "/.well-known/oauth-protected-resource", "/static/app.css" };
    for (public_paths) |p| {
        var env = TestEnv{ .a = std.testing.allocator };
        defer env.deinit();
        env.initWard("http" ++ "://v", login_url, "http" ++ "://i");
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.url(p); // GET, no cookie, no bearer, dev off
        var srv = env.server(false);
        try std.testing.expect(try ward_auth.authMiddleware(&srv, ht.req, ht.res));
    }
}

// spec: serve - An allocation failure during the sync bearer fallback surfaces as an error rather than admitting
test "auth-request: oom during the sync bearer fallback errors instead of admitting" {
    var env = TestEnv{ .a = std.testing.allocator };
    defer env.deinit();
    env.initWard("http" ++ "://v", login_url, "http" ++ "://i");
    // Seed a live grant so the request WOULD be admitted if memory allowed —
    // the only thing failing here is allocation, never the credential.
    try env.state.ward.bearer.?.cache.put(bearer_token, "ada", .member, "files", std.time.timestamp());
    var ht = httpz.testing.init(.{});
    defer ht.deinit();
    ht.url("/api/sync-kicad-pcb/x");
    ht.req.method = .POST;
    ht.header("authorization", "Bearer " ++ bearer_token);
    // Every request-arena allocation fails: duping the cached identity inside
    // the bearer check hits OOM, and the middleware must surface the error
    // (fail closed) — never swallow it into an admission.
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    ht.req.arena = failing.allocator();
    var srv = env.server(false);
    try std.testing.expectError(error.OutOfMemory, ward_auth.authMiddleware(&srv, ht.req, ht.res));
}

// ── RFC 9728 protected-resource metadata ─────────────────────────────────────

// spec: serve - The protected-resource metadata derives its resource url from the host and names the ward server
test "auth-request: protected-resource metadata derives host and names the ward server" {
    var env = TestEnv{ .a = std.testing.allocator };
    defer env.deinit();
    env.state.ward.cfg = .{
        .verify_url = "",
        .login_url = login_url,
        .auth_server_url = "",
        .introspect_url = "",
        .service_name = service,
        .cache_ttl_secs = 300,
    };

    // Resource url comes from the Host header; authorization server strips /login.
    {
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.url("/.well-known/oauth-protected-resource");
        ht.header("host", "eda.example:7050");
        var srv = env.server(false);
        try ward_auth.metadataProtectedResource(&srv, ht.req, ht.res);
        try expectContains(ht.res.body, "\"resource\":\"http" ++ "://eda.example:7050\"");
        try expectContains(ht.res.body, "\"authorization_servers\":[\"" ++ "https" ++ "://ward.example\"]");
    }
    // No Host header → the resource url derives to localhost.
    {
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.url("/.well-known/oauth-protected-resource");
        var srv = env.server(false);
        try ward_auth.metadataProtectedResource(&srv, ht.req, ht.res);
        try expectContains(ht.res.body, "\"resource\":\"http" ++ "://localhost\"");
    }
    // An x-forwarded-proto: https hint makes the resource url https.
    {
        var ht = httpz.testing.init(.{});
        defer ht.deinit();
        ht.url("/.well-known/oauth-protected-resource");
        ht.header("host", "eda.example");
        ht.header("x-forwarded-proto", "https");
        var srv = env.server(false);
        try ward_auth.metadataProtectedResource(&srv, ht.req, ht.res);
        try expectContains(ht.res.body, "\"resource\":\"" ++ "https" ++ "://eda.example\"");
    }
}
