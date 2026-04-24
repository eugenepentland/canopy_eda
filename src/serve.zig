const std = @import("std");
const httpz = @import("httpz");

// Sub-modules
const pages = @import("serve/pages.zig");
const api = @import("serve/api.zig");
const edit = @import("serve/edit.zig");
const library = @import("serve/library.zig");
const upload = @import("serve/upload.zig");
const upload_package = @import("serve/upload_package.zig");
const footprint_preview = @import("serve/footprint_preview.zig");
const model = @import("serve/model.zig");
const schematic_page = @import("serve/schematic_page.zig");
const canvas_page = @import("serve/canvas_page.zig");
const pcb_page = @import("serve/pcb_page.zig");
const auth = @import("serve/auth.zig");
const mcp = @import("serve/mcp.zig");
const oauth = @import("serve/oauth.zig");
const account_page = @import("serve/account_page.zig");
const kicad_sync = @import("serve/kicad_sync.zig");
const sync = @import("serve/sync.zig");
const spa_shell = @import("serve/spa_shell.zig");
const spa_bundle = @import("serve/spa_bundle.zig");

// ── Global live state ──────────────────────────────────────────────────

pub var live_mutex: std.Thread.Mutex = .{};
pub var live_layout_json: ?[]const u8 = null;

/// Replace the cached live scene-graph JSON. The incoming slice may come from
/// a request-scoped arena (e.g. MCP tool dispatch) so it must be duplicated
/// into page_allocator memory that outlives the caller. The previous value,
/// if any, is freed.
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

// ── Layout storage (in-memory) ─────────────────────────────────────────

pub var layout_mutex: std.Thread.Mutex = .{};
pub var layout_data: ?[]const u8 = null;

// ── Server ─────────────────────────────────────────────────────────────

pub const Handler = struct {
    allocator: std.mem.Allocator,
    project_dir: []const u8,

    pub const WebsocketHandler = mcp.Client;

    pub fn dispatch(self: *Handler, action: *const fn (*Handler, *httpz.Request, *httpz.Response) anyerror!void, req: *httpz.Request, res: *httpz.Response) !void {
        // Auth middleware: check before dispatching to route handler
        if (!try auth.authMiddleware(self, req, res)) return;
        return action(self, req, res);
    }

    pub fn notFound(_: *Handler, _: *httpz.Request, res: *httpz.Response) !void {
        res.status = 404;
        res.body = "Not found";
    }
};

pub fn serve(allocator: std.mem.Allocator, port: u16, project_dir: []const u8) !void {
    var handler = Handler{ .allocator = allocator, .project_dir = project_dir };
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

    // Lustre SPA (v2) — single-page app served under /v2/*. The bundle is
    // produced by `make -C frontend build` and embedded into the Zig binary.
    router.get("/v2/spa.js", spa_bundle.jsApi, .{});
    router.get("/v2/spa.css", spa_bundle.cssApi, .{});
    router.get("/v2", spa_shell.shellApi, .{});
    router.get("/v2/*", spa_shell.shellApi, .{});

    // Pages
    router.get("/", pages.indexPage, .{});
    router.get("/style.css", pages.cssPage, .{});
    router.get("/schematics/:name", schematic_page.schematicPage, .{});
    // Legacy Pixi.js canvas kept alongside the new HTML view while the HTML
    // version catches up on editing / search / pin-move parity.
    router.get("/schematics/:name/canvas", canvas_page.canvasPage, .{});
    router.get("/pcb/:name", pcb_page.pcbPage, .{});
    router.get("/review/:name", api.reviewPage, .{});

    // API
    router.post("/api/push/:name", api.pushApi, .{});
    router.get("/api/version/:name", api.versionApi, .{});
    router.get("/schematics/:name/layout", api.layoutGetApi, .{});
    router.post("/schematics/:name/layout", api.layoutPostApi, .{});
    router.get("/api/export-kicad/:name", api.exportKicadApi, .{});
    router.get("/api/export-netlist/:name", api.exportNetlistApi, .{});
    // Incremental sync (content-addressed) for the KiCad plugin.
    router.get("/api/sync-manifest/:name", sync.syncManifestApi, .{});
    router.get("/api/netlist/:name", sync.netlistApi, .{});
    router.get("/api/object/:sha", sync.objectApi, .{});
    router.get("/api/kicad-sync-config/:name", kicad_sync.getConfigApi, .{});
    router.post("/api/kicad-sync-config/:name", kicad_sync.setConfigApi, .{});
    router.post("/api/export-netlist-to-dir/:name", kicad_sync.writeNetlistApi, .{});
    router.post("/api/export-kicad-to-dir/:name", kicad_sync.writeKicadApi, .{});
    router.post("/api/update-kicad-pcb/:name", kicad_sync.writePcbApi, .{});
    router.get("/api/export-bom/:name", api.exportBomCsvApi, .{});
    router.get("/api/export-gerber/:name", api.exportGerberApi, .{});
    router.post("/api/update-pcb/:name", api.updatePcbApi, .{});
    router.post("/api/pcb-placement/:name", api.pcbPlacementApi, .{});
    router.post("/api/pcb-routing/:name", api.pcbRoutingApi, .{});
    router.post("/api/pcb-rules/:name", api.pcbRulesApi, .{});
    router.post("/api/zone-fill/:name", api.zoneFillApi, .{});
    router.get("/api/drc/:name", api.drcApi, .{});
    router.get("/api/erc/:name", api.ercApi, .{});
    router.get("/api/review/:name", api.reviewJsonApi, .{});
    router.get("/api/review-state/:name", api.reviewStateGetApi, .{});
    router.post("/api/review-state/:name/item", api.reviewStateAddItemApi, .{});
    router.post("/api/review-state/:name/item/toggle", api.reviewStateToggleItemApi, .{});
    router.post("/api/review-state/:name/item/delete", api.reviewStateDeleteItemApi, .{});
    router.post("/api/review-state/:name/approve", api.reviewStateApproveApi, .{});
    router.get("/api/designs", api.designsApi, .{});
    router.get("/api/scene-graph/:name", api.sceneGraphApi, .{});
    router.get("/api/block-diagram-json/:name", api.blockDiagramJsonApi, .{});
    router.get("/api/pinout/:name", api.pinoutApi, .{});
    router.get("/api/datasheet/:name", api.datasheetGetApi, .{});
    router.post("/api/datasheet/:name", api.datasheetUploadApi, .{});

    // Edit
    router.post("/api/edit-value/:name", edit.editValueApi, .{});
    router.post("/api/edit-footprint/:name", edit.editFootprintApi, .{});
    router.post("/api/edit-courtyard", edit.editCourtyardApi, .{});
    router.post("/api/add-instance/:name", edit.addInstanceApi, .{});
    router.post("/api/remove-instance/:name", edit.removeInstanceApi, .{});
    router.post("/api/rewire-pin/:name", edit.rewirePinApi, .{});
    router.post("/api/move-pin/:name", edit.movePinApi, .{});
    router.post("/api/swap-pins/:name", edit.swapPinsApi, .{});
    router.get("/api/free-pins/:name", api.freePinsApi, .{});
    router.get("/api/design-state/:name", api.designStateApi, .{});
    router.post("/api/board-outline/:name", edit.boardOutlineApi, .{});
    router.get("/api/source/:name", edit.getSourceApi, .{});
    router.post("/api/source/:name", edit.saveSourceApi, .{});

    // Library
    router.get("/library", library.libraryPage, .{});

    // Upload
    router.post("/api/upload-package", upload_package.uploadPackageApi, .{});
    router.get("/api/footprint/:name", footprint_preview.footprintSvgApi, .{});
    router.post("/api/upload-zip", upload.uploadZipApi, .{});

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

    // Account (user-facing OAuth client management)
    router.get("/account", account_page.accountPage, .{});
    router.post("/api/oauth/clients", account_page.createClientApi, .{});
    router.post("/api/oauth/clients/:id/revoke", account_page.revokeClientApi, .{});
    router.post("/api/users/role", account_page.updateUserRoleApi, .{});
    router.post("/api/users/delete", account_page.deleteUserApi, .{});

    // Model
    router.get("/model-viewer/:name", model.modelViewerPage, .{});
    router.get("/api/model/:name", model.modelFileApi, .{});
    router.get("/api/model-config", model.modelConfigGetApi, .{});
    router.post("/api/model-config", model.modelConfigPostApi, .{});
    router.post("/api/upload-model/:name", model.uploadModelApi, .{});

    std.debug.print("Listening on http://localhost:{d}\n", .{port});
    std.debug.print("Project: {s}\n", .{project_dir});
    try server.listen();
}
