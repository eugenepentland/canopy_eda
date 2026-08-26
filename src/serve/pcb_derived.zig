//! Warming the PCB editor's deferred payload.
//!
//! An editable `/pcb-layout/<name>` answers in two parts. The page itself
//! carries placement and saved copper and paints immediately; everything
//! derived from that copper — poured fills, the reporting DRC, mask relief,
//! trace EM, power integrity, the fab-identity mark — arrives afterwards from
//! `?derived=1` (see `pcb_board.js`'s `loadDeferredAnalysis`). Both halves are
//! retained in the shared PCB page cache under their own keys, and one edit
//! invalidates both — so every edit cycle used to pay a page render AND a
//! COMPLETE second render behind it: re-evaluating the design, re-parsing the
//! multi-megabyte layout sidecar, re-choosing and re-solving the placement and
//! restoring the same copper, purely to reach the analyses.
//!
//! Two changes remove that from the reader's path.
//!
//! A warm-up render now answers both halves from ONE solve: it publishes the
//! finished page through a `PageSink` the moment it is ready — so admitting the
//! page never waits on the analyses behind it — and then completes the same
//! solved view and returns the deferred JSON (`pcb_layout_page.warmPage`).
//!
//! And `spawn` starts that warm from the page handler itself. Measured on
//! barracuda (2026-08-26, Debug), the prefix a second render repeats is ~0.4 s
//! of a ~16 s response: real, but small beside the analyses, which is why
//! moving the whole deferred render off the critical path matters more than
//! the saving. It begins when the page render finishes rather than when the
//! browser gets around to asking — after a megabyte of HTML has downloaded,
//! parsed, painted and passed two animation frames — and the page cache's
//! in-flight coalescing makes the browser's fetch JOIN that render instead of
//! starting a second one.

const std = @import("std");
const httpz = @import("httpz");
const serve_root = @import("../serve.zig");
const Server = serve_root.Server;
const pcb_layout_page = @import("pcb_layout_page.zig");
const pcb_page_cache = @import("pcb_page_cache.zig");
const modules_mod = @import("modules.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const StoreRevCheck = pcb_layout_page.StoreRevCheck;
const log = @import("../infra/log.zig");

/// How a both-payload render hands the finished page back mid-call, so a
/// warm-up admits it immediately instead of holding it until the analyses
/// behind it complete. Erased to `*anyopaque` because the only implementation
/// lives with the render's own cache-retention state.
pub const PageSink = struct {
    context: *anyopaque,
    publish: *const fn (context: *anyopaque, html: []const u8) void,

    /// Hand the finished page to whoever asked for both payloads.
    pub fn call(self: PageSink, html: []const u8) void {
        self.publish(self.context, html);
    }
};

/// A warm-up's request for the page AND the `?derived=1` payload from a single
/// render. The page goes out through `publish` the moment it is complete, so
/// admitting it never waits on the analyses; the render then returns the
/// deferred JSON in the page's place and sets `took`, which is how the caller
/// tells the two bodies apart.
pub const BothPayloads = struct {
    publish: PageSink,
    took: *bool,
};

/// One warm-up's retention state, and the `PageSink` a both-payload render
/// publishes the finished page through. Split out so the page reaches the
/// cache the moment it exists — a reader after a deploy waits on the page, not
/// on the analyses that follow it into the second entry.
const PageWarm = struct {
    ctx: *Server,
    scratch: std.mem.Allocator,
    name: []const u8,
    /// Alive for the whole render: the cache stamps the files it loaded.
    eval: *const Evaluator,
    /// Captured BEFORE the render: an edit that lands mid-render leaves
    /// `current_version` ahead of it and the entry is dropped rather than
    /// served stale, exactly as on the request path.
    live_version: u32,
    rev: *const StoreRevCheck,
    /// False when the request path already holds (or has cached) the page and
    /// this render is warming only the deferred half.
    admit_page: bool,

    fn retain(self: *const PageWarm) pcb_page_cache.Retain {
        return .{
            .scratch = self.scratch,
            .project_dir = self.ctx.project_dir,
            .name = self.name,
            .eval = self.eval,
            .live_version = self.live_version,
            .current_version = serve_root.getLiveVersion(self.name),
        };
    }

    fn publishPage(context: *anyopaque, html: []const u8) void {
        const self: *PageWarm = @ptrCast(@alignCast(context));
        if (!self.admit_page) return;
        self.ctx.state.caches.pcb_pages.warm(self.retain(), .page, html, self.rev.*);
        // The response filter gzips every page after the handler returns, and a
        // megabyte board costs ~150 ms of deflate — more than the cached render
        // it wraps. That memo is keyed on the body itself and a cache hit serves
        // these exact bytes, so compressing once here retires that cost for the
        // first reader too. The stream is discarded; the memo entry is the point.
        _ = self.ctx.state.caches.gzip.compress(self.scratch, html) catch return;
    }

    fn sink(self: *PageWarm) PageSink {
        return .{ .context = self, .publish = publishPage };
    }
};

/// Which of the editor's two responses a warm-up is after.
pub const WarmScope = enum {
    /// The page alone. The boot warm-up's first pass, so a deploy has every
    /// editor page cached in about a second.
    page,
    /// The deferred payload — and the page too when nothing else holds it, in
    /// which case ONE solve answers both.
    derived,
};

/// Pre-render the plain `/pcb-layout/<name>` page — no query, no request — and
/// the `?derived=1` payload the editor fetches after first paint, and retain
/// both. This is the most expensive read-only page the server has (a routed
/// board spends hundreds of milliseconds in placement and HTML before a byte
/// reaches the wire, and the deferred half spends seconds more in pours and
/// DRC), and every cache it lands in is process-lifetime, so a deploy makes the
/// next visitor pay all of it.
///
/// ONE solve answers both: the design is evaluated, the multi-megabyte layout
/// sidecar parsed, the placement chosen and its copper restored a single time,
/// the page is published through `PageWarm` as soon as it is built, and the
/// same solved view is then completed into the deferred JSON (see
/// `pcb_derived`). Called off the request path by the boot warm-up and by
/// `pcb_derived.spawn`; best-effort. `scratch` need only outlive the call: the
/// cache dupes the bodies it keeps and the file stamps own their own memory.
pub fn warmPage(ctx: *Server, scratch: std.mem.Allocator, name: []const u8, scope: WarmScope) bool {
    const pages = &ctx.state.caches.pcb_pages;
    // Read BEFORE anything else, exactly as the handler does: an edit that
    // lands mid-render leaves `current_version` ahead of it and the entry is
    // dropped rather than served stale.
    const live_version = serve_root.getLiveVersion(name);
    // Warm-up and the already-listening request path share one render lease per
    // entry. If either side has a VALID half cached or a render in progress,
    // the other does no duplicate evaluator/pour/serialization work — and a
    // request that arrives mid-render waits for this one rather than starting
    // its own.
    const hold_page = pages.reserveWarm(scratch, name, .page, live_version);
    defer if (hold_page) pages.finishWarm(scratch, name, .page);
    // A page-scoped pass never takes the deferred lease: the boot warm-up runs
    // one of those over every board FIRST, and holding each page back for its
    // own analyses would put the last board's page twenty seconds out.
    const hold_derived = scope == .derived and pages.reserveWarm(scratch, name, .derived, live_version);
    defer if (hold_derived) pages.finishWarm(scratch, name, .derived);
    if (!hold_page and !hold_derived) return true;

    var page_ctx = ctx.*;
    page_ctx.allocator = scratch;
    var eval = Evaluator.init(scratch, ctx.project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        scratch.destroy(mr.eval);
    };
    var rev_check = StoreRevCheck{ .rendered = -1, .ctx = &page_ctx, .name = name, .sub = null };
    var warm = PageWarm{
        .ctx = ctx,
        .scratch = scratch,
        .name = name,
        .eval = &eval,
        .live_version = live_version,
        .rev = &rev_check,
        .admit_page = hold_page,
    };
    var took_both = false;
    const body = (pcb_layout_page.renderLayoutPage(&page_ctx, null, null, .{
        .name = name,
        .eval = &eval,
        .module_res_out = &module_res,
        .rev = &rev_check,
        .both = if (hold_derived) .{ .publish = warm.sink(), .took = &took_both } else null,
    }) catch return false) orelse return false;
    // The render returns the deferred JSON only when it actually took the
    // both-payload path; otherwise `body` is the page and nothing published it.
    if (!took_both) {
        PageWarm.publishPage(&warm, body);
        return true;
    }
    pages.warm(warm.retain(), .derived, body, rev_check);
    return true;
}

/// Whether this request is the plain editor page whose deferred half is worth
/// warming: the query-free `/pcb-layout/<name>` URL a reader navigates to and
/// `pcb_board.js` fetches `?derived=1` against. Every other surface either
/// emits its derived fields inline or is a read-only embed that never asks.
pub fn warmsDeferred(req: *httpz.Request) bool {
    const q = req.query() catch return false;
    return q.len == 0;
}

/// Background deferred-payload warms in flight, held on `ServerState` rather
/// than at module scope so two server instances stay independent.
///
/// The cap is small on purpose. A deferred render is the heaviest read-only
/// work this server does — seconds of pour rasterisation and DRC over
/// board-sized buffers — so a burst of saves across several designs must not
/// put one of these on every core and starve the requests they exist to make
/// faster.
pub const WarmLimit = struct {
    running: std.atomic.Value(usize) = .init(0),

    const max_concurrent: usize = 2;

    /// Take a slot, or refuse when the cap is reached. Release with `end`.
    fn begin(self: *WarmLimit) bool {
        var seen = self.running.load(.monotonic);
        while (seen < max_concurrent) {
            seen = self.running.cmpxchgWeak(seen, seen + 1, .acq_rel, .monotonic) orelse return true;
        }
        return false;
    }

    fn end(self: *WarmLimit) void {
        _ = self.running.fetchSub(1, .release);
    }
};

/// What the detached warm thread owns: a request-free copy of the server (the
/// per-request `Server` it was spawned from borrows an arena that is reset the
/// moment the response is written, so the copy keeps only the long-lived fields
/// and replaces the allocator) and its own copy of the design name.
const Warm = struct {
    server: Server,
    name: []const u8,

    fn run(self: Warm) void {
        defer {
            // allocator-ok: releasing the process-lifetime copy `spawn` made.
            std.heap.page_allocator.free(self.name);
            self.server.state.derived_warms.end();
        }
        // The warm owns its scratch and releases it before returning, so a
        // board-sized render is not retained past the entries it produced.
        // allocator-ok: detached warm-thread scratch, released at the end of this call.
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        var ctx = self.server;
        _ = warmPage(&ctx, arena.allocator(), self.name, .derived);
    }
};

/// Start warming `name`'s deferred payload on a detached thread, if a slot is
/// free. Called by the page handler after it renders a plain editor page the
/// cache did not already hold — the exact moment an edit has invalidated both
/// halves and the browser is about to ask for the second one.
///
/// Best-effort in every direction: no slot, no name copy, or no thread simply
/// means the deferred fetch renders for itself, exactly as before. The page
/// cache's own reservation keeps two warms of one design from overlapping and
/// makes the browser's `?derived=1` fetch join this render rather than start a
/// second one.
pub fn spawn(ctx: *Server, name: []const u8) void {
    if (!ctx.state.derived_warms.begin()) return;
    // Owned by the thread: `name` points into the request's URL, which is gone
    // the moment the response is written.
    // allocator-ok: process-lifetime by necessity — this outlives the request.
    const owned = std.heap.page_allocator.dupe(u8, name) catch {
        ctx.state.derived_warms.end();
        return;
    };
    const thread = std.Thread.spawn(.{}, Warm.run, .{Warm{ .server = ctx.*, .name = owned }}) catch |e| {
        log.warn("pcb derived warm: not started for {s} ({s})", .{ name, @errorName(e) });
        // allocator-ok: releasing the process-lifetime copy made just above.
        std.heap.page_allocator.free(owned);
        ctx.state.derived_warms.end();
        return;
    };
    thread.detach();
}

// spec: Web Server - Background PCB deferred-payload warms are capped, so a burst of saves cannot put the heaviest read-only render on every core
test "deferred warm slots are capped and released" {
    var limit = WarmLimit{};
    try std.testing.expect(limit.begin());
    try std.testing.expect(limit.begin());
    try std.testing.expect(!limit.begin());
    limit.end();
    try std.testing.expect(limit.begin());
    limit.end();
    limit.end();
    try std.testing.expectEqual(@as(usize, 0), limit.running.load(.monotonic));
}
