//! Content-addressed memo for gzip-compressed response bodies.
//!
//! `serve.maybeCompress` runs after every handler, so a page that answers from
//! a rendered-HTML cache in ~1 ms still paid to re-gzip its whole body on every
//! request: a 1.2 MB schematic page cost ~150 ms of deflate per view, which
//! dwarfed the cached render it was wrapping and was the largest single term in
//! what a browser actually waited for. Memoising the compressed bytes turns
//! that back into a hash plus two copies.
//!
//! The key is the body itself, so this cache cannot go stale: a re-render that
//! changes one byte simply misses and compresses afresh. That is why it needs
//! none of the file-mtime machinery `page_cache.zig` carries — there is no
//! dependency to track when the identity IS the content. Entries are confirmed
//! with a full comparison on hit rather than trusting the 64-bit hash alone: a
//! collision would serve one page's bytes under another page's URL, and that is
//! not a risk worth a few microseconds.

const std = @import("std");
const deflate = @import("../deflate.zig");
const infra_fs = @import("../infra/fs.zig");

/// Below this a body compresses in well under a millisecond, so memoising it
/// would spend memory to save noise. The cache is for the big server-rendered
/// pages; small JSON replies keep compressing inline.
const min_body_bytes: usize = 32 * 1024;

/// Total retained bytes (uncompressed plus compressed, summed over entries)
/// before the least-recently-used entry is dropped. Sized to hold every large
/// page of a big project several times over while staying a rounding error next
/// to the evaluator state a single design build allocates.
const max_bytes: usize = 64 * 1024 * 1024;

const Entry = struct {
    /// The exact uncompressed bytes this entry answers for. Retained rather
    /// than only hashed so a hit can be confirmed by comparison.
    body: []const u8,
    /// The gzip stream for `body`.
    gz: []const u8,
    hash: u64,
    /// Stamp of the last hit, for least-recently-used eviction.
    used: u64,
};

/// One server instance's bounded gzip memo. `allocator=null` intentionally
/// disables it for lightweight handler tests that construct `ServerState{}`,
/// which then compress inline exactly as before this cache existed.
pub const Store = struct {
    allocator: ?std.mem.Allocator = null,
    mutex: infra_fs.Mutex = .{},
    entries: std.ArrayList(Entry) = .empty,
    bytes: usize = 0,
    use_clock: u64 = 0,

    /// gzip `body`, reusing a previously computed stream when this exact body
    /// has been compressed before. The result is always allocated in `alloc`
    /// (the request arena) and owned by the caller, so eviction here can never
    /// pull bytes out from under an in-flight response.
    ///
    /// Errors are the caller's existing "skip compression" signal — a memo
    /// failure degrades to sending the body uncompressed, never to sending it
    /// wrong.
    pub fn compress(self: *Store, alloc: std.mem.Allocator, body: []const u8) deflate.Error![]u8 {
        const owner = self.allocator orelse return deflate.gzip(alloc, body);
        if (body.len < min_body_bytes) return deflate.gzip(alloc, body);

        const hash = std.hash.Wyhash.hash(0, body);
        if (self.lookup(alloc, hash, body)) |hit| return hit;

        const gz = try deflate.gzip(alloc, body);
        self.store(owner, hash, body, gz);
        return gz;
    }

    /// Free every retained entry. The owning `serve()` calls this on shutdown;
    /// tests call it to keep instances independent.
    pub fn deinit(self: *Store) void {
        const owner = self.allocator orelse return;
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries.items) |e| {
            owner.free(e.body);
            owner.free(e.gz);
        }
        self.entries.clearAndFree(owner);
        self.bytes = 0;
    }

    /// A private copy of the memoised stream for `body`, or null when absent.
    fn lookup(self: *Store, alloc: std.mem.Allocator, hash: u64, body: []const u8) ?[]u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.entries.items) |*e| {
            if (e.hash != hash or e.body.len != body.len) continue;
            if (!std.mem.eql(u8, e.body, body)) continue;
            self.use_clock +%= 1;
            e.used = self.use_clock;
            // Copy out under the lock: the caller keeps its slice across later
            // evictions, which free `e.gz`.
            return alloc.dupe(u8, e.gz) catch null;
        }
        return null;
    }

    /// Retain `body`/`gz` for future requests. Best-effort: if the copies don't
    /// allocate, the next request simply compresses again.
    fn store(self: *Store, owner: std.mem.Allocator, hash: u64, body: []const u8, gz: []const u8) void {
        const body_copy = owner.dupe(u8, body) catch return;
        const gz_copy = owner.dupe(u8, gz) catch {
            owner.free(body_copy);
            return;
        };
        self.mutex.lock();
        defer self.mutex.unlock();
        self.use_clock +%= 1;
        self.entries.append(owner, .{
            .body = body_copy,
            .gz = gz_copy,
            .hash = hash,
            .used = self.use_clock,
        }) catch {
            owner.free(body_copy);
            owner.free(gz_copy);
            return;
        };
        self.bytes += body_copy.len + gz_copy.len;
        self.trim(owner);
    }

    /// Drop least-recently-used entries until the retained total is back under
    /// budget. Caller holds `mutex`.
    fn trim(self: *Store, owner: std.mem.Allocator) void {
        while (self.bytes > max_bytes and self.entries.items.len > 1) {
            var oldest: usize = 0;
            for (self.entries.items, 0..) |e, i| {
                if (e.used < self.entries.items[oldest].used) oldest = i;
            }
            const e = self.entries.swapRemove(oldest);
            self.bytes -= e.body.len + e.gz.len;
            owner.free(e.body);
            owner.free(e.gz);
        }
    }
};

// spec: Web Server - A repeated response body is gzipped once and served from a content-keyed memo
test "the same body compresses to the same bytes on a repeat request" {
    var store = Store{ .allocator = std.testing.allocator };
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const body = try makeBody(alloc, 'a');
    const first = try store.compress(alloc, body);
    try std.testing.expectEqual(@as(usize, 1), store.entries.items.len);

    const second = try store.compress(alloc, body);
    try std.testing.expectEqualSlices(u8, first, second);
    // The repeat was answered from the memo, not by adding a second entry...
    try std.testing.expectEqual(@as(usize, 1), store.entries.items.len);
    // ...and it handed back its OWN buffer, so a later eviction cannot free
    // bytes an in-flight response is still pointing at.
    try std.testing.expect(first.ptr != second.ptr);
}

// spec: Web Server - A response body that changed by one byte misses the gzip memo instead of serving the page it replaced
test "a changed body misses the memo instead of serving the previous page" {
    var store = Store{ .allocator = std.testing.allocator };
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const first_body = try makeBody(alloc, 'a');
    const edited = try makeBody(alloc, 'a');
    // One byte apart: a re-render that changes anything at all must not be
    // answered with the bytes of the page it replaced.
    edited[min_body_bytes / 2] = 'Z';

    const first = try store.compress(alloc, first_body);
    const second = try store.compress(alloc, edited);
    try std.testing.expect(!std.mem.eql(u8, first, second));
    try std.testing.expectEqual(@as(usize, 2), store.entries.items.len);

    // Both stay individually addressable — the miss added an entry, it did not
    // overwrite the one already there.
    try std.testing.expectEqualSlices(u8, first, try store.compress(alloc, first_body));
    try std.testing.expectEqual(@as(usize, 2), store.entries.items.len);
}

// spec: Web Server - A response body too small to be worth memoising is still compressed
test "bodies too small to be worth memoising still compress" {
    var store = Store{ .allocator = std.testing.allocator };
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const small = try alloc.alloc(u8, 2048);
    @memset(small, 'q');
    const gz = try store.compress(alloc, small);
    try std.testing.expect(gz.len < small.len);
    // Under the threshold nothing is retained: the cache exists for the big
    // server-rendered pages, not for every short JSON reply.
    try std.testing.expectEqual(@as(usize, 0), store.entries.items.len);
}

// spec: Web Server - A server whose gzip memo has no allocator still compresses its responses
test "a store with no allocator compresses without retaining anything" {
    // The shape `ServerState{}` yields in handler tests: the memo is off, and
    // compression must still be correct rather than skipped.
    var store = Store{};
    defer store.deinit();
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    const body = try makeBody(alloc, 'a');
    const gz = try store.compress(alloc, body);
    try std.testing.expect(gz.len < body.len);
    try std.testing.expectEqual(@as(usize, 0), store.entries.items.len);
}

/// A body large enough to be memoised, compressible but not uniform (so the
/// gzip stream is a real one rather than a degenerate run).
fn makeBody(alloc: std.mem.Allocator, seed: u8) ![]u8 {
    const buf = try alloc.alloc(u8, min_body_bytes * 2);
    for (buf, 0..) |*b, i| b.* = seed +% @as(u8, @intCast(i % 17));
    return buf;
}
