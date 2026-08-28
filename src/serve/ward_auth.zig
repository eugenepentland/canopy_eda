//! Ward auth adapter — the single seam between netlisp's serve layer and the
//! `ward` library. netlisp is now a pure resource server: wardd
//! (ward.eugenepentland.dev) owns every passkey, session, and OAuth grant, and
//! this module verifies the `ward_session` cookie and sync bearer tokens
//! against it via the ward middleware.
//!
//! `authMiddleware` is the chokepoint the request dispatcher calls before every
//! route: the local-dev bypass and the plugin-token sync path are preserved,
//! and everything else runs the ward session path. Long-lived verdict caches and
//! HTTP clients live on `WardState` (one per server, on `ServerState`). The
//! session and bearer paths each own a {cache + client} pair guarded by its own
//! mutex — ward's `Cache` is not internally synchronized, and `std.http.Client`
//! shares a connection pool that must not be driven by two threads at once, so
//! the two paths never touch shared verify state. When the `WARD_*` URLs are
//! unset, protected requests fail closed (503) — never open.

const std = @import("std");
const httpz = @import("httpz");
const ward = @import("ward");
const net = @import("../infra/net.zig");
const clock = @import("../infra/clock.zig");
const infra_fs = @import("../infra/fs.zig");
const log = @import("../infra/log.zig");
const config = @import("../config.zig");
const server_mod = @import("../serve.zig");
const Server = server_mod.Server;
const auth = @import("auth.zig");

/// Error set the middleware surfaces to the dispatcher — only allocation
/// failure escapes; every auth decision is written into the response and
/// reported as a bool return.
pub const AuthError = std.mem.Allocator.Error;

// ── Constants ──────────────────────────────────────────────────────────
const default_service_name = "netlisp";
const default_cache_ttl_secs: i64 = 30;

const http_unauthorized: u16 = 401;
const http_forbidden: u16 = 403;
const http_service_unavailable: u16 = 503;
const http_redirect_found: u16 = 302;

const header_www_authenticate = "www-authenticate";
const header_host = "host";
const header_forwarded_proto = "x-forwarded-proto";
const header_authorization = "authorization";
const header_cookie = "cookie";

const scheme_https = "https";
const scheme_http = "http";
const url_template = "{s}://{s}";
const concat_template = "{s}{s}";
const login_path_suffix = "/login";

const sync_path_prefix = "/api/sync-kicad-pcb/";

const body_forbidden_write = "{\"error\":\"forbidden\",\"error_description\":\"writer role required\"}";
const body_unavailable = "{\"error\":\"service_unavailable\",\"error_description\":\"auth backend unavailable\"}";
const body_unauthorized = "{\"error\":\"unauthorized\",\"error_description\":\"missing or invalid bearer token\"}";
const body_api_unauthorized = "{\"error\":\"unauthorized\"}";

/// Public routes served without a ward session: the static assets the
/// login/setup flow pulls and the RFC 9728 protected-resource metadata
/// document. The homegrown `/auth/*` and OAuth authorization-server routes were
/// deleted in the ward migration, so they are no longer allowlisted — a request
/// to any such path now correctly falls through to the session gate.
const public_routes = [_][]const u8{
    "/static/*",
    "/.well-known/oauth-protected-resource",
};

/// POST prefixes exempt from write-gating because they only compute (scoring,
/// routing overlays, dry validation) rather than mutate design state. Each entry
/// is an exact route prefix ending in `/` so it can only match its own
/// `/route/:name` family — never a sibling route that merely shares a stem (e.g.
/// `/api/pcb-drc/` must not exempt the mutating `POST /api/pcb-drc-rules/:name`,
/// which persists rules to disk). `/api/pcb-score-batch/` is listed explicitly
/// because it is a distinct read-only route (scores a batch, persists nothing),
/// not a child of `/api/pcb-score/`.
const read_only_posts = [_][]const u8{
    "/api/pcb-score/",
    "/api/pcb-score-batch/",
    "/api/pcb-route/",
    "/api/pcb-route-complete/",
    // Live-route start/cancel: the same compute-only routing as /api/pcb-route
    // run on a background thread (the finished run's cached-replay write is
    // the same best-effort out/ cache the review path performs).
    "/api/route-live/",
    "/api/pcb-route-analyze/",
    "/api/pcb-drc/",
    "/api/validate/",
    "/api/kicad-route-review/",
};

// ── Types ──────────────────────────────────────────────────────────────

/// Permission tier the auth middleware uses to gate writes/admin.
/// Ward roles map onto it (see `mapWardRole`); the local-dev bypass acts as
/// admin. Formerly lived in the (now-deleted) homegrown `users.zig` store.
pub const Role = enum {
    admin,
    writer,
    reader,

    /// The lowercase wire/display name of the role (as it appears in role
    /// messages and the ward mapping).
    pub fn toString(self: Role) []const u8 {
        return switch (self) {
            .admin => "admin",
            .writer => "writer",
            .reader => "reader",
        };
    }

    /// Can this role mutate designs via HTTP edit endpoints?
    pub fn canWrite(self: Role) bool {
        return self == .admin or self == .writer;
    }
};

/// Startup-resolved ward settings, owned by the process allocator. An empty URL
/// string means that path is unconfigured and must fail closed.
const WardConfig = struct {
    verify_url: []const u8,
    login_url: []const u8,
    /// Explicit RFC 9728 authorization-server base URL. Empty string = unset:
    /// `authServerUrl` then derives it by stripping `/login` off `login_url`.
    auth_server_url: []const u8,
    introspect_url: []const u8,
    service_name: []const u8,
    /// Browsable URL reported as `X-Ward-Service-Url` so ward's home page links
    /// this app rather than listing it as plain text. Empty string = unset: the
    /// header is then omitted entirely. Defaults to unset so a config literal
    /// that predates URL reporting still builds.
    service_url: []const u8 = "",
    cache_ttl_secs: i64,
};

/// One verify path's mutable state, built by `WardState.init`: the verdict cache
/// and the HTTP client that path's verifier borrows. The session and bearer paths
/// each own one (`WardState.session` / `.bearer`), guarded by that path's own
/// mutex — so no `std.http.Client` (with its shared connection pool) is ever
/// driven under two different locks. Keeping the pair in one struct makes the
/// "built vs not-built" state a single optional per path rather than a loose
/// scatter of separately-nullable fields.
const WardPath = struct {
    cache: ward.cache.Cache,
    client: net.HttpClient,
};

/// Long-lived per-server ward state: the session and bearer verify paths (each a
/// verdict-cache + HTTP-client pair, guarded by its own mutex) plus the resolved
/// config. `session`/`bearer` are null until `init` builds them; one instance
/// lives on `ServerState`.
///
/// The remaining within-path serialization — every cache miss on a path blocks
/// behind that path's single mutex while its one client makes the wardd call —
/// is an accepted tradeoff for a loopback wardd (verdicts cache, so misses are
/// rare and the round-trip is local); it is not worth a finer cache-only lock.
pub const WardState = struct {
    cfg: WardConfig = .{
        .verify_url = "",
        .login_url = "",
        .auth_server_url = "",
        .introspect_url = "",
        .service_name = default_service_name,
        .cache_ttl_secs = default_cache_ttl_secs,
    },
    session: ?WardPath = null,
    session_mu: infra_fs.Mutex = .{},
    bearer: ?WardPath = null,
    bearer_mu: infra_fs.Mutex = .{},

    /// Load the ward config from the environment and build each verify path (its
    /// verdict cache plus a dedicated HTTP client) on `allocator`
    /// (process-lifetime). Logs a warning for any unset URL so an operator sees
    /// why requests fail closed; never opens.
    pub fn init(self: *WardState, allocator: std.mem.Allocator) void {
        self.cfg = loadConfig(allocator);
        self.session = .{
            .cache = ward.cache.Cache.init(allocator, self.cfg.cache_ttl_secs),
            .client = net.initHttpClient(allocator),
        };
        self.bearer = .{
            .cache = ward.cache.Cache.init(allocator, self.cfg.cache_ttl_secs),
            .client = net.initHttpClient(allocator),
        };
        warnIfUnconfigured(self.cfg);
    }

    /// Pointer to the initialized session cache (init must have run).
    fn sessionCache(self: *WardState) *ward.cache.Cache {
        return &self.session.?.cache;
    }

    /// Pointer to the initialized bearer cache (init must have run).
    fn bearerCache(self: *WardState) *ward.cache.Cache {
        return &self.bearer.?.cache;
    }

    /// Pointer to the session path's HTTP client — borrowed only under
    /// `session_mu` (init must have run).
    fn sessionClient(self: *WardState) *net.HttpClient {
        return &self.session.?.client;
    }

    /// Pointer to the bearer path's HTTP client — borrowed only under
    /// `bearer_mu` (init must have run).
    fn bearerClient(self: *WardState) *net.HttpClient {
        return &self.bearer.?.client;
    }
};

// ── Startup ────────────────────────────────────────────────────────────

/// Read every `WARD_*` variable through the config loader, substituting empty
/// URLs (fail-closed markers) and the default service name where unset.
fn loadConfig(allocator: std.mem.Allocator) WardConfig {
    return .{
        .verify_url = config.wardVerifyUrl(allocator) orelse "",
        .login_url = config.wardLoginUrl(allocator) orelse "",
        .auth_server_url = config.wardAuthServerUrl(allocator) orelse "",
        .introspect_url = config.wardIntrospectUrl(allocator) orelse "",
        .service_name = config.wardServiceName(allocator) orelse default_service_name,
        .service_url = config.wardServiceUrl(allocator) orelse "",
        .cache_ttl_secs = config.wardCacheTtlSecs(allocator, default_cache_ttl_secs),
    };
}

/// Warn (once, at startup) when a path's URL is unset so its fail-closed
/// behaviour is diagnosable rather than mysterious.
fn warnIfUnconfigured(cfg: WardConfig) void {
    if (!sessionConfigured(cfg))
        log.warn("ward: WARD_VERIFY_URL/WARD_LOGIN_URL unset — session requests fail closed (503)", .{});
    if (!bearerConfigured(cfg))
        log.warn("ward: WARD_INTROSPECT_URL unset — sync bearer requests fail closed (503)", .{});
}

// ── Pure policy helpers ────────────────────────────────────────────────

/// Map a ward verdict role onto the netlisp role that gates writes and admin.
pub fn mapWardRole(role: ward.verdict.Role) Role {
    return switch (role) {
        .member => .writer,
        .admin => .admin,
        .unknown => .reader,
    };
}

/// Derive the ward authorization-server base URL by stripping the trailing
/// `/login` path from the configured login URL (borrows from `login_url`).
pub fn deriveAuthServer(login_url: []const u8) []const u8 {
    if (std.mem.endsWith(u8, login_url, login_path_suffix))
        return login_url[0 .. login_url.len - login_path_suffix.len];
    return login_url;
}

/// Choose the RFC 9728 authorization-server base for `cfg`: the explicitly
/// configured `WARD_AUTH_SERVER_URL` when set, else the value derived by
/// stripping `/login` off the login URL (the historical, still-correct default).
fn resolveAuthServer(cfg: WardConfig) []const u8 {
    if (cfg.auth_server_url.len > 0) return cfg.auth_server_url;
    return deriveAuthServer(cfg.login_url);
}

/// The ward authorization-server URL for the RFC 9728 protected-resource
/// metadata document, taken from the running server's ward config.
pub fn authServerUrl(ctx: *Server) []const u8 {
    return resolveAuthServer(ctx.state.ward.cfg);
}

// ── RFC 9728 protected-resource metadata ───────────────────────────────

const header_cors_allow_origin = "access-control-allow-origin";

/// GET /.well-known/oauth-protected-resource — RFC 9728 metadata that tells an
/// OAuth client which authorization server protects this resource (wardd) and
/// which bearer mechanism (header) it expects. Built by the ward library so the
/// resource identifier is this request's host and the authorization server is
/// wardd, discovered from this document alone. (netlisp is a pure resource
/// server post-migration — it no longer publishes RFC 8414 auth-server data.)
pub fn metadataProtectedResource(ctx: *Server, req: *httpz.Request, res: *httpz.Response) AuthError!void {
    const base = try requestBaseUrl(req);
    res.content_type = .JSON;
    res.header(header_cors_allow_origin, "*");
    res.body = try ward.resource.buildProtectedResourceMetadata(req.arena, base, authServerUrl(ctx));
}

/// Whether the session path has both URLs it needs (verify + login).
fn sessionConfigured(cfg: WardConfig) bool {
    return cfg.verify_url.len > 0 and cfg.login_url.len > 0;
}

/// Whether the bearer path has the introspection URL it needs.
fn bearerConfigured(cfg: WardConfig) bool {
    return cfg.introspect_url.len > 0;
}

/// Whether a bearer grant's `scope` authorizes this service (whole-entry match).
fn serviceScopeOk(scope: []const u8, service: []const u8) bool {
    return ward.bearer.hasScope(scope, service);
}

/// Whether `req` mutates server state and therefore needs the writer role.
/// Safe methods and a small pure-computation POST allowlist are open.
fn requiresWrite(req: *httpz.Request) bool {
    return requiresWriteFor(req.method, req.url.path);
}

/// `requiresWrite` over the two fields it actually reads, so the policy is
/// testable without standing up a request. Safe methods are open; a POST is
/// write-gated unless its path starts with a `read_only_posts` prefix (each of
/// which ends in `/`, so a sibling route sharing a stem is NOT exempted).
fn requiresWriteFor(method: httpz.Method, path: []const u8) bool {
    if (method == .GET or method == .HEAD or method == .OPTIONS) return false;
    for (read_only_posts) |p| {
        if (std.mem.startsWith(u8, path, p)) return false;
    }
    return true;
}

// ── Middleware ─────────────────────────────────────────────────────────

/// Gate every request before dispatch. Returns true to proceed, false when a
/// response (302 / 401 / 403 / 503) has already been written. The local-dev
/// bypass and the plugin-token sync path are preserved; ward owns the session
/// and bearer verdicts.
pub fn authMiddleware(ctx: *Server, req: *httpz.Request, res: *httpz.Response) AuthError!bool {
    if (auth.isLocalhostRequest(ctx, req)) return true;
    const path = req.url.path;
    if (std.mem.startsWith(u8, path, sync_path_prefix) and syncBearerOk(ctx, req)) return true;
    return sessionGateMiddleware(ctx, req, res);
}

/// The plugin-or-bearer check for `/api/sync-kicad-pcb/`: a plugin token wins
/// outright, else a valid ward bearer. Returns false (fall through to the
/// session path) rather than writing a response, matching the old applier.
fn syncBearerOk(ctx: *Server, req: *httpz.Request) bool {
    if (auth.validatePluginBearerToken(ctx, req)) return true;
    return wardBearerAllows(ctx, req);
}

/// Whether a live ward grant may drive the sync write. Two independent
/// conditions, both required:
///
///   * **scope** — wardd is a shared auth server, so a bearer minted for another
///     service must not reach this one.
///   * **role** — `POST /api/sync-kicad-pcb/:name` rewrites the KiCad board file
///     in place. It is the most destructive write the server offers, and the
///     bearer leg of `authMiddleware` returns `true` straight past the session
///     gate's `requiresWrite` check — so without this, a ward READER holding an
///     netlisp-scoped token could drive it. The role mapping is
///     `mapWardRole`: member→writer, admin→admin, unknown→reader.
fn wardSyncGrantOk(scope: []const u8, role: ward.verdict.Role, service: []const u8) bool {
    return serviceScopeOk(scope, service) and mapWardRole(role).canWrite();
}

/// Whether `req` carries a live ward bearer token *scoped for this service* and
/// carrying a *writer-capable role* (see `wardSyncGrantOk`), without writing a
/// response — the OAuth fallback the sync applier accepted before. A grant
/// failing either half returns false so the caller falls through to the
/// plugin/session path — the fall-through contract (never write a response here)
/// is preserved, and the session gate then answers 401/403 for it.
fn wardBearerAllows(ctx: *Server, req: *httpz.Request) bool {
    const state = &ctx.state.ward;
    if (!bearerConfigured(state.cfg)) return false;
    const action = bearerDecision(state, req, "") catch return false;
    return switch (action) {
        .allow => |id| wardSyncGrantOk(id.scope, id.role, state.cfg.service_name),
        else => false,
    };
}

/// Run the ward bearer middleware under the bearer mutex, returning the action.
/// The `allow` identity strings are request-arena owned, so they stay valid
/// after the lock is released.
fn bearerDecision(state: *WardState, req: *httpz.Request, challenge: []const u8) AuthError!ward.bearer.BearerAction {
    const gate = ward.bearer.BearerGate{
        .allowlist = .{ .patterns = &.{} },
        .challenge = challenge,
        .cache = state.bearerCache(),
        .now = clock.timestamp(),
    };
    const request = ward.bearer.BearerRequest{
        .authorization = req.header(header_authorization),
        .path = req.url.path,
    };
    var verifier = bearerVerifier(state);
    state.bearer_mu.lock();
    defer state.bearer_mu.unlock();
    return ward.bearer.requireBearer(req.arena, gate, request, &verifier);
}

/// The ward session gate: allowlisted routes proceed; otherwise verify the
/// `ward_session` cookie, redirect to the ward login when absent/invalid, fail
/// closed when unconfigured or wardd is unreachable, and write-gate mutations.
fn sessionGateMiddleware(ctx: *Server, req: *httpz.Request, res: *httpz.Response) AuthError!bool {
    const state = &ctx.state.ward;
    const path = req.url.path;
    if (sessionAllowlist().isPublic(path)) return true;
    if (!sessionConfigured(state.cfg)) return failClosed(res);
    const request = ward.middleware.Request{
        .cookie_header = req.header(header_cookie),
        .path = path,
        .url = try currentUrl(req),
    };
    const decision = try sessionDecision(state, req.arena, request);
    switch (decision.action) {
        // Unreachable: `sessionAllowlist().isPublic(path)` is checked at the top
        // of this function and returns early, so a public path never reaches
        // `requireUser` to come back as a `.public` action.
        .public => unreachable,
        .allow => {
            if (requiresWrite(req) and !mapWardRole(decision.role).canWrite())
                return forbidden(res, body_forbidden_write);
            return true;
        },
        // An unauthenticated XHR/fetch to an /api/ route wants a 401 it can
        // handle, not an HTML login redirect (the pre-migration behaviour).
        .redirect => |location| return if (isApiPath(path)) unauthorizedApi(res) else redirectTo(res, location),
        .fail_closed => return failClosed(res),
    }
}

/// Whether `path` targets a JSON API route (redirects there answer 401, not 302).
fn isApiPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/api/");
}

/// The session action plus the ward role behind it (read from the cache under
/// the session mutex, since `requireUser`'s action drops the role).
const SessionDecision = struct {
    action: ward.verdict.Action,
    role: ward.verdict.Role,
};

/// Run the ward session middleware under the session mutex and read back the
/// role the just-cached (or already-cached) verdict carries, so a mutating
/// request can be write-gated on it.
fn sessionDecision(
    state: *WardState,
    arena: std.mem.Allocator,
    request: ward.middleware.Request,
) AuthError!SessionDecision {
    const gate = sessionGate(state, clock.timestamp());
    var verifier = sessionVerifier(state);
    state.session_mu.lock();
    defer state.session_mu.unlock();
    const action = try ward.middleware.requireUser(arena, gate, request, &verifier);
    const role = cachedSessionRole(state, request.cookie_header, gate.now);
    return .{ .action = action, .role = role };
}

// ── Gate / verifier / cookie helpers ───────────────────────────────────

/// The public-route allowlist shared by the session gate and its tests.
fn sessionAllowlist() ward.allowlist.Allowlist {
    return .{ .patterns = &public_routes };
}

/// Build the ward session gate for `state` at `now`.
fn sessionGate(state: *WardState, now: i64) ward.middleware.Gate {
    return .{
        .allowlist = sessionAllowlist(),
        .login_url = state.cfg.login_url,
        .cache = state.sessionCache(),
        .now = now,
    };
}

/// Build the production session verifier over the session path's HTTP client
/// (borrowed under `session_mu`).
fn sessionVerifier(state: *WardState) ward.http.HttpVerifier {
    return .{
        .client = state.sessionClient(),
        .verify_url = state.cfg.verify_url,
        .service_name = state.cfg.service_name,
        .service_url = serviceUrlOrNull(state.cfg),
    };
}

/// The configured browsable URL, or null when unset. An empty `service_url`
/// means "report none", which omits the header rather than sending a blank
/// value wardd would only have to reject.
fn serviceUrlOrNull(cfg: WardConfig) ?[]const u8 {
    return if (cfg.service_url.len == 0) null else cfg.service_url;
}

/// Build the production bearer-introspection verifier over the bearer path's
/// HTTP client (borrowed under `bearer_mu`).
fn bearerVerifier(state: *WardState) ward.bearer_http.BearerHttpVerifier {
    return .{
        .client = state.bearerClient(),
        .introspect_url = state.cfg.introspect_url,
    };
}

/// Extract the ward session token (`ward_session=` value) from a raw `Cookie`
/// header, or null when absent or empty.
fn wardSessionToken(cookie_header: ?[]const u8) ?[]const u8 {
    const header = cookie_header orelse return null;
    var it = std.mem.splitScalar(u8, header, ';');
    while (it.next()) |pair| {
        const trimmed = std.mem.trim(u8, pair, " ");
        const eq = std.mem.indexOfScalar(u8, trimmed, '=') orelse continue;
        if (std.mem.eql(u8, trimmed[0..eq], ward.middleware.session_cookie_name)) {
            const value = trimmed[eq + 1 ..];
            return if (value.len == 0) null else value;
        }
    }
    return null;
}

/// The ward role cached for this request's session token, or `.unknown` when
/// absent or uncached. Caller must hold the session mutex.
fn cachedSessionRole(state: *WardState, cookie_header: ?[]const u8, now: i64) ward.verdict.Role {
    const token = wardSessionToken(cookie_header) orelse return .unknown;
    const hit = state.sessionCache().get(token, now) orelse return .unknown;
    return hit.role;
}

// ── Request URL helpers ────────────────────────────────────────────────

/// Whether the request arrived over HTTPS (honouring the reverse-proxy hint).
fn isHttps(req: *httpz.Request) bool {
    const proto = req.header(header_forwarded_proto) orelse return false;
    return std.mem.eql(u8, proto, scheme_https);
}

/// The `scheme://host` base of the current request, arena-allocated.
fn requestBaseUrl(req: *httpz.Request) AuthError![]const u8 {
    const host = req.header(header_host) orelse "localhost";
    const scheme = if (isHttps(req)) scheme_https else scheme_http;
    return std.fmt.allocPrint(req.arena, url_template, .{ scheme, host });
}

/// The absolute URL of the current request (base + raw target), arena-allocated,
/// so the ward login redirect can carry it back as its `?rd=` return target.
fn currentUrl(req: *httpz.Request) AuthError![]const u8 {
    const base = try requestBaseUrl(req);
    return std.fmt.allocPrint(req.arena, concat_template, .{ base, req.url.raw });
}

// ── Response writers ───────────────────────────────────────────────────

/// Write a JSON response with `status` and `body`, then stop dispatch (returns
/// false). The shared shape behind the plain-body responders below; the redirect
/// and bearer-challenge writers stay separate because they add a header.
fn writeJson(res: *httpz.Response, status: u16, body: []const u8) bool {
    res.status = status;
    res.content_type = .JSON;
    res.body = body;
    return false;
}

/// Write a 503 fail-closed JSON response and stop dispatch.
fn failClosed(res: *httpz.Response) bool {
    return writeJson(res, http_service_unavailable, body_unavailable);
}

/// Write a 403 forbidden JSON response with `body` and stop dispatch.
fn forbidden(res: *httpz.Response, body: []const u8) bool {
    return writeJson(res, http_forbidden, body);
}

/// Write a 302 redirect to `location` and stop dispatch.
fn redirectTo(res: *httpz.Response, location: []const u8) bool {
    res.status = http_redirect_found;
    res.header("location", location);
    return false;
}

/// Write a 401 with the RFC 9728 `WWW-Authenticate` challenge and stop dispatch.
fn unauthorizedBearer(res: *httpz.Response, challenge: []const u8) bool {
    res.status = http_unauthorized;
    res.content_type = .JSON;
    res.header(header_www_authenticate, challenge);
    res.body = body_unauthorized;
    return false;
}

/// Write a plain 401 JSON for an unauthenticated API request and stop dispatch.
fn unauthorizedApi(res: *httpz.Response) bool {
    return writeJson(res, http_unauthorized, body_api_unauthorized);
}

// ── Tests ──────────────────────────────────────────────────────────────

/// Test double standing in for the network-backed session verifier: answers
/// every verify call with a preset verdict (no network).
const FakeVerifier = struct {
    verdict: ward.verdict.Verdict,

    /// Answer the ward verify port with the preset verdict (no network), duping
    /// the username so the caller owns it exactly like the real verifier.
    pub fn verify(
        self: *FakeVerifier,
        allocator: std.mem.Allocator,
        token: []const u8,
    ) std.mem.Allocator.Error!ward.verdict.Verdict {
        _ = token;
        return switch (self.verdict) {
            .authorized => |a| .{ .authorized = .{
                .username = try allocator.dupe(u8, a.username),
                .role = a.role,
            } },
            else => self.verdict,
        };
    }
};

// spec: serve - A configured browsable url is reported to ward while an unset one omits the header
test "serviceUrlOrNull reports a configured url and omits an unset one" {
    const configured = WardConfig{
        .verify_url = "",
        .login_url = "",
        .auth_server_url = "",
        .introspect_url = "",
        .service_name = default_service_name,
        .service_url = "https://netlisp.example",
        .cache_ttl_secs = default_cache_ttl_secs,
    };
    try std.testing.expectEqualStrings("https://netlisp.example", serviceUrlOrNull(configured).?);
    // The field defaults to unset, so an untouched config reports no url at all
    // rather than an empty one wardd would reject.
    const unset = WardConfig{
        .verify_url = "",
        .login_url = "",
        .auth_server_url = "",
        .introspect_url = "",
        .service_name = default_service_name,
        .cache_ttl_secs = default_cache_ttl_secs,
    };
    try std.testing.expect(serviceUrlOrNull(unset) == null);
}

// spec: serve - Ward member maps to the writer role, admin to admin, and an unknown role to reader
test "mapWardRole maps ward roles onto netlisp roles" {
    try std.testing.expectEqual(Role.writer, mapWardRole(.member));
    try std.testing.expectEqual(Role.admin, mapWardRole(.admin));
    try std.testing.expectEqual(Role.reader, mapWardRole(.unknown));
}

// spec: serve - An unconfigured ward adapter reports session and bearer paths unconfigured so requests fail closed
test "session and bearer config predicates require their urls" {
    const empty = WardConfig{
        .verify_url = "",
        .login_url = "",
        .auth_server_url = "",
        .introspect_url = "",
        .service_name = default_service_name,
        .cache_ttl_secs = default_cache_ttl_secs,
    };
    try std.testing.expect(!sessionConfigured(empty));
    try std.testing.expect(!bearerConfigured(empty));
    const full = WardConfig{
        .verify_url = "v",
        .login_url = "l",
        .auth_server_url = "",
        .introspect_url = "i",
        .service_name = default_service_name,
        .cache_ttl_secs = default_cache_ttl_secs,
    };
    try std.testing.expect(sessionConfigured(full));
    try std.testing.expect(bearerConfigured(full));
    // The session path needs BOTH urls — a single populated url is not enough
    // (guards the `and` and each `len > 0` against a loosening mutation).
    const verify_only = WardConfig{
        .verify_url = "v",
        .login_url = "",
        .auth_server_url = "",
        .introspect_url = "",
        .service_name = default_service_name,
        .cache_ttl_secs = default_cache_ttl_secs,
    };
    const login_only = WardConfig{
        .verify_url = "",
        .login_url = "l",
        .auth_server_url = "",
        .introspect_url = "",
        .service_name = default_service_name,
        .cache_ttl_secs = default_cache_ttl_secs,
    };
    try std.testing.expect(!sessionConfigured(verify_only));
    try std.testing.expect(!sessionConfigured(login_only));
}

// spec: serve - The service scope check accepts a scope containing the service name and rejects one without it
test "serviceScopeOk requires a whole-entry service scope" {
    try std.testing.expect(serviceScopeOk("netlisp", "netlisp"));
    try std.testing.expect(serviceScopeOk("files netlisp", "netlisp"));
    try std.testing.expect(serviceScopeOk("netlisp files", "netlisp"));
    try std.testing.expect(!serviceScopeOk("files", "netlisp"));
    try std.testing.expect(!serviceScopeOk("", "netlisp"));
    // A prefix lookalike is not a whole-entry match — "netlispx" must not authorize "netlisp".
    try std.testing.expect(!serviceScopeOk("netlispx", "netlisp"));
    try std.testing.expect(!serviceScopeOk("files netlispx", "netlisp"));
}

// spec: serve - The sync bearer grant requires both a service scope and a writer-capable role
test "wardSyncGrantOk requires the netlisp scope and a writer-capable role together" {
    // Both halves present — the fallback the KiCad sync agent relies on.
    try std.testing.expect(wardSyncGrantOk("netlisp", .member, "netlisp"));
    try std.testing.expect(wardSyncGrantOk("files netlisp", .admin, "netlisp"));
    // Role without scope: a token minted for another service on this shared
    // wardd must not reach the board write however privileged its holder.
    try std.testing.expect(!wardSyncGrantOk("files", .admin, "netlisp"));
    try std.testing.expect(!wardSyncGrantOk("", .member, "netlisp"));
    // Scope without role: `.unknown` maps to reader, and a reader may not
    // rewrite the board — the leg that used to be missing entirely, since the
    // bearer path returns before the session gate's write check.
    try std.testing.expect(!wardSyncGrantOk("netlisp", .unknown, "netlisp"));
    try std.testing.expect(!wardSyncGrantOk("files netlisp", .unknown, "netlisp"));
}

// spec: serve - Every read-only post prefix exempts only its own route family while safe methods are never write-gated
test "requiresWriteFor exempts each read-only post prefix and gates its siblings" {
    // Safe methods are open whatever the path; everything else mutates by default.
    try std.testing.expect(!requiresWriteFor(.GET, "/api/edit-value/x"));
    try std.testing.expect(!requiresWriteFor(.HEAD, "/api/edit-value/x"));
    try std.testing.expect(!requiresWriteFor(.OPTIONS, "/api/edit-value/x"));
    try std.testing.expect(requiresWriteFor(.POST, "/api/edit-value/x"));
    try std.testing.expect(requiresWriteFor(.PUT, "/api/edit-value/x"));
    try std.testing.expect(requiresWriteFor(.DELETE, "/api/edit-value/x"));

    for (read_only_posts) |p| {
        // Each listed prefix exempts its own family…
        try std.testing.expect(!requiresWriteFor(.POST, p));
        // …and each is written with a trailing `/`, which is the ONLY thing
        // stopping a sibling route that shares the stem from inheriting the
        // exemption. An entry that lost its slash would widen the gate silently.
        try std.testing.expect(std.mem.endsWith(u8, p, "/"));
    }

    // The one-character-wide hazard the list's own comment names, pinned on both
    // sides: `/api/pcb-drc/:name` computes, `/api/pcb-drc-rules/:name` persists.
    try std.testing.expect(!requiresWriteFor(.POST, "/api/pcb-drc/barracuda"));
    try std.testing.expect(requiresWriteFor(.POST, "/api/pcb-drc-rules/barracuda"));
    // Same shape for the score pair: the batch route is listed in its own right,
    // and a third name sharing the stem is NOT exempt.
    try std.testing.expect(!requiresWriteFor(.POST, "/api/pcb-score/x"));
    try std.testing.expect(!requiresWriteFor(.POST, "/api/pcb-score-batch/x"));
    try std.testing.expect(requiresWriteFor(.POST, "/api/pcb-scores/x"));
    // And for the route/validate families.
    try std.testing.expect(!requiresWriteFor(.POST, "/api/pcb-route/x"));
    try std.testing.expect(requiresWriteFor(.POST, "/api/pcb-route-analyze-save/x"));
    try std.testing.expect(!requiresWriteFor(.POST, "/api/validate/x"));
    try std.testing.expect(requiresWriteFor(.POST, "/api/validate-and-write/x"));
    // A prefix stripped of its trailing slash is not itself exempt.
    try std.testing.expect(requiresWriteFor(.POST, "/api/pcb-drc"));
    // The genuinely destructive routes are gated.
    try std.testing.expect(requiresWriteFor(.POST, "/api/sync-kicad-pcb/x"));
    try std.testing.expect(requiresWriteFor(.POST, "/api/push/x"));
}

// spec: serve - Every public route entry is served without a session while a sibling sharing its leading text is not
test "the session allowlist admits exactly its public routes" {
    const rows = [_]struct { path: []const u8, public: bool }{
        // "/static/*" — the subtree entry the login/setup flow pulls assets from.
        .{ .path = "/static", .public = true },
        .{ .path = "/static/app.css", .public = true },
        .{ .path = "/static/pcb/board.js", .public = true },
        .{ .path = "/statics/app.css", .public = false },
        .{ .path = "/staticx", .public = false },
        // "/.well-known/oauth-protected-resource" — the exact RFC 9728 entry.
        .{ .path = "/.well-known/oauth-protected-resource", .public = true },
        .{ .path = "/.well-known/oauth-protected-resource/x", .public = false },
        .{ .path = "/.well-known/oauth-protected-resourcex", .public = false },
        // Deleted in the ward migration — netlisp is a resource server now, so
        // the authorization-server document must NOT be public (or served).
        .{ .path = "/.well-known/oauth-authorization-server", .public = false },
        // Nothing else bypasses the session gate.
        .{ .path = "/", .public = false },
        .{ .path = "/api/scene-graph/x", .public = false },
        .{ .path = "/auth/login", .public = false },
    };
    for (rows) |r| try std.testing.expectEqual(r.public, sessionAllowlist().isPublic(r.path));
    // The rows above enumerate BOTH entries by hand; a third one added without
    // its own rows here fails rather than landing unpinned.
    try std.testing.expectEqual(@as(usize, 2), public_routes.len);
}

// spec: serve - The ward auth-server url is derived by stripping the login path from the configured login url
test "deriveAuthServer strips the trailing login path" {
    const login = "https" ++ "://ward.example/login";
    try std.testing.expectEqualStrings("https" ++ "://ward.example", deriveAuthServer(login));
    try std.testing.expectEqualStrings("bare-host", deriveAuthServer("bare-host"));
}

// spec: serve - The auth-server url prefers explicit config over the login-path strip
test "resolveAuthServer prefers explicit config over the derived fallback" {
    const explicit = WardConfig{
        .verify_url = "",
        .login_url = "https" ++ "://ward.example/login",
        .auth_server_url = "https" ++ "://auth.example",
        .introspect_url = "",
        .service_name = default_service_name,
        .cache_ttl_secs = default_cache_ttl_secs,
    };
    // An explicit WARD_AUTH_SERVER_URL wins verbatim, ignoring the login url.
    try std.testing.expectEqualStrings("https" ++ "://auth.example", resolveAuthServer(explicit));
    const derived = WardConfig{
        .verify_url = "",
        .login_url = "https" ++ "://ward.example/login",
        .auth_server_url = "",
        .introspect_url = "",
        .service_name = default_service_name,
        .cache_ttl_secs = default_cache_ttl_secs,
    };
    // Empty explicit config falls back to stripping /login off the login url.
    try std.testing.expectEqualStrings("https" ++ "://ward.example", resolveAuthServer(derived));
}

// spec: serve - A cookieless session request is decided as a redirect to the ward login url carrying the return target
test "a cookieless session request decides to redirect to the ward login" {
    const login = "https" ++ "://ward.example/login";
    var state: WardState = .{};
    state.cfg = .{
        .verify_url = "http" ++ "://v",
        .login_url = login,
        .auth_server_url = "",
        .introspect_url = "http" ++ "://i",
        .service_name = default_service_name,
        .cache_ttl_secs = 30,
    };
    state.session = .{
        .cache = ward.cache.Cache.init(std.testing.allocator, 30),
        .client = net.initHttpClient(std.testing.allocator),
    };
    defer {
        state.session.?.cache.deinit();
        state.session.?.client.deinit();
    }

    var verifier = FakeVerifier{ .verdict = .{ .authorized = .{ .username = "ada", .role = .member } } };
    const gate = sessionGate(&state, 100);
    const request = ward.middleware.Request{
        .cookie_header = null,
        .path = "/dashboard",
        .url = "https" ++ "://app.example/dashboard",
    };
    const action = try ward.middleware.requireUser(std.testing.allocator, gate, request, &verifier);
    defer action.deinit(std.testing.allocator);
    try std.testing.expect(std.meta.activeTag(action) == .redirect);
    try std.testing.expect(std.mem.startsWith(u8, action.redirect, login));
    try std.testing.expect(std.mem.indexOf(u8, action.redirect, "rd=") != null);
}

// spec: serve - An api path is distinguished from a non-api path for the 401-versus-redirect choice
test "isApiPath distinguishes api routes" {
    try std.testing.expect(isApiPath("/api/version/x"));
    try std.testing.expect(isApiPath("/api/"));
    try std.testing.expect(!isApiPath("/apix"));
    try std.testing.expect(!isApiPath("/schematics/x"));
    try std.testing.expect(!isApiPath("/"));
}

// spec: serve - The ward session cookie value is read from the cookie header and absent when empty or missing
test "wardSessionToken extracts the ward_session value" {
    try std.testing.expectEqualStrings("abc", wardSessionToken("ward_session=abc").?);
    try std.testing.expectEqualStrings("xyz", wardSessionToken("other=1; ward_session=xyz").?);
    // Empty value, wrong cookie, and an absent header all read back null.
    try std.testing.expect(wardSessionToken("ward_session=") == null);
    try std.testing.expect(wardSessionToken("other=1") == null);
    try std.testing.expect(wardSessionToken(null) == null);
}

// spec: serve - A cached session role is read back by token and reported unknown when absent or expired
test "cachedSessionRole reads the cached role for a session token" {
    var state: WardState = .{};
    state.session = .{
        .cache = ward.cache.Cache.init(std.testing.allocator, 30),
        .client = net.initHttpClient(std.testing.allocator),
    };
    defer {
        state.session.?.cache.deinit();
        state.session.?.client.deinit();
    }
    try state.sessionCache().put("tok", "ada", .admin, "", 100);
    try std.testing.expectEqual(ward.verdict.Role.admin, cachedSessionRole(&state, "ward_session=tok", 110));
    // Absent cookie, an unknown token, and an elapsed entry all read back unknown.
    try std.testing.expectEqual(ward.verdict.Role.unknown, cachedSessionRole(&state, null, 110));
    try std.testing.expectEqual(ward.verdict.Role.unknown, cachedSessionRole(&state, "ward_session=other", 110));
    try std.testing.expectEqual(ward.verdict.Role.unknown, cachedSessionRole(&state, "ward_session=tok", 131));
}

// spec: serve - Admin and writer may write while reader may not, and roles stringify lowercase
test "role write predicate and toString" {
    try std.testing.expect(Role.admin.canWrite());
    try std.testing.expect(Role.writer.canWrite());
    try std.testing.expect(!Role.reader.canWrite());
    try std.testing.expectEqualStrings("admin", Role.admin.toString());
    try std.testing.expectEqualStrings("writer", Role.writer.toString());
    try std.testing.expectEqualStrings("reader", Role.reader.toString());
}

// spec: serve - An unavailable session verifier resolves the request to fail closed rather than admit it
test "an unavailable session verifier fails closed through the netlisp gate" {
    var state: WardState = .{};
    state.cfg = .{
        .verify_url = "http" ++ "://v",
        .login_url = "https" ++ "://ward.example/login",
        .auth_server_url = "",
        .introspect_url = "http" ++ "://i",
        .service_name = default_service_name,
        .cache_ttl_secs = 30,
    };
    state.session = .{
        .cache = ward.cache.Cache.init(std.testing.allocator, 30),
        .client = net.initHttpClient(std.testing.allocator),
    };
    defer {
        state.session.?.cache.deinit();
        state.session.?.client.deinit();
    }
    var verifier = FakeVerifier{ .verdict = .unavailable };
    const gate = sessionGate(&state, 100);
    const request = ward.middleware.Request{
        .cookie_header = "ward_session=live-token",
        .path = "/dashboard",
        .url = "https" ++ "://app.example/dashboard",
    };
    const action = try ward.middleware.requireUser(std.testing.allocator, gate, request, &verifier);
    defer action.deinit(std.testing.allocator);
    try std.testing.expect(std.meta.activeTag(action) == .fail_closed);
}

// spec: serve - Ward state initialization builds distinct http clients for the session and bearer verify paths
test "WardState init builds a distinct http client per verify path" {
    // A shared std.http.Client driven under two different mutexes was the race;
    // pin that the session and bearer paths get their own client. An arena backs
    // init so the config strings / caches / clients it allocates are reclaimed
    // wholesale — a freshly built client holds no sockets, so no deinit is due.
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var state: WardState = .{};
    state.init(arena.allocator());
    try std.testing.expect(state.sessionClient() != state.bearerClient());
}
