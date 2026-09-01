//! `POST /api/design-archive/:name` — one revision-locked engineering handoff.
//!
//! The ordinary fabrication service remains the authority: readiness,
//! confirmation, waivers and the resulting board-house ZIP are byte-identical
//! to `/api/pcb-gerbers`. The outer archive then adds the offline schematic,
//! source/layout tree, KiCad project, used datasheets, and the full-board STEP
//! recipe posted by the PCB 3D viewer.

const std = @import("std");
const httpz = @import("httpz");

const bom = @import("../bom.zig");
const design_archive = @import("../design_archive.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const export_fab = @import("../export_fab.zig");
const fab_release = @import("../fab_release.zig");
const infra_fs = @import("../infra/fs.zig");
const paths = @import("../paths.zig");
const render_html = @import("../render_html.zig");
const review = @import("../review.zig");
const zipfile = @import("../zipfile.zig");
const assets_css = @import("assets_css.zig");
const fab_service = @import("fab_release_service.zig");
const mcp_tools = @import("mcp_tools.zig");
const pcb_step_export = @import("pcb_step_export.zig");
const system_review_api = @import("system_review_api.zig");
const serve_root = @import("../serve.zig");
const Server = serve_root.Server;

pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error;

fn queryValue(req: *httpz.Request, key: []const u8) ?[]const u8 {
    const query = req.query() catch return null;
    return query.get(key);
}

fn queryFlag(req: *httpz.Request, key: []const u8) bool {
    const value = queryValue(req, key) orelse return false;
    return std.mem.eql(u8, value, "1") or std.ascii.eqlIgnoreCase(value, "true");
}

fn options(req: *httpz.Request, accept_waivers: bool) fab_service.Options {
    return .{
        .layout = queryValue(req, "layout"),
        .dnp = if (queryValue(req, "dnp")) |value|
            (if (std.ascii.eqlIgnoreCase(value, "keep")) .keep else .drop)
        else
            .drop,
        .accept_waivers = accept_waivers,
    };
}

fn serviceFailure(res: *httpz.Response, err: anyerror) void {
    res.status = switch (err) {
        error.BoardNotFound, error.LayoutNotFound, error.NoSavedLayout => 404,
        error.ReleaseBlocked => 500,
        error.WaiverRequired, error.InputsChanged => 428,
        error.BoardReleaseTooLarge => 413,
        else => 500,
    };
    res.content_type = .TEXT;
    res.body = switch (res.status) {
        404 => "design or saved layout not found",
        413 => "design archive is too large",
        428 => "design changed or release waiver is required; run readiness again",
        else => "design archive export failed",
    };
}

fn snapshotStable(before: fab_release.ProjectState, after: fab_release.ProjectState) bool {
    return before.status == .clean and after.status == .clean and std.mem.eql(u8, before.commit, after.commit);
}

fn releaseBaselineMatches(
    released: fab_service.Result,
    project: fab_release.ProjectState,
    layout: [64]u8,
    bom_evidence: [64]u8,
) bool {
    if (!std.mem.eql(u8, project.commit, released.lock.project_commit)) return false;
    if (!std.mem.eql(u8, &layout, &released.digests.layout)) return false;
    return std.mem.eql(u8, &bom_evidence, &released.digests.bom_evidence);
}

/// Build the full archive only after the caller confirms the exact ordinary
/// fab-readiness token. The posted body is the 3D viewer's STEP recipe.
pub fn designArchiveApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const body = req.body() orelse {
        res.status = 400;
        res.body = "missing full-board STEP export data";
        return;
    };

    const ready = fab_service.readiness(req.arena, ctx.project_dir, name, options(req, false)) catch |err| {
        serviceFailure(res, err);
        return;
    };
    res.header("cache-control", "no-store");
    if (ready.readiness.blocked) {
        res.status = 500;
        res.content_type = .JSON;
        res.body = ready.readiness.json;
        return;
    }
    const confirmed = if (queryValue(req, "confirm")) |token|
        std.mem.eql(u8, token, &ready.lock.release_token)
    else
        false;
    const waived = queryFlag(req, "waive");
    const waiver_missing = ready.readiness.needs_waiver and !waived;
    if (!confirmed or waiver_missing) {
        res.status = 428;
        res.content_type = .JSON;
        res.body = ready.readiness.json;
        return;
    }

    var assembly_context = system_review_api.AssemblyRenderContext{ .ctx = ctx, .req = req };
    const released = fab_service.release(
        req.arena,
        ctx.project_dir,
        name,
        options(req, waived),
        .{ .context = &assembly_context, .render = system_review_api.renderAssembly },
    ) catch |err| {
        serviceFailure(res, err);
        return;
    };
    const fab_zip = released.zip orelse {
        res.status = 500;
        res.body = "fabrication package was not composed";
        return;
    };

    const project_before = fab_release.captureProjectState(req.arena, ctx.project_dir) catch |err| {
        serviceFailure(res, err);
        return;
    };
    defer req.arena.free(project_before.commit);
    const layout_before = try fab_release.savedLayoutDigest(req.arena, ctx.project_dir, name);
    const bom_before = try fab_release.savedBomDigest(req.arena, ctx.project_dir, name);
    if (project_before.status != .clean or !releaseBaselineMatches(released, project_before, layout_before, bom_before)) {
        res.status = 428;
        res.body = "design inputs changed after the fabrication package was composed; run readiness again";
        return;
    }
    var trace = infra_fs.ReadTrace.init(req.arena);
    defer trace.deinit();
    trace.begin();

    var evaluator = Evaluator.init(req.arena, ctx.project_dir);
    defer evaluator.deinit();
    const named = mcp_tools.evalNamedBlock(req.arena, ctx.project_dir, name, &evaluator) catch |err| {
        trace.end();
        serviceFailure(res, err);
        return;
    };
    if (!named.is_module) {
        const bom_path = paths.designSiblingPath(req.arena, ctx.project_dir, name, ".bom") catch null;
        if (bom_path) |path| {
            defer req.arena.free(path);
            bom.resolveIdentities(req.arena, named.block, path, ctx.project_dir) catch |err| {
                trace.end();
                serviceFailure(res, err);
                return;
            };
        }
    }
    const board_step = pcb_step_export.buildFromJson(req.arena, ctx.project_dir, name, body) catch |err| {
        trace.end();
        res.status = switch (err) {
            error.MissingModel => 404,
            error.ModelLimit => 413,
            else => 400,
        };
        res.body = try std.fmt.allocPrint(req.arena, "full-board STEP export failed: {s}", .{@errorName(err)});
        return;
    };
    var empty_checks = render_html.CheckResultMap.empty;
    defer empty_checks.deinit(req.arena);
    const schematic_html = render_html.renderToHtml(
        req.arena,
        named.block,
        ctx.project_dir,
        name,
        assets_css.navbar_css,
        if (ready.readiness.needs_waiver) review.Status.warn else review.Status.pass,
        null,
        &empty_checks,
        .{ .path = "/schematics/", .offline = true },
    ) catch |err| {
        trace.end();
        res.status = 500;
        res.body = try std.fmt.allocPrint(req.arena, "schematic HTML export failed: {s}", .{@errorName(err)});
        return;
    };

    var pkg = export_fab.Package{ .arena = req.arena, .prefix = name };
    try pkg.addNamed("fabrication/board-release.zip", fab_zip);
    var displayed_id = released.lock.fab_id;
    _ = std.ascii.upperString(&displayed_id, &released.lock.fab_id);
    design_archive.append(req.arena, &pkg, .{
        .project_dir = ctx.project_dir,
        .name = name,
        .block = named.block,
        .evaluator = &evaluator,
        .schematic_html = schematic_html,
        .board_step = board_step,
        .fab_id = &displayed_id,
    }) catch |err| {
        trace.end();
        res.status = 500;
        res.body = try std.fmt.allocPrint(req.arena, "design archive export failed: {s}", .{@errorName(err)});
        return;
    };
    trace.end();

    const project_after = fab_release.captureProjectState(req.arena, ctx.project_dir) catch |err| {
        serviceFailure(res, err);
        return;
    };
    defer req.arena.free(project_after.commit);
    const layout_after = try fab_release.savedLayoutDigest(req.arena, ctx.project_dir, name);
    const bom_after = try fab_release.savedBomDigest(req.arena, ctx.project_dir, name);
    const baseline_held = releaseBaselineMatches(released, project_after, layout_after, bom_after);
    for ([_]bool{ snapshotStable(project_before, project_after), baseline_held, trace.verify() }) |held| {
        if (!held) {
            res.status = 428;
            res.content_type = .TEXT;
            res.body = "design inputs changed while the archive was being composed; run readiness again";
            return;
        }
    }

    var output: std.Io.Writer.Allocating = .init(req.arena);
    try zipfile.write(&output.writer, pkg.entries.items);
    const revision = try fab_release.safeRevision(req.arena, released.identity.revision);
    res.header("content-type", "application/zip");
    res.header("x-pcb-fab-id", try req.arena.dupe(u8, &released.lock.fab_id));
    res.header("content-disposition", try std.fmt.allocPrint(
        req.arena,
        "attachment; filename=\"{s}-rev-{s}-{s}-design-archive.zip\"",
        .{ name, revision, &released.lock.fab_id },
    ));
    res.body = output.written();
}

test "archive snapshot requires one unchanged clean project revision" {
    const clean = fab_release.ProjectState{ .commit = "abc", .status = .clean };
    try std.testing.expect(snapshotStable(clean, .{ .commit = "abc", .status = .clean }));
    try std.testing.expect(!snapshotStable(clean, .{ .commit = "def", .status = .clean }));
    try std.testing.expect(!snapshotStable(clean, .{ .commit = "abc", .status = .dirty }));
}
