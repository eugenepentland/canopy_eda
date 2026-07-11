const std = @import("std");
const httpz = @import("httpz");
const infra_fs = @import("../infra/fs.zig");
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
const page_cache = @import("page_cache.zig");
const modules_page = @import("modules.zig");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;

/// Error set for HTTP handlers in this module.
pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error || error{InvalidName};

// ── Rendered-HTML cache ────────────────────────────────────────────────
//
// The schematic page is a pure function of the design's source files: a clean
// reload re-evaluates the design, runs ERC + requirement checks + the review
// doc, and renders ~1 MB of HTML, all identical to last time. We cache the
// rendered body across requests, keyed by design name and invalidated by the
// evaluation's file read-set (page_cache.FileSet) plus the live version, so a
// repeat load skips eval+erc+render entirely. The body and its read-set live in
// page_allocator (the request arena is freed per response); a hit dupes the
// body back into the request arena under the lock so a concurrent eviction
// can't free it mid-response. Keys are bounded by the number of design files on
// disk (module-only names are rendered in place by the module renderer and
// return before reaching here), so per-name replacement needs no separate
// eviction policy.

const page = std.heap.page_allocator;

const HtmlCacheEntry = struct {
    html: []const u8,
    files: page_cache.FileSet,
    live_version: u32,
};

var html_cache_mutex: std.Thread.Mutex = .{};
var html_cache: std.StringHashMapUnmanaged(HtmlCacheEntry) = .empty;

/// Return a request-arena copy of the cached HTML for `name` when a valid entry
/// exists (read-set unchanged and live version matches), else null. Validation
/// and the dup happen under the lock so a concurrent put can't free the body.
fn htmlCacheGet(arena: std.mem.Allocator, name: []const u8, live_version: u32) ?[]const u8 {
    html_cache_mutex.lock();
    defer html_cache_mutex.unlock();
    const e = html_cache.getPtr(name) orelse return null;
    if (e.live_version != live_version or !e.files.isValid()) return null;
    return arena.dupe(u8, e.html) catch null;
}

/// Cache freshly-rendered `html` for `name`, duping the body and read-set into
/// page_allocator and freeing any prior entry. `scratch` is the request arena.
fn htmlCachePut(
    scratch: std.mem.Allocator,
    eval: *const Evaluator,
    project_dir: []const u8,
    name: []const u8,
    html: []const u8,
    live_version: u32,
) void {
    const files = page_cache.capture(scratch, eval, project_dir, name) catch return;
    const body = page.dupe(u8, html) catch {
        files.deinit();
        return;
    };
    const key = page.dupe(u8, name) catch {
        files.deinit();
        page.free(body);
        return;
    };

    html_cache_mutex.lock();
    defer html_cache_mutex.unlock();
    const gop = html_cache.getOrPut(page, key) catch {
        files.deinit();
        page.free(body);
        page.free(key);
        return;
    };
    if (gop.found_existing) {
        page.free(key); // map keeps the original key
        gop.value_ptr.files.deinit();
        page.free(gop.value_ptr.html);
    }
    gop.value_ptr.* = .{ .html = body, .files = files, .live_version = live_version };
}

/// True when `designSourcePath` resolved a *module-only* name to its
/// `lib/modules/<name>.sexp` fallback (see `paths.designSiblingPath`) rather
/// than a real `src/` design. That file existing must NOT be read as "a design
/// source exists" — evaluating the `(defmodule …)` yields a module, not a
/// design block, which 500s. Detecting it lets `/schematics/<module>` render
/// the module in place via the module renderer instead.
fn resolvesToModuleSource(board_path: []const u8) bool {
    return std.mem.indexOf(u8, board_path, "/lib/modules/") != null;
}

/// True when `name` has no real `src/` design but does exist under
/// `lib/modules/` — i.e. a module name typed into `/schematics/…`. Detected so
/// the schematic handler can render the module *in place* (no 302 hop) using
/// the same address shape as a design. `board_path` is `designSourcePath`'s
/// result: a real design's path points into `src/`; a module-only name falls
/// back to its `lib/modules/<name>.sexp` (caught by `resolvesToModuleSource`,
/// or by the path not existing on disk).
fn isModuleOnly(ctx: *Handler, name: []const u8, board_path: []const u8) bool {
    // A real `src/` design renders normally. Treat as a module only when the
    // resolved path is NOT a real src/ design — either it fell back to the
    // lib/modules path, or it doesn't exist on disk at all.
    if (!resolvesToModuleSource(board_path)) {
        if (infra_fs.cwd().access(board_path, .{})) |_| return false else |_| {}
    }
    if (std.mem.indexOfScalar(u8, name, '/') != null) return false;
    if (std.mem.indexOf(u8, name, "..") != null) return false;
    const mod_path = std.fmt.allocPrint(ctx.allocator, "{s}/lib/modules/{s}.sexp", .{ ctx.project_dir, name }) catch return false;
    defer ctx.allocator.free(mod_path);
    infra_fs.cwd().access(mod_path, .{}) catch return false;
    return true;
}

/// GET /schematics/:name — HTML schematic page. Evaluates the design, runs
/// ERC for the status banner, then hands off to render_html.renderToHtml.
pub fn schematicPage(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };

    const board_path = try paths.designSourcePath(ctx.allocator, ctx.project_dir, name);
    defer ctx.allocator.free(board_path);

    // A module name typed into a design URL: render the module in place via the
    // module renderer, so designs and modules open from the same address shape
    // with no redirect hop. (The module chrome's own links stay at /modules/.)
    if (isModuleOnly(ctx, name, board_path)) return modules_page.renderModulePage(ctx, res, name);

    // Serve the cached render when the design's source files are unchanged.
    // Capture the live version *before* evaluating so a bump mid-eval is
    // correctly treated as a miss on the next load rather than baked in.
    const live_version = serve_root.getLiveVersion(name);
    if (htmlCacheGet(ctx.allocator, name, live_version)) |cached| {
        res.content_type = .HTML;
        res.body = cached;
        return;
    }

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
    const review_doc: ?review.ReviewDoc = review.buildReview(ctx.allocator, name, block, eval.assertions.items, violations, &check_results) catch null;

    const html = render_html.renderToHtml(
        ctx.allocator,
        block,
        ctx.project_dir,
        name,
        assets_css.navbar_css,
        status,
        review_doc,
        &check_results,
        "/schematics/",
    ) catch |err| {
        res.status = 500;
        res.body = try std.fmt.allocPrint(ctx.allocator, "Render error: {s}", .{@errorName(err)});
        return;
    };

    htmlCachePut(ctx.allocator, &eval, ctx.project_dir, name, html, live_version);

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
