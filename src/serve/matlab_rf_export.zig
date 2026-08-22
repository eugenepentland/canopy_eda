//! HTTP handoff for the MATLAB R2022b RF PCB simulation bundle.

const std = @import("std");
const httpz = @import("httpz");
const build_id = @import("../build_id.zig");
const clock = @import("../infra/clock.zig");
const export_gerber = @import("../export_gerber.zig");
const export_matlab_rf = @import("../export_matlab_rf.zig");
const serve_root = @import("../serve.zig");
const pcb_layout_page = @import("pcb_layout_page.zig");

const Server = serve_root.Server;
const HandlerError = pcb_layout_page.HandlerError;

/// GET /api/pcb-matlab-rf/:name — export the named saved layout's CAL_THRU
/// route as the validated four-layer MATLAB RF PCB Toolbox ZIP.
pub fn pcbMatlabRfApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = pcb_layout_page.nameParam(req, res) orelse return;
    const layout = pcb_layout_page.queryOpt(req, "layout");
    const source = pcb_layout_page.fabViewFor(req.arena, ctx.project_dir, name, layout) catch |e| {
        res.status = if (e == error.PlacementFailed) 500 else 404;
        res.body = switch (e) {
            error.BlockNotFound => "No design or module by that name",
            error.UnknownLayout => "No saved layout by that name",
            error.NoSavedLayout => "no saved layout — place the board (and save/star a layout) first",
            error.PlacementFailed => "Placement error",
        };
        return;
    };
    const stamped = try export_gerber.creationDate(req.arena, clock.timestamp());
    const artifact = export_matlab_rf.build(req.arena, .{
        .project_name = name,
        .revision = if (source.authored.revision.present) source.authored.revision.id else "",
        .generator = .{
            .generated_utc = stamped,
            .application_version = build_id.current(),
        },
        .net_name = pcb_layout_page.queryOpt(req, "net") orelse export_matlab_rf.default_net,
        .placement = source.placement,
        .copper = .{
            .tracks = source.routed.tracks,
            .arcs = source.routed.arcs,
            .rf_paths = source.routed.rf_port_outcomes,
            .vias = source.routed.vias,
        },
        .stackup = source.authored.stackup,
    }) catch |e| {
        res.status = switch (e) {
            error.OutOfMemory, error.WriteFailed, error.EmptyImage => 500,
            else => 422,
        };
        res.header("content-type", "text/plain; charset=utf-8");
        res.body = export_matlab_rf.errorMessage(e);
        return;
    };
    res.header("content-type", "application/zip");
    res.header("content-disposition", try std.fmt.allocPrint(req.arena, "attachment; filename=\"{s}\"", .{artifact.filename}));
    res.body = artifact.zip;
}
