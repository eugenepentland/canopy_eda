const std = @import("std");
const httpz = @import("httpz");

const server_mod = @import("../serve.zig");
const Handler = server_mod.Handler;
const auth = @import("auth.zig");
const store = @import("oauth_store.zig");
const users = @import("users.zig");

// ── Constants ─────────────────────────────────────────────────────
const ERR_EXPECTED_OBJECT = "expected object";
const ERR_INVALID_JSON = "invalid json";
const ERR_MISSING_BODY = "missing body";
const OK_JSON_TRUE = "{\"ok\":true}";

/// Error set for HTTP handlers in this module. Wide enough to absorb
/// the file-IO and form-parsing errors propagated by every helper called
/// from the bodies via `try`.
pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error ||
    std.fs.File.WriteError || std.fs.File.OpenError || std.fs.File.ReadError ||
    std.fs.Dir.MakeError || std.fs.Dir.StatFileError ||
    error{ LastAdmin, CannotDeleteSelf, FileTooBig, StreamTooLong, EndOfStream, InvalidEscapeSequence };

fn currentEmail(ctx: *Handler, req: *httpz.Request) ?[]const u8 {
    return auth.currentEmail(ctx, req);
}

/// GET /account
/// Unified account page: passkeys, invite link, and OAuth clients for MCP.
pub fn accountPage(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const email = currentEmail(ctx, req) orelse {
        res.status = 303;
        res.header("location", "/auth/login");
        return;
    };

    const clients = try store.listClientsByEmail(ctx.allocator, ctx.project_dir, email);
    defer ctx.allocator.free(clients);

    const current_role = users.getRole(ctx.allocator, ctx.project_dir, email);
    const is_admin = current_role.canAdmin();

    const user_list: []users.User = if (is_admin)
        try users.listUsers(ctx.allocator, ctx.project_dir)
    else
        &[_]users.User{};
    defer if (is_admin) ctx.allocator.free(user_list);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(req.arena);
    try w.writeAll("<!DOCTYPE html><html><head><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">");
    try w.writeAll("<title>Account — Canopy EDA</title><style>");
    try w.writeAll(auth.PAGE_STYLE);
    try w.writeAll(ACCOUNT_PAGE_CSS);
    try w.writeAll("</style></head><body><div class=\"wrap\">");

    try w.writeAll("<div class=\"user-bar\"><span class=\"email\"><a href=\"/\">← Designs</a> · Signed in as ");
    try w.writeAll(email);
    try w.print(" <span class=\"role-pill role-{s}\">{s}</span>", .{ current_role.toString(), current_role.toString() });
    try w.writeAll("</span><button id=\"logout-btn\">Sign out</button></div>");
    try w.writeAll("<h1 style=\"margin-bottom:1.5rem\">Account</h1>");

    // ── Passkeys card ──
    try w.writeAll(
        \\<div class="card"><h2>Passkeys</h2>
        \\<p class="muted">Devices that can sign in to this account.</p>
        \\<div id="passkey-list"></div>
        \\<button class="btn-primary" id="add-passkey-btn" style="margin-top:8px">Add passkey on this device</button>
        \\</div>
    );

    // ── Invite card (admin only) ──
    if (is_admin) {
        try w.writeAll(
            \\<div class="card"><h2>Invite</h2>
            \\<p class="muted">Generate a one-time link (valid 7 days). The role is assigned to whoever registers through the link.</p>
            \\<label>Role</label>
            \\<select id="invite-role">
            \\  <option value="writer" selected>writer (can edit)</option>
            \\  <option value="reader">reader (view only)</option>
            \\  <option value="admin">admin</option>
            \\</select>
            \\<div style="margin-top:10px"><button id="invite-btn">Create invite link</button></div>
            \\<div id="invite-out"></div>
            \\</div>
        );
    }

    // ── Users card (admin only) ──
    if (is_admin) {
        try w.writeAll(USERS_CARD_HEAD);
        for (user_list) |u| {
            try w.writeAll("<tr><td>");
            try w.writeAll(u.email);
            try w.writeAll("</td><td>");
            if (std.mem.eql(u8, u.email, email)) {
                try w.print("<span class=\"role-pill role-{s}\">{s}</span> <span class=\"muted\">(you)</span>", .{ u.role.toString(), u.role.toString() });
            } else {
                try w.print("<select onchange=\"updateRole(this,'{s}')\">", .{u.email});
                inline for ([_][]const u8{ "admin", "writer", "reader" }) |r| {
                    const selected = if (std.mem.eql(u8, r, u.role.toString())) " selected" else "";
                    try w.print("<option value=\"{s}\"{s}>{s}</option>", .{ r, selected, r });
                }
                try w.writeAll("</select>");
            }
            try w.print("</td><td class=\"muted\"><span data-ts=\"{d}\"></span></td><td>", .{u.created_at});
            if (!std.mem.eql(u8, u.email, email)) {
                try w.print("<button class=\"btn-danger\" onclick=\"deleteUser('{s}')\">Delete</button>", .{u.email});
            }
            try w.writeAll("</td></tr>");
        }
        try w.writeAll("</table></div>");
    }

    // ── OAuth clients card ──
    try w.writeAll(
        \\<div class="card"><h2>MCP OAuth Clients</h2>
        \\<p class="muted">Register a Claude Code / Claude.ai MCP client. Each client gets credentials you paste into the remote-MCP connector.</p>
    );
    if (clients.len == 0) {
        try w.writeAll("<p class=\"muted\">No clients yet — create one below.</p>");
    } else {
        try w.writeAll("<table><tr><th>Name</th><th>Client ID</th><th>Redirect URI</th><th></th></tr>");
        for (clients) |c| {
            try w.writeAll("<tr><td>");
            try w.writeAll(c.name);
            try w.writeAll("</td><td><code>");
            try w.writeAll(c.id);
            try w.writeAll("</code></td><td><code>");
            try w.writeAll(c.redirect_uri);
            try w.writeAll("</code></td><td>");
            try w.print("<button class=\"btn-danger\" onclick=\"revokeClient('{s}')\">Revoke</button>", .{c.id});
            try w.writeAll("</td></tr>");
        }
        try w.writeAll("</table>");
    }
    try w.writeAll(CLIENT_CREATE_FORM);

    try w.writeAll("<script>");
    try w.writeAll(auth.B64URL_JS);
    try w.writeAll(ACCOUNT_PAGE_JS);
    try w.writeAll("</script></div></body></html>");

    res.content_type = .HTML;
    res.body = buf.items;
}

/// POST /api/oauth/clients
/// Body: {"name":"...","redirect_uri":"..."}
pub fn createClientApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const email = currentEmail(ctx, req) orelse {
        res.status = 401;
        res.body = "sign in required";
        return;
    };
    const body = req.body() orelse {
        res.status = 400;
        res.body = ERR_MISSING_BODY;
        return;
    };

    const parsed = std.json.parseFromSlice(std.json.Value, req.arena, body, .{}) catch {
        res.status = 400;
        res.body = ERR_INVALID_JSON;
        return;
    };
    if (parsed.value != .object) {
        res.status = 400;
        res.body = ERR_EXPECTED_OBJECT;
        return;
    }
    const name = if (parsed.value.object.get("name")) |v| (if (v == .string) v.string else "") else "";
    const redirect_uri = if (parsed.value.object.get("redirect_uri")) |v| (if (v == .string) v.string else "") else "";
    if (name.len == 0 or redirect_uri.len == 0) {
        res.status = 400;
        res.body = "name and redirect_uri are required";
        return;
    }

    const r = try store.createClient(ctx.allocator, ctx.project_dir, name, email, redirect_uri);
    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(
        req.arena,
        \\{{"client_id":"{s}","client_secret":"{s}"}}
    ,
        .{ r.id, r.secret },
    );
}

/// POST /api/oauth/clients/:id/revoke
pub fn revokeClientApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const email = currentEmail(ctx, req) orelse {
        res.status = 401;
        res.body = "sign in required";
        return;
    };
    const id = req.param("id") orelse {
        res.status = 400;
        res.body = "missing id";
        return;
    };
    const ok = store.revokeClient(ctx.allocator, ctx.project_dir, id, email);
    if (!ok) {
        res.status = 404;
        res.body = "client not found";
        return;
    }
    res.content_type = .JSON;
    res.body = OK_JSON_TRUE;
}

/// GET /auth/manage — legacy redirect to /account.
pub fn manageRedirect(_: *Handler, _: *httpz.Request, res: *httpz.Response) HandlerError!void {
    res.status = 303;
    res.header("location", "/account");
}

fn requireAdmin(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) ?[]const u8 {
    const email = currentEmail(ctx, req) orelse {
        res.status = 401;
        res.content_type = .JSON;
        res.body = "{\"error\":\"sign in required\"}";
        return null;
    };
    if (!users.getRole(ctx.allocator, ctx.project_dir, email).canAdmin()) {
        res.status = 403;
        res.content_type = .JSON;
        res.body = "{\"error\":\"admin role required\"}";
        return null;
    }
    return email;
}

/// POST /api/users/role
/// Body: {"email":"target@example.com","role":"admin"|"writer"|"reader"}
pub fn updateUserRoleApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const actor = requireAdmin(ctx, req, res) orelse return;
    const body = req.body() orelse {
        res.status = 400;
        res.body = ERR_MISSING_BODY;
        return;
    };
    const parsed = std.json.parseFromSlice(std.json.Value, req.arena, body, .{}) catch {
        res.status = 400;
        res.body = ERR_INVALID_JSON;
        return;
    };
    if (parsed.value != .object) {
        res.status = 400;
        res.body = ERR_EXPECTED_OBJECT;
        return;
    }
    const target = if (parsed.value.object.get("email")) |v| (if (v == .string) v.string else "") else "";
    if (target.len == 0) {
        res.status = 400;
        res.body = "missing email";
        return;
    }
    const role_raw = if (parsed.value.object.get("role")) |v| (if (v == .string) v.string else "") else "";
    const new_role = users.Role.fromString(role_raw) orelse {
        res.status = 400;
        res.body = "unknown role";
        return;
    };

    const ok = users.setRole(ctx.allocator, ctx.project_dir, target, new_role, actor) catch |err| {
        if (err == error.LastAdmin) {
            res.status = 409;
            res.content_type = .JSON;
            res.body = "{\"error\":\"cannot demote the last admin\"}";
            return;
        }
        return err;
    };
    if (!ok) {
        res.status = 404;
        res.body = "user not found";
        return;
    }
    res.content_type = .JSON;
    res.body = OK_JSON_TRUE;
}

/// POST /api/users/delete
/// Body: {"email":"target@example.com"}
/// Removes the user record, revokes all their OAuth clients, deletes their
/// passkeys, and drops their sessions. Admin-only. Cannot delete yourself or
/// the last admin.
pub fn deleteUserApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const actor = requireAdmin(ctx, req, res) orelse return;
    const body = req.body() orelse {
        res.status = 400;
        res.body = ERR_MISSING_BODY;
        return;
    };
    const parsed = std.json.parseFromSlice(std.json.Value, req.arena, body, .{}) catch {
        res.status = 400;
        res.body = ERR_INVALID_JSON;
        return;
    };
    if (parsed.value != .object) {
        res.status = 400;
        res.body = ERR_EXPECTED_OBJECT;
        return;
    }
    const target = if (parsed.value.object.get("email")) |v| (if (v == .string) v.string else "") else "";
    if (target.len == 0) {
        res.status = 400;
        res.body = "missing email";
        return;
    }

    const ok = users.deleteUser(ctx.allocator, ctx.project_dir, target, actor) catch |err| {
        res.status = 409;
        res.content_type = .JSON;
        res.body = switch (err) {
            error.CannotDeleteSelf => "{\"error\":\"you cannot delete your own account\"}",
            error.LastAdmin => "{\"error\":\"cannot delete the last admin\"}",
            else => return err,
        };
        return;
    };
    if (!ok) {
        res.status = 404;
        res.body = "user not found";
        return;
    }

    // Cascade: revoke OAuth clients, drop passkeys + sessions.
    store.revokeAllClientsForEmail(ctx.allocator, ctx.project_dir, target);
    auth.purgeIdentity(ctx.allocator, ctx.project_dir, target);

    res.content_type = .JSON;
    res.body = OK_JSON_TRUE;
}

const ACCOUNT_PAGE_CSS = @embedFile("assets/account_page.css");
const ACCOUNT_PAGE_JS = @embedFile("assets/account_page.js");

const USERS_CARD_HEAD =
    \\<div class="card"><h2>Users</h2>
    \\<p class="muted">Every user registered on this server.
    \\Admins can change roles or remove users
    \\(which revokes their passkeys, sessions, and OAuth clients).</p>
    \\<table><tr><th>Email</th><th>Role</th><th>Joined</th><th></th></tr>
;

const CLIENT_CREATE_FORM =
    \\<h3 style="margin-top:18px;font-size:0.95rem;color:#f0f6fc">Create new client</h3>
    \\<form onsubmit="return createClient(event)">
    \\<label>Name (for your reference)</label>
    \\<input type="text" id="client-name" placeholder="e.g. My laptop — Claude Code" required>
    \\<label>Redirect URI (must match your MCP client's OAuth callback exactly)</label>
    \\<input type="text" id="client-redirect"
    \\ value="https://claude.ai/api/mcp/auth_callback" required>
    \\<p class="muted" style="margin-bottom:8px">Common values:
    \\ <code>https://claude.ai/api/mcp/auth_callback</code> (Claude.ai web),
    \\ <code>http://localhost:8080/callback</code> (Claude Code CLI default).</p>
    \\<button type="submit" class="btn-primary">Create client</button>
    \\</form>
    \\<div id="client-secret-output"></div>
    \\</div>
    \\<div class="status" id="status"></div>
;
