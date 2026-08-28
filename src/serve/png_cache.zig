//! Dependency-aware cache for the board images served by
//! `GET /api/pcb-png/:name`, and the handler that answers from it.
//!
//! This is the endpoint an AI agent uses to *see* a board, and it was the last
//! expensive read surface with no retention at all: measured on this project's
//! boards, a plain request cost **25.1 s cold and 23.7 s hot** for `barracuda`
//! and **26.9 s / 28.3 s** for `barracuda-base` against an already-warm server —
//! every repeat paid the whole pipeline over again, byte for byte, while the
//! page tiers beside it answered the same board in 14 ms. Each call runs
//! `pcb_layout_page.solveForRequest` (design evaluation + a multi-megabyte
//! `.layouts.json` parse + the placement), the full reporting DRC over the
//! restored copper, and then the rasterizer's own pour of every poured face,
//! plane and hand-drawn zone — and the image it produces is a pure function of
//! the design's sources and its sidecars. So it is kept in process memory and
//! invalidated the ordinary way: the evaluator read-set, the layout /
//! DRC-override sidecars, and the design's live-edit version — the same
//! contract `describe_cache.zig` uses for the facts JSON of the very same
//! solve, and `pcb_page_cache.zig` for the rendered PCB page.
//!
//! `Cache-Control: no-store` stays on the response: the browser must not hold
//! an image of a board that has since been edited, and this store is what makes
//! re-fetching it cheap. The server-side retention is the point, not the
//! client's.
//!
//! Only query modes whose cache semantics have been considered may share an
//! entry, and they are folded into the key rather than ignored — the strict
//! allow-list `describe_cache` and `pcb_page_cache` use, so a future framing
//! parameter bypasses by default instead of silently serving someone else's
//! picture. `?route=1` (route fresh) and `?regen=1` (force a fresh solve) are
//! one-shot modes whose whole point is to recompute, so they bypass along with
//! `?sub=` and every unrecognised parameter.

const std = @import("std");
const httpz = @import("httpz");
const infra_fs = @import("../infra/fs.zig");
const page_cache = @import("page_cache.zig");
const progress_cache = @import("progress_cache.zig");
const modules_mod = @import("modules.zig");
const pcb_layout_page = @import("pcb_layout_page.zig");
const serve_root = @import("../serve.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const Server = serve_root.Server;

/// The file dependency set of one image render: everything the design (and, for
/// a bare `lib/modules` name, the module resolver's own) evaluator read, plus
/// the layout / DRC-override sidecars the solve parses outside it. Deliberately
/// the describe endpoint's set — an image and its facts come out of the same
/// `solveForRequest`, read the same sources, and so must go stale together.
pub fn captureRenderDeps(
    alloc: std.mem.Allocator,
    eval: *const Evaluator,
    module_res: ?modules_mod.ResolvedBlock,
    project_dir: []const u8,
    name: []const u8,
) ?page_cache.FileSet {
    if (module_res) |mr| return progress_cache.captureDeps(alloc, &.{ eval, mr.eval }, project_dir, name);
    return progress_cache.captureDeps(alloc, &.{eval}, project_dir, name);
}

/// Entry cap. A handful of designs times the framing variants below; a burst of
/// crops must not be able to grow this store without bound.
const png_max_entries: usize = 32;
/// Total byte budget of this store, and the largest single image it will admit.
/// Its own figure, measured rather than guessed: a default-width board image is
/// 69 KB (`Cyclops-Flex`) to 449 KB (`barracuda`), so 32 entries of real
/// traffic occupy well under half of this and the entry cap is what actually
/// binds. The headroom exists for the wide framing requests — `?width=4000`, a
/// `?sheet=1` contact sheet — that a review loop asks for a few of. It is an
/// order of magnitude below the rendered-page store's 128 MB because an image
/// is a secondary surface, not the navigation hot path.
const png_max_bytes: usize = 32 * 1024 * 1024;
const cache_header = "X-Netlisp-Png-Cache";

/// Query keys that change the IMAGE deterministically, each folded into the key
/// so one design can hold several. They are the framing and overlay set: which
/// saved board (`layout`), how big (`width`), how parts are labelled (`names`),
/// what is spotlit (`nets`, `refs`), which pads carry net labels (`pins`), what
/// the viewport is cropped to (`crop` + its radius `r`, or `cropnet`), whether
/// it is a contact sheet (`sheet`) or carries the callout overlay (`critique`),
/// and the heat-field twin with its cooling assumptions (`thermal`, `scenario`,
/// `ambient`).
///
/// Everything else bypasses — `route`, `regen` and `sub` for the reasons in the
/// header, and every tuning knob and diagnostic overlay because nothing has
/// established that its image is a pure function of the same read-set. A
/// parameter earns a place here by being considered, not by being harmless.
const keyed_params = [_][]const u8{
    "layout",   "width",   "names",   "nets",  "refs",     "pins",
    "crop",     "r",       "cropnet", "sheet", "critique", "thermal",
    "scenario", "ambient",
};

const Identity = struct { keyed: [keyed_params.len]?[]const u8 };

/// The query-free request an agent loop and the CLI review path actually send.
/// Variant pressure evicts a variant before displacing one of these.
fn isPlain(ident: Identity) bool {
    for (ident.keyed) |value| if (value != null) return false;
    return true;
}

/// The cache identity of `req`, or null when it must bypass. Strict
/// allow-listing: a parameter is either one of `keyed_params` — folded into the
/// key — or it disqualifies the request outright. `?sub=` bypasses because a
/// sub-scoped view reads its own `<design>.<sub>.layouts.json`, which the shared
/// read-set does not stamp; `?route=1` and `?regen=1` bypass because recomputing
/// is what they were asked for.
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
/// is built in, the entry's identity, the image bytes, their stamped
/// dependencies, and the live version they were computed against.
const Retain = struct {
    scratch: std.mem.Allocator,
    name: []const u8,
    ident: Identity,
    png: []const u8,
    files: page_cache.FileSet,
    live_version: u32,
};

const Entry = struct {
    png: []const u8,
    files: page_cache.FileSet,
    live_version: u32,
    used: u64,
    plain: bool,
};

/// One server instance's bounded board-image cache. `allocator=null`
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
        self.bytes -= entry.png.len;
        allocator.free(key);
        allocator.free(entry.png);
        entry.files.deinit();
    }

    /// Evict least-recently-used until the store is back inside both budgets,
    /// preferring variants: a `?crop=` burst must not displace the plain board
    /// image every caller asks for.
    fn trim(self: *Store, allocator: std.mem.Allocator) void {
        while (self.entries.count() > png_max_entries or self.bytes > png_max_bytes) {
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

    /// Free every retained image when its owning server stops.
    pub fn deinit(self: *Store) void {
        const allocator = self.allocator orelse return;
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            allocator.free(kv.value_ptr.png);
            kv.value_ptr.files.deinit();
        }
        self.entries.deinit(allocator);
        self.* = .{};
    }

    /// Serve a valid cache hit and return true. `in` supplies scratch, request,
    /// response, design name, and the live version read before the request ran.
    /// On a miss `miss_version` receives that version so `store` can refuse to
    /// retain an image an edit raced.
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
        const body = in.scratch.dupe(u8, entry.png) catch {
            miss_version.* = in.live_version;
            in.res.header(cache_header, "miss");
            return false;
        };
        entry.used = self.nextUse();
        in.res.header(cache_header, "hit");
        in.res.content_type = .PNG;
        in.res.header("Cache-Control", "no-store");
        in.res.body = body;
        return true;
    }

    /// Retain a freshly rendered image. `in.files` is the read-set the handler
    /// captured from the evaluator(s) that produced it; an EMPTY set is refused,
    /// because a set that stamps nothing can never go stale and would pin the
    /// first picture forever.
    pub fn store(self: *Store, in: anytype) void {
        const allocator = self.allocator orelse return;
        const live_version = in.live_version orelse return;
        const files = in.files orelse return;
        // An image is retained only when it is a complete answer that fits the
        // budget, keys on something that CAN go stale (a non-empty read-set),
        // was not raced by a live edit, and came from a cacheable query mode.
        const admissible = blk: {
            if (in.res.status != 200 or in.png.len > png_max_bytes) break :blk false;
            if (files.stamps.len == 0 or in.current_version != live_version) break :blk false;
            break :blk identity(in.req) != null;
        };
        if (!admissible) {
            files.deinit();
            return;
        }
        self.retain(allocator, .{
            .scratch = in.scratch,
            .name = in.name,
            .ident = identity(in.req).?,
            .png = in.png,
            .files = files,
            .live_version = live_version,
        });
    }

    /// Take ownership of `files` and a copy of `png` under this request's key,
    /// evicting any previous entry for it.
    fn retain(self: *Store, allocator: std.mem.Allocator, in: Retain) void {
        const files = in.files;
        const scratch_key = cacheKey(in.scratch, in.name, in.ident) catch {
            files.deinit();
            return;
        };
        const body = allocator.dupe(u8, in.png) catch {
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
            self.bytes -= gop.value_ptr.png.len;
            allocator.free(gop.value_ptr.png);
            gop.value_ptr.files.deinit();
        }
        gop.value_ptr.* = .{
            .png = body,
            .files = files,
            .live_version = in.live_version,
            .used = self.nextUse(),
            .plain = isPlain(in.ident),
        };
        self.bytes += body.len;
        self.trim(allocator);
    }
};

/// GET /api/pcb-png/:name — the body of `pcb_layout_page.pcbPngApi`. Answer an
/// allow-listed request from the retention above, else render it and retain the
/// bytes against the read-set the render captured.
///
/// Request-scoped allocation uses `req.arena` (freed after the response is
/// sent; `res.body` stays valid until then) — the retained COPY lives in the
/// store's own long-lived allocator, so the arena is still free to go.
pub fn serveImage(ctx: *Server, req: *httpz.Request, res: *httpz.Response) pcb_layout_page.HandlerError!void {
    const arena = req.arena;
    const name = pcb_layout_page.nameParam(req, res) orelse return;
    // Read the live version BEFORE rendering, so a design edit that lands
    // mid-request is treated as a miss next time instead of being baked in.
    const live_version = serve_root.getLiveVersion(name);
    var miss_version: ?u32 = null;
    if (ctx.state.caches.png_images.serve(.{
        .scratch = arena,
        .req = req,
        .res = res,
        .name = name,
        .live_version = live_version,
    }, &miss_version)) return;

    const opts = pcb_layout_page.pngRequestFromQuery(arena, req);
    var deps: ?page_cache.FileSet = null;
    const png_bytes = pcb_layout_page.renderDesignPng(arena, ctx.project_dir, name, opts, &deps) catch |e| {
        if (deps) |d| d.deinit();
        const fail = pcb_layout_page.pngFailure(e);
        res.status = fail.status;
        res.body = fail.msg;
        return;
    };
    res.content_type = .PNG;
    res.header("Cache-Control", "no-store");
    res.body = png_bytes;
    ctx.state.caches.png_images.store(.{
        .scratch = arena,
        .req = req,
        .res = res,
        .name = name,
        .png = png_bytes,
        .files = deps,
        .live_version = miss_version,
        .current_version = serve_root.getLiveVersion(name),
    });
}

// ── Tests ──────────────────────────────────────────────────────────────

// spec: Web Server - The PCB image endpoint caches only its allow-listed framing modes and bypasses fresh-route, fresh-solve and sub-scoped requests
test "png cache allow-lists its query modes and keys the ones it admits" {
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
    // allow-list is that a new framing knob is safe until its cache semantics
    // are considered.
    var unknown = httpz.testing.init(.{});
    defer unknown.deinit();
    unknown.query("blame", "1");
    try testing.expect(identity(unknown.req) == null);

    // Every admitted mode is keyed, not ignored: each frames a different
    // picture, so none of them may answer another's request.
    for (keyed_params) |param| {
        var variant = httpz.testing.init(.{});
        defer variant.deinit();
        variant.query(param, "x");
        const ident = identity(variant.req) orelse return error.TestExpectedAdmitted;
        try testing.expect(!isPlain(ident));
        const plain_key = try cacheKey(testing.allocator, "demo", plain_ident);
        defer testing.allocator.free(plain_key);
        const variant_key = try cacheKey(testing.allocator, "demo", ident);
        defer testing.allocator.free(variant_key);
        try testing.expect(!std.mem.eql(u8, plain_key, variant_key));
    }
}

// spec: Web Server - The PCB image endpoint reuses a dependency-validated image and invalidates it when the design or its sidecars change
test "png cache returns the identical bytes then invalidates after a layout-sidecar edit" {
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

    // Stand-in for a rendered image: the bytes are opaque to the store, and
    // what this test pins is that they come back BIT-FOR-BIT, embedded NULs
    // and all — an image is not a NUL-terminated string.
    const image = "\x89PNG\r\n\x1a\n\x00\x00\x00\rIHDR\x00\xff";

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
        .png = image,
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
    // Byte-for-byte parity with the fresh render, and still an image response
    // the browser is told not to keep.
    try testing.expectEqualSlices(u8, image, hit.res.body);
    try testing.expectEqual(httpz.ContentType.PNG, hit.res.content_type);

    // The plain entry is not the `?layout=` one: a named board's picture must
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

    // Saving a layout rewrites the sidecar → new poses, new copper, new DRC
    // markers, so the retained image must not be served.
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

// spec: Web Server - The PCB image cache refuses a body whose dependency set stamps nothing
test "png cache refuses an empty dependency set and an uncacheable mode" {
    const testing = std.testing;
    var cache: Store = .{ .allocator = testing.allocator };
    defer cache.deinit();

    var req = httpz.testing.init(.{});
    defer req.deinit();
    req.res.status = 200;
    // A read-set that stamps nothing could never go stale, so caching against
    // it would pin the first picture for the life of the process.
    cache.store(.{
        .scratch = req.arena,
        .req = req.req,
        .res = req.res,
        .name = "demo",
        .png = "\x89PNG",
        .files = @as(?page_cache.FileSet, null),
        .live_version = @as(?u32, 0),
        .current_version = @as(u32, 0),
    });
    try testing.expectEqual(@as(usize, 0), cache.entries.count());

    // A bypassing mode may not write an entry either — a `?route=1` image
    // shows copper this board does not have saved.
    var fresh = httpz.testing.init(.{});
    defer fresh.deinit();
    fresh.query("route", "1");
    fresh.res.status = 200;
    cache.store(.{
        .scratch = fresh.arena,
        .req = fresh.req,
        .res = fresh.res,
        .name = "demo",
        .png = "\x89PNG",
        .files = @as(?page_cache.FileSet, try page_cache.captureOne("build.zig")),
        .live_version = @as(?u32, 0),
        .current_version = @as(u32, 0),
    });
    try testing.expectEqual(@as(usize, 0), cache.entries.count());
}
