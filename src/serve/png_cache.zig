//! Dependency-aware cache for the board images served by
//! `GET /api/pcb-png/:name`, and the handler that answers from it.
//!
//! This is the endpoint an AI agent uses to *see* a board, and it was the last
//! expensive read surface with no retention at all: measured on this project's
//! boards, a plain request cost **25.1 s cold and 23.7 s hot** for `board-a`
//! and **26.9 s / 28.3 s** for `board-a-base` against an already-warm server —
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
//! client's. Because the framing is the same on a hit and on a fresh render,
//! it is applied in exactly one place — `page_cache_endpoint.Endpoint`, which is also
//! where the identical hit/compute/retain body the describe and ladder
//! endpoints used to hand-copy now lives.
//!
//! Only query modes whose cache semantics have been considered may share an
//! entry, and they are folded into the key rather than ignored — the strict
//! allow-list every `read_cache.Store` applies, so a future framing parameter
//! bypasses by default instead of silently serving someone else's picture.
//! `?route=1` (route fresh) and `?regen=1` (force a fresh solve) are one-shot
//! modes whose whole point is to recompute, so they bypass along with `?sub=`
//! and every unrecognised parameter.

const std = @import("std");
const httpz = @import("httpz");
const page_cache_endpoint = @import("page_cache_endpoint.zig");
const page_cache = @import("page_cache.zig");
const progress_cache = @import("progress_cache.zig");
const read_cache = @import("read_cache.zig");
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

/// `GET /api/pcb-png/:name`. The keyed parameters change the IMAGE
/// deterministically, so one design can hold several: which saved board
/// (`layout`), how big (`width`), how parts are labelled (`names`), what is
/// spotlit (`nets`, `refs`), which pads carry net labels (`pins`), what the
/// viewport is cropped to (`crop` + its radius `r`, or `cropnet`), whether it is
/// a contact sheet (`sheet`) or carries the callout overlay (`critique`), and
/// the heat-field twin with its cooling assumptions (`thermal`, `scenario`,
/// `ambient`).
///
/// Everything else bypasses — `route`, `regen` and `sub` for the reasons in the
/// header, and every tuning knob and diagnostic overlay because nothing has
/// established that its image is a pure function of the same read-set. A
/// parameter earns a place here by being considered, not by being harmless.
///
/// The entry cap is a handful of designs times those framing variants, so a
/// burst of crops cannot grow the store without bound. The byte budget is its
/// own figure, measured rather than guessed: a default-width board image is
/// 69 KB (`Board-B-Flex`) to 449 KB (`board-a`), so 32 entries of real
/// traffic occupy well under half of it and the entry cap is what actually
/// binds. The headroom exists for the wide framing requests — `?width=4000`, a
/// `?sheet=1` contact sheet — that a review loop asks for a few of. It is an
/// order of magnitude below the rendered-page store's 128 MB because an image
/// is a secondary surface, not the navigation hot path.
pub const config: read_cache.Config = .{
    .header = "X-Netlisp-Png-Cache",
    .keyed_params = &.{
        "layout",   "width",   "names",   "nets",  "refs",     "pins",
        "crop",     "r",       "cropnet", "sheet", "critique", "thermal",
        "scenario", "ambient", "layer",
    },
    .max_entries = 32,
    .max_bytes = 32 * 1024 * 1024,
};

/// One server instance's bounded board-image cache. `allocator=null`
/// intentionally disables it for handler tests that construct `ServerState{}`.
pub const Store = read_cache.Store(config);

/// The image endpoint: render with `renderDesignPng`, classify a failed solve
/// as the PNG handler's plain-text body, and frame every answer — cached or
/// fresh — as a `no-store` image.
const image_endpoint = page_cache_endpoint.Endpoint(.{
    .compute = pcb_layout_page.renderDesignPng,
    .request_opts = pcb_layout_page.pngRequestFromQuery,
    .failure = pcb_layout_page.pngFailure,
    .version_of = serve_root.getLiveVersion,
    .content_type = httpz.ContentType.PNG,
    .error_body = page_cache_endpoint.ErrorBody.text,
    .no_store = true,
});

/// GET /api/pcb-png/:name — the body of `pcb_layout_page.pcbPngApi`. Answer an
/// allow-listed request from the retention above, else render it and retain the
/// bytes against the read-set the render captured.
pub fn serveImage(ctx: *Server, req: *httpz.Request, res: *httpz.Response) pcb_layout_page.HandlerError!void {
    const name = pcb_layout_page.nameParam(req, res) orelse return;
    image_endpoint.answer(&ctx.state.caches.reads.png_images, ctx.project_dir, name, req, res);
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

// spec: Web Server - The PCB image endpoint caches only its allow-listed framing modes and bypasses fresh-route, fresh-solve and sub-scoped requests
test "png cache allow-lists its query modes and keys the ones it admits" {
    var cache: Store = .{ .allocator = testing.allocator };
    defer cache.deinit();

    var plain = httpz.testing.init(.{});
    defer plain.deinit();
    try testing.expect(!roundTrip(&cache, &plain, "PLAIN", try page_cache.captureOne("build.zig")));

    // `?route=1` re-routes and `?regen=1` re-solves — one-shot modes whose whole
    // purpose is to recompute. A sub-scoped view reads a per-sub sidecar the
    // shared read-set never stamps. An unrecognised parameter joins them by
    // default: the whole point of the allow-list is that a new framing knob is
    // safe until its cache semantics are considered.
    try expectBypasses(&cache, &.{
        .{ "route", "1" },
        .{ "regen", "1" },
        .{ "sub", "amp1" },
        .{ "blame", "1" },
    });
    try testing.expectEqual(@as(usize, 1), cache.entries.count());

    // Every admitted mode is keyed, not ignored: each frames a different
    // picture, so none of them may answer another's request — and two VALUES of
    // one admitted parameter are two entries, which is what keeps a `?layout=A`
    // image from being served for `?layout=B` (or a 600 px board for a 2400 px
    // request).
    for (config.keyed_params) |param| {
        var variant = httpz.testing.init(.{});
        defer variant.deinit();
        variant.query(param, "x");
        try testing.expect(!roundTrip(&cache, &variant, "VARIANT", try page_cache.captureOne("build.zig")));

        var other = httpz.testing.init(.{});
        defer other.deinit();
        other.query(param, "y");
        try testing.expect(!roundTrip(&cache, &other, "OTHER", try page_cache.captureOne("build.zig")));
    }

    // The plain image survived the whole sweep: a variant burst is evicted
    // before the query-free picture every caller asks for.
    var again = httpz.testing.init(.{});
    defer again.deinit();
    try testing.expect(roundTrip(&cache, &again, "UNUSED", null));
    try testing.expectEqualStrings("PLAIN", again.res.body);
}

// spec: Web Server - The PCB image endpoint reuses a dependency-validated image and invalidates it when the design or its sidecars change
test "png cache returns the identical bytes then invalidates after a layout-sidecar edit" {
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
    try testing.expect(!roundTrip(
        &cache,
        &first,
        image,
        progress_cache.captureDeps(first.arena, &.{&eval}, root, "demo"),
    ));

    var hit = httpz.testing.init(.{});
    defer hit.deinit();
    try testing.expect(roundTrip(&cache, &hit, "UNUSED", null));
    try testing.expectEqualSlices(u8, image, hit.res.body);

    // The plain entry is not the `?layout=` one: a named board's picture must
    // never be answered from the starred default's, or the other way round.
    var variant = httpz.testing.init(.{});
    defer variant.deinit();
    variant.query("layout", "RF-final");
    try testing.expect(!roundTrip(&cache, &variant, "OTHER", null));

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
    try testing.expect(!roundTrip(&cache, &stale, "FRESH", null));
}

// spec: Web Server - The PCB image cache retains nothing when its server gave it no allocator
test "png cache with no allocator retains nothing and always reports a miss" {
    // `ServerState{}` — what a handler test constructs — leaves every store
    // without an allocator, and a store without one must compute every image
    // fresh rather than half-participate. It is also the state the store is in
    // before `Caches.init`, so this is the safe default, not just a test aid.
    var off: Store = .{};
    defer off.deinit();

    var req = httpz.testing.init(.{});
    defer req.deinit();
    try testing.expect(!roundTrip(&off, &req, "\x89PNG", try page_cache.captureOne("build.zig")));
    try testing.expectEqual(@as(usize, 0), off.entries.count());
    try testing.expectEqual(@as(usize, 0), off.bytes);
}

// spec: Web Server - The PCB image cache refuses a body whose dependency set stamps nothing
test "png cache refuses an empty dependency set and an uncacheable mode" {
    var cache: Store = .{ .allocator = testing.allocator };
    defer cache.deinit();

    // A read-set that stamps nothing could never go stale, so caching against
    // it would pin the first picture for the life of the process.
    var req = httpz.testing.init(.{});
    defer req.deinit();
    try testing.expect(!roundTrip(&cache, &req, "\x89PNG", null));
    try testing.expectEqual(@as(usize, 0), cache.entries.count());

    // A bypassing mode may not write an entry either — a `?route=1` image
    // shows copper this board does not have saved.
    var fresh = httpz.testing.init(.{});
    defer fresh.deinit();
    fresh.query("route", "1");
    try testing.expect(!roundTrip(&cache, &fresh, "\x89PNG", try page_cache.captureOne("build.zig")));
    try testing.expectEqual(@as(usize, 0), cache.entries.count());
}
