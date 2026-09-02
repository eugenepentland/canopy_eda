//! The bookkeeping every dependency-validated server cache is built from.
//!
//! Seven stores in `src/serve/` retain a derived answer against a
//! `page_cache.FileSet` and a live-edit version: the generic response-body
//! store (`read_cache.zig`, which the describe / progress / image / ERC /
//! thermal / PDF / KiCad surfaces all instantiate), the rendered PCB page
//! (`pcb_page_cache.zig`), the assembly workspace (`assembly_page_cache.zig`)
//! and the solved thermal fields (`thermal_cache.zig`). The first three hold
//! bytes; the last holds `[]ScenarioResult`. What they genuinely share is not
//! the payload but the BOOKKEEPING around it — a `StringHashMapUnmanaged` of
//! entries, a byte total, a monotonic use clock, an LRU sweep back inside two
//! budgets, and a teardown that frees every entry — and each store had
//! hand-copied both loops. Six copies of the eviction sweep drifted apart in
//! exactly the way `twin-drift` names: three of them prefer to evict a query
//! VARIANT over the plain answer every caller asks for, three never learned to.
//!
//! `evictLru` and `freeAll` are therefore duck-typed over the store rather than
//! generic over the payload: a store qualifies by having `allocator`, `entries`
//! and `bytes` fields and a `freeEntry` method, which is the whole contract, and
//! its entries opt into variant-preference simply by carrying a `plain` field.
//! A store with no such field is swept in plain LRU order, which is what a store
//! whose keys have no variants wants anyway.
//!
//! The other half of the shape — the hit / compute / frame / retain body the
//! cached GET handlers share — lives in `page_cache_endpoint.zig`, which reads
//! a store through the same duck typing.

const std = @import("std");

/// Evict least-recently-used entries from `store` until it is back inside both
/// budgets, preferring VARIANTS: when the entry type carries a `plain` flag, a
/// burst of keyed variants (a `?crop=` sweep, a themed re-render) is spent
/// before the query-free answer every caller asks for is displaced. An entry
/// type without that field is swept in plain LRU order.
///
/// `store` must own the `entries` map, the `bytes` total and a
/// `freeEntry(allocator, key, entry)` that releases one entry and un-charges its
/// bytes. The caller holds whatever lock the store uses; this does not take one.
pub fn evictLru(
    store: anytype,
    allocator: std.mem.Allocator,
    max_entries: usize,
    max_bytes: usize,
) void {
    while (store.entries.count() > max_entries or store.bytes > max_bytes) {
        var oldest_key: ?[]const u8 = null;
        var oldest_use: u64 = std.math.maxInt(u64);
        var oldest_variant_key: ?[]const u8 = null;
        var oldest_variant_use: u64 = std.math.maxInt(u64);
        var it = store.entries.iterator();
        while (it.next()) |kv| {
            if (kv.value_ptr.used < oldest_use) {
                oldest_key = kv.key_ptr.*;
                oldest_use = kv.value_ptr.used;
            }
            if (comptime @hasField(@TypeOf(kv.value_ptr.*), "plain")) {
                if (!kv.value_ptr.plain and kv.value_ptr.used < oldest_variant_use) {
                    oldest_variant_key = kv.key_ptr.*;
                    oldest_variant_use = kv.value_ptr.used;
                }
            }
        }
        const key = oldest_variant_key orelse oldest_key orelse return;
        const removed = store.entries.fetchRemove(key) orelse return;
        store.freeEntry(allocator, removed.key, removed.value);
    }
}

/// Free every retained entry and the map itself, leaving `store.entries` empty.
/// A store with no allocator never retained anything, so this is a no-op there.
/// Callers follow it with `self.* = .{}`; the key slices are freed while the
/// iterator still walks the table, which is safe because iteration never hashes
/// a key it has already passed.
pub fn freeAll(store: anytype) void {
    const allocator = store.allocator orelse return;
    var it = store.entries.iterator();
    while (it.next()) |kv| store.freeEntry(allocator, kv.key_ptr.*, kv.value_ptr.*);
    store.entries.deinit(allocator);
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// A store shaped like the real ones for the sweep under test: entries carry a
/// recency stamp and a `plain` flag, and `freeEntry` un-charges the bytes.
const VariantStore = struct {
    const Entry = struct { bytes: usize, used: u64, plain: bool };

    allocator: ?std.mem.Allocator = null,
    entries: std.StringHashMapUnmanaged(Entry) = .empty,
    bytes: usize = 0,
    freed: usize = 0,

    fn freeEntry(self: *VariantStore, allocator: std.mem.Allocator, key: []const u8, entry: Entry) void {
        self.bytes -= entry.bytes;
        self.freed += 1;
        allocator.free(key);
    }

    fn put(self: *VariantStore, key: []const u8, used: u64, plain: bool) !void {
        const owned = try testing.allocator.dupe(u8, key);
        try self.entries.put(testing.allocator, owned, .{ .bytes = 10, .used = used, .plain = plain });
        self.bytes += 10;
    }
};

/// The same store without the `plain` field — a cache whose keys have no
/// variants, which must still be swept in plain recency order.
const PlainStore = struct {
    const Entry = struct { bytes: usize, used: u64 };

    allocator: ?std.mem.Allocator = null,
    entries: std.StringHashMapUnmanaged(Entry) = .empty,
    bytes: usize = 0,

    fn freeEntry(self: *PlainStore, allocator: std.mem.Allocator, key: []const u8, entry: Entry) void {
        self.bytes -= entry.bytes;
        allocator.free(key);
    }

    fn put(self: *PlainStore, key: []const u8, used: u64) !void {
        const owned = try testing.allocator.dupe(u8, key);
        try self.entries.put(testing.allocator, owned, .{ .bytes = 10, .used = used });
        self.bytes += 10;
    }
};

// spec: Web Server - The shared cache eviction sweep spends a keyed variant before the plain answer
test "the shared LRU sweep evicts a variant before the plain answer it is bounded against" {
    var store: VariantStore = .{ .allocator = testing.allocator };
    defer freeAll(&store);

    // The plain answer is the OLDEST entry, so plain recency would evict it
    // first. Variant preference is what keeps the navigation hot path.
    try store.put("plain", 1, true);
    try store.put("variant-old", 2, false);
    try store.put("variant-new", 3, false);
    evictLru(&store, testing.allocator, 2, 1000);
    try testing.expectEqual(@as(usize, 2), store.entries.count());
    try testing.expect(store.entries.contains("plain"));
    try testing.expect(!store.entries.contains("variant-old"));

    // The byte budget binds independently of the entry count, and `freeEntry`
    // is what un-charges it — so the total tracks what is actually held.
    evictLru(&store, testing.allocator, 100, 10);
    try testing.expectEqual(@as(usize, 1), store.entries.count());
    try testing.expectEqual(@as(usize, 10), store.bytes);
    try testing.expectEqual(@as(usize, 2), store.freed);
}

// spec: Web Server - The shared cache eviction sweep falls back to plain recency for a store whose entries carry no variant flag
test "the shared LRU sweep orders a variant-free store by recency alone" {
    var store: PlainStore = .{ .allocator = testing.allocator };
    defer freeAll(&store);

    try store.put("oldest", 1);
    try store.put("middle", 2);
    try store.put("newest", 3);
    evictLru(&store, testing.allocator, 2, 1000);
    try testing.expectEqual(@as(usize, 2), store.entries.count());
    try testing.expect(!store.entries.contains("oldest"));
    try testing.expect(store.entries.contains("newest"));
}

// spec: Web Server - A shared-core cache teardown frees every retained entry, and does nothing at all for a store that was never given an allocator
test "the shared teardown frees every entry and no-ops on a disabled store" {
    var store: VariantStore = .{ .allocator = testing.allocator };
    try store.put("a", 1, true);
    try store.put("b", 2, false);
    freeAll(&store);
    try testing.expectEqual(@as(usize, 2), store.freed);
    try testing.expectEqual(@as(usize, 0), store.bytes);

    // A store that was never handed an allocator retained nothing, so tearing
    // it down must not touch the map it never filled.
    var off: PlainStore = .{};
    freeAll(&off);
    try testing.expectEqual(@as(usize, 0), off.entries.count());
}
