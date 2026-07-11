//! Footprint-preview HTTP handlers: rasterizes a library footprint (pads,
//! courtyard, silkscreen) to an SVG the library/preview UI embeds, plus the
//! whole-board footprint view. Read-only; renders onto the request arena.

const std = @import("std");
const httpz = @import("httpz");
const infra_fs = @import("../infra/fs.zig");
const parser_mod = @import("../sexpr/parser.zig");
const ast = @import("../sexpr/ast.zig");
const Node = ast.Node;
const export_kicad = @import("../export_kicad.zig");
const footprint_mod = @import("../export_kicad_footprint.zig");
const serve_root = @import("../serve.zig");
const Handler = serve_root.Handler;
const numeric = @import("../numeric.zig");
// ── Constants ─────────────────────────────────────────────────────
const http_not_found: u16 = 404;
const http_internal_error: u16 = 500;
const max_footprint_bytes: usize = 256 * 1024;
const sexp_ext_len: usize = ".sexp".len;
const far_away: f64 = 999;
const svg_bbox_pad: f64 = 0.5;
// A `(rect x0 y0 x1 y1)` form is the head atom plus four coordinates.
const rect_form_items: usize = 5;
// JSON `[a,b,c,d]` of four 3-decimal coords — rects + line segments.
const json_f4 = "[{d:.3},{d:.3},{d:.3},{d:.3}]";

// The layer palette + pad-label sizing now live in the shared client renderer
// (`assets/footprint_svg.js`); this module only describes the geometry as JSON.

/// Error set for HTTP handlers in this module.
pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error;

const Layer = enum { silk, fab };

// `pts` carries a custom pad's real copper outline (footprint coords); when
// present it's drawn as a filled polygon instead of the pos/size rectangle.
const Pad = struct { id: []const u8, x: f64, y: f64, w: f64, h: f64, shape: []const u8, pts: ?[]const Point = null, drill: f64 = 0, npth: bool = false };
const Point = struct { x: f64, y: f64 };
const Seg = struct { x1: f64, y1: f64, x2: f64, y2: f64, layer: Layer };
const Circ = struct { cx: f64, cy: f64, r: f64, layer: Layer };
const RectS = struct { x0: f64, y0: f64, x1: f64, y1: f64, layer: Layer };
const Poly = struct { pts: []const Point, layer: Layer };
const CourtRect = struct { x0: f64, y0: f64, x1: f64, y1: f64 };
const CourtCirc = struct { cx: f64, cy: f64, r: f64 };

/// Every drawable extracted from a footprint, grouped by primitive. Pads draw
/// on top; courtyard sits behind everything as a boundary.
const Shapes = struct {
    pads: std.ArrayList(Pad) = .empty,
    segs: std.ArrayList(Seg) = .empty,
    circs: std.ArrayList(Circ) = .empty,
    rects: std.ArrayList(RectS) = .empty,
    polys: std.ArrayList(Poly) = .empty,
    court_rects: std.ArrayList(CourtRect) = .empty,
    court_circs: std.ArrayList(CourtCirc) = .empty,

    fn isEmpty(self: Shapes) bool {
        return self.pads.items.len == 0 and self.segs.items.len == 0 and
            self.rects.items.len == 0 and self.polys.items.len == 0 and
            self.court_rects.items.len == 0 and self.court_circs.items.len == 0;
    }
};

/// GET /api/footprint/:name — return a `lib/footprints/<name>.sexp` as a JSON
/// footprint description (pads incl. custom polygons, courtyard, silkscreen +
/// fabrication geometry). The shared client renderer `/static/footprint_svg.js`
/// draws it — one engine for the library preview, the schematic sidebar, and
/// the PCB-layout page — so a pad-shape change lands in exactly one place.
pub fn footprintApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = http_not_found;
        return;
    };

    const fp_path = std.fmt.allocPrint(ctx.allocator, "{s}/lib/footprints/{s}.sexp", .{ ctx.project_dir, name }) catch {
        res.status = http_internal_error;
        return;
    };
    defer ctx.allocator.free(fp_path);
    const content = infra_fs.cwd().readFileAlloc(ctx.allocator, fp_path, max_footprint_bytes) catch {
        res.status = http_not_found;
        res.body = "Footprint not found";
        return;
    };

    const nodes = parser_mod.parse(ctx.allocator, content) catch {
        res.status = http_internal_error;
        res.body = "Parse error";
        return;
    };
    if (nodes.len == 0) {
        res.status = http_internal_error;
        return;
    }
    const top = nodes[0].asList() orelse {
        res.status = http_internal_error;
        return;
    };

    var shapes: Shapes = .{};
    try collectShapes(ctx.allocator, top[1..], &shapes);

    if (shapes.isEmpty()) {
        res.status = http_not_found;
        res.body = "Empty footprint";
        return;
    }

    var buf: std.ArrayList(u8) = .empty;
    try emitFootprintJson(buf.writer(ctx.allocator), shapes);

    res.body = buf.toOwnedSlice(ctx.allocator) catch "";
    res.content_type = .JSON;
}

/// Walk the footprint's top-level forms into `shapes`: pads, `(courtyard …)`,
/// and the `(silkscreen …)` / `(fab …)` geometry blocks.
fn collectShapes(allocator: std.mem.Allocator, children: []const Node, shapes: *Shapes) HandlerError!void {
    for (children) |child| {
        if (child.isForm("pad")) {
            if (parsePad(allocator, child)) |p| try shapes.pads.append(allocator, p);
        } else if (child.isForm("courtyard")) {
            const cl = child.asList() orelse continue;
            try parseCourtyard(allocator, cl[1..], shapes);
        } else if (child.isForm("silkscreen")) {
            const cl = child.asList() orelse continue;
            try parseGeomBlock(allocator, cl[1..], .silk, shapes);
        } else if (child.isForm("fab")) {
            const cl = child.asList() orelse continue;
            try parseGeomBlock(allocator, cl[1..], .fab, shapes);
        }
    }
}

fn parsePad(allocator: std.mem.Allocator, child: Node) ?Pad {
    const cl = child.asList() orelse return null;
    if (cl.len < 4) return null;
    const id: []const u8 = cl[1].asAtom() orelse cl[1].asString() orelse blk: {
        const n = cl[1].asNumber() orelse break :blk "";
        break :blk std.fmt.allocPrint(allocator, "{d}", .{numeric.checkedInt(i64, n) orelse 0}) catch "";
    };
    // Pad type keyword (cl[2]): "smd" (default), "thru", or "npth" (non-plated).
    const ptype: []const u8 = cl[2].asAtom() orelse "smd";
    const npth = std.mem.eql(u8, ptype, "npth");
    const shape: []const u8 = cl[3].asAtom() orelse "rect";
    var px: f64 = 0;
    var py: f64 = 0;
    var pw: f64 = 0;
    var ph: f64 = 0;
    var drill: f64 = 0;
    var pts: ?[]const Point = null;
    for (cl[4..]) |sub| {
        if (sub.isForm("pos")) {
            const sl = sub.asList().?;
            if (sl.len >= 3) {
                px = sl[1].asNumber() orelse 0;
                py = sl[2].asNumber() orelse 0;
            }
        }
        if (sub.isForm("size")) {
            const sl = sub.asList().?;
            if (sl.len >= 3) {
                pw = sl[1].asNumber() orelse 0;
                ph = sl[2].asNumber() orelse 0;
            }
        }
        if (sub.isForm("drill")) {
            // `(drill D)` scalar or `(drill oval X Y)` — take the largest axis.
            const dl = sub.asList().?;
            for (dl[1..]) |dn| {
                if (dn.asNumber()) |d| drill = @max(drill, d);
            }
        }
        if (sub.isForm("poly")) pts = readPolyPts(allocator, sub) catch null;
    }
    return .{ .id = id, .x = px, .y = py, .w = pw, .h = ph, .shape = shape, .pts = pts, .drill = drill, .npth = npth };
}

/// Parse the children of a `(silkscreen …)` or `(fab …)` block: `(line …)`,
/// `(circle …)`, `(rect …)`, `(poly …)`. Unknown forms are skipped.
fn parseGeomBlock(allocator: std.mem.Allocator, items: []const Node, layer: Layer, shapes: *Shapes) HandlerError!void {
    for (items) |sub| {
        if (sub.isForm("line")) {
            if (readSeg(sub, layer)) |s| try shapes.segs.append(allocator, s);
        } else if (sub.isForm("circle")) {
            if (readCircle(sub, layer)) |c| try shapes.circs.append(allocator, c);
        } else if (sub.isForm("rect")) {
            if (readRect(sub, layer)) |r| try shapes.rects.append(allocator, r);
        } else if (sub.isForm("poly")) {
            if (try readPoly(allocator, sub, layer)) |p| try shapes.polys.append(allocator, p);
        }
    }
}

/// Parse the children of a `(courtyard …)` form: a single `(rect …)` or
/// `(circle …)` boundary.
fn parseCourtyard(allocator: std.mem.Allocator, items: []const Node, shapes: *Shapes) HandlerError!void {
    for (items) |sub| {
        if (sub.isForm("rect")) {
            if (readRect(sub, .fab)) |r| try shapes.court_rects.append(allocator, .{ .x0 = r.x0, .y0 = r.y0, .x1 = r.x1, .y1 = r.y1 });
        } else if (sub.isForm("circle")) {
            if (readCircle(sub, .fab)) |c| try shapes.court_circs.append(allocator, .{ .cx = c.cx, .cy = c.cy, .r = c.r });
        }
    }
}

fn readSeg(node: Node, layer: Layer) ?Seg {
    const sl = node.asList() orelse return null;
    if (sl.len < 3) return null;
    const p1 = sl[1].asList() orelse return null;
    const p2 = sl[2].asList() orelse return null;
    if (p1.len < 2 or p2.len < 2) return null;
    return .{
        .x1 = p1[0].asNumber() orelse 0,
        .y1 = p1[1].asNumber() orelse 0,
        .x2 = p2[0].asNumber() orelse 0,
        .y2 = p2[1].asNumber() orelse 0,
        .layer = layer,
    };
}

fn readCircle(node: Node, layer: Layer) ?Circ {
    const sl = node.asList() orelse return null;
    if (sl.len < 3) return null;
    const center = sl[1].asList() orelse return null;
    if (center.len < 2) return null;
    return .{
        .cx = center[0].asNumber() orelse 0,
        .cy = center[1].asNumber() orelse 0,
        .r = sl[2].asNumber() orelse 0,
        .layer = layer,
    };
}

fn readRect(node: Node, layer: Layer) ?RectS {
    const sl = node.asList() orelse return null;
    if (sl.len < rect_form_items) return null;
    return .{
        .x0 = sl[1].asNumber() orelse 0,
        .y0 = sl[2].asNumber() orelse 0,
        .x1 = sl[3].asNumber() orelse 0,
        .y1 = sl[4].asNumber() orelse 0,
        .layer = layer,
    };
}

/// Parse a `(poly (x y) (x y) …)` form into its point slice (≥3 points), or
/// null. Shared by silk/fab polygons and custom-pad copper outlines.
fn readPolyPts(allocator: std.mem.Allocator, node: Node) HandlerError!?[]const Point {
    const sl = node.asList() orelse return null;
    if (sl.len < 4) return null; // need ≥3 points to be a polygon
    var pts: std.ArrayList(Point) = .empty;
    for (sl[1..]) |pn| {
        const pl = pn.asList() orelse continue;
        if (pl.len < 2) continue;
        try pts.append(allocator, .{ .x = pl[0].asNumber() orelse 0, .y = pl[1].asNumber() orelse 0 });
    }
    if (pts.items.len < 3) return null;
    return try pts.toOwnedSlice(allocator);
}

fn readPoly(allocator: std.mem.Allocator, node: Node, layer: Layer) HandlerError!?Poly {
    const pts = try readPolyPts(allocator, node) orelse return null;
    return .{ .pts = pts, .layer = layer };
}

const BBox = struct { min_x: f64, min_y: f64, max_x: f64, max_y: f64 };

fn computeBBox(shapes: Shapes) BBox {
    var b: BBox = .{ .min_x = far_away, .min_y = far_away, .max_x = -far_away, .max_y = -far_away };
    for (shapes.pads.items) |p| {
        grow(&b, p.x - p.w / 2, p.y - p.h / 2);
        grow(&b, p.x + p.w / 2, p.y + p.h / 2);
    }
    for (shapes.segs.items) |s| {
        grow(&b, s.x1, s.y1);
        grow(&b, s.x2, s.y2);
    }
    for (shapes.circs.items) |c| {
        grow(&b, c.cx - c.r, c.cy - c.r);
        grow(&b, c.cx + c.r, c.cy + c.r);
    }
    for (shapes.rects.items) |r| {
        grow(&b, r.x0, r.y0);
        grow(&b, r.x1, r.y1);
    }
    for (shapes.polys.items) |poly| for (poly.pts) |pt| grow(&b, pt.x, pt.y);
    for (shapes.court_rects.items) |r| {
        grow(&b, r.x0, r.y0);
        grow(&b, r.x1, r.y1);
    }
    for (shapes.court_circs.items) |c| {
        grow(&b, c.cx - c.r, c.cy - c.r);
        grow(&b, c.cx + c.r, c.cy + c.r);
    }
    return b;
}

fn grow(b: *BBox, x: f64, y: f64) void {
    if (x < b.min_x) b.min_x = x;
    if (y < b.min_y) b.min_y = y;
    if (x > b.max_x) b.max_x = x;
    if (y > b.max_y) b.max_y = y;
}

/// Emit the footprint as a JSON description for the shared client renderer:
/// `{bbox, pads, silk, fab, courtyard}`. The renderer draws courtyard (dashed)
/// behind fab + silkscreen, with pads (polygon/circle/oval/rect + id label) on
/// top — see `/static/footprint_svg.js`.
fn emitFootprintJson(w: anytype, shapes: Shapes) HandlerError!void {
    var b = computeBBox(shapes);
    b.min_x -= svg_bbox_pad;
    b.min_y -= svg_bbox_pad;
    b.max_x += svg_bbox_pad;
    b.max_y += svg_bbox_pad;

    try w.print("{{\"bbox\":{{\"x\":{d:.3},\"y\":{d:.3},\"w\":{d:.3},\"h\":{d:.3}}}", .{
        b.min_x, b.min_y, b.max_x - b.min_x, b.max_y - b.min_y,
    });

    try w.writeAll(",\"pads\":[");
    for (shapes.pads.items, 0..) |p, i| {
        if (i != 0) try w.writeAll(",");
        try w.writeAll("{\"id\":");
        try writeJsonStr(w, p.id);
        try w.print(",\"x\":{d:.3},\"y\":{d:.3},\"w\":{d:.3},\"h\":{d:.3},\"shape\":", .{ p.x, p.y, p.w, p.h });
        try writeJsonStr(w, p.shape);
        if (p.pts) |pts| {
            try w.writeAll(",\"poly\":");
            try writePtsJson(w, pts);
        }
        if (p.drill > 0) {
            try w.print(",\"drill\":{d:.3}", .{p.drill});
            if (p.npth) try w.writeAll(",\"npth\":true");
        }
        try w.writeAll("}");
    }
    try w.writeAll("]");

    try w.writeAll(",\"silk\":");
    try emitLayerJson(w, shapes, .silk);
    try w.writeAll(",\"fab\":");
    try emitLayerJson(w, shapes, .fab);

    try w.writeAll(",\"courtyard\":{\"rects\":[");
    for (shapes.court_rects.items, 0..) |r, i| {
        if (i != 0) try w.writeAll(",");
        try w.print(json_f4, .{ r.x0, r.y0, r.x1, r.y1 });
    }
    try w.writeAll("],\"circles\":[");
    for (shapes.court_circs.items, 0..) |c, i| {
        if (i != 0) try w.writeAll(",");
        try w.print("[{d:.3},{d:.3},{d:.3}]", .{ c.cx, c.cy, c.r });
    }
    try w.writeAll("]}}");
}

/// Emit one layer's geometry as `{lines:[[x1,y1,x2,y2]…], circles:[[cx,cy,r]…],
/// rects:[[x0,y0,x1,y1]…], polys:[[[x,y]…]…]}`.
fn emitLayerJson(w: anytype, shapes: Shapes, layer: Layer) HandlerError!void {
    try w.writeAll("{\"lines\":[");
    var first = true;
    for (shapes.segs.items) |s| {
        if (s.layer != layer) continue;
        if (!first) try w.writeAll(",");
        first = false;
        try w.print(json_f4, .{ s.x1, s.y1, s.x2, s.y2 });
    }
    try w.writeAll("],\"circles\":[");
    first = true;
    for (shapes.circs.items) |c| {
        if (c.layer != layer) continue;
        if (!first) try w.writeAll(",");
        first = false;
        try w.print("[{d:.3},{d:.3},{d:.3}]", .{ c.cx, c.cy, c.r });
    }
    try w.writeAll("],\"rects\":[");
    first = true;
    for (shapes.rects.items) |r| {
        if (r.layer != layer) continue;
        if (!first) try w.writeAll(",");
        first = false;
        try w.print(json_f4, .{ r.x0, r.y0, r.x1, r.y1 });
    }
    try w.writeAll("],\"polys\":[");
    first = true;
    for (shapes.polys.items) |poly| {
        if (poly.layer != layer) continue;
        if (!first) try w.writeAll(",");
        first = false;
        try writePtsJson(w, poly.pts);
    }
    try w.writeAll("]}");
}

/// Emit a point slice as `[[x,y],[x,y],…]`.
fn writePtsJson(w: anytype, pts: []const Point) HandlerError!void {
    try w.writeAll("[");
    for (pts, 0..) |pt, i| {
        if (i != 0) try w.writeAll(",");
        try w.print("[{d:.3},{d:.3}]", .{ pt.x, pt.y });
    }
    try w.writeAll("]");
}

/// Write `s` as a minimally-escaped JSON string (quotes + backslashes).
fn writeJsonStr(w: anytype, s: []const u8) HandlerError!void {
    try w.writeByte('"');
    for (s) |c| switch (c) {
        '"' => try w.writeAll("\\\""),
        '\\' => try w.writeAll("\\\\"),
        else => try w.writeByte(c),
    };
    try w.writeByte('"');
}

// ── Board-side footprint extraction (old-vs-new compare) ────────────────
// The sync preview's swap rows offer an "old vs new" comparison: the NEW
// side is the library footprint (`/api/footprint/:name` above); the OLD
// side is the footprint as it currently exists on the design's
// `(kicad-pcb "<path>")` board file, served here in the SAME JSON shape so
// the shared client renderer draws both. Coordinates are footprint-local
// exactly as stored, so the two sides compare directly regardless of where
// (or on which side) the part is placed. Courtyard drawn as fp_line on the
// board is skipped — pads, silk, and fab are what the comparison is for.

const eval_mod = @import("../eval/evaluator.zig");
const paths = @import("../paths.zig");

const http_bad_request: u16 = 400;
const max_pcb_bytes: usize = 64 * 1024 * 1024;

/// GET /api/board-footprint/:name?uuid=<kicad-uuid> — one footprint from the
/// design's declared `.kicad_pcb`, as preview JSON ({bbox, pads, silk, fab,
/// courtyard}). 404 when the design has no board file or the uuid isn't on it.
pub fn boardFootprintApi(ctx: *Handler, req: *httpz.Request, res: *httpz.Response) HandlerError!void {
    const name = req.param("name") orelse {
        res.status = http_not_found;
        return;
    };
    const q = req.query() catch {
        res.status = http_bad_request;
        return;
    };
    const want_uuid = q.get("uuid") orelse {
        res.status = http_bad_request;
        res.body = "missing ?uuid=";
        return;
    };

    const design_path = paths.designSourcePath(req.arena, ctx.project_dir, name) catch {
        res.status = http_internal_error;
        return;
    };
    var eval = eval_mod.Evaluator.init(ctx.allocator, ctx.project_dir);
    defer eval.deinit();
    const result = eval.evalFile(design_path) catch {
        res.status = http_internal_error;
        res.body = "Build error";
        return;
    };
    const block = switch (result) {
        .design_block => |b| b,
        else => {
            res.status = http_not_found;
            return;
        },
    };
    const pcb_path = block.kicad_pcb_path orelse {
        res.status = http_not_found;
        res.body = "design has no (kicad-pcb …) form";
        return;
    };
    const src = infra_fs.cwd().readFileAlloc(req.arena, pcb_path, max_pcb_bytes) catch {
        res.status = http_not_found;
        res.body = "board file unreadable";
        return;
    };
    const nodes = parser_mod.parse(req.arena, src) catch {
        res.status = http_internal_error;
        return;
    };
    const found = findBoardFootprint(nodes, want_uuid) orelse {
        res.status = http_not_found;
        res.body = "footprint not on board";
        return;
    };

    var shapes: Shapes = .{};
    try collectShapesFromBoardFp(req.arena, found.children, &shapes);
    if (shapes.isEmpty()) {
        res.status = http_not_found;
        res.body = "Empty footprint";
        return;
    }
    // KiCad stores back-side footprints with local Y negated (mirrored across
    // the part's X axis). Normalise to front view so the comparison against
    // the front-authored library reads 1:1 — without this every Y-asymmetric
    // bottom part looks "re-pinned" even when the geometry matches exactly.
    if (found.back) try mirrorShapesY(req.arena, &shapes);
    var buf: std.ArrayList(u8) = .empty;
    try emitFootprintJson(buf.writer(req.arena), shapes);
    res.body = buf.items;
    res.content_type = .JSON;
}

const BoardFpMatch = struct { children: []const Node, back: bool };

/// Locate the board footprint whose `(uuid "…")` equals `want`; returns its
/// child forms (everything after the lib-id string) plus whether the part
/// sits on the back (`(layer "B.Cu")`), or null.
fn findBoardFootprint(nodes: []const Node, want: []const u8) ?BoardFpMatch {
    if (nodes.len == 0) return null;
    const root = nodes[0].asList() orelse return null;
    for (root) |child| {
        if (!child.isForm("footprint")) continue;
        const cl = child.asList() orelse continue;
        if (cl.len < 2) continue;
        var is_match = false;
        var back = false;
        for (cl[2..]) |sub| {
            const sl = sub.asList() orelse continue;
            if (sl.len < 2) continue;
            const head = sl[0].asAtom() orelse continue;
            if (std.mem.eql(u8, head, "uuid")) {
                const u = sl[1].asString() orelse continue;
                if (std.mem.eql(u8, u, want)) is_match = true;
            } else if (std.mem.eql(u8, head, "layer")) {
                const lname = sl[1].asString() orelse (sl[1].asAtom() orelse continue);
                back = std.mem.eql(u8, lname, "B.Cu");
            }
        }
        if (is_match) return .{ .children = cl[2..], .back = back };
    }
    return null;
}

/// Negate every Y in the collected shapes — normalises a back-side board
/// footprint (stored Y-mirrored by KiCad) into the front-view frame the
/// library preview uses. Polygon point slices are reallocated (they alias
/// parsed-source-derived storage).
fn mirrorShapesY(allocator: std.mem.Allocator, shapes: *Shapes) HandlerError!void {
    for (shapes.pads.items) |*p| p.y = -p.y;
    for (shapes.segs.items) |*s| {
        s.y1 = -s.y1;
        s.y2 = -s.y2;
    }
    for (shapes.circs.items) |*c| c.cy = -c.cy;
    for (shapes.rects.items) |*r| {
        r.y0 = -r.y0;
        r.y1 = -r.y1;
    }
    for (shapes.polys.items) |*poly| {
        const flipped = try allocator.alloc(Point, poly.pts.len);
        for (poly.pts, 0..) |pt, i| flipped[i] = .{ .x = pt.x, .y = -pt.y };
        poly.pts = flipped;
    }
    for (shapes.court_rects.items) |*r| {
        r.y0 = -r.y0;
        r.y1 = -r.y1;
    }
    for (shapes.court_circs.items) |*c| c.cy = -c.cy;
}

/// The board layer a KiCad fp graphic targets, looked up from its
/// `(layer "…")` child. Both sides map to the same preview layer so a
/// bottom part's silk compares cleanly against the front-authored library.
fn boardGraphicLayer(sub: Node) ?Layer {
    const sl = sub.asList() orelse return null;
    for (sl[1..]) |c| {
        const cl = c.asList() orelse continue;
        if (cl.len < 2) continue;
        const head = cl[0].asAtom() orelse continue;
        if (!std.mem.eql(u8, head, "layer")) continue;
        const lname = cl[1].asString() orelse (cl[1].asAtom() orelse continue);
        if (std.mem.endsWith(u8, lname, ".SilkS")) return .silk;
        if (std.mem.endsWith(u8, lname, ".Fab")) return .fab;
        return null; // CrtYd / Cu / other — not part of the preview layers
    }
    return null;
}

/// Read a named `(head x y)` 2-vector child of a board graphic form.
fn boardVec2(sub: Node, head_name: []const u8) ?Point {
    const sl = sub.asList() orelse return null;
    for (sl[1..]) |c| {
        const cl = c.asList() orelse continue;
        if (cl.len < 3) continue;
        const head = cl[0].asAtom() orelse continue;
        if (!std.mem.eql(u8, head, head_name)) continue;
        const x = cl[1].asNumber() orelse return null;
        const y = cl[2].asNumber() orelse return null;
        return .{ .x = x, .y = y };
    }
    return null;
}

/// Walk a BOARD-format footprint's children into `shapes`. The `.kicad_pcb`
/// grammar differs from the library `.sexp`: pads carry `(at …)`/`(size …)`,
/// graphics are `fp_line`/`fp_circle`/`fp_rect`/`fp_poly` with a per-form
/// `(layer …)`. Pad-local coordinates are stored library-identical for both
/// board sides (KiCad mirrors at render), so no coordinate mapping is needed.
fn collectShapesFromBoardFp(allocator: std.mem.Allocator, children: []const Node, shapes: *Shapes) HandlerError!void {
    for (children) |child| {
        if (child.isForm("pad")) {
            if (parseBoardPad(allocator, child)) |p| try shapes.pads.append(allocator, p);
        } else if (child.isForm("fp_line")) {
            const layer = boardGraphicLayer(child) orelse continue;
            const s = boardVec2(child, "start") orelse continue;
            const e = boardVec2(child, "end") orelse continue;
            try shapes.segs.append(allocator, .{ .x1 = s.x, .y1 = s.y, .x2 = e.x, .y2 = e.y, .layer = layer });
        } else if (child.isForm("fp_circle")) {
            const layer = boardGraphicLayer(child) orelse continue;
            const c = boardVec2(child, "center") orelse continue;
            const e = boardVec2(child, "end") orelse continue;
            const r = @sqrt((e.x - c.x) * (e.x - c.x) + (e.y - c.y) * (e.y - c.y));
            try shapes.circs.append(allocator, .{ .cx = c.x, .cy = c.y, .r = r, .layer = layer });
        } else if (child.isForm("fp_rect")) {
            const layer = boardGraphicLayer(child) orelse continue;
            const s = boardVec2(child, "start") orelse continue;
            const e = boardVec2(child, "end") orelse continue;
            try shapes.rects.append(allocator, .{ .x0 = s.x, .y0 = s.y, .x1 = e.x, .y1 = e.y, .layer = layer });
        } else if (child.isForm("fp_poly")) {
            const layer = boardGraphicLayer(child) orelse continue;
            if (try readBoardPolyPts(allocator, child)) |pts| {
                try shapes.polys.append(allocator, .{ .pts = pts, .layer = layer });
            }
        }
    }
}

/// Pad in `.kicad_pcb` form: `(pad "N" <type> <shape> (at x y [rot]) (size w h) …)`.
fn parseBoardPad(allocator: std.mem.Allocator, child: Node) ?Pad {
    const cl = child.asList() orelse return null;
    if (cl.len < 4) return null;
    const id: []const u8 = cl[1].asString() orelse cl[1].asAtom() orelse blk: {
        const n = cl[1].asNumber() orelse break :blk "";
        break :blk std.fmt.allocPrint(allocator, "{d}", .{numeric.checkedInt(i64, n) orelse 0}) catch "";
    };
    const shape: []const u8 = cl[3].asAtom() orelse "rect";
    const at = boardVec2(child, "at") orelse Point{ .x = 0, .y = 0 };
    const size = boardVec2(child, "size") orelse Point{ .x = 0, .y = 0 };
    return .{ .id = id, .x = at.x, .y = at.y, .w = size.x, .h = size.y, .shape = shape, .pts = null };
}

/// `(fp_poly (pts (xy x y) (xy x y) …) …)` → point slice, or null when too few.
fn readBoardPolyPts(allocator: std.mem.Allocator, child: Node) HandlerError!?[]const Point {
    const cl = child.asList() orelse return null;
    for (cl[1..]) |sub| {
        if (!sub.isForm("pts")) continue;
        const pl = sub.asList() orelse return null;
        var pts: std.ArrayList(Point) = .empty;
        for (pl[1..]) |xy| {
            const xl = xy.asList() orelse continue;
            if (xl.len < 3) continue;
            const x = xl[1].asNumber() orelse continue;
            const y = xl[2].asNumber() orelse continue;
            try pts.append(allocator, .{ .x = x, .y = y });
        }
        if (pts.items.len < 3) return null;
        return pts.items;
    }
    return null;
}
