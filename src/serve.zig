const std = @import("std");
const httpz = @import("httpz");

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
const library = @import("serve/library.zig");
const library_3d = @import("serve/library_3d.zig");
const upload = @import("serve/upload.zig");
const upload_package = @import("serve/upload_package.zig");
const upload_datasheet = @import("serve/upload_datasheet.zig");
const pdf_viewer = @import("serve/pdf_viewer.zig");
const footprint_preview = @import("serve/footprint_preview.zig");
const schematic_page = @import("serve/schematic_page.zig");
const pcb_layout_page = @import("serve/pcb_layout_page.zig");
const modules_page = @import("serve/modules.zig");
const auth = @import("serve/auth.zig");
const mcp = @import("serve/mcp.zig");
const oauth = @import("serve/oauth.zig");
const account_page = @import("serve/account_page.zig");
const static_assets = @import("serve/static_assets.zig");
const sync = @import("serve/sync.zig");
const notes = @import("serve/notes.zig");
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
    /// historic location. Override via `eda serve --auth-dir <path>` or the
    /// `EDA_AUTH_DIR` env var so multiple worktrees / project checkouts
    /// share one passkey + session store and a passkey registered in one
    /// worktree keeps working in the others.
    auth_dir: []const u8,

    pub const WebsocketHandler = mcp.Client;

    pub fn dispatch(
        self: *Handler,
        action: *const fn (*Handler, *httpz.Request, *httpz.Response) anyerror!void,
        req: *httpz.Request,
        res: *httpz.Response,
    ) !void {
        // Auth middleware: check before dispatching to route handler
        if (!try auth.authMiddleware(self, req, res)) return;
        return action(self, req, res);
    }

    pub fn notFound(_: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
        res.status = 404;
        res.body = "Not found";
    }
};

/// Bring up the EDA web server on `port`: registers every page, JSON API,
/// auth, OAuth, and MCP route against an httpz instance, then blocks on
/// `server.listen()`. Project files are served out of `project_dir`; auth
/// state lives in `auth_dir` (or `<project_dir>/auth` when null).
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
    var handler = Handler{ .allocator = allocator, .project_dir = project_dir, .auth_dir = effective_auth };
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
    router.post("/auth/password/login", auth.passwordLoginApi, .{});
    router.post("/auth/password/set", auth.passwordSetApi, .{});
    router.get("/auth/password/status", auth.passwordStatusApi, .{});

    // Pages
    router.get("/", pages.indexPage, .{});
    router.get("/style.css", pages.cssPage, .{});
    router.get("/static/:name", static_assets.staticAsset, .{});
    router.get("/schematics/:name", schematic_page.schematicPage, .{});
    router.get("/pcb-layout/:name", pcb_layout_page.pcbLayoutPage, .{});
    router.get("/api/pcb-layout/:name", pcb_layout_page.pcbLayoutJsonApi, .{});
    router.post("/api/pcb-layouts/:name", pcb_layout_page.saveNamedLayoutApi, .{});
    router.post("/api/pcb-layouts/:name/delete", pcb_layout_page.deleteNamedLayoutApi, .{});
    router.post("/api/pcb-rescore/:name", pcb_layout_page.rescoreLayoutsApi, .{});
    router.post("/api/pcb-score/:name", pcb_layout_page.pcbScoreApi, .{});
    router.post("/api/pcb-score-batch/:name", pcb_layout_page.pcbScoreBatchApi, .{});
    router.post("/api/pcb-route/:name", pcb_layout_page.pcbRouteApi, .{});
    router.post("/api/courtyard/:name", pcb_layout_page.savePcbCourtyardApi, .{});
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
    router.get("/api/review/:name", api.reviewJsonApi, .{});
    router.post("/api/section-note/:name/add", api.addSectionNoteApi, .{});
    router.post("/api/section-note/:name/remove", api.removeSectionNoteApi, .{});
    router.post("/api/component-datasheet/:component/add", api.addComponentDatasheetApi, .{});
    router.post("/api/component-datasheet/:component/remove", api.removeComponentDatasheetApi, .{});
    router.get("/api/designs", api.designsApi, .{});
    router.get("/api/scene-graph/:name", api.sceneGraphApi, .{});
    router.get("/api/pinout/:name", api.pinoutApi, .{});
    router.post("/api/upload-datasheet", upload_datasheet.uploadDatasheetApi, .{});
    router.get("/api/datasheets", upload_datasheet.listDatasheetsApi, .{});
    router.get("/datasheets/:filename", upload_datasheet.serveDatasheetApi, .{});
    router.get("/pdf-view/:filename", pdf_viewer.pdfViewerPage, .{});

    // Edit
    router.post("/api/edit-value/:name", edit.editValueApi, .{});
    router.post("/api/edit-mpn/:name", edit.editMpnApi, .{});
    router.post("/api/edit-footprint/:name", edit.editFootprintApi, .{});
    router.post("/api/add-instance/:name", edit.addInstanceApi, .{});
    router.post("/api/remove-instance/:name", edit.removeInstanceApi, .{});
    router.post("/api/rewire-pin/:name", edit.rewirePinApi, .{});
    router.post("/api/move-pin/:name", edit.movePinApi, .{});
    router.post("/api/swap-pins/:name", edit.swapPinsApi, .{});
    router.get("/api/free-pins/:name", api.freePinsApi, .{});
    router.get("/api/design-state/:name", api.designStateApi, .{});
    router.get("/api/source/:name", edit.getSourceApi, .{});
    router.post("/api/source/:name", edit.saveSourceApi, .{});
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
