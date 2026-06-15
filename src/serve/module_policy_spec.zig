//! GET /api/module-policy/:name — reverse-engineer an editable `(module-policy …)`
//! block from the detected layout policy, the reverse of the override consumption
//! in `placement/module_policy.zig`. The detector reads the board (module classes,
//! criticality net classes); this endpoint turns that reading back into the
//! declarative form so an author can paste it, correct a misread net or hub, and
//! commit it. Same placement-selection logic and query parameters as
//! /api/pcb-png (`layout=`, `regen=1`, `sub=`), so the export describes exactly
//! the board the image shows. `?format=sexp` returns the bare block text.
//! Phase 4 of the module-placement ruleset.

const std = @import("std");
const httpz = @import("httpz");
const module_policy = @import("../placement/module_policy.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const modules_mod = @import("modules.zig");
const pcb_layout_page = @import("pcb_layout_page.zig");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;

/// The two render forms returned by `exportPolicy`: the bare s-expression block
/// and a JSON wrapper carrying the design name, title, and provenance.
pub const ExportedPolicy = struct { json: []const u8, sexp: []const u8 };

/// GET /api/module-policy/:name — accepts the same query parameters as
/// /api/pcb-png (layout=, regen=, sub=) plus `format=sexp`.
pub fn modulePolicyApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) pcb_layout_page.HandlerError!void {
    const arena = req.arena;
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    const opts = pcb_layout_page.pngRequestFromQuery(arena, req);
    const result = exportPolicy(arena, ctx.project_dir, name, opts) catch |e| {
        res.status = if (e == error.BlockNotFound or e == error.SubNotFound) 404 else 500;
        res.body = "{\"error\":\"module-policy export failed\"}";
        return;
    };
    const want_sexp = blk: {
        const q = req.query() catch break :blk false;
        const v = q.get("format") orelse break :blk false;
        break :blk std.mem.eql(u8, v, "sexp");
    };
    if (want_sexp) {
        res.content_type = .TEXT;
        res.body = result.sexp;
        return;
    }
    res.content_type = .JSON;
    res.body = result.json;
}

/// Solve the design (honoring layout=/regen=/sub=), render the detected policy as
/// a `(module-policy …)` block, and wrap it in JSON. An empty block (nothing
/// criticality-bearing to pin) yields `spec:""` — a legitimate result, not an
/// error. Split from the handler so it's reusable (the MCP `export_module_policy`
/// tool calls it).
pub fn exportPolicy(
    alloc: std.mem.Allocator,
    project_dir: []const u8,
    name: []const u8,
    opts: pcb_layout_page.PngRequest,
) pcb_layout_page.PngError!ExportedPolicy {
    var eval = Evaluator.init(alloc, project_dir);
    defer eval.deinit();
    var module_res: ?modules_mod.ResolvedBlock = null;
    defer if (module_res) |mr| {
        mr.eval.deinit();
        alloc.destroy(mr.eval);
    };
    const solved = try pcb_layout_page.solveForRequest(alloc, project_dir, name, opts, &eval, &module_res);
    const sexp = (module_policy.exportText(alloc, solved.placement) catch return error.BuildFailed) orelse "";

    const source: []const u8 = if (opts.layout) |ln|
        std.fmt.allocPrint(alloc, "saved:{s}", .{ln}) catch return error.BuildFailed
    else if (solved.spec_status != null)
        "spec"
    else if (opts.regen)
        "regen"
    else
        "auto";

    var aw: std.Io.Writer.Allocating = .init(alloc);
    const w = &aw.writer;
    w.writeAll("{\"name\":") catch return error.BuildFailed;
    pcb_layout_page.writeJsonStr(w, name) catch return error.BuildFailed;
    w.writeAll(",\"title\":") catch return error.BuildFailed;
    pcb_layout_page.writeJsonStr(w, solved.title) catch return error.BuildFailed;
    w.writeAll(",\"source\":") catch return error.BuildFailed;
    pcb_layout_page.writeJsonStr(w, source) catch return error.BuildFailed;
    w.writeAll(",\"spec\":") catch return error.BuildFailed;
    pcb_layout_page.writeJsonStr(w, sexp) catch return error.BuildFailed;
    w.writeAll("}") catch return error.BuildFailed;
    return .{ .json = aw.written(), .sexp = sexp };
}
