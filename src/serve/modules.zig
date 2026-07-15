//! `/modules` browser: lists the reusable `(defmodule …)` blocks under
//! `lib/modules/` and renders each one as a standalone schematic page, plus
//! the `/api/module-source` endpoint that backs the "copy source" button on
//! sub-block cards.
//!
//! A module is parameterized, so it renders standalone via its parameter
//! defaults — the deterministic, defaults-first `evalNamedBlock` resolution
//! every read surface uses. A module that declares a required parameter with
//! no default can't be instantiated, so it shows the raw source instead.

const std = @import("std");
const httpz = @import("httpz");
const infra_fs = @import("../infra/fs.zig");
const escape = @import("../escape.zig");
const paths = @import("../paths.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const env_mod = @import("../eval/env.zig");
const parser_mod = @import("../sexpr/parser.zig");
const printer_mod = @import("../sexpr/printer.zig");
const sexpr_ast = @import("../sexpr/ast.zig");
const render_html = @import("../render_html.zig");
const assets_css = @import("assets_css.zig");
const mcp_tools = @import("mcp_tools.zig");
const pages = @import("templates/pages.zig");
const serve_root = @import("../serve.zig");
const Server = serve_root.Server;

/// Error set for HTTP handlers in this module.
pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error;

const max_module_bytes: usize = 1024 * 1024;
const err_not_found = "module source not found";

const page_css =
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
    \\.mod-search{width:100%;box-sizing:border-box;background:#161b22;border:1px solid #30363d;
    \\border-radius:6px;color:#c9d1d9;padding:0.55rem 0.75rem;font-size:0.95rem;margin:0 0 8px;
    \\font-family:inherit;}
    \\.mod-search:focus{outline:none;border-color:#58a6ff;}
    \\.mod-search::placeholder{color:#555;}
    \\.mod-count{color:#6e7681;font-size:12px;margin:0 0 16px;}
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
const copy_script =
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

/// Reject absolute paths, `..` traversal, and NUL/backslash in a sub-block
/// `source` value. A path-shaped `source` is additionally confined to the
/// `lib/` and `src/` source roots and to the `.sexp` extension by
/// `resolveSourcePath` — this predicate is only the first, coarse gate.
fn sourceIsSafe(src: []const u8) bool {
    if (src.len == 0) return false;
    if (src[0] == '/') return false;
    if (std.mem.indexOf(u8, src, "..") != null) return false;
    if (std.mem.indexOfScalar(u8, src, 0) != null) return false;
    if (std.mem.indexOfScalar(u8, src, '\\') != null) return false;
    // A legitimate module name / .sexp path never contains markup
    // metacharacters; rejecting them keeps a hostile `source` out of the
    // `<title>`/`<h1>`/`data-src` sinks even before output escaping.
    if (std.mem.indexOfAny(u8, src, "\"'<>") != null) return false;
    return true;
}

/// Resolve a sub-block `source` to a readable file path under `project_dir`.
/// A `source` containing `/` or ending in `.sexp` is treated as a
/// project-relative path; otherwise it is a module name resolved against
/// `lib/modules/` then `lib/components/`. Caller frees. Null when unsafe or
/// no candidate exists.
///
/// SECURITY: a path-shaped `source` is confined to the design/library source
/// roots (`lib/` or `src/`) AND must end in `.sexp`. Without this, `?src=
/// auth/sessions.json` (has `/`, no `..`) resolved to `{project_dir}/auth/
/// sessions.json` and leaked raw session tokens — full account takeover.
fn resolveSourcePath(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    src: []const u8,
) !?[]const u8 {
    if (!sourceIsSafe(src)) return null;

    if (std.mem.indexOfScalar(u8, src, '/') != null or std.mem.endsWith(u8, src, ".sexp")) {
        // Confine path-shaped sources to source-file roots + the .sexp extension.
        const in_src_root = std.mem.startsWith(u8, src, "lib/") or std.mem.startsWith(u8, src, "src/");
        if (!in_src_root or !std.mem.endsWith(u8, src, ".sexp")) return null;
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
pub fn moduleSourceApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
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
        res.body = err_not_found;
        return;
    };
    defer ctx.allocator.free(path);

    const content = infra_fs.cwd().readFileAlloc(ctx.allocator, path, max_module_bytes) catch {
        res.status = 404;
        res.body = err_not_found;
        return;
    };
    res.content_type = .TEXT;
    res.body = content;
}

// ── GET /modules ──────────────────────────────────────────────────────

/// One row in the `/modules` list (also reused by the home page's
/// Modules section).
pub const ModuleEntry = struct {
    name: []const u8,
    params: []const u8,
    doc: []const u8,
    /// True when the defmodule body declares placement-cohesion `(group …)`
    /// forms (the form the rough seed coheres). Drives the home page's
    /// "grouping" tag. Source-derived, so it rides the inventory cache.
    has_groups: bool = false,
};

/// `(defmodule …)` metadata: the parameter list rendered as `(a b c)`, the
/// optional doc string, and whether the body carries placement-cohesion
/// `(group …)` forms. All empty/false when the file isn't a valid module.
const ModuleMeta = struct {
    params: []const u8 = "",
    doc: []const u8 = "",
    has_groups: bool = false,
};

/// Parse `(defmodule <name> (<params…>) "<doc>"? …)` out of a module file.
fn moduleMeta(allocator: std.mem.Allocator, content: []const u8) ModuleMeta {
    const empty: ModuleMeta = .{};
    const nodes = parser_mod.parse(allocator, content) catch return empty;
    for (nodes) |node| {
        if (!node.isForm("defmodule")) continue;
        const children = node.asList() orelse return empty;
        if (children.len < 3) return empty;
        const params = renderParamList(allocator, children[2]) orelse return empty;
        var doc: []const u8 = "";
        if (children.len > 3) {
            if (children[3].asString()) |d| doc = d;
        }
        return .{ .params = params, .doc = doc, .has_groups = nodeHasCohesionGroup(node) };
    }
    return empty;
}

/// True when `node` (or any descendant) is a placement-cohesion
/// `(group "name" (member …))` form — the form the rough seed coheres
/// (`block.groups`). It is distinguished from a pin `(group "label")` (no
/// argument list) and a diagram-layout `(group "label" "key" …)` (bare-string
/// members) by its parenthesized member LIST argument, so the home page's
/// "grouping" tag tracks exactly what enables a good roughing pass.
fn nodeHasCohesionGroup(node: sexpr_ast.Node) bool {
    const children = node.asList() orelse return false;
    if (node.isForm("group")) {
        for (children[1..]) |arg| {
            if (arg.asList() != null) return true;
        }
    }
    for (children) |child| {
        if (nodeHasCohesionGroup(child)) return true;
    }
    return false;
}

/// Render a defmodule parameter list as display text: `(a b=4.7k)`. A bare
/// atom prints as-is; a `(param default)` pair prints `name=default` so the
/// card shows which arguments are optional. Null on allocation failure.
fn renderParamList(allocator: std.mem.Allocator, params_node: sexpr_ast.Node) ?[]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    appendParamList(allocator, &buf, params_node) catch return null;
    return buf.items;
}

fn appendParamList(
    allocator: std.mem.Allocator,
    buf: *std.ArrayList(u8),
    params_node: sexpr_ast.Node,
) std.mem.Allocator.Error!void {
    try buf.append(allocator, '(');
    if (params_node.asList()) |plist| {
        for (plist, 0..) |p, i| {
            if (i > 0) try buf.appendSlice(allocator, " ");
            if (p.asAtom()) |pname| {
                try buf.appendSlice(allocator, pname);
                continue;
            }
            const pair = p.asList() orelse continue;
            if (pair.len != 2) continue;
            try buf.appendSlice(allocator, pair[0].asAtom() orelse "");
            try buf.append(allocator, '=');
            try buf.appendSlice(allocator, try printer_mod.print(allocator, pair[1..2]));
        }
    }
    try buf.append(allocator, ')');
}

/// Collect every `lib/modules/*.sexp` entry, sorted by name.
// ── Module-list cache ──────────────────────────────────────────────────
//
// collectModules reads + parses all 52 lib/modules/*.sexp files on every call
// (~18 ms), and it backs both the home page (module-card join) and the /modules
// list. The result depends only on the lib/modules directory, so we cache it
// across requests, keyed by a cheap directory fingerprint — the .sexp file
// count and the newest mtime among them. An edit bumps an mtime, an add bumps
// the count and mtime, a delete bumps the count; any of those invalidates. The
// cached entries live in page_allocator (the request arena dies per response);
// hits dupe back into the request arena. The fingerprint scan is ~52 stat()s
// (~1 ms) versus the ~18 ms read+parse it replaces.

const page = std.heap.page_allocator;

const ModuleDirStamp = struct {
    count: usize = 0,
    max_mtime_ns: i128 = 0,
    /// Distinguishes "no cache yet" from "an empty/absent directory".
    valid: bool = false,
};

var module_cache_mutex: std.Thread.Mutex = .{};
var module_cache_entries: []ModuleEntry = &.{};
var module_cache_stamp: ModuleDirStamp = .{};

/// Fingerprint the lib/modules directory: count of `.sexp` files and the newest
/// mtime among them. `scratch` is the request arena (for the dir path).
fn moduleDirStamp(scratch: std.mem.Allocator, project_dir: []const u8) ModuleDirStamp {
    const dir_path = std.fmt.allocPrint(scratch, "{s}/lib/modules", .{project_dir}) catch return .{};
    defer scratch.free(dir_path);
    var dir = infra_fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return .{ .valid = true };
    defer dir.close();
    var stamp: ModuleDirStamp = .{ .valid = true };
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".sexp")) continue;
        stamp.count += 1;
        if (dir.statFile(entry.name)) |st| {
            if (st.mtime > stamp.max_mtime_ns) stamp.max_mtime_ns = st.mtime;
        } else |_| {}
    }
    return stamp;
}

/// Deep-copy module entries into `alloc`.
fn dupeModuleEntries(alloc: std.mem.Allocator, src: []const ModuleEntry) std.mem.Allocator.Error![]ModuleEntry {
    const out = try alloc.alloc(ModuleEntry, src.len);
    for (src, 0..) |e, i| out[i] = .{
        .name = try alloc.dupe(u8, e.name),
        .params = try alloc.dupe(u8, e.params),
        .doc = try alloc.dupe(u8, e.doc),
        .has_groups = e.has_groups,
    };
    return out;
}

/// The lib/modules inventory (name + params + doc per module), sorted by name.
/// Cached across requests and invalidated when the directory's file
/// count/mtimes change. Backs the home page and /modules list.
pub fn collectModules(allocator: std.mem.Allocator, project_dir: []const u8) std.mem.Allocator.Error![]ModuleEntry {
    const stamp = moduleDirStamp(allocator, project_dir);
    if (stamp.valid) {
        module_cache_mutex.lock();
        if (module_cache_stamp.valid and
            module_cache_stamp.count == stamp.count and // mutate-ok: perf-only cache key; miss recomputes same result
            module_cache_stamp.max_mtime_ns == stamp.max_mtime_ns)
        {
            const hit = dupeModuleEntries(allocator, module_cache_entries) catch null;
            module_cache_mutex.unlock();
            if (hit) |entries| return entries;
        } else {
            module_cache_mutex.unlock();
        }
    }

    const fresh = try collectModulesUncached(allocator, project_dir);
    if (stamp.valid) cacheModules(fresh, stamp);
    return fresh;
}

/// Store a freshly-collected inventory (deep-duped into page_allocator),
/// freeing the prior cached copy.
fn cacheModules(entries: []const ModuleEntry, stamp: ModuleDirStamp) void {
    const stored = dupeModuleEntries(page, entries) catch return;
    module_cache_mutex.lock();
    defer module_cache_mutex.unlock();
    for (module_cache_entries) |e| {
        page.free(e.name);
        page.free(e.params);
        page.free(e.doc);
    }
    page.free(module_cache_entries);
    module_cache_entries = stored;
    module_cache_stamp = stamp;
}

fn collectModulesUncached(allocator: std.mem.Allocator, project_dir: []const u8) std.mem.Allocator.Error![]ModuleEntry {
    const dir_path = try std.fmt.allocPrint(allocator, "{s}/lib/modules", .{project_dir});
    defer allocator.free(dir_path);

    var dir = infra_fs.cwd().openDir(dir_path, .{ .iterate = true }) catch return &[_]ModuleEntry{};
    defer dir.close();

    var entries: std.ArrayList(ModuleEntry) = .empty;
    var iter = dir.iterate();
    while (iter.next() catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, ".sexp")) continue;
        const base = try allocator.dupe(u8, entry.name[0 .. entry.name.len - ".sexp".len]);
        const content = dir.readFileAlloc(allocator, entry.name, max_module_bytes) catch {
            try entries.append(allocator, .{ .name = base, .params = "", .doc = "" });
            continue;
        };
        const meta = moduleMeta(allocator, content);
        try entries.append(allocator, .{ .name = base, .params = meta.params, .doc = meta.doc, .has_groups = meta.has_groups });
    }

    std.mem.sort(ModuleEntry, entries.items, {}, struct {
        fn lt(_: void, a: ModuleEntry, b: ModuleEntry) bool {
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lt);
    return entries.items;
}

/// GET /modules — the standalone module list was merged into the home page
/// (`GET /`), which now lists designs and modules together as one tagged,
/// searchable grid. Redirect any lingering links there.
pub fn modulesListPage(_: *Server, _: *httpz.Request, res: *httpz.Response) HandlerError!void {
    res.status = 302;
    res.header("Location", "/");
}

// ── GET /modules/:name ────────────────────────────────────────────────

/// A module instantiated standalone for rendering, paired with the
/// `*Evaluator` whose arena the block borrows — the caller must keep the
/// evaluator alive until rendering is done.
pub const ResolvedBlock = struct {
    block: *env_mod.DesignBlock,
    eval: *Evaluator,
};

/// Resolve `module_name` to a renderable, fully-evaluated block via its
/// parameter defaults — the deterministic, defaults-first instantiation
/// `mcp_tools.evalNamedBlock` performs for every read surface (it is the single
/// resolver; this wrapper only adapts the ownership: the returned `eval` owns
/// the block's arena and the caller must `deinit` + `destroy` it once done).
/// Null when the module is missing or declares a required parameter with no
/// default (caller shows the source-only view).
pub fn resolveModuleBlock(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    module_name: []const u8,
) ?ResolvedBlock {
    const eval = allocator.create(Evaluator) catch return null;
    eval.* = Evaluator.init(allocator, project_dir);
    const nb = mcp_tools.evalNamedBlock(allocator, project_dir, module_name, eval) catch {
        eval.deinit();
        allocator.destroy(eval);
        return null;
    };
    return .{ .block = nb.block, .eval = eval };
}

/// GET /modules/:name — render a module as a standalone schematic page. Falls
/// back to a raw-source view when the module can't be instantiated (e.g. a
/// parameterized module that no design currently uses).
pub fn moduleViewPage(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    return renderModulePage(ctx, res, name);
}

/// Render module `name` as a standalone schematic page (the body of
/// `moduleViewPage`, factored out so `/schematics/<module>` can render a module
/// in place rather than 302-redirecting). Validates the name, resolves the
/// source path, and renders via the shared `render_html` renderer with the
/// `/modules/` chrome — falling back to the raw-source view when the module
/// can't be instantiated or the renderer errors. The `sourceIsSafe` guard is
/// kept here so both entry points are protected.
pub fn renderModulePage(ctx: *Server, res: *httpz.Response, name: []const u8) HandlerError!void {
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

    // Preferred path: the module instantiated via its parameter defaults →
    // full schematic page via the shared renderer.
    if (resolveModuleBlock(ctx.allocator, ctx.project_dir, name)) |resolved| {
        var empty_checks: render_html.CheckResultMap = .empty;
        const html = render_html.renderToHtml(
            ctx.allocator,
            resolved.block,
            ctx.project_dir,
            name,
            assets_css.navbar_css,
            .pass,
            null,
            &empty_checks,
            "/modules/",
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
    ctx: *Server,
    res: *httpz.Response,
    name: []const u8,
    src_path: []const u8,
    render_failed: bool,
) HandlerError!void {
    const content = infra_fs.cwd().readFileAlloc(ctx.allocator, src_path, max_module_bytes) catch {
        res.status = 404;
        res.body = err_not_found;
        return;
    };

    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    const w = &aw.writer;
    try w.writeAll("<!DOCTYPE html><html><head><meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">");
    try w.writeAll("<title>");
    try escape.writeXml(w, name);
    try w.writeAll(" — module</title><style>");
    try w.writeAll(assets_css.navbar_css);
    try w.writeAll("</style>");
    try w.writeAll(page_css);
    try w.writeAll("</head><body>");
    try pages.Navbar.render(.{"designs"}, w);
    try w.writeAll("<div class=\"mod-wrap\">");
    try w.writeAll("<div class=\"mod-src-head\"><h1>");
    try escape.writeXml(w, name);
    try w.writeAll("</h1><button type=\"button\" class=\"copy-src-btn\" data-src=\"");
    try escape.writeXml(w, name);
    try w.writeAll("\">Copy source</button></div>");
    try w.writeAll("<div class=\"mod-src-note\">");
    if (render_failed) {
        try w.writeAll("This module evaluated but the schematic renderer errored — showing source instead.");
    } else {
        try w.writeAll("This module has required parameters and no design currently instantiates it, " ++
            "so it can't be rendered as a schematic on its own. Give every parameter a default " ++
            "— <code>(defmodule m ((param default) …) …)</code> — to make it render standalone. " ++
            "Showing source instead.");
    }
    try w.writeAll("</div>");
    try w.writeAll("<pre class=\"mod-src-pre\">");
    try escape.writeXml(w, content);
    try w.writeAll("</pre></div>");
    try w.writeAll(copy_script);
    try w.writeAll("</body></html>");

    res.body = aw.written();
    res.content_type = .HTML;
}

// ── Tests ──────────────────────────────────────────────────────────────

// spec: Web Server - Module grouping tag detects placement-cohesion groups but not pin or diagram groups
test "nodeHasCohesionGroup distinguishes cohesion groups from pin and diagram groups" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    // Cohesion group: a member LIST follows the name → counts.
    const cohesion = try parser_mod.parse(a, "(defmodule m () (design-block \"t\" (group \"Buck\" (\"U1\" \"L1\"))))");
    try std.testing.expect(nodeHasCohesionGroup(cohesion[0]));

    // Pin group inside (pins …): label only, no list → does not count.
    const pin = try parser_mod.parse(a, "(defmodule m () (design-block \"t\" (pins \"U1\" (group \"Bank\") (pin 1 \"VDD\"))))");
    try std.testing.expect(!nodeHasCohesionGroup(pin[0]));

    // Diagram-layout group: bare-string members, no list → does not count.
    const diagram = try parser_mod.parse(a, "(defmodule m () (design-block \"t\" (diagram-layout (group \"Front\" \"a\" \"b\"))))");
    try std.testing.expect(!nodeHasCohesionGroup(diagram[0]));
}

// A hostile module `source` must never reach the `<title>`/`<h1>`/`data-src`
// sinks in the source page: sourceIsSafe rejects markup metacharacters and the
// pre-existing path-traversal set, so both output escaping and this input gate
// have to fail before an injection lands.
test "sourceIsSafe rejects markup metacharacters and traversal" {
    // Markup metacharacters (the XSS-hardening addition).
    try std.testing.expect(!sourceIsSafe("evil\"onload=x"));
    try std.testing.expect(!sourceIsSafe("a'b"));
    try std.testing.expect(!sourceIsSafe("<script>"));
    try std.testing.expect(!sourceIsSafe("a>b"));
    // Pre-existing path/traversal rejections still hold.
    try std.testing.expect(!sourceIsSafe(""));
    try std.testing.expect(!sourceIsSafe("/etc/passwd"));
    try std.testing.expect(!sourceIsSafe("../secrets"));
    try std.testing.expect(!sourceIsSafe("a\\b"));
    // A legitimate module name / .sexp path is still accepted.
    try std.testing.expect(sourceIsSafe("stm32_power"));
    try std.testing.expect(sourceIsSafe("lib/modules/buck.sexp"));
}
