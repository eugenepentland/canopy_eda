//! Dependency-validated cache of solved thermal fields, one entry per board —
//! a design's default placement, or one of its named saved layouts.
//!
//! A cooling-scenario ladder costs two expensive things: resolving the board's
//! placement (which re-parses a potentially multi-megabyte `.layouts.json`
//! sidecar) and then relaxing four steady-state spreader fields over it. On a
//! real board that is seconds — and it was paid again on every thermal page
//! load, every heat-zone PNG, every review render and every ambient nudge, all
//! for a board that had not changed a byte between them.
//!
//! What is cached is the solver's own output: `[]ScenarioResult`, whose fields
//! are temperature RISES above ambient, never absolute temperatures. That is
//! what makes one cached solve serve every ambient — `thermal_scenarios.ladderAt`
//! is the only place an ambient is ever added, so re-screening at 70 °C is now
//! arithmetic over a cached field instead of four fresh relaxations.
//!
//! Validity follows `serve/pcb_page_cache.zig` exactly, because the inputs are
//! the same ones: the evaluator's read-set (design, checks, every transitively
//! imported `lib/` file) plus the `.layouts.json` / `.autolayout.json` sidecars
//! the placement is resolved from, all stamped by mtime through
//! `page_cache.FileSet`, and the design's live-edit version on top. Any edit to
//! the design, any saved or starred layout, any autoroute that rewrites the
//! sidecar flips the entry; nothing else does.
//!
//! Entries are keyed by the SAVED LAYOUT as well, because two layouts of one
//! design are two different boards: the parts sit in different places and the
//! vias stitching them into the plane are different copper. Keying on the
//! design alone is how a layout-comparison sweep would report one board's
//! temperatures under every layout's name.
//!
//! The running server publishes its store through `publish`/`active` rather
//! than reaching it off a `Server` context, because one of the surfaces that
//! wants it — the `describe_thermal` CLI tool — is dispatched with nothing but
//! an allocator and a project directory. Entries are keyed by project dir AND
//! design name so two projects in one process can never read each other's
//! board, and `Store` stays an ordinary value a test can own outright.
//!
//! Entries are pinned to the process page allocator because the HTTP server
//! frees its per-request arena after every response. A hit is therefore always
//! COPIED back into the caller's arena under the store's lock: an entry may be
//! evicted by another thread the moment the lock is released, and a borrowed
//! field would then be a use-after-free. The copy is a few tens of kilobytes
//! against a multi-second solve.

const std = @import("std");
const infra_fs = @import("../infra/fs.zig");
const cache_core = @import("cache_core.zig");
const page_cache = @import("page_cache.zig");
const paths = @import("../paths.zig");
const thermal_scenarios = @import("../thermal_scenarios.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;

/// Boards retained at once — one design's layout counts as its own board, so a
/// reader comparing the cooling of eight saved layouts fills eight slots. Sized
/// for a comparison sweep rather than a single page: `max_field_bytes` is the
/// real guard, and an ordinary board's field is a few kilobytes.
const max_entries: usize = 32;
/// Total byte budget of the retained fields. A grid is capped at 512 cells per
/// axis, so a pathological board costs ~1 MB per scenario and 4 MB for a ladder;
/// an ordinary 100 mm board's grid is ~64×40 and costs a few kilobytes.
const max_field_bytes: usize = 32 * 1024 * 1024;

/// What a cached solve is FOR: which project, which design, which SAVED LAYOUT
/// of it, and which live-edit generation of that design. Carried as one value
/// so a caller cannot pair one design's name with another's version — or, since
/// the thermal page compares boards, one layout's field with another's poses.
pub const Key = struct {
    project_dir: []const u8,
    name: []const u8,
    live_version: u32,
    /// Saved layout the field was solved over, empty for the design's DEFAULT
    /// board (the starred layout, else the auto cache, else a plain grid). Two
    /// saved layouts of one design place the same parts in different spots and
    /// stitch different vias under them, so they are different boards and get
    /// different entries.
    layout: []const u8 = "",
};

/// Map key: project directory, design name and layout, NUL-joined so no
/// `<dir>/<a>` vs `<dir>/<b>` pair can ever collide by concatenation. The live
/// version is deliberately NOT part of it — an edited design REPLACES its entry
/// rather than accumulating one per keystroke.
fn keyOf(alloc: std.mem.Allocator, k: Key) std.mem.Allocator.Error![]u8 {
    return std.fmt.allocPrint(alloc, "{s}\x00{s}\x00{s}", .{ k.project_dir, k.name, k.layout });
}

/// One design's solved ladder plus everything needed to know it is still true.
const Entry = struct {
    results: []thermal_scenarios.ScenarioResult,
    files: page_cache.FileSet,
    live_version: u32,
    bytes: usize,
    used: u64,
};

/// Bytes `results` occupies when duped — the field arrays, the per-part rows,
/// and every string they name. Used only for the store's budget.
fn sizeOf(results: []const thermal_scenarios.ScenarioResult) usize {
    var total: usize = 0;
    for (results) |r| {
        total += @sizeOf(thermal_scenarios.ScenarioResult);
        total += r.grid.rise_c.len * @sizeOf(f32);
        total += r.parts.len * @sizeOf(thermal_scenarios.PartField);
        for (r.parts) |p| total += p.ref_des.len;
        total += r.skipped.len * @sizeOf([]const u8);
        for (r.skipped) |s| total += s.len;
        total += r.max_ambient.ref_des.len;
        total += r.heatsink_ref.len;
    }
    return total;
}

/// Deep-copy one solved ladder into `alloc`. Every slice AND every string is
/// duplicated, because the source strings belong to the request arena that
/// solved them (they came out of `eval/thermal.zig`'s screened rows) and a
/// retained entry must not point into it.
fn dupeResults(
    alloc: std.mem.Allocator,
    results: []const thermal_scenarios.ScenarioResult,
) std.mem.Allocator.Error![]thermal_scenarios.ScenarioResult {
    const out = try alloc.alloc(thermal_scenarios.ScenarioResult, results.len);
    var done: usize = 0;
    errdefer {
        for (out[0..done]) |r| freeResult(alloc, r);
        alloc.free(out);
    }
    for (results, out) |src, *dst| {
        dst.* = src;
        dst.grid.rise_c = try alloc.dupe(f32, src.grid.rise_c);
        const parts = try alloc.alloc(thermal_scenarios.PartField, src.parts.len);
        for (src.parts, parts) |sp, *dp| {
            dp.* = sp;
            dp.ref_des = try alloc.dupe(u8, sp.ref_des);
        }
        dst.parts = parts;
        const skipped = try alloc.alloc([]const u8, src.skipped.len);
        for (src.skipped, skipped) |ss, *ds| ds.* = try alloc.dupe(u8, ss);
        dst.skipped = skipped;
        dst.max_ambient.ref_des = try alloc.dupe(u8, src.max_ambient.ref_des);
        dst.heatsink_ref = try alloc.dupe(u8, src.heatsink_ref);
        done += 1;
    }
    return out;
}

fn freeResult(alloc: std.mem.Allocator, r: thermal_scenarios.ScenarioResult) void {
    alloc.free(r.grid.rise_c);
    for (r.parts) |p| alloc.free(p.ref_des);
    alloc.free(r.parts);
    for (r.skipped) |s| alloc.free(s);
    alloc.free(r.skipped);
    alloc.free(r.max_ambient.ref_des);
    alloc.free(r.heatsink_ref);
}

fn freeResults(alloc: std.mem.Allocator, results: []thermal_scenarios.ScenarioResult) void {
    for (results) |r| freeResult(alloc, r);
    alloc.free(results);
}

/// One server instance's bounded solved-field store. `allocator=null` leaves it
/// disabled, which is what a `ServerState{}` in a handler test and the CLI both
/// want: every lookup misses and every store is a no-op.
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

    /// Release one entry and un-charge its bytes. `pub` because it is the
    /// contract `cache_core`'s shared eviction sweep and teardown call back
    /// into; nothing outside this module has any reason to.
    pub fn freeEntry(self: *Store, alloc: std.mem.Allocator, key: []const u8, entry: Entry) void {
        self.bytes -= entry.bytes;
        alloc.free(key);
        freeResults(alloc, entry.results);
        entry.files.deinit();
    }

    /// Evict least-recently-used until the store is back inside both budgets.
    /// `Entry` carries no `plain` flag — every board here is somebody's board —
    /// so the shared sweep runs in plain recency order.
    fn trim(self: *Store, alloc: std.mem.Allocator) void {
        cache_core.evictLru(self, alloc, max_entries, max_field_bytes);
    }

    /// Free every retained field when its owning server stops.
    pub fn deinit(self: *Store) void {
        cache_core.freeAll(self);
        self.* = .{};
    }

    /// A valid cached solve for `name`, copied into `scratch` — or null when
    /// the store is disabled, has never seen the design, or the design has
    /// changed under it. A stale entry is dropped here rather than left to rot.
    pub fn get(
        self: *Store,
        scratch: std.mem.Allocator,
        k: Key,
    ) ?[]thermal_scenarios.ScenarioResult {
        const alloc = self.allocator orelse return null;
        const key = keyOf(scratch, k) catch return null;
        defer scratch.free(key);
        self.mutex.lock();
        defer self.mutex.unlock();
        const entry = self.entries.getPtr(key) orelse return null;
        if (entry.live_version != k.live_version or !entry.files.isValid()) {
            const removed = self.entries.fetchRemove(key).?;
            self.freeEntry(alloc, removed.key, removed.value);
            return null;
        }
        // Copied under the lock: the entry can be evicted the instant it drops.
        const copy = dupeResults(scratch, entry.results) catch return null;
        entry.used = self.nextUse();
        return copy;
    }

    /// Retain a freshly solved ladder for `name`. `eval` is the evaluator that
    /// resolved the placement — its read-set is the dependency set. A live
    /// version that moved while the solve ran refuses the insert, so an edit
    /// racing a multi-second solve can never be cached over.
    pub fn put(
        self: *Store,
        scratch: std.mem.Allocator,
        eval: *const Evaluator,
        k: Key,
        results: []const thermal_scenarios.ScenarioResult,
    ) void {
        const alloc = self.allocator orelse return;
        const size = sizeOf(results);
        if (size > max_field_bytes) return;

        // The two placement sidecars the evaluator never parses but
        // `solveForRequest` reads — the same pair `pcb_page_cache` stamps.
        const layouts = paths.designSiblingPath(scratch, k.project_dir, k.name, ".layouts.json") catch return;
        defer scratch.free(layouts);
        const legacy = paths.designSiblingPath(scratch, k.project_dir, k.name, ".autolayout.json") catch return;
        defer scratch.free(legacy);
        const files = page_cache.captureWithExtras(
            scratch,
            eval,
            k.project_dir,
            k.name,
            &.{ layouts, legacy },
        ) catch return;

        const owned = dupeResults(alloc, results) catch {
            files.deinit();
            return;
        };
        const key = keyOf(alloc, k) catch {
            files.deinit();
            freeResults(alloc, owned);
            return;
        };

        self.mutex.lock();
        defer self.mutex.unlock();
        const gop = self.entries.getOrPut(alloc, key) catch {
            files.deinit();
            freeResults(alloc, owned);
            alloc.free(key);
            return;
        };
        if (gop.found_existing) {
            alloc.free(key);
            self.bytes -= gop.value_ptr.bytes;
            freeResults(alloc, gop.value_ptr.results);
            gop.value_ptr.files.deinit();
        }
        gop.value_ptr.* = .{
            .results = owned,
            .files = files,
            .live_version = k.live_version,
            .bytes = size,
            .used = self.nextUse(),
        };
        self.bytes += size;
        self.trim(alloc);
    }
};

// ── The running server's store ────────────────────────────────────────────
//
// A `Server` context reaches its own `state.caches.thermal_solves` directly, but the
// `describe_thermal` CLI tool is dispatched through `mcp_tools.zig` with only
// an allocator and a project dir — no context to hang a store off. Publishing
// the live server's store here lets every surface share one cache without
// threading a pointer through the whole tool-dispatch chain. Unpublished (every
// unit test, every CLI run) `active()` is null and every lookup simply misses.

var shared_mutex: infra_fs.Mutex = .{};
var shared_store: ?*Store = null;

/// Publish (or, with null, retract) the store every cache-aware surface reads.
/// `serve()` publishes its `ServerState`'s store on startup and retracts it
/// BEFORE tearing it down, so no handler can reach a freed store.
pub fn publish(store: ?*Store) void {
    shared_mutex.lock();
    defer shared_mutex.unlock();
    shared_store = store;
}

/// The published store, or null when nothing is serving.
pub fn active() ?*Store {
    shared_mutex.lock();
    defer shared_mutex.unlock();
    return shared_store;
}

// ── Tests ─────────────────────────────────────────────────────────────────
//
// The fixture is a two-file project (a design and its layout sidecar) the same
// shape `pcb_page_cache`'s tests use, because the dependency set under test is
// literally the same one. The retained ladders are hand-built rather than
// solved: what is under test here is retention and invalidation, not physics.

const testing = std.testing;

/// A one-scenario ladder whose peak rise is `rise`, owned by `alloc`.
fn fakeResults(alloc: std.mem.Allocator, rise: f32, cells: usize) ![]thermal_scenarios.ScenarioResult {
    const out = try alloc.alloc(thermal_scenarios.ScenarioResult, 1);
    const grid = try alloc.alloc(f32, cells);
    @memset(grid, rise);
    const parts = try alloc.alloc(thermal_scenarios.PartField, 1);
    parts[0] = .{ .ref_des = try alloc.dupe(u8, "U1"), .board_rise_c = rise, .tj_rise_c = rise + 5 };
    out[0] = .{
        .scenario = .natural,
        .grid = .{ .cols = cells, .rows = 1, .cell_mm = 1, .origin_x_mm = 0, .origin_y_mm = 0, .rise_c = grid },
        .parts = parts,
        .hotspot = .{ .rise_c = rise },
        .max_ambient = .{ .c = 125 - rise, .ref_des = try alloc.dupe(u8, "U1") },
    };
    return out;
}

/// Read a key back and drop the copy, reporting only whether it hit — the shape
/// a test wants when it is exercising recency rather than the payload.
fn readsBack(store: *Store, key: Key) bool {
    const hit = store.get(testing.allocator, key) orelse return false;
    freeResults(testing.allocator, hit);
    return true;
}

const Fixture = struct {
    tmp: std.testing.TmpDir,
    /// Sentinel-terminated because that is what `realPathFileAlloc` allocates;
    /// storing it as a plain `[]u8` would free one byte short of the allocation.
    root: [:0]u8,
    eval: Evaluator,

    fn init() !Fixture {
        var tmp = testing.tmpDir(.{});
        errdefer tmp.cleanup();
        try tmp.dir.createDir(std.testing.io, "src", .default_dir);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/demo.sexp", .data = "(design demo)" });
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/demo.layouts.json", .data = "{}" });
        const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
        errdefer testing.allocator.free(root);
        return .{ .tmp = tmp, .root = root, .eval = Evaluator.init(testing.allocator, root) };
    }

    fn deinit(self: *Fixture) void {
        self.eval.deinit();
        testing.allocator.free(self.root);
        self.tmp.cleanup();
    }

    fn key(self: *const Fixture, version: u32) Key {
        return .{ .project_dir = self.root, .name = "demo", .live_version = version };
    }

    /// Push the layout sidecar's mtime a second into the future, which is what
    /// a saved layout or a finished autoroute does to it.
    fn touchSidecar(self: *Fixture) !void {
        var f = try self.tmp.dir.openFile(std.testing.io, "src/demo.layouts.json", .{ .mode = .read_write });
        defer f.close(std.testing.io);
        const stat = try f.stat(std.testing.io);
        try f.setTimestamps(std.testing.io, .{
            .access_timestamp = .init(stat.atime),
            .modify_timestamp = .{ .new = stat.mtime.addDuration(.{ .nanoseconds = std.time.ns_per_s }) },
        });
    }
};

// spec: serve/thermal_cache - a cached field is returned only while the design, its checks, its imported library files, its layout sidecars and its live-edit version are all unchanged, and a stale entry is dropped on the lookup that finds it
test "thermal cache hits, then misses after a sidecar edit and after a live-version bump" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var store: Store = .{ .allocator = testing.allocator };
    defer store.deinit();

    const solved = try fakeResults(testing.allocator, 12, 4);
    defer freeResults(testing.allocator, solved);
    store.put(testing.allocator, &fx.eval, fx.key(0), solved);

    const hit = store.get(testing.allocator, fx.key(0)) orelse return error.ExpectedHit;
    defer freeResults(testing.allocator, hit);
    try testing.expectEqual(@as(f64, 12), hit[0].hotspot.rise_c);

    // A live edit to the design bumps the version without touching a file.
    try testing.expect(store.get(testing.allocator, fx.key(1)) == null);
    // ...and that miss DROPPED the entry rather than leaving it to rot.
    try testing.expectEqual(@as(usize, 0), store.entries.count());

    store.put(testing.allocator, &fx.eval, fx.key(0), solved);
    try fx.touchSidecar();
    try testing.expect(store.get(testing.allocator, fx.key(0)) == null);
}

// spec: serve/thermal_cache - a hit is a deep copy the caller owns, so it survives both the request arena it was solved in and the entry's eviction
test "thermal cache hands back a copy that outlives the entry" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var store: Store = .{ .allocator = testing.allocator };
    defer store.deinit();

    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    const solved = try fakeResults(arena.allocator(), 9, 4);
    solved[0].scenario = .heatsink;
    solved[0].heatsink_ref = try arena.allocator().dupe(u8, "U1");
    store.put(arena.allocator(), &fx.eval, fx.key(0), solved);
    // The arena that solved it is gone — the entry must not point into it.
    arena.deinit();

    const hit = store.get(testing.allocator, fx.key(0)) orelse return error.ExpectedHit;
    defer freeResults(testing.allocator, hit);
    try testing.expectEqualStrings("U1", hit[0].parts[0].ref_des);
    try testing.expectEqualStrings("U1", hit[0].heatsink_ref);

    // Evicting the entry must not disturb the copy already handed out.
    store.mutex.lock();
    var keys = store.entries.keyIterator();
    const removed = store.entries.fetchRemove(keys.next().?.*).?;
    store.freeEntry(testing.allocator, removed.key, removed.value);
    store.mutex.unlock();
    try testing.expectEqualStrings("U1", hit[0].parts[0].ref_des);
    try testing.expectEqualStrings("U1", hit[0].heatsink_ref);
    try testing.expectEqual(@as(f64, 9), hit[0].grid.rise_c[0]);
}

// spec: serve/thermal_cache - entries are keyed by project directory as well as design name, so the same design name in two projects never crosses over
test "thermal cache keys on the project directory as well as the design name" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var store: Store = .{ .allocator = testing.allocator };
    defer store.deinit();

    const solved = try fakeResults(testing.allocator, 30, 4);
    defer freeResults(testing.allocator, solved);
    store.put(testing.allocator, &fx.eval, fx.key(0), solved);

    // Same design name, a different project: a hit here would be another
    // board's heat map under this board's name.
    var other = fx.key(0);
    other.project_dir = "/some/other/project";
    try testing.expect(store.get(testing.allocator, other) == null);
    try testing.expect(readsBack(&store, fx.key(0)));
}

// spec: serve/thermal_cache - entries are keyed by the saved layout the field was solved over, so two layouts of one design keep separate fields
test "thermal cache keys on the saved layout as well as the design" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var store: Store = .{ .allocator = testing.allocator };
    defer store.deinit();

    const default_board = try fakeResults(testing.allocator, 30, 4);
    defer freeResults(testing.allocator, default_board);
    store.put(testing.allocator, &fx.eval, fx.key(0), default_board);

    // Two saved layouts of one design are two different boards for heat: the
    // same parts, placed differently, over different copper. A hit here would
    // report one layout's temperatures under the other's name — the exact
    // mistake this page exists to let a reader avoid.
    var named = fx.key(0);
    named.layout = "RF-final";
    try testing.expect(store.get(testing.allocator, named) == null);

    const other_board = try fakeResults(testing.allocator, 70, 4);
    defer freeResults(testing.allocator, other_board);
    store.put(testing.allocator, &fx.eval, named, other_board);

    // …and now each answers with its own field, neither having displaced the
    // other: comparing layouts reads both back in one page load.
    const hot = store.get(testing.allocator, named) orelse return error.ExpectedHit;
    defer freeResults(testing.allocator, hot);
    try testing.expectEqual(@as(f64, 70), hot[0].grid.rise_c[0]);
    const cool = store.get(testing.allocator, fx.key(0)) orelse return error.ExpectedHit;
    defer freeResults(testing.allocator, cool);
    try testing.expectEqual(@as(f64, 30), cool[0].grid.rise_c[0]);
}

// spec: serve/thermal_cache - the store is bounded by entry count and by retained bytes, evicting least-recently-used first, and refuses outright to retain a single field larger than the whole budget
test "thermal cache evicts the least recently used and refuses an over-budget field" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var store: Store = .{ .allocator = testing.allocator };
    defer store.deinit();

    // Fill the store exactly to its limit — `demo` first, then one short of
    // `max_entries` more — and only THEN read `demo` back, which makes it the
    // most recently used and `d0` the oldest. Reading it earlier would not save
    // it: recency is a single clock, so a put that lands after the read is
    // newer than the read.
    var buf: [8]u8 = undefined;
    const solved = try fakeResults(testing.allocator, 5, 2);
    defer freeResults(testing.allocator, solved);
    store.put(testing.allocator, &fx.eval, fx.key(0), solved);
    for (0..max_entries - 1) |i| {
        const name = try std.fmt.bufPrint(&buf, "d{d}", .{i});
        store.put(testing.allocator, &fx.eval, .{ .project_dir = fx.root, .name = name, .live_version = 0 }, solved);
    }
    try testing.expectEqual(max_entries, store.entries.count());
    try testing.expect(readsBack(&store, fx.key(0)));

    // One design too many. The victim is the least recently used — `d0`, the
    // oldest design nobody read back — and `demo` survives on its read.
    const overflow = try std.fmt.bufPrint(&buf, "d{d}", .{max_entries});
    store.put(testing.allocator, &fx.eval, .{ .project_dir = fx.root, .name = overflow, .live_version = 0 }, solved);
    try testing.expectEqual(max_entries, store.entries.count());
    try testing.expect(readsBack(&store, fx.key(0)));
    try testing.expect(store.get(testing.allocator, .{ .project_dir = fx.root, .name = "d0", .live_version = 0 }) == null);

    // A single field bigger than the whole budget is refused, never retained
    // by evicting everything else to make room for it.
    var big: Store = .{ .allocator = testing.allocator };
    defer big.deinit();
    const huge = try fakeResults(testing.allocator, 1, max_field_bytes / @sizeOf(f32) + 16);
    defer freeResults(testing.allocator, huge);
    big.put(testing.allocator, &fx.eval, fx.key(0), huge);
    try testing.expectEqual(@as(usize, 0), big.entries.count());
}

// spec: serve/thermal_cache - a store with no allocator misses every lookup and retains nothing, which is what an offline CLI run and a handler test both want
test "a thermal store with no allocator caches nothing" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var store: Store = .{};
    defer store.deinit();

    const solved = try fakeResults(testing.allocator, 40, 4);
    defer freeResults(testing.allocator, solved);
    store.put(testing.allocator, &fx.eval, fx.key(0), solved);
    try testing.expectEqual(@as(usize, 0), store.entries.count());
    try testing.expect(store.get(testing.allocator, fx.key(0)) == null);
}

// spec: serve/thermal_cache - the published store is what every cache-aware surface reads, and nothing is published when no server is running
test "the published thermal store is what active() hands out" {
    try testing.expect(active() == null);
    var store: Store = .{};
    defer store.deinit();
    publish(&store);
    try testing.expectEqual(@as(?*Store, &store), active());
    publish(null);
    try testing.expect(active() == null);
}

/// One worker's share of the contention test: retain a ladder under a rotating
/// name and read one straight back, so every thread drives `put`, the replace
/// path, `get` and the eviction sweep at the same time as its peers.
fn hammerStore(store: *Store, fx: *const Fixture, seed: usize) void {
    var buf: [16]u8 = undefined;
    for (0..40) |i| {
        const name = std.fmt.bufPrint(&buf, "d{d}", .{(seed + i) % (max_entries * 2)}) catch return;
        const key: Key = .{ .project_dir = fx.root, .name = name, .live_version = 0 };
        const solved = fakeResults(testing.allocator, 7, 4) catch return;
        defer freeResults(testing.allocator, solved);
        store.put(testing.allocator, &fx.eval, key, solved);
        _ = readsBack(store, key);
    }
}

/// Run four workers over one store and wait for all of them, so the test body
/// asserts rather than orchestrates.
fn runHammers(store: *Store, fx: *const Fixture) !void {
    var threads: [4]std.Thread = undefined;
    for (&threads, 0..) |*t, i| t.* = try std.Thread.spawn(.{}, hammerStore, .{ store, fx, i * 3 });
    for (threads) |t| t.join();
}

// spec: serve/thermal_cache - every lookup, insert and eviction is serialised on the store's own lock, so concurrent request threads sharing one store can read and retain simultaneously without tearing an entry or handing back a field another thread is evicting
test "a shared thermal store survives concurrent readers and writers" {
    var fx = try Fixture.init();
    defer fx.deinit();
    var store: Store = .{ .allocator = testing.allocator };
    defer store.deinit();

    // Sixteen designs over four threads against a store that retains eight:
    // every worker is evicting entries the others are inserting and reading.
    try runHammers(&store, &fx);

    // The lock is held across the eviction sweep as well as the insert, so the
    // store lands inside its own bounds rather than somewhere between two
    // half-applied updates — and the byte total still matches what it holds.
    try testing.expect(store.entries.count() <= max_entries);
    try testing.expect(store.bytes <= max_field_bytes);
    const sample = try fakeResults(testing.allocator, 7, 4);
    defer freeResults(testing.allocator, sample);
    try testing.expectEqual(sizeOf(sample) * store.entries.count(), store.bytes);
}
