const std = @import("std");
const httpz = @import("httpz");
const infra_fs = @import("../infra/fs.zig");
const clock = @import("../infra/clock.zig");
const log = @import("../infra/log.zig");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;
const oauth_store = @import("oauth_store.zig");
const plugin_tokens = @import("plugin_tokens.zig");
const users = @import("users.zig");
const infra_random = @import("../infra/random.zig");

// ── Constants ─────────────────────────────────────────────────────
const HTTP_NOT_FOUND: u16 = 404;
const HTTP_BAD_REQUEST: u16 = 400;
const HTTP_INTERNAL_ERROR: u16 = 500;

// Time (use std.time constants to avoid bare-60 magic-number violations)
const SECONDS_PER_DAY: i64 = std.time.s_per_day;
const SESSION_TTL_DAYS: i64 = 7;
const SESSION_TTL_SECS: i64 = SESSION_TTL_DAYS * SECONDS_PER_DAY;

// Token sizes
const SESSION_RAND_BYTES: usize = 32;
const INVITE_RAND_BYTES: usize = 24;

// File-size limits
const MAX_SESSION_FILE_BYTES: usize = 256 * 1024;
const MAX_INVITES_FILE_BYTES: usize = 256 * 1024;

// WebAuthn authenticatorData layout (RFC 8809 §6)
const AUTH_DATA_RPID_HASH_LEN: usize = 32;
const AUTH_DATA_FLAGS_LEN: usize = 1;
const AUTH_DATA_SIGN_COUNT_LEN: usize = 4;
const AUTH_DATA_HEADER_LEN: usize = AUTH_DATA_RPID_HASH_LEN + AUTH_DATA_FLAGS_LEN + AUTH_DATA_SIGN_COUNT_LEN; // 37
const AUTH_DATA_AAGUID_LEN: usize = 16;
const AUTH_DATA_CRED_LEN_OFFSET: usize = AUTH_DATA_HEADER_LEN + AUTH_DATA_AAGUID_LEN; // 53
const AUTH_DATA_CRED_DATA_OFFSET: usize = AUTH_DATA_CRED_LEN_OFFSET + 2; // 55

// EC P-256 SEC1 uncompressed point: 1 tag byte + 32 X + 32 Y
const SEC1_UNCOMPRESSED_LEN: usize = 65;
const SEC1_TAG_AND_X_LEN: usize = 33;

// CBOR encoding constants (RFC 8949)
const CBOR_TAG_BITS: u3 = 5;
const CBOR_ADDITIONAL_MASK: u8 = 0x1f;
const CBOR_MAJOR_MAP: u8 = 5;
const CBOR_ADDITIONAL_U8: u8 = 24;
const CBOR_ADDITIONAL_U16: u8 = 25;
const CBOR_ADDITIONAL_U32: u8 = 26;
const CBOR_ADDITIONAL_U64: u8 = 27;
const CBOR_HEADER_LEN_U8: usize = 2;
const CBOR_HEADER_LEN_U16: usize = 3;
const CBOR_HEADER_LEN_U32: usize = 5;
const CBOR_HEADER_LEN_U64: usize = 9;

// URL scheme prefixes (extracted to satisfy ban-hardcoded-paths)
const URL_SCHEME_HTTPS = "https";
const URL_SCHEME_HTTP = "http";
const URL_SCHEME_TEMPLATE = "{s}://{s}";

// Repeated string literals (HTML/JSON templates and headers)
const HEADER_LOCATION = "location";
const HEADER_SET_COOKIE = "set-cookie";
const PATH_AUTH_LOGIN = "/auth/login";
const HOST_LOCALHOST = "localhost";

const HTML_DOCTYPE_HEAD = "<!DOCTYPE html><html><head><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">";
const HTML_STYLE_HEAD_BODY_OPEN = "</style></head><body>";
const HTML_AUTH_CARD_OPEN = "<div class=\"auth-card\">";
const HTML_STATUS_DIV = "<div class=\"status\" id=\"status\"></div>";
const HTML_BRAND_SPAN = "<span class=\"brand\">Canopy EDA</span>";
const HTML_EMAIL_INPUT = "<input type=\"email\" id=\"email\" placeholder=\"Email address\" required ";
const HTML_INPUT_STYLE_DARK =
    "style=\"width:100%;box-sizing:border-box;padding:10px 12px;" ++
    "background:#0d1117;border:1px solid #30363d;border-radius:6px;" ++
    "color:#c9d1d9;font-size:14px;margin-bottom:12px;outline:none\" />";
const HTML_INPUT_STYLE_MID =
    "style=\"width:100%;box-sizing:border-box;padding:10px 12px;" ++
    "background:#161b22;border:1px solid #30363d;border-radius:6px;" ++
    "color:#c9d1d9;font-size:14px;margin-bottom:12px;outline:none\" />";

const MANAGE_PAGE_EXTRA_CSS =
    "\n.row { display:flex; justify-content:space-between; align-items:center;" ++
    " padding:10px 12px; border:1px solid #21262d; border-radius:6px; margin-bottom:8px; }" ++
    "\n.row .meta { color:#8b949e; font-size:0.85rem; }" ++
    "\n.row button { background:#21262d; color:#f85149; border:1px solid #30363d;" ++
    " border-radius:4px; padding:4px 10px; cursor:pointer; font-size:0.8rem; }" ++
    "\n.row button:hover { background:#2d333b; }" ++
    "\n.section-title { color:#8b949e; font-size:0.8rem; text-transform:uppercase;" ++
    " letter-spacing:0.05em; margin:1.5rem 0 0.5rem; }" ++
    "\n.btn-sec { background:#21262d; border:1px solid #30363d; color:#c9d1d9; }" ++
    "\n.btn-sec:hover { background:#2d333b; }" ++
    "\n.invite-box { background:#0d1117; border:1px solid #30363d; border-radius:6px;" ++
    " padding:10px; margin-top:8px; font-size:0.8rem; word-break:break-all; }" ++
    "\n.user-bar { display:flex; justify-content:space-between; align-items:center;" ++
    " margin-bottom:1rem; padding-bottom:1rem; border-bottom:1px solid #21262d; }" ++
    "\n.user-bar .email { color:#8b949e; font-size:0.85rem; }";
const HTML_SCRIPT_OPEN = "<script>";
const HTML_SCRIPT_BODY_CLOSE = "</script></body></html>";

const ERR_INVALID_EMAIL_JSON = "{\"error\":\"invalid email\"}";
const ERR_INVALID_JSON_JSON = "{\"error\":\"invalid json\"}";
const ERR_MISSING_BODY_JSON = "{\"error\":\"missing body\"}";
const ERR_MISSING_ID_JSON = "{\"error\":\"missing id\"}";
const OK_JSON_TRUE = "{\"ok\":true}";

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

var sessions_mutex: std.Thread.Mutex = .{};
var sessions: ?std.StringHashMap(SessionData) = null;
var sessions_auth_dir: ?[]const u8 = null;

fn getSessionMap(allocator: std.mem.Allocator, auth_dir: []const u8) *std.StringHashMap(SessionData) {
    if (sessions == null) {
        sessions = std.StringHashMap(SessionData).init(allocator);
        sessions_auth_dir = auth_dir;
        // Load persisted sessions
        loadSessions(allocator, auth_dir);
    }
    return &sessions.?;
}

fn sessionsPath(allocator: std.mem.Allocator, auth_dir: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/sessions.json", .{auth_dir});
}

fn loadSessions(allocator: std.mem.Allocator, auth_dir: []const u8) void {
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
            const token_dup = allocator.dupe(u8, entry.token) catch continue;
            const email_dup = allocator.dupe(u8, entry.email) catch continue;
            sessions.?.put(token_dup, .{ .email = email_dup, .expiry = entry.expiry }) catch continue;
        }
    }
}

fn persistSessions(allocator: std.mem.Allocator) void {
    const auth_dir = sessions_auth_dir orelse return;
    const path = sessionsPath(allocator, auth_dir) catch return;
    defer allocator.free(path);
    infra_fs.cwd().makePath(auth_dir) catch return;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(allocator);
    w.writeAll("[") catch return;
    var map = &sessions.?;
    var it = map.iterator();
    var first = true;
    while (it.next()) |entry| {
        if (!first) w.writeAll(",") catch return;
        w.print("{{\"token\":\"{s}\",\"email\":\"{s}\",\"expiry\":{d}}}", .{ entry.key_ptr.*, entry.value_ptr.email, entry.value_ptr.expiry }) catch return;
        first = false;
    }
    w.writeAll("]") catch return;
    const file = infra_fs.cwd().createFile(path, .{}) catch return;
    defer file.close();
    file.writeAll(buf.items) catch return;
}

/// Mint a new 7-day session for `email` (32-byte hex random token), persist
/// it to `projects/.../auth/sessions.json`, and return the cookie value the
/// caller should send back as `eda_session`.
pub fn createSession(allocator: std.mem.Allocator, auth_dir: []const u8, email: []const u8) std.mem.Allocator.Error![]const u8 {
    var rand_bytes: [32]u8 = undefined;
    infra_random.bytes(&rand_bytes);
    const hex = std.fmt.bytesToHex(rand_bytes, .lower);
    const token = try allocator.dupe(u8, &hex);
    const email_dup = try allocator.dupe(u8, email);

    const now = clock.timestamp();
    const expiry = now + SESSION_TTL_SECS;

    sessions_mutex.lock();
    defer sessions_mutex.unlock();
    const map = getSessionMap(allocator, auth_dir);
    try map.put(token, .{ .email = email_dup, .expiry = expiry });
    persistSessions(allocator);
    return token;
}

/// Look up `token` in the persisted session map and return the associated
/// email if it has not yet expired. Expired entries are evicted as a side
/// effect; returns `null` for unknown or expired tokens.
pub fn validateSession(allocator: std.mem.Allocator, auth_dir: []const u8, token: []const u8) ?[]const u8 {
    sessions_mutex.lock();
    defer sessions_mutex.unlock();
    const map = getSessionMap(allocator, auth_dir);
    const entry = map.get(token) orelse return null;
    const now = clock.timestamp();
    if (now > entry.expiry) {
        _ = map.fetchRemove(token);
        persistSessions(allocator);
        return null;
    }
    return entry.email;
}

/// Drop `token` from the in-memory map and persist the change to disk so a
/// stolen cookie cannot reauthenticate. Used by `logoutApi` and during
/// credential-revocation flows.
pub fn deleteSession(allocator: std.mem.Allocator, auth_dir: []const u8, token: []const u8) void {
    sessions_mutex.lock();
    defer sessions_mutex.unlock();
    const map = getSessionMap(allocator, auth_dir);
    _ = map.fetchRemove(token);
    persistSessions(allocator);
}

// ── Challenge store ──────────────────────────────────────────────────

var challenge_mutex: std.Thread.Mutex = .{};
var pending_challenge: ?[32]u8 = null;

fn storePendingChallenge(challenge: [32]u8) void {
    challenge_mutex.lock();
    defer challenge_mutex.unlock();
    pending_challenge = challenge;
}

fn takePendingChallenge() ?[32]u8 {
    challenge_mutex.lock();
    defer challenge_mutex.unlock();
    const c = pending_challenge orelse return null;
    pending_challenge = null;
    return c;
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
    var buf: std.ArrayListUnmanaged(u8) = .empty;
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

    const file = try infra_fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(buf.items);
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

const INVITE_TTL_SECONDS: i64 = SESSION_TTL_SECS;

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

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const bw = buf.writer(allocator);
    try bw.writeAll("[");
    for (invites, 0..) |inv, i| {
        if (i > 0) try bw.writeAll(",");
        try bw.print("{{\"token\":\"{s}\",\"created_by\":\"{s}\",\"expiry\":{d},\"role\":\"{s}\"}}", .{ inv.token, inv.created_by, inv.expiry, inv.role });
    }
    try bw.writeAll("]");

    const file = try infra_fs.cwd().createFile(path, .{});
    defer file.close();
    try file.writeAll(buf.items);
}

fn createInvite(allocator: std.mem.Allocator, auth_dir: []const u8, created_by: []const u8, role: []const u8) ![]const u8 {
    var rand_bytes: [24]u8 = undefined;
    infra_random.bytes(&rand_bytes);
    const hex = std.fmt.bytesToHex(rand_bytes, .lower);
    const token = try allocator.dupe(u8, &hex);

    const now = clock.timestamp();
    const existing = try loadInvites(allocator, auth_dir);
    var invites: std.ArrayListUnmanaged(Invite) = .empty;
    for (existing) |inv| {
        if (now < inv.expiry) try invites.append(allocator, inv);
    }
    try invites.append(allocator, .{
        .token = token,
        .created_by = try allocator.dupe(u8, created_by),
        .expiry = now + INVITE_TTL_SECONDS,
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
    var remaining: std.ArrayListUnmanaged(Invite) = .empty;
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

    const major = data[0] >> CBOR_TAG_BITS;
    const additional = data[0] & CBOR_ADDITIONAL_MASK;
    var offset: usize = 1;

    // Decode argument value
    var arg: u64 = 0;
    if (additional < CBOR_ADDITIONAL_U8) {
        arg = additional;
    } else if (additional == CBOR_ADDITIONAL_U8) {
        if (data.len < CBOR_HEADER_LEN_U8) return CborError.InvalidCbor;
        arg = data[1];
        offset = CBOR_HEADER_LEN_U8;
    } else if (additional == CBOR_ADDITIONAL_U16) {
        if (data.len < CBOR_HEADER_LEN_U16) return CborError.InvalidCbor;
        arg = std.mem.readInt(u16, data[1..3], .big);
        offset = CBOR_HEADER_LEN_U16;
    } else if (additional == CBOR_ADDITIONAL_U32) {
        if (data.len < CBOR_HEADER_LEN_U32) return CborError.InvalidCbor;
        arg = std.mem.readInt(u32, data[1..CBOR_HEADER_LEN_U32], .big);
        offset = CBOR_HEADER_LEN_U32;
    } else if (additional == CBOR_ADDITIONAL_U64) {
        if (data.len < CBOR_HEADER_LEN_U64) return CborError.InvalidCbor;
        arg = std.mem.readInt(u64, data[1..CBOR_HEADER_LEN_U64], .big);
        offset = CBOR_HEADER_LEN_U64;
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
        CBOR_MAJOR_MAP => { // map
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

fn isLocalhost(req: *httpz.Request) bool {
    // Check peer address via the host header for loopback detection
    const host = req.header("host") orelse return false;
    // Strip port if present
    var hostname = host;
    if (std.mem.indexOfScalar(u8, host, ':')) |idx| {
        hostname = host[0..idx];
    }
    if (std.mem.eql(u8, hostname, "127.0.0.1")) return true;
    if (std.mem.eql(u8, hostname, "::1")) return true;
    if (std.mem.eql(u8, hostname, HOST_LOCALHOST)) return true;
    return false;
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
pub fn validateBearerToken(ctx: *Handler, req: *httpz.Request) bool {
    const raw = getBearerToken(req) orelse return false;
    const tok = oauth_store.validateToken(ctx.allocator, ctx.auth_dir, raw) catch return false;
    return tok != null;
}

/// True when the `Authorization: Bearer …` header matches a plugin-issued
/// token from `plugin_tokens`. Plugin tokens live alongside OAuth tokens
/// but are scoped to read-only schematic/PCB consumers.
pub fn validatePluginBearerToken(ctx: *Handler, req: *httpz.Request) bool {
    const raw = getBearerToken(req) orelse return false;
    return plugin_tokens.validate(ctx.allocator, ctx.auth_dir, raw);
}

/// If the request carries a valid OAuth bearer token, return the token
/// owner's email. Used by MCP role resolution.
pub fn getBearerEmail(ctx: *Handler, req: *httpz.Request) ?[]const u8 {
    const raw = getBearerToken(req) orelse return null;
    const tok = oauth_store.validateToken(ctx.allocator, ctx.auth_dir, raw) catch return null;
    return if (tok) |t| t.email else null;
}

/// True when the `Host` header refers to 127.0.0.1, ::1, or `localhost`.
/// Used by the auth middleware to bypass passkey enforcement during local
/// development so the dev server is usable without an account setup.
pub fn isLocalhostRequest(req: *httpz.Request) bool {
    return isLocalhost(req);
}

/// Remove all stored passkey credentials for an email, and drop any live
/// sessions tied to that email. Called by the admin delete-user flow.
pub fn purgeIdentity(allocator: std.mem.Allocator, auth_dir: []const u8, email: []const u8) void {
    const creds = loadCredentials(allocator, auth_dir) catch return;
    var kept: std.ArrayListUnmanaged(StoredCredential) = .empty;
    defer kept.deinit(allocator);
    for (creds) |c| {
        if (!std.mem.eql(u8, c.email, email)) kept.append(allocator, c) catch continue;
    }
    saveCredentials(allocator, auth_dir, kept.items) catch |e| {
        log.warn("saveCredentials failed: {s}", .{@errorName(e)});
    };

    sessions_mutex.lock();
    defer sessions_mutex.unlock();
    if (sessions) |*map| {
        var it = map.iterator();
        var to_remove: std.ArrayListUnmanaged([]const u8) = .empty;
        defer to_remove.deinit(allocator);
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.email, email)) {
                to_remove.append(allocator, entry.key_ptr.*) catch continue;
            }
        }
        for (to_remove.items) |tok| _ = map.fetchRemove(tok);
        persistSessions(allocator);
    }
}

/// Resolve the current user's email for OAuth/account flows. Returns the
/// signed-in session's email, or falls back to a dev identity on localhost
/// (matching the existing localhost auth bypass in authMiddleware). Off-
/// localhost requests without a session return null.
pub fn currentEmail(ctx: *Handler, req: *httpz.Request) ?[]const u8 {
    if (getSessionToken(req)) |tok| {
        if (validateSession(ctx.allocator, ctx.auth_dir, tok)) |em| return em;
    }
    if (isLocalhost(req)) return "dev@localhost";
    return null;
}

fn isApiPath(path: []const u8) bool {
    return std.mem.startsWith(u8, path, "/api/");
}

/// Gate every incoming request: allow localhost, auth/SPA routes, and
/// requests carrying a valid session cookie or bearer token; redirect
/// others to `/auth/login`. Returns `true` to continue dispatch, `false`
/// when the response has already been written by the middleware.
pub fn authMiddleware(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!bool {
    // Allow localhost without auth
    if (isLocalhost(req)) return true;

    // Exempt auth paths
    if (std.mem.startsWith(u8, req.url.path, "/auth/")) return true;

    // SPA shell + its assets are public; the APIs it calls still enforce auth
    // at their own check points.
    if (std.mem.eql(u8, req.url.path, "/v2") or
        std.mem.startsWith(u8, req.url.path, "/v2/")) return true;

    // OAuth discovery + token/authorize endpoints must be reachable without
    // a logged-in session — Claude Code fetches these before it has a token.
    if (std.mem.startsWith(u8, req.url.path, "/.well-known/oauth-")) return true;
    if (std.mem.startsWith(u8, req.url.path, "/oauth/token")) return true;
    if (std.mem.startsWith(u8, req.url.path, "/oauth/authorize")) return true;

    // MCP endpoints accept OAuth bearer tokens issued via /oauth/token.
    if (std.mem.startsWith(u8, req.url.path, "/mcp")) {
        if (validateBearerToken(ctx, req)) return true;
    }

    // Incremental-sync endpoints accept either a plugin bearer token or an
    // OAuth bearer token. Plugin tokens are minted once via `eda mint-plugin-
    // token`; OAuth is what the KiCad-side IPC sync plugin (tools/kicad-sync-
    // plugin/) uses, mirroring the MCP flow. Both are scoped to these read-
    // only sync routes; other APIs still require a session.
    if (std.mem.startsWith(u8, req.url.path, "/api/sync-manifest/") or
        std.mem.startsWith(u8, req.url.path, "/api/netlist/") or
        std.mem.startsWith(u8, req.url.path, "/api/object/"))
    {
        if (validatePluginBearerToken(ctx, req)) return true;
        if (validateBearerToken(ctx, req)) return true;
    }

    // Check for valid session
    if (getSessionToken(req)) |token| {
        if (validateSession(ctx.allocator, ctx.auth_dir, token) != null) return true;
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
        res.header(HEADER_LOCATION, PATH_AUTH_LOGIN);
    } else {
        res.status = 303;
        res.header(HEADER_LOCATION, "/auth/setup");
    }
    return false;
}

// ── Registration endpoints ───────────────────────────────────────────

/// POST /auth/register/challenge — issue a fresh WebAuthn challenge plus
/// `PublicKeyCredentialCreationOptions` JSON for the browser. Authorises
/// the request via active session (add-device), invite token, or first-
/// user bootstrap when no credentials exist yet.
pub fn registerChallengePage(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const existing = try loadCredentials(ctx.allocator, ctx.auth_dir);
    const q = try req.query();

    // Determine mode and resolve email.
    // Priority: valid session (add-device) > valid invite > bootstrap (no creds exist).
    var email: []const u8 = "";
    var authorized = false;

    if (getSessionToken(req)) |tok| {
        if (validateSession(ctx.allocator, ctx.auth_dir, tok)) |session_email| {
            email = session_email;
            authorized = true;
        }
    }

    if (!authorized) {
        if (q.get("invite")) |inv_token| {
            if (try findInvite(ctx.allocator, ctx.auth_dir, inv_token)) |_| {
                const body_email = q.get("email") orelse "";
                if (body_email.len == 0 or std.mem.indexOfScalar(u8, body_email, '@') == null) {
                    res.status = HTTP_BAD_REQUEST;
                    res.content_type = .JSON;
                    res.body = ERR_INVALID_EMAIL_JSON;
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
            res.status = HTTP_BAD_REQUEST;
            res.content_type = .JSON;
            res.body = ERR_INVALID_EMAIL_JSON;
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
    storePendingChallenge(challenge);

    const challenge_b64 = try base64urlEncode(req.arena, &challenge);

    const host = req.header("host") orelse HOST_LOCALHOST;
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
    var exclude_buf: std.ArrayListUnmanaged(u8) = .empty;
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

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(req.arena);
    try w.print(
        "{{\"challenge\":\"{s}\",\"rp\":{{\"name\":\"Canopy EDA\",\"id\":\"{s}\"}}," ++
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
pub fn registerCompletePage(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const body = req.body() orelse {
        res.status = HTTP_BAD_REQUEST;
        res.body = ERR_MISSING_BODY_JSON;
        res.content_type = .JSON;
        return;
    };

    const parsed = std.json.parseFromSlice(std.json.Value, req.arena, body, .{}) catch {
        res.status = HTTP_BAD_REQUEST;
        res.body = ERR_INVALID_JSON_JSON;
        res.content_type = .JSON;
        return;
    };
    const root = parsed.value;

    // Extract fields from the JSON
    const cred_id_b64 = (root.object.get("id") orelse {
        res.status = HTTP_BAD_REQUEST;
        res.body = ERR_MISSING_ID_JSON;
        res.content_type = .JSON;
        return;
    }).string;

    const response_obj = (root.object.get("response") orelse {
        res.status = HTTP_BAD_REQUEST;
        res.body = "{\"error\":\"missing response\"}";
        res.content_type = .JSON;
        return;
    }).object;

    const attestation_b64 = (response_obj.get("attestationObject") orelse {
        res.status = HTTP_BAD_REQUEST;
        res.body = "{\"error\":\"missing attestationObject\"}";
        res.content_type = .JSON;
        return;
    }).string;

    const client_data_b64 = (response_obj.get("clientDataJSON") orelse {
        res.status = HTTP_BAD_REQUEST;
        res.body = "{\"error\":\"missing clientDataJSON\"}";
        res.content_type = .JSON;
        return;
    }).string;

    // Decode attestationObject
    const attestation_raw = base64urlDecode(req.arena, attestation_b64) catch {
        res.status = HTTP_BAD_REQUEST;
        res.body = "{\"error\":\"invalid attestation base64\"}";
        res.content_type = .JSON;
        return;
    };

    // Decode clientDataJSON and verify challenge
    const client_data_raw = base64urlDecode(req.arena, client_data_b64) catch {
        res.status = HTTP_BAD_REQUEST;
        res.body = "{\"error\":\"invalid clientData base64\"}";
        res.content_type = .JSON;
        return;
    };

    const client_data_parsed = std.json.parseFromSlice(std.json.Value, req.arena, client_data_raw, .{}) catch {
        res.status = HTTP_BAD_REQUEST;
        res.body = "{\"error\":\"invalid clientDataJSON\"}";
        res.content_type = .JSON;
        return;
    };

    // Verify type
    const cd_type = (client_data_parsed.value.object.get("type") orelse {
        res.status = HTTP_BAD_REQUEST;
        res.body = "{\"error\":\"missing type in clientData\"}";
        res.content_type = .JSON;
        return;
    }).string;
    if (!std.mem.eql(u8, cd_type, "webauthn.create")) {
        res.status = HTTP_BAD_REQUEST;
        res.body = "{\"error\":\"wrong ceremony type\"}";
        res.content_type = .JSON;
        return;
    }

    // Verify challenge
    const cd_challenge = (client_data_parsed.value.object.get("challenge") orelse {
        res.status = HTTP_BAD_REQUEST;
        res.body = "{\"error\":\"missing challenge in clientData\"}";
        res.content_type = .JSON;
        return;
    }).string;

    const stored_challenge = takePendingChallenge() orelse {
        res.status = HTTP_BAD_REQUEST;
        res.body = "{\"error\":\"no pending challenge\"}";
        res.content_type = .JSON;
        return;
    };

    const expected_challenge_b64 = try base64urlEncode(req.arena, &stored_challenge);
    if (!std.mem.eql(u8, cd_challenge, expected_challenge_b64)) {
        res.status = HTTP_BAD_REQUEST;
        res.body = "{\"error\":\"challenge mismatch\"}";
        res.content_type = .JSON;
        return;
    }

    // Parse CBOR attestationObject
    const cbor_val = decodeCbor(req.arena, attestation_raw) catch {
        res.status = HTTP_BAD_REQUEST;
        res.body = "{\"error\":\"invalid CBOR\"}";
        res.content_type = .JSON;
        return;
    };

    const att_map = switch (cbor_val) {
        .map => |m| m,
        else => {
            res.status = HTTP_BAD_REQUEST;
            res.body = "{\"error\":\"attestation not a map\"}";
            res.content_type = .JSON;
            return;
        },
    };

    // Get authData
    const auth_data_val = cborMapGetText(att_map, "authData") orelse {
        res.status = HTTP_BAD_REQUEST;
        res.body = "{\"error\":\"missing authData\"}";
        res.content_type = .JSON;
        return;
    };
    const auth_data = switch (auth_data_val) {
        .bytes => |b| b,
        else => {
            res.status = HTTP_BAD_REQUEST;
            res.body = "{\"error\":\"authData not bytes\"}";
            res.content_type = .JSON;
            return;
        },
    };

    // Parse authenticatorData:
    // 32 bytes rpIdHash + 1 byte flags + 4 bytes signCount + attestedCredentialData
    if (auth_data.len < AUTH_DATA_HEADER_LEN) {
        res.status = HTTP_BAD_REQUEST;
        res.body = "{\"error\":\"authData too short\"}";
        res.content_type = .JSON;
        return;
    }

    const flags = auth_data[AUTH_DATA_RPID_HASH_LEN];
    if (flags & 0x40 == 0) {
        res.status = HTTP_BAD_REQUEST;
        res.body = "{\"error\":\"no attested credential data\"}";
        res.content_type = .JSON;
        return;
    }

    // Skip: 32 rpIdHash + 1 flags + 4 signCount + 16 AAGUID = 53
    if (auth_data.len < AUTH_DATA_CRED_DATA_OFFSET) {
        res.status = HTTP_BAD_REQUEST;
        res.body = "{\"error\":\"authData too short for credential\"}";
        res.content_type = .JSON;
        return;
    }

    const cred_id_len = std.mem.readInt(u16, auth_data[AUTH_DATA_CRED_LEN_OFFSET..AUTH_DATA_CRED_DATA_OFFSET], .big);
    const cred_data_start: usize = AUTH_DATA_CRED_DATA_OFFSET + cred_id_len;
    if (auth_data.len < cred_data_start) {
        res.status = HTTP_BAD_REQUEST;
        res.body = "{\"error\":\"authData too short for cred id\"}";
        res.content_type = .JSON;
        return;
    }

    // Parse COSE public key (remainder of authData after credential ID)
    const cose_key_bytes = auth_data[cred_data_start..];
    const cose_key_cbor = decodeCbor(req.arena, cose_key_bytes) catch {
        res.status = HTTP_BAD_REQUEST;
        res.body = "{\"error\":\"invalid COSE key CBOR\"}";
        res.content_type = .JSON;
        return;
    };

    const key_map = switch (cose_key_cbor) {
        .map => |m| m,
        else => {
            res.status = HTTP_BAD_REQUEST;
            res.body = "{\"error\":\"COSE key not a map\"}";
            res.content_type = .JSON;
            return;
        },
    };

    // Extract x coordinate (key -2)
    const x_val = cborMapGet(key_map, -2) orelse {
        res.status = HTTP_BAD_REQUEST;
        res.body = "{\"error\":\"missing x in COSE key\"}";
        res.content_type = .JSON;
        return;
    };
    const x_bytes = switch (x_val) {
        .bytes => |b| b,
        else => {
            res.status = HTTP_BAD_REQUEST;
            res.body = "{\"error\":\"x not bytes\"}";
            res.content_type = .JSON;
            return;
        },
    };

    // Extract y coordinate (key -3)
    const y_val = cborMapGet(key_map, -3) orelse {
        res.status = HTTP_BAD_REQUEST;
        res.body = "{\"error\":\"missing y in COSE key\"}";
        res.content_type = .JSON;
        return;
    };
    const y_bytes = switch (y_val) {
        .bytes => |b| b,
        else => {
            res.status = HTTP_BAD_REQUEST;
            res.body = "{\"error\":\"y not bytes\"}";
            res.content_type = .JSON;
            return;
        },
    };

    if (x_bytes.len != 32 or y_bytes.len != 32) {
        res.status = HTTP_BAD_REQUEST;
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
        if (validateSession(ctx.allocator, ctx.auth_dir, stok)) |session_email| {
            resolved_email = session_email;
        }
    }

    if (resolved_email.len == 0 and invite_token.len > 0) {
        if (try findInvite(ctx.allocator, ctx.auth_dir, invite_token)) |inv| {
            if (body_email.len == 0 or std.mem.indexOfScalar(u8, body_email, '@') == null) {
                res.status = HTTP_BAD_REQUEST;
                res.body = ERR_INVALID_EMAIL_JSON;
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
            res.status = HTTP_BAD_REQUEST;
            res.body = ERR_INVALID_EMAIL_JSON;
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

    var creds: std.ArrayListUnmanaged(StoredCredential) = .empty;
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
        res.status = HTTP_INTERNAL_ERROR;
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
    _ = users.ensureUser(ctx.allocator, ctx.auth_dir, resolved_email, invited_role) catch |e| {
        log.warn("ensureUser failed: {s}", .{@errorName(e)});
    };

    // Create a session for the newly registered user (unless they already have one)
    if (session_token_opt == null) {
        const token = try createSession(ctx.allocator, ctx.auth_dir, resolved_email);
        const cookie = try std.fmt.allocPrint(req.arena, "session={s}; Path=/; HttpOnly; SameSite=Strict; Max-Age=604800", .{token});
        res.header(HEADER_SET_COOKIE, cookie);
    }

    res.content_type = .JSON;
    res.body = OK_JSON_TRUE;
}

// ── Authentication endpoints ─────────────────────────────────────────

/// POST /auth/login/challenge — issue a fresh WebAuthn assertion challenge
/// and the `allowCredentials` list (optionally filtered by `?email=`) so
/// the browser can prompt the user to tap their passkey.
pub fn loginChallengePage(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    var challenge: [32]u8 = undefined;
    infra_random.bytes(&challenge);
    storePendingChallenge(challenge);

    const challenge_b64 = try base64urlEncode(req.arena, &challenge);

    const q = try req.query();
    const email_filter = q.get("email") orelse "";

    const creds = try loadCredentials(ctx.allocator, ctx.auth_dir);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
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

    const host = req.header("host") orelse HOST_LOCALHOST;
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
pub fn loginCompletePage(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const body = req.body() orelse {
        res.status = HTTP_BAD_REQUEST;
        res.body = ERR_MISSING_BODY_JSON;
        res.content_type = .JSON;
        return;
    };

    const parsed = std.json.parseFromSlice(std.json.Value, req.arena, body, .{}) catch {
        res.status = HTTP_BAD_REQUEST;
        res.body = ERR_INVALID_JSON_JSON;
        res.content_type = .JSON;
        return;
    };
    const root = parsed.value;

    const cred_id = (root.object.get("id") orelse {
        res.status = HTTP_BAD_REQUEST;
        res.body = ERR_MISSING_ID_JSON;
        res.content_type = .JSON;
        return;
    }).string;

    const response_obj = (root.object.get("response") orelse {
        res.status = HTTP_BAD_REQUEST;
        res.body = "{\"error\":\"missing response\"}";
        res.content_type = .JSON;
        return;
    }).object;

    const auth_data_b64 = (response_obj.get("authenticatorData") orelse {
        res.status = HTTP_BAD_REQUEST;
        res.body = "{\"error\":\"missing authenticatorData\"}";
        res.content_type = .JSON;
        return;
    }).string;

    const client_data_b64 = (response_obj.get("clientDataJSON") orelse {
        res.status = HTTP_BAD_REQUEST;
        res.body = "{\"error\":\"missing clientDataJSON\"}";
        res.content_type = .JSON;
        return;
    }).string;

    const sig_b64 = (response_obj.get("signature") orelse {
        res.status = HTTP_BAD_REQUEST;
        res.body = "{\"error\":\"missing signature\"}";
        res.content_type = .JSON;
        return;
    }).string;

    // Decode all base64url fields
    const auth_data = base64urlDecode(req.arena, auth_data_b64) catch {
        res.status = HTTP_BAD_REQUEST;
        res.body = "{\"error\":\"invalid authenticatorData base64\"}";
        res.content_type = .JSON;
        return;
    };

    const client_data_raw = base64urlDecode(req.arena, client_data_b64) catch {
        res.status = HTTP_BAD_REQUEST;
        res.body = "{\"error\":\"invalid clientDataJSON base64\"}";
        res.content_type = .JSON;
        return;
    };

    const sig_raw = base64urlDecode(req.arena, sig_b64) catch {
        res.status = HTTP_BAD_REQUEST;
        res.body = "{\"error\":\"invalid signature base64\"}";
        res.content_type = .JSON;
        return;
    };

    // Parse and verify clientDataJSON
    const client_data_parsed = std.json.parseFromSlice(std.json.Value, req.arena, client_data_raw, .{}) catch {
        res.status = HTTP_BAD_REQUEST;
        res.body = "{\"error\":\"invalid clientDataJSON\"}";
        res.content_type = .JSON;
        return;
    };

    // Verify type
    const cd_type = (client_data_parsed.value.object.get("type") orelse {
        res.status = HTTP_BAD_REQUEST;
        res.body = "{\"error\":\"missing type\"}";
        res.content_type = .JSON;
        return;
    }).string;
    if (!std.mem.eql(u8, cd_type, "webauthn.get")) {
        res.status = HTTP_BAD_REQUEST;
        res.body = "{\"error\":\"wrong ceremony type\"}";
        res.content_type = .JSON;
        return;
    }

    // Verify origin
    const cd_origin = (client_data_parsed.value.object.get("origin") orelse {
        res.status = HTTP_BAD_REQUEST;
        res.body = "{\"error\":\"missing origin\"}";
        res.content_type = .JSON;
        return;
    }).string;

    const host = req.header("host") orelse HOST_LOCALHOST;
    // Construct expected origins (http and https)
    const expected_https = try std.fmt.allocPrint(req.arena, URL_SCHEME_TEMPLATE, .{ URL_SCHEME_HTTPS, host });
    const expected_http = try std.fmt.allocPrint(req.arena, URL_SCHEME_TEMPLATE, .{ URL_SCHEME_HTTP, host });
    if (!std.mem.eql(u8, cd_origin, expected_https) and !std.mem.eql(u8, cd_origin, expected_http)) {
        res.status = HTTP_BAD_REQUEST;
        res.body = "{\"error\":\"origin mismatch\"}";
        res.content_type = .JSON;
        return;
    }

    // Verify challenge
    const cd_challenge = (client_data_parsed.value.object.get("challenge") orelse {
        res.status = HTTP_BAD_REQUEST;
        res.body = "{\"error\":\"missing challenge\"}";
        res.content_type = .JSON;
        return;
    }).string;

    const stored_challenge = takePendingChallenge() orelse {
        res.status = HTTP_BAD_REQUEST;
        res.body = "{\"error\":\"no pending challenge\"}";
        res.content_type = .JSON;
        return;
    };

    const expected_challenge_b64 = try base64urlEncode(req.arena, &stored_challenge);
    if (!std.mem.eql(u8, cd_challenge, expected_challenge_b64)) {
        res.status = HTTP_BAD_REQUEST;
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
        res.status = HTTP_BAD_REQUEST;
        res.body = "{\"error\":\"unknown credential\"}";
        res.content_type = .JSON;
        return;
    };

    // Reconstruct the public key
    const x_bytes = base64urlDecode(req.arena, cred.public_key_x) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = "{\"error\":\"invalid stored key x\"}";
        res.content_type = .JSON;
        return;
    };
    const y_bytes = base64urlDecode(req.arena, cred.public_key_y) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = "{\"error\":\"invalid stored key y\"}";
        res.content_type = .JSON;
        return;
    };

    if (x_bytes.len != 32 or y_bytes.len != 32) {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = "{\"error\":\"invalid stored key length\"}";
        res.content_type = .JSON;
        return;
    }

    // Build SEC1 uncompressed point: 0x04 || x || y
    var sec1: [SEC1_UNCOMPRESSED_LEN]u8 = undefined;
    sec1[0] = 0x04;
    @memcpy(sec1[1..SEC1_TAG_AND_X_LEN], x_bytes);
    @memcpy(sec1[SEC1_TAG_AND_X_LEN..SEC1_UNCOMPRESSED_LEN], y_bytes);

    const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
    const pubkey = EcdsaP256.PublicKey.fromSec1(&sec1) catch {
        res.status = HTTP_INTERNAL_ERROR;
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
        res.status = HTTP_BAD_REQUEST;
        res.body = "{\"error\":\"invalid signature format\"}";
        res.content_type = .JSON;
        return;
    } orelse {
        res.status = HTTP_BAD_REQUEST;
        res.body = "{\"error\":\"could not parse DER signature\"}";
        res.content_type = .JSON;
        return;
    };

    const signature = EcdsaP256.Signature.fromBytes(sig_rs);

    // Verify the signature
    signature.verify(verify_msg, pubkey) catch {
        res.status = HTTP_BAD_REQUEST;
        res.body = "{\"error\":\"signature verification failed\"}";
        res.content_type = .JSON;
        return;
    };

    // Success - create session tied to the credential's email
    const session_email = if (cred.email.len > 0) cred.email else "";
    const token = try createSession(ctx.allocator, ctx.auth_dir, session_email);
    const cookie = try std.fmt.allocPrint(req.arena, "session={s}; Path=/; HttpOnly; SameSite=Strict; Max-Age=604800", .{token});
    res.header(HEADER_SET_COOKIE, cookie);

    res.content_type = .JSON;
    res.body = OK_JSON_TRUE;
}

// ── HTML Pages ───────────────────────────────────────────────────────

pub const PAGE_STYLE =
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

pub const B64URL_JS =
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
/// challenge/complete endpoints.
pub fn loginPage(_: *Handler, _: *httpz.Request, res: *httpz.Response) HandlerError!void {
    res.content_type = .HTML;
    res.body =
        HTML_DOCTYPE_HEAD ++
        "<title>Login - Canopy EDA</title><style>" ++ PAGE_STYLE ++ HTML_STYLE_HEAD_BODY_OPEN ++
        HTML_AUTH_CARD_OPEN ++
        HTML_BRAND_SPAN ++
        "<h1>Sign In</h1>" ++
        "<p>Enter your email and use your passkey to authenticate.</p>" ++
        HTML_EMAIL_INPUT ++
        HTML_INPUT_STYLE_DARK ++
        "<button class=\"auth-btn\" id=\"login-btn\">Sign in with Passkey</button>" ++
        HTML_STATUS_DIV ++
        "</div>" ++
        HTML_SCRIPT_OPEN ++ B64URL_JS ++
        \\const btn = document.getElementById('login-btn');
        \\const emailInput = document.getElementById('email');
        \\const status = document.getElementById('status');
        \\btn.addEventListener('click', async () => {
        \\  const email = emailInput.value.trim();
        \\  if (!email || !email.includes('@')) {
        \\    status.className = 'status error';
        \\    status.textContent = 'Please enter a valid email address';
        \\    return;
        \\  }
        \\  btn.disabled = true;
        \\  status.className = 'status';
        \\  status.textContent = 'Requesting challenge...';
        \\  try {
        \\    const challengeRes = await fetch('/auth/login/challenge?email=' + encodeURIComponent(email));
        \\    const opts = await challengeRes.json();
        \\    if (!opts.allowCredentials || opts.allowCredentials.length === 0) {
        \\      throw new Error('No passkey registered for this email on this server. Ask an admin for an invite link.');
        \\    }
        \\    const publicKey = {
        \\      challenge: b64urlToBytes(opts.challenge),
        \\      rpId: opts.rpId,
        \\      timeout: opts.timeout,
        \\      userVerification: opts.userVerification,
        \\      allowCredentials: (opts.allowCredentials || []).map(c => ({
        \\        type: c.type,
        \\        id: b64urlToBytes(c.id)
        \\      }))
        \\    };
        \\    status.textContent = 'Waiting for passkey...';
        \\    const cred = await navigator.credentials.get({ publicKey });
        \\    status.textContent = 'Verifying...';
        \\    const body = JSON.stringify({
        \\      id: bytesToB64url(cred.rawId),
        \\      response: {
        \\        authenticatorData: bytesToB64url(cred.response.authenticatorData),
        \\        clientDataJSON: bytesToB64url(cred.response.clientDataJSON),
        \\        signature: bytesToB64url(cred.response.signature)
        \\      }
        \\    });
        \\    const verifyRes = await fetch('/auth/login/complete', {
        \\      method: 'POST',
        \\      headers: { 'Content-Type': 'application/json' },
        \\      body: body
        \\    });
        \\    const result = await verifyRes.json();
        \\    if (result.ok) {
        \\      status.className = 'status ok';
        \\      status.textContent = 'Authenticated!';
        \\      window.location.href = '/';
        \\    } else {
        \\      status.className = 'status error';
        \\      status.textContent = result.error || 'Authentication failed';
        \\      btn.disabled = false;
        \\    }
        \\  } catch (e) {
        \\    status.className = 'status error';
        \\    status.textContent = e.message || 'Authentication failed';
        \\    btn.disabled = false;
        \\  }
        \\});
        ++ HTML_SCRIPT_BODY_CLOSE;
}

/// GET /auth/setup — first-user bootstrap page. Redirects to `/auth/login`
/// when at least one credential already exists; otherwise renders the
/// passkey-registration UI for the initial admin account.
pub fn setupPage(ctx: *Handler, _: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const existing = try loadCredentials(ctx.allocator, ctx.auth_dir);
    if (existing.len > 0) {
        res.status = 303;
        res.header(HEADER_LOCATION, PATH_AUTH_LOGIN);
        return;
    }
    res.content_type = .HTML;
    res.body =
        HTML_DOCTYPE_HEAD ++
        "<title>Setup - Canopy EDA</title><style>" ++ PAGE_STYLE ++ HTML_STYLE_HEAD_BODY_OPEN ++
        HTML_AUTH_CARD_OPEN ++
        HTML_BRAND_SPAN ++
        "<h1>Setup Passkey</h1>" ++
        "<p>Register a passkey to secure remote access to your EDA server.</p>" ++
        HTML_EMAIL_INPUT ++
        HTML_INPUT_STYLE_MID ++
        "<button class=\"auth-btn\" id=\"register-btn\">Register Passkey</button>" ++
        HTML_STATUS_DIV ++
        "<a class=\"link\" href=\"/auth/login\">Already registered? Sign in</a>" ++
        "</div>" ++
        HTML_SCRIPT_OPEN ++ B64URL_JS ++
        \\const btn = document.getElementById('register-btn');
        \\const emailInput = document.getElementById('email');
        \\const status = document.getElementById('status');
        \\btn.addEventListener('click', async () => {
        \\  const email = emailInput.value.trim();
        \\  if (!email || !email.includes('@')) {
        \\    status.className = 'status error';
        \\    status.textContent = 'Please enter a valid email address';
        \\    return;
        \\  }
        \\  btn.disabled = true;
        \\  status.className = 'status';
        \\  status.textContent = 'Requesting challenge...';
        \\  try {
        \\    const challengeRes = await fetch('/auth/register/challenge?email=' + encodeURIComponent(email));
        \\    const opts = await challengeRes.json();
        \\    const publicKey = {
        \\      challenge: b64urlToBytes(opts.challenge),
        \\      rp: opts.rp,
        \\      user: {
        \\        id: b64urlToBytes(opts.user.id),
        \\        name: opts.user.name,
        \\        displayName: opts.user.displayName
        \\      },
        \\      pubKeyCredParams: opts.pubKeyCredParams,
        \\      authenticatorSelection: opts.authenticatorSelection,
        \\      timeout: opts.timeout
        \\    };
        \\    status.textContent = 'Waiting for passkey...';
        \\    const cred = await navigator.credentials.create({ publicKey });
        \\    status.textContent = 'Registering...';
        \\    const body = JSON.stringify({
        \\      id: bytesToB64url(cred.rawId),
        \\      email: email,
        \\      response: {
        \\        attestationObject: bytesToB64url(cred.response.attestationObject),
        \\        clientDataJSON: bytesToB64url(cred.response.clientDataJSON)
        \\      }
        \\    });
        \\    const verifyRes = await fetch('/auth/register/complete', {
        \\      method: 'POST',
        \\      headers: { 'Content-Type': 'application/json' },
        \\      body: body
        \\    });
        \\    const result = await verifyRes.json();
        \\    if (result.ok) {
        \\      status.className = 'status ok';
        \\      status.textContent = 'Passkey registered!';
        \\      window.location.href = '/';
        \\    } else {
        \\      status.className = 'status error';
        \\      status.textContent = result.error || 'Registration failed';
        \\      btn.disabled = false;
        \\    }
        \\  } catch (e) {
        \\    status.className = 'status error';
        \\    status.textContent = e.message || 'Registration failed';
        \\    btn.disabled = false;
        \\  }
        \\});
        ++ HTML_SCRIPT_BODY_CLOSE;
}

// ── Session / account management ─────────────────────────────────────

fn requireSession(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) ?[]const u8 {
    const tok = getSessionToken(req) orelse {
        res.status = 401;
        res.content_type = .JSON;
        res.body = "{\"error\":\"not signed in\"}";
        return null;
    };
    const email = validateSession(ctx.allocator, ctx.auth_dir, tok) orelse {
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
pub fn logoutApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    if (getSessionToken(req)) |tok| {
        deleteSession(ctx.allocator, ctx.auth_dir, tok);
    }
    res.header(HEADER_SET_COOKIE, "session=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0");
    res.content_type = .JSON;
    res.body = OK_JSON_TRUE;
}

/// GET /api/auth/credentials — return the signed-in user's registered
/// passkeys (id, email, created_at) as JSON for the account page's
/// device-management list.
pub fn listCredentialsApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const email = requireSession(ctx, req, res) orelse return;

    const creds = try loadCredentials(ctx.allocator, ctx.auth_dir);

    var buf: std.ArrayListUnmanaged(u8) = .empty;
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
pub fn deleteCredentialApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const email = requireSession(ctx, req, res) orelse return;

    const body = req.body() orelse {
        res.status = HTTP_BAD_REQUEST;
        res.content_type = .JSON;
        res.body = ERR_MISSING_BODY_JSON;
        return;
    };
    const parsed = std.json.parseFromSlice(std.json.Value, req.arena, body, .{}) catch {
        res.status = HTTP_BAD_REQUEST;
        res.content_type = .JSON;
        res.body = ERR_INVALID_JSON_JSON;
        return;
    };
    const id_val = parsed.value.object.get("id") orelse {
        res.status = HTTP_BAD_REQUEST;
        res.content_type = .JSON;
        res.body = ERR_MISSING_ID_JSON;
        return;
    };
    if (id_val != .string) {
        res.status = HTTP_BAD_REQUEST;
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
        res.status = HTTP_BAD_REQUEST;
        res.content_type = .JSON;
        res.body = "{\"error\":\"cannot delete your only passkey\"}";
        return;
    }

    var kept: std.ArrayListUnmanaged(StoredCredential) = .empty;
    var removed = false;
    for (existing) |c| {
        if (std.mem.eql(u8, c.id, target_id) and std.mem.eql(u8, c.email, email)) {
            removed = true;
            continue;
        }
        try kept.append(ctx.allocator, c);
    }

    if (!removed) {
        res.status = HTTP_NOT_FOUND;
        res.content_type = .JSON;
        res.body = "{\"error\":\"credential not found\"}";
        return;
    }

    saveCredentials(ctx.allocator, ctx.auth_dir, kept.items) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.content_type = .JSON;
        res.body = "{\"error\":\"failed to save\"}";
        return;
    };

    res.content_type = .JSON;
    res.body = OK_JSON_TRUE;
}

/// POST /api/auth/invites — admin-only: mint a 7-day single-use invite token
/// (defaulting to writer role) the recipient can redeem at
/// `/auth/invite/<token>` to register their first passkey.
pub fn createInviteApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const email = currentEmail(ctx, req) orelse {
        res.status = 401;
        res.content_type = .JSON;
        res.body = "{\"error\":\"sign in required\"}";
        return;
    };

    // Admin-only.
    if (!users.getRole(ctx.allocator, ctx.auth_dir, email).canAdmin()) {
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

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(req.arena);
    try w.print("{{\"ok\":true,\"token\":\"{s}\",\"path\":\"/auth/invite/{s}\",\"role\":\"{s}\"}}", .{ token, token, role_str });

    res.content_type = .JSON;
    res.body = buf.items;
}

/// GET /auth/invite/:token — render the passkey-registration UI for an
/// invite recipient. Shows an "expired" page when the token is missing,
/// consumed, or past its TTL; otherwise drives the WebAuthn create flow.
pub fn invitePage(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const path = req.url.path;
    const prefix = "/auth/invite/";
    if (!std.mem.startsWith(u8, path, prefix)) {
        res.status = HTTP_NOT_FOUND;
        res.body = "not found";
        return;
    }
    const token = path[prefix.len..];
    if (token.len == 0) {
        res.status = HTTP_NOT_FOUND;
        res.body = "not found";
        return;
    }

    const found = try findInvite(ctx.allocator, ctx.auth_dir, token);
    if (found == null) {
        res.content_type = .HTML;
        res.body =
            HTML_DOCTYPE_HEAD ++
            "<title>Invite - Canopy EDA</title><style>" ++ PAGE_STYLE ++ HTML_STYLE_HEAD_BODY_OPEN ++
            HTML_AUTH_CARD_OPEN ++
            HTML_BRAND_SPAN ++
            "<h1>Invite Expired</h1>" ++
            "<p>This invite link is invalid or has expired. Ask the person who invited you for a new link.</p>" ++
            "<a class=\"link\" href=\"/auth/login\">Back to sign in</a>" ++
            "</div></body></html>";
        return;
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(req.arena);
    try w.writeAll(
        HTML_DOCTYPE_HEAD ++
            "<title>Accept Invite - Canopy EDA</title><style>" ++ PAGE_STYLE ++ HTML_STYLE_HEAD_BODY_OPEN ++
            HTML_AUTH_CARD_OPEN ++
            HTML_BRAND_SPAN ++
            "<h1>Accept Invite</h1>" ++
            "<p>Enter your email and register a passkey for this device.</p>" ++
            HTML_EMAIL_INPUT ++
            HTML_INPUT_STYLE_DARK ++
            "<button class=\"auth-btn\" id=\"register-btn\">Register Passkey</button>" ++
            HTML_STATUS_DIV ++
            "</div>" ++
            HTML_SCRIPT_OPEN ++ B64URL_JS,
    );
    try w.print("const INVITE_TOKEN = \"{s}\";\n", .{token});
    try w.writeAll(
        \\const btn = document.getElementById('register-btn');
        \\const emailInput = document.getElementById('email');
        \\const status = document.getElementById('status');
        \\btn.addEventListener('click', async () => {
        \\  const email = emailInput.value.trim();
        \\  if (!email || !email.includes('@')) {
        \\    status.className = 'status error';
        \\    status.textContent = 'Please enter a valid email address';
        \\    return;
        \\  }
        \\  btn.disabled = true;
        \\  status.className = 'status';
        \\  status.textContent = 'Requesting challenge...';
        \\  try {
        \\    const url = '/auth/register/challenge?invite=' + encodeURIComponent(INVITE_TOKEN) + '&email=' + encodeURIComponent(email);
        \\    const challengeRes = await fetch(url);
        \\    const opts = await challengeRes.json();
        \\    if (!challengeRes.ok) throw new Error(opts.error || 'Challenge failed');
        \\    const publicKey = {
        \\      challenge: b64urlToBytes(opts.challenge),
        \\      rp: opts.rp,
        \\      user: { id: b64urlToBytes(opts.user.id), name: opts.user.name, displayName: opts.user.displayName },
        \\      pubKeyCredParams: opts.pubKeyCredParams,
        \\      authenticatorSelection: opts.authenticatorSelection,
        \\      timeout: opts.timeout,
        \\      excludeCredentials: (opts.excludeCredentials || []).map(c => ({ type: c.type, id: b64urlToBytes(c.id) }))
        \\    };
        \\    status.textContent = 'Waiting for passkey...';
        \\    const cred = await navigator.credentials.create({ publicKey });
        \\    status.textContent = 'Registering...';
        \\    const body = JSON.stringify({
        \\      id: bytesToB64url(cred.rawId),
        \\      email: email,
        \\      invite: INVITE_TOKEN,
        \\      response: {
        \\        attestationObject: bytesToB64url(cred.response.attestationObject),
        \\        clientDataJSON: bytesToB64url(cred.response.clientDataJSON)
        \\      }
        \\    });
        \\    const verifyRes = await fetch('/auth/register/complete', {
        \\      method: 'POST',
        \\      headers: { 'Content-Type': 'application/json' },
        \\      body: body
        \\    });
        \\    const result = await verifyRes.json();
        \\    if (result.ok) {
        \\      status.className = 'status ok';
        \\      status.textContent = 'Passkey registered!';
        \\      window.location.href = '/';
        \\    } else {
        \\      status.className = 'status error';
        \\      status.textContent = result.error || 'Registration failed';
        \\      btn.disabled = false;
        \\    }
        \\  } catch (e) {
        \\    status.className = 'status error';
        \\    status.textContent = e.message || 'Registration failed';
        \\    btn.disabled = false;
        \\  }
        \\});
    );
    try w.writeAll(HTML_SCRIPT_BODY_CLOSE);

    res.content_type = .HTML;
    res.body = buf.items;
}

/// GET /auth/manage — signed-in account page for listing the user's
/// passkeys, adding another device, generating invite links, and signing
/// out. Redirects to `/auth/login` when the request lacks a valid session.
pub fn managePage(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const tok = getSessionToken(req) orelse {
        res.status = 303;
        res.header(HEADER_LOCATION, PATH_AUTH_LOGIN);
        return;
    };
    if (validateSession(ctx.allocator, ctx.auth_dir, tok) == null) {
        res.status = 303;
        res.header(HEADER_LOCATION, PATH_AUTH_LOGIN);
        return;
    }

    res.content_type = .HTML;
    res.body =
        HTML_DOCTYPE_HEAD ++
        "<title>Manage - Canopy EDA</title><style>" ++ PAGE_STYLE ++
        "\n.auth-card { max-width: 520px; text-align: left; }" ++
        "\n.auth-card h1 { text-align: center; }" ++
        MANAGE_PAGE_EXTRA_CSS ++
        HTML_STYLE_HEAD_BODY_OPEN ++
        HTML_AUTH_CARD_OPEN ++
        HTML_BRAND_SPAN ++
        "<h1>Manage Passkeys</h1>" ++
        "<div class=\"user-bar\"><span class=\"email\" id=\"user-email\"></span>" ++
        "<button class=\"btn-sec\" id=\"logout-btn\" " ++
        "style=\"padding:4px 10px;font-size:0.8rem;border-radius:4px;cursor:pointer\">" ++
        "Sign out</button></div>" ++
        "<div class=\"section-title\">Your Passkeys</div>" ++
        "<div id=\"passkey-list\"></div>" ++
        "<button class=\"auth-btn\" id=\"add-btn\" style=\"margin-top:8px\">Add passkey on this device</button>" ++
        "<div class=\"section-title\">Invite a new user</div>" ++
        "<p style=\"color:#8b949e;font-size:0.85rem;margin-bottom:8px\">" ++
        "Generate a one-time link (valid 7 days). " ++
        "The same link works on your other devices to add passkeys to your own account.</p>" ++
        "<button class=\"btn-sec auth-btn\" id=\"invite-btn\">Create invite link</button>" ++
        "<div id=\"invite-out\"></div>" ++
        HTML_STATUS_DIV ++
        "<a class=\"link\" href=\"/\">Back to designs</a>" ++
        "</div>" ++
        HTML_SCRIPT_OPEN ++ B64URL_JS ++
        \\const status = document.getElementById('status');
        \\function fmtDate(ts) {
        \\  if (!ts) return 'Unknown';
        \\  const d = new Date(ts * 1000);
        \\  return d.toLocaleString();
        \\}
        \\async function refresh() {
        \\  const r = await fetch('/auth/credentials/list');
        \\  if (!r.ok) { window.location.href = '/auth/login'; return; }
        \\  const data = await r.json();
        \\  document.getElementById('user-email').textContent = data.email;
        \\  const list = document.getElementById('passkey-list');
        \\  list.innerHTML = '';
        \\  for (const c of data.credentials) {
        \\    const row = document.createElement('div');
        \\    row.className = 'row';
        \\    const meta = document.createElement('div');
        \\    const added = document.createElement('div');
        \\    added.className = 'meta';
        \\    added.textContent = 'Added ' + fmtDate(c.created_at);
        \\    const title = document.createElement('div');
        \\    title.textContent = 'Passkey';
        \\    meta.appendChild(title);
        \\    meta.appendChild(added);
        \\    const btn = document.createElement('button');
        \\    btn.textContent = 'Delete';
        \\    btn.onclick = async () => {
        \\      if (data.credentials.length <= 1) {
        \\        status.className = 'status error';
        \\        status.textContent = 'Cannot delete your only passkey. Add another first.';
        \\        return;
        \\      }
        \\      if (!confirm('Delete this passkey?')) return;
        \\      const rr = await fetch('/auth/credentials/delete', {
        \\        method: 'POST',
        \\        headers: { 'Content-Type': 'application/json' },
        \\        body: JSON.stringify({ id: c.id })
        \\      });
        \\      const j = await rr.json();
        \\      if (j.ok) { refresh(); } else {
        \\        status.className = 'status error';
        \\        status.textContent = j.error || 'Delete failed';
        \\      }
        \\    };
        \\    row.appendChild(meta);
        \\    row.appendChild(btn);
        \\    list.appendChild(row);
        \\  }
        \\}
        \\document.getElementById('logout-btn').onclick = async () => {
        \\  await fetch('/auth/logout', { method: 'POST' });
        \\  window.location.href = '/auth/login';
        \\};
        \\document.getElementById('add-btn').onclick = async () => {
        \\  status.className = 'status';
        \\  status.textContent = 'Requesting challenge...';
        \\  try {
        \\    const challengeRes = await fetch('/auth/register/challenge');
        \\    const opts = await challengeRes.json();
        \\    if (!challengeRes.ok) throw new Error(opts.error || 'Challenge failed');
        \\    const publicKey = {
        \\      challenge: b64urlToBytes(opts.challenge),
        \\      rp: opts.rp,
        \\      user: { id: b64urlToBytes(opts.user.id), name: opts.user.name, displayName: opts.user.displayName },
        \\      pubKeyCredParams: opts.pubKeyCredParams,
        \\      authenticatorSelection: opts.authenticatorSelection,
        \\      timeout: opts.timeout,
        \\      excludeCredentials: (opts.excludeCredentials || []).map(c => ({ type: c.type, id: b64urlToBytes(c.id) }))
        \\    };
        \\    status.textContent = 'Waiting for passkey...';
        \\    const cred = await navigator.credentials.create({ publicKey });
        \\    status.textContent = 'Registering...';
        \\    const body = JSON.stringify({
        \\      id: bytesToB64url(cred.rawId),
        \\      response: {
        \\        attestationObject: bytesToB64url(cred.response.attestationObject),
        \\        clientDataJSON: bytesToB64url(cred.response.clientDataJSON)
        \\      }
        \\    });
        \\    const verifyRes = await fetch('/auth/register/complete', {
        \\      method: 'POST',
        \\      headers: { 'Content-Type': 'application/json' },
        \\      body: body
        \\    });
        \\    const result = await verifyRes.json();
        \\    if (result.ok) {
        \\      status.className = 'status ok';
        \\      status.textContent = 'Passkey added.';
        \\      refresh();
        \\    } else {
        \\      status.className = 'status error';
        \\      status.textContent = result.error || 'Registration failed';
        \\    }
        \\  } catch (e) {
        \\    status.className = 'status error';
        \\    status.textContent = e.message || 'Registration failed';
        \\  }
        \\};
        \\document.getElementById('invite-btn').onclick = async () => {
        \\  const r = await fetch('/auth/invite/create', { method: 'POST' });
        \\  const j = await r.json();
        \\  if (j.ok) {
        \\    const fullUrl = window.location.origin + j.path;
        \\    const out = document.getElementById('invite-out');
        \\    out.innerHTML = '';
        \\    const box = document.createElement('div');
        \\    box.className = 'invite-box';
        \\    box.textContent = fullUrl;
        \\    const note = document.createElement('div');
        \\    note.style.color = '#8b949e';
        \\    note.style.fontSize = '0.8rem';
        \\    note.style.marginTop = '6px';
        \\    note.textContent = 'Valid for 7 days. One-time use.';
        \\    out.appendChild(box);
        \\    out.appendChild(note);
        \\  } else {
        \\    status.className = 'status error';
        \\    status.textContent = j.error || 'Failed to create invite';
        \\  }
        \\};
        \\refresh();
        ++ HTML_SCRIPT_BODY_CLOSE;
}
