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
//! allow-list every store in `read_cache.zig` applies, so a future server-side
//! query parameter bypasses by default instead of silently aliasing onto
//! someone else's facts. `?route=1` (route fresh, with stuck-net diagnostics)
//! and `?regen=1` (force a fresh solve) are one-shot modes whose whole point is
//! to recompute, so they bypass along with every unrecognised parameter.
//!
//! The store itself is `read_cache.Store` — the generic this file used to be a
//! hand-copy of. What remains here is the configuration (the header, the three
//! keyed parameters and the budgets) and the tests that pin THIS surface's
//! allow-list; the LRU bound, the dependency validation and the retention rules
//! are shared with every other read cache.

const std = @import("std");
const httpz = @import("httpz");
const page_cache = @import("page_cache.zig");
const read_cache = @import("read_cache.zig");

/// `GET /api/pcb-describe/:name`. The keyed parameters change the facts
/// deterministically: `layout` picks which saved board is described, `cropnet`
/// adds the zoom lens' world bbox, and `pads` adds the per-part pad detail.
/// Everything else — `route`, `regen`, `sub`, the tuning knobs, and every
/// PNG-only framing parameter — bypasses.
///
/// A facts document is far bigger than a ladder (it carries the per-part,
/// per-loop and per-DRC-finding detail) and far smaller than a rendered PCB
/// page, so the byte budget is neither of those stores'.
pub const config: read_cache.Config = .{
    .header = "X-Netlisp-Describe-Cache",
    .keyed_params = &.{ "layout", "cropnet", "pads" },
    .max_entries = 32,
    .max_bytes = 64 * 1024 * 1024,
};

/// One server instance's bounded facts-JSON cache. `allocator=null`
/// intentionally disables it for handler tests that construct `ServerState{}`.
pub const Store = read_cache.Store(config);

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// Look `ht` up in `store` and, on a miss, retain `body` against `files`.
/// Returns whether the lookup HIT, which is the only thing these tests ask.
fn roundTrip(store: *Store, ht: *httpz.testing.Testing, body: []const u8, files: ?page_cache.FileSet) bool {
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
        .files = files,
        .live_version = miss_version,
        .current_version = @as(u32, 0),
    });
    return false;
}

/// Drive each `<key, value>` query through `cache` and require it to bypass in
/// BOTH directions: reading no entry, and writing none even though the answer
/// came with a perfectly good read-set.
fn expectBypasses(cache: *Store, pairs: []const [2][]const u8) !void {
    for (pairs) |pair| {
        var bypass = httpz.testing.init(.{});
        defer bypass.deinit();
        bypass.query(pair[0], pair[1]);
        try testing.expect(!roundTrip(cache, &bypass, "BYPASS", try page_cache.captureOne("build.zig")));
        try testing.expectEqualStrings("bypass", bypass.res.headers.get(config.header).?);
    }
}

// spec: Web Server - The PCB-describe endpoint caches only its allow-listed query modes and bypasses fresh-solve and sub-scoped requests
test "describe cache allow-lists its query modes and keys the ones it admits" {
    var cache: Store = .{ .allocator = testing.allocator };
    defer cache.deinit();
    var plain = httpz.testing.init(.{});
    defer plain.deinit();
    try testing.expect(!roundTrip(&cache, &plain, "PLAIN", try page_cache.captureOne("build.zig")));

    // `?route=1` re-routes, `?regen=1` re-solves and `?sub=` reads a per-sub
    // sidecar the shared read-set never stamps: one-shot or unstamped modes
    // that may neither read nor write an entry. An unrecognised parameter joins
    // them by default — the whole point of the allow-list is that a new
    // server-side query feature is safe until its cache semantics are known.
    try expectBypasses(&cache, &.{
        .{ "route", "1" },
        .{ "regen", "1" },
        .{ "sub", "amp1" },
        .{ "court_overlap", "0.2" },
    });
    try testing.expectEqual(@as(usize, 1), cache.entries.count());

    // The admitted modes are keyed, not ignored: each describes a different
    // board, so none of them may answer another's request.
    for (config.keyed_params) |param| {
        var variant = httpz.testing.init(.{});
        defer variant.deinit();
        variant.query(param, "x");
        try testing.expect(!roundTrip(&cache, &variant, "VARIANT", try page_cache.captureOne("build.zig")));

        // …and two VALUES of one admitted parameter are two entries, which is
        // what keeps a `?layout=A` document from answering for `?layout=B`.
        var other = httpz.testing.init(.{});
        defer other.deinit();
        other.query(param, "y");
        try testing.expect(!roundTrip(&cache, &other, "OTHER", try page_cache.captureOne("build.zig")));
    }

    // The plain answer survived every one of those: it is never displaced by a
    // variant while the store is inside its budget.
    var again = httpz.testing.init(.{});
    defer again.deinit();
    try testing.expect(roundTrip(&cache, &again, "UNUSED", null));
    try testing.expectEqualStrings("PLAIN", again.res.body);
}

// spec: Web Server - The PCB-describe endpoint reuses a dependency-validated facts document and invalidates it when the design or its sidecars change
test "describe cache hits then invalidates after a layout-sidecar edit" {
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
    try testing.expect(!roundTrip(
        &cache,
        &first,
        "{\"design\":\"demo\"}",
        progress_cache.captureDeps(first.arena, &.{&eval}, root, "demo"),
    ));

    var hit = httpz.testing.init(.{});
    defer hit.deinit();
    try testing.expect(roundTrip(&cache, &hit, "UNUSED", null));
    try testing.expectEqualStrings("{\"design\":\"demo\"}", hit.res.body);

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
    try testing.expect(!roundTrip(&cache, &stale, "FRESH", null));
}

// spec: Web Server - The PCB-describe cache refuses a body whose dependency set stamps nothing
test "describe cache refuses an empty dependency set and an uncacheable mode" {
    var cache: Store = .{ .allocator = testing.allocator };
    defer cache.deinit();

    // A read-set that stamps nothing could never go stale, so caching against
    // it would pin the first answer for the life of the process.
    var req = httpz.testing.init(.{});
    defer req.deinit();
    try testing.expect(!roundTrip(&cache, &req, "{}", null));
    try testing.expectEqual(@as(usize, 0), cache.entries.count());

    // A bypassing mode may not write an entry either — a `?route=1` body
    // describes copper this board does not have saved.
    var fresh = httpz.testing.init(.{});
    defer fresh.deinit();
    fresh.query("route", "1");
    try testing.expect(!roundTrip(&cache, &fresh, "{}", try page_cache.captureOne("build.zig")));
    try testing.expectEqual(@as(usize, 0), cache.entries.count());
}
