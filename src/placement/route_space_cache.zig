//! Run-scoped reuse cache for the pour-derived route-space provider.
//!
//! A routing run repeatedly asks about different endpoints and live copper on
//! the same board. The outline, pads, and zones do not change between those
//! queries, so retaining their signed-margin raster avoids rebuilding the
//! expensive static half of the field. It also retains one complete live field
//! and compact answers for identical queries; every key includes all geometry
//! that affects the cached value.

const std = @import("std");

/// Two independent hashes identify one exact immutable field configuration.
pub const Key = struct { lo: u64, hi: u64 };

/// Cacheable route-space answer independent of the provider's private types.
pub const Query = struct {
    path: ?[]const [2]f64 = null,
    requested_pitch: f64,
    pitch: f64,
    cells: usize,
    coarsened: bool,
    terminals_free: bool,
};

/// Owner of reusable signed-margin fields and paths for one routing run.
pub const Cache = struct {
    allocator: std.mem.Allocator,
    entries: std.AutoHashMapUnmanaged(Key, []f32) = .empty,
    queries: std.AutoHashMapUnmanaged(Key, Query) = .empty,
    /// Payload bytes retained by immutable rasters and compact query paths.
    /// The one `last_live` raster is bounded separately by the provider's
    /// `max_cells` (3,000,000 cells / 12 MB by default).
    bytes: usize = 0,
    max_bytes: usize = 384 * 1024 * 1024,
    last_live: struct { key: ?Key = null, margin: []f32 = &.{} } = .{},

    /// Create an empty cache backed by the caller's recyclable allocator.
    pub fn init(allocator: std.mem.Allocator) Cache {
        return .{ .allocator = allocator };
    }

    /// Release every retained raster and the lookup table.
    pub fn deinit(self: *Cache) void {
        var values = self.entries.valueIterator();
        while (values.next()) |margin| self.allocator.free(margin.*);
        var queries = self.queries.valueIterator();
        while (queries.next()) |query| if (query.path) |path| self.allocator.free(path);
        if (self.last_live.margin.len > 0) self.allocator.free(self.last_live.margin);
        self.entries.deinit(self.allocator);
        self.queries.deinit(self.allocator);
    }

    /// Return a retained raster and record whether lookup succeeded.
    pub fn get(self: *Cache, key: Key) ?[]const f32 {
        return self.entries.get(key);
    }

    /// Cache failure is an optimization miss, never a routing failure. The
    /// caller may ignore allocation errors and continue with its scratch base.
    pub fn put(self: *Cache, key: Key, margin: []const f32) std.mem.Allocator.Error!bool {
        const byte_len = std.math.mul(usize, margin.len, @sizeOf(f32)) catch return false;
        if (byte_len > self.max_bytes -| self.bytes) return false;
        const copy = try self.allocator.dupe(f32, margin);
        errdefer self.allocator.free(copy);
        const gop = try self.entries.getOrPut(self.allocator, key);
        if (gop.found_existing) {
            self.allocator.free(copy);
            return false;
        }
        gop.value_ptr.* = copy;
        self.bytes += byte_len;
        return true;
    }

    /// Return a previously computed answer for an identical live-copper query.
    pub fn getQuery(self: *Cache, key: Key) ?Query {
        return self.queries.get(key);
    }

    /// Retain a compact path answer; failure merely disables this reuse.
    pub fn putQuery(self: *Cache, key: Key, query: Query) std.mem.Allocator.Error!void {
        if (self.queries.contains(key)) return;
        const byte_len = if (query.path) |path|
            std.math.mul(usize, path.len, @sizeOf([2]f64)) catch return
        else
            0;
        if (byte_len > self.max_bytes -| self.bytes) return;

        var saved = query;
        if (query.path) |path| saved.path = try self.allocator.dupe([2]f64, path);
        errdefer if (saved.path) |path| self.allocator.free(path);
        const gop = try self.queries.getOrPut(self.allocator, key);
        if (gop.found_existing) {
            if (saved.path) |path| self.allocator.free(path);
            return;
        }
        gop.value_ptr.* = saved;
        self.bytes += byte_len;
    }

    /// Copy the most recently composed static-plus-live field when unchanged.
    pub fn getLive(self: *Cache, key: Key, out: []f32) bool {
        const saved = self.last_live.key orelse return false;
        if (saved.lo != key.lo or saved.hi != key.hi) return false;
        if (self.last_live.margin.len != out.len) return false;
        @memcpy(out, self.last_live.margin);
        return true;
    }

    /// Retain the most recent complete field for consecutive endpoint queries.
    pub fn putLive(self: *Cache, key: Key, margin: []const f32) std.mem.Allocator.Error!void {
        if (self.last_live.margin.len != margin.len) {
            const fresh = try self.allocator.alloc(f32, margin.len);
            if (self.last_live.margin.len > 0) self.allocator.free(self.last_live.margin);
            self.last_live.margin = fresh;
        }
        @memcpy(self.last_live.margin, margin);
        self.last_live.key = key;
    }
};

// spec: placement/router - route-space immutable rasters and cached path payloads share one memory budget while the single live raster is independently cell-bounded
test "query paths share the immutable route-space cache budget" {
    const testing = std.testing;
    var cache = Cache.init(testing.allocator);
    defer cache.deinit();
    cache.max_bytes = 2 * @sizeOf([2]f64);

    const raster = [_]f32{ 1, 2, 3, 4 };
    try testing.expect(try cache.put(.{ .lo = 1, .hi = 1 }, &raster));

    const first_path = [_][2]f64{.{ 1, 2 }};
    try cache.putQuery(.{ .lo = 2, .hi = 2 }, .{
        .path = &first_path,
        .requested_pitch = 0.05,
        .pitch = 0.05,
        .cells = 10,
        .coarsened = false,
        .terminals_free = true,
    });
    try testing.expect(cache.getQuery(.{ .lo = 2, .hi = 2 }) != null);
    try testing.expectEqual(cache.max_bytes, cache.bytes);

    const second_path = [_][2]f64{.{ 3, 4 }};
    try cache.putQuery(.{ .lo = 3, .hi = 3 }, .{
        .path = &second_path,
        .requested_pitch = 0.05,
        .pitch = 0.05,
        .cells = 10,
        .coarsened = false,
        .terminals_free = true,
    });
    try testing.expect(cache.getQuery(.{ .lo = 3, .hi = 3 }) == null);
    try testing.expectEqual(cache.max_bytes, cache.bytes);
}

test "duplicate query insertion neither replaces nor recounts its path" {
    const testing = std.testing;
    var cache = Cache.init(testing.allocator);
    defer cache.deinit();
    cache.max_bytes = 2 * @sizeOf([2]f64);

    const original_path = [_][2]f64{.{ 1, 2 }};
    const replacement_path = [_][2]f64{ .{ 3, 4 }, .{ 5, 6 } };
    const key: Key = .{ .lo = 1, .hi = 2 };
    try cache.putQuery(key, .{
        .path = &original_path,
        .requested_pitch = 0.05,
        .pitch = 0.05,
        .cells = 10,
        .coarsened = false,
        .terminals_free = true,
    });
    const retained_bytes = cache.bytes;
    try cache.putQuery(key, .{
        .path = &replacement_path,
        .requested_pitch = 0.1,
        .pitch = 0.1,
        .cells = 20,
        .coarsened = true,
        .terminals_free = false,
    });

    const saved = cache.getQuery(key).?;
    try testing.expectEqualSlices([2]f64, &original_path, saved.path.?);
    try testing.expectEqual(@as(f64, 0.05), saved.pitch);
    try testing.expectEqual(retained_bytes, cache.bytes);
}
