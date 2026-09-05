//! Package builder page and thin JSON operation adapters.
const std = @import("std");
const httpz = @import("httpz");
const Server = @import("../serve.zig").Server;
const service = @import("package_tools.zig");
const navbar = @import("navbar.zig");
const autocommit = @import("autocommit.zig");
pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error;

/// GET /library/package — create a package or load ?name= from the library.
pub fn page(_: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    var out: std.Io.Writer.Allocating = .init(req.arena);
    try out.writer.writeAll("<!doctype html><html><head><meta charset=\"utf-8\"><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\"><title>IC Package Builder</title><style>");
    try out.writer.writeAll(navbar.css);
    try out.writer.writeAll(@embedFile("assets/package_builder.css"));
    try out.writer.writeAll("</style></head><body>");
    try navbar.write(&out.writer, .library);
    try out.writer.writeAll(@embedFile("assets/package_builder.html"));
    res.content_type = .HTML;
    res.body = out.written();
}

/// POST /api/packages/:operation — use the same recipe and results as structured tools.
pub fn api(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    res.content_type = .JSON;
    const action = req.param("operation") orelse "";
    const operation = if (std.mem.eql(u8, action, "export")) service.Operation.export_asset else std.meta.stringToEnum(service.Operation, action) orelse {
        res.status = 404;
        res.body = "{\"ok\":false,\"error_message\":\"Unknown package operation\"}";
        return;
    };
    const body = req.body() orelse "{}";
    if (body.len > 512 * 1024) {
        res.status = 413;
        res.body = "{\"ok\":false,\"error_message\":\"Recipe is too large\"}";
        return;
    }
    const args = std.json.parseFromSliceLeaky(std.json.Value, req.arena, body, .{}) catch {
        res.status = 400;
        res.body = "{\"ok\":false,\"error_message\":\"Invalid JSON\"}";
        return;
    };
    var session = if (operation == .save) autocommit.begin(req.arena, ctx.project_dir) else null;
    defer if (session) |*s| s.deinit();
    res.body = service.execute(req.arena, ctx.project_dir, operation, args) catch |err| {
        res.status = switch (err) {
            error.RevisionConflict, error.RevisionRequired, error.GeneratedAssetChanged, error.NameAlreadyExists => 409,
            error.FileNotFound => 404,
            else => 400,
        };
        res.body = try std.json.Stringify.valueAlloc(req.arena, .{ .ok = false, .error_code = @errorName(err), .error_message = service.message(err) }, .{});
        return;
    };
    if (operation == .save) {
        const result = std.json.parseFromSliceLeaky(std.json.Value, req.arena, res.body, .{}) catch {
            res.status = 500;
            return;
        };
        if (result.object.get("ok")) |ok| if (ok == .bool and ok.bool) autocommit.commit(session, null, "package_save");
    }
}
