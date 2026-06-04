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

// ── Constants ─────────────────────────────────────────────────────
const HTTP_NOT_FOUND: u16 = 404;
const HTTP_INTERNAL_ERROR: u16 = 500;
const MAX_FOOTPRINT_BYTES: usize = 256 * 1024;
const SEXP_EXT_LEN: usize = ".sexp".len;
const FAR_AWAY: f64 = 999;
const SVG_BBOX_PAD: f64 = 0.5;
// A `(rect x0 y0 x1 y1)` form is the head atom plus four coordinates.
const RECT_FORM_ITEMS: usize = 5;
// JSON `[a,b,c,d]` of four 3-decimal coords — rects + line segments.
const JSON_F4 = "[{d:.3},{d:.3},{d:.3},{d:.3}]";

// The layer palette + pad-label sizing now live in the shared client renderer
// (`assets/footprint_svg.js`); this module only describes the geometry as JSON.

/// Error set for HTTP handlers in this module.
pub const HandlerError = std.mem.Allocator.Error || std.Io.Writer.Error;

const Layer = enum { silk, fab };

// `pts` carries a custom pad's real copper outline (footprint coords); when
// present it's drawn as a filled polygon instead of the pos/size rectangle.
const Pad = struct { id: []const u8, x: f64, y: f64, w: f64, h: f64, shape: []const u8, pts: ?[]const Point = null };
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
    pads: std.ArrayListUnmanaged(Pad) = .empty,
    segs: std.ArrayListUnmanaged(Seg) = .empty,
    circs: std.ArrayListUnmanaged(Circ) = .empty,
    rects: std.ArrayListUnmanaged(RectS) = .empty,
    polys: std.ArrayListUnmanaged(Poly) = .empty,
    court_rects: std.ArrayListUnmanaged(CourtRect) = .empty,
    court_circs: std.ArrayListUnmanaged(CourtCirc) = .empty,

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
        res.status = HTTP_NOT_FOUND;
        return;
    };

    const fp_path = std.fmt.allocPrint(ctx.allocator, "{s}/lib/footprints/{s}.sexp", .{ ctx.project_dir, name }) catch {
        res.status = HTTP_INTERNAL_ERROR;
        return;
    };
    defer ctx.allocator.free(fp_path);
    const content = infra_fs.cwd().readFileAlloc(ctx.allocator, fp_path, MAX_FOOTPRINT_BYTES) catch {
        res.status = HTTP_NOT_FOUND;
        res.body = "Footprint not found";
        return;
    };

    const nodes = parser_mod.parse(ctx.allocator, content) catch {
        res.status = HTTP_INTERNAL_ERROR;
        res.body = "Parse error";
        return;
    };
    if (nodes.len == 0) {
        res.status = HTTP_INTERNAL_ERROR;
        return;
    }
    const top = nodes[0].asList() orelse {
        res.status = HTTP_INTERNAL_ERROR;
        return;
    };

    var shapes: Shapes = .{};
    try collectShapes(ctx.allocator, top[1..], &shapes);

    if (shapes.isEmpty()) {
        res.status = HTTP_NOT_FOUND;
        res.body = "Empty footprint";
        return;
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
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
        break :blk std.fmt.allocPrint(allocator, "{d}", .{@as(i64, @intFromFloat(n))}) catch "";
    };
    const shape: []const u8 = cl[3].asAtom() orelse "rect";
    var px: f64 = 0;
    var py: f64 = 0;
    var pw: f64 = 0;
    var ph: f64 = 0;
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
        if (sub.isForm("poly")) pts = readPolyPts(allocator, sub) catch null;
    }
    return .{ .id = id, .x = px, .y = py, .w = pw, .h = ph, .shape = shape, .pts = pts };
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
    if (sl.len < RECT_FORM_ITEMS) return null;
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
    var pts: std.ArrayListUnmanaged(Point) = .empty;
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
    var b: BBox = .{ .min_x = FAR_AWAY, .min_y = FAR_AWAY, .max_x = -FAR_AWAY, .max_y = -FAR_AWAY };
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
    b.min_x -= SVG_BBOX_PAD;
    b.min_y -= SVG_BBOX_PAD;
    b.max_x += SVG_BBOX_PAD;
    b.max_y += SVG_BBOX_PAD;

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
        try w.print(JSON_F4, .{ r.x0, r.y0, r.x1, r.y1 });
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
        try w.print(JSON_F4, .{ s.x1, s.y1, s.x2, s.y2 });
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
        try w.print(JSON_F4, .{ r.x0, r.y0, r.x1, r.y1 });
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
