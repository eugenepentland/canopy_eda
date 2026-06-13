const std = @import("std");
const json_writer = @import("../json_writer.zig");
const infra_fs = @import("../infra/fs.zig");
const clock = @import("../infra/clock.zig");
const log = @import("../infra/log.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;
const infra_random = @import("../infra/random.zig");
const auth_store = @import("auth_store.zig");

// ── Constants ─────────────────────────────────────────────────────
const AUTH_CODE_TTL_SECS: i64 = 600; // 10 min
const ACCESS_TOKEN_TTL_DAYS: i64 = 30;
const ACCESS_TOKEN_TTL_SECS: i64 = ACCESS_TOKEN_TTL_DAYS * std.time.s_per_day;

/// Persisted OAuth client record (one per Claude Code install). Secrets are
/// hashed via SHA-256 before storage so a leaked `oauth_clients.json`
/// cannot be replayed against the token endpoint.
pub const Client = struct {
    id: []const u8,
    secret_hash: []const u8,
    name: []const u8,
    email: []const u8,
    redirect_uri: []const u8,
    created_at: i64,
    revoked: bool = false,
};

/// Short-lived authorization code waiting to be exchanged for an access
/// token at `/oauth/token`. Held only in memory; PKCE `code_challenge` is
/// verified against the verifier the client posts back.
pub const AuthCode = struct {
    code: []const u8,
    client_id: []const u8,
    redirect_uri: []const u8,
    email: []const u8,
    code_challenge: []const u8,
    scope: []const u8,
    expires_at: i64,
};

/// Persisted bearer-token record. Only the SHA-256 `hash` of the token
/// reaches disk; comparison happens on the hash so a stolen
/// `oauth_tokens.json` reveals neither the original token nor the secret.
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
var loaded_auth_dir: ?[]const u8 = null;
/// Set when `loadClients` successfully read a non-empty file. Used by
/// `saveClients` as a tripwire: if the in-memory list is empty but the
/// loaded file had content, refuse to write — that's the signature of a
/// silent parse failure that would otherwise blow away all the credentials
/// on the next createClient/revokeClient call. The user has to fix the
/// file (or reset the flag) before the server will overwrite it.
var clients_file_was_nonempty: bool = false;
var tokens_file_was_nonempty: bool = false;

// Everything held in the module-global lists/maps above outlives any single
// request — handlers call in with a per-request arena, so persistent rows,
// codes, and the containers themselves are allocated from the process
// allocator instead of the caller's.
const store_alloc = std.heap.page_allocator;

fn ensureLoaded(allocator: std.mem.Allocator, auth_dir: []const u8) void {
    if (loaded_auth_dir) |d| {
        if (std.mem.eql(u8, d, auth_dir)) return;
        // auth_dir is changing — reset the in-memory state so we don't end
        // up with the union of two files' contents (the previous behaviour
        // when callers passed inconsistent paths). This shouldn't happen in
        // normal operation but did slip in via a typo bug at one point;
        // making it well-defined keeps the failure mode "load the wrong
        // file" rather than "merge two files into a duplicated mess that
        // then writes back."
        for (clients_list.items) |c| {
            store_alloc.free(@constCast(c.id));
            store_alloc.free(@constCast(c.secret_hash));
            store_alloc.free(@constCast(c.name));
            store_alloc.free(@constCast(c.email));
            store_alloc.free(@constCast(c.redirect_uri));
        }
        clients_list.clearRetainingCapacity();
        for (tokens_list.items) |t| {
            store_alloc.free(@constCast(t.hash));
            store_alloc.free(@constCast(t.client_id));
            store_alloc.free(@constCast(t.email));
            store_alloc.free(@constCast(t.scope));
        }
        tokens_list.clearRetainingCapacity();
        clients_file_was_nonempty = false;
        tokens_file_was_nonempty = false;
    }
    loaded_auth_dir = auth_dir;
    loadClients(allocator, auth_dir);
    loadTokens(allocator, auth_dir);
    if (codes_map == null) codes_map = std.StringHashMap(AuthCode).init(store_alloc);
}

fn clientsPath(allocator: std.mem.Allocator, auth_dir: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/oauth_clients.json", .{auth_dir});
}

fn tokensPath(allocator: std.mem.Allocator, auth_dir: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/oauth_tokens.json", .{auth_dir});
}

const ensureAuthDir = auth_store.ensureAuthDir;

fn loadClients(allocator: std.mem.Allocator, auth_dir: []const u8) void {
    const path = clientsPath(allocator, auth_dir) catch return;
    defer allocator.free(path);
    const data = infra_fs.cwd().readFileAlloc(allocator, path, 4 * 1024 * 1024) catch |e| {
        if (e != error.FileNotFound) {
            log.warn("oauth: read {s} failed: {s}", .{ path, @errorName(e) });
        }
        return;
    };
    const file_had_content = data.len > 2; // "[]" is the only possible empty-but-valid file.
    const Entry = struct {
        id: []const u8,
        secret_hash: []const u8,
        name: []const u8,
        email: []const u8,
        redirect_uri: []const u8,
        created_at: i64,
        revoked: bool = false,
    };
    const parsed = std.json.parseFromSlice([]const Entry, allocator, data, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch |e| {
        // Parse failed — file is corrupt or in an unexpected schema. Trip
        // the safety so the next save refuses to clobber it; the operator
        // has to fix the file by hand. Without this, a parse failure
        // followed by createClient would write a fresh file with a single
        // entry and silently destroy the rest.
        log.warn("oauth: parse {s} failed: {s} — load skipped, saves locked", .{ path, @errorName(e) });
        if (file_had_content) clients_file_was_nonempty = true;
        return;
    };
    defer parsed.deinit();
    for (parsed.value) |e| {
        clients_list.append(store_alloc, .{
            .id = store_alloc.dupe(u8, e.id) catch continue,
            .secret_hash = store_alloc.dupe(u8, e.secret_hash) catch continue,
            .name = store_alloc.dupe(u8, e.name) catch continue,
            .email = store_alloc.dupe(u8, e.email) catch continue,
            .redirect_uri = store_alloc.dupe(u8, e.redirect_uri) catch continue,
            .created_at = e.created_at,
            .revoked = e.revoked,
        }) catch continue;
    }
    if (file_had_content) clients_file_was_nonempty = true;
}

fn saveClients(allocator: std.mem.Allocator, auth_dir: []const u8) void {
    ensureAuthDir(auth_dir);
    const path = clientsPath(allocator, auth_dir) catch return;
    defer allocator.free(path);

    // Empty-list guard: refuse to overwrite a file that previously had
    // content. Catches the case where loadClients silently failed (parse
    // error, transient I/O blip) and a subsequent createClient/revokeClient
    // would otherwise write `[]` and destroy every credential.
    if (clients_list.items.len == 0 and clients_file_was_nonempty) {
        log.warn("oauth: refusing to overwrite {s} with empty list (file had content; possible prior load failure)", .{path});
        return;
    }

    var bw: std.ArrayListUnmanaged(u8) = .empty;
    defer bw.deinit(allocator);
    const w = bw.writer(allocator);
    w.writeAll("[") catch return;
    for (clients_list.items, 0..) |c, i| {
        if (i > 0) w.writeAll(",") catch return;
        w.print("{{\"id\":\"{s}\",\"secret_hash\":\"{s}\",\"name\":", .{ c.id, c.secret_hash }) catch return;
        json_writer.writeString(w, c.name) catch return;
        w.print(",\"email\":\"{s}\",\"redirect_uri\":", .{c.email}) catch return;
        json_writer.writeString(w, c.redirect_uri) catch return;
        w.print(",\"created_at\":{d},\"revoked\":{}}}", .{ c.created_at, c.revoked }) catch return;
    }
    w.writeAll("]") catch return;
    writeFileAtomicWithBackup(allocator, path, bw.items);
    if (clients_list.items.len > 0) clients_file_was_nonempty = true;
}

fn loadTokens(allocator: std.mem.Allocator, auth_dir: []const u8) void {
    const path = tokensPath(allocator, auth_dir) catch return;
    defer allocator.free(path);
    const data = infra_fs.cwd().readFileAlloc(allocator, path, 4 * 1024 * 1024) catch |e| {
        if (e != error.FileNotFound) {
            log.warn("oauth: read {s} failed: {s}", .{ path, @errorName(e) });
        }
        return;
    };
    const file_had_content = data.len > 2;
    const Entry = struct {
        hash: []const u8,
        client_id: []const u8,
        email: []const u8,
        scope: []const u8,
        expires_at: i64,
    };
    const parsed = std.json.parseFromSlice([]const Entry, allocator, data, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch |e| {
        log.warn("oauth: parse {s} failed: {s} — load skipped, saves locked", .{ path, @errorName(e) });
        if (file_had_content) tokens_file_was_nonempty = true;
        return;
    };
    defer parsed.deinit();
    const now = clock.timestamp();
    for (parsed.value) |e| {
        if (e.expires_at < now) continue;
        tokens_list.append(store_alloc, .{
            .hash = store_alloc.dupe(u8, e.hash) catch continue,
            .client_id = store_alloc.dupe(u8, e.client_id) catch continue,
            .email = store_alloc.dupe(u8, e.email) catch continue,
            .scope = store_alloc.dupe(u8, e.scope) catch continue,
            .expires_at = e.expires_at,
        }) catch continue;
    }
    if (file_had_content) tokens_file_was_nonempty = true;
}

fn saveTokens(allocator: std.mem.Allocator, auth_dir: []const u8) void {
    ensureAuthDir(auth_dir);
    const path = tokensPath(allocator, auth_dir) catch return;
    defer allocator.free(path);

    // Same empty-list guard as saveClients: don't overwrite a previously
    // populated tokens file with `[]` after a load failure.
    if (tokens_list.items.len == 0 and tokens_file_was_nonempty) {
        log.warn("oauth: refusing to overwrite {s} with empty list (file had content; possible prior load failure)", .{path});
        return;
    }

    var bw: std.ArrayListUnmanaged(u8) = .empty;
    defer bw.deinit(allocator);
    const w = bw.writer(allocator);
    w.writeAll("[") catch return;
    for (tokens_list.items, 0..) |t, i| {
        if (i > 0) w.writeAll(",") catch return;
        w.print(
            "{{\"hash\":\"{s}\",\"client_id\":\"{s}\"," ++
                "\"email\":\"{s}\",\"scope\":\"{s}\",\"expires_at\":{d}}}",
            .{ t.hash, t.client_id, t.email, t.scope, t.expires_at },
        ) catch return;
    }
    w.writeAll("]") catch return;
    writeFileAtomicWithBackup(allocator, path, bw.items);
    if (tokens_list.items.len > 0) tokens_file_was_nonempty = true;
}

/// Atomic save with rolling backup:
///   1. Copy `<path>` → `<path>.bak` (best effort; missing source = no-op)
///   2. Write `data` to `<path>.tmp`, then rename onto `<path>`
///
/// Step 1 gives us a trivial recovery point — if anything dropped entries
/// (manual edit, bad merge, partial restore), the previous good state is
/// one `cp` away. Step 2 means a crash mid-write can't truncate the live
/// file: the rename either succeeds atomically or the live file stays as
/// whichever side completed last.
fn writeFileAtomicWithBackup(allocator: std.mem.Allocator, path: []const u8, data: []const u8) void {
    // Backup: copy current file (if any) to <path>.bak. We don't fail the
    // save when backup fails — a missing source on first save is normal
    // and we don't want to block saves on FS quirks.
    const bak_path = std.fmt.allocPrint(allocator, "{s}.bak", .{path}) catch return;
    defer allocator.free(bak_path);
    if (infra_fs.cwd().readFileAlloc(allocator, path, 4 * 1024 * 1024)) |existing| {
        defer allocator.free(existing);
        if (infra_fs.cwd().createFile(bak_path, .{ .truncate = true })) |bf| {
            defer bf.close();
            bf.writeAll(existing) catch |e| log.warn("oauth: backup write {s} failed: {s}", .{ bak_path, @errorName(e) });
        } else |e| {
            log.warn("oauth: backup create {s} failed: {s}", .{ bak_path, @errorName(e) });
        }
    } else |_| {} // no prior file; nothing to back up

    // Atomic write: tmp → rename. Same pattern vfs.zig uses for user files.
    var write_buf: [4096]u8 = undefined;
    var atomic = infra_fs.cwd().atomicFile(path, .{ .write_buffer = &write_buf }) catch |e| {
        log.warn("oauth: atomicFile {s} failed: {s}", .{ path, @errorName(e) });
        return;
    };
    defer atomic.deinit();
    atomic.file_writer.interface.writeAll(data) catch |e| {
        log.warn("oauth: atomic write {s} failed: {s}", .{ path, @errorName(e) });
        return;
    };
    atomic.finish() catch |e| {
        log.warn("oauth: atomic finish {s} failed: {s}", .{ path, @errorName(e) });
        return;
    };
}

// ── Client CRUD ─────────────────────────────────────────────────────────

/// Returned by `createClient`: the fresh `client_id` and the *plaintext*
/// `client_secret` shown to the user exactly once on the account page.
/// Only the secret's hash is persisted to disk after this point.
pub const NewClientResult = struct {
    id: []const u8,
    secret: []const u8,
};

/// Mint a new `eda_c_…` client_id and `eda_s_…` secret pair, persist the
/// client (with hashed secret) to `oauth_clients.json`, and return the
/// plaintext secret for one-time display in the account UI.
pub fn createClient(
    allocator: std.mem.Allocator,
    auth_dir: []const u8,
    name: []const u8,
    email: []const u8,
    redirect_uri: []const u8,
) std.mem.Allocator.Error!NewClientResult {
    mu.lock();
    defer mu.unlock();
    ensureLoaded(allocator, auth_dir);

    const id_suffix = try randomHex(allocator, 16);
    defer allocator.free(id_suffix);
    // `id` is both stored and returned — allocate it from the store so the
    // persisted row survives the caller's request arena.
    const id = try std.fmt.allocPrint(store_alloc, "eda_c_{s}", .{id_suffix});

    const secret_suffix = try randomHex(allocator, 32);
    defer allocator.free(secret_suffix);
    const secret = try std.fmt.allocPrint(allocator, "eda_s_{s}", .{secret_suffix});

    const secret_hash = try sha256Hex(store_alloc, secret);

    try clients_list.append(store_alloc, .{
        .id = id,
        .secret_hash = secret_hash,
        .name = try store_alloc.dupe(u8, name),
        .email = try store_alloc.dupe(u8, email),
        .redirect_uri = try store_alloc.dupe(u8, redirect_uri),
        .created_at = clock.timestamp(),
        .revoked = false,
    });

    saveClients(allocator, auth_dir);
    return .{ .id = id, .secret = secret };
}

/// Return the active client with the given id, or null when no match
/// exists or the row has been revoked. Used during the authorize flow to
/// confirm the client_id parameter is one we know about.
pub fn findClient(allocator: std.mem.Allocator, auth_dir: []const u8, id: []const u8) ?Client {
    mu.lock();
    defer mu.unlock();
    ensureLoaded(allocator, auth_dir);
    for (clients_list.items) |c| {
        if (c.revoked) continue;
        if (std.mem.eql(u8, c.id, id)) return c;
    }
    return null;
}

/// Look up the client and constant-compare its stored hash against
/// `sha256(secret)`. Returns the client record on a match, null on
/// unknown/revoked id or wrong secret. Called from the token endpoint.
pub fn verifyClientSecret(allocator: std.mem.Allocator, auth_dir: []const u8, id: []const u8, secret: []const u8) std.mem.Allocator.Error!?Client {
    const client = findClient(allocator, auth_dir, id) orelse return null;
    const hash = try sha256Hex(allocator, secret);
    defer allocator.free(hash);
    if (!std.mem.eql(u8, hash, client.secret_hash)) return null;
    return client;
}

/// Set an unowned client's email. Called when the first user approves a
/// dynamically-registered client on `/oauth/authorize` — assigns ownership
/// so they can revoke it later from `/account`. No-op if the client
/// already has an owner (different email) or doesn't exist.
pub fn claimClient(allocator: std.mem.Allocator, auth_dir: []const u8, id: []const u8, owner_email: []const u8) void {
    mu.lock();
    defer mu.unlock();
    ensureLoaded(allocator, auth_dir);
    var changed = false;
    for (clients_list.items) |*c| {
        if (!std.mem.eql(u8, c.id, id)) continue;
        if (c.email.len != 0) return; // already owned
        const dup = store_alloc.dupe(u8, owner_email) catch return;
        store_alloc.free(@constCast(c.email));
        c.email = dup;
        changed = true;
        break;
    }
    if (changed) saveClients(allocator, auth_dir);
}

/// Mark a single client as revoked, but only when `owner_email` matches —
/// users can't accidentally (or maliciously) revoke another user's client.
/// Returns true when a row was modified.
pub fn revokeClient(allocator: std.mem.Allocator, auth_dir: []const u8, id: []const u8, owner_email: []const u8) bool {
    mu.lock();
    defer mu.unlock();
    ensureLoaded(allocator, auth_dir);
    var changed = false;
    for (clients_list.items) |*c| {
        if (std.mem.eql(u8, c.id, id) and std.mem.eql(u8, c.email, owner_email)) {
            c.revoked = true;
            changed = true;
            break;
        }
    }
    if (changed) saveClients(allocator, auth_dir);
    return changed;
}

/// Mass-revoke every active client owned by `owner_email`. Called by the
/// admin user-deletion path so a removed user can't keep using cached
/// `client_id`/`client_secret` pairs from Claude Code.
pub fn revokeAllClientsForEmail(allocator: std.mem.Allocator, auth_dir: []const u8, owner_email: []const u8) void {
    mu.lock();
    defer mu.unlock();
    ensureLoaded(allocator, auth_dir);
    var changed = false;
    for (clients_list.items) |*c| {
        if (!c.revoked and std.mem.eql(u8, c.email, owner_email)) {
            c.revoked = true;
            changed = true;
        }
    }
    if (changed) saveClients(allocator, auth_dir);
}

/// Return every non-revoked client owned by `owner_email`. Backs the
/// account page's "Your Claude Code clients" list. Caller owns the slice.
pub fn listClientsByEmail(allocator: std.mem.Allocator, auth_dir: []const u8, owner_email: []const u8) std.mem.Allocator.Error![]Client {
    mu.lock();
    defer mu.unlock();
    ensureLoaded(allocator, auth_dir);
    var out: std.ArrayListUnmanaged(Client) = .empty;
    for (clients_list.items) |c| {
        if (c.revoked) continue;
        if (std.mem.eql(u8, c.email, owner_email)) try out.append(allocator, c);
    }
    return out.toOwnedSlice(allocator);
}

// ── Auth codes (in-memory, 10 min TTL) ──────────────────────────────────

/// Generate and stash a fresh authorization code (10-minute TTL, in
/// memory only) the user's browser will redirect with after consenting on
/// `/oauth/authorize`. Bound to the PKCE `code_challenge`.
pub fn issueCode(
    allocator: std.mem.Allocator,
    auth_dir: []const u8,
    client_id: []const u8,
    redirect_uri: []const u8,
    email: []const u8,
    code_challenge: []const u8,
    scope: []const u8,
) std.mem.Allocator.Error![]const u8 {
    mu.lock();
    defer mu.unlock();
    ensureLoaded(allocator, auth_dir);

    const code = try randomHex(store_alloc, 32);
    const entry = AuthCode{
        .code = code,
        .client_id = try store_alloc.dupe(u8, client_id),
        .redirect_uri = try store_alloc.dupe(u8, redirect_uri),
        .email = try store_alloc.dupe(u8, email),
        .code_challenge = try store_alloc.dupe(u8, code_challenge),
        .scope = try store_alloc.dupe(u8, scope),
        .expires_at = clock.timestamp() + AUTH_CODE_TTL_SECS,
    };
    try codes_map.?.put(code, entry);
    return code;
}

/// Single-use lookup: pop the AuthCode out of the in-memory map and
/// return it (only when not yet expired). The code is gone after this
/// call — replays at the token endpoint return null.
pub fn consumeCode(allocator: std.mem.Allocator, auth_dir: []const u8, code: []const u8) ?AuthCode {
    mu.lock();
    defer mu.unlock();
    ensureLoaded(allocator, auth_dir);
    const entry = codes_map.?.fetchRemove(code) orelse return null;
    if (entry.value.expires_at < clock.timestamp()) return null;
    return entry.value;
}

// ── Access tokens (persisted, 30 day TTL) ───────────────────────────────

/// Mint a new `eda_t_…` access token (30-day TTL), persist its hash to
/// `oauth_tokens.json`, and return the plaintext token to hand back at the
/// `/oauth/token` endpoint.
pub fn issueToken(
    allocator: std.mem.Allocator,
    auth_dir: []const u8,
    client_id: []const u8,
    email: []const u8,
    scope: []const u8,
) std.mem.Allocator.Error![]const u8 {
    mu.lock();
    defer mu.unlock();
    ensureLoaded(allocator, auth_dir);

    const raw_suffix = try randomHex(allocator, 32);
    defer allocator.free(raw_suffix);
    const raw = try std.fmt.allocPrint(allocator, "eda_t_{s}", .{raw_suffix});
    const hash = try sha256Hex(store_alloc, raw);

    try tokens_list.append(store_alloc, .{
        .hash = hash,
        .client_id = try store_alloc.dupe(u8, client_id),
        .email = try store_alloc.dupe(u8, email),
        .scope = try store_alloc.dupe(u8, scope),
        .expires_at = clock.timestamp() + ACCESS_TOKEN_TTL_SECS,
    });
    saveTokens(allocator, auth_dir);
    return raw;
}

/// Return the Token record matching `sha256(raw)` when it has not
/// expired and its owning client is still active. Used by the auth
/// middleware on every request that carries a Bearer header.
pub fn validateToken(allocator: std.mem.Allocator, auth_dir: []const u8, raw: []const u8) std.mem.Allocator.Error!?Token {
    mu.lock();
    defer mu.unlock();
    ensureLoaded(allocator, auth_dir);
    const hash = try sha256Hex(allocator, raw);
    defer allocator.free(hash);
    const now = clock.timestamp();
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

/// SHA-256 of `input` as a 64-char lower-case hex string (re-exported from
/// `auth_store`). Used to hash secrets and tokens before they reach
/// `oauth_clients.json` / `oauth_tokens.json`.
pub const sha256Hex = auth_store.sha256Hex;

/// SHA-256 of `input` rendered as base64url with no padding — the format
/// PKCE S256 uses for `code_challenge`. Used by `verifyPkce` to compare
/// what the client-provided `code_verifier` should hash to.
pub fn sha256Base64Url(allocator: std.mem.Allocator, input: []const u8) std.mem.Allocator.Error![]u8 {
    var digest: [32]u8 = undefined;
    Sha256.hash(input, &digest, .{});
    const enc = std.base64.url_safe_no_pad.Encoder;
    const out_len = enc.calcSize(digest.len);
    const out = try allocator.alloc(u8, out_len);
    _ = enc.encode(out, &digest);
    return out;
}

/// PKCE S256: verify code_verifier matches code_challenge.
pub fn verifyPkce(allocator: std.mem.Allocator, code_verifier: []const u8, code_challenge: []const u8) std.mem.Allocator.Error!bool {
    const expected = try sha256Base64Url(allocator, code_verifier);
    defer allocator.free(expected);
    return std.mem.eql(u8, expected, code_challenge);
}

fn randomHex(allocator: std.mem.Allocator, n_chars: usize) ![]u8 {
    const n_bytes = (n_chars + 1) / 2;
    const bytes = try allocator.alloc(u8, n_bytes);
    defer allocator.free(bytes);
    infra_random.bytes(bytes);
    var out = try allocator.alloc(u8, n_chars);
    const hex = "0123456789abcdef";
    var i: usize = 0;
    while (i < n_chars) : (i += 1) {
        const byte = bytes[i / 2];
        out[i] = if (i % 2 == 0) hex[byte >> 4] else hex[byte & 0x0f];
    }
    return out;
}
