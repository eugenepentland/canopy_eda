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

// ── Global live state ──────────────────────────────────────────────────

pub var live_mutex: std.Thread.Mutex = .{};
pub var live_version: u32 = 0;
pub var live_svg: ?[]const u8 = null;

// ── Layout storage (in-memory) ─────────────────────────────────────────

pub var layout_mutex: std.Thread.Mutex = .{};
pub var layout_data: ?[]const u8 = null;

// ── Server ─────────────────────────────────────────────────────────────

pub const Handler = struct {
    allocator: std.mem.Allocator,
    project_dir: []const u8,

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
            .max_body_size = 10 * 1024 * 1024,
            .buffer_size = 256 * 1024,
            .max_header_count = 64,
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
    router.get("/schematics/:name", pages.designPage, .{});

    // API
    router.post("/api/push/:name", api.pushApi, .{});
    router.get("/api/version/:name", api.versionApi, .{});
    router.get("/api/svg/:name", api.svgApi, .{});
    router.get("/schematics/:name/layout", api.layoutGetApi, .{});
    router.post("/schematics/:name/layout", api.layoutPostApi, .{});
    router.get("/api/export-kicad/:name", api.exportKicadApi, .{});
    router.get("/api/export-netlist/:name", api.exportNetlistApi, .{});
    router.post("/api/update-pcb/:name", api.updatePcbApi, .{});
    router.get("/api/block-diagram/:name", api.blockDiagramApi, .{});

    // Edit
    router.post("/api/edit-value/:name", edit.editValueApi, .{});
    router.post("/api/edit-footprint/:name", edit.editFootprintApi, .{});

    // Library
    router.get("/library", library.libraryPage, .{});

    // Upload
    router.post("/api/upload-package", upload_package.uploadPackageApi, .{});
    router.get("/api/footprint/:name", footprint_preview.footprintSvgApi, .{});
    router.post("/api/upload-zip", upload.uploadZipApi, .{});

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
