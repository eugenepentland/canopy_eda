//! Dependency-aware cache for the spatial-facts JSON served by
//! `GET /api/pcb-describe/:name`.
//!
//! This is the endpoint agent loops and review tooling hit hardest, and it was
//! the only expensive one left with no retention at all: measured on this
//! project's boards, two identical back-to-back requests for `barracuda` cost
//! **6.570 s and 6.574 s** against an already-warm server — the second paid the
//! first's work over again, byte for byte. Each call runs
//! `pcb_layout_page.solveForRequest` (design evaluation + a multi-megabyte
//! `.layouts.json` parse + the placement) and then the full reporting DRC
//! (`drc_rules.checkFilteredZones`, whose `net_open`/pour raster dominates),
//! and the answer it produces is a pure function of the design's sources and
//! its sidecars. So it is kept in process memory and invalidated the ordinary
//! way: the evaluator read-set, the layout / DRC-override sidecars, and the
//! design's live-edit version — the same contract `progress_cache.zig` uses for
//! the completion ladder and `pcb_page_cache.zig` for the rendered PCB page.
//! The dependency set is literally the ladder's (`progress_cache.captureDeps`):
//! the facts document *embeds* that ladder, and reads no sidecar it doesn't.
//!
//! Only query modes whose cache semantics have been considered may share an
//! entry, and they are folded into the key rather than ignored — the strict
//! allow-list `pcb_page_cache` uses, so a future server-side query parameter
//! bypasses by default instead of silently aliasing onto someone else's facts.
//! `?route=1` (route fresh, with stuck-net diagnostics) and `?regen=1` (force a
//! fresh solve) are one-shot modes whose whole point is to recompute, so they
//! bypass along with every unrecognised parameter.

const std = @import("std");
const httpz = @import("httpz");
const infra_fs = @import("../infra/fs.zig");
const page_cache = @import("page_cache.zig");

/// Entry cap. A handful of designs times the few keyed variants below; the
/// byte budget is the real limit on a board whose facts run large.
const describe_max_entries: usize = 32;
/// Total byte budget of this store, and the largest single body it will admit.
/// Its own figure: a facts document is far bigger than a ladder (it carries the
/// per-part, per-loop and per-DRC-finding detail) and far smaller than a
/// rendered PCB page, so it is neither of those stores' budget.
const describe_max_bytes: usize = 64 * 1024 * 1024;
const cache_header = "X-Netlisp-Describe-Cache";

/// Query keys that change the facts deterministically, each folded into the
/// key so one design can hold several: `layout` picks which saved board is
/// described, `cropnet` adds the zoom lens' world bbox, and `pads` adds the
/// per-part pad detail. Everything else — `route`, `regen`, `sub`, the tuning
/// knobs, and every PNG-only framing parameter — bypasses.
const keyed_params = [_][]const u8{ "layout", "cropnet", "pads" };

const Identity = struct { keyed: [keyed_params.len]?[]const u8 };

/// The query-free request an agent loop and the review tooling actually send.
/// Variant pressure evicts a variant before displacing one of these.
fn isPlain(ident: Identity) bool {
    for (ident.keyed) |value| if (value != null) return false;
    return true;
}

/// The cache identity of `req`, or null when it must bypass. Strict
/// allow-listing: a parameter is either one of `keyed_params` — folded into the
/// key — or it disqualifies the request outright. `?sub=` bypasses because a
/// sub-scoped view reads its own `<design>.<sub>.layouts.json`, which the
/// shared read-set does not stamp; `?route=1` and `?regen=1` bypass because
/// recomputing is what they were asked for.
fn identity(req: *httpz.Request) ?Identity {
    const q = req.query() catch return null;
    var it = q.iterator();
    outer: while (it.next()) |field| {
        for (keyed_params) |allowed| {
            if (std.mem.eql(u8, field.key, allowed)) continue :outer;
        }
        return null;
    }
    var ident = Identity{ .keyed = @splat(null) };
    for (keyed_params, &ident.keyed) |param, *slot| slot.* = q.get(param);
    return ident;
}

/// `<name>` for the plain request, `<name>\0<param>\0<value>…` once a keyed
/// parameter participates. NUL-separated so no design or layout name can spell
/// another entry's key.
fn cacheKey(allocator: std.mem.Allocator, name: []const u8, ident: Identity) std.mem.Allocator.Error![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    w.writeAll(name) catch return error.OutOfMemory;
    for (keyed_params, ident.keyed) |param, value| {
        if (value) |v| w.print("\x00{s}\x00{s}", .{ param, v }) catch return error.OutOfMemory;
    }
    return allocator.dupe(u8, aw.written());
}

/// Everything one retention needs beyond the store itself: the scratch the key
/// is built in, the entry's identity, the body, its stamped dependencies, and
/// the live version the body was computed against.
const Retain = struct {
    scratch: std.mem.Allocator,
    name: []const u8,
    ident: Identity,
    json: []const u8,
    files: page_cache.FileSet,
    live_version: u32,
};

const Entry = struct {
    json: []const u8,
    files: page_cache.FileSet,
    live_version: u32,
    used: u64,
    plain: bool,
};

/// One server instance's bounded facts-JSON cache. `allocator=null`
/// intentionally disables it for handler tests that construct `ServerState{}`.
pub const Store = struct {
    allocator: ?std.mem.Allocator = null,
    mutex: infra_fs.Mutex = .{},
    entries: std.StringHashMapUnmanaged(Entry) = .empty,
    bytes: usize = 0,
    use_clock: u64 = 0,

    fn nextUse(self: *Store) u64 {
        self.use_clock +%= 1;
        return self.use_clock;
    }

    fn freeEntry(self: *Store, allocator: std.mem.Allocator, key: []const u8, entry: Entry) void {
        self.bytes -= entry.json.len;
        allocator.free(key);
        allocator.free(entry.json);
        entry.files.deinit();
    }

    /// Evict least-recently-used until the store is back inside both budgets,
    /// preferring variants: a `?cropnet=` burst must not displace the plain
    /// facts every caller asks for.
    fn trim(self: *Store, allocator: std.mem.Allocator) void {
        while (self.entries.count() > describe_max_entries or self.bytes > describe_max_bytes) {
            var oldest_key: ?[]const u8 = null;
            var oldest_use: u64 = std.math.maxInt(u64);
            var oldest_variant_key: ?[]const u8 = null;
            var oldest_variant_use: u64 = std.math.maxInt(u64);
            var it = self.entries.iterator();
            while (it.next()) |kv| {
                if (kv.value_ptr.used < oldest_use) {
                    oldest_key = kv.key_ptr.*;
                    oldest_use = kv.value_ptr.used;
                }
                if (!kv.value_ptr.plain and kv.value_ptr.used < oldest_variant_use) {
                    oldest_variant_key = kv.key_ptr.*;
                    oldest_variant_use = kv.value_ptr.used;
                }
            }
            const key = oldest_variant_key orelse oldest_key orelse return;
            const removed = self.entries.fetchRemove(key) orelse return;
            self.freeEntry(allocator, removed.key, removed.value);
        }
    }

    /// Free every retained body when its owning server stops.
    pub fn deinit(self: *Store) void {
        const allocator = self.allocator orelse return;
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            allocator.free(kv.value_ptr.json);
            kv.value_ptr.files.deinit();
        }
        self.entries.deinit(allocator);
        self.* = .{};
    }

    /// Serve a valid cache hit and return true. `in` supplies scratch, request,
    /// response, design name, and the live version read before the request ran.
    /// On a miss `miss_version` receives that version so `store` can refuse to
    /// retain a body an edit raced.
    pub fn serve(self: *Store, in: anytype, miss_version: *?u32) bool {
        const allocator = self.allocator orelse return false;
        miss_version.* = null;
        const ident = identity(in.req) orelse {
            in.res.header(cache_header, "bypass");
            return false;
        };
        const key = cacheKey(in.scratch, in.name, ident) catch {
            in.res.header(cache_header, "bypass");
            return false;
        };

        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = self.entries.getPtr(key) orelse {
            miss_version.* = in.live_version;
            in.res.header(cache_header, "miss");
            return false;
        };
        if (entry.live_version != in.live_version or !entry.files.isValid()) {
            const removed = self.entries.fetchRemove(key).?;
            self.freeEntry(allocator, removed.key, removed.value);
            miss_version.* = in.live_version;
            in.res.header(cache_header, "miss");
            return false;
        }
        const body = in.scratch.dupe(u8, entry.json) catch {
            miss_version.* = in.live_version;
            in.res.header(cache_header, "miss");
            return false;
        };
        entry.used = self.nextUse();
        in.res.header(cache_header, "hit");
        in.res.content_type = .JSON;
        in.res.body = body;
        return true;
    }

    /// Retain a freshly computed facts body. `in.files` is the read-set the
    /// handler captured from the evaluator(s) that produced it; an EMPTY set is
    /// refused, because a set that stamps nothing can never go stale and would
    /// pin the first answer forever.
    pub fn store(self: *Store, in: anytype) void {
        const allocator = self.allocator orelse return;
        const live_version = in.live_version orelse return;
        const files = in.files orelse return;
        const ident = identity(in.req);
        // A body is retained only when it is a complete answer that fits the
        // budget, keys on something that CAN go stale (a non-empty read-set),
        // was not raced by a live edit, and came from a cacheable query mode.
        const admissible = blk: {
            if (in.res.status != 200 or in.json.len > describe_max_bytes) break :blk false;
            if (files.stamps.len == 0 or in.current_version != live_version) break :blk false;
            break :blk ident != null;
        };
        if (!admissible) {
            files.deinit();
            return;
        }
        self.retain(allocator, .{
            .scratch = in.scratch,
            .name = in.name,
            .ident = ident.?,
            .json = in.json,
            .files = files,
            .live_version = live_version,
        });
    }

    /// Take ownership of `files` and a copy of `json` under this request's key,
    /// evicting any previous entry for it.
    fn retain(self: *Store, allocator: std.mem.Allocator, in: Retain) void {
        const files = in.files;
        const scratch_key = cacheKey(in.scratch, in.name, in.ident) catch {
            files.deinit();
            return;
        };
        const body = allocator.dupe(u8, in.json) catch {
            files.deinit();
            return;
        };
        const key = allocator.dupe(u8, scratch_key) catch {
            files.deinit();
            allocator.free(body);
            return;
        };

        self.mutex.lock();
        defer self.mutex.unlock();
        const gop = self.entries.getOrPut(allocator, key) catch {
            files.deinit();
            allocator.free(body);
            allocator.free(key);
            return;
        };
        if (gop.found_existing) {
            allocator.free(key); // the map keeps the original key
            self.bytes -= gop.value_ptr.json.len;
            allocator.free(gop.value_ptr.json);
            gop.value_ptr.files.deinit();
        }
        gop.value_ptr.* = .{
            .json = body,
            .files = files,
            .live_version = in.live_version,
            .used = self.nextUse(),
            .plain = isPlain(in.ident),
        };
        self.bytes += body.len;
        self.trim(allocator);
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

// spec: Web Server - The PCB-describe endpoint caches only its allow-listed query modes and bypasses fresh-solve and sub-scoped requests
test "describe cache allow-lists its query modes and keys the ones it admits" {
    const testing = std.testing;

    var plain = httpz.testing.init(.{});
    defer plain.deinit();
    const plain_ident = identity(plain.req).?;
    try testing.expect(isPlain(plain_ident));

    // `?route=1` re-routes and `?regen=1` re-solves — one-shot modes whose
    // whole purpose is to recompute, so neither may read or write an entry.
    var routed = httpz.testing.init(.{});
    defer routed.deinit();
    routed.query("route", "1");
    try testing.expect(identity(routed.req) == null);

    var regen = httpz.testing.init(.{});
    defer regen.deinit();
    regen.query("regen", "1");
    try testing.expect(identity(regen.req) == null);

    // A sub-scoped view reads a per-sub sidecar the shared read-set never
    // stamps, so it bypasses rather than risking an entry nothing invalidates.
    var sub = httpz.testing.init(.{});
    defer sub.deinit();
    sub.query("sub", "amp1");
    try testing.expect(identity(sub.req) == null);

    // Unrecognised parameters bypass by default — the whole point of the
    // allow-list is that a new server-side query feature is safe until its
    // cache semantics are considered.
    var unknown = httpz.testing.init(.{});
    defer unknown.deinit();
    unknown.query("court_overlap", "0.2");
    try testing.expect(identity(unknown.req) == null);

    // The admitted modes are keyed, not ignored: each describes a different
    // board, so none of them may answer another's request.
    var named = httpz.testing.init(.{});
    defer named.deinit();
    named.query("layout", "RF-final");
    const named_ident = identity(named.req).?;
    try testing.expect(!isPlain(named_ident));
    const plain_key = try cacheKey(testing.allocator, "demo", plain_ident);
    defer testing.allocator.free(plain_key);
    const named_key = try cacheKey(testing.allocator, "demo", named_ident);
    defer testing.allocator.free(named_key);
    try testing.expect(!std.mem.eql(u8, plain_key, named_key));
}

// spec: Web Server - The PCB-describe endpoint reuses a dependency-validated facts document and invalidates it when the design or its sidecars change
test "describe cache hits then invalidates after a layout-sidecar edit" {
    const testing = std.testing;
    const progress_cache = @import("progress_cache.zig");
    const Evaluator = @import("../eval/evaluator.zig").Evaluator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "src", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/demo.sexp", .data = "(design demo)" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/demo.layouts.json", .data = "{}" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    var cache: Store = .{ .allocator = testing.allocator };
    defer cache.deinit();
    var eval = Evaluator.init(testing.allocator, root);
    defer eval.deinit();

    var first = httpz.testing.init(.{});
    defer first.deinit();
    var version: ?u32 = null;
    try testing.expect(!cache.serve(.{
        .scratch = first.arena,
        .req = first.req,
        .res = first.res,
        .name = "demo",
        .live_version = @as(u32, 0),
    }, &version));
    first.res.status = 200;
    cache.store(.{
        .scratch = first.arena,
        .req = first.req,
        .res = first.res,
        .name = "demo",
        .json = "{\"design\":\"demo\"}",
        .files = progress_cache.captureDeps(first.arena, &.{&eval}, root, "demo"),
        .live_version = version,
        .current_version = @as(u32, 0),
    });

    var hit = httpz.testing.init(.{});
    defer hit.deinit();
    try testing.expect(cache.serve(.{
        .scratch = hit.arena,
        .req = hit.req,
        .res = hit.res,
        .name = "demo",
        .live_version = @as(u32, 0),
    }, &version));
    try testing.expectEqualStrings("{\"design\":\"demo\"}", hit.res.body);

    // The plain entry is not the `?layout=` one: a named board's facts must
    // never be answered from the starred default's, or the other way round.
    var variant = httpz.testing.init(.{});
    defer variant.deinit();
    variant.query("layout", "RF-final");
    try testing.expect(!cache.serve(.{
        .scratch = variant.arena,
        .req = variant.req,
        .res = variant.res,
        .name = "demo",
        .live_version = @as(u32, 0),
    }, &version));

    // Saving a layout rewrites the sidecar → new poses, new copper, new DRC,
    // so the retained facts must not be served.
    var sidecar = try tmp.dir.openFile(std.testing.io, "src/demo.layouts.json", .{ .mode = .read_write });
    defer sidecar.close(std.testing.io);
    const stat = try sidecar.stat(std.testing.io);
    try sidecar.setTimestamps(std.testing.io, .{
        .access_timestamp = .init(stat.atime),
        .modify_timestamp = .{ .new = stat.mtime.addDuration(.{ .nanoseconds = std.time.ns_per_s }) },
    });
    var stale = httpz.testing.init(.{});
    defer stale.deinit();
    try testing.expect(!cache.serve(.{
        .scratch = stale.arena,
        .req = stale.req,
        .res = stale.res,
        .name = "demo",
        .live_version = @as(u32, 0),
    }, &version));
}

// spec: Web Server - The PCB-describe cache refuses a body whose dependency set stamps nothing
test "describe cache refuses an empty dependency set and an uncacheable mode" {
    const testing = std.testing;
    var cache: Store = .{ .allocator = testing.allocator };
    defer cache.deinit();

    var req = httpz.testing.init(.{});
    defer req.deinit();
    req.res.status = 200;
    // A read-set that stamps nothing could never go stale, so caching against
    // it would pin the first answer for the life of the process.
    cache.store(.{
        .scratch = req.arena,
        .req = req.req,
        .res = req.res,
        .name = "demo",
        .json = "{}",
        .files = @as(?page_cache.FileSet, null),
        .live_version = @as(?u32, 0),
        .current_version = @as(u32, 0),
    });
    try testing.expectEqual(@as(usize, 0), cache.entries.count());

    // A bypassing mode may not write an entry either — a `?route=1` body
    // describes copper this board does not have saved.
    var fresh = httpz.testing.init(.{});
    defer fresh.deinit();
    fresh.query("route", "1");
    fresh.res.status = 200;
    cache.store(.{
        .scratch = fresh.arena,
        .req = fresh.req,
        .res = fresh.res,
        .name = "demo",
        .json = "{}",
        .files = @as(?page_cache.FileSet, try page_cache.captureOne("build.zig")),
        .live_version = @as(?u32, 0),
        .current_version = @as(u32, 0),
    });
    try testing.expectEqual(@as(usize, 0), cache.entries.count());
}
