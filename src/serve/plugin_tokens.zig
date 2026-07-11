const std = @import("std");
const json_writer = @import("../json_writer.zig");
const clock = @import("../infra/clock.zig");
const infra_fs = @import("../infra/fs.zig");
const log = @import("../infra/log.zig");
const infra_random = @import("../infra/random.zig");
const auth_store = @import("auth_store.zig");
const oauth_store = @import("oauth_store.zig");

/// Stored record for a minted plugin token. Only the hash is persisted —
/// the raw token is shown once at mint time and never stored.
pub const Token = struct {
    hash: []const u8,
    label: []const u8,
    created_at: i64,
};

// Tokens persist for the life of the process — callers pass a per-request
// arena, so stored strings must come from the process allocator.
const store_alloc = std.heap.page_allocator;

fn tokensPath(allocator: std.mem.Allocator, auth_dir: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/plugin_tokens.json", .{auth_dir});
}

const ensureAuthDir = auth_store.ensureAuthDir;

/// Per-server plugin-token table, persisted to `<auth_dir>/plugin_tokens.json`
/// (hashes only). Instance state carried on `ServerState` (it used to be a
/// file-scope global); rows live in `store_alloc` (process lifetime).
pub const PluginTokenStore = struct {
    mu: std.Thread.Mutex = .{},
    tokens_list: std.ArrayList(Token) = .empty,
    loaded_auth_dir: ?[]const u8 = null,

    fn ensureLoaded(self: *PluginTokenStore, allocator: std.mem.Allocator, auth_dir: []const u8) void {
        if (self.loaded_auth_dir) |d| {
            if (std.mem.eql(u8, d, auth_dir)) return;
        }
        self.loaded_auth_dir = auth_dir;
        self.load(allocator, auth_dir);
    }

    fn load(self: *PluginTokenStore, allocator: std.mem.Allocator, auth_dir: []const u8) void {
        const path = tokensPath(allocator, auth_dir) catch return;
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
            self.tokens_list.append(store_alloc, .{
                .hash = store_alloc.dupe(u8, e.hash) catch continue,
                .label = store_alloc.dupe(u8, e.label) catch continue,
                .created_at = e.created_at,
            }) catch continue;
        }
    }

    fn save(self: *PluginTokenStore, allocator: std.mem.Allocator, auth_dir: []const u8) void {
        ensureAuthDir(auth_dir);
        const path = tokensPath(allocator, auth_dir) catch return;
        defer allocator.free(path);
        var bw: std.ArrayList(u8) = .empty;
        defer bw.deinit(allocator);
        const w = bw.writer(allocator);
        w.writeAll("[") catch return;
        for (self.tokens_list.items, 0..) |t, i| {
            if (i > 0) w.writeAll(",") catch return;
            w.writeAll("{\"hash\":\"") catch return;
            w.writeAll(t.hash) catch return;
            w.writeAll("\",\"label\":") catch return;
            json_writer.writeString(w, t.label) catch return;
            w.print(",\"created_at\":{d}}}", .{t.created_at}) catch return;
        }
        w.writeAll("]") catch return;
        oauth_store.writeFileAtomicWithBackup(allocator, path, bw.items);
    }

    /// Mint a new plugin token. Returns the raw token string (prefix `eda_p_`) —
    /// shown once to the user and never stored. Caller owns the returned memory.
    pub fn mint(
        self: *PluginTokenStore,
        allocator: std.mem.Allocator,
        auth_dir: []const u8,
        label: []const u8,
    ) std.mem.Allocator.Error![]const u8 {
        self.mu.lock();
        defer self.mu.unlock();
        self.ensureLoaded(allocator, auth_dir);

        const suffix = try randomHex(allocator, 32);
        defer allocator.free(suffix);
        const raw = try std.fmt.allocPrint(allocator, "eda_p_{s}", .{suffix});
        const hash = try sha256Hex(store_alloc, raw);
        try self.tokens_list.append(store_alloc, .{
            .hash = hash,
            .label = try store_alloc.dupe(u8, label),
            .created_at = clock.timestamp(),
        });
        self.save(allocator, auth_dir);
        return raw;
    }

    /// Returns true if `raw` matches a stored plugin token. Tokens do not
    /// expire; revoke by deleting from `plugin_tokens.json`.
    pub fn validate(self: *PluginTokenStore, allocator: std.mem.Allocator, auth_dir: []const u8, raw: []const u8) bool {
        self.mu.lock();
        defer self.mu.unlock();
        self.ensureLoaded(allocator, auth_dir);
        const hash = sha256Hex(allocator, raw) catch return false;
        defer allocator.free(hash);
        for (self.tokens_list.items) |t| {
            if (std.mem.eql(u8, t.hash, hash)) return true;
        }
        return false;
    }
};

// ── helpers ─────────────────────────────────────────────────────────────

const sha256Hex = auth_store.sha256Hex;

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
