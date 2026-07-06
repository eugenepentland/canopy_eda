const std = @import("std");
const httpz = @import("httpz");
const deflate = @import("deflate.zig");

/// Error set for the `serve` entry point — wraps all the failure modes that
/// can come out of `httpz.Server.init`, `router`, and `listen`. The set is
/// intentionally broad because the http server's own surface is wide; we
/// derive it from the actual `listen()` return type so it stays in sync.
pub const ServeError = std.mem.Allocator.Error ||
    @typeInfo(@typeInfo(@TypeOf(httpz.Server(*Handler).listen)).@"fn".return_type.?).error_union.error_set ||
    @typeInfo(@typeInfo(@TypeOf(httpz.Server(*Handler).router)).@"fn".return_type.?).error_union.error_set ||
    @typeInfo(@typeInfo(@TypeOf(httpz.Server(*Handler).init)).@"fn".return_type.?).error_union.error_set ||
    error{ InvalidIPAddressFormat, ThreadQuotaExceeded };

// Sub-modules
const pages = @import("serve/pages.zig");
const api = @import("serve/api.zig");
const edit = @import("serve/edit.zig");
const edit_assist = @import("serve/edit_assist.zig");
const library = @import("serve/library.zig");
const library_3d = @import("serve/library_3d.zig");
const upload = @import("serve/upload.zig");
const upload_package = @import("serve/upload_package.zig");
const upload_datasheet = @import("serve/upload_datasheet.zig");
const pdf_viewer = @import("serve/pdf_viewer.zig");
const footprint_preview = @import("serve/footprint_preview.zig");
const schematic_page = @import("serve/schematic_page.zig");
const editor_page = @import("serve/editor_page.zig");
const pcb_layout_page = @import("serve/pcb_layout_page.zig");
const pcb_describe = @import("serve/pcb_describe.zig");
const layout_match = @import("serve/layout_match.zig");
const rough_best = @import("serve/rough_best.zig");
const modules_page = @import("serve/modules.zig");
const auth = @import("serve/auth.zig");
const mcp = @import("serve/mcp.zig");
const oauth = @import("serve/oauth.zig");
const account_page = @import("serve/account_page.zig");
const static_assets = @import("serve/static_assets.zig");
const sync = @import("serve/sync.zig");
const notes = @import("serve/notes.zig");
const design_diff = @import("serve/design_diff.zig");
const datasheet_attach = @import("serve/datasheet_attach.zig");
const rate_limiter = @import("serve/rate_limiter.zig");
const mcp_docs = @import("serve/mcp_docs.zig");

// ── Global live state ──────────────────────────────────────────────────

pub var live_mutex: std.Thread.Mutex = .{};
pub var live_layout_json: ?[]const u8 = null;

/// Replace the cached live schematic scene-graph JSON. The incoming slice may
/// come from a request-scoped arena (e.g. MCP tool dispatch) so it must be
/// duplicated into page_allocator memory that outlives the caller. The previous
/// value, if any, is freed.
pub fn setLiveLayoutJson(data: ?[]const u8) void {
    const dup: ?[]const u8 = if (data) |d|
        (std.heap.page_allocator.dupe(u8, d) catch null)
    else
        null;
    live_mutex.lock();
    const old = live_layout_json;
    live_layout_json = dup;
    live_mutex.unlock();
    if (old) |o| std.heap.page_allocator.free(o);
}

// Per-design live version. The browser polls /api/version/:name; each design
// has its own counter so mutating design A never invalidates B's viewer.
// Keys are duplicated into page_allocator memory so they outlive callers.
pub var live_version_mutex: std.Thread.Mutex = .{};
pub var live_versions: std.StringHashMapUnmanaged(u32) = .empty;

/// Increment and return the live version for a design.
pub fn bumpLiveVersion(name: []const u8) u32 {
    live_version_mutex.lock();
    defer live_version_mutex.unlock();
    const gop = live_versions.getOrPut(std.heap.page_allocator, name) catch return 0;
    if (!gop.found_existing) {
        gop.key_ptr.* = std.heap.page_allocator.dupe(u8, name) catch {
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
var pcb_jobs_mutex: std.Thread.Mutex = .{};
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
    const gop = pcb_jobs.getOrPut(std.heap.page_allocator, name) catch return .{ .gen = 0, .fresh = false };
    if (!gop.found_existing) {
        gop.key_ptr.* = std.heap.page_allocator.dupe(u8, name) catch {
            _ = pcb_jobs.remove(name);
            return .{ .gen = 0, .fresh = false };
        };
        gop.value_ptr.* = .{};
    }
    if (gop.value_ptr.running) return .{ .gen = gop.value_ptr.gen, .fresh = false };
    if (gop.value_ptr.frame) |old| {
        std.heap.page_allocator.free(old);
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
    const dup = std.heap.page_allocator.dupe(u8, json) catch return;
    pcb_jobs_mutex.lock();
    defer pcb_jobs_mutex.unlock();
    const e = pcb_jobs.getPtr(name) orelse {
        std.heap.page_allocator.free(dup);
        return;
    };
    if (e.gen != gen or !e.running) {
        std.heap.page_allocator.free(dup);
        return;
    }
    if (e.frame) |old| std.heap.page_allocator.free(old);
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

// ── Server ─────────────────────────────────────────────────────────────

/// httpz request handler shared across every route and worker thread. Owns
/// the long-lived allocator and project directory, runs the auth middleware
/// before dispatch, and exposes the MCP WebSocket client type so the server
/// can upgrade `GET /mcp` connections.
pub const Handler = struct {
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    /// Directory holding the auth state files (`credentials.json`,
    /// `sessions.json`, `users.json`, `invites.json`, `oauth_clients.json`,
    /// `oauth_tokens.json`, `plugin_tokens.json`). Defaults to
    /// `<project_dir>/auth` when no explicit override is supplied — the
    /// historic location. Override via `netlisp serve --auth-dir <path>` or the
    /// `EDA_AUTH_DIR` env var so multiple worktrees / project checkouts
    /// share one passkey + session store and a passkey registered in one
    /// worktree keeps working in the others.
    auth_dir: []const u8,

    /// When true, requests arriving directly from the loopback interface (and
    /// NOT forwarded by a reverse proxy) bypass passkey/session auth and act as
    /// a `dev@localhost` admin — the local-development convenience. Default
    /// FALSE: it is opt-in via the `NETLISP_DEV` env var. This must never be
    /// derived from a request header — the prod server sits behind a same-host
    /// reverse proxy, so every internet request also arrives from loopback, and
    /// a `Host: localhost` header used to grant unauthenticated admin remotely.
    dev_mode: bool = false,

    pub const WebsocketHandler = mcp.Client;

    pub fn dispatch(
        self: *Handler,
        action: *const fn (*Handler, *httpz.Request, *httpz.Response) anyerror!void,
        req: *httpz.Request,
        res: *httpz.Response,
    ) !void {
        // Hand the route handler a request-scoped view of the Handler whose
        // allocator is httpz's per-request arena (reset after the response is
        // written). Every per-request allocation — evaluator state, rendered
        // HTML, scene graphs, PNG canvases — dies with the request instead of
        // accumulating in the process allocator for the life of the server
        // (the old behaviour leaked MBs per page view until OOM). Anything
        // that must outlive the request (live versions, regen-job frames,
        // auth/oauth stores, the MCP websocket client) dupes into
        // page_allocator internally and was audited to do so.
        var req_handler = Handler{
            .allocator = res.arena,
            .project_dir = self.project_dir,
            .auth_dir = self.auth_dir,
            .dev_mode = self.dev_mode,
        };
        // Auth middleware: check before dispatching to route handler
        if (!try auth.authMiddleware(&req_handler, req, res)) return;
        try action(&req_handler, req, res);
        // gzip text responses for clients that accept it. The compressed buffer
        // lives in res.arena (dies with the request) — stateless, nothing to
        // invalidate. Biggest win for remote clients where transfer dominates.
        maybeCompress(req, res);
    }

    pub fn notFound(_: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
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
/// in the per-request arena (`res.arena`), so it dies with the request — there
/// is no cross-request state and nothing to invalidate. No-op for small bodies,
/// non-text content types, already-written/chunked responses (e.g. the MCP
/// WebSocket upgrade, event streams), or clients that don't send gzip.
fn maybeCompress(req: *httpz.Request, res: *httpz.Response) void {
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

    const compressed = deflate.gzip(res.arena, body) catch return;
    if (compressed.len >= body.len) return; // never inflate

    // Route the response through res.body and drop any writer-buffer contents,
    // since httpz prefers a non-empty buffer over res.body.
    res.buffer.writer.end = 0;
    res.body = compressed;
    res.header("Content-Encoding", "gzip");
    res.header("Vary", "Accept-Encoding");
}

/// Bring up the EDA web server on `port`: registers every page, JSON API,
/// auth, OAuth, and MCP route against an httpz instance, then blocks on
/// `server.listen()`. Project files are served out of `project_dir`; auth
/// state lives in `auth_dir` (or `<project_dir>/auth` when null).
/// The PCB-layout surface: the viewer page plus its JSON/PNG/facts APIs,
/// layout snapshot management, routing/regen, and the fab outputs
/// (centroid, drill, gerber package).
fn registerPcbRoutes(router: anytype) void {
    router.get("/pcb-layout/:name", pcb_layout_page.pcbLayoutPage, .{});
    router.get("/api/pcb-layout/:name", pcb_layout_page.pcbLayoutJsonApi, .{});
    router.get("/api/pcb-png/:name", pcb_layout_page.pcbPngApi, .{});
    router.get("/api/pcb-describe/:name", pcb_describe.pcbDescribeApi, .{});
    router.get("/api/layout-match/:name", layout_match.layoutMatchApi, .{});
    router.get("/api/rough-best/:name", rough_best.bestRoughApi, .{});
    router.get("/api/rough-best-png/:name", rough_best.bestRoughPngApi, .{});
    router.get("/api/pcb-centroid/:name", pcb_layout_page.pcbCentroidApi, .{});
    router.get("/api/pcb-drill/:name", pcb_layout_page.pcbDrillApi, .{});
    router.get("/api/fab-readiness/:name", pcb_layout_page.pcbFabReadinessApi, .{});
    router.get("/api/pcb-gerbers/:name", pcb_layout_page.pcbGerbersApi, .{});
    router.post("/api/pcb-layouts/:name", pcb_layout_page.saveNamedLayoutApi, .{});
    router.post("/api/pcb-layouts/:name/delete", pcb_layout_page.deleteNamedLayoutApi, .{});
    router.post("/api/pcb-layouts/:name/default", pcb_layout_page.setDefaultLayoutApi, .{});
    router.post("/api/pcb-rescore/:name", pcb_layout_page.rescoreLayoutsApi, .{});
    router.post("/api/pcb-score/:name", pcb_layout_page.pcbScoreApi, .{});
    router.post("/api/pcb-score-batch/:name", pcb_layout_page.pcbScoreBatchApi, .{});
    router.post("/api/pcb-route/:name", pcb_layout_page.pcbRouteApi, .{});
    router.post("/api/pcb-regen-start/:name", pcb_layout_page.pcbRegenStartApi, .{});
    router.get("/api/pcb-progress/:name", pcb_layout_page.pcbProgressApi, .{});
    router.post("/api/courtyard/:name", pcb_layout_page.savePcbCourtyardApi, .{});
}

/// Start the HTTP server: configure auth/rate limits, register every route
/// (pages, APIs, MCP, OAuth), and block serving requests until shutdown.
pub fn serve(
    allocator: std.mem.Allocator,
    port: u16,
    project_dir: []const u8,
    auth_dir: ?[]const u8,
) ServeError!void {
    // Set the CSE/DigiKey rate limits from env/.env once, before any request
    // thread can touch the limiters.
    rate_limiter.configureFromEnv(allocator);
    const effective_auth: []const u8 = if (auth_dir) |d| d else try std.fmt.allocPrint(allocator, "{s}/auth", .{project_dir});
    // Opt-in local-dev auth bypass. Off in production (no env var) → every
    // request must authenticate. See Handler.dev_mode. Read via config.zig so
    // the ban-env policy holds (only config.zig touches the environment).
    const dev_mode = @import("config.zig").devMode(allocator);
    if (dev_mode) std.debug.print("netlisp: NETLISP_DEV set — loopback requests bypass auth as dev@localhost\n", .{});
    var handler = Handler{ .allocator = allocator, .project_dir = project_dir, .auth_dir = effective_auth, .dev_mode = dev_mode };
    var server = try httpz.Server(*Handler).init(allocator, .{
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

    // Auth routes (auth middleware exempts all /auth/* paths; handlers that
    // need auth re-check the session internally)
    router.get("/auth/login", auth.loginPage, .{});
    router.get("/auth/setup", auth.setupPage, .{});
    router.get("/auth/login/challenge", auth.loginChallengePage, .{});
    router.post("/auth/login/complete", auth.loginCompletePage, .{});
    router.get("/auth/register/challenge", auth.registerChallengePage, .{});
    router.post("/auth/register/complete", auth.registerCompletePage, .{});
    router.post("/auth/logout", auth.logoutApi, .{});
    router.get("/auth/manage", account_page.manageRedirect, .{});
    router.get("/auth/credentials/list", auth.listCredentialsApi, .{});
    router.post("/auth/credentials/delete", auth.deleteCredentialApi, .{});
    router.post("/auth/invite/create", auth.createInviteApi, .{});
    router.get("/auth/invite/*", auth.invitePage, .{});
    // Pages
    router.get("/", pages.indexPage, .{});
    router.get("/style.css", pages.cssPage, .{});
    router.get("/static/:name", static_assets.staticAsset, .{});
    router.get("/schematics/:name", schematic_page.schematicPage, .{});
    // KiCad-style sheet editor (prototype): section-as-sheet canvas navigator.
    router.get("/editor/:name", editor_page.editorPage, .{});
    router.get("/api/editor-scene/:name", editor_page.editorSceneApi, .{});
    registerPcbRoutes(router);
    router.get("/modules", modules_page.modulesListPage, .{});
    router.get("/modules/:name", modules_page.moduleViewPage, .{});
    router.get("/mcp-tools", mcp_docs.mcpDocsPage, .{});
    // API
    router.post("/api/push/:name", api.pushApi, .{});
    router.get("/api/module-source", modules_page.moduleSourceApi, .{});
    router.get("/api/version/:name", api.versionApi, .{});
    router.get("/api/export-kicad/:name", api.exportKicadApi, .{});
    router.get("/api/export-netlist/:name", api.exportNetlistApi, .{});
    // File-based KiCad sync — server writes the .kicad_pcb at the
    // design's (kicad-pcb "<path>") form directly. `?dry_run=1` returns
    // the would-be ops without writing (Phase 2 — writer lands in
    // Phase 3).
    router.post("/api/sync-kicad-pcb/:name", sync.syncKicadPcbApi, .{});
    router.get("/api/export-bom/:name", api.exportBomCsvApi, .{});
    router.get("/api/export-review/:name", api.exportReviewPackageApi, .{});
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

    // Library
    router.get("/library", library.libraryPage, .{});
    // 3D model alignment viewer + its STEP stream + transform persistence.
    router.get("/library/3d/:footprint", library_3d.viewerPage, .{});
    router.get("/api/model-file/:footprint", library_3d.modelFileApi, .{});
    router.post("/api/model-transform/:footprint", library_3d.saveTransformApi, .{});

    // Upload
    router.post("/api/upload-package", upload_package.uploadPackageApi, .{});
    router.get("/api/footprint/:name", footprint_preview.footprintApi, .{});
    // Board-side twin of /api/footprint — one footprint as it exists on the
    // design's .kicad_pcb, for the sync preview's old-vs-new comparison.
    router.get("/api/board-footprint/:name", footprint_preview.boardFootprintApi, .{});
    router.post("/api/upload-zip", upload.uploadZipApi, .{});
    // Fetch a part's footprint + datasheet from Component Search Engine.
    router.post("/api/cse-fetch", library.cseFetchApi, .{});
    // Drop a zip onto a card → attach/replace its STEP 3D model; delete a card.
    router.post("/api/upload-model/:name", library.uploadModelApi, .{});
    router.post("/api/library-delete/:kind/:name", library.deleteLibraryEntryApi, .{});

    // MCP — POST /mcp is the streamable-HTTP transport Claude Code connects
    // to via its remote-MCP connector. GET /mcp upgrades to WebSocket, used
    // by local testing and the stdio bridge.
    router.post("/mcp", mcp.postApi, .{});
    router.get("/mcp", mcp.upgrade, .{});

    // OAuth 2.0 (authorization code + PKCE). Metadata endpoints let Claude
    // Code discover the token/authorize URLs per RFC 8414 / RFC 9728.
    router.get("/.well-known/oauth-authorization-server", oauth.metadataAuthServer, .{});
    router.get("/.well-known/oauth-protected-resource", oauth.metadataProtectedResource, .{});
    router.get("/oauth/authorize", oauth.authorizePage, .{});
    router.post("/oauth/authorize/approve", oauth.authorizeApprove, .{});
    router.post("/oauth/token", oauth.tokenEndpoint, .{});
    // RFC 7591 Dynamic Client Registration: lets a native app self-register
    // (loopback redirect_uri only) so users don't have to mint client_id +
    // client_secret on /account by hand. The minted client has no owner
    // email until the user signs in and approves on /oauth/authorize.
    router.post("/oauth/register", oauth.registerEndpoint, .{});

    // Account (user-facing OAuth client management)
    router.get("/account", account_page.accountPage, .{});
    router.post("/api/oauth/clients", account_page.createClientApi, .{});
    router.post("/api/oauth/clients/:id/revoke", account_page.revokeClientApi, .{});
    router.post("/api/users/role", account_page.updateUserRoleApi, .{});
    router.post("/api/users/delete", account_page.deleteUserApi, .{});

    std.debug.print("Listening on http://localhost:{d}\n", .{port});
    std.debug.print("Project: {s}\n", .{project_dir});
    try server.listen();
}
