//! Fill the read-path caches once, at startup, off the request path.
//!
//! Every cache the home page depends on — design summaries, the module list,
//! parsed `.layouts.json` sidecars, the `src/` basename index, and the
//! six-stage progress ladder per card — is process-lifetime and in memory, so
//! a restart empties all of them. On this deployment a restart IS a deploy,
//! and deploys land several times an hour, so "cold" is the common state
//! rather than a rare one: measured on this project the first `GET /` after a
//! restart costs 2.74 s (every design evaluated) and the cards' ladders a
//! further 52 s of wall clock at the browser's three-way fetch concurrency,
//! against 0.011 s and ~0.005 s once warm.
//!
//! So the first visitor after a deploy should not be the one who pays. A
//! background thread runs the same gather the request handlers run, discards
//! the result, and leaves the caches populated. It deliberately re-COMPUTES
//! rather than reloading anything from disk: the process that restarted is
//! usually running new code, and a ladder persisted by the old binary could
//! disagree with what this one would produce.
//!
//! The PCB layout page gets the same treatment, and needs it most: it is the
//! costliest read-only page here — placement, DRC and a megabyte of HTML per
//! request — so a cold one is the slowest thing a deploy can hand a reader.
//! PCB pages run before the progress ladders: the live startup warm-up had
//! taken roughly four minutes in aggregate, and putting lazy diagnostics first
//! meant no editor page even began warming during its entire first phase. A
//! page is warmed only for designs that already have a saved-layout sidecar: a
//! design with no PCB work behind it is not where anyone's first click after a
//! deploy lands, and rendering one would run a fresh solve that the page path then
//! persists, writing layout files for boards nobody asked about.
//!
//! The editor's DEFERRED payload (`?derived=1` — pours, the reporting DRC,
//! mask relief, trace EM, power integrity) is warmed the same way, in a second
//! board pass. It is fetched automatically right after every editor page paints
//! and costs far more than the page it follows (barracuda: ~15 s against
//! ~0.3 s), so a cold one is the longest wait the editor has. It is a second
//! pass rather than part of the first because a reader BLOCKS on the page: one
//! render can produce both halves, but holding each page back until its own
//! analyses finished would put the last board's page twenty seconds out instead
//! of one.
//!
//! Everything here is best-effort. A failure warms less, never breaks the
//! server: the request path is unchanged and simply finds a cold cache.

const std = @import("std");
const Server = @import("../serve.zig").Server;
const serve_root = @import("../serve.zig");
const pages = @import("pages.zig");
const pcb_describe = @import("pcb_describe.zig");
const pcb_derived = @import("pcb_derived.zig");
const pcb_layout_page = @import("pcb_layout_page.zig");
const page_cache = @import("page_cache.zig");
const paths = @import("../paths.zig");
const infra_fs = @import("../infra/fs.zig");
const log = @import("../infra/log.zig");
const clock = @import("../infra/clock.zig");
const mcp_tools = @import("mcp_tools.zig");

/// Three page renders use half of the production host's physical cores, making
/// the editor cache ready promptly without letting startup work occupy the
/// whole machine when a real request arrives. The request path is already
/// concurrent, and every render below owns its evaluator + arena; the shared
/// page and gzip stores serialize only their short admission sections.
const pcb_warm_workers: usize = 3;

const WarmPhase = enum { pcb_pages, pcb_derived, progress_ladders };
/// This array drives `run`, rather than merely documenting it, so the test at
/// the foot of the file pins the user-visible startup priority.
const warm_phase_order = [_]WarmPhase{ .pcb_pages, .pcb_derived, .progress_ladders };

const BoardWarmWork = struct {
    ctx: *Server,
    summaries: []const mcp_tools.DesignSummary,
    scope: pcb_derived.WarmScope,
    next: std.atomic.Value(usize) = .init(0),
    warmed: std.atomic.Value(usize) = .init(0),

    fn run(self: *BoardWarmWork) void {
        while (true) {
            const i = self.next.fetchAdd(1, .monotonic);
            if (i >= self.summaries.len) return;
            const summary = self.summaries[i];
            if (!summary.build_ok) continue;
            if (warmPcbPage(self.ctx, summary.name, self.scope)) _ = self.warmed.fetchAdd(1, .monotonic);
        }
    }
};

/// Run one pass of `warmPcbPage` over every buildable design on a small worker
/// set, and return how many it retained. Both board phases share this: the
/// pass is what `pcb_derived.warmPage` makes of the entries it finds free,
/// so the second one lands on the deferred halves the first one left.
fn warmBoards(ctx: *Server, summaries: []const mcp_tools.DesignSummary, scope: pcb_derived.WarmScope) usize {
    var work = BoardWarmWork{ .ctx = ctx, .summaries = summaries, .scope = scope };
    var threads: [pcb_warm_workers - 1]std.Thread = undefined;
    var spawned: usize = 0;
    while (spawned < threads.len) : (spawned += 1) {
        threads[spawned] = std.Thread.spawn(.{}, BoardWarmWork.run, .{&work}) catch break;
    }
    // The warm-up thread is a worker too. If either spawn failed, it claims
    // more indices and preserves the serial best-effort fallback.
    work.run();
    for (threads[0..spawned]) |thread| thread.join();
    return work.warmed.load(.monotonic);
}

/// Start the warm-up on its own thread and return immediately. Called just
/// before `listen()`, so warming overlaps with serving rather than delaying
/// the port coming up — a request that arrives mid-warm is answered from
/// whatever is ready and computes the rest itself, which is correct either
/// way because every cache here is keyed on the file state it was built from.
pub fn spawn(ctx: *Server) void {
    const t = std.Thread.spawn(.{}, run, .{ctx}) catch |e| {
        log.warn("warmup: not started ({s}) — the first page load will be cold", .{@errorName(e)});
        return;
    };
    t.detach();
}

fn run(ctx: *Server) void {
    const started = clock.nanoTimestamp();

    // One arena for the home gather. Its result is discarded — the point is
    // the cross-request caches it fills along the way, which own their own
    // copies under the process allocator.
    // This thread owns its own scratch: there is no request arena to inherit,
    // and the arena is released before it returns.
    // allocator-ok: warm-up thread scratch, released at the end of this call.
    var home_arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer home_arena.deinit();
    const home = pages.gatherHome(home_arena.allocator(), ctx.project_dir);

    var boards: usize = 0;
    var warmed: usize = 0;
    for (warm_phase_order) |phase| switch (phase) {
        .pcb_pages => {
            // Boards FIRST. The live warm-up took ~4 minutes in aggregate when
            // this ordering was fixed. Putting lazy ladders first defeated PCB
            // pre-rendering exactly when it mattered: after every deploy, no
            // editor entry even began warming until the unrelated first phase
            // completed. A small worker set also starts common adjacent boards
            // (barracuda / barracuda-base included) together.
            const boards_started = clock.nanoTimestamp();
            boards = warmBoards(ctx, home.summaries, .page);
            const board_ms = @divTrunc(clock.nanoTimestamp() - boards_started, std.time.ns_per_ms);
            log.progress("warmup: {d} pcb page(s) ready in {d} ms", .{ boards, board_ms });
        },
        .pcb_derived => {
            // A SECOND pass over the same boards, after every page is retained.
            // The editor fetches `?derived=1` right after first paint and that
            // response — pours, the reporting DRC, mask relief, trace EM, power
            // integrity — is by far the most expensive thing this server
            // computes (barracuda: ~15 s against ~0.3 s for its page). Warming
            // it matters as much as warming the page.
            //
            // It is a separate phase rather than part of the pass above so a
            // deploy still has every editor PAGE cached in about a second. One
            // render can answer both halves (`pcb_derived.warmPage`), but
            // holding each page back until its own analyses finished would put
            // the last board's page twenty seconds out — and the page is what a
            // reader blocks on. The repeated solve this costs is ~0.3 s per
            // board against the ~6 s of analyses behind it.
            const derived_started = clock.nanoTimestamp();
            const derived = warmBoards(ctx, home.summaries, .derived);
            const derived_ms = @divTrunc(clock.nanoTimestamp() - derived_started, std.time.ns_per_ms);
            log.progress("warmup: {d} pcb deferred payload(s) ready in {d} ms", .{ derived, derived_ms });
        },
        .progress_ladders => {
            // A card with no ladder issues no request, so warming one would be
            // pure waste. Ladders follow pages because their chips remain lazy
            // placeholders until clicked; a cold editor blocks before painting.
            for (home.summaries) |s| {
                if (!s.build_ok) continue;
                if (warmLadder(ctx, s.name)) warmed += 1;
            }
        },
    };

    const ms = @divTrunc(clock.nanoTimestamp() - started, std.time.ns_per_ms);
    log.progress("warmup: {d} design(s), {d} ladder(s), {d} pcb page(s) in {d} ms", .{ home.summaries.len, warmed, boards, ms });
}

/// Compute one design's query-free ladder and retain it. Returns whether the
/// cache took it.
fn warmLadder(ctx: *Server, name: []const u8) bool {
    // Per-ladder scratch, released before the next design so a whole-project
    // warm-up peaks at one board rather than all of them.
    // allocator-ok: warm-up thread scratch, released at the end of this call.
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();

    // Read the live version BEFORE computing, exactly as the handler does, so
    // an edit that lands mid-computation is a miss next time instead of being
    // baked in.
    const live_version = serve_root.getLiveVersion(name);
    var deps: ?page_cache.FileSet = null;
    const body = pcb_describe.describeProgress(
        arena.allocator(),
        ctx.project_dir,
        name,
        pcb_layout_page.PngRequest{},
        &deps,
    ) catch {
        if (deps) |d| d.deinit();
        return false;
    };
    const files = deps orelse return false;
    if (serve_root.getLiveVersion(name) != live_version) {
        files.deinit();
        return false;
    }
    ctx.state.caches.progress_json.warm(name, body, files, live_version);
    return true;
}

/// Pre-render one design's plain PCB layout page into the page cache. Skipped
/// unless the design already has a saved-layout sidecar — see the file header
/// for why an unlaid-out board is deliberately left cold.
fn warmPcbPage(ctx: *Server, name: []const u8, scope: pcb_derived.WarmScope) bool {
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const sidecar = paths.designSiblingPath(scratch, ctx.project_dir, name, ".layouts.json") catch return false;
    _ = infra_fs.cwd().statFile(sidecar) catch return false;
    return pcb_derived.warmPage(ctx, scratch, name, scope);
}

// spec: Web Server - Startup warms PCB editor pages before the slower progress ladders, so an unrelated lazy diagnostic cannot leave every editor cache cold after a deploy
// spec: Web Server - Startup warms every PCB page before any deferred payload, so a deploy has the pages a reader blocks on cached in about a second rather than behind twelve boards of analyses
test "startup prioritizes PCB pages over deferred payloads over progress ladders" {
    try std.testing.expectEqual(WarmPhase.pcb_pages, warm_phase_order[0]);
    try std.testing.expectEqual(WarmPhase.pcb_derived, warm_phase_order[1]);
    try std.testing.expectEqual(WarmPhase.progress_ladders, warm_phase_order[2]);
}
