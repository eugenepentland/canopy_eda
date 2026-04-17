const std = @import("std");
const httpz = @import("httpz");

const server_mod = @import("../serve.zig");
const Handler = server_mod.Handler;
const auth = @import("auth.zig");
const store = @import("oauth_store.zig");

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

pub fn metadataProtectedResource(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const base = try requestUrl(ctx, req);
    defer ctx.allocator.free(base);
    res.content_type = .JSON;
    res.header("access-control-allow-origin", "*");
    res.body = try std.fmt.allocPrint(
        req.arena,
        \\{{"resource":"{s}","authorization_servers":["{s}"],"scopes_supported":["mcp"],"bearer_methods_supported":["header"]}}
    ,
        .{ base, base },
    );
}

pub fn metadataAuthServer(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const base = try requestUrl(ctx, req);
    defer ctx.allocator.free(base);
    res.content_type = .JSON;
    res.header("access-control-allow-origin", "*");
    res.body = try std.fmt.allocPrint(
        req.arena,
        \\{{"issuer":"{s}","authorization_endpoint":"{s}/oauth/authorize","token_endpoint":"{s}/oauth/token","response_types_supported":["code"],"grant_types_supported":["authorization_code"],"code_challenge_methods_supported":["S256"],"token_endpoint_auth_methods_supported":["client_secret_post"],"scopes_supported":["mcp"]}}
    ,
        .{ base, base, base },
    );
}

/// GET /oauth/authorize
/// Query params: response_type=code, client_id, redirect_uri, scope, state,
/// code_challenge, code_challenge_method=S256.
///
/// If signed in, render a consent page. If not, render a "please sign in" page
/// with a link to /auth/login.
pub fn authorizePage(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const q = try req.query();
    const client_id = q.get("client_id") orelse return badRequest(res, "missing client_id");
    const redirect_uri = q.get("redirect_uri") orelse return badRequest(res, "missing redirect_uri");
    const response_type = q.get("response_type") orelse "";
    const state = q.get("state") orelse "";
    const code_challenge = q.get("code_challenge") orelse "";
    const code_challenge_method = q.get("code_challenge_method") orelse "";
    const scope = q.get("scope") orelse "mcp";

    if (!std.mem.eql(u8, response_type, "code")) return badRequest(res, "response_type must be \"code\"");
    if (code_challenge.len == 0) return badRequest(res, "missing code_challenge (PKCE required)");
    if (!std.mem.eql(u8, code_challenge_method, "S256")) return badRequest(res, "code_challenge_method must be \"S256\"");

    const client = store.findClient(ctx.allocator, ctx.project_dir, client_id) orelse return badRequest(res, "unknown client_id");
    if (!std.mem.eql(u8, client.redirect_uri, redirect_uri)) {
        return badRequest(res, "redirect_uri does not match registered URI");
    }

    const signed_in_email: ?[]const u8 = auth.currentEmail(ctx, req);

    res.content_type = .HTML;
    if (signed_in_email == null) {
        res.body = try std.fmt.allocPrint(req.arena,
            \\<!DOCTYPE html><html><head><title>Authorize — Canopy EDA</title>
            \\<style>body{{font-family:system-ui,sans-serif;background:#0d1117;color:#c9d1d9;max-width:520px;margin:80px auto;padding:24px;line-height:1.5}}a{{color:#58a6ff}}.card{{background:#161b22;border:1px solid #30363d;border-radius:8px;padding:20px 24px}}</style>
            \\</head><body><div class="card"><h1>Sign in required</h1>
            \\<p>The MCP client <strong>{s}</strong> wants to access this server on your behalf.</p>
            \\<p>Please <a href="/auth/login">sign in</a>, then re-open this page to continue.</p>
            \\</div></body></html>
        , .{client.name});
        return;
    }

    const email = signed_in_email.?;
    // Render consent page. All authorize params are echoed as hidden inputs so
    // the POST /oauth/authorize/approve has everything it needs.
    res.body = try std.fmt.allocPrint(req.arena,
        \\<!DOCTYPE html><html><head><title>Authorize {s} — Canopy EDA</title>
        \\<style>body{{font-family:system-ui,sans-serif;background:#0d1117;color:#c9d1d9;max-width:560px;margin:80px auto;padding:24px;line-height:1.5}}.card{{background:#161b22;border:1px solid #30363d;border-radius:8px;padding:20px 24px}}button{{cursor:pointer;border-radius:6px;padding:10px 18px;font-size:14px;border:1px solid #30363d;margin-right:8px}}.btn-primary{{background:#238636;color:white;border-color:#2ea043}}.btn-deny{{background:#21262d;color:#c9d1d9}}.muted{{color:#8b949e;font-size:13px}}</style>
        \\</head><body><div class="card">
        \\<h1>Authorize access</h1>
        \\<p><strong>{s}</strong> wants permission to read and modify your designs on this server.</p>
        \\<p class="muted">Signed in as <strong>{s}</strong> · scope: <code>{s}</code></p>
        \\<form method="POST" action="/oauth/authorize/approve">
        \\<input type="hidden" name="client_id" value="{s}">
        \\<input type="hidden" name="redirect_uri" value="{s}">
        \\<input type="hidden" name="state" value="{s}">
        \\<input type="hidden" name="code_challenge" value="{s}">
        \\<input type="hidden" name="scope" value="{s}">
        \\<button type="submit" class="btn-primary">Authorize</button>
        \\<a href="/"><button type="button" class="btn-deny">Cancel</button></a>
        \\</form>
        \\</div></body></html>
    , .{ client.name, client.name, email, scope, client_id, redirect_uri, state, code_challenge, scope });
}

/// POST /oauth/authorize/approve
/// User has clicked "Authorize" on the consent page. Re-validate everything,
/// mint an auth code, and 302-redirect to the client's redirect_uri.
pub fn authorizeApprove(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const email = auth.currentEmail(ctx, req) orelse return unauthorized(res);

    const form = try req.formData();
    const client_id = form.get("client_id") orelse return badRequest(res, "missing client_id");
    const redirect_uri = form.get("redirect_uri") orelse return badRequest(res, "missing redirect_uri");
    const state = form.get("state") orelse "";
    const code_challenge = form.get("code_challenge") orelse return badRequest(res, "missing code_challenge");
    const scope = form.get("scope") orelse "mcp";

    const client = store.findClient(ctx.allocator, ctx.project_dir, client_id) orelse return badRequest(res, "unknown client_id");
    if (!std.mem.eql(u8, client.redirect_uri, redirect_uri)) return badRequest(res, "redirect_uri mismatch");

    const code = try store.issueCode(ctx.allocator, ctx.project_dir, client_id, redirect_uri, email, code_challenge, scope);

    const separator: []const u8 = if (std.mem.indexOfScalar(u8, redirect_uri, '?') == null) "?" else "&";
    const location = try std.fmt.allocPrint(req.arena, "{s}{s}code={s}&state={s}", .{ redirect_uri, separator, code, state });
    res.status = 302;
    res.header("location", location);
}

/// POST /oauth/token
/// Form body: grant_type=authorization_code, code, redirect_uri, client_id,
/// client_secret, code_verifier
pub fn tokenEndpoint(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const form = try req.formData();

    const grant_type = form.get("grant_type") orelse return tokenError(req, res, "invalid_request", "missing grant_type");
    if (!std.mem.eql(u8, grant_type, "authorization_code")) {
        return tokenError(req, res, "unsupported_grant_type", "only authorization_code is supported");
    }
    const code = form.get("code") orelse return tokenError(req, res, "invalid_request", "missing code");
    const redirect_uri = form.get("redirect_uri") orelse return tokenError(req, res, "invalid_request", "missing redirect_uri");
    const client_id = form.get("client_id") orelse return tokenError(req, res, "invalid_request", "missing client_id");
    const client_secret = form.get("client_secret") orelse return tokenError(req, res, "invalid_request", "missing client_secret");
    const code_verifier = form.get("code_verifier") orelse return tokenError(req, res, "invalid_request", "missing code_verifier");

    const verified_client = try store.verifyClientSecret(ctx.allocator, ctx.project_dir, client_id, client_secret);
    if (verified_client == null) return tokenError(req, res, "invalid_client", "bad client_id or client_secret");

    const auth_code = store.consumeCode(ctx.allocator, ctx.project_dir, code) orelse return tokenError(req, res, "invalid_grant", "code expired or already used");
    if (!std.mem.eql(u8, auth_code.client_id, client_id)) return tokenError(req, res, "invalid_grant", "code was issued to a different client");
    if (!std.mem.eql(u8, auth_code.redirect_uri, redirect_uri)) return tokenError(req, res, "invalid_grant", "redirect_uri mismatch");

    const pkce_ok = try store.verifyPkce(ctx.allocator, code_verifier, auth_code.code_challenge);
    if (!pkce_ok) return tokenError(req, res, "invalid_grant", "PKCE verification failed");

    const access_token = try store.issueToken(ctx.allocator, ctx.project_dir, client_id, auth_code.email, auth_code.scope);

    res.content_type = .JSON;
    res.header("cache-control", "no-store");
    res.header("access-control-allow-origin", "*");
    res.body = try std.fmt.allocPrint(
        req.arena,
        \\{{"access_token":"{s}","token_type":"Bearer","expires_in":2592000,"scope":"{s}"}}
    ,
        .{ access_token, auth_code.scope },
    );
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
