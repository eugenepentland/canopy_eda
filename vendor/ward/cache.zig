//! Verdict cache — an in-process cache of positive (authorized) verdicts keyed
//! by the SHA-256 hash of the session token, never its raw text.
//!
//! Only authorized usernames are stored, so a rejected token is re-checked on
//! its next request and a fresh login is seen immediately; a revoked session
//! lags at most the TTL. `now` is injected (whole unix-epoch seconds); every
//! store prunes elapsed entries, and a hard entry cap (default 4096) evicts
//! the entry nearest expiry when distinct tokens pile up faster than they
//! elapse — so the cache cannot grow without bound either way.

const std = @import("std");
const verdict_mod = @import("verdict.zig");

/// A user's access role, mirrored from the verdict module so a cached verdict
/// stays role-complete.
pub const Role = verdict_mod.Role;

/// Number of bytes in the SHA-256 digest a token is keyed by.
const hash_len = 32;

/// Entry cap applied by `init`; `initBounded` accepts any other bound.
pub const default_max_entries: usize = 4096;

/// A cache hit: the authorized username, the role, and the scope it was stored
/// with. `scope` is the empty string for a session verdict (which carries none)
/// and the granted space-separated scope for a bearer verdict.
pub const Cached = struct {
    /// The authenticated username (borrowed from the cache until its next mutation).
    username: []const u8,
    /// The user's role as recorded when the verdict was cached.
    role: Role,
    /// The space-separated scope the verdict carried (empty for a session).
    scope: []const u8,
};

/// One cached positive verdict: the resolved username, role, scope, and expiry.
const Entry = struct {
    /// Owned copy of the authenticated username.
    username: []const u8,
    /// The user's access role at the time the verdict was cached.
    role: Role,
    /// Owned copy of the space-separated scope (empty for a session verdict).
    scope: []const u8,
    /// Whole unix-epoch second at or after which this entry is stale.
    expires_at: i64,
};

/// In-process cache of authorized verdicts, keyed by hashed session token.
pub const Cache = struct {
    /// Allocator backing the map and every stored username copy.
    allocator: std.mem.Allocator,
    /// Lifetime applied to each stored verdict, in seconds.
    ttl_secs: i64,
    /// Token-hash -> cached entry.
    entries: std.AutoHashMapUnmanaged([hash_len]u8, Entry),
    /// Hard bound on stored entries; a store at the bound evicts first.
    max_entries: usize,

    /// Creates an empty cache whose entries each live `ttl_secs` seconds,
    /// bounded to `default_max_entries` entries.
    pub fn init(allocator: std.mem.Allocator, ttl_secs: i64) Cache {
        return initBounded(allocator, ttl_secs, default_max_entries);
    }

    /// Creates an empty cache whose entries each live `ttl_secs` seconds and
    /// which holds at most `max_entries` verdicts at once.
    pub fn initBounded(allocator: std.mem.Allocator, ttl_secs: i64, max_entries: usize) Cache {
        return .{
            .allocator = allocator,
            .ttl_secs = ttl_secs,
            .entries = .empty,
            .max_entries = max_entries,
        };
    }

    /// Frees every stored string and the map itself.
    pub fn deinit(self: *Cache) void {
        var it = self.entries.iterator();
        while (it.next()) |entry| freeEntry(self.allocator, entry.value_ptr.*);
        self.entries.deinit(self.allocator);
    }

    /// Returns the cached username, role, and scope for `token` when a live entry
    /// exists at `now`; a stale entry is dropped and reported as a miss (null).
    /// The slices are owned by the cache and valid until the next mutation.
    pub fn get(self: *Cache, token: []const u8, now: i64) ?Cached {
        const key = hashToken(token);
        const entry = self.entries.getPtr(key) orelse return null;
        if (entry.expires_at <= now) {
            self.dropKey(key);
            return null;
        }
        return .{ .username = entry.username, .role = entry.role, .scope = entry.scope };
    }

    /// Stores `username` (in `role`, carrying `scope`) for `token`, expiring
    /// `ttl_secs` after `now`. Elapsed entries are pruned first, and a store of a
    /// new token at the entry cap evicts the entry nearest expiry, so the cache
    /// stays hard-bounded. `scope` is the empty string for a session verdict.
    pub fn put(
        self: *Cache,
        token: []const u8,
        username: []const u8,
        role: Role,
        scope: []const u8,
        now: i64,
    ) std.mem.Allocator.Error!void {
        try self.prune(now);
        const key = hashToken(token);
        if (self.entries.count() >= self.max_entries and !self.entries.contains(key)) {
            self.evictSoonest();
        }
        const copy = try self.allocator.dupe(u8, username);
        errdefer self.allocator.free(copy);
        const scope_copy = try self.allocator.dupe(u8, scope);
        errdefer self.allocator.free(scope_copy);
        const gop = try self.entries.getOrPut(self.allocator, key);
        if (gop.found_existing) freeEntry(self.allocator, gop.value_ptr.*);
        gop.value_ptr.* = .{ .username = copy, .role = role, .scope = scope_copy, .expires_at = now + self.ttl_secs };
    }

    /// Removes every entry whose lifetime has elapsed at `now`, freeing usernames.
    fn prune(self: *Cache, now: i64) std.mem.Allocator.Error!void {
        var stale: std.ArrayList([hash_len]u8) = .empty;
        defer stale.deinit(self.allocator);
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.expires_at <= now) try stale.append(self.allocator, entry.key_ptr.*);
        }
        for (stale.items) |key| self.dropKey(key);
    }

    /// Removes the single entry whose expiry instant is nearest (with one
    /// shared TTL, the oldest store); an empty map is left untouched.
    fn evictSoonest(self: *Cache) void {
        var victim: ?[hash_len]u8 = null;
        var victim_expiry: i64 = std.math.maxInt(i64);
        var it = self.entries.iterator();
        while (it.next()) |entry| {
            if (victim == null or entry.value_ptr.expires_at < victim_expiry) {
                victim = entry.key_ptr.*;
                victim_expiry = entry.value_ptr.expires_at;
            }
        }
        if (victim) |key| self.dropKey(key);
    }

    /// Removes one entry by key, freeing its strings; an absent key is a no-op.
    fn dropKey(self: *Cache, key: [hash_len]u8) void {
        if (self.entries.fetchRemove(key)) |kv| freeEntry(self.allocator, kv.value);
    }
};

/// Frees the owned strings of one cache entry.
fn freeEntry(allocator: std.mem.Allocator, entry: Entry) void {
    allocator.free(entry.username);
    allocator.free(entry.scope);
}

/// Hashes a session token to the fixed-size key it is cached under, so the raw
/// token text never lives in the cache.
fn hashToken(token: []const u8) [hash_len]u8 {
    var digest: [hash_len]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(token, &digest, .{});
    return digest;
}

const cache_token = "session-token-value";
const cache_user = "alice";
/// Scope stored by the session-path tests (empty, as a session carries none).
const cache_scope = "";

// spec: Verdict cache - An authorized username is served from the cache again within its TTL
test "cache serves a stored username within its TTL" {
    var cache = Cache.init(std.testing.allocator, 30);
    defer cache.deinit();
    try cache.put(cache_token, cache_user, .member, cache_scope, 100);
    try std.testing.expectEqualStrings(cache_user, cache.get(cache_token, 120).?.username);
}

// spec: Verdict cache - A cache entry at or past its TTL expiry is treated as a miss
test "cache treats an expired entry as a miss" {
    var cache = Cache.init(std.testing.allocator, 30);
    defer cache.deinit();
    try cache.put(cache_token, cache_user, .member, cache_scope, 100);
    try std.testing.expect(cache.get(cache_token, 130) == null);
}

// spec: Verdict cache - Cache entries are keyed by the SHA-256 hash of the token rather than its raw text
test "cache keys entries by the token hash" {
    var cache = Cache.init(std.testing.allocator, 30);
    defer cache.deinit();
    try cache.put(cache_token, cache_user, .member, cache_scope, 100);
    try std.testing.expect(cache.entries.contains(hashToken(cache_token)));
    try std.testing.expect(!cache.entries.contains(hashToken("other-token-value")));
}

// spec: Verdict cache - Storing into the cache prunes entries whose TTL has already elapsed
test "cache prunes elapsed entries on store" {
    var cache = Cache.init(std.testing.allocator, 30);
    defer cache.deinit();
    try cache.put(cache_token, cache_user, .member, cache_scope, 100);
    try cache.put("second-token-value", "bob", .member, cache_scope, 200);
    try std.testing.expect(cache.entries.count() == 1);
}

// spec: Middleware roles - A cached authorized verdict preserves the role it was stored under
test "cache preserves the stored role" {
    var cache = Cache.init(std.testing.allocator, 30);
    defer cache.deinit();
    try cache.put(cache_token, cache_user, .admin, cache_scope, 100);
    const hit = cache.get(cache_token, 120).?;
    try std.testing.expectEqualStrings(cache_user, hit.username);
    try std.testing.expectEqual(Role.admin, hit.role);
}

// spec: Bearer cache - A cached bearer verdict preserves the scope it was stored under
test "cache preserves the stored scope" {
    var cache = Cache.init(std.testing.allocator, 30);
    defer cache.deinit();
    try cache.put(cache_token, cache_user, .member, "files:read files:write", 100);
    const hit = cache.get(cache_token, 120).?;
    try std.testing.expectEqualStrings("files:read files:write", hit.scope);
}

// spec: Verdict cache bound - A store at the entry cap evicts the entry nearest expiry to admit the new verdict
test "cache at its cap evicts the entry nearest expiry" {
    var cache = Cache.initBounded(std.testing.allocator, 300, 2);
    defer cache.deinit();
    try cache.put("token-alpha", "alice", .member, cache_scope, 100);
    try cache.put("token-bravo", "bob", .member, cache_scope, 110);
    try cache.put("token-charlie", "carol", .member, cache_scope, 120);
    try std.testing.expectEqual(@as(usize, 2), cache.entries.count());
    try std.testing.expect(cache.get("token-alpha", 121) == null);
    try std.testing.expectEqualStrings("bob", cache.get("token-bravo", 121).?.username);
    try std.testing.expectEqualStrings("carol", cache.get("token-charlie", 121).?.username);
}

// spec: Verdict cache bound - Re-storing an already cached token at the cap replaces it without evicting another entry
test "cache re-store at the cap replaces in place" {
    var cache = Cache.initBounded(std.testing.allocator, 300, 2);
    defer cache.deinit();
    try cache.put("token-alpha", "alice", .member, cache_scope, 100);
    try cache.put("token-bravo", "bob", .member, cache_scope, 110);
    try cache.put("token-alpha", "alice2", .member, cache_scope, 120);
    try std.testing.expectEqual(@as(usize, 2), cache.entries.count());
    try std.testing.expectEqualStrings("alice2", cache.get("token-alpha", 121).?.username);
    try std.testing.expectEqualStrings("bob", cache.get("token-bravo", 121).?.username);
}

// spec: Verdict cache bound - A cache created through init defaults its entry cap to 4096 entries
test "cache init applies the default entry cap" {
    var cache = Cache.init(std.testing.allocator, 30);
    defer cache.deinit();
    try std.testing.expectEqual(@as(usize, 4096), cache.max_entries);
    try std.testing.expectEqual(default_max_entries, cache.max_entries);
}
