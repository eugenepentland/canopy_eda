//! Background live-route jobs — the streaming twin of the blocking
//! `POST /api/pcb-route/:name`. A start solves the route body's placement
//! synchronously in the request (errors are immediate 4xx/5xx), then spawns a
//! detached routing thread whose `route_policy.ProgressSink` serializes every
//! captured timeline event (route_review's replay element shape) into a
//! mutex-guarded, generation-versioned per-design job store. The browser polls
//! events past a cursor; a cancel trips the router's cooperative flag and the
//! job still finishes to a valid partial result. On completion the poll's
//! `final` payload carries the EXACT blocking-route response contract (both
//! surfaces serialize through pcb_layout_page's shared prepare/route/write
//! pipeline, so they cannot drift) and the run is persisted as the design's
//! cached replay. One job per design: a start while one is running is refused
//! with the in-flight generation; a fresh start replaces a finished job and
//! frees its memory.

const std = @import("std");
const httpz = @import("httpz");
const clock = @import("../infra/clock.zig");
const infra_fs = @import("../infra/fs.zig");
const serve_root = @import("../serve.zig");
const Server = serve_root.Server;
const optimizer = @import("../placement/optimizer.zig");
const router = @import("../placement/router.zig");
const route_plan = @import("route_plan.zig");
const route_review = @import("route_review.zig");
const pcb_layout_page = @import("pcb_layout_page.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const modules_mod = @import("modules.zig");

const HandlerError = route_review.HandlerError;

/// The durable allocator every job structure uses. Request arenas die with the
/// response; job state must outlive both the request that started it and the
/// thread that streams into it.
const durable = std.heap.page_allocator;

/// Most events one poll response carries — a client that receives a full batch
/// re-polls immediately, so a long timeline drains in a few round trips
/// without ever assembling one giant response.
const max_poll_events: usize = 200;

// Shared literals (job error messages are static so the store never owns them).
const err_no_job = "no live route job for this design";
const err_no_name = "missing design name";
const err_stream_alloc = "event streaming ran out of memory";
const err_route_failed = "the autorouter failed";
const err_payload_alloc = "assembling the final payload ran out of memory";
const err_thread = "could not start the routing thread";

// ── job store ─────────────────────────────────────────────────────────────

/// One design's live-route job. Every slice is `durable`-owned; `cancel` is a
/// heap flag shared with the router thread (freed only when a finished job is
/// replaced, so the thread's lock-free atomic reads stay valid for its life).
const Job = struct {
    /// Monotonic per-design run counter — stale threads' writes are dropped.
    gen: u32 = 0,
    /// 1-based capture attempt; a second `.initial` event (a finer-grid
    /// restart) bumps it and restarts the event stream from zero.
    attempt: u32 = 1,
    running: bool = false,
    done: bool = false,
    /// Static description of what went wrong, or null while healthy.
    err: ?[]const u8 = null,
    /// True when the router finished early because the cancel flag tripped.
    cancelled: bool = false,
    started_ms: i64 = 0,
    finished_ms: ?i64 = null,
    /// Nets connected so far (the last streamed event's running count).
    routed: usize = 0,
    /// Total nets tried — unknown (null) until the run finishes, because the
    /// router backfills each event's total only at finish.
    total: ?usize = null,
    /// Pre-serialized timeline events in the replay element shape, in stream
    /// order for the CURRENT attempt.
    events: std.ArrayList([]const u8) = .empty,
    /// The finished run's blocking-route-contract payload, once done.
    final: ?[]const u8 = null,
    /// Cooperative cancel flag the cancel endpoint trips.
    cancel: ?*std.atomic.Value(bool) = null,
};

/// The per-design live-route job table, held in `ServerState` so it lives for
/// the server's lifetime without a module-level global (route_session_api's
/// convention). All access is serialized by `mutex`; jobs are generation-
/// versioned so a superseded thread's late writes are no-ops.
pub const Store = struct {
    mutex: infra_fs.Mutex = .{},
    map: std.StringHashMapUnmanaged(Job) = .empty,

    /// Outcome of `begin`: an already-running job's generation, or the fresh
    /// job's generation plus its heap cancel flag for the new thread.
    const Begin = union(enum) { busy: u32, started: Started };

    /// A freshly begun job: its generation and the cancel flag the spawned
    /// thread polls (owned by the store, shared with the cancel endpoint).
    const Started = struct { gen: u32, cancel: *std.atomic.Value(bool) };

    /// Start a live-route job for `name`. Refused (`.busy` with the in-flight
    /// generation) while one is running; otherwise any finished job's memory is
    /// freed, the generation bumps, and the fresh job records its start time.
    /// Null only on allocation failure.
    fn begin(self: *Store, name: []const u8) ?Begin {
        self.mutex.lock();
        defer self.mutex.unlock();
        const gop = self.map.getOrPut(durable, name) catch return null;
        if (!gop.found_existing) {
            // Borrow the caller's name until the durable dupe lands so a failed
            // dupe can still remove the entry through a valid key.
            gop.key_ptr.* = name;
            gop.value_ptr.* = .{};
            gop.key_ptr.* = durable.dupe(u8, name) catch {
                _ = self.map.remove(name);
                return null;
            };
        }
        if (gop.value_ptr.running) return .{ .busy = gop.value_ptr.gen };
        const flag = durable.create(std.atomic.Value(bool)) catch return null;
        flag.* = std.atomic.Value(bool).init(false);
        resetJob(gop.value_ptr);
        gop.value_ptr.gen +%= 1;
        gop.value_ptr.cancel = flag;
        gop.value_ptr.running = true;
        gop.value_ptr.started_ms = clock.milliTimestamp();
        return .{ .started = .{ .gen = gop.value_ptr.gen, .cancel = flag } };
    }

    /// Append one pre-serialized event for generation `gen`, taking ownership
    /// of `json` (freed when the job is stale). `reset` is the finer-grid
    /// restart: the attempt bumps and the current attempt's events are
    /// discarded so cursors restart from zero. `routed` is the event's running
    /// connected-net count.
    fn appendEvent(self: *Store, name: []const u8, gen: u32, json: []const u8, reset: bool, routed: usize) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const job = self.jobFor(name, gen) orelse {
            durable.free(json);
            return;
        };
        if (reset) {
            for (job.events.items) |e| durable.free(e);
            job.events.clearRetainingCapacity();
            job.attempt +%= 1;
        }
        job.events.append(durable, json) catch {
            durable.free(json);
            job.err = err_stream_alloc;
            return;
        };
        job.routed = routed;
    }

    /// Record a non-fatal failure (e.g. the sink ran out of memory) on the
    /// running generation; the poll surfaces it while the route continues.
    fn fail(self: *Store, name: []const u8, gen: u32, message: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const job = self.jobFor(name, gen) orelse return;
        job.err = message;
    }

    /// How a run ended — everything `finishJob` publishes. `final` transfers
    /// ownership (durable); `err` keeps any earlier sink error when null.
    const Finish = struct {
        final: ?[]const u8 = null,
        err: ?[]const u8 = null,
        routed: ?usize = null,
        total: ?usize = null,
        cancelled: bool = false,
    };

    /// Mark generation `gen` finished with its final payload and counts. A
    /// stale generation's finish is dropped (and its payload freed).
    fn finishJob(self: *Store, name: []const u8, gen: u32, fin: Finish) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const job = self.jobFor(name, gen) orelse {
            if (fin.final) |f| durable.free(f);
            return;
        };
        job.running = false;
        job.done = true;
        if (job.final) |old| durable.free(old);
        job.final = fin.final;
        if (fin.err) |e| job.err = e;
        if (fin.routed) |r| job.routed = r;
        job.total = fin.total;
        job.cancelled = fin.cancelled;
        job.finished_ms = clock.milliTimestamp();
    }

    /// Trip the job's cooperative cancel flag. False when the design has no
    /// job at all; tripping an already-finished job is a harmless no-op.
    fn cancelJob(self: *Store, name: []const u8) bool {
        self.mutex.lock();
        defer self.mutex.unlock();
        const job = self.map.getPtr(name) orelse return false;
        if (job.cancel) |flag| flag.store(true, .seq_cst);
        return true;
    }

    /// A consistent poll view duped into the request arena, so the handler can
    /// serialize after the lock is released.
    const Poll = struct {
        gen: u32,
        attempt: u32,
        running: bool,
        done: bool,
        err: ?[]const u8,
        cancelled: bool,
        routed: usize,
        total: ?usize,
        elapsed_ms: i64,
        /// The cursor for the next poll (index past the last returned event).
        next: usize,
        events: []const []const u8,
        final: ?[]const u8,
    };

    /// Snapshot the job for `name`: events past the `since` cursor (capped at
    /// `max_poll_events`), restarted from zero when the stored attempt differs
    /// from the caller's, plus the envelope fields (and the final payload once
    /// done). Null when no job exists for `name`.
    fn snapshot(self: *Store, alloc: std.mem.Allocator, name: []const u8, since: usize, attempt: u32) std.mem.Allocator.Error!?Poll {
        self.mutex.lock();
        defer self.mutex.unlock();
        const job = self.map.getPtr(name) orelse return null;
        const len = job.events.items.len;
        const from = if (attempt != job.attempt) 0 else @min(since, len);
        const end = @min(len, from + max_poll_events);
        const events = try alloc.alloc([]const u8, end - from);
        for (job.events.items[from..end], 0..) |e, i| events[i] = try alloc.dupe(u8, e);
        const final: ?[]const u8 = if (job.done and job.final != null) try alloc.dupe(u8, job.final.?) else null;
        const end_ms = job.finished_ms orelse clock.milliTimestamp();
        return .{
            .gen = job.gen,
            .attempt = job.attempt,
            .running = job.running,
            .done = job.done,
            .err = job.err,
            .cancelled = job.cancelled,
            .routed = job.routed,
            .total = job.total,
            .elapsed_ms = end_ms - job.started_ms,
            .next = end,
            .events = events,
            .final = final,
        };
    }

    /// The job for `name` at exactly generation `gen` while it is running —
    /// the staleness guard every thread-side mutation shares. Caller holds
    /// `mutex`.
    fn jobFor(self: *Store, name: []const u8, gen: u32) ?*Job {
        const job = self.map.getPtr(name) orelse return null;
        if (job.gen != gen or !job.running) return null;
        return job;
    }
};

/// Free a job's owned memory (events, final payload, cancel flag) and reset
/// every field except the generation counter, which only ever climbs so stale
/// pollers notice a replacement.
fn resetJob(job: *Job) void {
    for (job.events.items) |e| durable.free(e);
    job.events.deinit(durable);
    if (job.final) |f| durable.free(f);
    if (job.cancel) |c| durable.destroy(c);
    const gen = job.gen;
    job.* = .{};
    job.gen = gen;
}

// ── progress sink ─────────────────────────────────────────────────────────

/// What the router thread's progress sink carries: the job identity, the
/// placement (for net names), and the attempt-local stream cursor. Lives on
/// the routing thread's stack for the whole run — only that one thread ever
/// appends this job's events, so `seq`/`saw_initial` need no lock.
const SinkCtx = struct {
    store: *Store,
    name: []const u8,
    gen: u32,
    placement: *const optimizer.Placement,
    seq: usize = 0,
    saw_initial: bool = false,
};

/// `route_policy.ProgressSink` callback: restore the type-erased event,
/// serialize it in the replay element shape, and append it under the store
/// mutex. A SECOND `.initial` means the router restarted on a finer grid —
/// the attempt bumps and the stream restarts from zero. The sink cannot
/// error, so an allocation failure sets the job's err flag instead.
fn emitLiveEvent(ctx_ptr: ?*anyopaque, ev_ptr: *const anyopaque) void {
    const ctx: *SinkCtx = @ptrCast(@alignCast(ctx_ptr orelse return));
    const ev: *const router.RouteEvent = @ptrCast(@alignCast(ev_ptr));
    var reset = false;
    if (ev.kind == .initial) {
        if (ctx.saw_initial) {
            reset = true;
            ctx.seq = 0;
        }
        ctx.saw_initial = true;
    }
    const json = serializeEvent(ctx.placement.*, ev.*, ctx.seq) orelse {
        ctx.store.fail(ctx.name, ctx.gen, err_stream_alloc);
        return;
    };
    ctx.store.appendEvent(ctx.name, ctx.gen, json, reset, ev.state.routed);
    ctx.seq += 1;
}

/// One timeline event as a durable JSON string in route_review's replay
/// element shape (`writeTimelineEvent`, so a live stream and a saved replay
/// are byte-identical). Null when allocation fails.
fn serializeEvent(placement: optimizer.Placement, ev: router.RouteEvent, seq: usize) ?[]const u8 {
    var aw: std.Io.Writer.Allocating = .init(durable);
    defer aw.deinit();
    route_review.writeTimelineEvent(&aw.writer, placement, ev, seq) catch return null;
    return durable.dupe(u8, aw.written()) catch null;
}

// ── worker ────────────────────────────────────────────────────────────────

/// Everything the worker body needs, bundled so tests can run the job
/// synchronously without a thread or a solve arena of their own.
const LiveRun = struct {
    store: *Store,
    name: []const u8,
    project_dir: []const u8,
    gen: u32,
    prep: *const pcb_layout_page.RoutePrep,
    cancel: *std.atomic.Value(bool),
};

/// The worker body: route the prepared placement through the shared pipeline
/// with the streaming sink + cancel flag attached, assemble the final
/// blocking-contract payload, mark the job done, and best-effort persist the
/// run as the design's cached replay. Factored from the thread entry so tests
/// drive it inline.
fn runLiveJob(alloc: std.mem.Allocator, run: LiveRun) void {
    var sctx = SinkCtx{ .store = run.store, .name = run.name, .gen = run.gen, .placement = &run.prep.placement };
    const live = route_plan.LiveRoute{
        .sink = .{ .ctx = &sctx, .emit = emitLiveEvent },
        .cancel = run.cancel,
        .timeline = .on,
    };
    const outcome = pcb_layout_page.routePrepared(alloc, run.project_dir, run.name, run.prep.*, live) catch {
        run.store.finishJob(run.name, run.gen, .{ .err = err_route_failed });
        return;
    };
    const routed = outcome.run.routed;
    const final = buildFinalPayload(alloc, run.prep.*, outcome);
    run.store.finishJob(run.name, run.gen, .{
        .final = final,
        .err = if (final == null) err_payload_alloc else null,
        .routed = routed.routed,
        .total = routed.total,
        .cancelled = routed.cancelled,
    });
    // A cancelled run is a partial board — never let it overwrite a complete
    // cached replay the design may already have.
    if (!routed.cancelled) persistReplay(alloc, run, outcome);
}

/// The `final` payload: the blocking route endpoint's exact response object
/// (`{` + writeRoutePayload + `}`), duped durable so it outlives the job
/// arena. Null on allocation failure.
fn buildFinalPayload(
    alloc: std.mem.Allocator,
    prep: pcb_layout_page.RoutePrep,
    outcome: pcb_layout_page.RouteOutcome,
) ?[]const u8 {
    const body = renderFinalPayload(alloc, prep, outcome) catch return null;
    return durable.dupe(u8, body) catch null;
}

/// Serialize the blocking-contract response object into `alloc`.
fn renderFinalPayload(
    alloc: std.mem.Allocator,
    prep: pcb_layout_page.RoutePrep,
    outcome: pcb_layout_page.RouteOutcome,
) HandlerError![]const u8 {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try aw.writer.writeAll("{");
    try pcb_layout_page.writeRoutePayload(&aw.writer, prep, outcome);
    try aw.writer.writeAll("}");
    return aw.written();
}

/// Best-effort: serialize the finished run in the design-replay wire shape and
/// save it as the design's cached replay (the same `out/` cache the /pcb-layout
/// Replay panel loads). Any failure is swallowed — the job result never
/// depends on the cache write.
fn persistReplay(alloc: std.mem.Allocator, run: LiveRun, outcome: pcb_layout_page.RouteOutcome) void {
    var aw: std.Io.Writer.Allocating = .init(alloc);
    route_review.writeDesignReviewJson(alloc, &aw.writer, run.name, run.prep.placement, .{
        .run = outcome.run,
        .violations = outcome.violations,
        .router_claimed = outcome.claimed_routed,
    }) catch return;
    route_review.saveCachedReplay(alloc, run.project_dir, run.name, aw.written());
}

// ── start solve + thread ──────────────────────────────────────────────────

/// A solved start request: the dedicated arena owning the evaluator, block,
/// placement, and name copy, plus the prepared pipeline inputs. Handed to the
/// detached thread on success; freed via `freeSolved` on every failure path.
const Solved = struct {
    arena: *std.heap.ArenaAllocator,
    eval: *Evaluator,
    module_res: ?modules_mod.ResolvedBlock,
    name: []const u8,
    project_dir: []const u8,
    prep: pcb_layout_page.RoutePrep,
};

/// Free a solved start. Order matters: the evaluators are released before the
/// arena that backs them.
fn freeSolved(s: *const Solved) void {
    s.eval.deinit();
    if (s.module_res) |mr| mr.eval.deinit();
    s.arena.deinit();
    durable.destroy(s.arena);
}

/// The start solve's error set: the shared pipeline's failures plus a body
/// that isn't JSON at all.
const StartError = pcb_layout_page.RoutePrepError || error{BadJson};

/// Solve a live start synchronously: a dedicated arena, the body parse, and
/// the shared route pipeline's prepare — everything the background thread will
/// route. `project_dir` is borrowed from the long-lived Server (it outlives
/// every thread); the body and name are duped into the arena because the
/// request's memory dies with the response.
fn solveStart(project_dir: []const u8, name: []const u8, sub: ?[]const u8, body: []const u8) StartError!Solved {
    const arena = try durable.create(std.heap.ArenaAllocator);
    arena.* = std.heap.ArenaAllocator.init(durable);
    errdefer {
        arena.deinit();
        durable.destroy(arena);
    }
    const sa = arena.allocator();
    const name_sa = try sa.dupe(u8, name);
    const sub_sa: ?[]const u8 = if (sub) |s| try sa.dupe(u8, s) else null;
    const body_sa = try sa.dupe(u8, body);
    const root = std.json.parseFromSliceLeaky(std.json.Value, sa, body_sa, .{}) catch return error.BadJson;
    const eval = try sa.create(Evaluator);
    eval.* = Evaluator.init(sa, project_dir);
    var module_res: ?modules_mod.ResolvedBlock = null;
    errdefer {
        eval.deinit();
        if (module_res) |mr| mr.eval.deinit();
    }
    const prep = try pcb_layout_page.prepareRouteFromJson(sa, .{
        .project_dir = project_dir,
        .name = name_sa,
        .sub = sub_sa,
        .root = root,
    }, eval, &module_res);
    return .{
        .arena = arena,
        .eval = eval,
        .module_res = module_res,
        .name = name_sa,
        .project_dir = project_dir,
        .prep = prep,
    };
}

/// Status + message for a failed start solve — one classifier so the two
/// facets can't drift (route_session's `createFail` convention).
fn startFailure(e: StartError) struct { status: u16, message: []const u8 } {
    return switch (e) {
        error.BadJson => .{ .status = 400, .message = "malformed route JSON body" },
        error.MissingParts => .{ .status = 400, .message = "route body needs a parts array" },
        error.BlockNotFound => .{ .status = 404, .message = "no design or module by that name" },
        error.SubNotFound => .{ .status = 404, .message = "no sub-block by that name" },
        error.PlacementFailed => .{ .status = 500, .message = "could not build the placement" },
        error.ScopeFailed => .{ .status = 500, .message = "could not resolve the route scope" },
        error.OutOfMemory => .{ .status = 500, .message = "out of memory" },
    };
}

/// Heap work item the detached route thread owns: the solved start plus the
/// job identity. Freed by the thread on exit.
const JobTask = struct {
    store: *Store,
    solved: Solved,
    gen: u32,
    cancel: *std.atomic.Value(bool),
};

/// Detached thread entry: run the worker body, then free the solve state.
fn routeThread(task: *JobTask) void {
    runLiveJob(task.solved.arena.allocator(), .{
        .store = task.store,
        .name = task.solved.name,
        .project_dir = task.solved.project_dir,
        .gen = task.gen,
        .prep = &task.solved.prep,
        .cancel = task.cancel,
    });
    freeSolved(&task.solved);
    durable.destroy(task);
}

// ── HTTP handlers ─────────────────────────────────────────────────────────

/// POST /api/route-live/:name/start — solve the blocking route body's
/// placement synchronously (errors are immediate 4xx/5xx, and nothing is
/// spawned), then start the detached routing thread whose progress sink
/// streams every captured timeline event into the job store. Answers
/// `{"ok":true,"gen":G,"nets":[…]}` — the net-name table the streamed tuple
/// net indices reference. A start while a job is running is refused with 409
/// and the in-flight generation.
pub fn routeLiveStartApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const arena = ctx.allocator;
    const name = req.param("name") orelse return route_review.jsonError(arena, res, 404, err_no_name);
    const body = req.body() orelse return route_review.jsonError(arena, res, 400, "missing route body");
    const solved = solveStart(ctx.project_dir, name, querySub(req), body) catch |e| {
        const fail = startFailure(e);
        return route_review.jsonError(arena, res, fail.status, fail.message);
    };
    const store = &ctx.state.route_live;
    const begun = store.begin(name) orelse {
        freeSolved(&solved);
        return route_review.jsonError(arena, res, 500, "could not register the live route job");
    };
    switch (begun) {
        .busy => |gen| {
            freeSolved(&solved);
            try respondBusy(arena, res, gen);
        },
        .started => |st| try launchJob(arena, res, store, solved, st),
    }
}

/// Serialize the start response (BEFORE the thread owns the solve), create the
/// heap task, and spawn the detached route thread. A spawn failure finishes
/// the job as errored so pollers aren't left waiting on a thread that never
/// ran.
fn launchJob(
    arena: std.mem.Allocator,
    res: *httpz.Response,
    store: *Store,
    solved: Solved,
    st: Store.Started,
) HandlerError!void {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try aw.writer.print("{{\"ok\":true,\"gen\":{d}", .{st.gen});
    try route_review.writeNets(&aw.writer, solved.prep.placement);
    try aw.writer.writeByte('}');
    const task = durable.create(JobTask) catch return abortLaunch(arena, res, store, solved, st.gen);
    task.* = .{ .store = store, .solved = solved, .gen = st.gen, .cancel = st.cancel };
    const t = std.Thread.spawn(.{}, routeThread, .{task}) catch {
        durable.destroy(task);
        return abortLaunch(arena, res, store, solved, st.gen);
    };
    t.detach();
    res.content_type = .JSON;
    res.body = aw.written();
}

/// Mark a job whose thread never started as failed, free the solve, and 500.
fn abortLaunch(
    arena: std.mem.Allocator,
    res: *httpz.Response,
    store: *Store,
    solved: Solved,
    gen: u32,
) HandlerError!void {
    store.finishJob(solved.name, gen, .{ .err = err_thread });
    freeSolved(&solved);
    return route_review.jsonError(arena, res, 500, err_thread);
}

/// 409 with the in-flight generation so the client can attach to it instead.
fn respondBusy(arena: std.mem.Allocator, res: *httpz.Response, gen: u32) HandlerError!void {
    var aw: std.Io.Writer.Allocating = .init(arena);
    try aw.writer.print("{{\"ok\":false,\"error\":\"a live route is already running for this design\",\"gen\":{d}}}", .{gen});
    res.status = 409;
    res.content_type = .JSON;
    res.body = aw.written();
}

/// GET /api/route-live/:name?since=K&attempt=A — the job envelope plus events
/// past the cursor (at most `max_poll_events`; a full batch means "poll again
/// immediately"). When the stored attempt differs from `A` (a finer-grid
/// restart happened) the events restart from zero under the new attempt. Once
/// done the envelope splices in the `final` blocking-route payload. 404 when
/// the design has no job.
pub fn routeLivePollApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const arena = ctx.allocator;
    const name = req.param("name") orelse return route_review.jsonError(arena, res, 404, err_no_name);
    const since = queryUnsigned(usize, req, "since");
    const attempt = queryUnsigned(u32, req, "attempt");
    const snap = (try ctx.state.route_live.snapshot(arena, name, since, attempt)) orelse
        return route_review.jsonError(arena, res, 404, err_no_job);
    var aw: std.Io.Writer.Allocating = .init(arena);
    try writePoll(&aw.writer, snap);
    res.content_type = .JSON;
    res.body = aw.written();
}

/// Serialize one poll envelope.
fn writePoll(w: *std.Io.Writer, p: Store.Poll) HandlerError!void {
    try w.print("{{\"gen\":{d},\"attempt\":{d},\"running\":{s},\"done\":{s},\"err\":", .{
        p.gen, p.attempt, boolStr(p.running), boolStr(p.done),
    });
    if (p.err) |e| try route_review.writeJsonString(w, e) else try w.writeAll("null");
    try w.print(",\"cancelled\":{s},\"routed\":{d},\"total\":", .{ boolStr(p.cancelled), p.routed });
    if (p.total) |t| try w.print("{d}", .{t}) else try w.writeAll("null");
    try w.print(",\"elapsed_ms\":{d},\"next\":{d},\"events\":[", .{ p.elapsed_ms, p.next });
    for (p.events, 0..) |e, i| {
        if (i > 0) try w.writeByte(',');
        try w.writeAll(e);
    }
    try w.writeByte(']');
    if (p.final) |f| {
        try w.writeAll(",\"final\":");
        try w.writeAll(f);
    }
    try w.writeByte('}');
}

/// POST /api/route-live/:name/cancel — trip the cooperative cancel flag; the
/// router stops starting new work at the next net boundary and the job still
/// finishes to a valid partial result. 404 when the design has no live job.
pub fn routeLiveCancelApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const arena = ctx.allocator;
    const name = req.param("name") orelse return route_review.jsonError(arena, res, 404, err_no_name);
    if (!ctx.state.route_live.cancelJob(name)) return route_review.jsonError(arena, res, 404, err_no_job);
    res.content_type = .JSON;
    res.body = "{\"ok\":true}";
}

/// The `?sub=<slug>` query value (empty counts as absent) — mirrors the
/// blocking endpoint's sub-block targeting.
fn querySub(req: *httpz.Request) ?[]const u8 {
    const q = req.query() catch return null;
    const s = q.get("sub") orelse return null;
    return if (s.len == 0) null else s;
}

/// An unsigned integer query value; absent or malformed reads as zero.
fn queryUnsigned(comptime T: type, req: *httpz.Request, key: []const u8) T {
    const q = req.query() catch return 0;
    const s = q.get(key) orelse return 0;
    return std.fmt.parseInt(T, s, 10) catch 0;
}

/// JSON boolean literal.
fn boolStr(b: bool) []const u8 {
    return if (b) "true" else "false";
}

// ── tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;
const geometry = @import("../placement/geometry.zig");
const export_kicad = @import("../export_kicad.zig");
const env_mod = @import("../eval/env.zig");

const fixture_pins = [_]export_kicad.FlatPin{
    .{ .ref_des = "R1", .pin = "1" },
    .{ .ref_des = "R2", .pin = "1" },
};

/// A minimal routable two-pad placement (mirrors route_session_api's fixture):
/// one net between two 0.4 mm pads 3 mm apart on the legacy 2-layer rules.
fn buildFixture(a: std.mem.Allocator) std.mem.Allocator.Error!optimizer.Placement {
    const pad = try a.dupe(geometry.Pad, &.{.{ .number = "1", .x = 0, .y = 0, .w = 0.4, .h = 0.4 }});
    const parts = try a.dupe(optimizer.Part, &.{
        .{ .ref_des = "R1", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = pad, .fallback = false, .x = 0, .y = 0 },
        .{ .ref_des = "R2", .kind = .passive, .hw = 0.5, .hh = 0.5, .pads = pad, .fallback = false, .x = 3, .y = 0 },
    });
    const nets = try a.dupe(optimizer.FlatNet, &.{.{ .name = "SIG", .pins = &fixture_pins }});
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -0.5,
        .miny = -0.5,
        .maxx = 3.5,
        .maxy = 0.5,
        .generated = true,
    };
}

/// The pipeline reads only `pcb_plan` off the block; an empty block routes
/// plan-less, matching a design with no `(pcb-plan …)` form.
const fixture_block = env_mod.DesignBlock{
    .name = "fixture",
    .instances = &.{},
    .nets = &.{},
    .ports = &.{},
    .notes = &.{},
    .groups = &.{},
    .sub_blocks = &.{},
};

/// A whole-board `RoutePrep` over the two-pad fixture at default params — the
/// shape `prepareRouteFromJson` would build for a scope-less route body.
fn fixturePrep(a: std.mem.Allocator) std.mem.Allocator.Error!pcb_layout_page.RoutePrep {
    return .{
        .eff_block = &fixture_block,
        .placement = try buildFixture(a),
        .rp = .{},
        .scoped = .{},
        .user_zones = &.{},
    };
}

/// A project path that does not exist — jobs that don't care about DRC rule
/// sidecars or replay persistence route against it.
const no_project = "/nonexistent-route-live-project";

const sealed_s_pins = [_]export_kicad.FlatPin{
    .{ .ref_des = "U1", .pin = "1" },
    .{ .ref_des = "R9", .pin = "1" },
};

const sealed_w_pins = [_]export_kicad.FlatPin{
    .{ .ref_des = "WN", .pin = "1" }, .{ .ref_des = "WS", .pin = "1" },
    .{ .ref_des = "WE", .pin = "1" }, .{ .ref_des = "WW", .pin = "1" },
    .{ .ref_des = "WA", .pin = "1" }, .{ .ref_des = "WB", .pin = "1" },
    .{ .ref_des = "WC", .pin = "1" }, .{ .ref_des = "WD", .pin = "1" },
};

/// A 0.2 mm-body passive at (x,y) — the sealed-pad fixture's part shape.
fn sealedPart(ref: []const u8, x: f64, y: f64, pads: []const geometry.Pad) optimizer.Part {
    return .{ .ref_des = ref, .kind = .passive, .hw = 0.2, .hh = 0.2, .pads = pads, .fallback = false, .x = x, .y = y };
}

/// The sealed-pad placement from route_diagnose's escape-blocked test: U1's
/// SMD pad is ringed by through-hole wall pads (copper on BOTH layers), so
/// net "S" to the far R9 pad deterministically fails — the fixture whose
/// uncancelled run always yields a stuck diagnosis.
fn unroutablePlacement(a: std.mem.Allocator) std.mem.Allocator.Error!optimizer.Placement {
    const smd = try a.dupe(geometry.Pad, &.{.{ .number = "1", .x = 0, .y = 0, .w = 0.3, .h = 0.3 }});
    const thru = try a.dupe(geometry.Pad, &.{.{ .number = "1", .x = 0, .y = 0, .w = 0.6, .h = 0.6, .thru = true, .drill = 0.3 }});
    const parts = try a.dupe(optimizer.Part, &.{
        sealedPart("U1", 0, 0, smd),
        sealedPart("R9", 0, 3, smd),
        sealedPart("WN", 0, -0.55, thru),
        sealedPart("WS", 0, 0.55, thru),
        sealedPart("WE", 0.55, 0, thru),
        sealedPart("WW", -0.55, 0, thru),
        sealedPart("WA", 0.5, -0.5, thru),
        sealedPart("WB", -0.5, -0.5, thru),
        sealedPart("WC", 0.5, 0.5, thru),
        sealedPart("WD", -0.5, 0.5, thru),
    });
    const nets = try a.dupe(optimizer.FlatNet, &.{
        .{ .name = "S", .pins = &sealed_s_pins },
        .{ .name = "W", .pins = &sealed_w_pins },
    });
    return .{
        .parts = parts,
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = nets,
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = -1,
        .miny = -1,
        .maxx = 1,
        .maxy = 3.3,
        .board_rect = .{ .minx = -1, .miny = -1, .w = 2, .h = 4.3 },
        .generated = true,
        .rules = .{ .copper_layers = 2 },
    };
}

/// A whole-board `RoutePrep` over the sealed-pad placement — the fixture with
/// a guaranteed failed net.
fn unroutablePrep(a: std.mem.Allocator) std.mem.Allocator.Error!pcb_layout_page.RoutePrep {
    return .{
        .eff_block = &fixture_block,
        .placement = try unroutablePlacement(a),
        .rp = .{ .track_width = 0.2, .clearance = 0.2 },
        .scoped = .{},
        .user_zones = &.{},
    };
}

/// Free every job a test left in `store`.
fn clearStore(store: *Store) void {
    var it = store.map.iterator();
    while (it.next()) |e| {
        resetJob(e.value_ptr);
        durable.free(e.key_ptr.*);
    }
    store.map.deinit(durable);
}

/// Seed `n` fake `{"seq":i}` events onto `name`'s job at generation `gen`,
/// each carrying its index as the running routed count.
fn seedEvents(store: *Store, name: []const u8, gen: u32, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const json = try std.fmt.allocPrint(durable, "{{\"seq\":{d}}}", .{i});
        store.appendEvent(name, gen, json, false, i);
    }
}

// spec: serve/route-live - a started live job streams the router's timeline events and finishes with the blocking route contract as its final payload
test "live job streams timeline events and finishes with the route contract" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var store: Store = .{};
    defer clearStore(&store);
    const prep = try fixturePrep(arena);
    const st = (store.begin("fixture") orelse return error.TestUnexpectedResult).started;
    runLiveJob(arena, .{
        .store = &store,
        .name = "fixture",
        .project_dir = no_project,
        .gen = st.gen,
        .prep = &prep,
        .cancel = st.cancel,
    });
    const snap = (try store.snapshot(arena, "fixture", 0, 1)) orelse return error.TestUnexpectedResult;
    try testing.expect(snap.done and !snap.running);
    try testing.expect(snap.err == null);
    try testing.expect(snap.events.len >= 2); // at least .initial and .complete
    try testing.expect(std.mem.indexOf(u8, snap.events[0], "\"kind\":\"initial\"") != null);
    try testing.expectEqual(@as(usize, 1), snap.routed);
    try testing.expectEqual(@as(?usize, 1), snap.total);
    const final = snap.final orelse return error.TestUnexpectedResult;
    // The blocking /api/pcb-route response contract, field for field.
    try testing.expect(std.mem.indexOf(u8, final, "\"tracks\":[") != null);
    try testing.expect(std.mem.indexOf(u8, final, "\"stuck\":[") != null);
    try testing.expect(std.mem.indexOf(u8, final, "\"routed\":1,\"total\":1,\"return_path\":") != null);
    try testing.expect(std.mem.indexOf(u8, final, "\"selected\":0,\"scope_unknown\":[]") != null);
}

// spec: serve/route-live - each streamed event serializes exactly as a replay timeline array element
test "streamed events serialize exactly as replay timeline elements" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const placement = try buildFixture(arena);
    const run = try router.routeWithTimeline(arena, placement, .{}, .{});
    try testing.expect(run.timeline.len >= 2);
    // Element by element through the factored per-event writer…
    var one: std.Io.Writer.Allocating = .init(arena);
    try one.writer.writeByte('[');
    for (run.timeline, 0..) |ev, i| {
        if (i > 0) try one.writer.writeByte(',');
        try route_review.writeTimelineEvent(&one.writer, placement, ev, i);
    }
    try one.writer.writeByte(']');
    // …must be byte-identical to the replay array writer.
    var all: std.Io.Writer.Allocating = .init(arena);
    try route_review.writeTimelineArray(&all.writer, placement, run.timeline);
    try testing.expectEqualStrings(all.written(), one.written());
}

// spec: serve/route-live - polling with a cursor returns only events past it and caps one batch
test "poll cursor returns only events past it and caps one batch" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var store: Store = .{};
    defer clearStore(&store);
    const st = (store.begin("board") orelse return error.TestUnexpectedResult).started;
    try seedEvents(&store, "board", st.gen, max_poll_events + 5);
    const first = (try store.snapshot(arena, "board", 0, 1)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(max_poll_events, first.events.len);
    try testing.expectEqual(max_poll_events, first.next);
    try testing.expectEqualStrings("{\"seq\":0}", first.events[0]);
    const rest = (try store.snapshot(arena, "board", first.next, 1)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 5), rest.events.len);
    try testing.expectEqual(max_poll_events + 5, rest.next);
    try testing.expectEqualStrings("{\"seq\":200}", rest.events[0]);
    // routed-so-far follows the last streamed event's running count.
    try testing.expectEqual(max_poll_events + 4, rest.routed);
}

// spec: serve/route-live - a finer-grid restart bumps the attempt and restarts the event stream from zero
test "a finer-grid restart bumps the attempt and restarts the stream" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var store: Store = .{};
    defer clearStore(&store);
    const st = (store.begin("board") orelse return error.TestUnexpectedResult).started;
    try seedEvents(&store, "board", st.gen, 3);
    // The router restarted on a finer grid: the sink appends with reset.
    const restart = try durable.dupe(u8, "{\"seq\":0,\"kind\":\"initial\"}");
    store.appendEvent("board", st.gen, restart, true, 0);
    // A poller still on attempt 1's cursor gets the new attempt from zero.
    const snap = (try store.snapshot(arena, "board", 3, 1)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(u32, 2), snap.attempt);
    try testing.expectEqual(@as(usize, 1), snap.events.len);
    try testing.expectEqual(@as(usize, 1), snap.next);
    try testing.expectEqualStrings("{\"seq\":0,\"kind\":\"initial\"}", snap.events[0]);
    // On the current attempt the cursor windows normally.
    const caught_up = (try store.snapshot(arena, "board", 1, 2)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 0), caught_up.events.len);
}

// spec: serve/route-live - a second start while a job is running is refused with the in-flight generation
test "a second start while running is refused with the live generation" {
    var store: Store = .{};
    defer clearStore(&store);
    const first = store.begin("board") orelse return error.TestUnexpectedResult;
    try testing.expect(first == .started);
    try testing.expectEqual(@as(u32, 1), first.started.gen);
    // Running ⇒ refused, answering the in-flight generation.
    const second = store.begin("board") orelse return error.TestUnexpectedResult;
    try testing.expect(second == .busy);
    try testing.expectEqual(@as(u32, 1), second.busy);
    // Finished ⇒ a fresh start replaces the job under the next generation.
    store.finishJob("board", 1, .{});
    const third = store.begin("board") orelse return error.TestUnexpectedResult;
    try testing.expect(third == .started);
    try testing.expectEqual(@as(u32, 2), third.started.gen);
}

// spec: serve/route-live - a cancelled live job still finishes to a valid partial result
test "a cancelled job still finishes to a valid partial result" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var store: Store = .{};
    defer clearStore(&store);
    const prep = try fixturePrep(arena);
    const st = (store.begin("fixture") orelse return error.TestUnexpectedResult).started;
    // The cancel endpoint's effect, tripped before the router starts.
    try testing.expect(store.cancelJob("fixture"));
    runLiveJob(arena, .{
        .store = &store,
        .name = "fixture",
        .project_dir = no_project,
        .gen = st.gen,
        .prep = &prep,
        .cancel = st.cancel,
    });
    const snap = (try store.snapshot(arena, "fixture", 0, 1)) orelse return error.TestUnexpectedResult;
    try testing.expect(snap.done and !snap.running);
    try testing.expect(snap.cancelled);
    try testing.expectEqual(@as(usize, 0), snap.routed);
    // Still a valid partial payload in the blocking contract shape.
    const final = snap.final orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, final, "\"routed\":0") != null);
    try testing.expect(std.mem.indexOf(u8, final, "\"scope_unknown\":[]") != null);
}

// spec: serve/route-live - a cancelled live run skips stuck-net diagnostics so the stop lands promptly
test "a cancelled run skips stuck diagnostics while an uncancelled run keeps them" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var store: Store = .{};
    defer clearStore(&store);
    // Uncancelled control run: the sealed-pad fixture leaves net "S" failed,
    // so its final payload carries a stuck diagnosis — proving the skip below
    // is cancel-gated, not empty-by-luck.
    const open_prep = try unroutablePrep(arena);
    const open = (store.begin("open") orelse return error.TestUnexpectedResult).started;
    runLiveJob(arena, .{
        .store = &store,
        .name = "open",
        .project_dir = no_project,
        .gen = open.gen,
        .prep = &open_prep,
        .cancel = open.cancel,
    });
    const open_snap = (try store.snapshot(arena, "open", 0, 1)) orelse return error.TestUnexpectedResult;
    try testing.expect(open_snap.done and !open_snap.cancelled);
    const open_final = open_snap.final orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, open_final, "\"stuck\":[{\"net\":") != null);
    // The same fixture cancelled: still done to a valid partial result, but
    // the stuck-net diagnosis (minutes of remedy search on a real board) is
    // skipped so the stop lands promptly.
    const cut_prep = try unroutablePrep(arena);
    const cut = (store.begin("cut") orelse return error.TestUnexpectedResult).started;
    try testing.expect(store.cancelJob("cut"));
    runLiveJob(arena, .{
        .store = &store,
        .name = "cut",
        .project_dir = no_project,
        .gen = cut.gen,
        .prep = &cut_prep,
        .cancel = cut.cancel,
    });
    const cut_snap = (try store.snapshot(arena, "cut", 0, 1)) orelse return error.TestUnexpectedResult;
    try testing.expect(cut_snap.done and cut_snap.cancelled);
    const cut_final = cut_snap.final orelse return error.TestUnexpectedResult;
    try testing.expect(std.mem.indexOf(u8, cut_final, "\"stuck\":[]") != null);
}

// spec: serve/route-live - a completed live run persists as the design's cached replay
test "a completed run persists the design's cached replay" {
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const project_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", arena);
    var store: Store = .{};
    defer clearStore(&store);
    const prep = try fixturePrep(arena);
    const st = (store.begin("fixture") orelse return error.TestUnexpectedResult).started;
    runLiveJob(arena, .{
        .store = &store,
        .name = "fixture",
        .project_dir = project_dir,
        .gen = st.gen,
        .prep = &prep,
        .cancel = st.cancel,
    });
    // The finished run landed in the same out/ cache the Replay panel loads.
    const body = try tmp.dir.readFileAlloc(std.testing.io, "out/route-review/fixture.json", arena, .limited64(16 * 1024 * 1024));
    try testing.expect(std.mem.indexOf(u8, body, "\"ok\":true,\"mode\":\"design\"") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"timeline\":[") != null);
    try testing.expect(std.mem.indexOf(u8, body, "\"final\":{") != null);
}
