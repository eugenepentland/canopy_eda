const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Client = struct {
    id: []const u8,
    secret_hash: []const u8,
    name: []const u8,
    email: []const u8,
    redirect_uri: []const u8,
    created_at: i64,
    revoked: bool = false,
};

pub const AuthCode = struct {
    code: []const u8,
    client_id: []const u8,
    redirect_uri: []const u8,
    email: []const u8,
    code_challenge: []const u8,
    scope: []const u8,
    expires_at: i64,
};

pub const Token = struct {
    hash: []const u8,
    client_id: []const u8,
    email: []const u8,
    scope: []const u8,
    expires_at: i64,
};

// ── Global state (lazy init, matches auth.zig pattern) ──────────────────

var mu = std.Thread.Mutex{};
var clients_list: std.ArrayListUnmanaged(Client) = .empty;
var tokens_list: std.ArrayListUnmanaged(Token) = .empty;
var codes_map: ?std.StringHashMap(AuthCode) = null;
var loaded_project_dir: ?[]const u8 = null;

fn ensureLoaded(allocator: std.mem.Allocator, project_dir: []const u8) void {
    if (loaded_project_dir) |d| {
        if (std.mem.eql(u8, d, project_dir)) return;
    }
    loaded_project_dir = project_dir;
    loadClients(allocator, project_dir);
    loadTokens(allocator, project_dir);
    if (codes_map == null) codes_map = std.StringHashMap(AuthCode).init(allocator);
}

fn clientsPath(allocator: std.mem.Allocator, project_dir: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/auth/oauth_clients.json", .{project_dir});
}

fn tokensPath(allocator: std.mem.Allocator, project_dir: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/auth/oauth_tokens.json", .{project_dir});
}

fn ensureAuthDir(project_dir: []const u8) void {
    var buf: [512]u8 = undefined;
    const dir = std.fmt.bufPrint(&buf, "{s}/auth", .{project_dir}) catch return;
    std.fs.cwd().makePath(dir) catch {};
}

fn loadClients(allocator: std.mem.Allocator, project_dir: []const u8) void {
    const path = clientsPath(allocator, project_dir) catch return;
    defer allocator.free(path);
    const data = std.fs.cwd().readFileAlloc(allocator, path, 4 * 1024 * 1024) catch return;
    const Entry = struct {
        id: []const u8,
        secret_hash: []const u8,
        name: []const u8,
        email: []const u8,
        redirect_uri: []const u8,
        created_at: i64,
        revoked: bool = false,
    };
    const parsed = std.json.parseFromSlice([]const Entry, allocator, data, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    for (parsed.value) |e| {
        clients_list.append(allocator, .{
            .id = allocator.dupe(u8, e.id) catch continue,
            .secret_hash = allocator.dupe(u8, e.secret_hash) catch continue,
            .name = allocator.dupe(u8, e.name) catch continue,
            .email = allocator.dupe(u8, e.email) catch continue,
            .redirect_uri = allocator.dupe(u8, e.redirect_uri) catch continue,
            .created_at = e.created_at,
            .revoked = e.revoked,
        }) catch {};
    }
}

fn saveClients(allocator: std.mem.Allocator, project_dir: []const u8) void {
    ensureAuthDir(project_dir);
    const path = clientsPath(allocator, project_dir) catch return;
    defer allocator.free(path);
    const file = std.fs.cwd().createFile(path, .{}) catch return;
    defer file.close();
    var bw: std.ArrayListUnmanaged(u8) = .empty;
    defer bw.deinit(allocator);
    const w = bw.writer(allocator);
    w.writeAll("[") catch return;
    for (clients_list.items, 0..) |c, i| {
        if (i > 0) w.writeAll(",") catch return;
        w.print("{{\"id\":\"{s}\",\"secret_hash\":\"{s}\",\"name\":", .{ c.id, c.secret_hash }) catch return;
        writeJsonStringTo(w, c.name) catch return;
        w.print(",\"email\":\"{s}\",\"redirect_uri\":", .{c.email}) catch return;
        writeJsonStringTo(w, c.redirect_uri) catch return;
        w.print(",\"created_at\":{d},\"revoked\":{}}}", .{ c.created_at, c.revoked }) catch return;
    }
    w.writeAll("]") catch return;
    file.writeAll(bw.items) catch return;
}

fn loadTokens(allocator: std.mem.Allocator, project_dir: []const u8) void {
    const path = tokensPath(allocator, project_dir) catch return;
    defer allocator.free(path);
    const data = std.fs.cwd().readFileAlloc(allocator, path, 4 * 1024 * 1024) catch return;
    const Entry = struct {
        hash: []const u8,
        client_id: []const u8,
        email: []const u8,
        scope: []const u8,
        expires_at: i64,
    };
    const parsed = std.json.parseFromSlice([]const Entry, allocator, data, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    const now = std.time.timestamp();
    for (parsed.value) |e| {
        if (e.expires_at < now) continue;
        tokens_list.append(allocator, .{
            .hash = allocator.dupe(u8, e.hash) catch continue,
            .client_id = allocator.dupe(u8, e.client_id) catch continue,
            .email = allocator.dupe(u8, e.email) catch continue,
            .scope = allocator.dupe(u8, e.scope) catch continue,
            .expires_at = e.expires_at,
        }) catch {};
    }
}

fn saveTokens(allocator: std.mem.Allocator, project_dir: []const u8) void {
    ensureAuthDir(project_dir);
    const path = tokensPath(allocator, project_dir) catch return;
    defer allocator.free(path);
    const file = std.fs.cwd().createFile(path, .{}) catch return;
    defer file.close();
    var bw: std.ArrayListUnmanaged(u8) = .empty;
    defer bw.deinit(allocator);
    const w = bw.writer(allocator);
    w.writeAll("[") catch return;
    for (tokens_list.items, 0..) |t, i| {
        if (i > 0) w.writeAll(",") catch return;
        w.print("{{\"hash\":\"{s}\",\"client_id\":\"{s}\",\"email\":\"{s}\",\"scope\":\"{s}\",\"expires_at\":{d}}}", .{ t.hash, t.client_id, t.email, t.scope, t.expires_at }) catch return;
    }
    w.writeAll("]") catch return;
    file.writeAll(bw.items) catch return;
}

// ── Client CRUD ─────────────────────────────────────────────────────────

pub const NewClientResult = struct {
    id: []const u8,
    secret: []const u8,
};

pub fn createClient(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    email: []const u8,
    redirect_uri: []const u8,
) !NewClientResult {
    mu.lock();
    defer mu.unlock();
    ensureLoaded(allocator, project_dir);

    const id_suffix = try randomHex(allocator, 16);
    defer allocator.free(id_suffix);
    const id = try std.fmt.allocPrint(allocator, "eda_c_{s}", .{id_suffix});

    const secret_suffix = try randomHex(allocator, 32);
    defer allocator.free(secret_suffix);
    const secret = try std.fmt.allocPrint(allocator, "eda_s_{s}", .{secret_suffix});

    const secret_hash = try sha256Hex(allocator, secret);

    try clients_list.append(allocator, .{
        .id = id,
        .secret_hash = secret_hash,
        .name = try allocator.dupe(u8, name),
        .email = try allocator.dupe(u8, email),
        .redirect_uri = try allocator.dupe(u8, redirect_uri),
        .created_at = std.time.timestamp(),
        .revoked = false,
    });

    saveClients(allocator, project_dir);
    return .{ .id = id, .secret = secret };
}

pub fn findClient(allocator: std.mem.Allocator, project_dir: []const u8, id: []const u8) ?Client {
    mu.lock();
    defer mu.unlock();
    ensureLoaded(allocator, project_dir);
    for (clients_list.items) |c| {
        if (c.revoked) continue;
        if (std.mem.eql(u8, c.id, id)) return c;
    }
    return null;
}

pub fn verifyClientSecret(allocator: std.mem.Allocator, project_dir: []const u8, id: []const u8, secret: []const u8) !?Client {
    const client = findClient(allocator, project_dir, id) orelse return null;
    const hash = try sha256Hex(allocator, secret);
    defer allocator.free(hash);
    if (!std.mem.eql(u8, hash, client.secret_hash)) return null;
    return client;
}

pub fn revokeClient(allocator: std.mem.Allocator, project_dir: []const u8, id: []const u8, owner_email: []const u8) bool {
    mu.lock();
    defer mu.unlock();
    ensureLoaded(allocator, project_dir);
    var changed = false;
    for (clients_list.items) |*c| {
        if (std.mem.eql(u8, c.id, id) and std.mem.eql(u8, c.email, owner_email)) {
            c.revoked = true;
            changed = true;
            break;
        }
    }
    if (changed) saveClients(allocator, project_dir);
    return changed;
}

pub fn revokeAllClientsForEmail(allocator: std.mem.Allocator, project_dir: []const u8, owner_email: []const u8) void {
    mu.lock();
    defer mu.unlock();
    ensureLoaded(allocator, project_dir);
    var changed = false;
    for (clients_list.items) |*c| {
        if (!c.revoked and std.mem.eql(u8, c.email, owner_email)) {
            c.revoked = true;
            changed = true;
        }
    }
    if (changed) saveClients(allocator, project_dir);
}

pub fn listClientsByEmail(allocator: std.mem.Allocator, project_dir: []const u8, owner_email: []const u8) ![]Client {
    mu.lock();
    defer mu.unlock();
    ensureLoaded(allocator, project_dir);
    var out: std.ArrayListUnmanaged(Client) = .empty;
    for (clients_list.items) |c| {
        if (c.revoked) continue;
        if (std.mem.eql(u8, c.email, owner_email)) try out.append(allocator, c);
    }
    return out.toOwnedSlice(allocator);
}

// ── Auth codes (in-memory, 10 min TTL) ──────────────────────────────────

pub fn issueCode(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    client_id: []const u8,
    redirect_uri: []const u8,
    email: []const u8,
    code_challenge: []const u8,
    scope: []const u8,
) ![]const u8 {
    mu.lock();
    defer mu.unlock();
    ensureLoaded(allocator, project_dir);

    const code = try randomHex(allocator, 32);
    const entry = AuthCode{
        .code = code,
        .client_id = try allocator.dupe(u8, client_id),
        .redirect_uri = try allocator.dupe(u8, redirect_uri),
        .email = try allocator.dupe(u8, email),
        .code_challenge = try allocator.dupe(u8, code_challenge),
        .scope = try allocator.dupe(u8, scope),
        .expires_at = std.time.timestamp() + 600,
    };
    try codes_map.?.put(code, entry);
    return code;
}

pub fn consumeCode(allocator: std.mem.Allocator, project_dir: []const u8, code: []const u8) ?AuthCode {
    mu.lock();
    defer mu.unlock();
    ensureLoaded(allocator, project_dir);
    const entry = codes_map.?.fetchRemove(code) orelse return null;
    if (entry.value.expires_at < std.time.timestamp()) return null;
    return entry.value;
}

// ── Access tokens (persisted, 30 day TTL) ───────────────────────────────

pub fn issueToken(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    client_id: []const u8,
    email: []const u8,
    scope: []const u8,
) ![]const u8 {
    mu.lock();
    defer mu.unlock();
    ensureLoaded(allocator, project_dir);

    const raw_suffix = try randomHex(allocator, 32);
    defer allocator.free(raw_suffix);
    const raw = try std.fmt.allocPrint(allocator, "eda_t_{s}", .{raw_suffix});
    const hash = try sha256Hex(allocator, raw);

    try tokens_list.append(allocator, .{
        .hash = hash,
        .client_id = try allocator.dupe(u8, client_id),
        .email = try allocator.dupe(u8, email),
        .scope = try allocator.dupe(u8, scope),
        .expires_at = std.time.timestamp() + 30 * 24 * 60 * 60,
    });
    saveTokens(allocator, project_dir);
    return raw;
}

pub fn validateToken(allocator: std.mem.Allocator, project_dir: []const u8, raw: []const u8) !?Token {
    mu.lock();
    defer mu.unlock();
    ensureLoaded(allocator, project_dir);
    const hash = try sha256Hex(allocator, raw);
    defer allocator.free(hash);
    const now = std.time.timestamp();
    for (tokens_list.items) |t| {
        if (t.expires_at < now) continue;
        if (std.mem.eql(u8, t.hash, hash)) {
            // Check client still active
            var client_ok = false;
            for (clients_list.items) |c| {
                if (!c.revoked and std.mem.eql(u8, c.id, t.client_id)) {
                    client_ok = true;
                    break;
                }
            }
            if (client_ok) return t;
            return null;
        }
    }
    return null;
}

// ── Crypto helpers ──────────────────────────────────────────────────────

pub fn sha256Hex(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    Sha256.hash(input, &digest, .{});
    var out = try allocator.alloc(u8, 64);
    const hex = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
    return out;
}

pub fn sha256Base64Url(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    Sha256.hash(input, &digest, .{});
    const enc = std.base64.url_safe_no_pad.Encoder;
    const out_len = enc.calcSize(digest.len);
    const out = try allocator.alloc(u8, out_len);
    _ = enc.encode(out, &digest);
    return out;
}

/// PKCE S256: verify code_verifier matches code_challenge.
pub fn verifyPkce(allocator: std.mem.Allocator, code_verifier: []const u8, code_challenge: []const u8) !bool {
    const expected = try sha256Base64Url(allocator, code_verifier);
    defer allocator.free(expected);
    return std.mem.eql(u8, expected, code_challenge);
}

fn randomHex(allocator: std.mem.Allocator, n_chars: usize) ![]u8 {
    const n_bytes = (n_chars + 1) / 2;
    const bytes = try allocator.alloc(u8, n_bytes);
    defer allocator.free(bytes);
    std.crypto.random.bytes(bytes);
    var out = try allocator.alloc(u8, n_chars);
    const hex = "0123456789abcdef";
    var i: usize = 0;
    while (i < n_chars) : (i += 1) {
        const byte = bytes[i / 2];
        out[i] = if (i % 2 == 0) hex[byte >> 4] else hex[byte & 0x0f];
    }
    return out;
}

fn writeJsonStringTo(w: anytype, s: []const u8) !void {
    try w.writeAll("\"");
    for (s) |ch| {
        switch (ch) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{ch}),
            else => try w.writeByte(ch),
        }
    }
    try w.writeAll("\"");
}
