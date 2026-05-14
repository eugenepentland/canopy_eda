//! `/modules` browser: lists the reusable `(defmodule …)` blocks under
//! `lib/modules/` and renders each one as a standalone schematic page, plus
//! the `/api/module-source` endpoint that backs the "copy source" button on
//! sub-block cards.
//!
//! A module is parameterized, so it can't be rendered in isolation without
//! argument values. The viewer prefers a *real* instantiation: it scans the
//! project's designs for a `(sub-block … (<module> …))` that already wired
//! the module up with concrete args and renders that evaluated block. When
//! no design uses the module it falls back to synthesizing a zero-arg
//! instantiation (works for parameter-less modules); failing that it shows
//! the raw source.

const std = @import("std");
const httpz = @import("httpz");
const infra_fs = @import("../infra/fs.zig");
const paths = @import("../paths.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const env_mod = @import("../eval/env.zig");
const parser_mod = @import("../sexpr/parser.zig");
const render_html = @import("../render_html.zig");
const assets_css = @import("assets_css.zig");
const mcp_tools = @import("mcp_tools.zig");
const pages = @import("templates/pages.zig");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;

/// Error set for HTTP handlers in this module.
pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error;

const MAX_MODULE_BYTES: usize = 1024 * 1024;
const ERR_NOT_FOUND = "module source not found";

const PAGE_CSS =
    \\<style>
    \\body{margin:0;background:#0d1117;color:#c9d1d9;font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;}
    \\.mod-wrap{max-width:960px;margin:0 auto;padding:8px 16px 32px;}
    \\h1{color:#f0f6fc;font-size:1.3rem;margin:16px 0 4px;}
    \\.mod-sub{color:#8b949e;font-size:0.9rem;margin:0 0 16px;}
    \\.mod-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(300px,1fr));gap:14px;}
    \\.mod-card{background:#161b22;border:1px solid #21262d;border-radius:10px;padding:16px 18px;
    \\display:flex;flex-direction:column;gap:8px;transition:border-color .15s;}
    \\.mod-card:hover{border-color:#58a6ff;}
    \\.mod-card-name{color:#f0f6fc;font-size:1rem;font-weight:600;font-family:"SF Mono",monospace;}
    \\.mod-card-params{color:#6e7681;font-size:12px;font-family:"SF Mono",monospace;}
    \\.mod-card-desc{color:#8b949e;font-size:0.85rem;line-height:1.4;flex:1;}
    \\.mod-card-links{display:flex;gap:8px;margin-top:4px;}
    \\.mod-card-link{color:#8b949e;font-size:13px;padding:6px 14px;border:1px solid #30363d;
    \\border-radius:6px;text-decoration:none;text-align:center;flex:1;}
    \\.mod-card-link:hover{border-color:#58a6ff;color:#c9d1d9;}
    \\.empty-hint{color:#6e7681;font-size:13px;padding:24px;text-align:center;}
    \\.mod-src-head{display:flex;align-items:center;gap:12px;margin:16px 0 8px;}
    \\.mod-src-note{background:#1c2230;border:1px solid #30363d;border-radius:6px;
    \\padding:10px 14px;color:#8b949e;font-size:0.85rem;margin:8px 0 16px;}
    \\.mod-src-pre{background:#010409;border:1px solid #21262d;border-radius:8px;padding:14px 16px;
    \\overflow-x:auto;font-family:"SF Mono",monospace;font-size:0.82rem;line-height:1.5;color:#c9d1d9;}
    \\.copy-src-btn{background:#21262d;color:#c9d1d9;border:1px solid #30363d;border-radius:5px;
    \\padding:5px 12px;font-size:0.8rem;cursor:pointer;font-family:inherit;}
    \\.copy-src-btn:hover{background:#30363d;border-color:#58a6ff;}
    \\.copy-src-btn.copied{color:#3fb950;border-color:#238636;}
    \\</style>
;

/// Inline `<script>` that wires every `.copy-src-btn` on the page to fetch
/// `/api/module-source` and drop the text on the clipboard. Mirrors the
/// handler baked into `schematic_viewer.js` so the standalone module pages
/// don't need that whole bundle.
const COPY_SCRIPT =
    \\<script>
    \\document.addEventListener('click',function(e){
    \\ var b=e.target.closest&&e.target.closest('.copy-src-btn');
    \\ if(!b||!b.dataset.src)return;
    \\ e.preventDefault();var o=b.textContent;
    \\ fetch('/api/module-source?src='+encodeURIComponent(b.dataset.src))
    \\  .then(function(r){if(!r.ok)throw 0;return r.text();})
    \\  .then(function(t){return navigator.clipboard.writeText(t);})
    \\  .then(function(){b.textContent='Copied \u{2713}';b.classList.add('copied');
    \\   setTimeout(function(){b.textContent=o;b.classList.remove('copied');},1500);})
    \\  .catch(function(){b.textContent='Copy failed';
    \\   setTimeout(function(){b.textContent=o;},1500);});
    \\});
    \\</script>
;

// ── Source resolution ─────────────────────────────────────────────────

/// Reject absolute paths and `..` traversal in a sub-block `source` value.
fn sourceIsSafe(src: []const u8) bool {
    if (src.len == 0) return false;
    if (src[0] == '/') return false;
    if (std.mem.indexOf(u8, src, "..") != null) return false;
    return true;
}

/// Resolve a sub-block `source` to a readable file path under `project_dir`.
/// A `source` containing `/` or ending in `.sexp` is treated as a
/// project-relative path; otherwise it is a module name resolved against
/// `lib/modules/` then `lib/components/`. Caller frees. Null when unsafe or
/// no candidate exists.
fn resolveSourcePath(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    src: []const u8,
) !?[]const u8 {
    if (!sourceIsSafe(src)) return null;

    if (std.mem.indexOfScalar(u8, src, '/') != null or std.mem.endsWith(u8, src, ".sexp")) {
        const p = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_dir, src });
        if (fileExists(p)) return p;
        allocator.free(p);
        return null;
    }

    const subdirs = [_][]const u8{ "lib/modules", "lib/components" };
    for (subdirs) |sub| {
        const p = try std.fmt.allocPrint(allocator, "{s}/{s}/{s}.sexp", .{ project_dir, sub, src });
        if (fileExists(p)) return p;
        allocator.free(p);
    }
    return null;
}

fn fileExists(path: []const u8) bool {
    infra_fs.cwd().access(path, .{}) catch return false;
    return true;
}

// ── GET /api/module-source ────────────────────────────────────────────

/// GET /api/module-source?src=<module-name-or-path> — return the raw `.sexp`
/// text behind a sub-block. `src` is the `SubBlock.source` value emitted into
/// the schematic page's "copy source" buttons.
pub fn moduleSourceApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    res.header("Access-Control-Allow-Origin", "*");
    const query = req.query() catch {
        res.status = 400;
        res.body = "bad query";
        return;
    };
    const src = query.get("src") orelse {
        res.status = 400;
        res.body = "missing src";
        return;
    };

    const path = (resolveSourcePath(ctx.allocator, ctx.project_dir, src) catch null) orelse {
        res.status = 404;
        res.body = ERR_NOT_FOUND;
        return;
    };
    defer ctx.allocator.free(path);

    const content = infra_fs.cwd().readFileAlloc(ctx.allocator, path, MAX_MODULE_BYTES) catch {
        res.status = 404;
        res.body = ERR_NOT_FOUND;
        return;
    };
    res.content_type = .TEXT;
    res.body = content;
}

// ── GET /modules ──────────────────────────────────────────────────────

/// One row in the `/modules` list.
const ModuleEntry = struct {
    name: []const u8,
    params: []const u8,
    doc: []const u8,
};

/// `(defmodule …)` metadata: the parameter list rendered as `(a b c)` and
/// the optional doc string. Both empty when the file isn't a valid module.
const ModuleMeta = struct {
    params: []const u8 = "",
    doc: []const u8 = "",
};

/// Parse `(defmodule <name> (<params…>) "<doc>"? …)` out of a module file.
fn moduleMeta(allocator: std.mem.Allocator, content: []const u8) ModuleMeta {
    const empty: ModuleMeta = .{};
    const nodes = parser_mod.parse(allocator, content) catch return empty;
    for (nodes) |node| {
        if (!node.isForm("defmodule")) continue;
        const children = node.asList() orelse return empty;
        if (children.len < 3) return empty;
        var params: std.ArrayListUnmanaged(u8) = .empty;
        params.append(allocator, '(') catch return empty;
        if (children[2].asList()) |plist| {
            for (plist, 0..) |p, i| {
                if (i > 0) params.appendSlice(allocator, " ") catch return empty;
                params.appendSlice(allocator, p.asAtom() orelse "") catch return empty;
            }
        }
        params.append(allocator, ')') catch return empty;
        var doc: []const u8 = "";
        if (children.len > 3) {
            if (children[3].asString()) |d| doc = d;
        }
        return .{ .params = params.items, .doc = doc };
    }
    return empty;
}

/// Collect every `lib/modules/*.sexp` entry, sorted by name.
fn collectModules(allocator: std.mem.Allocator, project_dir: []const u8) ![]ModuleEntry {
    const dir_path = try std.fmt.allocPrint(allocator, "{s}/lib/modules", .{project_dir});
    defer allocator.free(dir_path);

    var dir = infra_fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return &[_]ModuleEntry{};
    defer dir.close();

    var entries: std.ArrayListUnmanaged(ModuleEntry) = .empty;
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".sexp")) continue;
        const base = try allocator.dupe(u8, entry.name[0 .. entry.name.len - ".sexp".len]);
        const content = dir.readFileAlloc(allocator, entry.name, MAX_MODULE_BYTES) catch {
            try entries.append(allocator, .{ .name = base, .params = "", .doc = "" });
            continue;
        };
        const meta = moduleMeta(allocator, content);
        try entries.append(allocator, .{ .name = base, .params = meta.params, .doc = meta.doc });
    }

    std.mem.sort(ModuleEntry, entries.items, {}, struct {
        fn lt(_: void, a: ModuleEntry, b: ModuleEntry) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    return entries.items;
}

/// GET /modules — grid of every reusable module under `lib/modules/`.
pub fn modulesListPage(ctx: *Handler, _: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const entries = collectModules(ctx.allocator, ctx.project_dir) catch &[_]ModuleEntry{};

    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    const w = &aw.writer;
    try w.writeAll("<!DOCTYPE html><html><head><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">");
    try w.writeAll("<title>Modules</title><style>");
    try w.writeAll(assets_css.NAVBAR_CSS);
    try w.writeAll("</style>");
    try w.writeAll(PAGE_CSS);
    try w.writeAll("</head><body>");
    try pages.Navbar.render(.{"modules"}, w);
    try w.writeAll("<div class=\"mod-wrap\">");
    try w.writeAll("<h1>Modules</h1>");
    try w.writeAll("<p class=\"mod-sub\">Reusable <code>(defmodule …)</code> blocks under <code>lib/modules/</code>. " ++
        "Each is a sealed sub-block that designs import and wire up.</p>");

    if (entries.len == 0) {
        try w.writeAll("<div class=\"empty-hint\">No modules found in lib/modules/.</div>");
    } else {
        try w.writeAll("<div class=\"mod-grid\">");
        for (entries) |e| {
            try w.writeAll("<div class=\"mod-card\">");
            try w.writeAll("<div class=\"mod-card-name\">");
            try writeHtmlEscaped(w, e.name);
            if (e.params.len > 2) {
                try w.writeAll(" <span class=\"mod-card-params\">");
                try writeHtmlEscaped(w, e.params);
                try w.writeAll("</span>");
            }
            try w.writeAll("</div>");
            if (e.doc.len > 0) {
                try w.writeAll("<div class=\"mod-card-desc\">");
                try writeHtmlEscaped(w, e.doc);
                try w.writeAll("</div>");
            }
            try w.writeAll("<div class=\"mod-card-links\">");
            try w.writeAll("<a class=\"mod-card-link\" href=\"/modules/");
            try writeUrlEncoded(w, e.name);
            try w.writeAll("\">View schematic</a>");
            try w.writeAll("<button type=\"button\" class=\"copy-src-btn\" data-src=\"");
            try writeHtmlEscaped(w, e.name);
            try w.writeAll("\">Copy source</button>");
            try w.writeAll("</div></div>");
        }
        try w.writeAll("</div>");
    }
    try w.writeAll("</div>");
    try w.writeAll(COPY_SCRIPT);
    try w.writeAll("</body></html>");

    res.body = aw.written();
    res.content_type = .HTML;
}

// ── GET /modules/:name ────────────────────────────────────────────────

/// Recursively search a design's sub-block tree for one whose `source`
/// matches `module_name`, returning its evaluated block.
fn findSubBlockBlock(block: *const env_mod.DesignBlock, module_name: []const u8) ?*env_mod.DesignBlock {
    for (block.sub_blocks) |sb| {
        if (std.mem.eql(u8, sb.source, module_name)) return sb.block;
        if (findSubBlockBlock(sb.block, module_name)) |found| return found;
    }
    return null;
}

/// Try to obtain a renderable, fully-evaluated block for `module_name`.
/// First preference: a real instantiation found in one of the project's
/// designs (concrete args, real wiring). Fallback: synthesize a zero-arg
/// instantiation, which only succeeds for parameter-less modules. The
/// `*Evaluator` that produced the block is returned alongside it because the
/// block borrows the evaluator's arena — the caller must keep it alive until
/// rendering is done.
const ResolvedBlock = struct {
    block: *env_mod.DesignBlock,
    eval: *Evaluator,
};

fn resolveModuleBlock(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    module_name: []const u8,
) ?ResolvedBlock {
    // 1. Look for a real usage across the project's designs. `listDesignNames`
    //    returns bare basenames; the files may sit in `src/<group>/` subdirs,
    //    so resolve each through `paths.designSourcePath`.
    const design_names = mcp_tools.listDesignNames(allocator, project_dir) catch &[_][]const u8{};
    for (design_names) |dname| {
        const path = paths.designSourcePath(allocator, project_dir, dname) catch continue;
        const eval = allocator.create(Evaluator) catch continue;
        eval.* = Evaluator.init(allocator, project_dir);
        const result = eval.evalFile(path) catch {
            eval.deinit();
            allocator.destroy(eval);
            continue;
        };
        switch (result) {
            .design_block => |b| {
                if (findSubBlockBlock(b, module_name)) |found| {
                    return .{ .block = found, .eval = eval };
                }
            },
            else => {},
        }
        eval.deinit();
        allocator.destroy(eval);
    }

    // 2. Fallback: synthesize a zero-arg instantiation. Works only when the
    //    module takes no parameters; parameterized modules raise an arity or
    //    assert error here and fall through to the source-only view.
    const synthetic = std.fmt.allocPrint(
        allocator,
        "(import {s})\n(design-block \"{s}\" (sub-block \"preview\" ({s})))",
        .{ module_name, module_name, module_name },
    ) catch return null;
    const eval = allocator.create(Evaluator) catch return null;
    eval.* = Evaluator.init(allocator, project_dir);
    const result = eval.evalSource(synthetic) catch {
        eval.deinit();
        allocator.destroy(eval);
        return null;
    };
    switch (result) {
        .design_block => |b| {
            if (b.sub_blocks.len > 0) return .{ .block = b.sub_blocks[0].block, .eval = eval };
        },
        else => {},
    }
    eval.deinit();
    allocator.destroy(eval);
    return null;
}

/// GET /modules/:name — render a module as a standalone schematic page. Falls
/// back to a raw-source view when the module can't be instantiated (e.g. a
/// parameterized module that no design currently uses).
pub fn moduleViewPage(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    if (!sourceIsSafe(name)) {
        res.status = 400;
        res.body = "bad module name";
        return;
    }

    const src_path = (resolveSourcePath(ctx.allocator, ctx.project_dir, name) catch null) orelse {
        res.status = 404;
        res.body = "module not found";
        return;
    };
    defer ctx.allocator.free(src_path);

    // Preferred path: a real (or synthesized) evaluated block → full
    // schematic page via the shared renderer.
    if (resolveModuleBlock(ctx.allocator, ctx.project_dir, name)) |resolved| {
        var empty_checks: render_html.CheckResultMap = .empty;
        const html = render_html.renderToHtml(
            ctx.allocator,
            resolved.block,
            ctx.project_dir,
            name,
            assets_css.NAVBAR_CSS,
            .pass,
            null,
            &empty_checks,
        ) catch {
            // Fall through to the source view on a render failure.
            try writeSourceOnlyPage(ctx, res, name, src_path, true);
            return;
        };
        res.content_type = .HTML;
        res.body = html;
        return;
    }

    // Fallback: the module needs arguments no design supplies — show source.
    try writeSourceOnlyPage(ctx, res, name, src_path, false);
}

/// Render the raw-source fallback page for a module that couldn't be
/// instantiated. `render_failed` distinguishes "needs args" from "rendered
/// but the renderer errored" so the note text can be honest.
fn writeSourceOnlyPage(
    ctx: *Handler,
    res: *httpz.Response,
    name: []const u8,
    src_path: []const u8,
    render_failed: bool,
) HandlerError!void {
    const content = infra_fs.cwd().readFileAlloc(ctx.allocator, src_path, MAX_MODULE_BYTES) catch {
        res.status = 404;
        res.body = ERR_NOT_FOUND;
        return;
    };

    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    const w = &aw.writer;
    try w.writeAll("<!DOCTYPE html><html><head><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">");
    try w.writeAll("<title>");
    try writeHtmlEscaped(w, name);
    try w.writeAll(" — module</title><style>");
    try w.writeAll(assets_css.NAVBAR_CSS);
    try w.writeAll("</style>");
    try w.writeAll(PAGE_CSS);
    try w.writeAll("</head><body>");
    try pages.Navbar.render(.{"modules"}, w);
    try w.writeAll("<div class=\"mod-wrap\">");
    try w.writeAll("<div class=\"mod-src-head\"><h1>");
    try writeHtmlEscaped(w, name);
    try w.writeAll("</h1><button type=\"button\" class=\"copy-src-btn\" data-src=\"");
    try writeHtmlEscaped(w, name);
    try w.writeAll("\">Copy source</button></div>");
    try w.writeAll("<div class=\"mod-src-note\">");
    if (render_failed) {
        try w.writeAll("This module evaluated but the schematic renderer errored — showing source instead.");
    } else {
        try w.writeAll("This module takes parameters and no design currently instantiates it, " ++
            "so it can't be rendered as a schematic on its own. Showing source instead.");
    }
    try w.writeAll("</div>");
    try w.writeAll("<pre class=\"mod-src-pre\">");
    try writeHtmlEscaped(w, content);
    try w.writeAll("</pre></div>");
    try w.writeAll(COPY_SCRIPT);
    try w.writeAll("</body></html>");

    res.body = aw.written();
    res.content_type = .HTML;
}

// ── helpers ───────────────────────────────────────────────────────────

fn writeHtmlEscaped(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    for (s) |c| switch (c) {
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '&' => try w.writeAll("&amp;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(c),
    };
}

fn writeUrlEncoded(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    for (s) |c| {
        const safe = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.' or c == '~';
        if (safe) {
            try w.writeByte(c);
        } else {
            try w.print("%{X:0>2}", .{c});
        }
    }
}
