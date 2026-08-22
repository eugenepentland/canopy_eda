//! Dependency-aware cache for the compact PCB-completion ladder JSON served by
//! `GET /api/layout-progress/:name`.
//!
//! The home page lazily hydrates one of these per design card, so a single
//! reload fires the endpoint once per board — and each call re-evaluates the
//! design, re-parses its (potentially multi-megabyte) layout sidecar, and then
//! rasters every retained copper pour to answer the routing rung. Measured on
//! this project's boards, that is 0.1 s for a stub design and **100 s** for a
//! poured one (`barracuda-base`, 15 zones), with none of it retained: the next
//! reload paid it all again. The ladder is a pure function of the design's
//! sources and its sidecars, so it is kept in process memory and invalidated by
//! the evaluator read-set, the layout / DRC-override sidecars, and the design's
//! live-edit version — the same contract `pcb_page_cache.zig` uses for the
//! rendered PCB page.
//!
//! Only the plain, query-free request is cacheable. Every parameter the ladder
//! endpoint accepts (`?layout=`, `?sub=`, `?regen=1`, `?route=1`, the tuning
//! knobs) selects a different board or forces a fresh solve, and the home page
//! never sends one — so an unrecognised query bypasses the cache entirely
//! rather than risking a mismatched entry.

const std = @import("std");
const httpz = @import("httpz");
const infra_fs = @import("../infra/fs.zig");
const paths = @import("../paths.zig");
const page_cache = @import("page_cache.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;

/// Entry cap. Each body is a few kilobytes of ladder JSON, so this is a
/// generous ceiling for any real project's design count.
const ladder_max_entries: usize = 64;
/// Total byte budget of this store, and the largest single body it will admit.
/// Deliberately its own figure — a ladder is orders of magnitude smaller than a
/// rendered PCB page, so it is not the rendered-page cache's budget.
const ladder_max_bytes: usize = 8 * 1024 * 1024;
const cache_header = "X-Netlisp-Progress-Cache";

/// Sidecars the ladder reads that the evaluator never parses, so
/// `page_cache.capture` cannot know about them: the saved layouts (poses +
/// persisted copper — what the routing and placement rungs are computed from),
/// the legacy single-layout file still honoured as a fallback, and the design's
/// per-kind DRC severity overrides (they decide which violations the fab rung
/// counts as blocking). A module `(sub-block …)`'s own `<module>.layouts.json`
/// — read for each sub-circuit's ★ status — is already stamped by `capture`
/// for every loaded `lib/modules/*.sexp`.
const sidecar_exts = [_][]const u8{ ".layouts.json", ".autolayout.json", ".drc-rules.json" };

const Entry = struct {
    json: []const u8,
    files: page_cache.FileSet,
    live_version: u32,
    used: u64,
};

/// True when the request is the plain `/api/layout-progress/:name` the home
/// page sends — no query at all. Anything else picks a different board or
/// forces a solve and is deliberately not cached.
fn cacheable(req: *httpz.Request) bool {
    const q = req.query() catch return false;
    return q.len == 0;
}

/// One server instance's bounded ladder-JSON cache. `allocator=null`
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

    fn trim(self: *Store, allocator: std.mem.Allocator) void {
        while (self.entries.count() > ladder_max_entries or self.bytes > ladder_max_bytes) {
            var oldest_key: ?[]const u8 = null;
            var oldest_use: u64 = std.math.maxInt(u64);
            var it = self.entries.iterator();
            while (it.next()) |kv| {
                if (kv.value_ptr.used < oldest_use) {
                    oldest_key = kv.key_ptr.*;
                    oldest_use = kv.value_ptr.used;
                }
            }
            const key = oldest_key orelse return;
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
        if (!cacheable(in.req)) {
            in.res.header(cache_header, "bypass");
            return false;
        }

        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = self.entries.getPtr(in.name) orelse {
            miss_version.* = in.live_version;
            in.res.header(cache_header, "miss");
            return false;
        };
        if (entry.live_version != in.live_version or !entry.files.isValid()) {
            const removed = self.entries.fetchRemove(in.name).?;
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

    /// Retain a freshly computed ladder body. `in.files` is the read-set the
    /// handler captured from the evaluator(s) that produced it; an EMPTY set is
    /// refused, because a set that stamps nothing can never go stale and would
    /// pin the first answer forever.
    pub fn store(self: *Store, in: anytype) void {
        const allocator = self.allocator orelse return;
        const live_version = in.live_version orelse return;
        const files = in.files orelse return;
        // A body is retained only when it is a complete answer that fits the
        // budget, keys on something that CAN go stale (a non-empty read-set),
        // was not raced by a live edit, and came from the query-free request.
        const admissible = blk: {
            if (in.res.status != 200 or in.json.len > ladder_max_bytes) break :blk false;
            if (files.stamps.len == 0 or in.current_version != live_version) break :blk false;
            break :blk cacheable(in.req);
        };
        if (!admissible) {
            files.deinit();
            return;
        }
        self.retain(allocator, in.name, in.json, files, live_version);
    }

    /// Retain a ladder computed OFF-request — the startup warm-up
    /// (`serve/warmup.zig`), which has no `httpz` request to be judged as
    /// query-free and no response status to check. It computed the query-free
    /// body directly, so those two admission rules are satisfied by
    /// construction; the size and read-set rules still apply.
    pub fn warm(
        self: *Store,
        name: []const u8,
        json: []const u8,
        files: page_cache.FileSet,
        live_version: u32,
    ) void {
        const allocator = self.allocator orelse {
            files.deinit();
            return;
        };
        if (json.len > ladder_max_bytes or files.stamps.len == 0) {
            files.deinit();
            return;
        }
        self.retain(allocator, name, json, files, live_version);
    }

    /// Take ownership of `files` and a copy of `json` under `name`, evicting
    /// any previous entry. Shared by the request path and the warm-up so both
    /// produce byte-identical cache state.
    fn retain(
        self: *Store,
        allocator: std.mem.Allocator,
        name: []const u8,
        json: []const u8,
        files: page_cache.FileSet,
        live_version: u32,
    ) void {
        const body = allocator.dupe(u8, json) catch {
            files.deinit();
            return;
        };
        const key = allocator.dupe(u8, name) catch {
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
        gop.value_ptr.* = .{ .json = body, .files = files, .live_version = live_version, .used = self.nextUse() };
        self.bytes += body.len;
        self.trim(allocator);
    }
};

/// Capture the dependency set of a just-computed ladder: everything the
/// evaluator(s) read, plus the sidecars above. `evals` is the design evaluator
/// and — when `name` resolved to a bare `lib/modules` module instead — the
/// module resolver's own evaluator, whose read-set is the real one.
pub fn captureDeps(
    scratch: std.mem.Allocator,
    evals: []const *const Evaluator,
    project_dir: []const u8,
    name: []const u8,
) ?page_cache.FileSet {
    var extras: std.ArrayList([]const u8) = .empty;
    defer extras.deinit(scratch);
    for (sidecar_exts) |ext| {
        const p = paths.designSiblingPath(scratch, project_dir, name, ext) catch continue;
        extras.append(scratch, p) catch continue;
    }
    return page_cache.captureMerged(scratch, evals, project_dir, name, extras.items);
}

// ── Tests ──────────────────────────────────────────────────────────────

// spec: Web Server - The layout-progress ladder endpoint bypasses its cache for any query parameter
test "progress cache admits only the query-free request" {
    var plain = httpz.testing.init(.{});
    defer plain.deinit();
    try std.testing.expect(cacheable(plain.req));

    var named = httpz.testing.init(.{});
    defer named.deinit();
    named.query("layout", "RF-final");
    try std.testing.expect(!cacheable(named.req));

    var routed = httpz.testing.init(.{});
    defer routed.deinit();
    routed.query("route", "1");
    try std.testing.expect(!cacheable(routed.req));

    var sub = httpz.testing.init(.{});
    defer sub.deinit();
    sub.query("sub", "amp1");
    try std.testing.expect(!cacheable(sub.req));
}

// spec: Web Server - The layout-progress ladder endpoint reuses a dependency-validated JSON body and invalidates it when the design or its sidecars change
test "progress cache hits then invalidates after a layout-sidecar edit" {
    const testing = std.testing;
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
        .req = first.req,
        .res = first.res,
        .name = "demo",
        .json = "{\"name\":\"demo\"}",
        .files = captureDeps(first.arena, &.{&eval}, root, "demo"),
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
    try testing.expectEqualStrings("{\"name\":\"demo\"}", hit.res.body);

    // Starring a different layout rewrites the sidecar → the ladder's routing
    // and placement rungs change, so the retained body must not be served.
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

// spec: Web Server - The layout-progress cache refuses a body whose dependency set stamps nothing
test "progress cache refuses an empty dependency set" {
    const testing = std.testing;
    var cache: Store = .{ .allocator = testing.allocator };
    defer cache.deinit();

    var req = httpz.testing.init(.{});
    defer req.deinit();
    req.res.status = 200;
    // A read-set that stamps nothing could never go stale, so caching against
    // it would pin the first answer for the life of the process.
    cache.store(.{
        .req = req.req,
        .res = req.res,
        .name = "demo",
        .json = "{}",
        .files = @as(?page_cache.FileSet, null),
        .live_version = @as(?u32, 0),
        .current_version = @as(u32, 0),
    });
    try testing.expectEqual(@as(usize, 0), cache.entries.count());
}

// spec: Web Server - The progress store accepts a ladder computed off-request under the same size and read-set rules as a served one
test "warm retains an off-request ladder but still refuses an empty dependency set" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "dep.sexp", .data = "(design-block \"D\")" });
    const dep = try tmp.dir.realPathFileAlloc(std.testing.io, "dep.sexp", testing.allocator);
    defer testing.allocator.free(dep);

    var store: Store = .{ .allocator = testing.allocator };
    defer store.deinit();

    // A ladder the warm-up computed has no request to be judged query-free and
    // no response status, but it must land exactly as a served one does.
    store.warm("warmed", "{\"stages\":[]}", try page_cache.captureOne(dep), 7);
    try testing.expect(store.entries.contains("warmed"));

    // An empty read-set keys on nothing that can go stale, so it is refused
    // here for the same reason the request path refuses it.
    store.warm("unkeyed", "{\"stages\":[]}", .{ .stamps = &.{} }, 7);
    try testing.expect(!store.entries.contains("unkeyed"));
}
