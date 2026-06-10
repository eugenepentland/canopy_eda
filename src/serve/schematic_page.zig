const std = @import("std");
const httpz = @import("httpz");
const log = @import("../infra/log.zig");
const paths = @import("../paths.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const env_mod = @import("../eval/env.zig");
const erc_mod = @import("../erc.zig");
const bom = @import("../bom.zig");
const render_html = @import("../render_html.zig");
const review = @import("../review.zig");
const req_checks = @import("../req_checks.zig");
const assets_css = @import("assets_css.zig");
const diag_format = @import("diag_format.zig");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;

/// Error set for HTTP handlers in this module.
pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error;

/// GET /schematics/:name — HTML schematic page. Evaluates the design, runs
/// ERC for the status banner, then hands off to render_html.renderToHtml.
pub fn schematicPage(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };

    const board_path = try paths.designSourcePath(ctx.allocator, ctx.project_dir, name);
    defer ctx.allocator.free(board_path);

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();

    const result = eval.evalFile(board_path) catch |e| {
        // Render a proper diagnostic panel — file:line:col, the evaluator's
        // message, and the offending source line with a caret — instead of a
        // bare "Build error" string.
        const d = try diag_format.load(ctx.allocator, board_path, @errorName(e), eval.last_error);
        res.status = 500;
        res.content_type = .HTML;
        res.body = try diag_format.renderErrorPage(ctx.allocator, name, d);
        return;
    };

    const block: *env_mod.DesignBlock = switch (result) {
        .design_block => |b| b,
        else => {
            res.status = 500;
            res.body = "Not a design block";
            return;
        },
    };

    const bom_path = paths.designSiblingPath(ctx.allocator, ctx.project_dir, name, ".bom") catch {
        res.status = 500;
        return;
    };
    defer ctx.allocator.free(bom_path);
    bom.resolveIdentities(ctx.allocator, block, bom_path, ctx.project_dir) catch |e| {
        log.warn("resolveIdentities {s} failed: {s}", .{ name, @errorName(e) });
    };

    const violations = erc_mod.runErc(ctx.allocator, block, ctx.project_dir) catch &[_]erc_mod.Violation{};
    const status = computeStatus(violations, eval.assertions.items);

    // Run the requirement-attached (check ...) primitives once per design
    // load so the per-hub dropdown can show ✓/✗ next to each library-
    // declared rule. Keyed by ref_des; same-order alignment with
    // `inst.requirements`. Computed before buildReview so verified-status
    // surfaces in the embedded review JSON too.
    var check_results = req_checks.runChecks(ctx.allocator, &eval, block) catch blk: {
        break :blk std.StringHashMapUnmanaged([]req_checks.Result).empty;
    };
    req_checks.applyVerifications(&check_results, block, block.instances);

    // Build the review doc too — the schematic page embeds its content
    // (summary, power budget/sequencing, test points, ERC, assertions) below
    // the section cards so a single URL covers both "what it is" and
    // "whether it's correct."
    const review_doc: ?review.ReviewDoc = review.buildReview(ctx.allocator, name, block, eval.assertions.items, violations, &check_results, ctx.project_dir) catch null;

    const html = render_html.renderToHtml(
        ctx.allocator,
        block,
        ctx.project_dir,
        name,
        assets_css.NAVBAR_CSS,
        status,
        review_doc,
        &check_results,
        "/schematics/",
    ) catch |err| {
        res.status = 500;
        res.body = try std.fmt.allocPrint(ctx.allocator, "Render error: {s}", .{@errorName(err)});
        return;
    };

    res.content_type = .HTML;
    res.body = html;
}

fn computeStatus(violations: []const erc_mod.Violation, assertions: []const env_mod.AssertionResult) review.Status {
    var has_err = false;
    var has_warn = false;
    for (violations) |v| switch (v.severity) {
        .@"error" => has_err = true,
        .warning => has_warn = true,
        .info => {},
    };
    for (assertions) |a| {
        if (a.passed) continue;
        if (a.is_warning) has_warn = true else has_err = true;
    }
    if (has_err) return .fail;
    if (has_warn) return .warn;
    return .pass;
}
