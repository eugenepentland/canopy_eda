//! The one shape of a dependency-cached GET endpoint.
//!
//! Three handlers answer a design surface out of a `read_cache.Store`:
//! `/api/pcb-describe` (the spatial-facts document), `/api/layout-progress`
//! (the completion ladder) and `/api/pcb-png` (the board image). All three had
//! the same thirty-line body copied out — read the live version BEFORE
//! computing, try the cache, compute, classify a failure, frame the response,
//! retain against the read-set the computation stamped — and `twin-drift`
//! measured the copies at 68-70% agreement: the image handler validated its
//! `:name` parameter through `pcb_layout_page.nameParam` while the other two
//! open-coded it, and only one of them framed a cache HIT the same way it
//! framed a fresh answer.
//!
//! What genuinely differs is four functions and three framing decisions, so
//! those are a comptime configuration and the body exists once.
//!
//! Nothing here imports the handler layer: the configuration carries the
//! compute, failure and version functions as comptime values, so this module
//! sits below `pcb_layout_page.zig` in the import graph rather than beside it.

const std = @import("std");
const httpz = @import("httpz");
const page_cache = @import("page_cache.zig");

/// Which half of a `PngFail` a surface writes when the solve fails: the
/// plain-text sentence an image endpoint returns, or the JSON object a facts
/// endpoint returns. The two halves are built together so an unknown design
/// reads the same on both.
pub const ErrorBody = enum { text, json };

/// What a store's `serve` is asked for: the request/response pair to answer
/// into, the scratch a lookup key is built in, the design name, and the live
/// version read BEFORE the answer was computed. Named rather than passed as an
/// anonymous literal so this module states the store contract it depends on,
/// and so a test double can spell the same parameter.
const Lookup = struct {
    scratch: std.mem.Allocator,
    req: *httpz.Request,
    res: *httpz.Response,
    name: []const u8,
    live_version: u32,
};

/// What a store is handed to retain one answer: the body, the read-set it was
/// computed from, the version captured before the computation (null when the
/// lookup did not miss, which refuses retention) and the version now (ahead of
/// it means an edit raced the computation).
const Retention = struct {
    scratch: std.mem.Allocator,
    req: *httpz.Request,
    res: *httpz.Response,
    name: []const u8,
    body: []const u8,
    files: ?page_cache.FileSet,
    live_version: ?u32,
    current_version: u32,
};

/// One dependency-cached GET endpoint over a `read_cache.Store`.
///
/// `cfg` binds the four things such an endpoint differs in, as comptime values:
///
///   * `compute(alloc, project_dir, name, opts, *?FileSet) E![]u8` — the work,
///     which also hands back the read-set the answer is retained against.
///   * `request_opts(alloc, req)` — the query knobs `compute` takes.
///   * `failure(err)` — the wire classification of a failed solve, carrying
///     `status`, `msg` and `json`.
///   * `version_of(name)` — the design's live-edit generation.
///
/// plus `content_type`, `error_body` and `no_store` for the framing.
pub fn Endpoint(comptime cfg: anytype) type {
    return struct {
        /// Answer one request: serve a valid cached body, else compute it,
        /// frame it and retain it against the read-set the computation stamped.
        ///
        /// Request-scoped allocation uses `req.arena` (freed after the response
        /// is sent; `res.body` stays valid until then) — the retained COPY lives
        /// in the store's own long-lived allocator, so the arena is still free
        /// to go.
        pub fn answer(
            store: anytype,
            project_dir: []const u8,
            name: []const u8,
            req: *httpz.Request,
            res: *httpz.Response,
        ) void {
            const arena = req.arena;
            // Read the live version BEFORE computing, so a design edit that
            // lands mid-request is treated as a miss next time instead of being
            // baked in.
            const live_version = cfg.version_of(name);
            var miss_version: ?u32 = null;
            if (store.serve(Lookup{
                .scratch = arena,
                .req = req,
                .res = res,
                .name = name,
                .live_version = live_version,
            }, &miss_version)) {
                frame(res);
                return;
            }

            const opts = cfg.request_opts(arena, req);
            var deps: ?page_cache.FileSet = null;
            const body = cfg.compute(arena, project_dir, name, opts, &deps) catch |e| {
                // `compute` stamps the read-set through a `defer`, so a failed
                // solve still produced one and nothing else will free it.
                if (deps) |d| d.deinit();
                const fail = cfg.failure(e);
                res.status = fail.status;
                switch (cfg.error_body) {
                    .json => {
                        res.content_type = .JSON;
                        res.body = fail.json;
                    },
                    .text => res.body = fail.msg,
                }
                return;
            };
            frame(res);
            res.body = body;
            store.store(Retention{
                .scratch = arena,
                .req = req,
                .res = res,
                .name = name,
                .body = body,
                .files = deps,
                .live_version = miss_version,
                .current_version = cfg.version_of(name),
            });
        }

        /// The response framing this endpoint always answers with, applied on
        /// the hit and the fresh path alike so a cached answer is indistinguish-
        /// able from a computed one.
        fn frame(res: *httpz.Response) void {
            res.content_type = cfg.content_type;
            if (cfg.no_store) res.header("Cache-Control", "no-store");
        }
    };
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// A store stub: it answers from `hit_body` when one is set, and otherwise
/// records what the endpoint tried to retain. Duck-typed exactly as `Endpoint`
/// reads a real `read_cache.Store`.
const StubStore = struct {
    hit_body: ?[]const u8 = null,
    stored: ?[]const u8 = null,

    fn serve(self: *StubStore, in: Lookup, miss_version: *?u32) bool {
        miss_version.* = null;
        const body = self.hit_body orelse {
            miss_version.* = in.live_version;
            return false;
        };
        in.res.body = body;
        return true;
    }

    fn store(self: *StubStore, in: Retention) void {
        if (in.files) |f| f.deinit();
        self.stored = in.body;
    }
};

/// The classification a real surface's `failure` returns: one status with a
/// plain-text and a JSON wording of the same outcome.
const StubFail = struct { status: u16, msg: []const u8, json: []const u8 };

fn stubVersion(name: []const u8) u32 {
    _ = name;
    return 0;
}

fn stubOpts(alloc: std.mem.Allocator, req: *httpz.Request) void {
    _ = alloc;
    _ = req;
}

fn stubFailure(e: error{NotFound}) StubFail {
    return switch (e) {
        error.NotFound => .{
            .status = 404,
            .msg = "no such design",
            .json = "{\"error\":\"no such design\"}",
        },
    };
}

fn stubCompute(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    opts: void,
    deps: ?*?page_cache.FileSet,
) error{NotFound}![]u8 {
    _ = project_dir;
    _ = opts;
    if (deps) |out| out.* = null;
    if (std.mem.eql(u8, name, "missing")) return error.NotFound;
    return alloc.dupe(u8, "FRESH") catch return error.NotFound;
}

/// An image-shaped endpoint: one content type, a `no-store` header, and a
/// plain-text failure — the `/api/pcb-png` configuration with stub work.
const stub_endpoint = Endpoint(.{
    .compute = stubCompute,
    .request_opts = stubOpts,
    .failure = stubFailure,
    .version_of = stubVersion,
    .content_type = httpz.ContentType.PNG,
    .error_body = ErrorBody.text,
    .no_store = true,
});

// spec: Web Server - A cached read endpoint frames a hit exactly as a freshly computed answer and reports a failed computation in its own error shape
test "a cached endpoint frames a hit and a fresh answer identically" {
    var stub: StubStore = .{};

    // A fresh answer: the bytes reach the response under this endpoint's
    // framing, and are handed to the store to retain.
    var miss = httpz.testing.init(.{});
    defer miss.deinit();
    stub_endpoint.answer(&stub, ".", "demo", miss.req, miss.res);
    try testing.expectEqualStrings("FRESH", miss.res.body);
    try testing.expectEqual(httpz.ContentType.PNG, miss.res.content_type);
    try testing.expectEqualStrings("no-store", miss.res.headers.get("Cache-Control").?);
    try testing.expectEqualStrings("FRESH", stub.stored.?);

    // A HIT must be indistinguishable from it: retention that dropped the
    // content type would hand a browser an image it renders as text.
    stub.hit_body = "CACHED";
    var hit = httpz.testing.init(.{});
    defer hit.deinit();
    stub_endpoint.answer(&stub, ".", "demo", hit.req, hit.res);
    try testing.expectEqualStrings("CACHED", hit.res.body);
    try testing.expectEqual(httpz.ContentType.PNG, hit.res.content_type);
    try testing.expectEqualStrings("no-store", hit.res.headers.get("Cache-Control").?);

    // A failed computation is this endpoint's own error wording with its own
    // status, and nothing is retained against it.
    stub.hit_body = null;
    stub.stored = null;
    var fail = httpz.testing.init(.{});
    defer fail.deinit();
    stub_endpoint.answer(&stub, ".", "missing", fail.req, fail.res);
    try testing.expectEqual(@as(u16, 404), fail.res.status);
    try testing.expectEqualStrings("no such design", fail.res.body);
    try testing.expect(stub.stored == null);
}
