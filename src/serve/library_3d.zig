const std = @import("std");
const httpz = @import("httpz");
const infra_fs = @import("../infra/fs.zig");
const log = @import("../infra/log.zig");
const export_kicad = @import("../export_kicad.zig");
const footprint_mod = @import("../export_kicad_footprint.zig");
const parser_mod = @import("../sexpr/parser.zig");
const ast = @import("../sexpr/ast.zig");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;

const MAX_FOOTPRINT_BYTES: usize = 256 * 1024;
const MAX_MODEL_BYTES: usize = 64 * 1024 * 1024;
const MAX_BODY_BYTES: usize = 16 * 1024;

/// Route param name shared by all three handlers (`:footprint`).
const PARAM_FOOTPRINT = "footprint";
/// JSON tail emitted when the footprint has no parsable pads/courtyard:
/// closes the (empty) `pads` array and sets `courtyard` null.
const EMPTY_PADS_TAIL = "],\"courtyard\":null";

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
pub fn modelFileApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const footprint = req.param(PARAM_FOOTPRINT) orelse return notFound(res);
    const model_name = resolveModelName(req.arena, ctx.project_dir, footprint) orelse return notFound(res);
    const path = std.fmt.allocPrint(req.arena, "{s}/lib/models/{s}", .{ ctx.project_dir, model_name }) catch return notFound(res);
    const bytes = infra_fs.cwd().readFileAlloc(req.arena, path, MAX_MODEL_BYTES) catch return notFound(res);
    res.content_type = .BINARY;
    res.header("Cache-Control", "no-store");
    res.body = bytes;
}

// ── GET /library/3d/:footprint ─────────────────────────────────────

/// Render the standalone 3D alignment viewer for one footprint: a Three.js
/// scene with the footprint's copper pads laid flat + the STEP model on top,
/// plus rotation/offset controls that POST to `/api/model-transform/:fp`.
/// The page embeds the pads + courtyard + current transform as JSON; the
/// heavy lifting (STEP parse, render, gizmo) lives in `/static/model_viewer_3d.js`.
pub fn viewerPage(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const footprint = req.param(PARAM_FOOTPRINT) orelse return notFound(res);

    const model_name = resolveModelName(req.arena, ctx.project_dir, footprint);

    const cfg = export_kicad.loadModelConfig(req.arena, ctx.project_dir);
    const tf = cfg.get(footprint);
    const offset = if (tf) |t| t.offset else [3]f64{ 0, 0, 0 };
    const rotation = if (tf) |t| t.rotation else [3]f64{ 0, 0, 0 };

    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    const w = &aw.writer;

    try w.writeAll("<!DOCTYPE html><html><head><meta charset=\"utf-8\">");
    try w.print("<title>3D — {s}</title>", .{footprint});
    try w.writeAll(PAGE_CSS);
    try w.writeAll("</head><body>");

    // Header / toolbar.
    try w.writeAll("<div id=\"topbar\"><a id=\"back\" href=\"/library\">‹ Library</a>");
    try w.print("<span id=\"fp-name\">{s}</span>", .{footprint});
    if (model_name) |m| {
        try w.print("<span id=\"model-name\">{s}</span>", .{m});
    } else {
        try w.writeAll("<span id=\"model-name\" class=\"warn\">no STEP model found</span>");
    }
    try w.writeAll("<span id=\"save-state\"></span></div>");

    try w.writeAll("<div id=\"stage\"><canvas id=\"view\"></canvas><div id=\"status\">Loading 3D model…</div></div>");

    // Controls panel.
    try w.writeAll(CONTROLS_HTML);

    // Embedded data the viewer JS reads. Pads + courtyard come from the
    // footprint .sexp; offset/rotation from model-config.json.
    try w.writeAll("<script>window.VIEWER_DATA=");
    try writeViewerDataJson(w, req.arena, ctx.project_dir, footprint, model_name, offset, rotation);
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
    model_name: ?[]const u8,
    offset: [3]f64,
    rotation: [3]f64,
) !void {
    try w.writeAll("{\"footprint\":");
    try writeJsonString(w, footprint);
    try w.writeAll(",\"model\":");
    if (model_name) |m| {
        try writeJsonString(w, m);
        try w.print(",\"modelUrl\":\"/api/model-file/{s}\"", .{footprint});
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
        try w.writeAll(EMPTY_PADS_TAIL);
        return;
    };
    const source = infra_fs.cwd().readFileAlloc(arena, path, MAX_FOOTPRINT_BYTES) catch {
        try w.writeAll(EMPTY_PADS_TAIL);
        return;
    };
    const nodes = parser_mod.parse(arena, source) catch {
        try w.writeAll(EMPTY_PADS_TAIL);
        return;
    };
    if (nodes.len == 0 or !nodes[0].isForm("footprint")) {
        try w.writeAll(EMPTY_PADS_TAIL);
        return;
    }
    const children = nodes[0].asList() orelse {
        try w.writeAll(EMPTY_PADS_TAIL);
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
        }
    }
    if (!has_pos) return;

    if (!first.*) try w.writeAll(",");
    first.* = false;
    try w.print(
        "{{\"x\":{d:.4},\"y\":{d:.4},\"w\":{d:.4},\"h\":{d:.4},\"shape\":\"{s}\",\"type\":\"{s}\",\"drill\":{d:.4}}}",
        .{ x, y, w_mm, h_mm, shape, ptype, drill },
    );
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
pub fn saveTransformApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    res.content_type = .JSON;
    const footprint = req.param(PARAM_FOOTPRINT) orelse return badRequest(res, "missing footprint");
    const body = req.body() orelse return badRequest(res, "missing body");
    if (body.len > MAX_BODY_BYTES) return badRequest(res, "body too large");

    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

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

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(arena);
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
    try writeFileAtomic(arena, path, buf.items);
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

fn writeJsonString(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => try w.writeByte(c),
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

const PAGE_CSS = @embedFile("assets/model_viewer_3d.css");
const CONTROLS_HTML = @embedFile("assets/model_viewer_3d_controls.html");

// ── Tests ──────────────────────────────────────────────────────────

test "writeModelConfig round-trips through loadModelConfig, preserving other entries + model overrides" {
    const alloc = std.testing.allocator;
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const aa = arena.allocator();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.makePath("lib/models");
    // Seed an existing config in the exact format loadModelConfig reads
    // (no space after the field colons), with a model override + non-zero
    // transforms — the values a regression must not clobber.
    try tmp.dir.writeFile(.{ .sub_path = "lib/models/model-config.json", .data = 
        \\{
        \\  "withmodel":{"model":"foo.step","offset":[0,0,0.06],"rotation":[90,0,0]},
        \\  "plain":{"offset":[23.75,9.5,-5.25],"rotation":[0,0,0]}
        \\}
    });
    const proj = try tmp.dir.realpathAlloc(aa, ".");

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
