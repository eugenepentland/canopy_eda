const std = @import("std");
const httpz = @import("httpz");

const server_mod = @import("../serve.zig");
const Handler = server_mod.Handler;
const auth = @import("auth.zig");
const store = @import("oauth_store.zig");
const oauth_template = @import("templates/oauth.zig");

// ── Constants ─────────────────────────────────────────────────────
const HEADER_CORS_ALLOW_ORIGIN = "access-control-allow-origin";
const KEY_CLIENT_ID = "client_id";
const KEY_REDIRECT_URI = "redirect_uri";
const ERR_INVALID_GRANT = "invalid_grant";
const ERR_INVALID_REQUEST = "invalid_request";
const ERR_MISSING_CLIENT_ID = "missing client_id";
const ERR_MISSING_REDIRECT_URI = "missing redirect_uri";

/// Error set for HTTP handlers in this module.
pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error ||
    std.fs.File.WriteError || std.fs.File.OpenError ||
    error{ FileTooBig, StreamTooLong, EndOfStream, InvalidEscapeSequence };

fn requestUrl(ctx: *Handler, req: *httpz.Request) ![]const u8 {
    const host = req.header("host") orelse "localhost";
    const scheme = if (isTls(req)) "https" else "http";
    return std.fmt.allocPrint(ctx.allocator, "{s}://{s}", .{ scheme, host });
}

fn isTls(req: *httpz.Request) bool {
    // Honour reverse-proxy hint. httpz itself only speaks plain HTTP today.
    if (req.header("x-forwarded-proto")) |p| {
        return std.mem.eql(u8, p, "https");
    }
    return false;
}

/// GET /.well-known/oauth-protected-resource — RFC 9728 metadata that
/// tells Claude Code which authorization server protects this MCP
/// resource and which bearer mechanism (header) it expects.
pub fn metadataProtectedResource(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const base = try requestUrl(ctx, req);
    defer ctx.allocator.free(base);
    res.content_type = .JSON;
    res.header(HEADER_CORS_ALLOW_ORIGIN, "*");
    res.body = try std.fmt.allocPrint(
        req.arena,
        \\{{"resource":"{s}","authorization_servers":["{s}"],"scopes_supported":["mcp"],"bearer_methods_supported":["header"]}}
    ,
        .{ base, base },
    );
}

/// GET /.well-known/oauth-authorization-server — RFC 8414 metadata
/// describing this server's authorization and token endpoints, supported
/// PKCE method (S256), and the `mcp` scope used by Claude Code.
pub fn metadataAuthServer(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const base = try requestUrl(ctx, req);
    defer ctx.allocator.free(base);
    res.content_type = .JSON;
    res.header(HEADER_CORS_ALLOW_ORIGIN, "*");
    res.body = try std.fmt.allocPrint(
        req.arena,
        "{{\"issuer\":\"{s}\"," ++
            "\"authorization_endpoint\":\"{s}/oauth/authorize\"," ++
            "\"token_endpoint\":\"{s}/oauth/token\"," ++
            "\"registration_endpoint\":\"{s}/oauth/register\"," ++
            "\"response_types_supported\":[\"code\"]," ++
            "\"grant_types_supported\":[\"authorization_code\"]," ++
            "\"code_challenge_methods_supported\":[\"S256\"]," ++
            "\"token_endpoint_auth_methods_supported\":[\"client_secret_post\"]," ++
            "\"scopes_supported\":[\"mcp\"]}}",
        .{ base, base, base, base },
    );
}

/// POST /oauth/register — RFC 7591 Dynamic Client Registration.
///
/// Body: JSON with `client_name` (string) and `redirect_uris` (array of one).
/// Only loopback redirect_uris (`http://127.0.0.1[:port]/path` or
/// `http://localhost[:port]/path`) are accepted — public clients without
/// pre-existing operator review can't be allowed to redirect anywhere else.
///
/// Returns the standard RFC 7591 client-info response. The minted client
/// has no `email` (owner) yet; the first user to approve it on
/// `/oauth/authorize` claims it via `store.claimClient`. Until then it
/// can't actually do anything — `/oauth/authorize` still requires the
/// user to sign in before issuing any auth code.
pub fn registerEndpoint(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const body = req.body() orelse "";
    const Body = struct {
        client_name: ?[]const u8 = null,
        redirect_uris: ?[]const []const u8 = null,
        scope: ?[]const u8 = null,
        // RFC 7591 lists more optional fields; we accept and ignore them.
    };
    const parsed = std.json.parseFromSlice(Body, req.arena, body, .{ .ignore_unknown_fields = true, .allocate = .alloc_always }) catch {
        return registerError(req, res, ERR_INVALID_REQUEST, "request body must be JSON with client_name and redirect_uris");
    };
    defer parsed.deinit();

    const uris = parsed.value.redirect_uris orelse return registerError(req, res, ERR_INVALID_REQUEST, "redirect_uris required");
    if (uris.len != 1) return registerError(req, res, ERR_INVALID_REQUEST, "exactly one redirect_uri is required");
    const redirect_uri = uris[0];
    if (parseLoopbackUri(redirect_uri) == null) {
        return registerError(req, res, "invalid_redirect_uri", "redirect_uri must be a loopback URI (http://127.0.0.1 or http://localhost)");
    }

    const client_name = parsed.value.client_name orelse "Dynamic Client";
    if (client_name.len > 200) return registerError(req, res, ERR_INVALID_REQUEST, "client_name too long");

    // Empty email = unclaimed; first /oauth/authorize approval will set it.
    const minted = store.createClient(ctx.allocator, ctx.auth_dir, client_name, "", redirect_uri) catch {
        res.status = 500;
        res.content_type = .JSON;
        res.body = "{\"error\":\"server_error\",\"error_description\":\"could not register client\"}";
        return;
    };

    res.status = 201;
    res.content_type = .JSON;
    res.header("cache-control", "no-store");
    res.header(HEADER_CORS_ALLOW_ORIGIN, "*");
    // RFC 7591 §3.2.1 response shape. `token_endpoint_auth_method` matches
    // what the metadata advertises so the client knows to POST creds in the
    // form body rather than HTTP Basic.
    res.body = try std.fmt.allocPrint(
        req.arena,
        "{{\"client_id\":\"{s}\"," ++
            "\"client_secret\":\"{s}\"," ++
            "\"client_name\":\"{s}\"," ++
            "\"redirect_uris\":[\"{s}\"]," ++
            "\"grant_types\":[\"authorization_code\"]," ++
            "\"response_types\":[\"code\"]," ++
            "\"token_endpoint_auth_method\":\"client_secret_post\"," ++
            "\"scope\":\"mcp\"}}",
        .{ minted.id, minted.secret, client_name, redirect_uri },
    );
}

fn registerError(req: *httpz.Request, res: *httpz.Response, code: []const u8, desc: []const u8) void {
    res.status = 400;
    res.content_type = .JSON;
    res.header(HEADER_CORS_ALLOW_ORIGIN, "*");
    res.body = std.fmt.allocPrint(
        req.arena,
        \\{{"error":"{s}","error_description":"{s}"}}
    ,
        .{ code, desc },
    ) catch "{\"error\":\"server_error\"}";
}

/// GET /oauth/authorize
/// Query params: response_type=code, client_id, redirect_uri, scope, state,
/// code_challenge, code_challenge_method=S256.
///
/// If signed in, render a consent page. If not, render a "please sign in" page
/// with a link to /auth/login.
pub fn authorizePage(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const q = try req.query();
    const client_id = q.get(KEY_CLIENT_ID) orelse return badRequest(res, ERR_MISSING_CLIENT_ID);
    const redirect_uri = q.get(KEY_REDIRECT_URI) orelse return badRequest(res, ERR_MISSING_REDIRECT_URI);
    const response_type = q.get("response_type") orelse "";
    const state = q.get("state") orelse "";
    const code_challenge = q.get("code_challenge") orelse "";
    const code_challenge_method = q.get("code_challenge_method") orelse "";
    const scope = q.get("scope") orelse "mcp";

    if (!std.mem.eql(u8, response_type, "code")) return badRequest(res, "response_type must be \"code\"");
    if (code_challenge.len == 0) return badRequest(res, "missing code_challenge (PKCE required)");
    if (!std.mem.eql(u8, code_challenge_method, "S256")) return badRequest(res, "code_challenge_method must be \"S256\"");

    const client = store.findClient(ctx.allocator, ctx.auth_dir, client_id) orelse return badRequest(res, "unknown client_id");
    if (!redirectUriMatches(client.redirect_uri, redirect_uri)) {
        const msg = try std.fmt.allocPrint(
            req.arena,
            "redirect_uri mismatch.\n" ++
                "Requested:  {s}\n" ++
                "Registered: {s}\n\n" ++
                "Revoke this client at /account and re-register with a matching URI.\n" ++
                "(Loopback ports may differ — host and path must match.)",
            .{ redirect_uri, client.redirect_uri },
        );
        return badRequest(res, msg);
    }

    const signed_in_email: ?[]const u8 = auth.currentEmail(ctx, req);

    var aw: std.Io.Writer.Allocating = .init(req.arena);
    try oauth_template.Authorize.render(.{
        client.name,
        signed_in_email,
        scope,
        client_id,
        redirect_uri,
        state,
        code_challenge,
    }, &aw.writer);
    res.content_type = .HTML;
    res.body = aw.written();
}

/// POST /oauth/authorize/approve
/// User has clicked "Authorize" on the consent page. Re-validate everything,
/// mint an auth code, and 302-redirect to the client's redirect_uri.
pub fn authorizeApprove(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const email = auth.currentEmail(ctx, req) orelse return unauthorized(res);

    const form = try req.formData();
    const client_id = form.get(KEY_CLIENT_ID) orelse return badRequest(res, ERR_MISSING_CLIENT_ID);
    const redirect_uri = form.get(KEY_REDIRECT_URI) orelse return badRequest(res, ERR_MISSING_REDIRECT_URI);
    const state = form.get("state") orelse "";
    const code_challenge = form.get("code_challenge") orelse return badRequest(res, "missing code_challenge");
    const scope = form.get("scope") orelse "mcp";

    const client = store.findClient(ctx.allocator, ctx.auth_dir, client_id) orelse return badRequest(res, "unknown client_id");
    if (!redirectUriMatches(client.redirect_uri, redirect_uri)) return badRequest(res, "redirect_uri mismatch");

    // Dynamically-registered clients have no owner email until the first
    // user signs in and approves. Claim it now so the user can revoke it
    // from /account later. Already-owned clients are left alone.
    if (client.email.len == 0) {
        store.claimClient(ctx.allocator, ctx.auth_dir, client_id, email);
    }

    const code = try store.issueCode(ctx.allocator, ctx.auth_dir, client_id, redirect_uri, email, code_challenge, scope);

    const separator: []const u8 = if (std.mem.indexOfScalar(u8, redirect_uri, '?') == null) "?" else "&";
    const location = try std.fmt.allocPrint(req.arena, "{s}{s}code={s}&state={s}", .{ redirect_uri, separator, code, state });
    res.status = 302;
    res.header("location", location);
}

/// POST /oauth/token
/// Form body: grant_type=authorization_code, code, redirect_uri, client_id,
/// client_secret, code_verifier
pub fn tokenEndpoint(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const form = try req.formData();

    const grant_type = form.get("grant_type") orelse return tokenError(req, res, ERR_INVALID_REQUEST, "missing grant_type");
    if (!std.mem.eql(u8, grant_type, "authorization_code")) {
        return tokenError(req, res, "unsupported_grant_type", "only authorization_code is supported");
    }
    const code = form.get("code") orelse return tokenError(req, res, ERR_INVALID_REQUEST, "missing code");
    const redirect_uri = form.get(KEY_REDIRECT_URI) orelse return tokenError(req, res, ERR_INVALID_REQUEST, ERR_MISSING_REDIRECT_URI);
    const client_id = form.get(KEY_CLIENT_ID) orelse return tokenError(req, res, ERR_INVALID_REQUEST, ERR_MISSING_CLIENT_ID);
    const client_secret = form.get("client_secret") orelse return tokenError(req, res, ERR_INVALID_REQUEST, "missing client_secret");
    const code_verifier = form.get("code_verifier") orelse return tokenError(req, res, ERR_INVALID_REQUEST, "missing code_verifier");

    const verified_client = try store.verifyClientSecret(ctx.allocator, ctx.auth_dir, client_id, client_secret);
    if (verified_client == null) return tokenError(req, res, "invalid_client", "bad client_id or client_secret");

    const auth_code = store.consumeCode(ctx.allocator, ctx.auth_dir, code) orelse
        return tokenError(req, res, ERR_INVALID_GRANT, "code expired or already used");
    if (!std.mem.eql(u8, auth_code.client_id, client_id)) return tokenError(req, res, ERR_INVALID_GRANT, "code was issued to a different client");
    if (!redirectUriMatches(auth_code.redirect_uri, redirect_uri)) return tokenError(req, res, ERR_INVALID_GRANT, "redirect_uri mismatch");

    const pkce_ok = try store.verifyPkce(ctx.allocator, code_verifier, auth_code.code_challenge);
    if (!pkce_ok) return tokenError(req, res, ERR_INVALID_GRANT, "PKCE verification failed");

    const access_token = try store.issueToken(ctx.allocator, ctx.auth_dir, client_id, auth_code.email, auth_code.scope);

    res.content_type = .JSON;
    res.header("cache-control", "no-store");
    res.header(HEADER_CORS_ALLOW_ORIGIN, "*");
    res.body = try std.fmt.allocPrint(
        req.arena,
        \\{{"access_token":"{s}","token_type":"Bearer","expires_in":2592000,"scope":"{s}"}}
    ,
        .{ access_token, auth_code.scope },
    );
}

/// True when `requested` matches `registered` either exactly, or both are
/// loopback URIs in which case any port is accepted (RFC 8252 §7.3 — native
/// apps can't pre-register a fixed port because the OS may have it already).
/// Both URIs must use the same scheme + host + path; only the port may
/// differ on loopback.
fn redirectUriMatches(registered: []const u8, requested: []const u8) bool {
    if (std.mem.eql(u8, registered, requested)) return true;
    const a = parseLoopbackUri(registered) orelse return false;
    const b = parseLoopbackUri(requested) orelse return false;
    return std.mem.eql(u8, a.host, b.host) and std.mem.eql(u8, a.path, b.path);
}

const LoopbackUri = struct { host: []const u8, path: []const u8 };

/// Returns host/path for `http://127.0.0.1[:port][/path]` or
/// `http://localhost[:port][/path]`. Anything else (https, other hosts,
/// missing scheme) returns null so the strict-equality fallback applies.
const HTTP_PREFIX = "http" ++ "://";

fn parseLoopbackUri(uri: []const u8) ?LoopbackUri {
    if (!std.mem.startsWith(u8, uri, HTTP_PREFIX)) return null;
    const rest = uri[HTTP_PREFIX.len..];
    // Split off the path at the first '/'.
    const path_start = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    var hostport = rest[0..path_start];
    const path = if (path_start == rest.len) "" else rest[path_start..];
    // Strip the port if present.
    if (std.mem.indexOfScalar(u8, hostport, ':')) |colon| hostport = hostport[0..colon];
    if (!std.mem.eql(u8, hostport, "127.0.0.1") and !std.mem.eql(u8, hostport, "localhost")) return null;
    return .{ .host = hostport, .path = path };
}

test "redirectUriMatches: exact" {
    try std.testing.expect(redirectUriMatches("http://x.example/cb", "http://x.example/cb"));
    try std.testing.expect(!redirectUriMatches("http://x.example/cb", "http://y.example/cb"));
}

test "redirectUriMatches: loopback flex port" {
    try std.testing.expect(redirectUriMatches("http://127.0.0.1:53682/callback", "http://127.0.0.1:9000/callback"));
    try std.testing.expect(redirectUriMatches("http://127.0.0.1/callback", "http://127.0.0.1:53682/callback"));
}

test "redirectUriMatches: loopback different paths" {
    try std.testing.expect(!redirectUriMatches("http://127.0.0.1:53682/callback", "http://127.0.0.1:53682/other"));
}

test "redirectUriMatches: localhost vs 127.0.0.1 still strict on host" {
    // RFC 8252 considers these the same host but we keep them distinct to
    // match what most OAuth servers do — apps should pick one and stick.
    try std.testing.expect(!redirectUriMatches("http://localhost:53682/callback", "http://127.0.0.1:53682/callback"));
}

fn badRequest(res: *httpz.Response, msg: []const u8) void {
    res.status = 400;
    res.content_type = .HTML;
    res.body = msg;
}

fn unauthorized(res: *httpz.Response) void {
    res.status = 401;
    res.body = "unauthorized";
}

fn tokenError(req: *httpz.Request, res: *httpz.Response, code: []const u8, desc: []const u8) void {
    res.status = 400;
    res.content_type = .JSON;
    res.body = std.fmt.allocPrint(
        req.arena,
        \\{{"error":"{s}","error_description":"{s}"}}
    ,
        .{ code, desc },
    ) catch "{\"error\":\"server_error\"}";
}
