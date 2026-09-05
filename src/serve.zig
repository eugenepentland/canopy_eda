//! HTTP server entry point: builds the httpz router, owns the `Server`
//! shared across every request, and holds the global live schematic state
//! (scene-graph JSON behind `live_mutex`). Handlers run on httpz's per-request
//! arena; anything cached past the response — like the live layout JSON — is
//! duped into `page_allocator` here, never left pointing at the arena. The
//! traffic goes the other way too: a handler reads the live slot through
//! `liveLayoutFor`, which copies into the request arena under the lock, because
//! httpz serializes `res.body` after the handler returns and a concurrent push
//! frees the buffer the handler saw.

const std = @import("std");
const httpz = @import("httpz");
const clock = @import("infra/clock.zig");
const infra_fs = @import("infra/fs.zig");
const log = @import("infra/log.zig");
const process_alloc = @import("infra/process_alloc.zig");
const deflate = @import("deflate.zig");
const gzip_cache = @import("serve/gzip_cache.zig");

/// Error set for the `serve` entry point — wraps all the failure modes that
/// can come out of `httpz.Server.init`, `router`, and `listen`. The set is
/// intentionally broad because the http server's own surface is wide; we
/// derive it from the actual `listen()` return type so it stays in sync.
pub const ServeError = std.mem.Allocator.Error ||
    @typeInfo(@typeInfo(@TypeOf(httpz.Server(*Server).listen)).@"fn".return_type.?).error_union.error_set ||
    @typeInfo(@typeInfo(@TypeOf(httpz.Server(*Server).router)).@"fn".return_type.?).error_union.error_set ||
    @typeInfo(@typeInfo(@TypeOf(httpz.Server(*Server).init)).@"fn".return_type.?).error_union.error_set ||
    error{ InvalidIPAddressFormat, ThreadQuotaExceeded };

/// Startup settings shared by the CLI and the long-running HTTP server.
pub const ServeOptions = struct {
    port: u16,
    project_dir: []const u8,
    auth_dir: ?[]const u8,
    skip_warmup: bool = false,
};

// Sub-modules
const paths = @import("paths.zig");
const pages = @import("serve/pages.zig");
const api = @import("serve/api.zig");
const edit = @import("serve/edit.zig");
const design_rules_edit = @import("serve/design_rules_edit.zig");
const edit_assist = @import("serve/edit_assist.zig");
const library = @import("serve/library.zig");
const library_3d = @import("serve/library_3d.zig");
const upload = @import("serve/upload.zig");
const upload_package = @import("serve/upload_package.zig");
const upload_datasheet = @import("serve/upload_datasheet.zig");
const pdf_viewer = @import("serve/pdf_viewer.zig");
const footprint_preview = @import("serve/footprint_preview.zig");
const footprint_editor = @import("serve/footprint_editor.zig");
const schematic_page = @import("serve/schematic_page.zig");
const schematic_png = @import("serve/schematic_png.zig");
const schematic_pdf = @import("serve/schematic_pdf.zig");
const thermal_api = @import("serve/thermal_api.zig");
const thermal_page = @import("serve/thermal_page.zig");
const kicad_sch_export = @import("serve/kicad_sch_export.zig");
const sync_kicad_sch = @import("serve/sync_kicad_sch.zig");
const assembly_debug = @import("serve/assembly_debug.zig");
const assembly_page_cache = @import("serve/assembly_page_cache.zig");
const pcb_layout_page = @import("serve/pcb_layout_page.zig");
const board_review = @import("serve/board_review.zig");
const pcb_subseeds = @import("serve/pcb_subseeds.zig");
const matlab_rf_export = @import("serve/matlab_rf_export.zig");
const pcb_page_cache = @import("serve/pcb_page_cache.zig");
const pcb_derived = @import("serve/pcb_derived.zig");
const drc_reconcile = @import("drc_reconcile.zig");
const drc_sweep = @import("drc_sweep.zig");
const thermal_cache = @import("serve/thermal_cache.zig");
const progress_cache = @import("serve/progress_cache.zig");
const describe_cache = @import("serve/describe_cache.zig");
const read_cache = @import("serve/read_cache.zig");
const png_cache = @import("serve/png_cache.zig");
const warmup = @import("serve/warmup.zig");
const pcb_fence = @import("serve/pcb_fence.zig");
const pcb_step_export = @import("serve/pcb_step_export.zig");
const design_archive_api = @import("serve/design_archive_api.zig");
const ground_vias = @import("serve/ground_vias.zig");
const pcb_layout_sync = @import("serve/pcb_layout_sync.zig");
const route_review = @import("serve/route_review.zig");
const route_session_api = @import("serve/route_session_api.zig");
const route_live = @import("serve/route_live.zig");
const route_analyze_api = @import("serve/route_analyze_api.zig");
const route_vision = @import("serve/route_vision.zig");
const pcb_describe = @import("serve/pcb_describe.zig");
const drc_rules = @import("serve/drc_rules.zig");
const layout_match = @import("serve/layout_match.zig");
const rough_best = @import("serve/rough_best.zig");
const modules_page = @import("serve/modules.zig");
const auth = @import("serve/auth.zig");
const ward_auth = @import("serve/ward_auth.zig");
const plugin_tokens = @import("serve/plugin_tokens.zig");
const static_assets = @import("serve/static_assets.zig");
const sync = @import("serve/sync.zig");
const notes = @import("serve/notes.zig");
const design_diff = @import("serve/design_diff.zig");
const datasheet_attach = @import("serve/datasheet_attach.zig");
const dossier_jobs = @import("serve/dossier_jobs.zig");
const rate_limiter = @import("serve/rate_limiter.zig");
const request_log = @import("serve/request_log.zig");
const system_review_api = @import("serve/system_review_api.zig");
const warm_sched = @import("serve/warm_sched.zig");

// ── Global live state ──────────────────────────────────────────────────

/// Every store in this section outlives the request that wrote it, so none of
/// them may hold a handler's arena; `infra/process_alloc.zig` owns that choice
/// for the whole tree.
const durable = process_alloc.durable;

var live_mutex: infra_fs.Mutex = .{};

/// The one live scene-graph slot: the JSON the last build/push produced, plus
/// the design it was produced FOR. The name travels with the JSON because there
/// is exactly one slot for the whole server — without it `/api/scene-graph/:name`
/// cannot tell whether the bytes it holds actually answer the request.
const LiveLayout = struct {
    /// Design name the JSON was rendered for (page_allocator-owned).
    name: []const u8,
    /// The rendered scene-graph JSON (page_allocator-owned).
    json: []const u8,
};

var live_layout: ?LiveLayout = null;

/// Replace the cached live schematic scene-graph JSON for design `name`. Both
/// slices may come from a request-scoped arena (e.g. CLI tool dispatch) so they
/// are duplicated into page_allocator memory that outlives the caller. The
/// previous pair, if any, is freed — which is why readers must copy the bytes
/// out under `live_mutex` (see `liveLayoutFor`) rather than borrow them.
pub fn setLiveLayoutJson(name: []const u8, data: ?[]const u8) void {
    const alloc = durable;
    const next: ?LiveLayout = if (data) |d| blk: {
        const json = alloc.dupe(u8, d) catch break :blk null;
        const owned_name = alloc.dupe(u8, name) catch {
            alloc.free(json);
            break :blk null;
        };
        break :blk .{ .name = owned_name, .json = json };
    } else null;
    live_mutex.lock();
    const old = live_layout;
    live_layout = next;
    live_mutex.unlock();
    if (old) |o| {
        alloc.free(o.json);
        alloc.free(o.name);
    }
}

/// The live scene-graph JSON when it belongs to design `name`, copied into
/// `alloc` (the caller's request arena) while the lock is held. Null when
/// nothing has been pushed yet, when the slot holds a DIFFERENT design, or when
/// the copy fails.
///
/// The copy is the whole point: `setLiveLayoutJson` frees the previous buffer,
/// so a handler that stashed the raw pointer and let httpz serialize it after
/// dispatch returned would race a concurrent push into a use-after-free.
pub fn liveLayoutFor(alloc: std.mem.Allocator, name: []const u8) ?[]const u8 {
    live_mutex.lock();
    defer live_mutex.unlock();
    const cur = live_layout orelse return null;
    if (!std.mem.eql(u8, cur.name, name)) return null;
    return alloc.dupe(u8, cur.json) catch null;
}

// Per-design live version. The browser polls /api/version/:name; each design
// has its own counter so mutating design A never invalidates B's viewer.
// Keys are duplicated into page_allocator memory so they outlive callers.
pub var live_version_mutex: infra_fs.Mutex = .{};
pub var live_versions: std.StringHashMapUnmanaged(u32) = .empty;

/// Increment and return the live version for a design.
pub fn bumpLiveVersion(name: []const u8) u32 {
    live_version_mutex.lock();
    defer live_version_mutex.unlock();
    const gop = live_versions.getOrPut(durable, name) catch return 0;
    if (!gop.found_existing) {
        gop.key_ptr.* = durable.dupe(u8, name) catch {
            _ = live_versions.remove(name);
            return 0;
        };
        gop.value_ptr.* = 0;
    }
    gop.value_ptr.* += 1;
    return gop.value_ptr.*;
}

/// Return the current live version for a design (0 if never bumped).
pub fn getLiveVersion(name: []const u8) u32 {
    live_version_mutex.lock();
    defer live_version_mutex.unlock();
    return live_versions.get(name) orelse 0;
}

// ── Live PCB-regen jobs ────────────────────────────────────────────────
//
// A "Regenerate" on the PCB-layout page runs the optimizer on a background
// thread instead of blocking the request, so the browser can poll the
// best-so-far arrangement and animate the board converging instead of staring
// at a spinner. State per design: the active job generation, a frame counter,
// run/done/err flags, and the latest best-so-far frame JSON (poses + score).
// Keys and frame bodies are page_allocator-owned so they outlive the request
// that spawned the solver and the worker that reads them back.

/// One design's live-regen job. `frame` is the latest best-so-far snapshot
/// (`{"pass":…,"score":…,"parts":[…]}`), owned by `page_allocator`.
pub const PcbJob = struct {
    gen: u32 = 0,
    seq: u32 = 0,
    running: bool = false,
    done: bool = false,
    err: bool = false,
    frame: ?[]const u8 = null,
};

/// Outcome a finished live-regen run reports — `failed` when the design
/// couldn't be evaluated or the solve errored (the browser then falls back to
/// the blocking `?regen=1` path).
pub const JobOutcome = enum { ok, failed };

// Private to this module — only the pcbJob* helpers below touch them, so they
// stay unexported (no need for a mutable global on the public surface).
var pcb_jobs_mutex: infra_fs.Mutex = .{};
var pcb_jobs: std.StringHashMapUnmanaged(PcbJob) = .empty;

/// Result of `pcbJobBegin`: the job's generation and whether a fresh solver
/// should be spawned (`fresh` is false when one is already running for `name`).
pub const PcbJobBegin = struct { gen: u32, fresh: bool };

/// Start (or restart) a live-regen job for `name`. If one is already running,
/// returns its generation with `fresh=false` (one solver per design at a time).
/// Otherwise bumps the generation, clears prior frames, and returns `fresh=true`
/// so the caller spawns the background solver tagged with the new generation.
pub fn pcbJobBegin(name: []const u8) PcbJobBegin {
    pcb_jobs_mutex.lock();
    defer pcb_jobs_mutex.unlock();
    const gop = pcb_jobs.getOrPut(durable, name) catch return .{ .gen = 0, .fresh = false };
    if (!gop.found_existing) {
        gop.key_ptr.* = durable.dupe(u8, name) catch {
            _ = pcb_jobs.remove(name);
            return .{ .gen = 0, .fresh = false };
        };
        gop.value_ptr.* = .{};
    }
    if (gop.value_ptr.running) return .{ .gen = gop.value_ptr.gen, .fresh = false };
    if (gop.value_ptr.frame) |old| {
        durable.free(old);
        gop.value_ptr.frame = null;
    }
    gop.value_ptr.gen +%= 1;
    gop.value_ptr.seq = 0;
    gop.value_ptr.running = true;
    gop.value_ptr.done = false;
    gop.value_ptr.err = false;
    return .{ .gen = gop.value_ptr.gen, .fresh = true };
}

/// Publish a new best-so-far frame for generation `gen`. Ignored (and the frame
/// freed) if the job was superseded or already finished — so a stale solver's
/// late write can't clobber a newer run.
pub fn pcbJobFrame(name: []const u8, gen: u32, json: []const u8) void {
    const dup = durable.dupe(u8, json) catch return;
    pcb_jobs_mutex.lock();
    defer pcb_jobs_mutex.unlock();
    const e = pcb_jobs.getPtr(name) orelse {
        durable.free(dup);
        return;
    };
    if (e.gen != gen or !e.running) {
        durable.free(dup);
        return;
    }
    if (e.frame) |old| durable.free(old);
    e.frame = dup;
    e.seq +%= 1;
}

/// Mark generation `gen` finished (the browser then reloads to pick up the
/// freshly-written auto-cache). No-op if a newer generation has taken over.
pub fn pcbJobFinish(name: []const u8, gen: u32, outcome: JobOutcome) void {
    pcb_jobs_mutex.lock();
    defer pcb_jobs_mutex.unlock();
    const e = pcb_jobs.getPtr(name) orelse return;
    if (e.gen != gen) return;
    e.running = false;
    e.done = true;
    e.err = outcome == .failed;
}

/// A consistent read of a job's state for the progress API. `frame` is duped
/// into `alloc` (the request arena) so the handler can serialize it after the
/// lock is released. Null when no job has ever run for `name`.
pub const PcbJobView = struct {
    gen: u32,
    seq: u32,
    running: bool,
    done: bool,
    err: bool,
    frame: ?[]const u8,
};

/// Snapshot the current job state for `name`, duping the latest frame into
/// `alloc`. Returns null if no job exists for `name`.
pub fn pcbJobSnapshot(alloc: std.mem.Allocator, name: []const u8) ?PcbJobView {
    pcb_jobs_mutex.lock();
    defer pcb_jobs_mutex.unlock();
    const e = pcb_jobs.get(name) orelse return null;
    const fr: ?[]const u8 = if (e.frame) |f| (alloc.dupe(u8, f) catch null) else null;
    return .{ .gen = e.gen, .seq = e.seq, .running = e.running, .done = e.done, .err = e.err, .frame = fr };
}

// ── Per-server instance state ──────────────────────────────────────────
//
// The serve layer's mutable stores and caches used to be file-scope `var`s —
// process-global singletons that made per-test and multi-instance servers
// impossible and hid store-init failures behind a shared slot. They now live
// on one `ServerState`, constructed in `serve()`, owned there, and reached by
// every route handler through `Server.state`. Persisted stores keep their
// exact on-disk formats and paths; only the in-memory containers moved.

/// The finished responses of the read-only design surfaces, each retained
/// against the read-set that produced it (see `serve/read_cache.zig`). They are
/// grouped because they share one implementation and one reason to exist: every
/// one of these handlers opens with a FRESH `Evaluator.evalFile`, which on this
/// project's largest board is about four seconds and is charged upstream of
/// every per-analysis cache underneath them — so nothing but retaining the
/// finished response can skip it.
pub const ReadCaches = struct {
    /// `GET /api/erc/:name` — the electrical-rule violations document.
    erc: read_cache.Store(read_cache.erc) = .{},
    /// `GET /api/thermal/:name` — the thermal facts JSON.
    thermal_facts: read_cache.Store(read_cache.thermal_facts) = .{},
    /// `GET /thermal/:name` — the rendered thermal review page.
    thermal_page: read_cache.Store(read_cache.thermal_page) = .{},
    /// `GET /api/schematic-pdf/:name` — the composed review document.
    schematic_pdf: read_cache.Store(read_cache.schematic_pdf) = .{},
    /// `GET /api/kicad-sch/:name` — the exported schematic archive.
    kicad_sch: read_cache.Store(read_cache.kicad_sch) = .{},
    /// `GET /api/pcb-png/:name` — the rendered board image. Grouped here by
    /// ROLE rather than by mechanism: it is the same read-only design surface
    /// whose whole cost is a fresh evaluation, but its body is an image with a
    /// framing allow-list of its own, so it keeps its own store type
    /// (`serve/png_cache.zig`).
    png_images: png_cache.Store = .{},

    /// Give every store the server's long-lived allocator, which is the switch
    /// that turns retention on.
    pub fn init(allocator: std.mem.Allocator) ReadCaches {
        return .{
            .erc = .{ .allocator = allocator },
            .thermal_facts = .{ .allocator = allocator },
            .thermal_page = .{ .allocator = allocator },
            .schematic_pdf = .{ .allocator = allocator },
            .kicad_sch = .{ .allocator = allocator },
            .png_images = .{ .allocator = allocator },
        };
    }

    /// Release every retained body. Safe on a default-constructed value.
    pub fn deinit(self: *ReadCaches) void {
        self.erc.deinit();
        self.thermal_facts.deinit();
        self.thermal_page.deinit();
        self.schematic_pdf.deinit();
        self.kicad_sch.deinit();
        self.png_images.deinit();
    }
};

/// Everything the server keeps only because recomputing it would be wasted
/// work. Every entry here is DERIVED — validated against the design files it
/// came from and safe to drop at any moment — which is what separates it from
/// the subsystems above it in `ServerState`, whose contents exist nowhere else.
pub const Caches = struct {
    /// Dependency-validated rendered assembly workspaces, bounded per server.
    assembly_pages: assembly_page_cache.Store = .{},
    /// Dependency-validated rendered PCB pages, bounded per server instance.
    pcb_pages: pcb_page_cache.Store = .{},
    /// Dependency-validated solved thermal fields, keyed by design name. The
    /// fields are ambient-free rises, so one cached solve answers the page, the
    /// facts JSON, the heat-zone PNG and every ambient a reader dials in.
    thermal_solves: thermal_cache.Store = .{},
    /// Dependency-validated PCB-completion ladder JSON (`/api/layout-progress`),
    /// the per-card body the home page requests once per design on every load.
    progress_json: progress_cache.Store = .{},
    /// Dependency-validated PCB spatial-facts JSON (`/api/pcb-describe`), the
    /// endpoint agent loops and review tooling re-request most — and the one
    /// that used to pay its full 6.5 s solve + reporting DRC every single call.
    describe_json: describe_cache.Store = .{},
    /// The read-only design surfaces whose whole cost is the FRESH design
    /// evaluation each of their handlers starts with.
    reads: ReadCaches = .{},
    /// Memoised gzip streams, keyed on the response body itself (see
    /// `gzip_cache`). Held here rather than module-scope so two server
    /// instances stay independent.
    gzip: gzip_cache.Store = .{},

    /// Give every store the server's long-lived allocator. A store left at its
    /// default has no allocator and simply never caches, so this is the switch
    /// that turns caching on.
    pub fn init(allocator: std.mem.Allocator) Caches {
        return .{
            .assembly_pages = .{ .allocator = allocator },
            .pcb_pages = .{ .allocator = allocator },
            .thermal_solves = .{ .allocator = allocator },
            .progress_json = .{ .allocator = allocator },
            .describe_json = .{ .allocator = allocator },
            .reads = .init(allocator),
            .gzip = .{ .allocator = allocator },
        };
    }

    /// Release every store. Safe on a default-constructed `Caches`.
    pub fn deinit(self: *Caches) void {
        self.assembly_pages.deinit();
        self.pcb_pages.deinit();
        self.thermal_solves.deinit();
        self.progress_json.deinit();
        self.describe_json.deinit();
        self.reads.deinit();
        self.gzip.deinit();
    }
};

/// Mutable per-server state. Post ward-migration this is the plugin-token store
/// (bearer tokens for the KiCad sync helper) plus the ward auth adapter state;
/// sessions, passkeys, users, and OAuth grants all live in wardd now. One
/// instance per running server; two instances are fully independent, which is
/// what makes per-test servers possible. Every field defaults to empty so
/// `.{}` yields a fresh, unloaded server.
pub const ServerState = struct {
    plugin_tokens: plugin_tokens.PluginTokenStore = .{},
    /// Ward auth adapter state: verdict caches + HTTP client + resolved config,
    /// built once in `serve()` via `WardState.init`. netlisp now verifies
    /// sessions and bearer tokens against wardd through this.
    ward: ward_auth.WardState = .{},
    /// Interactive routing sessions, keyed by design name — mutex-guarded,
    /// idle-evicted, and capped (see `route_session_api.Store`). Held here so
    /// the table lives for the server's lifetime without a module-level global.
    route_sessions: route_session_api.Store = .{},
    /// Background live-route jobs, keyed by design name — mutex-guarded and
    /// generation-versioned (see `route_live.Store`). One job per design; a
    /// detached routing thread streams serialized timeline events into it.
    route_live: route_live.Store = .{},
    /// Derived results held so a repeat request costs nothing.
    caches: Caches = .{},
    /// Background PCB deferred-payload warms in flight (see
    /// `serve/pcb_derived.zig`). Held here rather than at module scope so two
    /// server instances stay independent.
    derived_warms: pcb_derived.WarmLimit = .{},
    /// Retained DRC reconcile sessions for the PCB editor, keyed by design (see
    /// `drc_reconcile.Store`). A default-constructed store has no allocator and
    /// retains nothing, so a handler test's bare `ServerState` takes the full
    /// check on every request.
    drc_sessions: drc_reconcile.Store = .{},
    /// Append-only interaction log (`serve/request_log.zig`): one JSONL line
    /// per request, per instrumented handler's stage breakdown, and per
    /// browser event posted to `/api/client-log/:name`. A default-constructed
    /// store names no project directory and writes nothing, so a handler test
    /// logs nowhere unless it asks to; `serve()` is what turns it on.
    request_log: request_log.Store = .{},
    /// Long-lived state shared by the generated dossiers and human review
    /// checklist. Dossier composition is backgrounded and persisted below
    /// `out/`; the mutex serializes review-sidecar read-modify-write operations
    /// so concurrent reviewer saves cannot silently discard one another.
    reviews: struct {
        dossiers: dossier_jobs.Store = .{},
        board_review_mutex: infra_fs.Mutex = .{},
    } = .{},
};

// ── Server ─────────────────────────────────────────────────────────────

/// httpz request handler shared across every route and worker thread. Owns
/// the long-lived allocator and project directory and runs the auth middleware
/// before dispatch.
pub const Server = struct {
    allocator: std.mem.Allocator,
    /// Process capability for large, short-lived analysis work that must be
    /// returned to the OS rather than retained by the response arena.
    scratch_allocator: ?std.mem.Allocator = null,
    project_dir: []const u8,
    /// Directory holding the auth state files. Post ward-migration this is only
    /// `plugin_tokens.json` (the KiCad-sync bearer store) — passkeys, sessions,
    /// users, and OAuth grants moved to wardd. Defaults to `<project_dir>/auth`
    /// when no explicit override is supplied — the historic location. Override
    /// via `netlisp serve --auth-dir <path>` or the `NETLISP_AUTH_DIR` env var so
    /// multiple worktrees / project checkouts share one plugin-token store.
    auth_dir: []const u8,

    /// When true, requests arriving directly from the loopback interface (and
    /// NOT forwarded by a reverse proxy) bypass passkey/session auth and act as
    /// a `dev@localhost` admin — the local-development convenience. Default
    /// FALSE: it is opt-in via the `NETLISP_DEV` env var. This must never be
    /// derived from a request header — the prod server sits behind a same-host
    /// reverse proxy, so every internet request also arrives from loopback, and
    /// a `Host: localhost` header used to grant unauthenticated admin remotely.
    dev_mode: bool = false,

    /// Authenticated identity for the current request. The long-lived server
    /// leaves these at their defaults; `dispatch` creates a request-local copy
    /// and `ward_auth.authMiddleware` fills them only after verification.
    /// Handlers that create audit records must use these fields rather than
    /// trusting a username supplied by the request body.
    request_auth: struct {
        username: ?[]const u8 = null,
        role: ward_auth.Role = .reader,
    } = .{},

    /// Per-server mutable state (session/challenge stores today; OAuth/user/
    /// plugin-token stores, caches, live versions, PCB jobs, and rate limiters
    /// as the migration lands). Borrowed — the single instance is owned by
    /// `serve()` and shared, by pointer, with every per-request `Server` copy.
    state: *ServerState,

    pub fn dispatch(
        self: *Server,
        action: *const fn (*Server, *httpz.Request, *httpz.Response) anyerror!void,
        req: *httpz.Request,
        res: *httpz.Response,
    ) !void {
        // Count the request for as long as it is being served. Background
        // sweeps (`serve/warmup.zig`) read this and pause briefly before
        // claiming their next board, so a reader who arrives during a
        // post-deploy warm competes with fewer of its workers. Cheap enough to
        // sit on every request: one relaxed atomic each way.
        warm_sched.enterInteractive();
        defer warm_sched.leaveInteractive();
        // A request is a snapshot: revalidate the `src/` basename index once
        // here so the handlers below resolve however many design siblings they
        // need without re-walking the tree per lookup (`paths.beginRequest`).
        paths.beginRequest();
        // Hand the route handler a request-scoped view of the Server whose
        // allocator is httpz's per-request arena (reset after the response is
        // written). Every per-request allocation — evaluator state, rendered
        // HTML, scene graphs, PNG canvases — dies with the request instead of
        // accumulating in the process allocator for the life of the server
        // (the old behaviour leaked MBs per page view until OOM). Anything
        // that must outlive the request (live versions, regen-job frames,
        // auth/oauth stores and other long-lived state dupes into
        // page_allocator internally and was audited to do so.
        var req_handler = Server{
            .allocator = res.arena,
            .scratch_allocator = self.scratch_allocator,
            .project_dir = self.project_dir,
            .auth_dir = self.auth_dir,
            .dev_mode = self.dev_mode,
            .request_auth = .{},
            // The per-request copy borrows the same long-lived state instance,
            // so every route handler reaches the same stores/caches/limiters.
            .state = self.state,
        };
        // One monotonic reading opens the request and every timing below is a
        // delta from it. The `defer` is what makes the log honest: an auth
        // refusal and a handler that returned an error are exactly the
        // requests an investigation wants to see, and both leave by a path
        // that never reaches the bottom of this function.
        const started_ns = clock.monotonicNanos();
        defer request_log.emitRequest(&self.state.request_log, res.arena, req, res, started_ns);
        // Auth middleware: check before dispatching to route handler
        if (!try auth.authMiddleware(&req_handler, req, res)) return;
        try action(&req_handler, req, res);
        // Hand the browser the server's own cost for this request, so a client
        // `save.end` line can separate server work from network and parse.
        request_log.stampServerMs(req, res, started_ns);
        // gzip text responses for clients that accept it. The compressed buffer
        // lives in res.arena (dies with the request) — stateless, nothing to
        // invalidate. Biggest win for remote clients where transfer dominates.
        maybeCompress(&req_handler.state.caches.gzip, req, res);
    }

    pub fn notFound(_: *Server, _: *httpz.Request, res: *httpz.Response) error{}!void {
        res.status = 404;
        res.body = "Not found";
    }
};

/// Bodies below this size aren't worth compressing — the gzip header/trailer
/// (18 B) plus the CPU outweigh the few saved bytes, and TCP ships them in one
/// segment regardless.
const gzip_min_bytes: usize = 1400;

/// gzip-compress a 200 text response in place when the client advertised gzip
/// support. Runs after every route handler. The compressed buffer is allocated
/// in the per-request arena (`res.arena`), so it dies with the request; the
/// deflate work behind it is memoised across requests by `gzip_cache`, keyed on
/// the body bytes, so there is still nothing to invalidate. No-op for small bodies,
/// non-text content types, already-written/chunked responses (for example event
/// streams), or clients that don't send gzip.
fn maybeCompress(gzip_store: *gzip_cache.Store, req: *httpz.Request, res: *httpz.Response) void {
    if (res.written or res.chunked or res.status != 200) return;
    const ct = res.content_type orelse return;
    switch (ct) {
        .HTML, .JSON, .CSS, .SVG, .JS, .TEXT, .XML, .CSV => {},
        else => return,
    }
    // The effective body is the writer buffer when a handler used the writer
    // API (res.json, etc.), otherwise res.body — mirroring httpz's own pick in
    // Response.write.
    const body = if (res.buffer.writer.end > 0) res.buffer.writer.buffered() else res.body;
    if (body.len < gzip_min_bytes) return;

    const accept = req.header("accept-encoding") orelse return;
    if (std.mem.indexOf(u8, accept, "gzip") == null) return;

    // Memoised on the body itself: a page answering from a rendered-HTML
    // cache would otherwise re-deflate its whole body on every view, which for
    // a 1.2 MB schematic cost ~150 ms — far more than the cached render it
    // wrapped. A content key cannot go stale, so there is nothing to invalidate.
    const compressed = gzip_store.compress(res.arena, body) catch return;
    if (compressed.len >= body.len) return; // never inflate

    // Route the response through res.body and drop any writer-buffer contents,
    // since httpz prefers a non-empty buffer over res.body.
    res.buffer.writer.end = 0;
    res.body = compressed;
    res.header("Content-Encoding", "gzip");
    res.header("Vary", "Accept-Encoding");
}

/// Redirect target for a retired /pcb-route-lab/:name request: the ordinary PCB
/// layout page, with `:name` verbatim (still percent-encoded as received) so
/// the URL re-encodes correctly.
fn routeLabLocation(alloc: std.mem.Allocator, name: []const u8) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(alloc, "/pcb-layout/{s}", .{name});
}

/// GET /pcb-route-lab/:name — the Route Lab page + its scheduler engine were
/// retired (the surviving router.zig surface supersedes them); 302 to the
/// ordinary PCB layout page so lingering bookmarks/agents don't 404 — mirrors
/// the `/modules` redirect.
fn routeLabRedirect(_: *Server, req: *httpz.Request, res: *httpz.Response) !void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    res.status = 302;
    res.header("Location", try routeLabLocation(res.arena, name));
}

// spec: Web Server - the retired /pcb-route-lab page 302-redirects to the /pcb-layout page for the same design
test "retired Route Lab path redirects to the PCB layout page" {
    const loc = try routeLabLocation(std.testing.allocator, "barracuda");
    defer std.testing.allocator.free(loc);
    try std.testing.expectEqualStrings("/pcb-layout/barracuda", loc);
}

// spec: Web Server - the live scene graph is answered only for the design it was pushed for
test "the live scene-graph slot answers its own design and refuses another name" {
    defer setLiveLayoutJson("", null); // leave the process-global slot empty
    setLiveLayoutJson("alpha", "{\"design\":\"alpha\"}");

    const mine = liveLayoutFor(std.testing.allocator, "alpha").?;
    defer std.testing.allocator.free(mine);
    try std.testing.expectEqualStrings("{\"design\":\"alpha\"}", mine);

    // ONE slot server-wide, so a request naming a different design must be
    // refused rather than handed these bytes.
    try std.testing.expect(liveLayoutFor(std.testing.allocator, "beta") == null);
    // A near-miss name is not a match either (no prefix/substring leniency).
    try std.testing.expect(liveLayoutFor(std.testing.allocator, "alph") == null);
    try std.testing.expect(liveLayoutFor(std.testing.allocator, "alphax") == null);

    // Nothing pushed at all reads back null for every name.
    setLiveLayoutJson("alpha", null);
    try std.testing.expect(liveLayoutFor(std.testing.allocator, "alpha") == null);
}

// spec: Web Server - a live scene-graph read copies the bytes so a later push cannot free the response body
test "a live scene-graph read survives the push that replaces the slot" {
    defer setLiveLayoutJson("", null);
    setLiveLayoutJson("alpha", "{\"v\":1}");

    // The reader's copy is its own allocation, not a borrow of the live slot…
    const held = liveLayoutFor(std.testing.allocator, "alpha").?;
    defer std.testing.allocator.free(held);

    // …so the push that frees the previous page_allocator buffer — exactly what
    // races httpz's post-dispatch serialization of `res.body` — leaves it intact.
    setLiveLayoutJson("alpha", "{\"v\":2}");
    try std.testing.expectEqualStrings("{\"v\":1}", held);

    const fresh = liveLayoutFor(std.testing.allocator, "alpha").?;
    defer std.testing.allocator.free(fresh);
    try std.testing.expectEqualStrings("{\"v\":2}", fresh);
}

const HttpCloseRaceHarness = struct {
    const payload_len = 3_200_000;

    entered: std.Io.Semaphore = .{},
    release: std.Io.Semaphore = .{},

    fn respond(self: *HttpCloseRaceHarness, _: *httpz.Request, res: *httpz.Response) !void {
        self.entered.post(std.testing.io);
        self.release.waitUncancelable(std.testing.io);
        const body = try res.arena.alloc(u8, payload_len);
        @memset(body, 'x');
        res.body = body;
    }
};

fn reserveHttpTestPort() !u16 {
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var listener = try address.listen(std.testing.io, .{});
    defer listener.deinit(std.testing.io);
    return listener.socket.address.getPort();
}

fn connectHttpTestClient(port: u16) !std.Io.net.Stream {
    const address = try std.Io.net.IpAddress.parse("127.0.0.1", port);
    const stream = try address.connect(std.testing.io, .{ .mode = .stream });
    const timeout = std.mem.toBytes(std.posix.timeval{ .sec = 1, .usec = 0 });
    try std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.RCVTIMEO, &timeout);
    try std.posix.setsockopt(stream.socket.handle, std.posix.SOL.SOCKET, std.posix.SO.SNDTIMEO, &timeout);
    return stream;
}

fn sendHttpTestRequest(stream: std.Io.net.Stream) !void {
    var writer = stream.writer(std.testing.io, &.{});
    try writer.interface.writeAll("GET / HTTP/1.1\r\nHost: localhost\r\n\r\n");
    try writer.interface.flush();
}

fn readHttpTestResponse(stream: std.Io.net.Stream, buffer: []u8) ![]const u8 {
    var used: usize = 0;
    while (used < buffer.len) {
        const count = std.posix.read(stream.socket.handle, buffer[used..]) catch |err| switch (err) {
            error.ConnectionResetByPeer => break,
            else => return err,
        };
        if (count == 0) break;
        used += count;
        if (std.mem.indexOf(u8, buffer[0..used], "\r\n\r\n")) |header| {
            const response_len = header + 4 + HttpCloseRaceHarness.payload_len;
            if (used >= response_len) return buffer[0..response_len];
        }
    }
    return buffer[0..used];
}

fn expectClosingHttpTestResponse(response: []const u8) !void {
    try std.testing.expect(std.mem.startsWith(u8, response, "HTTP/1.1 200"));
    const header_end = std.mem.indexOf(u8, response, "\r\n\r\n").? + 4;
    try std.testing.expectEqual(HttpCloseRaceHarness.payload_len, response.len - header_end);
}

fn verifyHttpzCloseHandover(allocator: std.mem.Allocator) !void {
    if (comptime @import("builtin").os.tag == .windows) return;

    const port = try reserveHttpTestPort();
    var harness = HttpCloseRaceHarness{};
    var server = try httpz.Server(*HttpCloseRaceHarness).init(std.testing.io, allocator, .{
        .address = .localhost(port),
        .workers = .{ .count = 1, .min_conn = 1, .max_conn = 4 },
        .thread_pool = .{ .count = 1 },
    }, &harness);
    var router = try server.router(.{});
    router.get("/", HttpCloseRaceHarness.respond, .{});

    const server_thread = try server.listenInNewThread();
    defer {
        server.stop();
        server_thread.join();
        server.deinit();
    }

    const response_buffer = try allocator.alloc(u8, HttpCloseRaceHarness.payload_len + 1024);
    defer allocator.free(response_buffer);

    for (0..4) |_| {
        const stream = try connectHttpTestClient(port);
        defer stream.close(std.testing.io);
        try sendHttpTestRequest(stream);
        harness.entered.waitUncancelable(std.testing.io);
        try stream.shutdown(std.testing.io, .send);
        try std.Io.sleep(std.testing.io, .fromMilliseconds(2), .awake);
        harness.release.post(std.testing.io);

        const response = try readHttpTestResponse(stream, response_buffer);
        try expectClosingHttpTestResponse(response);
    }

    // A fresh connection proves the worker survived every forced close race.
    const final_stream = try connectHttpTestClient(port);
    defer final_stream.close(std.testing.io);
    try sendHttpTestRequest(final_stream);
    harness.entered.waitUncancelable(std.testing.io);
    harness.release.post(std.testing.io);
    const final_response = try readHttpTestResponse(final_stream, response_buffer);
    try expectClosingHttpTestResponse(final_response);
}

test "httpz close handover cannot leave a stale read event" {
    try verifyHttpzCloseHandover(std.testing.allocator);
}

/// Bring up the netlisp web server on `port`: registers every page, JSON API,
/// auth, and OAuth-support route against an httpz instance, then blocks on
/// `server.listen()`. Project files are served out of `project_dir`; auth
/// state lives in `auth_dir` (or `<project_dir>/auth` when null).
/// The PCB-layout surface: the viewer page plus its JSON/PNG/facts APIs,
/// layout snapshot management, routing/regen, and the fab outputs
/// (centroid, drill, gerber package).
fn registerPcbRoutes(router: anytype) void {
    router.get("/assembly-debug/:name", assembly_debug.assemblyDebugPage, .{});
    router.get("/route-review", route_review.routeReviewPage, .{});
    router.post("/api/kicad-route-review/run", route_review.routeReviewApi, .{});
    router.get("/api/design-route-review/run/:name", route_review.designRouteReviewApi, .{});
    router.post("/api/design-route-review/run/:name", route_review.designRouteReviewApi, .{});
    router.get("/api/design-route-review/cached/:name", route_review.cachedDesignRouteReviewApi, .{});
    router.post("/api/route-session/:name/start", route_session_api.startSessionApi, .{});
    router.post("/api/route-session/:name/hint", route_session_api.hintSessionApi, .{});
    router.get("/api/route-session/:name/distill", route_session_api.distillSessionApi, .{});
    router.get("/api/route-session/:name", route_session_api.getSessionApi, .{});
    router.delete("/api/route-session/:name", route_session_api.deleteSessionApi, .{});
    // The Route Lab page + its scheduler engine were retired (superseded by the
    // router.zig surface); redirect any lingering /pcb-route-lab links to the
    // ordinary PCB layout page so bookmarks/agents don't 404.
    router.get("/pcb-route-lab/:name", routeLabRedirect, .{});
    router.get("/pcb-layout/:name", pcb_layout_page.pcbLayoutPage, .{});
    router.get("/review/:name", board_review.reviewPage, .{});
    router.get("/api/board-review/:name", board_review.getStateApi, .{});
    router.post("/api/board-review/:name", board_review.updateStateApi, .{});
    router.get("/api/board-review-audit/:name", board_review.auditApi, .{});
    router.get("/api/pcb-cam/:name", pcb_layout_page.pcbCamJsonApi, .{});
    router.get("/api/pcb-subseeds/:name", pcb_subseeds.pcbSubSeedsApi, .{});
    router.post("/api/pcb-subcircuit-layout/:name", pcb_subseeds.saveSubcircuitLayoutApi, .{});
    router.get("/api/pcb-layout/:name", pcb_layout_page.pcbLayoutJsonApi, .{});
    router.get("/api/pcb-settings/:name", pcb_layout_page.pcbSettingsApi, .{});
    router.get("/api/pcb-png/:name", pcb_layout_page.pcbPngApi, .{});
    router.get("/api/pcb-describe/:name", pcb_describe.pcbDescribeApi, .{});
    router.get("/api/layout-progress/:name", pcb_describe.layoutProgressApi, .{});
    router.get("/api/layout-match/:name", layout_match.layoutMatchApi, .{});
    router.get("/api/rough-best/:name", rough_best.bestRoughApi, .{});
    router.get("/api/rough-best-png/:name", rough_best.bestRoughPngApi, .{});
    router.get("/api/pcb-centroid/:name", pcb_layout_page.pcbCentroidApi, .{});
    router.get("/api/pcb-drill/:name", pcb_layout_page.pcbDrillApi, .{});
    router.get("/api/fab-readiness/:name", pcb_layout_page.pcbFabReadinessApi, .{});
    router.get("/api/pcb-gerbers/:name", pcb_layout_page.pcbGerbersApi, .{});
    router.post("/api/design-archive/:name", design_archive_api.designArchiveApi, .{});
    router.get("/api/pcb-matlab-rf/:name", matlab_rf_export.pcbMatlabRfApi, .{});
    router.post("/api/pcb-step/:name", pcb_step_export.pcbStepApi, .{});
    router.post("/api/pcb-layouts/:name", pcb_layout_page.saveNamedLayoutApi, .{});
    router.get("/api/pcb-layout-history/:name", pcb_layout_page.pcbLayoutHistoryApi, .{});
    router.post("/api/pcb-layout-history/:name/restore", pcb_layout_page.restoreLayoutHistoryApi, .{});
    router.post("/api/pcb-normalize-junctions/:name", pcb_layout_page.normalizeJunctionsApi, .{});
    router.post("/api/pcb-layouts/:name/delete", pcb_layout_page.deleteNamedLayoutApi, .{});
    router.post("/api/pcb-layouts/:name/rename", pcb_layout_page.renameNamedLayoutApi, .{});
    router.post("/api/pcb-layouts/:name/default", pcb_layout_page.setDefaultLayoutApi, .{});
    router.post("/api/import-kicad-layout/:name", pcb_layout_sync.importKicadLayoutApi, .{});
    router.post("/api/pcb-rescore/:name", pcb_layout_page.rescoreLayoutsApi, .{});
    router.post("/api/pcb-score/:name", pcb_layout_page.pcbScoreApi, .{});
    router.post("/api/pcb-score-batch/:name", pcb_layout_page.pcbScoreBatchApi, .{});
    router.post("/api/pcb-route/:name", pcb_layout_page.pcbRouteApi, .{});
    router.post("/api/pcb-route-complete/:name", route_session_api.completeApi, .{});
    router.post("/api/route-live/:name/start", route_live.routeLiveStartApi, .{});
    router.get("/api/route-live/:name", route_live.routeLivePollApi, .{});
    router.post("/api/route-live/:name/cancel", route_live.routeLiveCancelApi, .{});
    router.post("/api/pcb-route-analyze/:name", route_analyze_api.pcbRouteAnalyzeApi, .{});
    router.post("/api/route-vision/:name", route_vision.routeVisionApi, .{});
    router.post("/api/pcb-drc/:name", pcb_layout_page.pcbDrcApi, .{});
    router.post("/api/pcb-drc/:name/ground-vias", ground_vias.api, .{});
    router.post("/api/pcb-fence/:name", pcb_fence.pcbFenceApi, .{});
    router.get("/api/pcb-drc-rules/:name", drc_rules.getApi, .{});
    router.post("/api/pcb-drc-rules/:name", drc_rules.setApi, .{});
    router.post("/api/pcb-regen-start/:name", pcb_layout_page.pcbRegenStartApi, .{});
    router.get("/api/pcb-progress/:name", pcb_layout_page.pcbProgressApi, .{});
    router.post("/api/courtyard/:name", pcb_layout_page.savePcbCourtyardApi, .{});
    router.post("/api/library-courtyard/:name", pcb_layout_page.savePcbCourtyardApi, .{});
}

fn registerLibraryRoutes(router: anytype) void {
    router.get("/library", library.libraryPage, .{});
    router.get("/api/library-card/:name", library.libraryCardApi, .{});
    router.get("/library/footprint/:name", footprint_editor.editorPage, .{});
    router.get("/library/3d/:footprint", library_3d.viewerPage, .{});
    router.get("/api/model-file/:footprint", library_3d.modelFileApi, .{});
    router.get("/api/model-sprite/:footprint", library_3d.modelFileApi, .{});
    router.post("/api/model-sprite/:footprint", library_3d.modelFileApi, .{});
    router.post("/api/model-transform/:footprint", library_3d.saveTransformApi, .{});
    router.post("/api/upload-package", upload_package.uploadPackageApi, .{});
    router.get("/api/footprint/:name", footprint_preview.footprintApi, .{});
    router.post("/api/footprint/:name", footprint_editor.saveApi, .{});
    router.get("/api/board-footprint/:name", footprint_preview.boardFootprintApi, .{});
    router.post("/api/upload-zip", upload.uploadZipApi, .{});
    router.post("/api/cse-fetch", library.cseFetchApi, .{});
    router.post("/api/upload-model/:name", library.uploadModelApi, .{});
    router.post("/api/library-delete/:kind/:name", library.deleteLibraryEntryApi, .{});
}

/// Start the HTTP server: configure auth/rate limits, register every route
/// (pages, APIs, auth, OAuth support), and block serving requests until shutdown.
pub fn serve(
    io: std.Io,
    allocator: std.mem.Allocator,
    scratch_allocator: std.mem.Allocator,
    options: ServeOptions,
) ServeError!void {
    const port = options.port;
    const project_dir = options.project_dir;
    const auth_dir = options.auth_dir;
    // Set the CSE/DigiKey rate limits from env/.env once, before any request
    // thread can touch the limiters.
    rate_limiter.configureFromEnv(allocator);
    const effective_auth: []const u8 = if (auth_dir) |d| d else try std.fmt.allocPrint(allocator, "{s}/auth", .{project_dir});
    // Opt-in local-dev auth bypass. Off in production (no env var) → every
    // request must authenticate. See Server.dev_mode. Read via config.zig so
    // the ban-env policy holds (only config.zig touches the environment).
    const dev_mode = @import("config.zig").devMode(allocator);
    if (dev_mode) std.debug.print("netlisp: NETLISP_DEV set — loopback requests bypass auth as dev@localhost\n", .{});
    var state: ServerState = .{
        .caches = .init(allocator),
        // The reconcile store retains an evaluated design, its placement and a
        // board's worth of pour borrows per session, so it takes the server's
        // long-lived allocator for the same reason the page caches do.
        .drc_sessions = .{ .allocator = allocator },
        // Naming the project directory is what turns the interaction log on —
        // it writes into `<project_dir>/logs/`, which production keeps
        // gitignored under `/projects/`.
        .request_log = .{ .project_dir = project_dir },
        // Only a real server composes dossiers in the background: the detached
        // thread outlives the request that started it, which a handler test's
        // stack-owned `ServerState` could not survive.
        .reviews = .{ .dossiers = .{ .background = true, .project_dir = project_dir } },
    }; // owned here; shared by pointer
    defer state.caches.deinit();
    // A real server may run background full-board DRC sweeps behind the
    // editor's reconciles; nothing else does, which is what keeps every test's
    // sweep a synchronous call it can assert on (see `drc_sweep.zig`).
    drc_sweep.install(&state.drc_sessions);
    defer state.drc_sessions.deinit();
    // Published AFTER the deinit defer so the retraction below runs FIRST
    // (defers unwind last-in-first-out): no surface can reach a torn-down store.
    thermal_cache.publish(&state.caches.thermal_solves);
    defer thermal_cache.publish(null);
    state.ward.init(allocator); // ward verdict caches + HTTP client from WARD_* env
    var handler = Server{ .allocator = allocator, .scratch_allocator = scratch_allocator, .project_dir = project_dir, .auth_dir = effective_auth, .dev_mode = dev_mode, .state = &state };
    var server = try httpz.Server(*Server).init(io, allocator, .{
        .address = .all(port),
        .request = .{
            // 64 MiB so datasheet PDFs and large KiCad zips fit. Individual
            // endpoints re-validate their own per-request limits.
            .max_body_size = 64 * 1024 * 1024,
            .buffer_size = 256 * 1024,
            .max_header_count = 64,
            .max_form_count = 16,
            .max_query_count = 32,
        },
        .response = .{ .max_header_count = 32 },
        .workers = .{
            .large_buffer_size = 10 * 1024 * 1024,
        },
    }, &handler);
    const router = try server.router(.{});

    // Pages
    router.get("/", pages.indexPage, .{});
    router.get("/style.css", pages.cssPage, .{});
    router.get("/static/:name", static_assets.staticAsset, .{});
    router.get("/schematics/:name", schematic_page.schematicPage, .{});
    registerPcbRoutes(router);
    router.get("/systems/:name", system_review_api.systemPage, .{});
    router.get("/systems/:name/cad", system_review_api.systemCadPage, .{});
    // The draft package's HTML dossier as a readable page — same composition as
    // the `draft.zip` member, without the download-and-unzip round trip. The
    // composition itself runs on a background thread (`serve/dossier_jobs.zig`),
    // so this route answers from the composed copy or with a loader, never with
    // a minute of board analysis held open inside the request.
    router.get("/systems/:name/dossier", system_review_api.dossierPage, .{});
    router.get("/modules", modules_page.modulesListPage, .{});
    router.get("/modules/:name", modules_page.moduleViewPage, .{});
    // API
    router.get("/api/systems", system_review_api.listSystemsApi, .{});
    router.get("/api/systems/:name", system_review_api.getSystemApi, .{});
    router.get("/api/systems/:name/cad/mesh", system_review_api.systemCadMeshApi, .{});
    router.post("/api/systems/:name/cad/mesh", system_review_api.systemCadMeshApi, .{});
    router.get("/api/systems/:name/cad/export", system_review_api.systemCadExportApi, .{});
    router.post("/api/systems/:name/cad/export", system_review_api.systemCadExportApi, .{});
    router.get("/api/systems/:name/cad/document", system_review_api.systemCadDocumentApi, .{});
    router.put("/api/systems/:name/cad/document", system_review_api.putSystemCadDocumentApi, .{});
    router.get("/api/systems/:name/docs/:doc", system_review_api.getDocumentApi, .{});
    router.put("/api/systems/:name/docs/:doc", system_review_api.putDocumentApi, .{});
    router.post("/api/systems/:name/attest", system_review_api.attestSystemApi, .{});
    router.post("/api/systems/:name/assets", system_review_api.uploadAssetApi, .{});
    router.get("/api/systems/:name/assets/:asset", system_review_api.getAssetApi, .{});
    router.get("/api/systems/:name/readiness", system_review_api.readinessApi, .{});
    router.get("/api/systems/:name/dossier-status", system_review_api.dossierStatusApi, .{});
    router.post("/api/systems/:name/dossier-regenerate", system_review_api.regenerateDossierApi, .{});
    router.get("/api/systems/:name/draft.zip", system_review_api.draftPackageApi, .{});
    router.post("/api/systems/:name/release", system_review_api.releaseApi, .{});
    router.post("/api/push/:name", api.pushApi, .{});
    router.get("/api/module-source", modules_page.moduleSourceApi, .{});
    router.get("/api/version/:name", api.versionApi, .{});
    // Browser-side interaction events (page load, dirty bursts, autosave and
    // DRC round trips) land in the same JSONL file the server writes its own
    // request and stage lines to, so one file answers what the user did and
    // what it cost.
    router.post("/api/client-log/:name", request_log.clientLogApi, .{});
    router.get("/api/export-kicad/:name", api.exportKicadApi, .{});
    router.get("/api/export-netlist/:name", api.exportNetlistApi, .{});
    // File-based KiCad sync — server writes the .kicad_pcb at the
    // design's (kicad-pcb "<path>") form directly. `?dry_run=1` returns
    // the would-be ops without writing (Phase 2 — writer lands in
    // Phase 3).
    router.post("/api/sync-kicad-pcb/:name", sync.syncKicadPcbApi, .{});
    router.get("/api/export-bom/:name", api.exportBomCsvApi, .{});
    router.get("/api/export-review/:name", api.exportReviewPackageApi, .{});
    // Native schematic-block raster; unlike a browser screenshot this route
    // is deterministic, headless, and directly shared with CLI export.
    router.get("/api/schematic-png/:name", schematic_png.schematicPngApi, .{});
    // Review-document PDF (`?theme=dark` for the screen palette) — the HTTP
    // twin of `netlisp export-pdf`, served as a `<name>.pdf` attachment.
    router.get("/api/schematic-pdf/:name", schematic_pdf.schematicPdfApi, .{});
    // Exported KiCad schematic (+ project sidecars) as one store-only zip —
    // the HTTP twin of `netlisp export-kicad-sch`. `?vendor=0` / `?flat=1`
    // mirror the CLI flags.
    router.get("/api/kicad-sch/:name", kicad_sch_export.kicadSchApi, .{});
    // Guarded push of that same schematic INTO the KiCad project directory the
    // design's (kicad-pcb "<path>") names. `?dry_run=1` returns the per-file
    // plan without writing; a hand-drawn sheet in the way or a KiCad lock on
    // the project answers 409 and writes nothing.
    router.post("/api/sync-kicad-sch/:name", sync_kicad_sch.syncKicadSchApi, .{});
    // Lumped steady-state thermal screening as read-only facts JSON — the
    // HTTP twin of the `describe_thermal` CLI tool, sharing its whole body.
    // `?ambient=NN` screens at the caller's ambient instead of bench 25 °C.
    router.get("/api/thermal/:name", thermal_api.thermalApi, .{});
    // The solved rise FIELD of one cooling scenario, in board millimetres —
    // what the thermal page's board overlay paints on the live PCB view. The
    // numbers above are the authority; this is the same solve as a grid.
    router.get("/api/thermal-field/:name", thermal_api.thermalFieldApi, .{});
    // …and the Thermal tab that reads it: the verdict headline, the cooling
    // ladder and the per-part junction table in a panel beside the live board,
    // which is the read-only PCB viewer with the heat overlay painted on it.
    // `?fragment=1` answers the two ambient-dependent regions alone, which is
    // what the page's own client swaps in on an ambient change.
    router.get("/thermal/:name", thermal_page.thermalPage, .{});
    router.get("/api/erc/:name", api.ercApi, .{});
    // Version history: snapshot list + structured diff between two stored
    // revisions (or a revision and the current working file).
    router.get("/api/history/:name", design_diff.historyApi, .{});
    router.get("/api/diff/:name", design_diff.diffApi, .{});
    router.post("/api/section-note/:name/add", api.addSectionNoteApi, .{});
    router.post("/api/section-note/:name/remove", api.removeSectionNoteApi, .{});
    router.post("/api/component-datasheet/:component/add", api.addComponentDatasheetApi, .{});
    router.post("/api/component-datasheet/:component/remove", api.removeComponentDatasheetApi, .{});
    router.get("/api/designs", api.designsApi, .{});
    router.get("/api/scene-graph/:name", api.sceneGraphApi, .{});
    router.get("/api/pinout/:name", api.pinoutApi, .{});
    router.post("/api/upload-datasheet", upload_datasheet.uploadDatasheetApi, .{});
    router.get("/api/datasheets", upload_datasheet.listDatasheetsApi, .{});
    // One-click attach from the library page: splice (datasheet "…") into
    // a component's lib/components/<name>.sexp (idempotent).
    router.post("/api/attach-datasheet", datasheet_attach.attachDatasheetApi, .{});
    router.get("/datasheets/:filename", upload_datasheet.serveDatasheetApi, .{});
    router.get("/pdf-view/:filename", pdf_viewer.pdfViewerPage, .{});

    // Edit
    router.post("/api/edit-value/:name", edit.editValueApi, .{});
    router.post("/api/design-rules/:name", design_rules_edit.editDesignRulesApi, .{});
    router.post("/api/stackup-planes/:name", design_rules_edit.editStackupPlanesApi, .{});
    router.get("/api/board-role/:name", edit.getBoardRoleApi, .{});
    router.post("/api/board-role/:name", edit.setBoardRoleApi, .{});
    router.post("/api/power-plane/:name", edit.setPowerPlaneApi, .{});
    router.post("/api/edit-mpn/:name", edit.editMpnApi, .{});
    router.post("/api/edit-footprint/:name", edit.editFootprintApi, .{});
    router.post("/api/new-design", edit.newDesignApi, .{});
    router.post("/api/add-instance/:name", edit.addInstanceApi, .{});
    router.post("/api/remove-instance/:name", edit.removeInstanceApi, .{});
    router.post("/api/rewire-pin/:name", edit.rewirePinApi, .{});
    router.post("/api/bind-decouple/:name", edit.bindDecoupleApi, .{});
    router.post("/api/duplicate-instance/:name", edit.duplicateInstanceApi, .{});
    router.post("/api/rename-net/:name", edit.renameNetApi, .{});
    router.post("/api/move-pin/:name", edit.movePinApi, .{});
    router.post("/api/swap-pins/:name", edit.swapPinsApi, .{});
    router.post("/api/add-section/:name", edit.addSectionApi, .{});
    router.post("/api/rename-section/:name", edit.renameSectionApi, .{});
    router.post("/api/remove-section/:name", edit.removeSectionApi, .{});
    router.post("/api/add-port/:name", edit.addPortApi, .{});
    router.post("/api/remove-port/:name", edit.removePortApi, .{});
    router.post("/api/rename-refdes/:name", edit.renameRefdesApi, .{});
    router.post("/api/set-dnp/:name", edit.setDnpApi, .{});
    router.get("/api/free-pins/:name", api.freePinsApi, .{});
    router.get("/api/design-state/:name", api.designStateApi, .{});
    router.get("/api/source/:name", edit.getSourceApi, .{});
    router.post("/api/source/:name", edit.saveSourceApi, .{});
    // Smart-editor assistance: dry-validate unsaved source (no write) and the
    // autocomplete library index.
    router.post("/api/validate/:name", edit_assist.validateSourceApi, .{});
    router.get("/api/lib-index", edit_assist.libIndexApi, .{});
    // Layout-tab drag-to-arrange writeback: splice a regenerated
    // (diagram-layout …) form into the design source.
    router.post("/api/diagram-layout/:name", edit_assist.saveDiagramLayoutApi, .{});
    router.get("/api/notes/:name", notes.getNotesApi, .{});
    router.put("/api/notes/:name", notes.saveNotesApi, .{});
    router.get("/api/notes/:name/tasks", notes.getTasksApi, .{});
    router.post("/api/notes/:name/tasks/add", notes.addTaskApi, .{});
    router.post("/api/notes/:name/tasks/complete", notes.completeTaskApi, .{});
    router.post("/api/notes/:name/tasks/reopen", notes.reopenTaskApi, .{});
    router.post("/api/notes/:name/tasks/remove", notes.removeTaskApi, .{});

    registerLibraryRoutes(router);

    // RFC 9728 protected-resource metadata only (wardd is the auth server now).
    router.get("/.well-known/oauth-protected-resource", ward_auth.metadataProtectedResource, .{});

    std.debug.print("Listening on http://localhost:{d}\nProject: {s}\n", .{ port, project_dir });
    // Open the day's interaction log with a line naming this process, and say
    // on stderr where it is — a log nobody can find diagnoses nothing.
    request_log.emitServerStart(&state.request_log, allocator, port);
    if (request_log.currentPath(&state.request_log, allocator, null)) |log_path| {
        defer allocator.free(log_path);
        log.progress("interaction log: {s}", .{log_path});
    }
    // The one number that says whether a deploy's restart was a gap: everything
    // above this line runs BEFORE the socket answers — the interaction log's
    // own open included — and everything below it runs behind an
    // already-listening server. Kept as its own line (rather than folded into
    // the banner above) because the banner's exact text is what deploy logs and
    // humans grep for.
    log.progress("startup: listening after {d:.2} ms — design scan and page warm run behind the socket", .{warm_sched.sinceStartMs()});
    // Fill the read-path caches in the background so the first visitor after a
    // deploy is not the one who pays for them. Overlaps with listen(). A
    // private performance harness needs an idle machine more than corpus-wide
    // cache warmth, so its explicit CLI flag can skip that background work.
    if (options.skip_warmup)
        log.progress("startup cache warm-up disabled", .{})
    else
        warmup.spawn(&handler);
    try server.listen();
}
