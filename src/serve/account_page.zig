const std = @import("std");
const httpz = @import("httpz");

const server_mod = @import("../serve.zig");
const Handler = server_mod.Handler;
const auth = @import("auth.zig");
const store = @import("oauth_store.zig");
const users = @import("users.zig");

fn currentEmail(ctx: *Handler, req: *httpz.Request) ?[]const u8 {
    return auth.currentEmail(ctx, req);
}

/// GET /account
/// Unified account page: passkeys, invite link, and OAuth clients for MCP.
pub fn accountPage(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
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
    try w.writeAll(
        \\body{display:block;align-items:initial;justify-content:initial;padding:40px 16px}
        \\.wrap{max-width:760px;margin:0 auto}
        \\h1,h2{color:#f0f6fc}
        \\h2{font-size:1.1rem;margin:0 0 10px 0}
        \\.card{background:#161b22;border:1px solid #30363d;border-radius:8px;padding:20px 24px;margin-bottom:20px}
        \\.user-bar{display:flex;justify-content:space-between;align-items:center;margin-bottom:1rem}
        \\.user-bar .email{color:#8b949e;font-size:0.85rem}
        \\table{width:100%;border-collapse:collapse;font-size:14px;margin-bottom:12px}
        \\th,td{text-align:left;padding:8px 10px;border-bottom:1px solid #21262d;vertical-align:top}
        \\th{color:#8b949e;font-weight:500;font-size:12px;text-transform:uppercase;letter-spacing:0.05em}
        \\code{font-family:ui-monospace,monospace;font-size:12px;background:#0d1117;padding:2px 6px;border-radius:4px}
        \\input[type=text]{width:100%;box-sizing:border-box;padding:8px 10px;background:#0d1117;border:1px solid #30363d;border-radius:6px;color:#c9d1d9;font-size:14px;margin-bottom:12px;font-family:inherit}
        \\label{display:block;color:#8b949e;font-size:0.85rem;margin-bottom:4px}
        \\button{cursor:pointer;border-radius:6px;padding:8px 16px;font-size:14px;border:1px solid #30363d;background:#21262d;color:#c9d1d9;font-family:inherit}
        \\button:hover{background:#2d333b}
        \\.btn-primary{background:#238636;border-color:#2ea043;color:white}
        \\.btn-primary:hover{background:#2ea043}
        \\.btn-danger{background:#21262d;color:#f85149}
        \\.muted{color:#8b949e;font-size:13px}
        \\.secret-box{background:#0d1117;border:1px solid #d29922;border-radius:6px;padding:12px;margin-top:12px;font-family:ui-monospace,monospace;font-size:12px;word-break:break-all}
        \\.warn{color:#d29922;font-size:13px;margin-top:4px}
        \\.row{display:flex;justify-content:space-between;align-items:center;padding:10px 12px;border:1px solid #21262d;border-radius:6px;margin-bottom:8px}
        \\.row .meta{color:#8b949e;font-size:0.85rem}
        \\.invite-box{background:#0d1117;border:1px solid #30363d;border-radius:6px;padding:10px;margin-top:8px;font-size:0.8rem;word-break:break-all}
        \\.role-pill{display:inline-block;padding:1px 8px;border-radius:10px;font-size:11px;text-transform:uppercase;letter-spacing:0.04em;margin-left:6px;border:1px solid transparent}
        \\.role-admin{background:#3c2d00;color:#d29922;border-color:#5c4500}
        \\.role-writer{background:#0d2f1a;color:#3fb950;border-color:#174d2a}
        \\.role-reader{background:#1a2637;color:#58a6ff;border-color:#24456a}
        \\select{background:#0d1117;border:1px solid #30363d;border-radius:6px;color:#c9d1d9;font-size:13px;padding:5px 8px;font-family:inherit}
        \\a{color:#58a6ff;text-decoration:none}
        \\a:hover{text-decoration:underline}
        \\.status{margin-top:0.5rem;font-size:0.85rem;min-height:1.2em}
        \\.status.error{color:#f85149}
        \\.status.ok{color:#3fb950}
        \\
    );
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
        try w.writeAll(
            \\<div class="card"><h2>Users</h2>
            \\<p class="muted">Every user registered on this server. Admins can change roles or remove users (which revokes their passkeys, sessions, and OAuth clients).</p>
            \\<table><tr><th>Email</th><th>Role</th><th>Joined</th><th></th></tr>
        );
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
    try w.writeAll(
        \\<h3 style="margin-top:18px;font-size:0.95rem;color:#f0f6fc">Create new client</h3>
        \\<form onsubmit="return createClient(event)">
        \\<label>Name (for your reference)</label>
        \\<input type="text" id="client-name" placeholder="e.g. My laptop — Claude Code" required>
        \\<label>Redirect URI (must match your MCP client's OAuth callback exactly)</label>
        \\<input type="text" id="client-redirect" value="https://claude.ai/api/mcp/auth_callback" required>
        \\<p class="muted" style="margin-bottom:8px">Common values: <code>https://claude.ai/api/mcp/auth_callback</code> (Claude.ai web), <code>http://localhost:8080/callback</code> (Claude Code CLI default).</p>
        \\<button type="submit" class="btn-primary">Create client</button>
        \\</form>
        \\<div id="client-secret-output"></div>
        \\</div>
        \\<div class="status" id="status"></div>
    );

    try w.writeAll("<script>");
    try w.writeAll(auth.B64URL_JS);
    try w.writeAll(
        \\const status = document.getElementById('status');
        \\function fmtDate(ts){if(!ts)return 'Unknown';return new Date(ts*1000).toLocaleString()}
        \\async function refreshPasskeys(){
        \\  const r = await fetch('/auth/credentials/list');
        \\  if (!r.ok) return; // probably not logged in with a real session
        \\  const data = await r.json();
        \\  const list = document.getElementById('passkey-list');
        \\  list.innerHTML = '';
        \\  for (const c of data.credentials) {
        \\    const row = document.createElement('div'); row.className = 'row';
        \\    const meta = document.createElement('div');
        \\    const title = document.createElement('div'); title.textContent = 'Passkey';
        \\    const added = document.createElement('div'); added.className = 'meta'; added.textContent = 'Added ' + fmtDate(c.created_at);
        \\    meta.appendChild(title); meta.appendChild(added);
        \\    const btn = document.createElement('button'); btn.className='btn-danger'; btn.textContent = 'Delete';
        \\    btn.onclick = async () => {
        \\      if (data.credentials.length <= 1) { status.className='status error'; status.textContent='Cannot delete your only passkey. Add another first.'; return; }
        \\      if (!confirm('Delete this passkey?')) return;
        \\      const rr = await fetch('/auth/credentials/delete', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({id:c.id})});
        \\      const j = await rr.json();
        \\      if (j.ok) refreshPasskeys(); else { status.className='status error'; status.textContent = j.error || 'Delete failed'; }
        \\    };
        \\    row.appendChild(meta); row.appendChild(btn); list.appendChild(row);
        \\  }
        \\  if (data.credentials.length === 0) list.innerHTML = '<p class="muted">No passkeys yet.</p>';
        \\}
        \\document.getElementById('logout-btn').onclick = async () => {
        \\  await fetch('/auth/logout', {method:'POST'}); window.location.href = '/auth/login';
        \\};
        \\document.getElementById('add-passkey-btn').onclick = async () => {
        \\  status.className = 'status'; status.textContent = 'Requesting challenge...';
        \\  try {
        \\    const cr = await fetch('/auth/register/challenge');
        \\    const opts = await cr.json();
        \\    if (!cr.ok) throw new Error(opts.error || 'Challenge failed');
        \\    const publicKey = {
        \\      challenge: b64urlToBytes(opts.challenge), rp: opts.rp,
        \\      user: { id: b64urlToBytes(opts.user.id), name: opts.user.name, displayName: opts.user.displayName },
        \\      pubKeyCredParams: opts.pubKeyCredParams,
        \\      authenticatorSelection: opts.authenticatorSelection, timeout: opts.timeout,
        \\      excludeCredentials: (opts.excludeCredentials || []).map(c => ({type:c.type, id:b64urlToBytes(c.id)}))
        \\    };
        \\    status.textContent = 'Waiting for passkey...';
        \\    const cred = await navigator.credentials.create({publicKey});
        \\    const body = JSON.stringify({id: bytesToB64url(cred.rawId), response:{attestationObject: bytesToB64url(cred.response.attestationObject), clientDataJSON: bytesToB64url(cred.response.clientDataJSON)}});
        \\    const vr = await fetch('/auth/register/complete', {method:'POST', headers:{'Content-Type':'application/json'}, body});
        \\    const result = await vr.json();
        \\    if (result.ok) { status.className='status ok'; status.textContent='Passkey added.'; refreshPasskeys(); }
        \\    else { status.className='status error'; status.textContent = result.error || 'Registration failed'; }
        \\  } catch (e) { status.className='status error'; status.textContent = e.message || 'Registration failed'; }
        \\};
        \\const inviteBtn = document.getElementById('invite-btn');
        \\if (inviteBtn) inviteBtn.onclick = async () => {
        \\  const role = document.getElementById('invite-role').value;
        \\  const r = await fetch('/auth/invite/create', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({role})});
        \\  const j = await r.json();
        \\  if (j.ok) {
        \\    const fullUrl = window.location.origin + j.path;
        \\    const out = document.getElementById('invite-out');
        \\    out.innerHTML = '<div class="invite-box">' + fullUrl + '</div><div class="muted" style="margin-top:6px">Role: <strong>' + j.role + '</strong>. Valid for 7 days. One-time use.</div>';
        \\  } else { status.className='status error'; status.textContent = j.error || 'Failed to create invite'; }
        \\};
        \\async function updateRole(sel, targetEmail) {
        \\  const role = sel.value;
        \\  const r = await fetch('/api/users/role', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({email: targetEmail, role})});
        \\  if (!r.ok) { status.className='status error'; status.textContent = (await r.text()) || 'Update failed'; return; }
        \\  status.className='status ok'; status.textContent = targetEmail + ' → ' + role;
        \\}
        \\async function deleteUser(targetEmail) {
        \\  if (!confirm('Delete ' + targetEmail + '?\nThis removes their passkeys, sessions, and OAuth clients. This cannot be undone.')) return;
        \\  const r = await fetch('/api/users/delete', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({email: targetEmail})});
        \\  if (r.ok) { location.reload(); return; }
        \\  let msg;
        \\  try { msg = (await r.json()).error; } catch(e) { msg = await r.text(); }
        \\  status.className='status error'; status.textContent = msg || 'Delete failed';
        \\}
        \\document.querySelectorAll('span[data-ts]').forEach(el => {
        \\  const ts = parseInt(el.dataset.ts, 10);
        \\  if (ts) el.textContent = new Date(ts * 1000).toLocaleString();
        \\});
        \\async function createClient(ev) {
        \\  ev.preventDefault();
        \\  const name = document.getElementById('client-name').value;
        \\  const redirect_uri = document.getElementById('client-redirect').value;
        \\  const r = await fetch('/api/oauth/clients', {method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({name, redirect_uri})});
        \\  if (!r.ok) { alert('Failed: ' + await r.text()); return false; }
        \\  const d = await r.json();
        \\  const out = document.getElementById('client-secret-output');
        \\  out.innerHTML = '<div class="secret-box"><strong>Client ID:</strong><br>' + d.client_id +
        \\    '<br><br><strong>Client Secret:</strong><br>' + d.client_secret +
        \\    '</div><div class="warn">⚠ This is the only time the secret is shown. Copy it now.</div>' +
        \\    '<p><a href="/account">Reload page</a> to see the new client in the table.</p>';
        \\  return false;
        \\}
        \\async function revokeClient(id) {
        \\  if (!confirm('Revoke client ' + id + '? Tokens issued to it stop working immediately.')) return;
        \\  const r = await fetch('/api/oauth/clients/' + encodeURIComponent(id) + '/revoke', {method:'POST'});
        \\  if (r.ok) location.reload(); else alert('Failed: ' + await r.text());
        \\}
        \\refreshPasskeys();
    );
    try w.writeAll("</script></div></body></html>");

    res.content_type = .HTML;
    res.body = buf.items;
}

/// POST /api/oauth/clients
/// Body: {"name":"...","redirect_uri":"..."}
pub fn createClientApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const email = currentEmail(ctx, req) orelse {
        res.status = 401;
        res.body = "sign in required";
        return;
    };
    const body = req.body() orelse {
        res.status = 400;
        res.body = "missing body";
        return;
    };

    const parsed = std.json.parseFromSlice(std.json.Value, req.arena, body, .{}) catch {
        res.status = 400;
        res.body = "invalid json";
        return;
    };
    if (parsed.value != .object) {
        res.status = 400;
        res.body = "expected object";
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
pub fn revokeClientApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
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
    res.body = "{\"ok\":true}";
}

/// GET /auth/manage — legacy redirect to /account.
pub fn manageRedirect(_: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
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
pub fn updateUserRoleApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const actor = requireAdmin(ctx, req, res) orelse return;
    const body = req.body() orelse {
        res.status = 400;
        res.body = "missing body";
        return;
    };
    const parsed = std.json.parseFromSlice(std.json.Value, req.arena, body, .{}) catch {
        res.status = 400;
        res.body = "invalid json";
        return;
    };
    if (parsed.value != .object) {
        res.status = 400;
        res.body = "expected object";
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
    res.body = "{\"ok\":true}";
}

/// POST /api/users/delete
/// Body: {"email":"target@example.com"}
/// Removes the user record, revokes all their OAuth clients, deletes their
/// passkeys, and drops their sessions. Admin-only. Cannot delete yourself or
/// the last admin.
pub fn deleteUserApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) !void {
    const actor = requireAdmin(ctx, req, res) orelse return;
    const body = req.body() orelse {
        res.status = 400;
        res.body = "missing body";
        return;
    };
    const parsed = std.json.parseFromSlice(std.json.Value, req.arena, body, .{}) catch {
        res.status = 400;
        res.body = "invalid json";
        return;
    };
    if (parsed.value != .object) {
        res.status = 400;
        res.body = "expected object";
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
    res.body = "{\"ok\":true}";
}
