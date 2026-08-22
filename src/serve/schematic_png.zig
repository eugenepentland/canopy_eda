//! `GET /api/schematic-png/:name` — browser-free PNG export of one schematic
//! block. The HTTP handler is a thin name/query adapter over
//! `render_schematic_png`, shared in behavior with the MCP image tool and CLI.

const std = @import("std");
const httpz = @import("httpz");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const renderer = @import("../render_schematic_png.zig");
const mcp_tools = @import("mcp_tools.zig");
const serve_root = @import("../serve.zig");
const Server = serve_root.Server;

/// Request-local allocation or response-writer failure.
pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error;

fn optionsFromQuery(req: *httpz.Request) renderer.Options {
    const query = req.query() catch return .{};
    const width = if (query.get("width")) |raw|
        std.fmt.parseInt(u32, raw, 10) catch 1600
    else
        1600;
    return .{
        .width = std.math.clamp(width, 320, 4000),
        .view = renderer.parseView(query.get("view")),
        .theme = renderer.parseTheme(query.get("theme")),
        .sub = query.get("sub"),
        .ref = query.get("ref"),
    };
}

/// GET /api/schematic-png/:name?sub=<slug>|ref=<hub>&view=functional|sequential
/// Returns the same native image content as `get_schematic_image`; `width` is
/// clamped to 320…4000 and `theme=light` selects the print palette.
pub fn schematicPngApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    var eval = Evaluator.init(req.arena, ctx.project_dir);
    defer eval.deinit();
    const named = mcp_tools.evalNamedBlock(req.arena, ctx.project_dir, name, &eval) catch |err| {
        res.status = if (err == error.FileNotFound) 404 else 422;
        res.body = @errorName(err);
        return;
    };
    const bytes = renderer.render(req.arena, named.block, ctx.project_dir, optionsFromQuery(req)) catch |err| {
        res.status = switch (err) {
            error.SubNotFound, error.RefNotFound => 404,
            error.TargetConflict, error.TooManyBlocks => 400,
            else => 422,
        };
        res.body = renderer.errorMessage(err);
        return;
    };
    res.content_type = .PNG;
    res.header("Cache-Control", "no-store");
    res.body = bytes;
}
