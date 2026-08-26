//! Dependency-aware rendered-HTML cache for stable PCB editor page loads.
//!
//! A normal `/pcb-layout/:name` reload otherwise re-evaluates the design and
//! repeatedly parses its (potentially multi-megabyte) saved-layout sidecar even
//! though the resulting HTML is identical. Stable full-page requests are kept
//! in process memory and invalidated by the evaluator read-set, PCB sidecars,
//! and the design's live-edit version. Regeneration, routing, tuning, embeds,
//! sub-circuits, and any unknown query mode deliberately bypass the cache.

const std = @import("std");
const httpz = @import("httpz");
const infra_fs = @import("../infra/fs.zig");
const paths = @import("../paths.zig");
const page_cache = @import("page_cache.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;

// Eleven plain design pages are warmed at boot. Leave room for named layouts,
// assembly/CAM, and the editor's deferred derived payload without allowing a
// short variant burst to evict those common pages immediately.
const max_entries: usize = 48;
/// Total byte budget of this in-memory page store, and the largest single
/// rendered page it will admit. A memory budget, not a file-read cap.
const max_cache_bytes: usize = 128 * 1024 * 1024;
const cache_header = "X-Netlisp-PCB-Page-Cache";

/// Query keys that change the rendered HTML deterministically (chrome trims,
/// toggle defaults) — allowed through the cache, each participating in the
/// key. `embed`/`review`/`drc` is the assembly workspace's board iframe, which
/// used to bypass and pay a full re-render on every assembly page open;
/// `thermal` adds one script tag to that same iframe for the thermal page's
/// board pane, so it keys rather than bypasses — a thermal reader dialling
/// scenarios reloads that frame repeatedly.
const keyed_params = [_][]const u8{ "embed", "review", "drc", "edit", "model_sprites", "thermal", "cam", "derived" };

const Identity = struct { layout: ?[]const u8, keyed: [keyed_params.len]?[]const u8 };

/// Position of `derived` in `keyed_params`, resolved once so `WarmKind` spells
/// the editor's deferred-payload query in exactly one place.
const derived_key_index: usize = index: {
    for (keyed_params, 0..) |param, i| {
        if (std.mem.eql(u8, param, "derived")) break :index i;
    }
    @compileError("keyed_params must carry \"derived\" for WarmKind.derived");
};

/// What a request-less render is warming. The editor asks for two responses
/// per page — the page itself, then `?derived=1` after first paint — and one
/// solve answers both (see `serve/pcb_derived_warm.zig`), so the warm path
/// reserves and admits each under its own cache identity.
pub const WarmKind = enum {
    page,
    derived,

    fn identity(self: WarmKind) Identity {
        var ident = Identity{ .layout = null, .keyed = @splat(null) };
        if (self == .derived) ident.keyed[derived_key_index] = "1";
        return ident;
    }

    fn contentType(self: WarmKind) httpz.ContentType {
        return switch (self) {
            .page => .HTML,
            .derived => .JSON,
        };
    }
};

const Entry = struct {
    html: []const u8,
    content_type: httpz.ContentType,
    files: page_cache.FileSet,
    live_version: u32,
    used: u64,
    /// Query-free/default pages are the navigation hot path and boot-warmed.
    /// Variant pressure evicts another variant before displacing one of these.
    plain: bool,
};

fn isPlain(ident: Identity) bool {
    if (ident.layout != null) return false;
    for (ident.keyed) |value| if (value != null) return false;
    return true;
}

/// Only query values that the browser consumes without changing server-rendered
/// HTML (`focus`, `gpu`), or that change it deterministically (`layout` and
/// every `keyed_params` entry, all folded into the key), may share a cached
/// page. Strict allow-listing makes future server-side query features safe by
/// default until their cache semantics are considered.
fn identity(req: *httpz.Request) ?Identity {
    const q = req.query() catch return null;
    var it = q.iterator();
    outer: while (it.next()) |field| {
        if (std.mem.eql(u8, field.key, "layout")) continue;
        if (std.mem.eql(u8, field.key, "focus")) continue;
        if (std.mem.eql(u8, field.key, "gpu")) continue;
        // `view` (the 3D-tab deep link) is consumed by the page script only —
        // the served HTML is byte-identical, so it shares the plain page's entry.
        if (std.mem.eql(u8, field.key, "view")) continue;
        // The thermal frame's opening rung and ambient are read by
        // `pcb_thermal.js` off its OWN location and fetched from
        // `/api/thermal-field`; the server-rendered board is byte-identical for
        // every one of them. Keying on these would give the frame a fresh entry
        // per scenario and per degree — which is exactly the reader who reloads
        // it most, and the one this cache exists for.
        if (std.mem.eql(u8, field.key, "scenario")) continue;
        if (std.mem.eql(u8, field.key, "ambient")) continue;
        for (keyed_params) |allowed| {
            if (std.mem.eql(u8, field.key, allowed)) continue :outer;
        }
        return null;
    }
    var ident = Identity{ .layout = q.get("layout"), .keyed = @splat(null) };
    for (keyed_params, &ident.keyed) |param, *slot| slot.* = q.get(param);
    return ident;
}

fn cacheKey(allocator: std.mem.Allocator, name: []const u8, ident: Identity) std.mem.Allocator.Error![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(allocator);
    defer aw.deinit();
    const w = &aw.writer;
    w.writeAll(name) catch return error.OutOfMemory;
    if (ident.layout) |layout| w.print("\x00layout\x00{s}", .{layout}) catch return error.OutOfMemory;
    for (keyed_params, ident.keyed) |param, value| {
        if (value) |v| w.print("\x00{s}\x00{s}", .{ param, v }) catch return error.OutOfMemory;
    }
    return allocator.dupe(u8, aw.written());
}

/// Everything retention needs that is not the body itself. Named rather than
/// `anytype` because every caller is in the server's control: the request path
/// unpacks it from its handler input, the warm-up builds it directly.
pub const Retain = struct {
    scratch: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    /// Alive for the call only — its loaded-file list is stamped, not kept.
    eval: *const Evaluator,
    /// The live version captured BEFORE the render; null disables retention.
    live_version: ?u32,
    /// The live version now: ahead of `live_version` means an edit raced the
    /// render, and the page is dropped rather than retained stale.
    current_version: ?u32,
};

/// What the cache lookup path reads off a request: the design name, the
/// request/response pair to answer into, and the live version captured before
/// rendering (so a miss records it for the store that follows).
const ServeIn = struct {
    scratch: std.mem.Allocator,
    name: []const u8,
    live_version: u32,
};

/// One server instance's bounded PCB-page cache. `allocator=null` intentionally
/// disables it for lightweight handler tests that construct `ServerState{}`.
pub const Store = struct {
    allocator: ?std.mem.Allocator = null,
    mutex: infra_fs.Mutex = .{},
    entries: std.StringHashMapUnmanaged(Entry) = .empty,
    /// Keys currently being rendered. A waiter sleeps until the leader either
    /// admits the page or finishes without one, then retries atomically.
    in_flight: std.StringHashMapUnmanaged(void) = .empty,
    changed: infra_fs.Condition = .{},
    bytes: usize = 0,
    use_clock: u64 = 0,

    fn nextUse(self: *Store) u64 {
        self.use_clock +%= 1;
        return self.use_clock;
    }

    fn freeEntry(self: *Store, allocator: std.mem.Allocator, key: []const u8, entry: Entry) void {
        self.bytes -= entry.html.len;
        allocator.free(key);
        allocator.free(entry.html);
        entry.files.deinit();
    }

    fn trim(self: *Store, allocator: std.mem.Allocator) void {
        while (self.entries.count() > max_entries or self.bytes > max_cache_bytes) {
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

    /// Free every retained page when its owning server stops.
    pub fn deinit(self: *Store) void {
        const allocator = self.allocator orelse return;
        var it = self.entries.iterator();
        while (it.next()) |kv| {
            allocator.free(kv.key_ptr.*);
            allocator.free(kv.value_ptr.html);
            kv.value_ptr.files.deinit();
        }
        self.entries.deinit(allocator);
        var flight_it = self.in_flight.iterator();
        while (flight_it.next()) |kv| allocator.free(kv.key_ptr.*);
        self.in_flight.deinit(allocator);
        self.* = .{};
    }

    /// Mark `key` as the one active render. Caller holds `mutex`.
    fn claim(self: *Store, allocator: std.mem.Allocator, key: []const u8) bool {
        const owned = allocator.dupe(u8, key) catch return false;
        self.in_flight.put(allocator, owned, {}) catch {
            allocator.free(owned);
            return false;
        };
        return true;
    }

    /// Release one render reservation and wake every waiter so one may retry
    /// or become the next leader when the completed response was uncacheable.
    fn finishIdentity(self: *Store, scratch: std.mem.Allocator, name: []const u8, ident: Identity) void {
        const allocator = self.allocator orelse return;
        const key = cacheKey(scratch, name, ident) catch return;
        defer scratch.free(key);
        self.mutex.lock();
        if (self.in_flight.fetchRemove(key)) |removed| allocator.free(removed.key);
        self.changed.broadcast();
        self.mutex.unlock();
    }

    /// Reserve one query-free entry for a request-less warm. A live request
    /// that arrives during that render joins it rather than duplicating the
    /// work. `live_version` is the design's version as the caller read it,
    /// used exactly as `serve` uses it.
    ///
    /// A retained entry only refuses the reservation while it is still VALID. A
    /// warm that runs because a design was just edited finds the pre-edit entry
    /// still sitting in the map — nothing evicts it until a reader asks — and
    /// treating that as "already warm" would hand the wait straight back to
    /// that reader. Drop the dead entry and claim instead.
    pub fn reserveWarm(self: *Store, scratch: std.mem.Allocator, name: []const u8, kind: WarmKind, live_version: u32) bool {
        const allocator = self.allocator orelse return false;
        const ident = kind.identity();
        const key = cacheKey(scratch, name, ident) catch return false;
        defer scratch.free(key);
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.entries.getPtr(key)) |entry| {
            if (entry.live_version == live_version and entry.files.isValid()) return false;
            const removed = self.entries.fetchRemove(key).?;
            self.freeEntry(allocator, removed.key, removed.value);
        }
        if (self.in_flight.contains(key)) return false;
        return self.claim(allocator, key);
    }

    /// Complete a reservation created by `reserveWarm`, on success or error.
    pub fn finishWarm(self: *Store, scratch: std.mem.Allocator, name: []const u8, kind: WarmKind) void {
        self.finishIdentity(scratch, name, kind.identity());
    }

    /// Serve a valid cache hit and return true. `req`/`res` are the live
    /// request/response to answer into; `in` carries the design name, scratch,
    /// and the live version captured before rendering.
    pub fn serve(self: *Store, in: ServeIn, req: *httpz.Request, res: *httpz.Response, miss_version: *?u32) bool {
        const allocator = self.allocator orelse return false;
        miss_version.* = null;
        const ident = identity(req) orelse {
            res.header(cache_header, "bypass");
            return false;
        };
        const key = cacheKey(in.scratch, in.name, ident) catch return false;
        defer in.scratch.free(key);

        self.mutex.lock();
        defer self.mutex.unlock();
        while (true) {
            if (self.entries.getPtr(key)) |entry| {
                if (entry.live_version != in.live_version or !entry.files.isValid()) {
                    const removed = self.entries.fetchRemove(key).?;
                    self.freeEntry(allocator, removed.key, removed.value);
                } else if (in.scratch.dupe(u8, entry.html)) |body| {
                    entry.used = self.nextUse();
                    res.header(cache_header, "hit");
                    res.content_type = entry.content_type;
                    res.body = body;
                    return true;
                } else |_| {}
            }
            if (self.in_flight.contains(key)) {
                self.changed.wait(&self.mutex);
                continue;
            }
            // An allocation failure merely disables coalescing for this miss;
            // rendering is still preferable to refusing the request.
            _ = self.claim(allocator, key);
            miss_version.* = in.live_version;
            res.header(cache_header, "miss");
            return false;
        }
    }

    /// Retain a freshly rendered cacheable page. The input also carries the
    /// current live version so an edit racing the render prevents insertion,
    /// and the duck-typed `layout_rev` freshness check asked after stamping.
    pub fn store(self: *Store, in: anytype) void {
        const release_ident = identity(in.req);
        defer {
            if (release_ident) |ident| self.finishIdentity(in.scratch, in.name, ident);
        }
        if (in.res.status != 200) return;
        const content_type = in.res.content_type orelse return;
        const retain = Retain{
            .scratch = in.scratch,
            .project_dir = in.project_dir,
            .name = in.name,
            .eval = in.eval,
            .live_version = in.live_version,
            .current_version = in.current_version,
        };
        const ident = identity(in.req) orelse return;
        const captured = self.capture(retain, in.res.body) orelse return;
        // Only NOW — after the stamps above — ask whether the layout sidecar's
        // optimistic-concurrency rev still matches the one this render embedded
        // as `PCB.rev`. A user Save that landed mid-render bumped it, so this
        // HTML is already a rev behind while the stamps record the post-save
        // file: retaining it would pin a page whose every Save answers 409
        // "layout changed in another window", and because a refused save writes
        // nothing the sidecar mtime never moves — the entry stays valid and a
        // reload serves the same doomed page forever. Asking after the capture
        // is what leaves no window: a save landing later is a write the stamps
        // predate, so it invalidates the entry the ordinary way.
        if (in.layout_rev.moved()) {
            captured.deinit();
            return;
        }
        self.admit(retain, ident, in.res.body, content_type, captured);
    }

    /// Retain a body rendered with NO request — the warm-up's pre-render of the
    /// plain `/pcb-layout/<name>` URL, or of the `?derived=1` payload the editor
    /// fetches after first paint. Identical retention rules to `store`, but the
    /// identity comes from `kind` by construction rather than being read off a
    /// request, which is precisely the entry a first visitor's bare URL (and its
    /// deferred fetch) looks up. `layout_rev` is the warm-up's store-time
    /// freshness check, duck-typed exactly as `store`'s.
    pub fn warm(self: *Store, in: Retain, kind: WarmKind, body: []const u8, layout_rev: anytype) void {
        const captured = self.capture(in, body) orelse return;
        if (layout_rev.moved()) {
            captured.deinit();
            return;
        }
        self.admit(in, kind.identity(), body, kind.contentType(), captured);
    }

    /// Stamp a rendered page's dependencies and validate it for retention.
    /// Returns null (leaving nothing to free) when the page is unretainable:
    /// the store is disabled, the live version moved, the body is over the
    /// budget, or the dependency capture failed. The caller runs its own
    /// store-time freshness check between `capture` and `admit`.
    fn capture(self: *Store, in: Retain, html: []const u8) ?Capture {
        _ = self;
        const live_version = in.live_version orelse return null;
        if (html.len > max_cache_bytes or in.current_version != live_version) return null;
        const layouts = paths.designSiblingPath(in.scratch, in.project_dir, in.name, ".layouts.json") catch return null;
        defer in.scratch.free(layouts);
        const legacy = paths.designSiblingPath(in.scratch, in.project_dir, in.name, ".autolayout.json") catch return null;
        defer in.scratch.free(legacy);
        var files = page_cache.captureWithExtras(in.scratch, in.eval, in.project_dir, in.name, &.{ layouts, legacy }) catch return null;
        // The page embeds the 3D-model map (which footprints have a STEP body,
        // with their offsets/rotations). That map derives from lib/models —
        // model-config.json and the .step listing — which the evaluator never
        // reads, so stamp them explicitly: a model upload or transform save
        // must invalidate the cached page, or the assembly Models view would
        // keep serving the old (model-less) page forever.
        page_cache.appendModelStamps(&files, in.scratch, in.project_dir) catch {
            files.deinit();
            return null;
        };
        return .{ .files = files };
    }

    /// Insert a captured page under `ident`. Owns the `Capture` on success; on
    /// failure frees it (and any partially built key/body) before returning.
    fn admit(self: *Store, in: Retain, ident: Identity, html: []const u8, content_type: httpz.ContentType, captured: Capture) void {
        const allocator = self.allocator orelse {
            captured.deinit();
            return;
        };
        const live_version = in.live_version orelse {
            captured.deinit();
            return;
        };
        const body = allocator.dupe(u8, html) catch {
            captured.deinit();
            return;
        };
        const scratch_key = cacheKey(in.scratch, in.name, ident) catch {
            captured.deinit();
            allocator.free(body);
            return;
        };
        defer in.scratch.free(scratch_key);
        const key = allocator.dupe(u8, scratch_key) catch {
            captured.deinit();
            allocator.free(body);
            return;
        };

        self.mutex.lock();
        defer self.mutex.unlock();
        const gop = self.entries.getOrPut(allocator, key) catch {
            captured.deinit();
            allocator.free(body);
            allocator.free(key);
            return;
        };
        if (gop.found_existing) {
            allocator.free(key);
            self.bytes -= gop.value_ptr.html.len;
            allocator.free(gop.value_ptr.html);
            gop.value_ptr.files.deinit();
        }
        gop.value_ptr.* = .{ .html = body, .content_type = content_type, .files = captured.files, .live_version = live_version, .used = self.nextUse(), .plain = isPlain(ident) };
        self.bytes += body.len;
        self.trim(allocator);
    }
};

/// The stamped dependencies of one retained page (`capture`), moved into the
/// cache's entry by `admit`.
const Capture = struct {
    files: page_cache.FileSet,

    fn deinit(self: Capture) void {
        self.files.deinit();
    }
};

test "PCB page cache allows only HTML-stable query modes" {
    var plain = httpz.testing.init(.{});
    defer plain.deinit();
    try std.testing.expect(identity(plain.req) != null);

    var selected = httpz.testing.init(.{});
    defer selected.deinit();
    selected.query("layout", "RF-final");
    selected.query("gpu", "1");
    try std.testing.expectEqualStrings("RF-final", identity(selected.req).?.layout.?);

    // The assembly workspace's read-only board iframe is cacheable, keyed on
    // its chrome-mode params, so opening the assembly page twice renders once.
    var embed = httpz.testing.init(.{});
    defer embed.deinit();
    embed.query("embed", "1");
    embed.query("review", "1");
    embed.query("drc", "0");
    try std.testing.expect(identity(embed.req) != null);

    // Exact Assembly CAM is fetched after first paint and shares this store as
    // JSON under its own key, never colliding with the iframe HTML.
    var cam = httpz.testing.init(.{});
    defer cam.deinit();
    cam.query("cam", "1");
    try std.testing.expect(identity(cam.req) != null);

    // The editor's after-paint JSON has its own deterministic cache key and
    // cannot collide with the lightweight HTML first response.
    var derived = httpz.testing.init(.{});
    defer derived.deinit();
    derived.query("derived", "1");
    try std.testing.expect(identity(derived.req) != null);

    // The thermal page's board frame is the same embed plus one script tag, and
    // the rung / ambient it opens on are read by that script rather than
    // rendered — so a reader stepping through four scenarios at a dozen
    // ambients shares ONE entry instead of missing every time.
    var heat = httpz.testing.init(.{});
    defer heat.deinit();
    heat.query("embed", "1");
    heat.query("review", "1");
    heat.query("drc", "0");
    heat.query("thermal", "1");
    heat.query("scenario", "airflow_2ms");
    heat.query("ambient", "70");
    try std.testing.expect(identity(heat.req) != null);

    var route = httpz.testing.init(.{});
    defer route.deinit();
    route.query("route", "1");
    try std.testing.expect(identity(route.req) == null);

    var sub = httpz.testing.init(.{});
    defer sub.deinit();
    sub.query("embed", "1");
    sub.query("sub", "amp1");
    try std.testing.expect(identity(sub.req) == null);

    var future = httpz.testing.init(.{});
    defer future.deinit();
    future.query("unknown-render-mode", "1");
    try std.testing.expect(identity(future.req) == null);
}

test "PCB page cache keys separate the default, named-layout, and embed pages" {
    const testing = std.testing;
    const none: [keyed_params.len]?[]const u8 = @splat(null);
    const dflt = try cacheKey(testing.allocator, "black-canyon", .{ .layout = null, .keyed = none });
    defer testing.allocator.free(dflt);
    const rf = try cacheKey(testing.allocator, "black-canyon", .{ .layout = "RF", .keyed = none });
    defer testing.allocator.free(rf);
    try testing.expect(!std.mem.eql(u8, dflt, rf));

    var embedded = none;
    embedded[0] = "1"; // embed=1
    const embed_key = try cacheKey(testing.allocator, "black-canyon", .{ .layout = null, .keyed = embedded });
    defer testing.allocator.free(embed_key);
    try testing.expect(!std.mem.eql(u8, dflt, embed_key));

    // The thermal frame carries an extra script tag, so it is a DIFFERENT page
    // from the assembly page's frame and must not be served that entry.
    var heated = embedded;
    heated[5] = "1"; // thermal=1
    const heat_key = try cacheKey(testing.allocator, "black-canyon", .{ .layout = null, .keyed = heated });
    defer testing.allocator.free(heat_key);
    try testing.expect(!std.mem.eql(u8, embed_key, heat_key));

    var cam = none;
    cam[6] = "1"; // cam=1
    const cam_key = try cacheKey(testing.allocator, "black-canyon", .{ .layout = null, .keyed = cam });
    defer testing.allocator.free(cam_key);
    try testing.expect(!std.mem.eql(u8, dflt, cam_key));

    var derived = none;
    derived[7] = "1"; // derived=1
    const derived_key = try cacheKey(testing.allocator, "black-canyon", .{ .layout = null, .keyed = derived });
    defer testing.allocator.free(derived_key);
    try testing.expect(!std.mem.eql(u8, dflt, derived_key));
}

test "PCB page cache coalesces duplicate warm-up reservations" {
    var cache: Store = .{ .allocator = std.testing.allocator };
    defer cache.deinit();
    try std.testing.expect(cache.reserveWarm(std.testing.allocator, "demo", .page, 1));
    try std.testing.expect(!cache.reserveWarm(std.testing.allocator, "demo", .page, 1));
    cache.finishWarm(std.testing.allocator, "demo", .page);
    try std.testing.expect(cache.reserveWarm(std.testing.allocator, "demo", .page, 1));
    cache.finishWarm(std.testing.allocator, "demo", .page);
}

// spec: Web Server - One warm-up render answers both the PCB page and its deferred payload, each reserved and retained under its own cache identity
test "PCB page and deferred-payload warms reserve independently" {
    var cache: Store = .{ .allocator = std.testing.allocator };
    defer cache.deinit();
    // The page reservation must not block the deferred one: a single render
    // holds both at once and publishes the page before the analyses finish.
    try std.testing.expect(cache.reserveWarm(std.testing.allocator, "demo", .page, 1));
    try std.testing.expect(cache.reserveWarm(std.testing.allocator, "demo", .derived, 1));
    try std.testing.expect(!cache.reserveWarm(std.testing.allocator, "demo", .derived, 1));
    cache.finishWarm(std.testing.allocator, "demo", .page);
    cache.finishWarm(std.testing.allocator, "demo", .derived);
    try std.testing.expect(cache.reserveWarm(std.testing.allocator, "demo", .derived, 1));
    cache.finishWarm(std.testing.allocator, "demo", .derived);
}

// spec: Web Server - A deferred-payload warm reserves the SAME cache entry the editor's `?derived=1` fetch looks up, so the browser joins that render instead of starting a second one
test "deferred warm identity is the browser's derived request identity" {
    var derived_req = httpz.testing.init(.{});
    defer derived_req.deinit();
    derived_req.query("derived", "1");
    const from_request = identity(derived_req.req).?;
    const from_warm = WarmKind.derived.identity();
    const request_key = try cacheKey(std.testing.allocator, "demo", from_request);
    defer std.testing.allocator.free(request_key);
    const warm_key = try cacheKey(std.testing.allocator, "demo", from_warm);
    defer std.testing.allocator.free(warm_key);
    try std.testing.expectEqualStrings(request_key, warm_key);
    try std.testing.expectEqual(httpz.ContentType.JSON, WarmKind.derived.contentType());
    try std.testing.expectEqual(httpz.ContentType.HTML, WarmKind.page.contentType());
}

// spec: Web Server - A warm-up reservation drops a retained PCB entry an edit has already invalidated, so the warm that edit triggered actually runs instead of deferring to the dead entry
test "warm reservation claims an invalidated entry instead of skipping it" {
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
    first.query("derived", "1");
    var version: ?u32 = null;
    try testing.expect(!cache.serve(.{ .scratch = first.arena, .name = "demo", .live_version = 0 }, first.req, first.res, &version));
    first.res.status = 200;
    first.res.content_type = .JSON;
    first.res.body = "{\"rev\":0}";
    cache.store(.{ .scratch = first.arena, .project_dir = root, .name = "demo", .req = first.req, .eval = &eval, .res = first.res, .live_version = version, .current_version = @as(u32, 0), .layout_rev = StubRev{} });

    // Still valid: nothing to warm, so the reservation is refused.
    try testing.expect(!cache.reserveWarm(testing.allocator, "demo", .derived, 0));

    // An edit bumps the design's live version. Nothing evicts the retained
    // entry until a reader asks for it — and that reader is exactly who the
    // warm exists to spare, so the reservation must take it over.
    try testing.expect(cache.reserveWarm(testing.allocator, "demo", .derived, 1));
    cache.finishWarm(testing.allocator, "demo", .derived);
}

test "PCB page cache preserves JSON content type for deferred CAM" {
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
    first.query("cam", "1");
    var version: ?u32 = null;
    try testing.expect(!cache.serve(.{ .scratch = first.arena, .name = "demo", .live_version = 0 }, first.req, first.res, &version));
    first.res.status = 200;
    first.res.content_type = .JSON;
    first.res.body = "{\"source\":\"generated-gerber\"}";
    cache.store(.{ .scratch = first.arena, .project_dir = root, .name = "demo", .req = first.req, .eval = &eval, .res = first.res, .live_version = version, .current_version = @as(u32, 0), .layout_rev = StubRev{} });

    var hit = httpz.testing.init(.{});
    defer hit.deinit();
    hit.query("cam", "1");
    try testing.expect(cache.serve(.{ .scratch = hit.arena, .name = "demo", .live_version = 0 }, hit.req, hit.res, &version));
    try testing.expectEqual(httpz.ContentType.JSON, hit.res.content_type.?);
    try testing.expectEqualStrings(first.res.body, hit.res.body);
}

test "PCB page cache invalidates after a 3D-model upload" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "src", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/demo.sexp", .data = "(design demo)" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/demo.layouts.json", .data = "{}" });
    try tmp.dir.createDirPath(std.testing.io, "lib/models");
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    var cache: Store = .{ .allocator = testing.allocator };
    defer cache.deinit();
    var eval = Evaluator.init(testing.allocator, root);
    defer eval.deinit();
    var first = httpz.testing.init(.{});
    defer first.deinit();
    var version: ?u32 = null;
    try testing.expect(!cache.serve(.{ .scratch = first.arena, .name = "demo", .live_version = @as(u32, 0) }, first.req, first.res, &version));
    first.res.status = 200;
    first.res.content_type = .HTML;
    first.res.body = "cached-pcb";
    cache.store(.{ .scratch = first.arena, .project_dir = root, .name = "demo", .req = first.req, .eval = &eval, .res = first.res, .live_version = version, .current_version = @as(u32, 0), .layout_rev = StubRev{} });

    var hit = httpz.testing.init(.{});
    defer hit.deinit();
    try testing.expect(cache.serve(.{ .scratch = hit.arena, .name = "demo", .live_version = @as(u32, 0) }, hit.req, hit.res, &version));
    try testing.expectEqualStrings("cached-pcb", hit.res.body);

    // A model upload adds `lib/models/<fp>.step` — the embedded models map
    // derives from that listing, so the cached page must go stale even though
    // no design or sidecar file moved.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/models/qfn50p290x290x90-13n-d.step", .data = "ISO-10303-21;" });
    var stale = httpz.testing.init(.{});
    defer stale.deinit();
    try testing.expect(!cache.serve(.{ .scratch = stale.arena, .name = "demo", .live_version = @as(u32, 0) }, stale.req, stale.res, &version));
}

test "PCB page cache invalidates when a model config transform changes" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "src", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/demo.sexp", .data = "(design demo)" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/demo.layouts.json", .data = "{}" });
    try tmp.dir.createDirPath(std.testing.io, "lib/models");
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    var cache: Store = .{ .allocator = testing.allocator };
    defer cache.deinit();
    var eval = Evaluator.init(testing.allocator, root);
    defer eval.deinit();
    var first = httpz.testing.init(.{});
    defer first.deinit();
    var version: ?u32 = null;
    try testing.expect(!cache.serve(.{ .scratch = first.arena, .name = "demo", .live_version = @as(u32, 0) }, first.req, first.res, &version));
    first.res.status = 200;
    first.res.content_type = .HTML;
    first.res.body = "cached-pcb";
    cache.store(.{ .scratch = first.arena, .project_dir = root, .name = "demo", .req = first.req, .eval = &eval, .res = first.res, .live_version = version, .current_version = @as(u32, 0), .layout_rev = StubRev{} });

    var hit = httpz.testing.init(.{});
    defer hit.deinit();
    try testing.expect(cache.serve(.{ .scratch = hit.arena, .name = "demo", .live_version = @as(u32, 0) }, hit.req, hit.res, &version));
    try testing.expectEqualStrings("cached-pcb", hit.res.body);

    // A model-transform save (POST /api/model-transform/:fp) rewrites
    // lib/models/model-config.json; the page's models map embeds those
    // offsets/rotations, so the cached page must go stale.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/models/model-config.json", .data = "{\"qfn50p290x290x90-13n-d\":{\"offset\":[0,0,0],\"rotation\":[90,0,0]}}\n" });
    var stale = httpz.testing.init(.{});
    defer stale.deinit();
    try testing.expect(!cache.serve(.{ .scratch = stale.arena, .name = "demo", .live_version = @as(u32, 0) }, stale.req, stale.res, &version));
}

test "PCB page cache hits then invalidates after a layout-sidecar edit" {
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
    try testing.expect(!cache.serve(.{ .scratch = first.arena, .name = "demo", .live_version = @as(u32, 0) }, first.req, first.res, &version));
    first.res.status = 200;
    first.res.content_type = .HTML;
    first.res.body = "cached-pcb";
    cache.store(.{ .scratch = first.arena, .project_dir = root, .name = "demo", .req = first.req, .eval = &eval, .res = first.res, .live_version = version, .current_version = @as(u32, 0), .layout_rev = StubRev{} });

    var hit = httpz.testing.init(.{});
    defer hit.deinit();
    try testing.expect(cache.serve(.{ .scratch = hit.arena, .name = "demo", .live_version = @as(u32, 0) }, hit.req, hit.res, &version));
    try testing.expectEqualStrings("cached-pcb", hit.res.body);

    var sidecar = try tmp.dir.openFile(std.testing.io, "src/demo.layouts.json", .{ .mode = .read_write });
    defer sidecar.close(std.testing.io);
    const stat = try sidecar.stat(std.testing.io);
    try sidecar.setTimestamps(std.testing.io, .{
        .access_timestamp = .init(stat.atime),
        .modify_timestamp = .{ .new = stat.mtime.addDuration(.{ .nanoseconds = std.time.ns_per_s }) },
    });
    var stale = httpz.testing.init(.{});
    defer stale.deinit();
    try testing.expect(!cache.serve(.{ .scratch = stale.arena, .name = "demo", .live_version = @as(u32, 0) }, stale.req, stale.res, &version));
}

/// `pcb_layout_page.StoreRevCheck`'s shape for the tests: `moved` is whatever
/// the case under test wants the layout sidecar to have done mid-render.
const StubRev = struct {
    is_moved: bool = false,

    /// Whether the case under test wants the sidecar to have moved mid-render.
    pub fn moved(self: StubRev) bool {
        return self.is_moved;
    }
};

// spec: Web Server - A page render whose layout sidecar was saved mid-render is not cached
test "PCB page cache refuses a render the layout sidecar outran" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "src", .default_dir);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/demo.sexp", .data = "(design demo)" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/demo.layouts.json", .data = "{\"rev\":7}" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    var cache: Store = .{ .allocator = testing.allocator };
    defer cache.deinit();
    var eval = Evaluator.init(testing.allocator, root);
    defer eval.deinit();

    // A Save landed while this page rendered: the HTML carries the pre-save
    // rev, so it must not be retained — otherwise every Save from the served
    // page 409s, and a refused save never moves the mtime that would evict it.
    var raced = httpz.testing.init(.{});
    defer raced.deinit();
    var version: ?u32 = null;
    try testing.expect(!cache.serve(.{ .scratch = raced.arena, .name = "demo", .live_version = @as(u32, 0) }, raced.req, raced.res, &version));
    raced.res.status = 200;
    raced.res.content_type = .HTML;
    raced.res.body = "stale-pcb";
    cache.store(.{ .scratch = raced.arena, .project_dir = root, .name = "demo", .req = raced.req, .eval = &eval, .res = raced.res, .live_version = version, .current_version = @as(u32, 0), .layout_rev = StubRev{ .is_moved = true } });

    var after = httpz.testing.init(.{});
    defer after.deinit();
    try testing.expect(!cache.serve(.{ .scratch = after.arena, .name = "demo", .live_version = @as(u32, 0) }, after.req, after.res, &version));

    // The same render with an unmoved rev is the ordinary cacheable page.
    after.res.status = 200;
    after.res.content_type = .HTML;
    after.res.body = "fresh-pcb";
    cache.store(.{ .scratch = after.arena, .project_dir = root, .name = "demo", .req = after.req, .eval = &eval, .res = after.res, .live_version = version, .current_version = @as(u32, 0), .layout_rev = StubRev{} });

    var hit = httpz.testing.init(.{});
    defer hit.deinit();
    try testing.expect(cache.serve(.{ .scratch = hit.arena, .name = "demo", .live_version = @as(u32, 0) }, hit.req, hit.res, &version));
    try testing.expectEqualStrings("fresh-pcb", hit.res.body);
}
