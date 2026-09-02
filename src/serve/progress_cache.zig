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
//! rather than risking a mismatched entry. That is exactly `read_cache.Store`
//! with an EMPTY keyed-parameter list: its strict allow-list admits nothing, so
//! any query at all bypasses and the plain request's key is the design name.
//!
//! What stays here is that configuration, the ladder's own dependency capture
//! (`captureDeps`, which the describe and image surfaces also read through
//! because their answers embed this one), and the tests that pin them.

const std = @import("std");
const httpz = @import("httpz");
const paths = @import("../paths.zig");
const page_cache = @import("page_cache.zig");
const read_cache = @import("read_cache.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;

/// `GET /api/layout-progress/:name`. No keyed parameters at all: every query
/// this endpoint accepts either selects a different board or forces a fresh
/// solve, so all of them bypass.
///
/// Each body is a few kilobytes of ladder JSON, so the entry cap is a generous
/// ceiling for any real project's design count and the byte budget is
/// deliberately its own figure — a ladder is orders of magnitude smaller than a
/// rendered PCB page.
pub const config: read_cache.Config = .{
    .header = "X-Netlisp-Progress-Cache",
    .max_entries = 64,
    .max_bytes = 8 * 1024 * 1024,
};

/// One server instance's bounded ladder-JSON cache. `allocator=null`
/// intentionally disables it for handler tests that construct `ServerState{}`.
pub const Store = read_cache.Store(config);

/// Sidecars the ladder reads that the evaluator never parses, so
/// `page_cache.capture` cannot know about them: the saved layouts (poses +
/// persisted copper — what the routing and placement rungs are computed from),
/// the legacy single-layout file still honoured as a fallback, and the design's
/// per-kind DRC severity overrides (they decide which violations the fab rung
/// counts as blocking). A module `(sub-block …)`'s own `<module>.layouts.json`
/// — read for each sub-circuit's ★ status — is already stamped by `capture`
/// for every loaded `lib/modules/*.sexp`.
const sidecar_exts = [_][]const u8{ ".layouts.json", ".autolayout.json", ".drc-rules.json" };

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

// spec: Web Server - The layout-progress ladder endpoint bypasses its cache for any query parameter
test "progress cache admits only the query-free request" {
    var cache: Store = .{ .allocator = testing.allocator };
    defer cache.deinit();

    var plain = httpz.testing.init(.{});
    defer plain.deinit();
    try testing.expect(!roundTrip(&cache, &plain, "PLAIN", try page_cache.captureOne("build.zig")));
    var again = httpz.testing.init(.{});
    defer again.deinit();
    try testing.expect(roundTrip(&cache, &again, "UNUSED", null));

    // Every parameter the ladder endpoint accepts selects a different board or
    // forces a fresh solve, and the home page sends none of them — so each
    // bypasses in BOTH directions rather than reading or writing an entry.
    for ([_][2][]const u8{
        .{ "layout", "RF-final" },
        .{ "route", "1" },
        .{ "sub", "amp1" },
    }) |pair| {
        var bypass = httpz.testing.init(.{});
        defer bypass.deinit();
        bypass.query(pair[0], pair[1]);
        try testing.expect(!roundTrip(&cache, &bypass, "BYPASS", try page_cache.captureOne("build.zig")));
        try testing.expectEqualStrings("bypass", bypass.res.headers.get(config.header).?);
    }
    try testing.expectEqual(@as(usize, 1), cache.entries.count());
}

// spec: Web Server - The layout-progress ladder endpoint reuses a dependency-validated JSON body and invalidates it when the design or its sidecars change
test "progress cache hits then invalidates after a layout-sidecar edit" {
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
        "{\"name\":\"demo\"}",
        captureDeps(first.arena, &.{&eval}, root, "demo"),
    ));

    var hit = httpz.testing.init(.{});
    defer hit.deinit();
    try testing.expect(roundTrip(&cache, &hit, "UNUSED", null));
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
    try testing.expect(!roundTrip(&cache, &stale, "FRESH", null));
}

// spec: Web Server - The layout-progress cache refuses a body whose dependency set stamps nothing
test "progress cache refuses an empty dependency set" {
    var cache: Store = .{ .allocator = testing.allocator };
    defer cache.deinit();

    // A read-set that stamps nothing could never go stale, so caching against
    // it would pin the first answer for the life of the process.
    var req = httpz.testing.init(.{});
    defer req.deinit();
    try testing.expect(!roundTrip(&cache, &req, "{}", null));
    try testing.expectEqual(@as(usize, 0), cache.entries.count());
}

// spec: Web Server - The progress store accepts a ladder computed off-request under the same size and read-set rules as a served one
test "warm retains an off-request ladder but still refuses an empty dependency set" {
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "dep.sexp", .data = "(design-block \"D\")" });
    const dep = try tmp.dir.realPathFileAlloc(std.testing.io, "dep.sexp", testing.allocator);
    defer testing.allocator.free(dep);

    var store: Store = .{ .allocator = testing.allocator };
    defer store.deinit();

    // A ladder the warm-up computed has no request to be judged query-free and
    // no response status, but it must land exactly as a served one does — under
    // the plain identity, whose key is the design name itself.
    store.warm("warmed", "{\"stages\":[]}", try page_cache.captureOne(dep), 7);
    try testing.expect(store.entries.contains("warmed"));

    // An empty read-set keys on nothing that can go stale, so it is refused
    // here for the same reason the request path refuses it.
    store.warm("unkeyed", "{\"stages\":[]}", .{ .stamps = &.{} }, 7);
    try testing.expect(!store.entries.contains("unkeyed"));
}
