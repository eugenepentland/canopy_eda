//! Full-screen library footprint editor and its source-preserving save API.

const std = @import("std");
const httpz = @import("httpz");
const infra_fs = @import("../infra/fs.zig");
const parser = @import("../sexpr/parser.zig");
const escape = @import("../escape.zig");
const serve_root = @import("../serve.zig");
const lib_limits = @import("../lib_limits.zig");
const navbar = @import("navbar.zig");
const Server = serve_root.Server;

pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error;
const max_pads: usize = 2048;
const footprint_not_found = "Footprint not found";

const PadEdit = struct {
    id: []const u8,
    type: []const u8,
    shape: []const u8,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    drill_x: f64 = 0,
    drill_y: f64 = 0,
    roundrect_ratio: ?f64 = null,
    mask_margin: ?f64 = null,
    no_paste: bool = false,
    paste: ?[]const @import("../footprint_paste.zig").Aperture = null,
    poly: ?[][]f64 = null,
};

const PadChange = struct {
    index: usize,
    remove: bool = false,
    pad: ?PadEdit = null,
};

const PolygonEdit = struct { poly: [][]f64 };
const CourtyardEdit = struct { x0: f64 = 0, y0: f64 = 0, x1: f64 = 0, y1: f64 = 0, poly: ?[][]f64 = null };
const ArtworkEdit = struct {
    lines: [][]f64 = &.{},
    circles: [][]f64 = &.{},
    rects: [][]f64 = &.{},
    polys: []const PolygonEdit = &.{},
};

const SaveRequest = struct {
    revision: []const u8,
    // Read-only after parsing: `validateRequest` and `rewrite` only iterate,
    // and `findChange` already takes `[]const`. Const so a caller can pass a
    // literal payload — the JSON parser fills either spelling.
    changes: []const PadChange = &.{},
    additions: []const PadEdit = &.{},
    courtyard: ?CourtyardEdit = null,
    silk: ?ArtworkEdit = null,
    fab: ?ArtworkEdit = null,
};

const FormKind = enum { pad, courtyard, silk, fab };
const FormSpan = struct { start: usize, end: usize, kind: FormKind, pad_index: usize = 0 };
const Scan = struct { forms: []const FormSpan, root_close: usize, pad_count: usize };

/// GET /library/footprint/:name — a precise, full-screen footprint editor.
pub fn editorPage(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = 404;
        return;
    };
    if (!safeName(name)) {
        res.status = 400;
        res.body = "Invalid footprint name";
        return;
    }
    const path = try std.fmt.allocPrint(ctx.allocator, "{s}/lib/footprints/{s}.sexp", .{ ctx.project_dir, name });
    defer ctx.allocator.free(path);
    infra_fs.cwd().access(path, .{}) catch {
        res.status = 404;
        res.body = footprint_not_found;
        return;
    };

    var aw: std.Io.Writer.Allocating = .init(ctx.allocator);
    const w = &aw.writer;
    try w.writeAll(
        \\<!doctype html><html><head><meta charset="utf-8">
        \\<meta name="viewport" content="width=device-width,initial-scale=1">
        \\<title>
    );
    try escape.writeXml(w, name);
    try w.writeAll(
        \\ — Footprint editor</title>
        \\<style>
    );
    try w.writeAll(navbar.css);
    try w.writeAll(
        \\</style><link rel="stylesheet" href="/static/footprint_editor.css"></head>
        \\<body data-footprint="
    );
    try escape.writeXml(w, name);
    try w.writeAll(
        \\">
    );
    try navbar.write(w, .library);
    const recipe_path = try std.fmt.allocPrint(req.arena, "{s}/lib/packages/{s}.json", .{ ctx.project_dir, name });
    if (infra_fs.cwd().access(recipe_path, .{})) |_| {
        try w.writeAll("<div style=\"padding:8px 18px\"><a href=\"/library/package?name=");
        try (std.Uri.Component{ .raw = name }).formatEscaped(w);
        try w.writeAll("\">Edit package dimensions ↗</a> · Pad and artwork edits are saved as package overrides.</div>");
    } else |_| {}
    try w.writeAll(
        \\<header class="topbar">
        \\  <a class="back" href="/library" title="Back to component library">‹ Library</a>
        \\  <div class="title"><strong>
    );
    try escape.writeXml(w, name);
    try w.writeAll(
        \\</strong><span id="dirty-label">Saved</span></div>
        \\  <div class="toolbar" role="toolbar" aria-label="Footprint tools">
        \\    <button class="tool active" data-tool="select" title="Select and move pads (S)">↖ Select</button>
        \\    <button class="tool" data-tool="dim-aligned" title="Aligned dimension (D)">↔ Dimension</button>
        \\    <button class="tool" data-tool="dim-horizontal" title="Horizontal dimension (H)">⇆ X</button>
        \\    <button class="tool" data-tool="dim-vertical" title="Vertical dimension (V)">⇅ Y</button>
        \\    <button class="tool" data-tool="construction" title="Driving construction line (C)">╱ Construction</button>
        \\    <span class="divider"></span>
        \\    <button id="add-pad" title="Add a pad (A)">＋ Pad</button>
        \\    <button id="fit-view" title="Fit footprint in view (F)">Fit</button>
        \\  </div>
        \\  <div class="top-actions">
        \\    <button id="undo" title="Undo (Ctrl+Z)" disabled>Undo</button>
        \\    <button id="redo" title="Redo (Ctrl+Shift+Z)" disabled>Redo</button>
        \\    <button id="save" class="primary" title="Save (Ctrl+S)" disabled>Save footprint</button>
        \\  </div>
        \\</header>
        \\<main>
        \\  <aside class="left-panel panel">
        \\    <section><h2>View</h2>
        \\      <label>Grid <select id="grid">
        \\        <option value="0.01">0.01 mm</option><option value="0.025">0.025 mm</option>
        \\        <option value="0.05">0.05 mm</option><option value="0.1" selected>0.10 mm</option>
        \\        <option value="0.25">0.25 mm</option><option value="0.5">0.50 mm</option>
        \\        <option value="1">1.00 mm</option></select></label>
        \\      <label>Units <select id="units"><option value="mm">mm</option>
        \\        <option value="mil">mil</option></select></label>
        \\      <label class="check"><input id="snap" type="checkbox" checked> Snap to geometry</label>
        \\    </section>
        \\    <section class="help"><h2>Select pads</h2>
        \\      <p>Shift-click to add or remove a pad. Drag empty canvas to marquee-select.
        \\      Drag any selected pad to move the whole group. <kbd>Ctrl+A</kbd> selects all.</p>
        \\    </section>
        \\    <section><h2>Layers</h2>
        \\      <label class="layer copper"><input data-layer="pads" type="checkbox" checked> Copper pads</label>
        \\      <label class="layer silk"><input data-layer="silk" type="checkbox" checked> Silkscreen</label>
        \\      <label class="layer fab"><input data-layer="fab" type="checkbox" checked> Fabrication</label>
        \\      <label class="layer court"><input data-layer="courtyard" type="checkbox" checked> Courtyard</label>
        \\    </section>
        \\    <section class="help"><h2>Dimension tool</h2>
        \\      <p>Choose aligned, X, or Y. Click two snapped points, then click to place the dimension.
        \\      Dimensions are verification annotations kept in this browser, not exported as copper.</p>
        \\      <p><strong>Construction:</strong> click two pad edges. In the sidebar, center the line on
        \\      the origin and enter a driving length to move the attached pads.</p>
        \\      <p><kbd>Esc</kbd> cancel · wheel zoom · middle/space drag pan</p>
        \\    </section>
        \\  </aside>
        \\  <section class="canvas-wrap" id="canvas-wrap">
        \\    <svg id="editor-svg" xmlns="http://www.w3.org/2000/svg" aria-label="Footprint drawing canvas">
        \\      <defs><pattern id="minor-grid" width="1" height="1" patternUnits="userSpaceOnUse">
        \\        <path d="M 1 0 L 0 0 0 1" fill="none"/></pattern></defs>
        \\      <g id="viewport"><rect id="grid-plane"/><g id="geometry"></g>
        \\        <g id="dimensions"></g><g id="interaction"></g></g>
        \\    </svg>
        \\    <div id="cursor-readout">X 0.000 · Y 0.000 mm</div>
        \\    <div id="tool-hint">Select a pad or choose a dimension tool</div>
        \\  </section>
    );
    try writeRightPanel(w);
    res.body = aw.written();
    res.content_type = .HTML;
}

fn writeRightPanel(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.writeAll(
        \\  <aside class="right-panel panel">
        \\    <section id="nothing-selected"><h2>Inspector</h2>
        \\      <p>Select a pad to edit exact dimensions and position.</p></section>
        \\    <section id="pad-inspector" hidden><div class="section-head"><h2 id="pad-inspector-title">Pad</h2><div>
        \\      <button id="duplicate-pad" title="Duplicate pad (Ctrl+D)">Duplicate</button>
        \\      <button id="delete-pad" class="danger" title="Delete pad (Delete)">Delete</button>
        \\    </div></div>
        \\      <div class="form-grid">
        \\        <label>Number / name<input id="pad-id" type="text" maxlength="64"></label>
        \\        <label>Type<select id="pad-type"><option value="smd">SMD</option>
        \\          <option value="thru">Through-hole</option><option value="npth">NPTH</option>
        \\        </select></label>
        \\        <label>Shape<select id="pad-shape"><option value="rect">Rectangle</option>
        \\          <option value="roundrect">Rounded rect</option><option value="oval">Oval</option>
        \\          <option value="circle">Circle</option><option value="custom">Custom</option>
        \\        </select></label>
        \\        <label class="readonly-note" id="custom-note" hidden>Custom polygons use the shared shape sketch tools below.</label>
        \\        <label class="readonly-note multi-note" id="multi-note" hidden>Width and height apply to every
        \\        selected pad. Group center X/Y moves them together while preserving their spacing.</label>
        \\        <label><span id="pad-x-label">X</span><input id="pad-x" class="expression-input" type="text" inputmode="decimal"></label>
        \\        <label><span id="pad-y-label">Y</span><input id="pad-y" class="expression-input" type="text" inputmode="decimal"></label>
        \\        <label>Width<input id="pad-w" class="expression-input" type="text" inputmode="decimal"></label>
        \\        <label>Height<input id="pad-h" class="expression-input" type="text" inputmode="decimal"></label>
        \\        <label>Drill X<input id="pad-drill-x" class="expression-input" type="text" inputmode="decimal"></label>
        \\        <label>Drill Y<input id="pad-drill-y" class="expression-input" type="text" inputmode="decimal"></label>
        \\        <p class="expression-help">Math accepted: <code>0.4-2</code>, <code>2.54/2</code>, <code>(1+2)*0.5</code></p>
        \\      </div>
        \\    </section>
        \\    <section id="shape-sketch-panel"><div class="section-head"><h2>Shape sketch</h2><button id="shape-finish">Finish</button></div>
        \\      <p class="muted" id="shape-status">Select a custom pad, courtyard, silk polygon, or fab polygon.</p>
        \\      <div class="shape-tools"><span>Create</span><button data-shape="rect">Rectangle</button><button data-shape="line-tool">Line</button><button data-shape="dimension">Dimension</button></div>
        \\      <div class="shape-tools"><span>Constrain</span><button data-shape="horizontal">H</button><button data-shape="vertical">V</button><button data-shape="coincident">Coincident</button><button data-shape="parallel">∥</button><button data-shape="perpendicular">⟂</button><button data-shape="tangent">Tangent</button><button data-shape="equal">Equal</button><button data-shape="midpoint">Midpoint</button><button data-shape="symmetric">Symmetry</button><button data-shape="fixed">Fix</button></div>
        \\      <div class="shape-tools"><span>Modify</span><button data-shape="arc">Arc</button><button data-shape="line">Line</button><button data-shape="fillet">Fillet</button><button data-shape="remove-fillet">Remove fillet</button><button data-shape="chamfer">Chamfer</button><button data-shape="offset">Offset</button><button data-shape="mirror-x">Mirror X</button><button data-shape="mirror-y">Mirror Y</button><button data-shape="delete">Delete</button></div>
        \\      <div class="shape-tools"><span>Artwork</span><button id="edit-courtyard">Courtyard</button><button id="add-silk-poly">+ Silk polygon</button><button id="add-fab-poly">+ Fab polygon</button></div>
        \\    </section>
        \\    <section><div class="section-head"><h2>Courtyard</h2>
        \\      <button id="court-from-pads">Fit to pads</button></div>
        \\      <div class="form-grid">
        \\        <label>Left<input id="court-x0" class="expression-input" type="text" inputmode="decimal"></label>
        \\        <label>Top<input id="court-y0" class="expression-input" type="text" inputmode="decimal"></label>
        \\        <label>Right<input id="court-x1" class="expression-input" type="text" inputmode="decimal"></label>
        \\        <label>Bottom<input id="court-y1" class="expression-input" type="text" inputmode="decimal"></label>
        \\        <label>Pad clearance
        \\          <input id="court-clearance" class="expression-input" type="text" inputmode="decimal" value="0.25"></label>
        \\      </div>
        \\    </section>
        \\    <section><div class="section-head"><h2>Constructions</h2><button id="clear-constructions">Clear</button></div>
        \\      <p class="muted construction-intro">Driving sketch geometry. Attach endpoints to pad edges, optionally center on the origin, then edit the length.</p>
        \\      <div id="construction-list" class="construction-list"><p class="muted">No construction lines yet.</p></div>
        \\    </section>
        \\    <section><div class="section-head"><h2>Dimensions</h2><button id="clear-dims">Clear</button></div>
        \\      <div id="dimension-list" class="dimension-list"><p class="muted">No dimensions yet.</p></div>
        \\    </section>
        \\  </aside>
        \\</main>
        \\<div id="toast" role="status"></div>
        \\<script src="/static/footprint_svg.js"></script><script src="/static/shape_sketch.js"></script><script src="/static/footprint_editor.js"></script>
        \\</body></html>
    );
}

/// POST /api/footprint/:name — atomically apply edited/new/deleted pads and a
/// rectangular courtyard. Unchanged top-level source forms stay byte-for-byte
/// intact, including descriptions, silk, fab, and project-specific metadata.
pub fn saveApi(ctx: *Server, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const mutation = @import("../infra/source_transaction.zig").begin(ctx.project_dir) catch return sendError(res, 500, "Cannot lock project");
    defer mutation.unlock();
    const name = req.param("name") orelse return sendError(res, 404, footprint_not_found);
    if (!safeName(name)) return sendError(res, 400, "Invalid footprint name");
    const body = req.body() orelse return sendError(res, 400, "Missing request body");
    const payload = std.json.parseFromSliceLeaky(SaveRequest, req.arena, body, .{ .ignore_unknown_fields = true }) catch
        return sendError(res, 400, "Invalid editor data");
    if (payload.changes.len + payload.additions.len > max_pads) return sendError(res, 400, "Too many pad edits");

    const path = try std.fmt.allocPrint(ctx.allocator, "{s}/lib/footprints/{s}.sexp", .{ ctx.project_dir, name });
    defer ctx.allocator.free(path);
    const src = infra_fs.cwd().readFileAlloc(ctx.allocator, path, lib_limits.max_footprint_bytes) catch
        return sendError(res, 404, footprint_not_found);
    // `ctx.allocator` is the SERVER's allocator, not the per-request arena, so
    // everything taken from it here has to be given back on every exit path —
    // otherwise each save leaks the footprint source for the process's life.
    defer ctx.allocator.free(src);
    const current_rev = try std.fmt.allocPrint(ctx.allocator, "{x}", .{std.hash.Wyhash.hash(0, src)});
    defer ctx.allocator.free(current_rev);
    if (!std.mem.eql(u8, payload.revision, current_rev)) {
        return sendError(res, 409, "Footprint changed on disk; reload before saving");
    }

    const scan = scanTopForms(ctx.allocator, src) catch return sendError(res, 400, "Malformed footprint source");
    defer ctx.allocator.free(scan.forms);
    if (scan.pad_count + payload.additions.len > max_pads) return sendError(res, 400, "Footprint has too many pads");
    if (!validateRequest(req.arena, payload, scan.pad_count)) {
        return sendError(res, 400, "Pad or courtyard values are invalid");
    }

    const updated = rewrite(ctx.allocator, src, scan, payload) catch
        return sendError(res, 500, "Could not rewrite footprint");
    // Freed after `nodes` below: the parsed nodes borrow slices out of it, and
    // defers run last-in-first-out.
    defer ctx.allocator.free(updated);
    const nodes = parser.parse(ctx.allocator, updated) catch
        return sendError(res, 400, "Edited footprint is not valid S-expression syntax");
    defer parser.freeNodes(ctx.allocator, nodes);
    if (nodes.len == 0 or !nodes[0].isForm("footprint")) return sendError(res, 400, "Edited source is not a footprint");
    if (try saveGenerated(ctx, req, res, name, payload)) return;
    atomicWrite(path, updated) catch return sendError(res, 500, "Could not save footprint");

    res.content_type = .JSON;
    const new_revision = std.hash.Wyhash.hash(0, updated);
    res.body = try std.fmt.allocPrint(
        req.arena,
        "{{\"ok\":true,\"revision\":\"{x}\"}}",
        .{new_revision},
    );
}

fn sendError(res: *httpz.Response, status: u16, msg: []const u8) void {
    res.status = status;
    res.body = msg;
}

fn safeName(name: []const u8) bool {
    if (name.len == 0 or name.len > 128 or std.mem.indexOf(u8, name, "..") != null) return false;
    for (name) |c| if (c == '/' or c == '\\' or c < 0x20) return false;
    return true;
}

fn finiteBounded(v: f64) bool {
    return std.math.isFinite(v) and @abs(v) <= 1000;
}

fn validatePad(p: PadEdit) bool {
    if (p.id.len == 0 or p.id.len > 64) return false;
    if (!oneOf(p.type, &.{ "smd", "thru", "npth" })) return false;
    if (!oneOf(p.shape, &.{ "rect", "roundrect", "oval", "circle", "custom" })) return false;
    if (!finiteBounded(p.x) or !finiteBounded(p.y)) return false;
    if (!finiteBounded(p.w) or !finiteBounded(p.h)) return false;
    if (p.w <= 0 or p.h <= 0) return false;
    if (p.drill_x < 0 or p.drill_y < 0) return false;
    if (!finiteBounded(p.drill_x) or !finiteBounded(p.drill_y)) return false;
    if (p.roundrect_ratio) |r| {
        if (!std.math.isFinite(r)) return false;
        if (r < 0 or r > 0.5) return false;
    }
    if (p.mask_margin) |m| if (!finiteBounded(m)) return false;
    if (p.poly) |poly| {
        if (poly.len < 3 or poly.len > 512) return false;
        for (poly) |point| {
            if (point.len < 2) return false;
            if (!finiteBounded(point[0]) or !finiteBounded(point[1])) return false;
        }
    } else if (std.mem.eql(u8, p.shape, "custom")) return false;
    if (p.paste) |windows| if (!@import("../footprint_paste.zig").valid(windows, p.w, p.h)) return false;
    return true;
}

fn validatePointArray(poly: []const []const f64, min_len: usize) bool {
    if (poly.len < min_len or poly.len > 512) return false;
    for (poly) |point| {
        if (point.len < 2) return false;
        if (!finiteBounded(point[0]) or !finiteBounded(point[1])) return false;
    }
    return true;
}

fn validateArtwork(art: ArtworkEdit) bool {
    for (art.lines) |line| if (!validNumbers(line, 4, false)) return false;
    for (art.circles) |circle| if (!validNumbers(circle, 3, true)) return false;
    for (art.rects) |rect| if (!validNumbers(rect, 4, false)) return false;
    for (art.polys) |poly| if (!validatePointArray(poly.poly, 3)) return false;
    return true;
}

fn validNumbers(values: []const f64, count: usize, positive_last: bool) bool {
    if (values.len < count) return false;
    for (values[0..count]) |value| if (!finiteBounded(value)) return false;
    return !positive_last or values[count - 1] > 0;
}

fn oneOf(value: []const u8, choices: []const []const u8) bool {
    for (choices) |choice| if (std.mem.eql(u8, value, choice)) return true;
    return false;
}

fn validateRequest(allocator: std.mem.Allocator, payload: SaveRequest, old_pad_count: usize) bool {
    var seen = std.DynamicBitSetUnmanaged.initEmpty(allocator, old_pad_count) catch return false;
    defer seen.deinit(allocator);
    for (payload.changes) |change| {
        if (change.index >= old_pad_count or seen.isSet(change.index)) return false;
        seen.set(change.index);
        if (!change.remove) {
            const pad = change.pad orelse return false;
            if (!validatePad(pad)) return false;
        }
    }
    for (payload.additions) |pad| if (!validatePad(pad)) return false;
    if (payload.courtyard) |c| {
        if (c.poly) |poly| {
            if (!validatePointArray(poly, 3)) return false;
        } else {
            if (!finiteBounded(c.x0) or !finiteBounded(c.y0)) return false;
            if (!finiteBounded(c.x1) or !finiteBounded(c.y1)) return false;
            if (c.x1 <= c.x0 or c.y1 <= c.y0) return false;
        }
    }
    if (payload.silk) |art| if (!validateArtwork(art)) return false;
    if (payload.fab) |art| if (!validateArtwork(art)) return false;
    return true;
}

/// Scans `src`'s top-level forms. The returned `Scan.forms` is OWNED by the
/// caller and must be freed with `allocator`.
fn scanTopForms(allocator: std.mem.Allocator, src: []const u8) !Scan {
    var forms: std.ArrayList(FormSpan) = .empty;
    errdefer forms.deinit(allocator);
    var depth: usize = 0;
    var child_start: ?usize = null;
    var in_string = false;
    var escaped = false;
    var comment = false;
    var pad_index: usize = 0;
    var root_close: ?usize = null;
    for (src, 0..) |c, i| {
        if (comment) {
            if (c == '\n') comment = false;
            continue;
        }
        if (in_string) {
            if (escaped) escaped = false else if (c == '\\') escaped = true else if (c == '"') in_string = false;
            continue;
        }
        if (c == ';') {
            comment = true;
        } else if (c == '"') {
            in_string = true;
        } else if (c == '(') {
            if (depth == 1) child_start = i;
            depth += 1;
        } else if (c == ')') {
            if (depth == 0) return error.InvalidFootprint;
            if (depth == 1) {
                root_close = i;
                depth = 0;
                break;
            }
            depth -= 1;
            if (depth == 1) {
                const start = child_start orelse return error.InvalidFootprint;
                const name = formName(src, start);
                if (std.mem.eql(u8, name, "pad")) {
                    try forms.append(allocator, .{
                        .start = start,
                        .end = i + 1,
                        .kind = .pad,
                        .pad_index = pad_index,
                    });
                    pad_index += 1;
                } else if (std.mem.eql(u8, name, "courtyard")) {
                    try forms.append(allocator, .{ .start = start, .end = i + 1, .kind = .courtyard });
                } else if (std.mem.eql(u8, name, "silkscreen")) {
                    try forms.append(allocator, .{ .start = start, .end = i + 1, .kind = .silk });
                } else if (std.mem.eql(u8, name, "fab")) {
                    try forms.append(allocator, .{ .start = start, .end = i + 1, .kind = .fab });
                }
                child_start = null;
            }
        }
    }
    // `forms.items` would be a slice whose length is the element COUNT while
    // the live allocation is the list's CAPACITY, so freeing it is a size
    // mismatch the debug allocator rejects outright. Shrink to fit and hand
    // over the allocation itself.
    const root = root_close orelse return error.InvalidFootprint;
    return .{
        .forms = try forms.toOwnedSlice(allocator),
        .root_close = root,
        .pad_count = pad_index,
    };
}

fn formName(src: []const u8, start: usize) []const u8 {
    var i = start + 1;
    while (i < src.len and std.ascii.isWhitespace(src[i])) : (i += 1) {}
    const begin = i;
    while (i < src.len and isFormNameChar(src[i])) : (i += 1) {}
    return src[begin..i];
}

fn isFormNameChar(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\r', '\n', '(', ')' => false,
        else => true,
    };
}

fn findChange(changes: []const PadChange, index: usize) ?PadChange {
    for (changes) |change| if (change.index == index) return change;
    return null;
}

/// Rewrites `src` with `payload` applied. The result is OWNED by the caller
/// and must be freed with `allocator`.
fn rewrite(allocator: std.mem.Allocator, src: []const u8, scan: Scan, payload: SaveRequest) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    var cursor: usize = 0;
    var courtyard_written = false;
    var silk_written = false;
    var fab_written = false;
    for (scan.forms) |span| {
        try w.writeAll(src[cursor..span.start]);
        switch (span.kind) {
            .pad => if (findChange(payload.changes, span.pad_index)) |change| {
                if (!change.remove) try writePad(w, change.pad.?);
            } else try w.writeAll(src[span.start..span.end]),
            .courtyard => if (payload.courtyard) |court| {
                if (!courtyard_written) {
                    try writeCourtyard(w, court);
                    courtyard_written = true;
                }
            } else try w.writeAll(src[span.start..span.end]),
            .silk => if (payload.silk) |art| {
                try writeArtwork(w, "silkscreen", art);
                silk_written = true;
            } else try w.writeAll(src[span.start..span.end]),
            .fab => if (payload.fab) |art| {
                try writeArtwork(w, "fab", art);
                fab_written = true;
            } else try w.writeAll(src[span.start..span.end]),
        }
        cursor = span.end;
    }
    try w.writeAll(src[cursor..scan.root_close]);
    for (payload.additions) |pad| {
        try w.writeAll("\n  ");
        try writePad(w, pad);
    }
    if (payload.courtyard != null and !courtyard_written) {
        try w.writeAll("\n  ");
        try writeCourtyard(w, payload.courtyard.?);
    }
    if (payload.silk) |art| if (!silk_written) {
        try w.writeAll("\n  ");
        try writeArtwork(w, "silkscreen", art);
    };
    if (payload.fab) |art| if (!fab_written) {
        try w.writeAll("\n  ");
        try writeArtwork(w, "fab", art);
    };
    try w.writeAll(src[scan.root_close..]);
    // `written()` borrows the writer's buffer: its length is the byte COUNT
    // while the live allocation is the buffer's CAPACITY, so the caller could
    // neither free it nor outlive `out`. Shrink to fit and transfer ownership.
    return out.toOwnedSlice();
}

fn writePad(w: *std.Io.Writer, pad: PadEdit) !void {
    try w.writeAll("(pad ");
    try writeAtomOrString(w, pad.id);
    try w.print(
        " {s} {s} (pos {d:.4} {d:.4}) (size {d:.4} {d:.4})",
        .{ pad.type, pad.shape, pad.x, pad.y, pad.w, pad.h },
    );
    if (pad.drill_x > 0 or pad.drill_y > 0) {
        if (@abs(pad.drill_x - pad.drill_y) < 0.00001) {
            try w.print(" (drill {d:.4})", .{pad.drill_x});
        } else {
            try w.print(" (drill oval {d:.4} {d:.4})", .{ pad.drill_x, pad.drill_y });
        }
    }
    if (pad.roundrect_ratio) |ratio| try w.print(" (roundrect_rratio {d:.4})", .{ratio});
    if (pad.mask_margin) |margin| try w.print(" (mask-margin {d:.4})", .{margin});
    if (pad.no_paste) try w.writeAll(" no-paste");
    if (pad.paste) |windows| try @import("../footprint_paste.zig").write(w, windows);
    if (pad.poly) |poly| {
        try w.writeAll(" (poly");
        for (poly) |point| try w.print(" ({d:.4} {d:.4})", .{ point[0], point[1] });
        try w.writeAll(")");
    }
    try w.writeAll(")");
}

fn writeAtomOrString(w: *std.Io.Writer, value: []const u8) !void {
    var atom_ok = value.len > 0;
    for (value) |c| if (!isAtomChar(c)) {
        atom_ok = false;
        break;
    };
    if (atom_ok) return w.writeAll(value);
    try w.writeByte('"');
    for (value) |c| switch (c) {
        '\\', '"' => {
            try w.writeByte('\\');
            try w.writeByte(c);
        },
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

fn isAtomChar(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\r', '\n', '(', ')', '"', ';' => false,
        else => true,
    };
}

fn writeCourtyard(w: *std.Io.Writer, court: CourtyardEdit) !void {
    if (court.poly) |poly| {
        try w.writeAll("(courtyard (poly");
        for (poly) |point| try w.print(" ({d:.4} {d:.4})", .{ point[0], point[1] });
        return w.writeAll("))");
    }
    try w.print("(courtyard (rect {d:.4} {d:.4} {d:.4} {d:.4}))", .{ court.x0, court.y0, court.x1, court.y1 });
}

fn writeArtwork(w: *std.Io.Writer, name: []const u8, art: ArtworkEdit) !void {
    try w.print("({s}", .{name});
    for (art.lines) |line| try w.print(" (line ({d:.4} {d:.4}) ({d:.4} {d:.4}))", .{ line[0], line[1], line[2], line[3] });
    for (art.circles) |circle| try w.print(" (circle ({d:.4} {d:.4}) {d:.4})", .{ circle[0], circle[1], circle[2] });
    for (art.rects) |rect| try w.print(" (rect {d:.4} {d:.4} {d:.4} {d:.4})", .{ rect[0], rect[1], rect[2], rect[3] });
    for (art.polys) |poly| {
        try w.writeAll(" (poly");
        for (poly.poly) |point| try w.print(" ({d:.4} {d:.4})", .{ point[0], point[1] });
        try w.writeByte(')');
    }
    try w.writeByte(')');
}

fn atomicWrite(path: []const u8, data: []const u8) !void {
    var write_buf: [4096]u8 = undefined;
    var atomic = try infra_fs.cwd().atomicFile(path, .{ .write_buffer = &write_buf });
    defer atomic.deinit();
    try atomic.file_writer.interface.writeAll(data);
    try atomic.finish();
}

test "footprint editor rewrite preserves unrelated source and untouched pads" {
    const src =
        \\; handmade
        \\(footprint demo
        \\  (description "keep (this)")
        \\  (pad 1 smd rect (pos 0 0) (size 1 2) (mask-margin 0.1))
        \\  (pad 2 smd circle (pos 2 0) (size 1 1))
        \\  (silkscreen (line (-1 -1) (1 -1)))
        \\  (courtyard (rect -2 -2 3 2)))
    ;
    const scan = try scanTopForms(std.testing.allocator, src);
    defer std.testing.allocator.free(scan.forms);
    const changed = PadEdit{
        .id = "1",
        .type = "smd",
        .shape = "rect",
        .x = 0.5,
        .y = 0,
        .w = 1,
        .h = 2,
        .mask_margin = 0.1,
    };
    const payload = SaveRequest{ .revision = "x", .changes = &.{.{ .index = 0, .pad = changed }} };
    const out = try rewrite(std.testing.allocator, src, scan, payload);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "(description \"keep (this)\")") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(pad 2 smd circle (pos 2 0) (size 1 1))") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(pos 0.5000 0.0000)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(silkscreen (line (-1 -1) (1 -1)))") != null);
}

test "footprint editor scanner ignores parentheses in strings and comments" {
    const src = "(footprint x ; ) fake\n (description \"(not a form)\") (pad 1 smd rect (pos 0 0) (size 1 1)))";
    const scan = try scanTopForms(std.testing.allocator, src);
    defer std.testing.allocator.free(scan.forms);
    try std.testing.expectEqual(@as(usize, 1), scan.pad_count);
    try std.testing.expect(scan.root_close == src.len - 1);
}

// spec: Web Server - The footprint editor uses the shared shape-sketch tools for custom pad polygons, polygon courtyards, and closed silkscreen/fabrication artwork, while retaining conventional physical footprint forms for export and placement
test "footprint editor assets expose precise dimension and pad controls" {
    const js = @embedFile("assets/footprint_editor.js");
    const css = @embedFile("assets/footprint_editor.css");
    try std.testing.expect(std.mem.indexOf(u8, js, "dim-horizontal") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "dim-vertical") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "snapPoint") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "serializePad") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "selectedPads") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "finishMarquee") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "evaluateExpression") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "driveConstruction") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "window.PCBShapeSketch") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "function shapeAction(action)") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".dim-text") != null);
    try std.testing.expect(std.mem.indexOf(u8, css, ".construction-line") != null);
}

test "footprint editor rewrites polygon courtyard and editable artwork" {
    const src = "(footprint x (pad 1 smd rect (pos 0 0) (size 1 1)) (silkscreen (line (0 0) (1 1))) (fab (rect -1 -1 1 1)) (courtyard (rect -2 -2 2 2)))";
    const scan = try scanTopForms(std.testing.allocator, src);
    defer std.testing.allocator.free(scan.forms);
    var court = [_][]f64{ @constCast(&[_]f64{ -2, -1 }), @constCast(&[_]f64{ 2, -1 }), @constCast(&[_]f64{ 1, 2 }) };
    var silk_poly = [_][]f64{ @constCast(&[_]f64{ 0, 0 }), @constCast(&[_]f64{ 1, 0 }), @constCast(&[_]f64{ 0, 1 }) };
    const payload: SaveRequest = .{
        .revision = "x",
        .courtyard = .{ .poly = &court },
        .silk = .{ .polys = &.{.{ .poly = &silk_poly }} },
    };
    try std.testing.expect(validateRequest(std.testing.allocator, payload, 1));
    const out = try rewrite(std.testing.allocator, src, scan, payload);
    defer std.testing.allocator.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "(courtyard (poly") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(silkscreen (poly") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(fab (rect -1 -1 1 1))") != null);
}

test "footprint editor rejects duplicate or out-of-range source pad changes" {
    const pad = PadEdit{ .id = "1", .type = "smd", .shape = "rect", .x = 0, .y = 0, .w = 1, .h = 1 };
    const duplicate = SaveRequest{
        .revision = "x",
        .changes = &.{ .{ .index = 0, .pad = pad }, .{ .index = 0, .remove = true } },
    };
    try std.testing.expect(!validateRequest(std.testing.allocator, duplicate, 1));
    const out_of_range = SaveRequest{ .revision = "x", .changes = &.{.{ .index = 1, .pad = pad }} };
    try std.testing.expect(!validateRequest(std.testing.allocator, out_of_range, 1));
}

fn packagePad(a: std.mem.Allocator, key: []const u8, p: PadEdit) !@import("package_generator.zig").Pad {
    var value = try std.json.parseFromSliceLeaky(std.json.Value, a, try std.json.Stringify.valueAlloc(a, p, .{}), .{});
    try value.object.put(a, "key", .{ .string = key });
    return std.json.parseFromSliceLeaky(@import("package_generator.zig").Pad, a, try std.json.Stringify.valueAlloc(a, value, .{}), .{});
}
fn packageDiff(a: std.mem.Allocator, base: @import("package_generator.zig").Pad, pad: @import("package_generator.zig").Pad) !@import("package_generator.zig").Override {
    var patch_value: @import("package_generator.zig").Override = .{ .key = base.key };
    var clear: std.ArrayList([]const u8) = .empty;
    inline for (.{ "id", "x", "y", "w", "h", "type", "shape", "drill_x", "drill_y", "roundrect_ratio", "mask_margin", "no_paste", "poly", "paste" }) |field| {
        const original = @field(base, field);
        const edited = @field(pad, field);
        const old_json = try std.json.Stringify.valueAlloc(a, original, .{});
        const new_json = try std.json.Stringify.valueAlloc(a, edited, .{});
        if (!std.mem.eql(u8, old_json, new_json)) {
            @field(patch_value, field) = edited;
            if (@typeInfo(@TypeOf(edited)) == .optional) {
                if (edited == null) try clear.append(a, field);
            }
        }
    }
    patch_value.clear_fields = try clear.toOwnedSlice(a);
    return patch_value;
}
fn saveGenerated(ctx: *Server, req: *httpz.Request, res: *httpz.Response, name: []const u8, payload: SaveRequest) HandlerError!bool {
    const store = @import("package_store.zig");
    const recipe = store.load(req.arena, ctx.project_dir, name) catch |err| {
        if (err == error.FileNotFound) return false;
        sendError(res, 409, @import("package_tools.zig").message(err));
        return true;
    };
    const saved = saveGeneratedCore(req.arena, ctx.project_dir, recipe, payload) catch |err| {
        sendError(res, 409, @import("package_tools.zig").message(err));
        return true;
    };
    res.content_type = .JSON;
    res.body = try std.fmt.allocPrint(req.arena, "{{\"ok\":true,\"revision\":\"{x}\"}}", .{std.hash.Wyhash.hash(0, saved)});
    return true;
}
fn saveGeneratedCore(a: std.mem.Allocator, project: []const u8, input: @import("package_generator.zig").Recipe, payload: SaveRequest) ![]const u8 {
    const gen = @import("package_generator.zig");
    const store = @import("package_store.zig");
    var recipe = input;
    const current = try gen.generate(a, recipe);
    if (gen.hasErrors(current.diagnostics)) return error.InvalidPackage;
    var pads: std.ArrayList(gen.Pad) = .empty;
    for (current.pads, 0..) |pad, i| {
        var edited = pad;
        var removed = false;
        for (payload.changes) |change| if (change.index == i) {
            removed = change.remove;
            if (change.pad) |p| edited = try packagePad(a, pad.key, p);
        };
        if (!removed) try pads.append(a, edited);
    }
    for (payload.additions, 0..) |pad, i| try pads.append(a, try packagePad(a, try std.fmt.allocPrint(a, "manual-{x}-{d}", .{ std.hash.Wyhash.hash(0, current.footprint), i }), pad));
    const base = try gen.basePads(a, recipe);
    var overrides: std.ArrayList(gen.Override) = .empty;
    var additions: std.ArrayList(gen.Pad) = .empty;
    for (base) |p| {
        var found = false;
        for (pads.items) |edited| if (std.mem.eql(u8, p.key, edited.key)) {
            try overrides.append(a, try packageDiff(a, p, edited));
            found = true;
            break;
        };
        if (!found) try overrides.append(a, .{ .key = p.key, .remove = true });
    }
    for (pads.items) |p| {
        var found = false;
        for (base) |original| if (std.mem.eql(u8, p.key, original.key)) {
            found = true;
            break;
        };
        if (!found) try additions.append(a, p);
    }
    recipe.overrides = try overrides.toOwnedSlice(a);
    recipe.additions = try additions.toOwnedSlice(a);
    if (payload.courtyard) |court| {
        var w: std.Io.Writer.Allocating = .init(a);
        try writeCourtyard(&w.writer, court);
        recipe.artwork.courtyard = try w.toOwnedSlice();
    }
    if (payload.silk) |art| {
        var w: std.Io.Writer.Allocating = .init(a);
        try writeArtwork(&w.writer, "silkscreen", art);
        recipe.artwork.silk = try w.toOwnedSlice();
    }
    if (payload.fab) |art| {
        var w: std.Io.Writer.Allocating = .init(a);
        try writeArtwork(&w.writer, "fab", art);
        recipe.artwork.fab = try w.toOwnedSlice();
    }
    var session = @import("autocommit.zig").begin(a, project);
    defer if (session) |*s| s.deinit();
    const saved = try store.save(a, project, recipe);
    @import("autocommit.zig").commit(session, null, "package_footprint_edit");
    return (try gen.generate(a, saved)).footprint;
}

// spec: IC package builder - Precise-editor save retains changed fields and catches invalid recipes
test "IC package saveGenerated retains changed fields and catches invalid recipes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const gen = @import("package_generator.zig");
    const store = @import("package_store.zig");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    var recipe = gen.template(.dfn);
    recipe.dimensions_verified = true;
    recipe = try store.save(a, root, recipe);
    const payload = SaveRequest{ .revision = "unused", .changes = &.{.{ .index = 0, .pad = .{ .id = "1", .type = "smd", .shape = "rect", .x = -1.95, .y = -0.5, .w = 0.8, .h = 0.3 } }} };
    _ = try saveGeneratedCore(a, root, recipe, payload);
    const edited = try store.load(a, root, recipe.name);
    try std.testing.expectEqual(@as(?f64, 0.8), edited.overrides[0].w);
    try std.testing.expectEqual(@as(?f64, null), edited.overrides[0].x);
    recipe.body.width = -1;
    try std.testing.expectError(error.InvalidPackage, saveGeneratedCore(a, root, recipe, payload));
}
