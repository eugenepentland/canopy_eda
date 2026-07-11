//! Passkey (WebAuthn) authentication and the serve layer's session +
//! challenge stores. Runs the register/login ceremonies, the auth middleware
//! that gates every non-`/auth/*` route, invite links, and credential
//! management — all reading and writing the JSON files under the server's
//! `auth_dir`. The session table (`SessionStore`) and the per-attempt WebAuthn
//! challenge table (`ChallengeStore`) are per-server instance state carried on
//! `ServerState`; their rows live in `page_allocator` (process lifetime, not
//! the per-request arena) and the sessions persist to `<auth_dir>/sessions.json`.

const std = @import("std");
const httpz = @import("httpz");
const infra_fs = @import("../infra/fs.zig");
const clock = @import("../infra/clock.zig");
const log = @import("../infra/log.zig");
const serve_root = @import("../serve.zig");
const Server = serve_root.Server;
const oauth_store = @import("oauth_store.zig");
const users = @import("users.zig");
const infra_random = @import("../infra/random.zig");
const auth_template = @import("templates/auth.zig");

// ── Constants ─────────────────────────────────────────────────────
const http_not_found: u16 = 404;
const http_bad_request: u16 = 400;
const http_internal_error: u16 = 500;

// Time (use std.time constants to avoid bare-60 magic-number violations)
const seconds_per_day: i64 = std.time.s_per_day;
const session_ttl_days: i64 = 7;
const session_ttl_secs: i64 = session_ttl_days * seconds_per_day;

// Token sizes
const session_rand_bytes: usize = 32;
const invite_rand_bytes: usize = 24;

// File-size limits
const max_session_file_bytes: usize = 256 * 1024;
const max_invites_file_bytes: usize = 256 * 1024;

// WebAuthn authenticatorData layout (RFC 8809 §6)
const auth_data_rpid_hash_len: usize = 32;
const auth_data_flags_len: usize = 1;
const auth_data_sign_count_len: usize = 4;
const auth_data_header_len: usize = auth_data_rpid_hash_len + auth_data_flags_len + auth_data_sign_count_len; // 37
const auth_data_aaguid_len: usize = 16;
const auth_data_cred_len_offset: usize = auth_data_header_len + auth_data_aaguid_len; // 53
const auth_data_cred_data_offset: usize = auth_data_cred_len_offset + 2; // 55

// EC P-256 SEC1 uncompressed point: 1 tag byte + 32 X + 32 Y
const sec1_uncompressed_len: usize = 65;
const sec1_tag_and_x_len: usize = 33;

// CBOR encoding constants (RFC 8949)
const cbor_tag_bits: u3 = 5;
const cbor_additional_mask: u8 = 0x1f;
const cbor_major_map: u8 = 5;
const cbor_additional_u8: u8 = 24;
const cbor_additional_u16: u8 = 25;
const cbor_additional_u32: u8 = 26;
const cbor_additional_u64: u8 = 27;
const cbor_header_len_u8: usize = 2;
const cbor_header_len_u16: usize = 3;
const cbor_header_len_u32: usize = 5;
const cbor_header_len_u64: usize = 9;

// URL scheme prefixes (extracted to satisfy ban-hardcoded-paths)
const url_scheme_https = "https";
const url_scheme_http = "http";
const url_scheme_template = "{s}://{s}";

// Repeated string literals (HTML/JSON templates and headers)
const header_location = "location";
const header_set_cookie = "set-cookie";
const path_auth_login = "/auth/login";
const host_localhost = "localhost";

const session_cookie_fmt = "session={s}; Path=/; HttpOnly; SameSite=Strict; Max-Age=604800";

const err_invalid_email_json = "{\"error\":\"invalid email\"}";
const err_invalid_json_json = "{\"error\":\"invalid json\"}";
const err_missing_body_json = "{\"error\":\"missing body\"}";
const err_missing_id_json = "{\"error\":\"missing id\"}";
const err_invalid_client_data = "{\"error\":\"invalid clientDataJSON\"}";
const ok_json_true = "{\"ok\":true}";

/// Error set for HTTP handlers in this module. Wide enough to cover
/// allocator, writer, file IO, makePath, and JSON / form parsing errors
/// surfaced by `try` from helpers in the body.
pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error ||
    std.fs.File.WriteError || std.fs.File.OpenError || std.fs.File.ReadError ||
    std.fs.Dir.MakeError || std.fs.Dir.StatFileError ||
    error{ FileTooBig, StreamTooLong, EndOfStream, InvalidEscapeSequence };

// ── Session store ────────────────────────────────────────────────────

const SessionData = struct {
    email: []const u8,
    expiry: i64,
};

// Rows in the session and challenge stores outlive every request — handlers
// call in with a per-request arena, so the maps themselves and every
// token/email/id stored in them come from the process allocator instead.
const store_alloc = std.heap.page_allocator;

/// Per-server table of 7-day passkey sessions, persisted to
/// `<auth_dir>/sessions.json`. This is instance state carried on `ServerState`
/// (it used to be a file-scope global), so two servers — or two tests — keep
/// independent sessions. The map and its stored tokens/emails live in
/// `store_alloc` (process lifetime), never the per-request arena.
pub const SessionStore = struct {
    mutex: std.Thread.Mutex = .{},
    map: ?std.StringHashMapUnmanaged(SessionData) = null,
    auth_dir: ?[]const u8 = null,

    fn getMap(
        self: *SessionStore,
        allocator: std.mem.Allocator,
        auth_dir: []const u8,
    ) *std.StringHashMapUnmanaged(SessionData) {
        if (self.map == null) {
            self.map = std.StringHashMapUnmanaged(SessionData).empty;
            self.auth_dir = auth_dir;
            self.load(allocator, auth_dir); // Load persisted sessions
        }
        return &self.map.?;
    }

    fn load(self: *SessionStore, allocator: std.mem.Allocator, auth_dir: []const u8) void {
        const path = sessionsPath(allocator, auth_dir) catch return;
        defer allocator.free(path);
        const file = infra_fs.cwd().openFile(path, .{}) catch return;
        defer file.close();
        const data = file.readToEndAlloc(allocator, 256 * 1024) catch return;
        const Entry = struct { token: []const u8, email: []const u8 = "", expiry: i64 };
        const parsed = std.json.parseFromSlice([]const Entry, allocator, data, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch return;
        const now = clock.timestamp();
        for (parsed.value) |entry| {
            if (entry.email.len == 0) continue; // Drop legacy sessions without identity
            if (now < entry.expiry) {
                const token_dup = store_alloc.dupe(u8, entry.token) catch continue;
                const email_dup = store_alloc.dupe(u8, entry.email) catch continue;
                self.map.?.put(store_alloc, token_dup, .{ .email = email_dup, .expiry = entry.expiry }) catch continue;
            }
        }
    }

    fn persist(self: *SessionStore, allocator: std.mem.Allocator) void {
        const auth_dir = self.auth_dir orelse return;
        const path = sessionsPath(allocator, auth_dir) catch return;
        defer allocator.free(path);
        infra_fs.cwd().makePath(auth_dir) catch return;
        var buf: std.ArrayList(u8) = .empty;
        const w = buf.writer(allocator);
        w.writeAll("[") catch return;
        var map = &self.map.?;
        var it = map.iterator();
        var first = true;
        while (it.next()) |entry| {
            if (!first) w.writeAll(",") catch return;
            w.print("{{\"token\":\"{s}\",\"email\":\"{s}\",\"expiry\":{d}}}", .{ entry.key_ptr.*, entry.value_ptr.email, entry.value_ptr.expiry }) catch return;
            first = false;
        }
        w.writeAll("]") catch return;
        oauth_store.writeFileAtomicWithBackup(allocator, path, buf.items);
    }

    /// Mint a new 7-day session for `email` (32-byte hex random token), persist
    /// it to `<auth_dir>/sessions.json`, and return the token the caller should
    /// send back as the `session` cookie.
    pub fn create(
        self: *SessionStore,
        allocator: std.mem.Allocator,
        auth_dir: []const u8,
        email: []const u8,
    ) std.mem.Allocator.Error![]const u8 {
        var rand_bytes: [32]u8 = undefined;
        infra_random.bytes(&rand_bytes);
        const hex = std.fmt.bytesToHex(rand_bytes, .lower);
        const token = try store_alloc.dupe(u8, &hex);
        errdefer store_alloc.free(token);
        const email_dup = try store_alloc.dupe(u8, email);
        errdefer store_alloc.free(email_dup);

        const now = clock.timestamp();
        const expiry = now + session_ttl_secs;

        self.mutex.lock();
        defer self.mutex.unlock();
        const map = self.getMap(allocator, auth_dir);
        sweepExpiredSessions(allocator, map);
        try map.put(store_alloc, token, .{ .email = email_dup, .expiry = expiry });
        self.persist(allocator);
        return token;
    }

    /// Look up `token` in the persisted session map and return the associated
    /// email if it has not yet expired. Expired entries are evicted as a side
    /// effect; returns `null` for unknown or expired tokens.
    pub fn validate(
        self: *SessionStore,
        allocator: std.mem.Allocator,
        auth_dir: []const u8,
        token: []const u8,
    ) ?[]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const map = self.getMap(allocator, auth_dir);
        const entry = map.get(token) orelse return null;
        const now = clock.timestamp();
        if (now > entry.expiry) {
            _ = map.fetchRemove(token);
            self.persist(allocator);
            return null;
        }
        return entry.email;
    }

    /// Drop `token` from the in-memory map and persist the change to disk so a
    /// stolen cookie cannot reauthenticate. Used by `logoutApi` and during
    /// credential-revocation flows.
    pub fn delete(self: *SessionStore, allocator: std.mem.Allocator, auth_dir: []const u8, token: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const map = self.getMap(allocator, auth_dir);
        _ = map.fetchRemove(token);
        self.persist(allocator);
    }
};

fn sessionsPath(allocator: std.mem.Allocator, auth_dir: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/sessions.json", .{auth_dir});
}

/// Evict every expired entry from the session map. Called on each new login so
/// abandoned sessions don't accumulate in memory for the life of the process
/// (they were previously evicted only when that exact token was looked up
/// again). Caller must hold the store mutex.
fn sweepExpiredSessions(allocator: std.mem.Allocator, map: *std.StringHashMapUnmanaged(SessionData)) void {
    const now = clock.timestamp();
    var expired: std.ArrayList([]const u8) = .empty;
    defer expired.deinit(allocator);
    var it = map.iterator();
    while (it.next()) |e| {
        if (now > e.value_ptr.expiry) expired.append(allocator, e.key_ptr.*) catch break;
    }
    for (expired.items) |k| _ = map.fetchRemove(k);
}

// ── Challenge store ──────────────────────────────────────────────────

// WebAuthn ceremony challenges are keyed by a per-attempt id (the `authcid`
// cookie) rather than a single process-global slot — a global slot meant two
// concurrent register/login ceremonies clobbered each other, so one would fail
// "challenge mismatch" under any concurrency. Each entry is single-use with a
// short TTL.
const challenge_ttl_secs: i64 = 300;
const challenge_cookie = "authcid";
const ChallengeEntry = struct { challenge: [32]u8, expiry: i64 };

/// Per-server table of in-flight WebAuthn challenges, keyed by per-attempt id.
/// Instance state carried on `ServerState` (it used to be a file-scope global);
/// ids and challenges live in `store_alloc` (process lifetime) and are
/// single-use.
pub const ChallengeStore = struct {
    mutex: std.Thread.Mutex = .{},
    map: ?std.StringHashMapUnmanaged(ChallengeEntry) = null,

    fn getMap(self: *ChallengeStore) *std.StringHashMapUnmanaged(ChallengeEntry) {
        if (self.map == null) self.map = std.StringHashMapUnmanaged(ChallengeEntry).empty;
        return &self.map.?;
    }

    /// Mint a per-attempt id, store `challenge` under it with a TTL, and return
    /// the id (the caller emits it as the `authcid` cookie). Returns "" on
    /// allocation failure — the complete step then finds no challenge and rejects.
    pub fn mint(self: *ChallengeStore, challenge: [32]u8) []const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const map = self.getMap();
        const now = clock.timestamp();
        sweepExpiredChallenges(map, now);
        var rand: [16]u8 = undefined;
        infra_random.bytes(&rand);
        const hex = std.fmt.bytesToHex(rand, .lower);
        const cid = store_alloc.dupe(u8, &hex) catch return "";
        map.put(store_alloc, cid, .{ .challenge = challenge, .expiry = now + challenge_ttl_secs }) catch {
            store_alloc.free(cid);
            return "";
        };
        return cid;
    }

    /// Consume the challenge for attempt id `cid` (single-use). Null when the id
    /// is unknown or expired.
    pub fn consume(self: *ChallengeStore, cid: []const u8) ?[32]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        const map = self.getMap();
        const kv = map.fetchRemove(cid) orelse return null;
        defer store_alloc.free(kv.key);
        if (clock.timestamp() > kv.value.expiry) return null;
        return kv.value.challenge;
    }
};

/// Evict expired challenge entries (bounded batch per call). Caller holds the
/// store mutex.
fn sweepExpiredChallenges(map: *std.StringHashMapUnmanaged(ChallengeEntry), now: i64) void {
    var expired: [32][]const u8 = undefined;
    var n: usize = 0;
    var it = map.iterator();
    while (it.next()) |e| {
        if (now > e.value_ptr.expiry and n < expired.len) {
            expired[n] = e.key_ptr.*;
            n += 1;
        }
    }
    for (expired[0..n]) |k| if (map.fetchRemove(k)) |kv| store_alloc.free(kv.key);
}

/// Parse a named cookie value out of the request's `Cookie` header.
fn getCookie(req: *httpz.Request, name: []const u8) ?[]const u8 {
    const cookie_header = req.header("cookie") orelse return null;
    var iter = std.mem.splitSequence(u8, cookie_header, "; ");
    while (iter.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " ");
        if (std.mem.startsWith(u8, trimmed, name) and trimmed.len > name.len and trimmed[name.len] == '=') {
            return trimmed[name.len + 1 ..];
        }
    }
    return null;
}

/// Emit the short-lived `authcid` cookie binding this response's challenge to
/// the follow-up complete request.
fn setChallengeCookie(res: *httpz.Response, arena: std.mem.Allocator, cid: []const u8) !void {
    const cookie = try std.fmt.allocPrint(
        arena,
        challenge_cookie ++ "={s}; Max-Age={d}; Path=/; HttpOnly; SameSite=Strict",
        .{ cid, challenge_ttl_secs },
    );
    res.header("Set-Cookie", cookie);
}

// ── Credential storage ───────────────────────────────────────────────

const StoredCredential = struct {
    id: []const u8, // base64url
    public_key_x: []const u8, // base64url, 32 bytes decoded
    public_key_y: []const u8, // base64url, 32 bytes decoded
    email: []const u8 = "",
    created_at: i64 = 0,
};

fn credentialsPath(allocator: std.mem.Allocator, auth_dir: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/credentials.json", .{auth_dir});
}

fn loadCredentials(allocator: std.mem.Allocator, auth_dir: []const u8) ![]StoredCredential {
    const path = try credentialsPath(allocator, auth_dir);
    defer allocator.free(path);

    const file = infra_fs.cwd().openFile(path, .{}) catch return &[_]StoredCredential{};
    defer file.close();

    const data = file.readToEndAlloc(allocator, 1024 * 1024) catch return &[_]StoredCredential{};

    const parsed = std.json.parseFromSlice(
        []StoredCredential,
        allocator,
        data,
        .{ .allocate = .alloc_always, .ignore_unknown_fields = true },
    ) catch return &[_]StoredCredential{};
    return parsed.value;
}

fn saveCredentials(allocator: std.mem.Allocator, auth_dir: []const u8, creds: []const StoredCredential) !void {
    const path = try credentialsPath(allocator, auth_dir);
    defer allocator.free(path);

    // Ensure auth directory exists
    try infra_fs.cwd().makePath(auth_dir);

    // Build JSON string
    var buf: std.ArrayList(u8) = .empty;
    const bw = buf.writer(allocator);
    try bw.writeAll("[");
    for (creds, 0..) |c, i| {
        if (i > 0) try bw.writeAll(",");
        try bw.print(
            "{{\"id\":\"{s}\",\"public_key_x\":\"{s}\",\"public_key_y\":\"{s}\"," ++
                "\"email\":\"{s}\",\"created_at\":{d}}}",
            .{ c.id, c.public_key_x, c.public_key_y, c.email, c.created_at },
        );
    }
    try bw.writeAll("]");

    oauth_store.writeFileAtomicWithBackup(allocator, path, buf.items);
}

// ── Invite storage ───────────────────────────────────────────────────

const Invite = struct {
    token: []const u8,
    created_by: []const u8, // email of inviter
    expiry: i64,
    /// Role to assign the invited user. Defaults to "writer" if the field is
    /// absent (for backward compatibility with invites written before roles).
    role: []const u8 = "writer",
};

const invite_ttl_seconds: i64 = session_ttl_secs;

fn invitesPath(allocator: std.mem.Allocator, auth_dir: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/invites.json", .{auth_dir});
}

fn loadInvites(allocator: std.mem.Allocator, auth_dir: []const u8) ![]Invite {
    const path = try invitesPath(allocator, auth_dir);
    defer allocator.free(path);

    const file = infra_fs.cwd().openFile(path, .{}) catch return &[_]Invite{};
    defer file.close();

    const data = file.readToEndAlloc(allocator, 256 * 1024) catch return &[_]Invite{};
    const parsed = std.json.parseFromSlice([]Invite, allocator, data, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch return &[_]Invite{};
    return parsed.value;
}

fn saveInvites(allocator: std.mem.Allocator, auth_dir: []const u8, invites: []const Invite) !void {
    const path = try invitesPath(allocator, auth_dir);
    defer allocator.free(path);

    try infra_fs.cwd().makePath(auth_dir);

    var buf: std.ArrayList(u8) = .empty;
    const bw = buf.writer(allocator);
    try bw.writeAll("[");
    for (invites, 0..) |inv, i| {
        if (i > 0) try bw.writeAll(",");
        try bw.print("{{\"token\":\"{s}\",\"created_by\":\"{s}\",\"expiry\":{d},\"role\":\"{s}\"}}", .{ inv.token, inv.created_by, inv.expiry, inv.role });
    }
    try bw.writeAll("]");

    oauth_store.writeFileAtomicWithBackup(allocator, path, buf.items);
}

/// Mint a single-use invite token tied to `created_by`. The token is a
/// 24-byte random hex string; `role` is the role assigned to the user when
/// they redeem the invite. Persists to `auth_dir/invites.json`. Public so
/// the `netlisp mint-invite` CLI command can call it without going through the
/// admin HTTP endpoint (used for out-of-band recovery on locked-out
/// deployments).
pub fn createInvite(allocator: std.mem.Allocator, auth_dir: []const u8, created_by: []const u8, role: []const u8) HandlerError![]const u8 {
    var rand_bytes: [24]u8 = undefined;
    infra_random.bytes(&rand_bytes);
    const hex = std.fmt.bytesToHex(rand_bytes, .lower);
    const token = try allocator.dupe(u8, &hex);

    const now = clock.timestamp();
    const existing = try loadInvites(allocator, auth_dir);
    var invites: std.ArrayList(Invite) = .empty;
    for (existing) |inv| {
        if (now < inv.expiry) try invites.append(allocator, inv);
    }
    try invites.append(allocator, .{
        .token = token,
        .created_by = try allocator.dupe(u8, created_by),
        .expiry = now + invite_ttl_seconds,
        .role = try allocator.dupe(u8, role),
    });
    try saveInvites(allocator, auth_dir, invites.items);
    return token;
}

fn findInvite(allocator: std.mem.Allocator, auth_dir: []const u8, token: []const u8) !?Invite {
    const now = clock.timestamp();
    const invites = try loadInvites(allocator, auth_dir);
    for (invites) |inv| {
        if (std.mem.eql(u8, inv.token, token) and now < inv.expiry) return inv;
    }
    return null;
}

fn consumeInvite(allocator: std.mem.Allocator, auth_dir: []const u8, token: []const u8) !bool {
    const invites = try loadInvites(allocator, auth_dir);
    const now = clock.timestamp();
    var remaining: std.ArrayList(Invite) = .empty;
    var found = false;
    for (invites) |inv| {
        if (std.mem.eql(u8, inv.token, token) and now < inv.expiry) {
            found = true;
            continue; // consume (drop)
        }
        if (now < inv.expiry) try remaining.append(allocator, inv);
    }
    if (!found) return false;
    try saveInvites(allocator, auth_dir, remaining.items);
    return true;
}

// ── Minimal CBOR decoder ─────────────────────────────────────────────

const CborValue = union(enum) {
    unsigned: u64,
    negative: i64,
    bytes: []const u8,
    text: []const u8,
    array: []const CborValue,
    map: []const CborMapEntry,
};

const CborMapEntry = struct {
    key: CborValue,
    value: CborValue,
};

const CborError = error{
    InvalidCbor,
    UnsupportedType,
    OutOfMemory,
};

fn decodeCborArg(allocator: std.mem.Allocator, data: []const u8) CborError!struct { CborValue, usize } {
    if (data.len == 0) return CborError.InvalidCbor;

    const major = data[0] >> cbor_tag_bits;
    const additional = data[0] & cbor_additional_mask;
    var offset: usize = 1;

    // Decode argument value
    var arg: u64 = 0;
    if (additional < cbor_additional_u8) {
        arg = additional;
    } else if (additional == cbor_additional_u8) {
        if (data.len < cbor_header_len_u8) return CborError.InvalidCbor;
        arg = data[1];
        offset = cbor_header_len_u8;
    } else if (additional == cbor_additional_u16) {
        if (data.len < cbor_header_len_u16) return CborError.InvalidCbor;
        arg = std.mem.readInt(u16, data[1..3], .big);
        offset = cbor_header_len_u16;
    } else if (additional == cbor_additional_u32) {
        if (data.len < cbor_header_len_u32) return CborError.InvalidCbor;
        arg = std.mem.readInt(u32, data[1..cbor_header_len_u32], .big);
        offset = cbor_header_len_u32;
    } else if (additional == cbor_additional_u64) {
        if (data.len < cbor_header_len_u64) return CborError.InvalidCbor;
        arg = std.mem.readInt(u64, data[1..cbor_header_len_u64], .big);
        offset = cbor_header_len_u64;
    } else {
        return CborError.InvalidCbor;
    }

    switch (major) {
        0 => { // unsigned int
            return .{ .{ .unsigned = arg }, offset };
        },
        1 => { // negative int
            return .{ .{ .negative = -1 - @as(i64, @intCast(arg)) }, offset };
        },
        2 => { // byte string
            const len: usize = @intCast(arg);
            if (data.len < offset + len) return CborError.InvalidCbor;
            const bytes = data[offset .. offset + len];
            return .{ .{ .bytes = bytes }, offset + len };
        },
        3 => { // text string
            const len: usize = @intCast(arg);
            if (data.len < offset + len) return CborError.InvalidCbor;
            const text = data[offset .. offset + len];
            return .{ .{ .text = text }, offset + len };
        },
        4 => { // array
            const count: usize = @intCast(arg);
            var items = try allocator.alloc(CborValue, count);
            var pos = offset;
            for (0..count) |i| {
                const result = try decodeCborArg(allocator, data[pos..]);
                items[i] = result[0];
                pos += result[1];
            }
            return .{ .{ .array = items }, pos };
        },
        cbor_major_map => { // map
            const count: usize = @intCast(arg);
            var entries = try allocator.alloc(CborMapEntry, count);
            var pos = offset;
            for (0..count) |i| {
                const k = try decodeCborArg(allocator, data[pos..]);
                pos += k[1];
                const v = try decodeCborArg(allocator, data[pos..]);
                pos += v[1];
                entries[i] = .{ .key = k[0], .value = v[0] };
            }
            return .{ .{ .map = entries }, pos };
        },
        else => return CborError.UnsupportedType,
    }
}

fn decodeCbor(allocator: std.mem.Allocator, data: []const u8) CborError!CborValue {
    const result = try decodeCborArg(allocator, data);
    return result[0];
}

fn cborMapGet(m: []const CborMapEntry, key_int: i64) ?CborValue {
    for (m) |entry| {
        switch (entry.key) {
            .unsigned => |v| {
                if (key_int >= 0 and v == @as(u64, @intCast(key_int))) return entry.value;
            },
            .negative => |v| {
                if (v == key_int) return entry.value;
            },
            else => {},
        }
    }
    return null;
}

fn cborMapGetText(m: []const CborMapEntry, key: []const u8) ?CborValue {
    for (m) |entry| {
        switch (entry.key) {
            .text => |t| {
                if (std.mem.eql(u8, t, key)) return entry.value;
            },
            else => {},
        }
    }
    return null;
}

// ── DER signature parsing ────────────────────────────────────────────

fn parseDerInteger(data: []const u8) ?struct { []const u8, usize } {
    if (data.len < 2) return null;
    if (data[0] != 0x02) return null;
    const len: usize = data[1];
    if (data.len < 2 + len) return null;
    return .{ data[2 .. 2 + len], 2 + len };
}

fn padTo32(allocator: std.mem.Allocator, raw: []const u8) !*[32]u8 {
    var buf = try allocator.create([32]u8);
    @memset(buf, 0);
    if (raw.len >= 32) {
        // Take last 32 bytes (skip leading zero padding)
        @memcpy(buf, raw[raw.len - 32 ..]);
    } else {
        // Right-align into 32 bytes
        @memcpy(buf[32 - raw.len ..], raw);
    }
    return buf;
}

fn parseDerSignature(allocator: std.mem.Allocator, der: []const u8) !?[64]u8 {
    if (der.len < 6) return null;
    if (der[0] != 0x30) return null;
    // der[1] is the length of the rest

    const r_result = parseDerInteger(der[2..]) orelse return null;
    const r_raw = r_result[0];
    const r_consumed = r_result[1];

    const s_result = parseDerInteger(der[2 + r_consumed ..]) orelse return null;
    const s_raw = s_result[0];

    const r32 = try padTo32(allocator, r_raw);
    const s32 = try padTo32(allocator, s_raw);

    var sig: [64]u8 = undefined;
    @memcpy(sig[0..32], r32);
    @memcpy(sig[32..64], s32);
    return sig;
}

// ── Base64url helpers ────────────────────────────────────────────────

const b64url = std.base64.url_safe_no_pad;

fn base64urlEncode(allocator: std.mem.Allocator, data: []const u8) ![]const u8 {
    const len = b64url.Encoder.calcSize(data.len);
    const buf = try allocator.alloc(u8, len);
    _ = b64url.Encoder.encode(buf, data);
    return buf;
}

fn base64urlDecode(allocator: std.mem.Allocator, encoded: []const u8) ![]const u8 {
    const len = b64url.Decoder.calcSizeForSlice(encoded) catch return error.InvalidBase64;
    const buf = try allocator.alloc(u8, len);
    b64url.Decoder.decode(buf, encoded) catch return error.InvalidBase64;
    return buf;
}

// ── Auth middleware ──────────────────────────────────────────────────

/// True when the request's *actual TCP peer* is a loopback address
/// (127.0.0.0/8 or ::1). Reads `req.address` (the connected socket), NEVER a
/// request header — a header is fully attacker-controlled.
fn peerIsLoopback(req: *httpz.Request) bool {
    return switch (req.address.any.family) {
        std.posix.AF.INET => (std.mem.bigToNative(u32, req.address.in.sa.addr) >> 24) == 127,
        std.posix.AF.INET6 => blk: {
            const a = req.address.in6.sa.addr;
            // ::1
            var all_zero_hi = true;
            for (a[0..15]) |b| {
                if (b != 0) {
                    all_zero_hi = false;
                    break;
                }
            }
            break :blk all_zero_hi and a[15] == 1;
        },
        else => false,
    };
}

/// True when the request was relayed by a reverse proxy (carries a
/// `Forwarded`/`X-Forwarded-*`/`X-Real-IP` header). The prod server sits behind
/// a same-host proxy, so such requests reach us over loopback even though they
/// originated on the internet — they must NOT be treated as local.
fn viaProxy(req: *httpz.Request) bool {
    return req.header("x-forwarded-for") != null or
        req.header("x-forwarded-host") != null or
        req.header("x-real-ip") != null or
        req.header("forwarded") != null;
}

/// The local-development auth bypass. Requires ALL of: the operator opted in
/// (`ctx.dev_mode`, from the `NETLISP_DEV` env var), the TCP peer is genuinely
/// loopback, and the request did not come through a reverse proxy. Deriving
/// "local" from the `Host` header — the previous behaviour — let any remote
/// client send `Host: localhost` and obtain unauthenticated admin.
fn isLocalhost(ctx: *Server, req: *httpz.Request) bool {
    if (!ctx.dev_mode) return false;
    if (viaProxy(req)) return false;
    return peerIsLoopback(req);
}

/// Pull the `session=<token>` value out of the request's `Cookie` header.
/// Returns null when the header is missing or has no `session=` part.
pub fn getSessionToken(req: *httpz.Request) ?[]const u8 {
    const cookie_header = req.header("cookie") orelse return null;
    // Parse cookie header for session=<token>
    var iter = std.mem.splitSequence(u8, cookie_header, "; ");
    while (iter.next()) |part| {
        const trimmed = std.mem.trim(u8, part, " ");
        if (std.mem.startsWith(u8, trimmed, "session=")) {
            return trimmed["session=".len..];
        }
    }
    return null;
}

fn getBearerToken(req: *httpz.Request) ?[]const u8 {
    const h = req.header("authorization") orelse return null;
    const prefix = "Bearer ";
    if (h.len <= prefix.len) return null;
    if (!std.ascii.eqlIgnoreCase(h[0..prefix.len], prefix)) return null;
    return std.mem.trim(u8, h[prefix.len..], " ");
}

/// True when the `Authorization: Bearer …` header carries a non-expired
/// OAuth access token issued by `oauth_store`. Used to gate the MCP HTTP
/// transport for remote Claude Code clients.
pub fn validateBearerToken(ctx: *Server, req: *httpz.Request) bool {
    const raw = getBearerToken(req) orelse return false;
    const tok = ctx.state.oauth.validateToken(ctx.allocator, ctx.auth_dir, raw) catch return false;
    return tok != null;
}

/// Reply to an unauthenticated `/mcp` request with the RFC 9728 challenge
/// the MCP spec requires. Without this, MCP connectors that follow the
/// 303 to `/auth/login` get HTML, conclude there is no OAuth, and report
/// the server as connected with an empty tool list. Always returns
/// `false` so the middleware caller knows the response is fully written.
fn mcpUnauthorized(req: *httpz.Request, res: *httpz.Response) HandlerError!bool {
    const host = req.header("host") orelse host_localhost;
    const is_https = if (req.header("x-forwarded-proto")) |p|
        std.mem.eql(u8, p, url_scheme_https)
    else
        false;
    const scheme = if (is_https) url_scheme_https else url_scheme_http;
    const challenge = try std.fmt.allocPrint(
        req.arena,
        "Bearer resource_metadata=\"" ++ url_scheme_template ++ "/.well-known/oauth-protected-resource\"",
        .{ scheme, host },
    );
    res.status = 401;
    res.content_type = .JSON;
    res.header("www-authenticate", challenge);
    res.body = "{\"error\":\"unauthorized\",\"error_description\":\"missing or invalid bearer token\"}";
    return false;
}

/// True when the `Authorization: Bearer …` header matches a plugin-issued
/// token from `plugin_tokens`. Plugin tokens live alongside OAuth tokens
/// but are scoped to read-only schematic/PCB consumers.
pub fn validatePluginBearerToken(ctx: *Server, req: *httpz.Request) bool {
    const raw = getBearerToken(req) orelse return false;
    return ctx.state.plugin_tokens.validate(ctx.allocator, ctx.auth_dir, raw);
}

/// If the request carries a valid OAuth bearer token, return the token
/// owner's email. Used by MCP role resolution.
pub fn getBearerEmail(ctx: *Server, req: *httpz.Request) ?[]const u8 {
    const raw = getBearerToken(req) orelse return null;
    const tok = ctx.state.oauth.validateToken(ctx.allocator, ctx.auth_dir, raw) catch return null;
    return if (tok) |t| t.email else null;
}

/// True when the request qualifies for the local-development auth bypass
/// (`ctx.dev_mode` + loopback peer + not proxied). See `isLocalhost`.
pub fn isLocalhostRequest(ctx: *Server, req: *httpz.Request) bool {
    return isLocalhost(ctx, req);
}

/// Remove all stored passkey credentials for an email, and drop any live
/// sessions tied to that email. Called by the admin delete-user flow.
pub fn purgeIdentity(
    sessions_store: *SessionStore,
    allocator: std.mem.Allocator,
    auth_dir: []const u8,
    email: []const u8,
) void {
    const creds = loadCredentials(allocator, auth_dir) catch return;
    var kept: std.ArrayList(StoredCredential) = .empty;
    defer kept.deinit(allocator);
    for (creds) |c| {
        if (!std.mem.eql(u8, c.email, email)) kept.append(allocator, c) catch continue;
    }
    saveCredentials(allocator, auth_dir, kept.items) catch |e| {
        log.warn("saveCredentials failed: {s}", .{@errorName(e)});
    };

    sessions_store.mutex.lock();
    defer sessions_store.mutex.unlock();
    if (sessions_store.map) |*map| {
        var it = map.iterator();
        var to_remove: std.ArrayList([]const u8) = .empty;
        defer to_remove.deinit(allocator);
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.email, email)) {
                to_remove.append(allocator, entry.key_ptr.*) catch continue;
            }
        }
        for (to_remove.items) |tok| _ = map.fetchRemove(tok);
        sessions_store.persist(allocator);
    }
}

/// Resolve the current user's email for OAuth/account flows. Returns the
/// signed-in session's email, or falls back to a dev identity on localhost
/// (matching the existing localhost auth bypass in authMiddleware). Off-
/// localhost requests without a session return null.
pub fn currentEmail(ctx: *Server, req: *httpz.Request) ?[]const u8 {
    if (getSessionToken(req)) |tok| {
        if (ctx.state.sessions.validate(ctx.allocator, ctx.auth_dir, tok)) |em| return em;
    }
    if (isLocalhost(ctx, req)) return "dev@localhost";
    return null;
}

fn isApiPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/api/");
}

/// True when a request mutates server/design/library/board state and therefore
/// requires at least the `writer` role. Safe methods (GET/HEAD/OPTIONS) and a
/// small allowlist of pure-computation POSTs (scoring, routing overlay, dry
/// validation) are open to any authenticated role. Everything else that is
/// POST/PUT/PATCH/DELETE is a mutation. Route registration and this predicate
/// must stay in sync — when in doubt a route is treated as a mutation (deny by
/// default), so a new endpoint is write-gated until explicitly allowlisted.
fn requiresWrite(req: *httpz.Request) bool {
    switch (req.method) {
        .GET, .HEAD, .OPTIONS => return false,
        else => {},
    }
    const read_only_posts = [_][]const u8{
        "/api/pcb-score", // also covers /api/pcb-score-batch
        "/api/pcb-route",
        "/api/pcb-drc", // read-only DRC check of submitted copper
        "/api/validate/",
    };
    for (read_only_posts) |p| {
        if (std.mem.startsWith(u8, req.url.path, p)) return false;
    }
    return true;
}

/// Reject a mutating request from a non-writer session with 403. Returns true
/// when the caller should stop (response written), false to continue dispatch.
fn denyIfInsufficientRole(ctx: *Server, req: *httpz.Request, res: *httpz.Response, email: []const u8) bool {
    if (!requiresWrite(req)) return false;
    const role = ctx.state.users.getRole(ctx.allocator, ctx.auth_dir, email);
    if (role.canWrite()) return false;
    res.status = 403;
    res.content_type = .JSON;
    res.body = "{\"error\":\"forbidden\",\"error_description\":\"writer role required\"}";
    return true;
}

/// Gate every incoming request: allow localhost, auth routes, and
/// requests carrying a valid session cookie or bearer token; redirect
/// others to `/auth/login`. Returns `true` to continue dispatch, `false`
/// when the response has already been written by the middleware.
pub fn authMiddleware(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!bool {
    // Local-dev bypass (opt-in via NETLISP_DEV; loopback + not proxied only).
    if (isLocalhost(ctx, req)) return true;

    // Exempt auth paths
    if (std.mem.startsWith(u8, req.url.path, "/auth/")) return true;

    // Exempt /static/* — the auth pages themselves pull their JS/CSS from
    // there (e.g. /static/auth_login.js). Gating these on a session would
    // 303 them back to /auth/login and the page would render with no
    // event handlers attached. The registry in static_assets.zig is a
    // curated allowlist, so this exempts only assets we explicitly ship.
    if (std.mem.startsWith(u8, req.url.path, "/static/")) return true;

    // OAuth discovery + token/authorize endpoints must be reachable without
    // a logged-in session — Claude Code fetches these before it has a token.
    // RFC 7591 dynamic client registration is in the exempt set: the agent
    // calls /oauth/register before it has any session, and the minted client
    // is unowned until the first user signs in on /oauth/authorize and
    // approves it.
    if (std.mem.startsWith(u8, req.url.path, "/.well-known/oauth-") or
        std.mem.startsWith(u8, req.url.path, "/oauth/token") or
        std.mem.startsWith(u8, req.url.path, "/oauth/authorize") or
        std.mem.startsWith(u8, req.url.path, "/oauth/register")) return true;

    // MCP endpoints accept OAuth bearer tokens issued via /oauth/token.
    // When unauthenticated we MUST return 401 with a WWW-Authenticate
    // challenge advertising the protected-resource metadata URL — that's
    // how an MCP connector discovers our OAuth flow (RFC 9728). Falling
    // through to the generic /auth/login redirect serves HTML to the
    // connector, which then reports the server as "connected" but
    // surfaces zero tools because tools/list never authenticates.
    if (std.mem.startsWith(u8, req.url.path, "/mcp")) {
        if (validateBearerToken(ctx, req)) return true;
        return mcpUnauthorized(req, res);
    }

    // The file-based KiCad-sync applier (`/api/sync-kicad-pcb/`) accepts
    // either a plugin bearer token or an OAuth bearer token. Plugin tokens
    // are minted once via `netlisp mint-plugin-token`; OAuth mirrors the MCP flow.
    if (std.mem.startsWith(u8, req.url.path, "/api/sync-kicad-pcb/")) {
        if (validatePluginBearerToken(ctx, req)) return true;
        if (validateBearerToken(ctx, req)) return true;
    }

    // Check for valid session
    if (getSessionToken(req)) |token| {
        if (ctx.state.sessions.validate(ctx.allocator, ctx.auth_dir, token)) |email| {
            // A valid session proves identity; mutating routes additionally
            // require the writer role. Read + pure-computation routes are open
            // to any authenticated role (incl. reader). Admin-only routes
            // (user/invite/client management) self-check `canAdmin` in-handler.
            if (denyIfInsufficientRole(ctx, req, res, email)) return false;
            return true;
        }
    }

    // Check if credentials exist; if not, redirect to setup
    const creds = try loadCredentials(ctx.allocator, ctx.auth_dir);
    const has_creds = creds.len > 0;

    if (isApiPath(req.url.path)) {
        res.status = 401;
        res.content_type = .JSON;
        res.body = "{\"error\":\"unauthorized\"}";
        return false;
    }

    // Redirect to login or setup
    if (has_creds) {
        res.status = 303;
        res.header(header_location, path_auth_login);
    } else {
        res.status = 303;
        res.header(header_location, "/auth/setup");
    }
    return false;
}

// ── Registration endpoints ───────────────────────────────────────────

/// POST /auth/register/challenge — issue a fresh WebAuthn challenge plus
/// `PublicKeyCredentialCreationOptions` JSON for the browser. Authorises
/// the request via active session (add-device), invite token, or first-
/// user bootstrap when no credentials exist yet.
pub fn registerChallengePage(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const existing = try loadCredentials(ctx.allocator, ctx.auth_dir);
    const q = try req.query();

    // Determine mode and resolve email.
    // Priority: valid session (add-device) > valid invite > bootstrap (no creds exist).
    var email: []const u8 = "";
    var authorized = false;

    if (getSessionToken(req)) |tok| {
        if (ctx.state.sessions.validate(ctx.allocator, ctx.auth_dir, tok)) |session_email| {
            email = session_email;
            authorized = true;
        }
    }

    if (!authorized) {
        if (q.get("invite")) |inv_token| {
            if (try findInvite(ctx.allocator, ctx.auth_dir, inv_token)) |_| {
                const body_email = q.get("email") orelse "";
                if (body_email.len == 0 or std.mem.indexOfScalar(u8, body_email, '@') == null) {
                    res.status = http_bad_request;
                    res.content_type = .JSON;
                    res.body = err_invalid_email_json;
                    return;
                }
                email = body_email;
                authorized = true;
            }
        }
    }

    if (!authorized and existing.len == 0) {
        // Bootstrap: first user
        email = q.get("email") orelse "";
        if (email.len == 0 or std.mem.indexOfScalar(u8, email, '@') == null) {
            res.status = http_bad_request;
            res.content_type = .JSON;
            res.body = err_invalid_email_json;
            return;
        }
        authorized = true;
    }

    if (!authorized) {
        res.status = 403;
        res.content_type = .JSON;
        res.body = "{\"error\":\"registration disabled\"}";
        return;
    }

    var challenge: [32]u8 = undefined;
    infra_random.bytes(&challenge);
    try setChallengeCookie(res, req.arena, ctx.state.challenges.mint(challenge));

    const challenge_b64 = try base64urlEncode(req.arena, &challenge);

    const host = req.header("host") orelse host_localhost;
    var rp_id = host;
    if (std.mem.indexOfScalar(u8, host, ':')) |idx| {
        rp_id = host[0..idx];
    }

    // User ID is a stable hash of the email so multiple passkeys for the same
    // email are associated with the same WebAuthn user handle.
    var user_id_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(email, &user_id_hash, .{});
    const user_id_b64 = try base64urlEncode(req.arena, &user_id_hash);

    // Build excludeCredentials list: passkeys already registered for this email
    // so the browser won't offer to re-use them.
    var exclude_buf: std.ArrayList(u8) = .empty;
    const xw = exclude_buf.writer(req.arena);
    try xw.writeAll("[");
    var first_excl = true;
    for (existing) |c| {
        if (std.mem.eql(u8, c.email, email)) {
            if (!first_excl) try xw.writeAll(",");
            try xw.print("{{\"type\":\"public-key\",\"id\":\"{s}\"}}", .{c.id});
            first_excl = false;
        }
    }
    try xw.writeAll("]");

    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(req.arena);
    try w.print(
        "{{\"challenge\":\"{s}\",\"rp\":{{\"name\":\"Netlisp\",\"id\":\"{s}\"}}," ++
            "\"user\":{{\"id\":\"{s}\",\"name\":\"{s}\",\"displayName\":\"{s}\"}}," ++
            "\"pubKeyCredParams\":[{{\"type\":\"public-key\",\"alg\":-7}}]," ++
            "\"authenticatorSelection\":{{\"residentKey\":\"preferred\"," ++
            "\"userVerification\":\"preferred\"}}," ++
            "\"excludeCredentials\":{s},\"timeout\":60000}}",
        .{ challenge_b64, rp_id, user_id_b64, email, email, exclude_buf.items },
    );

    res.content_type = .JSON;
    res.body = buf.items;
}

/// POST /auth/register/complete — verify the WebAuthn attestation against
/// the pending challenge, persist the new passkey under its email, and set
/// a session cookie so the browser is logged in once registration succeeds.
pub fn registerCompletePage(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const body = req.body() orelse {
        res.status = http_bad_request;
        res.body = err_missing_body_json;
        res.content_type = .JSON;
        return;
    };

    const parsed = std.json.parseFromSlice(std.json.Value, req.arena, body, .{}) catch {
        res.status = http_bad_request;
        res.body = err_invalid_json_json;
        res.content_type = .JSON;
        return;
    };
    const root = parsed.value;

    // Extract fields from the JSON
    const cred_id_b64 = (root.object.get("id") orelse {
        res.status = http_bad_request;
        res.body = err_missing_id_json;
        res.content_type = .JSON;
        return;
    }).string;

    const response_obj = (root.object.get("response") orelse {
        res.status = http_bad_request;
        res.body = "{\"error\":\"missing response\"}";
        res.content_type = .JSON;
        return;
    }).object;

    const attestation_b64 = (response_obj.get("attestationObject") orelse {
        res.status = http_bad_request;
        res.body = "{\"error\":\"missing attestationObject\"}";
        res.content_type = .JSON;
        return;
    }).string;

    const client_data_b64 = (response_obj.get("clientDataJSON") orelse {
        res.status = http_bad_request;
        res.body = "{\"error\":\"missing clientDataJSON\"}";
        res.content_type = .JSON;
        return;
    }).string;

    // Decode attestationObject
    const attestation_raw = base64urlDecode(req.arena, attestation_b64) catch {
        res.status = http_bad_request;
        res.body = "{\"error\":\"invalid attestation base64\"}";
        res.content_type = .JSON;
        return;
    };

    // Decode clientDataJSON and verify challenge
    const client_data_raw = base64urlDecode(req.arena, client_data_b64) catch {
        res.status = http_bad_request;
        res.body = "{\"error\":\"invalid clientData base64\"}";
        res.content_type = .JSON;
        return;
    };

    const client_data_parsed = std.json.parseFromSlice(std.json.Value, req.arena, client_data_raw, .{}) catch {
        res.status = http_bad_request;
        res.body = err_invalid_client_data;
        res.content_type = .JSON;
        return;
    };

    if (client_data_parsed.value != .object) {
        res.status = http_bad_request;
        res.body = err_invalid_client_data;
        res.content_type = .JSON;
        return;
    }
    // Verify type
    const cd_type = (client_data_parsed.value.object.get("type") orelse {
        res.status = http_bad_request;
        res.body = "{\"error\":\"missing type in clientData\"}";
        res.content_type = .JSON;
        return;
    }).string;
    if (!std.mem.eql(u8, cd_type, "webauthn.create")) {
        res.status = http_bad_request;
        res.body = "{\"error\":\"wrong ceremony type\"}";
        res.content_type = .JSON;
        return;
    }

    // Verify challenge
    const cd_challenge = (client_data_parsed.value.object.get("challenge") orelse {
        res.status = http_bad_request;
        res.body = "{\"error\":\"missing challenge in clientData\"}";
        res.content_type = .JSON;
        return;
    }).string;

    const stored_challenge = ctx.state.challenges.consume(getCookie(req, challenge_cookie) orelse "") orelse {
        res.status = http_bad_request;
        res.body = "{\"error\":\"no pending challenge\"}";
        res.content_type = .JSON;
        return;
    };

    const expected_challenge_b64 = try base64urlEncode(req.arena, &stored_challenge);
    if (!std.mem.eql(u8, cd_challenge, expected_challenge_b64)) {
        res.status = http_bad_request;
        res.body = "{\"error\":\"challenge mismatch\"}";
        res.content_type = .JSON;
        return;
    }

    // Parse CBOR attestationObject
    const cbor_val = decodeCbor(req.arena, attestation_raw) catch {
        res.status = http_bad_request;
        res.body = "{\"error\":\"invalid CBOR\"}";
        res.content_type = .JSON;
        return;
    };

    const att_map = switch (cbor_val) {
        .map => |m| m,
        else => {
            res.status = http_bad_request;
            res.body = "{\"error\":\"attestation not a map\"}";
            res.content_type = .JSON;
            return;
        },
    };

    // Get authData
    const auth_data_val = cborMapGetText(att_map, "authData") orelse {
        res.status = http_bad_request;
        res.body = "{\"error\":\"missing authData\"}";
        res.content_type = .JSON;
        return;
    };
    const auth_data = switch (auth_data_val) {
        .bytes => |b| b,
        else => {
            res.status = http_bad_request;
            res.body = "{\"error\":\"authData not bytes\"}";
            res.content_type = .JSON;
            return;
        },
    };

    // Parse authenticatorData:
    // 32 bytes rpIdHash + 1 byte flags + 4 bytes signCount + attestedCredentialData
    if (auth_data.len < auth_data_header_len) {
        res.status = http_bad_request;
        res.body = "{\"error\":\"authData too short\"}";
        res.content_type = .JSON;
        return;
    }

    const flags = auth_data[auth_data_rpid_hash_len];
    if (flags & 0x40 == 0) {
        res.status = http_bad_request;
        res.body = "{\"error\":\"no attested credential data\"}";
        res.content_type = .JSON;
        return;
    }

    // Skip: 32 rpIdHash + 1 flags + 4 signCount + 16 AAGUID = 53
    if (auth_data.len < auth_data_cred_data_offset) {
        res.status = http_bad_request;
        res.body = "{\"error\":\"authData too short for credential\"}";
        res.content_type = .JSON;
        return;
    }

    const cred_id_len = std.mem.readInt(u16, auth_data[auth_data_cred_len_offset..auth_data_cred_data_offset], .big);
    const cred_data_start: usize = auth_data_cred_data_offset + cred_id_len;
    if (auth_data.len < cred_data_start) {
        res.status = http_bad_request;
        res.body = "{\"error\":\"authData too short for cred id\"}";
        res.content_type = .JSON;
        return;
    }

    // Parse COSE public key (remainder of authData after credential ID)
    const cose_key_bytes = auth_data[cred_data_start..];
    const cose_key_cbor = decodeCbor(req.arena, cose_key_bytes) catch {
        res.status = http_bad_request;
        res.body = "{\"error\":\"invalid COSE key CBOR\"}";
        res.content_type = .JSON;
        return;
    };

    const key_map = switch (cose_key_cbor) {
        .map => |m| m,
        else => {
            res.status = http_bad_request;
            res.body = "{\"error\":\"COSE key not a map\"}";
            res.content_type = .JSON;
            return;
        },
    };

    // Extract x coordinate (key -2)
    const x_val = cborMapGet(key_map, -2) orelse {
        res.status = http_bad_request;
        res.body = "{\"error\":\"missing x in COSE key\"}";
        res.content_type = .JSON;
        return;
    };
    const x_bytes = switch (x_val) {
        .bytes => |b| b,
        else => {
            res.status = http_bad_request;
            res.body = "{\"error\":\"x not bytes\"}";
            res.content_type = .JSON;
            return;
        },
    };

    // Extract y coordinate (key -3)
    const y_val = cborMapGet(key_map, -3) orelse {
        res.status = http_bad_request;
        res.body = "{\"error\":\"missing y in COSE key\"}";
        res.content_type = .JSON;
        return;
    };
    const y_bytes = switch (y_val) {
        .bytes => |b| b,
        else => {
            res.status = http_bad_request;
            res.body = "{\"error\":\"y not bytes\"}";
            res.content_type = .JSON;
            return;
        },
    };

    if (x_bytes.len != 32 or y_bytes.len != 32) {
        res.status = http_bad_request;
        res.body = "{\"error\":\"invalid key coordinate length\"}";
        res.content_type = .JSON;
        return;
    }

    // Determine registration mode and resolve target email.
    const existing = try loadCredentials(ctx.allocator, ctx.auth_dir);
    const body_email_val = root.object.get("email");
    const body_email = if (body_email_val) |ev| (if (ev == .string) ev.string else "") else "";
    const invite_val = root.object.get("invite");
    const invite_token = if (invite_val) |iv| (if (iv == .string) iv.string else "") else "";

    var resolved_email: []const u8 = "";
    var invite_to_consume: []const u8 = "";
    var invited_role: users.Role = .writer;

    const session_token_opt = getSessionToken(req);
    if (session_token_opt) |stok| {
        if (ctx.state.sessions.validate(ctx.allocator, ctx.auth_dir, stok)) |session_email| {
            resolved_email = session_email;
        }
    }

    if (resolved_email.len == 0 and invite_token.len > 0) {
        if (try findInvite(ctx.allocator, ctx.auth_dir, invite_token)) |inv| {
            if (body_email.len == 0 or std.mem.indexOfScalar(u8, body_email, '@') == null) {
                res.status = http_bad_request;
                res.body = err_invalid_email_json;
                res.content_type = .JSON;
                return;
            }
            resolved_email = body_email;
            invite_to_consume = invite_token;
            invited_role = users.Role.fromString(inv.role) orelse .writer;
        }
    }

    if (resolved_email.len == 0 and existing.len == 0) {
        // Bootstrap
        if (body_email.len == 0 or std.mem.indexOfScalar(u8, body_email, '@') == null) {
            res.status = http_bad_request;
            res.body = err_invalid_email_json;
            res.content_type = .JSON;
            return;
        }
        resolved_email = body_email;
    }

    if (resolved_email.len == 0) {
        res.status = 403;
        res.body = "{\"error\":\"registration disabled\"}";
        res.content_type = .JSON;
        return;
    }

    // Store credential
    const x_b64 = try base64urlEncode(ctx.allocator, x_bytes);
    const y_b64 = try base64urlEncode(ctx.allocator, y_bytes);
    const id_dup = try ctx.allocator.dupe(u8, cred_id_b64);
    const email_dup = try ctx.allocator.dupe(u8, resolved_email);

    var creds: std.ArrayList(StoredCredential) = .empty;
    for (existing) |c| {
        try creds.append(ctx.allocator, c);
    }

    try creds.append(ctx.allocator, .{
        .id = id_dup,
        .public_key_x = x_b64,
        .public_key_y = y_b64,
        .email = email_dup,
        .created_at = clock.timestamp(),
    });

    saveCredentials(ctx.allocator, ctx.auth_dir, creds.items) catch {
        res.status = http_internal_error;
        res.body = "{\"error\":\"failed to save credentials\"}";
        res.content_type = .JSON;
        return;
    };

    if (invite_to_consume.len > 0) {
        _ = consumeInvite(ctx.allocator, ctx.auth_dir, invite_to_consume) catch |e| {
            log.warn("consumeInvite failed: {s}", .{@errorName(e)});
        };
    }

    // Ensure a user record exists with the correct role. ensureUser is a no-op
    // if this email already has a record (e.g. when a logged-in user adds
    // another passkey to their own account).
    _ = ctx.state.users.ensureUser(ctx.allocator, ctx.auth_dir, resolved_email, invited_role) catch |e| {
        log.warn("ensureUser failed: {s}", .{@errorName(e)});
    };

    // Create a session for the newly registered user (unless they already have one)
    if (session_token_opt == null) {
        const token = try ctx.state.sessions.create(ctx.allocator, ctx.auth_dir, resolved_email);
        const cookie = try std.fmt.allocPrint(req.arena, session_cookie_fmt, .{token});
        res.header(header_set_cookie, cookie);
    }

    res.content_type = .JSON;
    res.body = ok_json_true;
}

// ── Authentication endpoints ─────────────────────────────────────────

/// POST /auth/login/challenge — issue a fresh WebAuthn assertion challenge
/// and the `allowCredentials` list (optionally filtered by `?email=`) so
/// the browser can prompt the user to tap their passkey.
pub fn loginChallengePage(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    var challenge: [32]u8 = undefined;
    infra_random.bytes(&challenge);
    try setChallengeCookie(res, req.arena, ctx.state.challenges.mint(challenge));

    const challenge_b64 = try base64urlEncode(req.arena, &challenge);

    const q = try req.query();
    const email_filter = q.get("email") orelse "";

    const creds = try loadCredentials(ctx.allocator, ctx.auth_dir);

    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(req.arena);
    try w.print("{{\"challenge\":\"{s}\",\"allowCredentials\":[", .{challenge_b64});
    var first = true;
    for (creds) |cred| {
        // If an email filter is supplied, only include matching credentials.
        // No filter → include everything (supports synced/resident-key flows).
        if (email_filter.len > 0 and !std.mem.eql(u8, cred.email, email_filter)) continue;
        if (!first) try w.writeAll(",");
        try w.print("{{\"type\":\"public-key\",\"id\":\"{s}\"}}", .{cred.id});
        first = false;
    }

    const host = req.header("host") orelse host_localhost;
    var rp_id = host;
    if (std.mem.indexOfScalar(u8, host, ':')) |idx| {
        rp_id = host[0..idx];
    }

    try w.print("],\"rpId\":\"{s}\",\"timeout\":60000,\"userVerification\":\"preferred\"}}", .{rp_id});

    res.content_type = .JSON;
    res.body = buf.items;
}

/// POST /auth/login/complete — verify the WebAuthn assertion against the
/// pending challenge and the stored credential's public key, then mint a
/// session cookie tied to the credential's email on success.
pub fn loginCompletePage(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const body = req.body() orelse {
        res.status = http_bad_request;
        res.body = err_missing_body_json;
        res.content_type = .JSON;
        return;
    };

    const parsed = std.json.parseFromSlice(std.json.Value, req.arena, body, .{}) catch {
        res.status = http_bad_request;
        res.body = err_invalid_json_json;
        res.content_type = .JSON;
        return;
    };
    const root = parsed.value;

    const cred_id = (root.object.get("id") orelse {
        res.status = http_bad_request;
        res.body = err_missing_id_json;
        res.content_type = .JSON;
        return;
    }).string;

    const response_obj = (root.object.get("response") orelse {
        res.status = http_bad_request;
        res.body = "{\"error\":\"missing response\"}";
        res.content_type = .JSON;
        return;
    }).object;

    const auth_data_b64 = (response_obj.get("authenticatorData") orelse {
        res.status = http_bad_request;
        res.body = "{\"error\":\"missing authenticatorData\"}";
        res.content_type = .JSON;
        return;
    }).string;

    const client_data_b64 = (response_obj.get("clientDataJSON") orelse {
        res.status = http_bad_request;
        res.body = "{\"error\":\"missing clientDataJSON\"}";
        res.content_type = .JSON;
        return;
    }).string;

    const sig_b64 = (response_obj.get("signature") orelse {
        res.status = http_bad_request;
        res.body = "{\"error\":\"missing signature\"}";
        res.content_type = .JSON;
        return;
    }).string;

    // Decode all base64url fields
    const auth_data = base64urlDecode(req.arena, auth_data_b64) catch {
        res.status = http_bad_request;
        res.body = "{\"error\":\"invalid authenticatorData base64\"}";
        res.content_type = .JSON;
        return;
    };

    const client_data_raw = base64urlDecode(req.arena, client_data_b64) catch {
        res.status = http_bad_request;
        res.body = "{\"error\":\"invalid clientDataJSON base64\"}";
        res.content_type = .JSON;
        return;
    };

    const sig_raw = base64urlDecode(req.arena, sig_b64) catch {
        res.status = http_bad_request;
        res.body = "{\"error\":\"invalid signature base64\"}";
        res.content_type = .JSON;
        return;
    };

    // Parse and verify clientDataJSON
    const client_data_parsed = std.json.parseFromSlice(std.json.Value, req.arena, client_data_raw, .{}) catch {
        res.status = http_bad_request;
        res.body = err_invalid_client_data;
        res.content_type = .JSON;
        return;
    };

    if (client_data_parsed.value != .object) {
        res.status = http_bad_request;
        res.body = err_invalid_client_data;
        res.content_type = .JSON;
        return;
    }
    // Verify type
    const cd_type = (client_data_parsed.value.object.get("type") orelse {
        res.status = http_bad_request;
        res.body = "{\"error\":\"missing type\"}";
        res.content_type = .JSON;
        return;
    }).string;
    if (!std.mem.eql(u8, cd_type, "webauthn.get")) {
        res.status = http_bad_request;
        res.body = "{\"error\":\"wrong ceremony type\"}";
        res.content_type = .JSON;
        return;
    }

    // Verify origin
    const cd_origin = (client_data_parsed.value.object.get("origin") orelse {
        res.status = http_bad_request;
        res.body = "{\"error\":\"missing origin\"}";
        res.content_type = .JSON;
        return;
    }).string;

    const host = req.header("host") orelse host_localhost;
    // Construct expected origins (http and https)
    const expected_https = try std.fmt.allocPrint(req.arena, url_scheme_template, .{ url_scheme_https, host });
    const expected_http = try std.fmt.allocPrint(req.arena, url_scheme_template, .{ url_scheme_http, host });
    if (!std.mem.eql(u8, cd_origin, expected_https) and !std.mem.eql(u8, cd_origin, expected_http)) {
        res.status = http_bad_request;
        res.body = "{\"error\":\"origin mismatch\"}";
        res.content_type = .JSON;
        return;
    }

    // Verify challenge
    const cd_challenge = (client_data_parsed.value.object.get("challenge") orelse {
        res.status = http_bad_request;
        res.body = "{\"error\":\"missing challenge\"}";
        res.content_type = .JSON;
        return;
    }).string;

    const stored_challenge = ctx.state.challenges.consume(getCookie(req, challenge_cookie) orelse "") orelse {
        res.status = http_bad_request;
        res.body = "{\"error\":\"no pending challenge\"}";
        res.content_type = .JSON;
        return;
    };

    const expected_challenge_b64 = try base64urlEncode(req.arena, &stored_challenge);
    if (!std.mem.eql(u8, cd_challenge, expected_challenge_b64)) {
        res.status = http_bad_request;
        res.body = "{\"error\":\"challenge mismatch\"}";
        res.content_type = .JSON;
        return;
    }

    // Find the matching credential
    const creds = try loadCredentials(ctx.allocator, ctx.auth_dir);
    var matching_cred: ?StoredCredential = null;
    for (creds) |cred| {
        if (std.mem.eql(u8, cred.id, cred_id)) {
            matching_cred = cred;
            break;
        }
    }

    const cred = matching_cred orelse {
        res.status = http_bad_request;
        res.body = "{\"error\":\"unknown credential\"}";
        res.content_type = .JSON;
        return;
    };

    // Reconstruct the public key
    const x_bytes = base64urlDecode(req.arena, cred.public_key_x) catch {
        res.status = http_internal_error;
        res.body = "{\"error\":\"invalid stored key x\"}";
        res.content_type = .JSON;
        return;
    };
    const y_bytes = base64urlDecode(req.arena, cred.public_key_y) catch {
        res.status = http_internal_error;
        res.body = "{\"error\":\"invalid stored key y\"}";
        res.content_type = .JSON;
        return;
    };

    if (x_bytes.len != 32 or y_bytes.len != 32) {
        res.status = http_internal_error;
        res.body = "{\"error\":\"invalid stored key length\"}";
        res.content_type = .JSON;
        return;
    }

    // Build SEC1 uncompressed point: 0x04 || x || y
    var sec1: [sec1_uncompressed_len]u8 = undefined;
    sec1[0] = 0x04;
    @memcpy(sec1[1..sec1_tag_and_x_len], x_bytes);
    @memcpy(sec1[sec1_tag_and_x_len..sec1_uncompressed_len], y_bytes);

    const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
    const pubkey = EcdsaP256.PublicKey.fromSec1(&sec1) catch {
        res.status = http_internal_error;
        res.body = "{\"error\":\"invalid public key\"}";
        res.content_type = .JSON;
        return;
    };

    // Compute SHA-256(clientDataJSON)
    var client_data_hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(client_data_raw, &client_data_hash, .{});

    // Verification message = authenticatorData || SHA-256(clientDataJSON)
    const verify_msg = try req.arena.alloc(u8, auth_data.len + 32);
    @memcpy(verify_msg[0..auth_data.len], auth_data);
    @memcpy(verify_msg[auth_data.len..], &client_data_hash);

    // Parse DER signature to raw r||s
    const sig_rs = parseDerSignature(req.arena, sig_raw) catch {
        res.status = http_bad_request;
        res.body = "{\"error\":\"invalid signature format\"}";
        res.content_type = .JSON;
        return;
    } orelse {
        res.status = http_bad_request;
        res.body = "{\"error\":\"could not parse DER signature\"}";
        res.content_type = .JSON;
        return;
    };

    const signature = EcdsaP256.Signature.fromBytes(sig_rs);

    // Verify the signature
    signature.verify(verify_msg, pubkey) catch {
        res.status = http_bad_request;
        res.body = "{\"error\":\"signature verification failed\"}";
        res.content_type = .JSON;
        return;
    };

    // Success - create session tied to the credential's email
    const session_email = if (cred.email.len > 0) cred.email else "";
    const token = try ctx.state.sessions.create(ctx.allocator, ctx.auth_dir, session_email);
    const cookie = try std.fmt.allocPrint(req.arena, session_cookie_fmt, .{token});
    res.header(header_set_cookie, cookie);

    res.content_type = .JSON;
    res.body = ok_json_true;
}

// ── HTML Pages ───────────────────────────────────────────────────────

pub const page_style =
    \\* { margin: 0; padding: 0; box-sizing: border-box; }
    \\body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
    \\  background: #0d1117; color: #c9d1d9; display: flex; justify-content: center;
    \\  align-items: center; min-height: 100vh; }
    \\.auth-card { background: #161b22; border: 1px solid #21262d; border-radius: 12px;
    \\  padding: 2.5rem; max-width: 400px; width: 90%; text-align: center; }
    \\.auth-card h1 { color: #f0f6fc; font-size: 1.5rem; margin-bottom: 0.5rem; }
    \\.auth-card p { color: #8b949e; font-size: 0.9rem; margin-bottom: 1.5rem; }
    \\.auth-btn { background: #238636; color: #fff; border: none; border-radius: 6px;
    \\  padding: 0.75rem 1.5rem; font-size: 1rem; cursor: pointer; width: 100%;
    \\  font-weight: 600; transition: background 0.15s; }
    \\.auth-btn:hover { background: #2ea043; }
    \\.auth-btn:disabled { background: #21262d; color: #484f58; cursor: not-allowed; }
    \\.status { margin-top: 1rem; font-size: 0.85rem; min-height: 1.2em; }
    \\.status.error { color: #f85149; }
    \\.status.ok { color: #3fb950; }
    \\.brand { color: #58a6ff; font-weight: 600; font-size: 0.9rem; margin-bottom: 1.5rem; display: block; }
    \\.link { color: #58a6ff; text-decoration: none; font-size: 0.85rem; display: inline-block; margin-top: 1rem; }
    \\.link:hover { text-decoration: underline; }
;

pub const b64url_js =
    \\function b64urlToBytes(b64) {
    \\  let s = b64.replace(/-/g, '+').replace(/_/g, '/');
    \\  while (s.length % 4) s += '=';
    \\  const raw = atob(s);
    \\  const arr = new Uint8Array(raw.length);
    \\  for (let i = 0; i < raw.length; i++) arr[i] = raw.charCodeAt(i);
    \\  return arr;
    \\}
    \\function bytesToB64url(buf) {
    \\  const bytes = new Uint8Array(buf);
    \\  let s = '';
    \\  for (let i = 0; i < bytes.length; i++) s += String.fromCharCode(bytes[i]);
    \\  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
    \\}
;

/// GET /auth/login — render the sign-in HTML: an email field plus a button
/// that drives the WebAuthn `navigator.credentials.get` flow against the
/// challenge/complete endpoints. Markup lives in `templates/auth.zt`; the
/// per-page JS is served from `/static/auth_login.js`.
pub fn loginPage(ctx: *Server, _: *httpz.Request, res: *httpz.Response) HandlerError!void {
    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    try auth_template.Login.render(.{}, &aw.writer);
    res.content_type = .HTML;
    res.body = aw.written();
}

/// GET /auth/setup — first-user bootstrap page. Redirects to `/auth/login`
/// when at least one credential already exists; otherwise renders the
/// passkey-registration UI for the initial admin account. Markup lives in
/// `templates/auth.zt`; per-page JS is served from `/static/auth_setup.js`.
pub fn setupPage(ctx: *Server, _: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const existing = try loadCredentials(ctx.allocator, ctx.auth_dir);
    if (existing.len > 0) {
        res.status = 303;
        res.header(header_location, path_auth_login);
        return;
    }
    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    try auth_template.Setup.render(.{}, &aw.writer);
    res.content_type = .HTML;
    res.body = aw.written();
}

// ── Session / account management ─────────────────────────────────────

fn requireSession(ctx: *Server, req: *httpz.Request, res: *httpz.Response) ?[]const u8 {
    const tok = getSessionToken(req) orelse {
        res.status = 401;
        res.content_type = .JSON;
        res.body = "{\"error\":\"not signed in\"}";
        return null;
    };
    const email = ctx.state.sessions.validate(ctx.allocator, ctx.auth_dir, tok) orelse {
        res.status = 401;
        res.content_type = .JSON;
        res.body = "{\"error\":\"invalid session\"}";
        return null;
    };
    return email;
}

/// POST /auth/logout — invalidate the current session both server-side
/// (drop from `sessions.json`) and client-side (overwrite the cookie with
/// `Max-Age=0`).
pub fn logoutApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    if (getSessionToken(req)) |tok| {
        ctx.state.sessions.delete(ctx.allocator, ctx.auth_dir, tok);
    }
    res.header(header_set_cookie, "session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0");
    res.content_type = .JSON;
    res.body = ok_json_true;
}

/// GET /api/auth/credentials — return the signed-in user's registered
/// passkeys (id, email, created_at) as JSON for the account page's
/// device-management list.
pub fn listCredentialsApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const email = requireSession(ctx, req, res) orelse return;

    const creds = try loadCredentials(ctx.allocator, ctx.auth_dir);

    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(req.arena);
    try w.print("{{\"email\":\"{s}\",\"credentials\":[", .{email});
    var first = true;
    for (creds) |c| {
        if (!std.mem.eql(u8, c.email, email)) continue;
        if (!first) try w.writeAll(",");
        try w.print("{{\"id\":\"{s}\",\"created_at\":{d}}}", .{ c.id, c.created_at });
        first = false;
    }
    try w.writeAll("]}");

    res.content_type = .JSON;
    res.body = buf.items;
}

/// POST /api/auth/credentials/delete — drop a single passkey by id from
/// `credentials.json`. Refuses to delete the user's last remaining passkey
/// to avoid locking themselves out.
pub fn deleteCredentialApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const email = requireSession(ctx, req, res) orelse return;

    const body = req.body() orelse {
        res.status = http_bad_request;
        res.content_type = .JSON;
        res.body = err_missing_body_json;
        return;
    };
    const parsed = std.json.parseFromSlice(std.json.Value, req.arena, body, .{}) catch {
        res.status = http_bad_request;
        res.content_type = .JSON;
        res.body = err_invalid_json_json;
        return;
    };
    if (parsed.value != .object) {
        res.status = http_bad_request;
        res.content_type = .JSON;
        res.body = err_invalid_json_json;
        return;
    }
    const id_val = parsed.value.object.get("id") orelse {
        res.status = http_bad_request;
        res.content_type = .JSON;
        res.body = err_missing_id_json;
        return;
    };
    if (id_val != .string) {
        res.status = http_bad_request;
        res.content_type = .JSON;
        res.body = "{\"error\":\"id must be string\"}";
        return;
    }
    const target_id = id_val.string;

    const existing = try loadCredentials(ctx.allocator, ctx.auth_dir);

    var user_count: usize = 0;
    for (existing) |c| {
        if (std.mem.eql(u8, c.email, email)) user_count += 1;
    }
    if (user_count <= 1) {
        res.status = http_bad_request;
        res.content_type = .JSON;
        res.body = "{\"error\":\"cannot delete your only passkey\"}";
        return;
    }

    var kept: std.ArrayList(StoredCredential) = .empty;
    var removed = false;
    for (existing) |c| {
        if (std.mem.eql(u8, c.id, target_id) and std.mem.eql(u8, c.email, email)) {
            removed = true;
            continue;
        }
        try kept.append(ctx.allocator, c);
    }

    if (!removed) {
        res.status = http_not_found;
        res.content_type = .JSON;
        res.body = "{\"error\":\"credential not found\"}";
        return;
    }

    saveCredentials(ctx.allocator, ctx.auth_dir, kept.items) catch {
        res.status = http_internal_error;
        res.content_type = .JSON;
        res.body = "{\"error\":\"failed to save\"}";
        return;
    };

    res.content_type = .JSON;
    res.body = ok_json_true;
}

/// POST /api/auth/invites — admin-only: mint a 7-day single-use invite token
/// (defaulting to writer role) the recipient can redeem at
/// `/auth/invite/<token>` to register their first passkey.
pub fn createInviteApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const email = currentEmail(ctx, req) orelse {
        res.status = 401;
        res.content_type = .JSON;
        res.body = "{\"error\":\"sign in required\"}";
        return;
    };

    // Admin-only.
    if (!ctx.state.users.getRole(ctx.allocator, ctx.auth_dir, email).canAdmin()) {
        res.status = 403;
        res.content_type = .JSON;
        res.body = "{\"error\":\"admin role required\"}";
        return;
    }

    var role_str: []const u8 = "writer";
    if (req.body()) |body| {
        if (body.len > 0) {
            if (std.json.parseFromSlice(std.json.Value, req.arena, body, .{})) |parsed| {
                if (parsed.value == .object) {
                    if (parsed.value.object.get("role")) |rv| {
                        if (rv == .string and users.Role.fromString(rv.string) != null) {
                            role_str = rv.string;
                        }
                    }
                }
            } else |_| {}
        }
    }

    const token = try createInvite(ctx.allocator, ctx.auth_dir, email, role_str);

    var buf: std.ArrayList(u8) = .empty;
    const w = buf.writer(req.arena);
    try w.print("{{\"ok\":true,\"token\":\"{s}\",\"path\":\"/auth/invite/{s}\",\"role\":\"{s}\"}}", .{ token, token, role_str });

    res.content_type = .JSON;
    res.body = buf.items;
}

/// GET /auth/invite/:token — render the passkey-registration UI for an
/// invite recipient. Shows an "expired" page when the token is missing,
/// consumed, or past its TTL; otherwise drives the WebAuthn create flow.
pub fn invitePage(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const path = req.url.path;
    const prefix = "/auth/invite/";
    if (!std.mem.startsWith(u8, path, prefix)) {
        res.status = http_not_found;
        res.body = "not found";
        return;
    }
    const token = path[prefix.len..];
    if (token.len == 0) {
        res.status = http_not_found;
        res.body = "not found";
        return;
    }

    const found = try findInvite(ctx.allocator, ctx.auth_dir, token);
    var aw: std.Io.Writer.Allocating = .init(req.arena);
    if (found == null) {
        try auth_template.InviteExpired.render(.{}, &aw.writer);
    } else {
        try auth_template.InviteAccept.render(.{token}, &aw.writer);
    }
    res.content_type = .HTML;
    res.body = aw.written();
}

// ── Tests ──────────────────────────────────────────────────────────────

// The session store used to be a file-scope global, so a session created in
// any server was visible to every other server (and every test) in the
// process — no per-test or multi-instance servers were possible. It is now
// instance state on `ServerState`; this proves two servers stay independent.
// spec: serve - A session minted on one ServerState instance is absent from an independent instance
test "session stores are isolated per ServerState instance" {
    const a = std.testing.allocator;

    // Two independent servers, each with its own on-disk session file, so the
    // isolation holds in memory AND on disk.
    var tmp_a = std.testing.tmpDir(.{});
    defer tmp_a.cleanup();
    var tmp_b = std.testing.tmpDir(.{});
    defer tmp_b.cleanup();
    const dir_a = try tmp_a.dir.realpathAlloc(a, ".");
    defer a.free(dir_a);
    const dir_b = try tmp_b.dir.realpathAlloc(a, ".");
    defer a.free(dir_b);

    var state_a: serve_root.ServerState = .{};
    var state_b: serve_root.ServerState = .{};

    // A session minted on server A resolves on A...
    const token = try state_a.sessions.create(a, dir_a, "alice@example.com");
    try std.testing.expectEqualStrings("alice@example.com", state_a.sessions.validate(a, dir_a, token).?);

    // ...but is invisible to server B — no shared global, so B's table is empty.
    try std.testing.expect(state_b.sessions.validate(a, dir_b, token) == null);
}
