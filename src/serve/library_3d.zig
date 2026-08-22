//! 3D-model library endpoints: serve a component's STEP/model file, render the
//! WebGL viewer page, and persist the per-model placement transform
//! (offset/rotation/scale) that the KiCad model export later applies.

const std = @import("std");
const httpz = @import("httpz");
const infra_fs = @import("../infra/fs.zig");
const log = @import("../infra/log.zig");
const export_kicad = @import("../export_kicad.zig");
const footprint_mod = @import("../export_kicad_footprint.zig");
const parser_mod = @import("../sexpr/parser.zig");
const ast = @import("../sexpr/ast.zig");
const serve_root = @import("../serve.zig");
const lib_limits = @import("../lib_limits.zig");
const Server = serve_root.Server;

/// Percent-decode a URL path param. httpz returns params verbatim, so a
/// footprint whose name embeds a reserved char (a comma → `%2C`, e.g.
/// `74ahct1g125gm,132`) arrives encoded; decode before resolving it to a file.
fn urlDecode(allocator: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error![]u8 {
    const buf = try allocator.dupe(u8, raw);
    return std.Uri.percentDecodeInPlace(buf);
}

const max_model_bytes: usize = 64 * 1024 * 1024;
const max_body_bytes: usize = 16 * 1024;
const max_sprite_bytes: usize = 8 * 1024 * 1024;
const max_sprite_meta_bytes: usize = 2048;
const sprite_render_version = "2";
const sprite_cache_rel = "lib/models/.sprites";
const png_signature = "\x89PNG\r\n\x1a\n";

/// Route param name shared by all three handlers (`:footprint`).
const param_footprint = "footprint";
const escape = @import("../escape.zig");

/// A footprint name is a library basename. Reject anything with path
/// separators / traversal / markup so the decoded value is safe both as a file
/// path (no `..`/`/`) and reflected into HTML/JS (no `<`/`"`). Allows the
/// `,`/`#` reserved chars real footprint names round-trip through the URL.
fn isSafeFootprint(name: []const u8) bool {
    if (name.len == 0 or name.len > 128) return false;
    if (std.mem.indexOf(u8, name, "..") != null) return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '.' or c == '-' or c == '_' or c == ',' or c == '#';
        if (!ok) return false;
    }
    return true;
}
/// JSON tail emitted when the footprint has no parsable pads/courtyard:
/// closes the (empty) `pads` array and sets `courtyard` null.
const empty_pads_tail = "],\"courtyard\":null";

/// Error set for the 3D-viewer handlers: only writer/allocator failures
/// propagate; every filesystem fallibility is handled inline as a 4xx/404.
pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error;

// ── Model resolution ───────────────────────────────────────────────

/// Resolve the STEP model filename for a footprint the same way the KiCad
/// export does: an explicit `model` override in `model-config.json` wins,
/// else `findModelFile` (exact footprint/component match → substring scan).
/// Returns null when no model can be found.
fn resolveModelName(allocator: std.mem.Allocator, project_dir: []const u8, footprint: []const u8) ?[]const u8 {
    const cfg = export_kicad.loadModelConfig(allocator, project_dir);
    if (cfg.get(footprint)) |c| {
        if (c.model) |m| return allocator.dupe(u8, m) catch null;
    }
    return footprint_mod.findModelFile(allocator, project_dir, footprint, footprint);
}

// ── GET /api/model-file/:footprint ─────────────────────────────────

/// Stream the raw `.step` bytes for a footprint's resolved 3D model, so the
/// browser-side OpenCASCADE (occt-import-js) WASM can parse it. 404 when the
/// footprint has no model. Served as binary; the viewer fetches it once.
pub fn modelFileApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    if (std.mem.startsWith(u8, req.url.path, "/api/model-sprite/")) {
        if (req.method == .POST) return saveModelSpriteApi(ctx, req, res);
        return modelSpriteApi(ctx, req, res);
    }
    return serveModelFile(ctx, req, res);
}

fn serveModelFile(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const footprint_raw = req.param(param_footprint) orelse return notFound(res);
    const footprint = urlDecode(req.arena, footprint_raw) catch return notFound(res);
    if (!isSafeFootprint(footprint)) return notFound(res);
    const model_name = resolveModelName(req.arena, ctx.project_dir, footprint) orelse return notFound(res);
    const path = std.fmt.allocPrint(req.arena, "{s}/lib/models/{s}", .{ ctx.project_dir, model_name }) catch return notFound(res);
    const bytes = infra_fs.cwd().readFileAlloc(req.arena, path, max_model_bytes) catch return notFound(res);
    res.content_type = .BINARY;
    res.header("Cache-Control", "no-store");
    res.body = bytes;
}

// ── GET/POST /api/model-sprite/:footprint ────────────────────────

const SpriteBounds = struct { x: f64, y: f64, w: f64, h: f64 };

const SpriteSource = struct {
    key: u64,
    offset: [3]f64,
    rotation: [3]f64,
};

const CachedSprite = struct {
    bounds: SpriteBounds,
    png: []const u8,
};

/// Resolve the model identity that determines a sprite. File size/mtime avoids
/// reading a multi-megabyte STEP file on every assembly load; the transform and
/// renderer version ensure alignment or rendering changes cause a cache miss.
fn spriteSource(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    footprint: []const u8,
) ?SpriteSource {
    const model_name = resolveModelName(allocator, project_dir, footprint) orelse return null;
    const model_path = std.fmt.allocPrint(allocator, "{s}/lib/models/{s}", .{ project_dir, model_name }) catch return null;
    const stat = infra_fs.cwd().statFile(model_path) catch return null;
    const cfg = export_kicad.loadModelConfig(allocator, project_dir);
    const tf = cfg.get(footprint);
    const offset = if (tf) |t| t.offset else [3]f64{ 0, 0, 0 };
    const rotation = if (tf) |t| t.rotation else [3]f64{ 0, 0, 0 };

    var hash = std.hash.Wyhash.init(0x535052495445);
    hash.update(sprite_render_version);
    hash.update(model_name);
    var size = stat.size;
    var mtime = stat.mtime.nanoseconds;
    hash.update(std.mem.asBytes(&size));
    hash.update(std.mem.asBytes(&mtime));
    var transform_buf: [256]u8 = undefined;
    const transform = std.fmt.bufPrint(&transform_buf, "{d},{d},{d};{d},{d},{d}", .{
        offset[0], offset[1], offset[2], rotation[0], rotation[1], rotation[2],
    }) catch return null;
    hash.update(transform);
    return .{ .key = hash.final(), .offset = offset, .rotation = rotation };
}

fn spriteKeyText(buf: []u8, key: u64) []const u8 {
    return std.fmt.bufPrint(buf, "{x:0>16}", .{key}) catch "0";
}

fn spriteCachePath(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    footprint: []const u8,
    extension: []const u8,
) std.mem.Allocator.Error![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}/{s}.{s}", .{ project_dir, sprite_cache_rel, footprint, extension });
}

fn jsonFloat(value: std.json.Value) ?f64 {
    return switch (value) {
        .float => |n| n,
        .integer => |n| @floatFromInt(n),
        else => null,
    };
}

fn validBounds(bounds: SpriteBounds) bool {
    const values = [_]f64{ bounds.x, bounds.y, bounds.w, bounds.h };
    for (values) |value| if (!std.math.isFinite(value) or @abs(value) > 10_000) return false;
    return bounds.w > 0 and bounds.h > 0;
}

/// Read the cache only when its metadata key matches the current model source.
fn readSpriteCache(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    footprint: []const u8,
    source: SpriteSource,
) ?CachedSprite {
    const meta_path = spriteCachePath(allocator, project_dir, footprint, "json") catch return null;
    const meta_bytes = infra_fs.cwd().readFileAlloc(allocator, meta_path, max_sprite_meta_bytes) catch return null;
    const parsed = std.json.parseFromSliceLeaky(std.json.Value, allocator, meta_bytes, .{}) catch return null;
    const object = switch (parsed) {
        .object => |obj| obj,
        else => return null,
    };
    const key_value = object.get("key") orelse return null;
    const cached_key = switch (key_value) {
        .string => |value| value,
        else => return null,
    };
    var key_buf: [16]u8 = undefined;
    if (!std.mem.eql(u8, cached_key, spriteKeyText(&key_buf, source.key))) return null;
    const bounds = SpriteBounds{
        .x = jsonFloat(object.get("x") orelse return null) orelse return null,
        .y = jsonFloat(object.get("y") orelse return null) orelse return null,
        .w = jsonFloat(object.get("w") orelse return null) orelse return null,
        .h = jsonFloat(object.get("h") orelse return null) orelse return null,
    };
    if (!validBounds(bounds)) return null;
    const png_path = spriteCachePath(allocator, project_dir, footprint, "png") catch return null;
    const png = infra_fs.cwd().readFileAlloc(allocator, png_path, max_sprite_bytes) catch return null;
    if (!std.mem.startsWith(u8, png, png_signature)) return null;
    return .{ .bounds = bounds, .png = png };
}

fn writeAtomic(path: []const u8, bytes: []const u8) !void {
    var write_buf: [8192]u8 = undefined;
    var atomic = try infra_fs.cwd().atomicFile(path, .{ .write_buffer = &write_buf });
    defer atomic.deinit();
    try atomic.file_writer.interface.writeAll(bytes);
    try atomic.finish();
}

/// Store PNG first and metadata second. A crash between them remains a safe
/// miss because readers trust the picture only after matching the metadata key.
fn writeSpriteCache(
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    footprint: []const u8,
    key: []const u8,
    bounds: SpriteBounds,
    png: []const u8,
) !void {
    const dir = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_dir, sprite_cache_rel });
    try infra_fs.cwd().makePath(dir);
    const png_path = try spriteCachePath(allocator, project_dir, footprint, "png");
    try writeAtomic(png_path, png);

    var meta: std.Io.Writer.Allocating = .init(allocator);
    defer meta.deinit();
    try meta.writer.print(
        "{{\"key\":\"{s}\",\"x\":{d},\"y\":{d},\"w\":{d},\"h\":{d}}}\n",
        .{ key, bounds.x, bounds.y, bounds.w, bounds.h },
    );
    const meta_path = try spriteCachePath(allocator, project_dir, footprint, "json");
    try writeAtomic(meta_path, meta.written());
}

fn headerFloat(res: *httpz.Response, allocator: std.mem.Allocator, name: []const u8, value: f64) !void {
    res.header(name, try std.fmt.allocPrint(allocator, "{d}", .{value}));
}

fn sourceHeaders(res: *httpz.Response, allocator: std.mem.Allocator, source: SpriteSource) !void {
    var key_buf: [16]u8 = undefined;
    res.header("X-Netlisp-Sprite-Key", try allocator.dupe(u8, spriteKeyText(&key_buf, source.key)));
    res.header("X-Netlisp-Model-Offset", try std.fmt.allocPrint(allocator, "{d},{d},{d}", .{
        source.offset[0], source.offset[1], source.offset[2],
    }));
    res.header("X-Netlisp-Model-Rotation", try std.fmt.allocPrint(allocator, "{d},{d},{d}", .{
        source.rotation[0], source.rotation[1], source.rotation[2],
    }));
}

/// Serve a persistent transparent component picture. A miss still returns the
/// current source key and model transform in headers so the browser can render
/// exactly that version once and POST it back for later assembly loads.
fn modelSpriteApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const footprint_raw = req.param(param_footprint) orelse return notFound(res);
    const footprint = urlDecode(req.arena, footprint_raw) catch return notFound(res);
    if (!isSafeFootprint(footprint)) return notFound(res);
    const source = spriteSource(req.arena, ctx.project_dir, footprint) orelse return notFound(res);
    try sourceHeaders(res, req.arena, source);
    const cached = readSpriteCache(req.arena, ctx.project_dir, footprint, source) orelse return notFound(res);
    try headerFloat(res, req.arena, "X-Netlisp-Sprite-X", cached.bounds.x);
    try headerFloat(res, req.arena, "X-Netlisp-Sprite-Y", cached.bounds.y);
    try headerFloat(res, req.arena, "X-Netlisp-Sprite-W", cached.bounds.w);
    try headerFloat(res, req.arena, "X-Netlisp-Sprite-H", cached.bounds.h);
    res.header("Cache-Control", "no-store");
    res.content_type = .PNG;
    res.body = cached.png;
}

fn queryValue(req: *httpz.Request, key: []const u8) ?[]const u8 {
    const query = req.query() catch return null;
    return query.get(key);
}

fn queryFloat(req: *httpz.Request, key: []const u8) ?f64 {
    return std.fmt.parseFloat(f64, queryValue(req, key) orelse return null) catch null;
}

/// Accept the one-time browser-rendered PNG for the current STEP identity.
/// Stale renders are rejected by key, and bounded/signature-checked bodies keep
/// this generated-file endpoint from becoming an arbitrary upload surface.
fn saveModelSpriteApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    res.content_type = .JSON;
    const footprint_raw = req.param(param_footprint) orelse return badRequest(res, "missing footprint");
    const footprint = urlDecode(req.arena, footprint_raw) catch return badRequest(res, "invalid footprint");
    if (!isSafeFootprint(footprint)) return badRequest(res, "invalid footprint");
    const png = req.body() orelse return badRequest(res, "missing body");
    if (png.len > max_sprite_bytes or !std.mem.startsWith(u8, png, png_signature)) return badRequest(res, "invalid PNG");
    const source = spriteSource(req.arena, ctx.project_dir, footprint) orelse return notFound(res);
    const supplied_key = queryValue(req, "key") orelse return badRequest(res, "missing key");
    var key_buf: [16]u8 = undefined;
    if (!std.mem.eql(u8, supplied_key, spriteKeyText(&key_buf, source.key))) {
        res.status = 409;
        res.body = "{\"ok\":false,\"error\":\"stale model\"}";
        return;
    }
    const bounds = SpriteBounds{
        .x = queryFloat(req, "x") orelse return badRequest(res, "invalid bounds"),
        .y = queryFloat(req, "y") orelse return badRequest(res, "invalid bounds"),
        .w = queryFloat(req, "w") orelse return badRequest(res, "invalid bounds"),
        .h = queryFloat(req, "h") orelse return badRequest(res, "invalid bounds"),
    };
    if (!validBounds(bounds)) return badRequest(res, "invalid bounds");
    writeSpriteCache(req.arena, ctx.project_dir, footprint, supplied_key, bounds, png) catch |err| {
        log.warn("model-sprite: write {s} failed: {s}", .{ footprint, @errorName(err) });
        res.status = 500;
        res.body = "{\"ok\":false,\"error\":\"write failed\"}";
        return;
    };
    res.status = 201;
    res.body = "{\"ok\":true}";
}

// ── GET /library/3d/:footprint ─────────────────────────────────────

/// Render the standalone 3D alignment viewer for one footprint: a Three.js
/// scene with the footprint's copper pads laid flat + the STEP model on top,
/// plus rotation/offset controls that POST to `/api/model-transform/:fp`.
/// The page embeds the pads + courtyard + current transform as JSON; the
/// heavy lifting (STEP parse, render, gizmo) lives in `/static/model_viewer_3d.js`.
pub fn viewerPage(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    // `footprint_url` is the raw (still percent-encoded) param — kept for
    // re-emitting into the model-file URL; `footprint` is decoded for display,
    // config lookups, and pad parsing (so commas etc. resolve to the right file).
    const footprint_url = req.param(param_footprint) orelse return notFound(res);
    const footprint = urlDecode(req.arena, footprint_url) catch return notFound(res);
    if (!isSafeFootprint(footprint)) return notFound(res);

    const model_name = resolveModelName(req.arena, ctx.project_dir, footprint);

    const cfg = export_kicad.loadModelConfig(req.arena, ctx.project_dir);
    const tf = cfg.get(footprint);
    const offset = if (tf) |t| t.offset else [3]f64{ 0, 0, 0 };
    const rotation = if (tf) |t| t.rotation else [3]f64{ 0, 0, 0 };

    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    const w = &aw.writer;

    try w.writeAll("<!DOCTYPE html><html><head><meta charset=\"utf-8\">");
    // `footprint` is gated by isSafeFootprint (no `<`/`"`); `model_name` comes
    // from model-config.json and is escaped defensively.
    try w.writeAll("<title>3D — ");
    try escape.writeXml(w, footprint);
    try w.writeAll("</title>");
    try w.writeAll(page_css);
    try w.writeAll("</head><body>");

    // Header / toolbar.
    try w.writeAll("<div id=\"topbar\"><a id=\"back\" href=\"/library\">‹ Library</a>");
    try w.writeAll("<span id=\"fp-name\">");
    try escape.writeXml(w, footprint);
    try w.writeAll("</span>");
    if (model_name) |m| {
        try w.writeAll("<span id=\"model-name\">");
        try escape.writeXml(w, m);
        try w.writeAll("</span>");
    } else {
        try w.writeAll("<span id=\"model-name\" class=\"warn\">no STEP model found</span>");
    }
    try w.writeAll("<span id=\"save-state\"></span></div>");

    try w.writeAll("<div id=\"stage\"><canvas id=\"view\"></canvas><div id=\"status\">Loading 3D model…</div></div>");

    // Controls panel.
    try w.writeAll(controls_html);

    // Embedded data the viewer JS reads. Pads + courtyard come from the
    // footprint .sexp; offset/rotation from model-config.json.
    try w.writeAll("<script>window.VIEWER_DATA=");
    try writeViewerDataJson(w, req.arena, ctx.project_dir, footprint, footprint_url, model_name, offset, rotation);
    try w.writeAll(";</script>");

    try w.writeAll("<script src=\"/static/three.min.js\"></script>");
    try w.writeAll("<script src=\"/static/OrbitControls.js\"></script>");
    try w.writeAll("<script src=\"/static/occt-import-js.js\"></script>");
    try w.writeAll("<script src=\"/static/model_viewer_3d.js\"></script>");
    try w.writeAll("</body></html>");

    res.body = aw.written();
    res.content_type = .HTML;
}

/// Emit the `VIEWER_DATA` JSON object: footprint name, model availability,
/// the SMD/through pad rectangles, courtyard bounds, and current transform.
fn writeViewerDataJson(
    w: *std.Io.Writer,
    arena: std.mem.Allocator,
    project_dir: []const u8,
    footprint: []const u8,
    footprint_url: []const u8,
    model_name: ?[]const u8,
    offset: [3]f64,
    rotation: [3]f64,
) !void {
    try w.writeAll("{\"footprint\":");
    try writeJsonString(w, footprint);
    try w.writeAll(",\"model\":");
    if (model_name) |m| {
        try writeJsonString(w, m);
        // Keep the encoded form in the URL so reserved chars (`,`, `#`, …)
        // round-trip back through the router to the same file.
        try w.print(",\"modelUrl\":\"/api/model-file/{s}\"", .{footprint_url});
    } else {
        try w.writeAll("null,\"modelUrl\":null");
    }
    try w.print(
        ",\"offset\":[{d:.4},{d:.4},{d:.4}],\"rotation\":[{d:.4},{d:.4},{d:.4}]",
        .{ offset[0], offset[1], offset[2], rotation[0], rotation[1], rotation[2] },
    );

    try w.writeAll(",\"pads\":[");
    try writePadsAndCourtyard(w, arena, project_dir, footprint);
    try w.writeAll("}");
}

/// Parse the footprint `.sexp` and emit each pad as `{x,y,w,h,shape,type}`
/// (closing the `pads` array) followed by `,"courtyard":{…}` if present.
/// Coordinates are in millimetres in the footprint's own frame (X right,
/// Y down — the viewer flips Y to KiCad's 3D up-frame).
fn writePadsAndCourtyard(
    w: *std.Io.Writer,
    arena: std.mem.Allocator,
    project_dir: []const u8,
    footprint: []const u8,
) !void {
    const path = std.fmt.allocPrint(arena, "{s}/lib/footprints/{s}.sexp", .{ project_dir, footprint }) catch {
        try w.writeAll(empty_pads_tail);
        return;
    };
    const source = infra_fs.cwd().readFileAlloc(arena, path, lib_limits.max_footprint_bytes) catch {
        try w.writeAll(empty_pads_tail);
        return;
    };
    const nodes = parser_mod.parse(arena, source) catch {
        try w.writeAll(empty_pads_tail);
        return;
    };
    if (nodes.len == 0 or !nodes[0].isForm("footprint")) {
        try w.writeAll(empty_pads_tail);
        return;
    }
    const children = nodes[0].asList() orelse {
        try w.writeAll(empty_pads_tail);
        return;
    };

    var first = true;
    var courtyard: ?ast.Node = null;
    for (children) |child| {
        if (child.isForm("pad")) {
            try writePadJson(w, child, &first);
        } else if (child.isForm("courtyard")) {
            courtyard = child;
        }
    }
    try w.writeAll("]");

    try w.writeAll(",\"courtyard\":");
    if (courtyard) |c| {
        try writeCourtyardJson(w, c);
    } else {
        try w.writeAll("null");
    }
}

/// Emit one `(pad …)` form as `{x,y,w,h,shape,type,drill}`. Handles both the
/// numbered (`(pad "1" smd rect …)`) and unnumbered (`(pad npth circle …)`)
/// syntactic forms. `drill` is the hole diameter in mm (0 for SMD pads), so
/// the viewer can cut the board + draw the plating barrel for through-holes.
/// Skips pads without a `(pos …)`.
fn writePadJson(w: *std.Io.Writer, pad: ast.Node, first: *bool) !void {
    const nodes = pad.asList() orelse return;
    if (nodes.len < 3) return;
    const unnumbered = if (nodes[1].asAtom()) |a| isPadTypeKeyword(a) else false;
    const type_idx: usize = if (unnumbered) 1 else 2;
    const shape_idx: usize = if (unnumbered) 2 else 3;
    if (nodes.len <= shape_idx) return;

    const ptype = nodes[type_idx].asAtom() orelse "smd";
    const shape = nodes[shape_idx].asAtom() orelse "rect";

    var x: f64 = 0;
    var y: f64 = 0;
    var w_mm: f64 = 0;
    var h_mm: f64 = 0;
    var drill: f64 = 0;
    var has_pos = false;
    var poly_node: ?ast.Node = null;
    for (nodes[shape_idx + 1 ..]) |n| {
        if (n.isForm("pos")) {
            const pl = n.asList().?;
            if (pl.len >= 3) {
                x = pl[1].asNumber() orelse 0;
                y = pl[2].asNumber() orelse 0;
                has_pos = true;
            }
        } else if (n.isForm("size")) {
            const sl = n.asList().?;
            if (sl.len >= 3) {
                w_mm = sl[1].asNumber() orelse 0;
                h_mm = sl[2].asNumber() orelse 0;
            }
        } else if (n.isForm("drill")) {
            const dl = n.asList().?;
            // `(drill D)` scalar, or `(drill oval X Y)` — use the first numeric
            // token as the bore diameter (oval bores render as a round hole).
            if (dl.len >= 2) {
                drill = dl[1].asNumber() orelse (if (dl.len >= 3) dl[2].asNumber() orelse 0 else 0);
            }
        } else if (n.isForm("poly")) {
            poly_node = n;
        }
    }
    if (!has_pos) return;

    if (!first.*) try w.writeAll(",");
    first.* = false;
    try w.print(
        "{{\"x\":{d:.4},\"y\":{d:.4},\"w\":{d:.4},\"h\":{d:.4},\"shape\":\"{s}\",\"type\":\"{s}\",\"drill\":{d:.4}",
        .{ x, y, w_mm, h_mm, shape, ptype, drill },
    );
    // A custom pad's real copper outline (footprint-absolute coords) so the
    // viewer extrudes the polygon instead of the size bounding box.
    if (poly_node) |pn| try writePadPolyJson(w, pn);
    try w.writeAll("}");
}

/// Emit a pad's `(poly (x y) …)` outline as `,"poly":[[x,y],…]`.
fn writePadPolyJson(w: *std.Io.Writer, poly_node: ast.Node) !void {
    const pl = poly_node.asList() orelse return;
    try w.writeAll(",\"poly\":[");
    var first = true;
    for (pl[1..]) |pt| {
        const ptl = pt.asList() orelse continue;
        if (ptl.len < 2) continue;
        const px = ptl[0].asNumber() orelse continue;
        const py = ptl[1].asNumber() orelse continue;
        if (!first) try w.writeAll(",");
        first = false;
        try w.print("[{d:.4},{d:.4}]", .{ px, py });
    }
    try w.writeAll("]");
}

/// Emit a `(courtyard (rect X1 Y1 X2 Y2))` as `{x1,y1,x2,y2}`. A circular
/// courtyard degrades to its bounding box. Null when neither form parses.
fn writeCourtyardJson(w: *std.Io.Writer, courtyard: ast.Node) !void {
    const children = courtyard.asList() orelse return w.writeAll("null");
    for (children[1..]) |child| {
        if (child.isForm("rect")) {
            const cl = child.asList() orelse continue;
            if (cl.len < 5) continue;
            const x1 = cl[1].asNumber() orelse continue;
            const y1 = cl[2].asNumber() orelse continue;
            const x2 = cl[3].asNumber() orelse continue;
            const y2 = cl[4].asNumber() orelse continue;
            try w.print("{{\"x1\":{d:.4},\"y1\":{d:.4},\"x2\":{d:.4},\"y2\":{d:.4}}}", .{ x1, y1, x2, y2 });
            return;
        } else if (child.isForm("circle")) {
            const cl = child.asList() orelse continue;
            if (cl.len < 3) continue;
            const center = cl[1].asList() orelse continue;
            if (center.len < 2) continue;
            const cx = center[0].asNumber() orelse continue;
            const cy = center[1].asNumber() orelse continue;
            const r = cl[2].asNumber() orelse continue;
            try w.print(
                "{{\"x1\":{d:.4},\"y1\":{d:.4},\"x2\":{d:.4},\"y2\":{d:.4}}}",
                .{ cx - r, cy - r, cx + r, cy + r },
            );
            return;
        }
    }
    try w.writeAll("null");
}

/// True when `s` is an EDA pad-type keyword — used to tell the two `(pad …)`
/// forms apart (`(pad "1" smd …)` numbered vs `(pad npth circle …)`).
fn isPadTypeKeyword(s: []const u8) bool {
    return std.mem.eql(u8, s, "smd") or
        std.mem.eql(u8, s, "thru") or
        std.mem.eql(u8, s, "thru_hole") or
        std.mem.eql(u8, s, "np_thru") or
        std.mem.eql(u8, s, "np_thru_hole") or
        std.mem.eql(u8, s, "npth");
}

// ── POST /api/model-transform/:footprint ───────────────────────────

/// Persist a footprint's 3D-model `offset`/`rotation` into
/// `lib/models/model-config.json` (read-modify-write, preserving every other
/// part's entry + this part's optional `model` override). Body:
/// `{"offset":[x,y,z],"rotation":[x,y,z]}`. The KiCad sync's `loadModelConfig`
/// reads this on the next push, so the orientation lands on the board.
pub fn saveTransformApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    res.content_type = .JSON;
    const footprint_raw = req.param(param_footprint) orelse return badRequest(res, "missing footprint");
    const body = req.body() orelse return badRequest(res, "missing body");
    if (body.len > max_body_bytes) return badRequest(res, "body too large");

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // Decode `%2C`-style escapes so the config key matches the footprint name
    // (e.g. `74ahct1g125gm,132`) the KiCad sync looks up.
    const footprint = urlDecode(aa, footprint_raw) catch return badRequest(res, "invalid footprint");
    if (!isSafeFootprint(footprint)) return badRequest(res, "invalid footprint");

    const parsed = std.json.parseFromSliceLeaky(std.json.Value, aa, body, .{}) catch return badRequest(res, "invalid JSON");
    const offset = parseVec3(parsed, "offset") orelse return badRequest(res, "missing offset[3]");
    const rotation = parseVec3(parsed, "rotation") orelse return badRequest(res, "missing rotation[3]");

    writeModelConfig(aa, ctx.project_dir, footprint, offset, rotation) catch |e| {
        log.warn("model-transform: write {s} failed: {s}", .{ footprint, @errorName(e) });
        res.status = 500;
        res.body = "{\"ok\":false,\"error\":\"write failed\"}";
        return;
    };
    res.body = "{\"ok\":true}";
}

/// Pull a 3-element float array out of a JSON object field. Accepts integer
/// or float JSON numbers; returns null if absent, not an array, or < 3 long.
fn parseVec3(v: std.json.Value, key: []const u8) ?[3]f64 {
    const obj = switch (v) {
        .object => |o| o,
        else => return null,
    };
    const arr_v = obj.get(key) orelse return null;
    const arr = switch (arr_v) {
        .array => |a| a,
        else => return null,
    };
    if (arr.items.len < 3) return null;
    var out: [3]f64 = .{ 0, 0, 0 };
    for (0..3) |i| {
        out[i] = switch (arr.items[i]) {
            .float => |f| f,
            .integer => |n| @floatFromInt(n),
            else => return null,
        };
    }
    return out;
}

/// Read the existing `model-config.json` into a map, set/replace this
/// footprint's `offset`+`rotation` (keeping any `model` override and every
/// other entry), and write the whole map back atomically. A new file is
/// created when none exists.
fn writeModelConfig(
    arena: std.mem.Allocator,
    project_dir: []const u8,
    footprint: []const u8,
    offset: [3]f64,
    rotation: [3]f64,
) !void {
    const cfg = export_kicad.loadModelConfig(arena, project_dir);

    var buf: std.Io.Writer.Allocating = .init(arena);
    const w = &buf.writer;
    try w.writeAll("{\n");

    var wrote_target = false;
    var first = true;
    var it = cfg.iterator();
    while (it.next()) |entry| {
        const fp = entry.key_ptr.*;
        const is_target = std.mem.eql(u8, fp, footprint);
        const off = if (is_target) offset else entry.value_ptr.offset;
        const rot = if (is_target) rotation else entry.value_ptr.rotation;
        if (is_target) wrote_target = true;
        try writeConfigEntry(w, &first, fp, off, rot, entry.value_ptr.model);
    }
    if (!wrote_target) {
        try writeConfigEntry(w, &first, footprint, offset, rotation, null);
    }
    try w.writeAll("\n}\n");

    const dir = std.fmt.allocPrint(arena, "{s}/lib/models", .{project_dir});
    try infra_fs.cwd().makePath(try dir);
    const path = try std.fmt.allocPrint(arena, "{s}/lib/models/model-config.json", .{project_dir});
    try writeFileAtomic(arena, path, buf.written());
}

/// Emit one `"footprint":{"offset":[…],"rotation":[…][,"model":"…"]}` entry,
/// comma-separating from the previous one via `first`.
///
/// The `"offset":[` / `"rotation":[` / `"model":"` substrings must appear with
/// NO space after the colon — `loadModelConfig`'s hand-rolled scanner matches
/// those exact byte sequences, and a space makes it silently read zeros (which,
/// on the next read-modify-write, would wipe every transform + model override).
fn writeConfigEntry(
    w: anytype,
    first: *bool,
    footprint: []const u8,
    offset: [3]f64,
    rotation: [3]f64,
    model: ?[]const u8,
) !void {
    if (!first.*) try w.writeAll(",\n");
    first.* = false;
    try w.writeAll("  ");
    try writeJsonString(w, footprint);
    try w.print(
        ":{{\"offset\":[{d:.4},{d:.4},{d:.4}],\"rotation\":[{d:.4},{d:.4},{d:.4}]",
        .{ offset[0], offset[1], offset[2], rotation[0], rotation[1], rotation[2] },
    );
    if (model) |m| {
        try w.writeAll(",\"model\":");
        try writeJsonString(w, m);
    }
    try w.writeAll("}");
}

/// Write `content` to `path` via a temp-then-rename so a reader never sees a
/// half-written config.
fn writeFileAtomic(arena: std.mem.Allocator, path: []const u8, content: []const u8) !void {
    const tmp = try std.fmt.allocPrint(arena, "{s}.tmp", .{path});
    const f = try infra_fs.cwd().createFile(tmp, .{ .truncate = true });
    {
        defer f.close();
        try f.writeAll(content);
    }
    try infra_fs.cwd().rename(tmp, path);
}

// ── helpers ────────────────────────────────────────────────────────

/// The output is embedded inside `<script>window.VIEWER_DATA=…</script>`, so as
/// well as JSON-escaping this also escapes `<` (→ `<`) to prevent a
/// `</script>` breakout, and control chars (`\u00XX`).
fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            '<' => try w.writeAll("\\u003c"),
            else => if (c < 0x20) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

fn notFound(res: *httpz.Response) void {
    res.status = 404;
    res.body = "not found";
}

fn badRequest(res: *httpz.Response, msg: []const u8) void {
    res.status = 400;
    res.body = msg;
}

// ── Page chrome (CSS + static controls markup) ─────────────────────

const page_css = @embedFile("assets/model_viewer_3d.css");
const controls_html = @embedFile("assets/model_viewer_3d_controls.html");

// ── Tests ──────────────────────────────────────────────────────────

// spec: Web Server - the assembly model-picture cache invalidates when its STEP file or saved alignment changes
test "model sprite filesystem cache invalidates with model and transform" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "lib/models");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/models/demo.step", .data = "step-v1" });
    const project_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", aa);

    const first = spriteSource(aa, project_dir, "demo") orelse return error.TestUnexpectedResult;
    var first_key_buf: [16]u8 = undefined;
    const first_key = try aa.dupe(u8, spriteKeyText(&first_key_buf, first.key));
    const bounds = SpriteBounds{ .x = -1.25, .y = -2.5, .w = 3.75, .h = 4.5 };
    const png = png_signature ++ "cached-pixels";
    try writeSpriteCache(aa, project_dir, "demo", first_key, bounds, png);
    const hit = readSpriteCache(aa, project_dir, "demo", first) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(png, hit.png);
    try std.testing.expectApproxEqAbs(bounds.x, hit.bounds.x, 1e-9);
    try std.testing.expectApproxEqAbs(bounds.h, hit.bounds.h, 1e-9);

    // A replaced STEP cannot reuse the old picture even when its filename is
    // unchanged; changing the byte count makes the source identity distinct.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/models/demo.step", .data = "step-version-two" });
    const replaced = spriteSource(aa, project_dir, "demo") orelse return error.TestUnexpectedResult;
    try std.testing.expect(replaced.key != first.key);
    try std.testing.expect(readSpriteCache(aa, project_dir, "demo", replaced) == null);

    var replaced_key_buf: [16]u8 = undefined;
    const replaced_key = try aa.dupe(u8, spriteKeyText(&replaced_key_buf, replaced.key));
    try writeSpriteCache(aa, project_dir, "demo", replaced_key, bounds, png);
    try writeModelConfig(aa, project_dir, "demo", .{ 1, 0, 0 }, .{ 0, 0, 90 });
    const realigned = spriteSource(aa, project_dir, "demo") orelse return error.TestUnexpectedResult;
    try std.testing.expect(realigned.key != replaced.key);
    try std.testing.expect(readSpriteCache(aa, project_dir, "demo", realigned) == null);
}

test "writeModelConfig round-trips through loadModelConfig, preserving other entries + model overrides" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "lib/models");
    // Seed an existing config in the exact format loadModelConfig reads
    // (no space after the field colons), with a model override + non-zero
    // transforms — the values a regression must not clobber.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "lib/models/model-config.json", .data =
        \\{
        \\  "withmodel":{"model":"foo.step","offset":[0,0,0.06],"rotation":[90,0,0]},
        \\  "plain":{"offset":[23.75,9.5,-5.25],"rotation":[0,0,0]}
        \\}
    });
    const proj = try tmp.dir.realPathFileAlloc(std.testing.io, ".", aa);

    // Add a brand-new entry.
    try writeModelConfig(aa, proj, "newpart", .{ 1, -2, 3 }, .{ 45, 0, 180 });

    var cfg = export_kicad.loadModelConfig(aa, proj);
    const tol = 1e-3;
    // New entry persisted with its exact values.
    const np = cfg.get("newpart").?;
    try std.testing.expectApproxEqAbs(@as(f64, 1), np.offset[0], tol);
    try std.testing.expectApproxEqAbs(@as(f64, -2), np.offset[1], tol);
    try std.testing.expectApproxEqAbs(@as(f64, 3), np.offset[2], tol);
    try std.testing.expectApproxEqAbs(@as(f64, 180), np.rotation[2], tol);
    // Existing entries untouched — including the model override and the
    // non-zero offset that the format bug used to silently zero out.
    const wm = cfg.get("withmodel").?;
    try std.testing.expectEqualStrings("foo.step", wm.model.?);
    try std.testing.expectApproxEqAbs(@as(f64, 0.06), wm.offset[2], tol);
    try std.testing.expectApproxEqAbs(@as(f64, 90), wm.rotation[0], tol);
    const pl = cfg.get("plain").?;
    try std.testing.expectApproxEqAbs(@as(f64, 23.75), pl.offset[0], tol);
    try std.testing.expectApproxEqAbs(@as(f64, -5.25), pl.offset[2], tol);

    // Updating an existing entry keeps its model override.
    try writeModelConfig(aa, proj, "withmodel", .{ 0, 0, 9 }, .{ 0, 0, 0 });
    var cfg2 = export_kicad.loadModelConfig(aa, proj);
    const wm2 = cfg2.get("withmodel").?;
    try std.testing.expectEqualStrings("foo.step", wm2.model.?);
    try std.testing.expectApproxEqAbs(@as(f64, 9), wm2.offset[2], tol);
    // And the sibling survived the rewrite.
    try std.testing.expectApproxEqAbs(@as(f64, 23.75), cfg2.get("plain").?.offset[0], tol);
}

test "writeJsonString emits a literal space, escaping only sub-0x20 controls" {
    // The `c < 0x20` guard escapes control chars only; a `<`->`<=` flip would
    // also escape 0x20 (space) as \\u0020 instead of writing it verbatim.
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try writeJsonString(&aw.writer, "a b");
    try std.testing.expectEqualStrings("\"a b\"", aw.written());
}
