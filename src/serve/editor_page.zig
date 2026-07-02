//! KiCad-style "sheet editor" prototype.
//!
//! A new read/write surface that reuses the existing scene-graph layout
//! (`render_json.renderSceneGraph`) but presents it as a pannable/zoomable
//! canvas where each `(section …)` reads as a navigable *sheet* (KiCad's
//! hierarchical sheets). All mutation goes through the existing surgical
//! `/api/*` endpoints (add-instance, remove-instance, rewire-pin, edit-value);
//! this module only serves the page shell + a per-design scene endpoint.
//!
//! Why a per-design scene endpoint: `/api/scene-graph/:name` returns a single
//! global "live" slot (whatever was last pushed), so the editor can't rely on
//! it to fetch an arbitrary design. `editorSceneApi` re-evaluates the named
//! design fresh and returns its scene graph, which the client refetches after
//! every edit (and on the version poll) to repaint.

const std = @import("std");
const httpz = @import("httpz");
const paths = @import("../paths.zig");
const Evaluator = @import("../eval/evaluator.zig").Evaluator;
const env_mod = @import("../eval/env.zig");
const render_json = @import("../render_json.zig");
const assets_css = @import("assets_css.zig");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;

pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error;

/// A design `:name` is a bare filesystem basename. Reject anything else so the
/// value is safe to reflect into HTML/JS/URL contexts (it is interpolated raw
/// into the page shell) and can never traverse the design directory. Without
/// this, `/editor/%3Cscript%3E…` reflected an executable payload.
fn isSafeName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    if (std.mem.indexOf(u8, name, "..") != null) return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_' or c == '.';
        if (!ok) return false;
    }
    return true;
}

/// Stream already-serialized JSON into a `<script>` element safely: `<` only
/// occurs inside JSON string values, so escaping it to `<` keeps the JSON
/// valid while preventing a `</script>` breakout from any embedded string.
fn writeScriptJson(w: *std.Io.Writer, json: []const u8) std.Io.Writer.Error!void {
    for (json) |c| {
        if (c == '<') try w.writeAll("\\u003c") else try w.writeByte(c);
    }
}

/// Evaluate `name`'s design source and return its scene-graph JSON, or null
/// with a reason written into `err`. Mirrors the eval path in `api.pushApi`.
fn sceneFor(ctx: *Handler, name: []const u8, err: *[]const u8) ?[]const u8 {
    const board_path = paths.designSourcePath(ctx.allocator, ctx.project_dir, name) catch {
        err.* = "alloc";
        return null;
    };
    defer ctx.allocator.free(board_path);

    var eval = Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();
    const result = eval.evalFile(board_path) catch {
        err.* = "eval";
        return null;
    };
    const block: *env_mod.DesignBlock = switch (result) {
        .design_block => |b| b,
        else => {
            err.* = "not a design-block";
            return null;
        },
    };
    return render_json.renderSceneGraph(ctx.allocator, block, ctx.project_dir) catch {
        err.* = "render";
        return null;
    };
}

/// GET /api/editor-scene/:name — the per-design scene graph as JSON. The
/// editor client refetches this after each edit and on the version poll.
pub fn editorSceneApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    if (!isSafeName(name)) {
        res.status = 404;
        return;
    }
    var err: []const u8 = "";
    const scene = sceneFor(ctx, name, &err);
    res.content_type = .JSON;
    res.header("Access-Control-Allow-Origin", "*");
    if (scene) |s| {
        res.body = s;
    } else {
        res.status = 200;
        res.body = try std.fmt.allocPrint(ctx.allocator, "{{\"error\":\"{s}\"}}", .{err});
    }
}

/// GET /editor/:name — the sheet-editor page. Embeds the scene graph + design
/// name + current live version, then loads the client (`/static/editor.js`).
pub fn editorPage(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    if (!isSafeName(name)) {
        res.status = 404;
        return;
    }
    var err: []const u8 = "";
    const scene = sceneFor(ctx, name, &err) orelse {
        res.status = 500;
        res.content_type = .HTML;
        res.body = try std.fmt.allocPrint(ctx.allocator, "<h1>Could not load {s}</h1><p>{s}</p>", .{ name, err });
        return;
    };
    const v = serve_root.getLiveVersion(name);

    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    const w = &aw.writer;

    try w.writeAll("<!DOCTYPE html><html><head><meta charset=\"utf-8\">");
    try w.writeAll("<meta name=\"viewport\" content=\"width=device-width,initial-scale=1\">");
    try w.print("<title>{s} — Sheet Editor</title>", .{name});
    try w.writeAll("<style>");
    try w.writeAll(assets_css.NAVBAR_CSS);
    try w.writeAll(EDITOR_CSS);
    try w.writeAll("</style></head><body>");

    // Minimal top bar (self-contained — no template dependency).
    try w.writeAll("<header class=\"ed-top\">");
    try w.print("<span class=\"ed-brand\">Sheet Editor <b>{s}</b></span>", .{name});
    try w.print("<a class=\"ed-link\" href=\"/schematics/{s}\">Schematic ↗</a>", .{name});
    try w.print("<a class=\"ed-link\" href=\"/pcb-layout/{s}\">PCB ↗</a>", .{name});
    try w.writeAll("<span class=\"ed-grow\"></span>");
    // Electrical-rule-check health chip (populated by the client from /api/erc).
    try w.writeAll("<button type=\"button\" id=\"ed-erc-chip\" class=\"ed-erc\" title=\"Electrical-rule checks — click for details\">ERC …</button>");
    try w.writeAll("<span class=\"ed-hint\">press <kbd>?</kbd> for keys</span>");
    try w.writeAll("</header>");

    // Floating ERC violations panel (toggled by the chip).
    try w.writeAll("<div id=\"ed-erc-panel\" class=\"ed-erc-panel\" hidden></div>");

    // App shell: left sheet navigator, left inspector, center canvas, bottom status.
    try w.writeAll("<div id=\"ed-app\">");
    try w.writeAll("<aside id=\"ed-sheets\"><div class=\"ed-sheets-h\">Sheets</div><div id=\"ed-sheet-list\"></div>");
    try w.writeAll("<label class=\"ed-iso\"><input type=\"checkbox\" id=\"ed-isolate\" checked> Isolate sheet</label></aside>");
    try w.writeAll("<aside id=\"ed-inspector\"></aside>");
    try w.writeAll("<main id=\"ed-canvas-wrap\"><canvas id=\"ed-canvas\"></canvas>");
    try w.writeAll("<div id=\"ed-status\"></div></main>");
    try w.writeAll("</div>");

    // Data block (consumed by the classic external script below, DOM order).
    // `name` is validated by `isSafeName` above (alphanumerics, `-`, `_`, `.`),
    // so it needs no JSON escaping; quote it directly. `scene` is design-derived
    // JSON and must be made `<script>`-safe (a net name could contain
    // `</script>`) — `writeScriptJson` escapes `<`.
    try w.writeAll("<script>");
    try w.print("window.DESIGN=\"{s}\";", .{name});
    try w.print("window.START_VERSION={d};", .{v});
    try w.writeAll("window.SCENE=");
    try writeScriptJson(w, scene);
    try w.writeAll(";</script>");
    try w.writeAll("<script src=\"/static/editor.js\"></script>");
    try w.writeAll("</body></html>");

    res.content_type = .HTML;
    res.body = aw.written();
}

const EDITOR_CSS = @embedFile("assets/editor.css");
