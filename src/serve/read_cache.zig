//! Dependency-validated response-body caches for the read-only design surfaces:
//! the ERC facts (`GET /api/erc`), the thermal facts and page (`GET
//! /api/thermal`, `GET /thermal`), the review PDF (`GET /api/schematic-pdf`),
//! the KiCad schematic archive (`GET /api/kicad-sch`), the spatial-facts
//! document (`GET /api/pcb-describe`), the completion ladder
//! (`GET /api/layout-progress`) and the board image (`GET /api/pcb-png`).
//!
//! Every one of those handlers begins with a FRESH `Evaluator.evalFile` of the
//! design, and on this project's largest board that evaluation alone is about
//! four seconds. Measured against an already-warm server, two identical
//! back-to-back requests for `barracuda` cost 3.7 s and 4.0 s (`/api/erc`),
//! 3.9 s and 4.4 s (`/api/thermal`), 4.2 s and 4.4 s (`/api/schematic-pdf`),
//! 4.6 s and 4.3 s (`/api/kicad-sch`) — the repeat paid the first's work over
//! again, byte for byte. The per-analysis caches that already exist underneath
//! (`serve/thermal_cache.zig` retains the solved field, and it DOES hit here)
//! cannot help: the evaluation is upstream of all of them, so it is charged
//! before any of them is consulted. Retaining the finished RESPONSE is what
//! actually skips it, exactly as `serve/pcb_page_cache.zig` does for the
//! rendered PCB page and `serve/describe_cache.zig` for the facts document.
//!
//! One generic store rather than eight near-identical modules: the bodies
//! differ only in their byte budget, their response header and which query
//! parameters they may key on, so those are the `Config` a caller instantiates
//! `Store` with. Everything else — the LRU bound, the strict query allow-list,
//! the dependency validation, the refusal to retain a body that stamps no file
//! — is one implementation, and a fix to it is a fix to all of them.
//!
//! The last three arrived late. `describe_cache.zig`, `progress_cache.zig` and
//! `png_cache.zig` were hand-written before this store existed and were then
//! copied from each other: six functions apiece, drifted in the ways
//! `twin-drift` names — two of the three kept a body whose read-set was refused,
//! leaking its `FileSet` to the page allocator, and the third had never learned
//! to spend a keyed variant before the plain answer. They are now thin
//! configurations of this type, and each of those bugs has exactly one fix.
//!
//! Validity is `serve/describe_cache.zig`'s contract, unchanged: the file
//! dependency set the handler captured from the evaluator(s) that produced the
//! body (`page_cache.FileSet`, mtime-stamped) plus the design's live-edit
//! version. Any edit to the design, its checks, any transitively imported
//! `lib/` file or any stamped sidecar flips the entry; nothing else does.
//!
//! Bodies are BYTES, not JSON: this store never sets a content type, a
//! disposition or a cache-control header. The handler owns the response
//! framing — it has to build the `Content-Disposition` filename anyway — and
//! this keeps one store able to hold a JSON document, an HTML page, a PDF and
//! a ZIP without knowing which it is holding.

const std = @import("std");
const httpz = @import("httpz");
const infra_fs = @import("../infra/fs.zig");
const cache_core = @import("cache_core.zig");
const page_cache = @import("page_cache.zig");

/// What distinguishes one surface's store from another's: the header it
/// reports its verdict through, the query parameters it may fold into a key,
/// and its two bounds. Everything here is comptime — a `Store` is instantiated
/// with one of the configurations below.
pub const Config = struct {
    /// Response header carrying `hit` / `miss` / `bypass`, so a caller (and the
    /// benchmark harness) can see which answer it got without timing it.
    header: []const u8,
    /// Query keys that change the body deterministically. Each is folded into
    /// the cache key so one design can hold several variants; every OTHER key
    /// disqualifies the request outright, so a future server-side parameter
    /// bypasses by default instead of silently aliasing onto someone else's
    /// answer.
    keyed_params: []const []const u8 = &.{},
    /// Entry cap. A handful of designs times the keyed variants below; the byte
    /// budget is the real limit on a board whose body runs large.
    max_entries: usize = 32,
    /// Total byte budget of the store, and the largest single body it admits.
    max_bytes: usize = 32 * 1024 * 1024,
};

/// `GET /api/erc/:name` — a violations document is a few kilobytes and the
/// endpoint takes no query parameters at all, so any query bypasses.
pub const erc: Config = .{
    .header = "X-Netlisp-Erc-Cache",
    .max_entries = 64,
    .max_bytes = 16 * 1024 * 1024,
};

/// `GET /api/thermal/:name` — `?ambient=` re-screens the same cached field at a
/// different temperature and `?layout=` screens a different board; both change
/// the facts deterministically, so both are keyed rather than bypassed.
pub const thermal_facts: Config = .{
    .header = "X-Netlisp-Thermal-Cache",
    .keyed_params = &.{ "ambient", "layout" },
    .max_entries = 64,
    .max_bytes = 16 * 1024 * 1024,
};

/// `GET /thermal/:name` — the page's five view parameters are keyed. `?row=`
/// is not: it answers the cells of a DIFFERENT board than the one on screen,
/// solved against a baseline this store's dependency set does not describe.
pub const thermal_page: Config = .{
    .header = "X-Netlisp-Thermal-Page-Cache",
    .keyed_params = &.{ "ambient", "scenario", "layout", "compare", "fragment" },
    .max_entries = 96,
    .max_bytes = 32 * 1024 * 1024,
};

/// `GET /api/schematic-pdf/:name` — one composed document per palette. A review
/// PDF of a large board is a few hundred kilobytes, and a reader may hold both
/// themes.
pub const schematic_pdf: Config = .{
    .header = "X-Netlisp-Pdf-Cache",
    .keyed_params = &.{"theme"},
    .max_entries = 32,
    .max_bytes = 64 * 1024 * 1024,
};

/// `GET /api/kicad-sch/:name` — one archive per `?vendor=` / `?flat=` pair. A
/// store-only ZIP of a large hierarchy is about a megabyte, so this budget
/// holds a project's worth of them.
pub const kicad_sch: Config = .{
    .header = "X-Netlisp-Kicad-Sch-Cache",
    .keyed_params = &.{ "vendor", "flat" },
    .max_entries = 32,
    .max_bytes = 64 * 1024 * 1024,
};

/// One surface's bounded response-body cache. `allocator=null` intentionally
/// disables it, which is what a handler test's bare `ServerState{}` wants:
/// every lookup misses and every retention is a no-op.
pub fn Store(comptime cfg: Config) type {
    return struct {
        const Self = @This();

        /// The keyed query values of one request, in `cfg.keyed_params` order.
        const Identity = struct { keyed: [cfg.keyed_params.len]?[]const u8 };

        /// Everything one retention needs beyond the store itself.
        const Retain = struct {
            scratch: std.mem.Allocator,
            name: []const u8,
            ident: Identity,
            body: []const u8,
            files: page_cache.FileSet,
            live_version: u32,
        };

        const Entry = struct {
            body: []const u8,
            files: page_cache.FileSet,
            live_version: u32,
            used: u64,
            plain: bool,
        };

        allocator: ?std.mem.Allocator = null,
        mutex: infra_fs.Mutex = .{},
        entries: std.StringHashMapUnmanaged(Entry) = .empty,
        bytes: usize = 0,
        use_clock: u64 = 0,

        /// The query-free request every one of these surfaces is normally sent.
        /// Variant pressure evicts a variant before displacing one of these.
        fn isPlain(ident: Identity) bool {
            for (ident.keyed) |value| if (value != null) return false;
            return true;
        }

        /// The cache identity of `req`, or null when it must bypass. Strict
        /// allow-listing: a parameter is either one of `cfg.keyed_params` —
        /// folded into the key — or it disqualifies the request outright.
        fn identity(req: *httpz.Request) ?Identity {
            const q = req.query() catch return null;
            var it = q.iterator();
            outer: while (it.next()) |field| {
                for (cfg.keyed_params) |allowed| {
                    if (std.mem.eql(u8, field.key, allowed)) continue :outer;
                }
                return null;
            }
            var ident = Identity{ .keyed = @splat(null) };
            for (cfg.keyed_params, &ident.keyed) |param, *slot| slot.* = q.get(param);
            return ident;
        }

        /// `<name>` for the plain request, `<name>\0<param>\0<value>…` once a
        /// keyed parameter participates. NUL-separated so no design or layout
        /// name can spell another entry's key.
        fn cacheKey(
            allocator: std.mem.Allocator,
            name: []const u8,
            ident: Identity,
        ) std.mem.Allocator.Error![]const u8 {
            var aw: std.Io.Writer.Allocating = .init(allocator);
            defer aw.deinit();
            const w = &aw.writer;
            w.writeAll(name) catch return error.OutOfMemory;
            for (cfg.keyed_params, ident.keyed) |param, value| {
                if (value) |v| w.print("\x00{s}\x00{s}", .{ param, v }) catch return error.OutOfMemory;
            }
            return allocator.dupe(u8, aw.written());
        }

        fn nextUse(self: *Self) u64 {
            self.use_clock +%= 1;
            return self.use_clock;
        }

        /// Release one entry and un-charge its bytes — the callback
        /// `cache_core`'s shared sweep and teardown reach back through.
        pub fn freeEntry(self: *Self, allocator: std.mem.Allocator, key: []const u8, entry: Entry) void {
            self.bytes -= entry.body.len;
            allocator.free(key);
            allocator.free(entry.body);
            entry.files.deinit();
        }

        /// Evict least-recently-used until the store is back inside both
        /// budgets, preferring variants: a `?ambient=` sweep must not displace
        /// the plain answer every caller asks for. `Entry.plain` is what asks
        /// the shared sweep for that preference.
        fn trim(self: *Self, allocator: std.mem.Allocator) void {
            cache_core.evictLru(self, allocator, cfg.max_entries, cfg.max_bytes);
        }

        /// Free every retained body when its owning server stops.
        pub fn deinit(self: *Self) void {
            cache_core.freeAll(self);
            self.* = .{};
        }

        /// Serve a valid cache hit and return true, leaving the content type and
        /// every other response header to the caller. `in` supplies scratch, the
        /// request, the response, the design name, and the live version read
        /// before the request ran. On a miss `miss_version` receives that
        /// version so `store` can refuse to retain a body an edit raced.
        pub fn serve(self: *Self, in: anytype, miss_version: *?u32) bool {
            const allocator = self.allocator orelse return false;
            miss_version.* = null;
            const ident = identity(in.req) orelse {
                in.res.header(cfg.header, "bypass");
                return false;
            };
            const key = cacheKey(in.scratch, in.name, ident) catch {
                in.res.header(cfg.header, "bypass");
                return false;
            };

            self.mutex.lock();
            defer self.mutex.unlock();
            const entry = self.entries.getPtr(key) orelse {
                miss_version.* = in.live_version;
                in.res.header(cfg.header, "miss");
                return false;
            };
            if (entry.live_version != in.live_version or !entry.files.isValid()) {
                const removed = self.entries.fetchRemove(key).?;
                self.freeEntry(allocator, removed.key, removed.value);
                miss_version.* = in.live_version;
                in.res.header(cfg.header, "miss");
                return false;
            }
            const body = in.scratch.dupe(u8, entry.body) catch {
                miss_version.* = in.live_version;
                in.res.header(cfg.header, "miss");
                return false;
            };
            entry.used = self.nextUse();
            in.res.header(cfg.header, "hit");
            in.res.body = body;
            return true;
        }

        /// Retain a freshly computed body. `in.files` is the read-set the
        /// handler captured from the evaluator(s) that produced it; an EMPTY set
        /// is refused, because a set that stamps nothing can never go stale and
        /// would pin the first answer for the life of the process.
        pub fn store(self: *Self, in: anytype) void {
            const allocator = self.allocator orelse {
                if (in.files) |f| f.deinit();
                return;
            };
            const files = in.files orelse return;
            const live_version = in.live_version orelse {
                files.deinit();
                return;
            };
            const ident = identity(in.req);
            // A body is retained only when it is a complete answer that fits the
            // budget, keys on something that CAN go stale (a non-empty
            // read-set), was not raced by a live edit, and came from a cacheable
            // query mode.
            const admissible = blk: {
                if (in.res.status != 200 or in.body.len > cfg.max_bytes) break :blk false;
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
                .body = in.body,
                .files = files,
                .live_version = live_version,
            });
        }

        /// Retain a body computed OFF-request — the startup warm-up
        /// (`serve/warmup.zig`), which has no `httpz` request to be judged
        /// against the allow-list and no response status to check. It computed
        /// the query-free body directly, so those two admission rules are
        /// satisfied by construction and its key is the design name itself (the
        /// plain identity keys nothing else); the size and read-set rules still
        /// apply, and a store with no allocator still refuses and frees.
        pub fn warm(
            self: *Self,
            name: []const u8,
            body: []const u8,
            files: page_cache.FileSet,
            live_version: u32,
        ) void {
            const allocator = self.allocator orelse {
                files.deinit();
                return;
            };
            if (body.len > cfg.max_bytes or files.stamps.len == 0) {
                files.deinit();
                return;
            }
            self.insert(allocator, .{
                .key = name,
                .body = body,
                .files = files,
                .live_version = live_version,
                .plain = true,
            });
        }

        /// Take ownership of `files` and a copy of `body` under this request's
        /// key, evicting any previous entry for it.
        fn retain(self: *Self, allocator: std.mem.Allocator, in: Retain) void {
            const scratch_key = cacheKey(in.scratch, in.name, in.ident) catch {
                in.files.deinit();
                return;
            };
            self.insert(allocator, .{
                .key = scratch_key,
                .body = in.body,
                .files = in.files,
                .live_version = in.live_version,
                .plain = isPlain(in.ident),
            });
        }

        /// One retention resolved to the map key it lands under — the seam the
        /// request path and the warm-up share, so both produce byte-identical
        /// cache state.
        const Insert = struct {
            /// Borrowed for the call; the map keeps its own copy.
            key: []const u8,
            body: []const u8,
            files: page_cache.FileSet,
            live_version: u32,
            plain: bool,
        };

        /// Take ownership of `in.files` and a copy of `in.body` under a copy of
        /// `in.key`, evicting any previous entry for it. Every failure path
        /// releases what it was handed rather than leaking it.
        fn insert(self: *Self, allocator: std.mem.Allocator, in: Insert) void {
            const files = in.files;
            const body = allocator.dupe(u8, in.body) catch {
                files.deinit();
                return;
            };
            const key = allocator.dupe(u8, in.key) catch {
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
                self.bytes -= gop.value_ptr.body.len;
                allocator.free(gop.value_ptr.body);
                gop.value_ptr.files.deinit();
            }
            gop.value_ptr.* = .{
                .body = body,
                .files = files,
                .live_version = in.live_version,
                .used = self.nextUse(),
                .plain = in.plain,
            };
            self.bytes += body.len;
            self.trim(allocator);
        }
    };
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// A two-parameter store small enough that three bodies overflow it, so one
/// fixture exercises the allow-list, the keying, the dependency validation and
/// both bounds.
const TestStore = Store(.{
    .header = "X-Netlisp-Test-Cache",
    .keyed_params = &.{ "theme", "layout" },
    .max_entries = 2,
    .max_bytes = 64,
});

/// A project holding one design and its layout sidecar — the same two-file
/// shape `page_cache`'s own tests use, because the dependency set under test is
/// literally the one `page_cache.capture` produces.
const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: [:0]u8,

    fn init() !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDir(std.testing.io, "src", .default_dir);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/demo.sexp", .data = "(design demo)" });
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
        return .{ .tmp = tmp, .root = root };
    }

    fn deinit(self: *Fixture) void {
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    /// The design source as a one-file dependency set — enough to stamp, and
    /// enough to invalidate by touching.
    fn deps(self: *const Fixture) !page_cache.FileSet {
        const path = try std.fmt.allocPrint(testing.allocator, "{s}/src/demo.sexp", .{self.root});
        defer testing.allocator.free(path);
        return page_cache.captureOne(path);
    }

    /// Push the design's mtime a second into the future, which is what any edit
    /// to it does.
    fn touchDesign(self: *Fixture) !void {
        var f = try self.tmp.dir.openFile(std.testing.io, "src/demo.sexp", .{ .mode = .read_write });
        defer f.close(std.testing.io);
        const stat = try f.stat(std.testing.io);
        try f.setTimestamps(std.testing.io, .{
            .access_timestamp = .init(stat.atime),
            .modify_timestamp = .{ .new = stat.mtime.addDuration(.{ .nanoseconds = std.time.ns_per_s }) },
        });
    }
};

/// Drive one request against `store`: look up, and on a miss retain `body`
/// under `deps`. Returns whether the lookup HIT, with the served body in
/// `ht.res.body` either way.
fn roundTrip(
    store: *TestStore,
    ht: *httpz.testing.Testing,
    fx: *const Fixture,
    body: []const u8,
) !bool {
    var miss_version: ?u32 = null;
    if (store.serve(.{
        .scratch = ht.arena,
        .req = ht.req,
        .res = ht.res,
        .name = "demo",
        .live_version = @as(u32, 0),
    }, &miss_version)) return true;
    ht.res.status = 200;
    store.store(.{
        .scratch = ht.arena,
        .req = ht.req,
        .res = ht.res,
        .name = "demo",
        .body = body,
        .files = @as(?page_cache.FileSet, try fx.deps()),
        .live_version = miss_version,
        .current_version = @as(u32, 0),
    });
    ht.res.body = body;
    return false;
}

// spec: Web Server - The read-only response caches reuse a dependency-validated body and invalidate it when the design changes
test "a read cache hits, then misses once its dependency changes" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var store: TestStore = .{ .allocator = testing.allocator };
    defer store.deinit();

    var first = httpz.testing.init(.{});
    defer first.deinit();
    try testing.expect(!try roundTrip(&store, &first, &fx, "BODY-ONE"));

    var hit = httpz.testing.init(.{});
    defer hit.deinit();
    try testing.expect(try roundTrip(&store, &hit, &fx, "BODY-TWO"));
    // The HIT is the retained body, not the one this request would have made —
    // which is what makes "cached bytes equal fresh bytes" a testable claim.
    try testing.expectEqualStrings("BODY-ONE", hit.res.body);

    // Any edit to a stamped file retires the entry on the lookup that finds it.
    try fx.touchDesign();
    var stale = httpz.testing.init(.{});
    defer stale.deinit();
    try testing.expect(!try roundTrip(&store, &stale, &fx, "BODY-TWO"));
    try testing.expectEqual(@as(usize, 1), store.entries.count());
}

// spec: Web Server - The read-only response caches key their allow-listed query parameters and bypass every other one
test "a read cache keys its allow-listed parameters and bypasses the rest" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var store: TestStore = .{ .allocator = testing.allocator };
    defer store.deinit();

    var plain = httpz.testing.init(.{});
    defer plain.deinit();
    try testing.expect(!try roundTrip(&store, &plain, &fx, "PLAIN"));

    // An allow-listed parameter is KEYED, not ignored: a themed body must never
    // be answered from the plain one, or the other way round.
    var themed = httpz.testing.init(.{});
    defer themed.deinit();
    themed.query("theme", "light");
    try testing.expect(!try roundTrip(&store, &themed, &fx, "THEMED"));
    var themed_again = httpz.testing.init(.{});
    defer themed_again.deinit();
    themed_again.query("theme", "light");
    try testing.expect(try roundTrip(&store, &themed_again, &fx, "OTHER"));
    try testing.expectEqualStrings("THEMED", themed_again.res.body);

    // An unrecognised parameter bypasses in BOTH directions — it neither reads
    // an entry nor writes one, so a new server-side query feature is safe until
    // its cache semantics have been considered.
    var unknown = httpz.testing.init(.{});
    defer unknown.deinit();
    unknown.query("row", "RF-final");
    try testing.expect(!try roundTrip(&store, &unknown, &fx, "ROW"));
    try testing.expectEqual(@as(usize, 2), store.entries.count());
    try testing.expectEqualStrings("bypass", unknown.res.headers.get("X-Netlisp-Test-Cache").?);
}

// spec: Web Server - The read-only response caches refuse a body that stamps no file, that is over budget, or that a live edit raced
test "a read cache refuses an unstamped, over-budget or raced body" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var store: TestStore = .{ .allocator = testing.allocator };
    defer store.deinit();

    var req = httpz.testing.init(.{});
    defer req.deinit();
    req.res.status = 200;
    // A read-set that stamps nothing could never go stale, so caching against
    // it would pin the first answer for the life of the process.
    store.store(.{
        .scratch = req.arena,
        .req = req.req,
        .res = req.res,
        .name = "demo",
        .body = "UNSTAMPED",
        .files = @as(?page_cache.FileSet, null),
        .live_version = @as(?u32, 0),
        .current_version = @as(u32, 0),
    });
    try testing.expectEqual(@as(usize, 0), store.entries.count());

    // A body bigger than the whole budget is refused outright, never retained
    // by evicting everything else to make room for it.
    const oversize: [128]u8 = @splat('x');
    var big = httpz.testing.init(.{});
    defer big.deinit();
    big.res.status = 200;
    store.store(.{
        .scratch = big.arena,
        .req = big.req,
        .res = big.res,
        .name = "demo",
        .body = @as([]const u8, &oversize),
        .files = @as(?page_cache.FileSet, try fx.deps()),
        .live_version = @as(?u32, 0),
        .current_version = @as(u32, 0),
    });
    try testing.expectEqual(@as(usize, 0), store.entries.count());

    // An edit that landed WHILE the body was being computed refuses the insert:
    // the answer describes the design as it was, and would otherwise stay wrong
    // until the next edit bumped the version again.
    var raced = httpz.testing.init(.{});
    defer raced.deinit();
    raced.res.status = 200;
    store.store(.{
        .scratch = raced.arena,
        .req = raced.req,
        .res = raced.res,
        .name = "demo",
        .body = "RACED",
        .files = @as(?page_cache.FileSet, try fx.deps()),
        .live_version = @as(?u32, 3),
        .current_version = @as(u32, 4),
    });
    try testing.expectEqual(@as(usize, 0), store.entries.count());
}

// spec: Web Server - The read-only response caches are bounded by entry count and by retained bytes, evicting a keyed variant before the plain answer
test "a read cache evicts a variant before the plain body it is bounded against" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var store: TestStore = .{ .allocator = testing.allocator };
    defer store.deinit();

    var plain = httpz.testing.init(.{});
    defer plain.deinit();
    try testing.expect(!try roundTrip(&store, &plain, &fx, "PLAIN"));
    var light = httpz.testing.init(.{});
    defer light.deinit();
    light.query("theme", "light");
    try testing.expect(!try roundTrip(&store, &light, &fx, "LIGHT"));
    try testing.expectEqual(@as(usize, 2), store.entries.count());

    // A third body is one too many. The victim is the least recently used
    // VARIANT, so the query-free answer every caller asks for survives a sweep
    // of themed ones.
    var dark = httpz.testing.init(.{});
    defer dark.deinit();
    dark.query("theme", "dark");
    try testing.expect(!try roundTrip(&store, &dark, &fx, "DARK"));
    try testing.expectEqual(@as(usize, 2), store.entries.count());

    var plain_again = httpz.testing.init(.{});
    defer plain_again.deinit();
    try testing.expect(try roundTrip(&store, &plain_again, &fx, "OTHER"));
    try testing.expectEqualStrings("PLAIN", plain_again.res.body);
    try testing.expect(store.bytes <= 64);
}

// spec: Web Server - A read-only response cache with no allocator retains nothing, so a handler test computes every answer fresh
test "a read cache with no allocator caches nothing" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var store: TestStore = .{};
    defer store.deinit();

    var req = httpz.testing.init(.{});
    defer req.deinit();
    try testing.expect(!try roundTrip(&store, &req, &fx, "BODY"));
    try testing.expectEqual(@as(usize, 0), store.entries.count());

    var again = httpz.testing.init(.{});
    defer again.deinit();
    try testing.expect(!try roundTrip(&store, &again, &fx, "BODY"));
}
