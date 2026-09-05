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
//! and costs far more than the page it follows (board-a: ~15 s against
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
const warm_sched = @import("warm_sched.zig");

/// Ceiling on the page renders this sweep runs at once, before the host's core
/// count halves it (`warm_sched.workerCount`). Bounded for two reasons that
/// pull the same way: every render owns an evaluator, an arena and a
/// board-sized raster, so an unbounded fan-out would peak the process at one
/// board per core; and the request path this exists to serve wants those cores
/// more than the sweep does. Four rather than three because this corpus's
/// deferred pass is dominated by a handful of expensive boards and the last one
/// to start sets the wall.
const pcb_warm_worker_cap: usize = 4;

const WarmPhase = enum { pcb_pages, pcb_derived, progress_ladders };
/// This array drives `run`, rather than merely documenting it, so the test at
/// the foot of the file pins the user-visible startup priority.
const warm_phase_order = [_]WarmPhase{ .pcb_pages, .pcb_derived, .progress_ladders };

/// One board the sweep will try, paired with the size of the `.layouts.json`
/// the render has to parse and restore. That sidecar is the biggest input a
/// board render reads (multi-megabyte on a routed board), so it is the sweep's
/// cost estimate — see `boardOrder`.
const BoardEntry = struct {
    name: []const u8,
    sidecar_bytes: u64,
};

const BoardWarmWork = struct {
    ctx: *Server,
    boards: []const BoardEntry,
    scope: pcb_derived.WarmScope,
    warmed: std.atomic.Value(usize) = .init(0),

    fn one(self: *BoardWarmWork, i: usize) void {
        // Between boards, never inside one: a reader who arrived mid-sweep gets
        // a brief head start on the cores, and abandoning a half-finished
        // render would waste exactly the work the reader is about to want.
        warm_sched.yieldToInteractive();
        if (warmPcbPage(self.ctx, self.boards[i].name, self.scope)) _ = self.warmed.fetchAdd(1, .monotonic);
    }
};

/// The buildable designs that actually have a saved layout, heaviest first.
///
/// Both halves matter. Filtering here rather than inside the render is what
/// lets the ORDER mean something: a corpus of twenty designs with eight boards
/// would otherwise hand most workers an immediate no-op and leave the real work
/// to whoever drew it. And with a bounded worker set the wall is set by the LAST
/// heavy board to start, so the heaviest go out first — a board whose sidecar is
/// megabytes of restored copper must not be picked up by the final free worker.
///
/// `scratch` owns the returned slice and the names in it, which is why it must
/// outlive the sweep.
fn boardOrder(
    project_dir: []const u8,
    scratch: std.mem.Allocator,
    summaries: []const mcp_tools.DesignSummary,
) []const BoardEntry {
    var out: std.ArrayList(BoardEntry) = .empty;
    for (summaries) |s| {
        if (!s.build_ok) continue;
        // A design with no saved-layout sidecar is deliberately left cold (see
        // the file header), and this is where that is decided.
        const sidecar = paths.designSiblingPath(scratch, project_dir, s.name, ".layouts.json") catch continue;
        const st = infra_fs.cwd().statFile(sidecar) catch continue;
        out.append(scratch, .{ .name = s.name, .sidecar_bytes = st.size }) catch break;
    }
    std.mem.sort(BoardEntry, out.items, {}, struct {
        fn lessThan(_: void, a: BoardEntry, b: BoardEntry) bool {
            return a.sidecar_bytes > b.sidecar_bytes;
        }
    }.lessThan);
    return out.items;
}

/// Run one pass of `warmPcbPage` over every laid-out design on a small worker
/// set, and return how many it retained. Both board phases share this: the
/// pass is what `pcb_derived.warmPage` makes of the entries it finds free,
/// so the second one lands on the deferred halves the first one left.
fn warmBoards(ctx: *Server, boards: []const BoardEntry, scope: pcb_derived.WarmScope) usize {
    var work = BoardWarmWork{ .ctx = ctx, .boards = boards, .scope = scope };
    warm_sched.runIndexed(
        BoardWarmWork,
        &work,
        boards.len,
        BoardWarmWork.one,
        warm_sched.workerCount(pcb_warm_worker_cap),
    );
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
    // The FIRST thing a restart owes anyone: `GET /` and `GET /api/designs`
    // both block on this gather, and until it lands they evaluate the whole
    // corpus themselves. It is reported separately from the phases below
    // because it is the only part of the warm-up a request can be waiting on
    // rather than merely benefiting from — and because a request that arrives
    // during it now JOINS this scan per design instead of starting its own
    // (see `mcp_tools.ensureSummaryCached`).
    log.progress("warmup: {d} design summary(s) ready in {d} ms", .{
        home.summaries.len,
        @divTrunc(clock.nanoTimestamp() - started, std.time.ns_per_ms),
    });

    // Which boards, in which order, decided ONCE and shared by both passes: the
    // second pass must revisit exactly the boards the first one rendered, and
    // re-deciding per pass would let a sidecar written between them change the
    // set under it.
    const board_order = boardOrder(ctx.project_dir, home_arena.allocator(), home.summaries);

    var boards: usize = 0;
    var warmed: usize = 0;
    for (warm_phase_order) |phase| switch (phase) {
        .pcb_pages => {
            // Boards FIRST. The live warm-up took ~4 minutes in aggregate when
            // this ordering was fixed. Putting lazy ladders first defeated PCB
            // pre-rendering exactly when it mattered: after every deploy, no
            // editor entry even began warming until the unrelated first phase
            // completed. A small worker set also starts common adjacent boards
            // (board-a / board-a-base included) together.
            const boards_started = clock.nanoTimestamp();
            boards = warmBoards(ctx, board_order, .page);
            const board_ms = @divTrunc(clock.nanoTimestamp() - boards_started, std.time.ns_per_ms);
            log.progress("warmup: {d} pcb page(s) ready in {d} ms", .{ boards, board_ms });
        },
        .pcb_derived => {
            // A SECOND pass over the same boards, after every page is retained.
            // The editor fetches `?derived=1` right after first paint and that
            // response — pours, the reporting DRC, mask relief, trace EM, power
            // integrity — is by far the most expensive thing this server
            // computes (board-a: ~15 s against ~0.3 s for its page). Warming
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
            const derived = warmBoards(ctx, board_order, .derived);
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

/// Pre-render one design's plain PCB layout page into the page cache. The
/// sidecar check is re-made here rather than trusted from `boardOrder`, so a
/// layout deleted between the two passes is a skip rather than a fresh solve
/// this path would then persist — see the file header for why an unlaid-out
/// board is deliberately left cold.
fn warmPcbPage(ctx: *Server, name: []const u8, scope: pcb_derived.WarmScope) bool {
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const sidecar = paths.designSiblingPath(scratch, ctx.project_dir, name, ".layouts.json") catch return false;
    _ = infra_fs.cwd().statFile(sidecar) catch return false;
    return pcb_derived.warmPage(ctx, scratch, name, scope);
}

/// The names `boardOrder` selected, in the order it dispatches them.
fn orderedNames(scratch: std.mem.Allocator, entries: []const BoardEntry) ![]const []const u8 {
    const out = try scratch.alloc([]const u8, entries.len);
    for (entries, out) |e, *name| name.* = e.name;
    return out;
}

// spec: Web Server - The startup board sweep skips designs with no saved layout and dispatches the heaviest remaining board first, so the last one to start does not set the wall
test "the board sweep drops unlaid-out designs and orders the rest heaviest first" {
    const testing = std.testing;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(std.testing.io, "src", .default_dir);
    const empty_layout = "{\"default\":\"hand\",\"layouts\":[{\"name\":\"hand\",\"kind\":\"manual\",\"ts\":2,\"parts\":[]}]}";
    // Three designs: one with no sidecar at all, one with a small sidecar, one
    // with a large one. Only the sidecar SIZE orders them — `small` is written
    // last, so mtime order would put it first.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/warmord-none.sexp", .data = "(design-block \"N\")" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/warmord-big.sexp", .data = "(design-block \"B\")" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/warmord-small.sexp", .data = "(design-block \"S\")" });
    var padded: std.ArrayList(u8) = .empty;
    defer padded.deinit(testing.allocator);
    try padded.appendSlice(testing.allocator, empty_layout);
    try padded.appendNTimes(testing.allocator, ' ', 4096);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/warmord-big.layouts.json", .data = padded.items });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src/warmord-small.layouts.json", .data = empty_layout });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", testing.allocator);
    defer testing.allocator.free(root);

    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const scratch = arena_state.allocator();

    const summaries = try mcp_tools.listDesignSummaries(scratch, root);
    const names = try orderedNames(scratch, boardOrder(root, scratch, summaries));
    // The design with no saved layout never reaches a render, and the heavier
    // sidecar goes to the first free worker.
    try testing.expectEqual(@as(usize, 2), names.len);
    try testing.expectEqualStrings("warmord-big", names[0]);
    try testing.expectEqualStrings("warmord-small", names[1]);
}

// spec: Web Server - Startup warms PCB editor pages before the slower progress ladders, so an unrelated lazy diagnostic cannot leave every editor cache cold after a deploy
// spec: Web Server - Startup warms every PCB page before any deferred payload, so a deploy has the pages a reader blocks on cached in about a second rather than behind twelve boards of analyses
test "startup prioritizes PCB pages over deferred payloads over progress ladders" {
    try std.testing.expectEqual(WarmPhase.pcb_pages, warm_phase_order[0]);
    try std.testing.expectEqual(WarmPhase.pcb_derived, warm_phase_order[1]);
    try std.testing.expectEqual(WarmPhase.progress_ladders, warm_phase_order[2]);
}
