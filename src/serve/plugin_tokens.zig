const std = @import("std");
const clock = @import("../infra/clock.zig");
const infra_fs = @import("../infra/fs.zig");
const log = @import("../infra/log.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;
const infra_random = @import("../infra/random.zig");

/// Stored record for a minted plugin token. Only the hash is persisted —
/// the raw token is shown once at mint time and never stored.
pub const Token = struct {
    hash: []const u8,
    label: []const u8,
    created_at: i64,
};

var mu: std.Thread.Mutex = .{};
var tokens_list: std.ArrayListUnmanaged(Token) = .empty;
var loaded_project_dir: ?[]const u8 = null;

fn tokensPath(allocator: std.mem.Allocator, project_dir: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/auth/plugin_tokens.json", .{project_dir});
}

fn ensureAuthDir(project_dir: []const u8) void {
    var buf: [512]u8 = undefined;
    const dir = std.fmt.bufPrint(&buf, "{s}/auth", .{project_dir}) catch return;
    infra_fs.cwd().makePath(dir) catch |e| {
        log.warn("makePath {s} failed: {s}", .{ dir, @errorName(e) });
    };
}

fn ensureLoaded(allocator: std.mem.Allocator, project_dir: []const u8) void {
    if (loaded_project_dir) |d| {
        if (std.mem.eql(u8, d, project_dir)) return;
    }
    loaded_project_dir = project_dir;
    load(allocator, project_dir);
}

fn load(allocator: std.mem.Allocator, project_dir: []const u8) void {
    const path = tokensPath(allocator, project_dir) catch return;
    defer allocator.free(path);
    const data = infra_fs.cwd().readFileAlloc(allocator, path, 1 * 1024 * 1024) catch return;
    const Entry = struct {
        hash: []const u8,
        label: []const u8 = "",
        created_at: i64 = 0,
    };
    const parsed = std.json.parseFromSlice([]const Entry, allocator, data, .{ .allocate = .alloc_always, .ignore_unknown_fields = true }) catch return;
    defer parsed.deinit();
    for (parsed.value) |e| {
        tokens_list.append(allocator, .{
            .hash = allocator.dupe(u8, e.hash) catch continue,
            .label = allocator.dupe(u8, e.label) catch continue,
            .created_at = e.created_at,
        }) catch continue;
    }
}

fn save(allocator: std.mem.Allocator, project_dir: []const u8) void {
    ensureAuthDir(project_dir);
    const path = tokensPath(allocator, project_dir) catch return;
    defer allocator.free(path);
    const file = infra_fs.cwd().createFile(path, .{}) catch return;
    defer file.close();
    var bw: std.ArrayListUnmanaged(u8) = .empty;
    defer bw.deinit(allocator);
    const w = bw.writer(allocator);
    w.writeAll("[") catch return;
    for (tokens_list.items, 0..) |t, i| {
        if (i > 0) w.writeAll(",") catch return;
        w.writeAll("{\"hash\":\"") catch return;
        w.writeAll(t.hash) catch return;
        w.writeAll("\",\"label\":") catch return;
        writeJsonString(w, t.label) catch return;
        w.print(",\"created_at\":{d}}}", .{t.created_at}) catch return;
    }
    w.writeAll("]") catch return;
    file.writeAll(bw.items) catch return;
}

/// Mint a new plugin token. Returns the raw token string (prefix `eda_p_`) —
/// shown once to the user and never stored. Caller owns the returned memory.
pub fn mint(allocator: std.mem.Allocator, project_dir: []const u8, label: []const u8) ![]const u8 {
    mu.lock();
    defer mu.unlock();
    ensureLoaded(allocator, project_dir);

    const suffix = try randomHex(allocator, 32);
    defer allocator.free(suffix);
    const raw = try std.fmt.allocPrint(allocator, "eda_p_{s}", .{suffix});
    const hash = try sha256Hex(allocator, raw);
    try tokens_list.append(allocator, .{
        .hash = hash,
        .label = try allocator.dupe(u8, label),
        .created_at = clock.timestamp(),
    });
    save(allocator, project_dir);
    return raw;
}

/// Returns true if `raw` matches a stored plugin token. Tokens do not expire;
/// revoke by deleting from `plugin_tokens.json`.
pub fn validate(allocator: std.mem.Allocator, project_dir: []const u8, raw: []const u8) bool {
    mu.lock();
    defer mu.unlock();
    ensureLoaded(allocator, project_dir);
    const hash = sha256Hex(allocator, raw) catch return false;
    defer allocator.free(hash);
    for (tokens_list.items) |t| {
        if (std.mem.eql(u8, t.hash, hash)) return true;
    }
    return false;
}

// ── helpers ─────────────────────────────────────────────────────────────

fn sha256Hex(allocator: std.mem.Allocator, input: []const u8) ![]u8 {
    var digest: [32]u8 = undefined;
    Sha256.hash(input, &digest, .{});
    const hex = "0123456789abcdef";
    var out = try allocator.alloc(u8, 64);
    for (digest, 0..) |b, i| {
        out[i * 2] = hex[b >> 4];
        out[i * 2 + 1] = hex[b & 0x0f];
    }
    return out;
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

fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeAll("\"");
    for (s) |ch| switch (ch) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        0x00...0x08, 0x0b, 0x0c, 0x0e...0x1f => try w.print("\\u{x:0>4}", .{ch}),
        else => try w.writeByte(ch),
    };
    try w.writeAll("\"");
}
