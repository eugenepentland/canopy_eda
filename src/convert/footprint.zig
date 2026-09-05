//! KiCad footprint conversion: parses a `.kicad_mod` and emits the equivalent
//! netlisp `(footprint …)` sexpr, mapping KiCad pad types and shapes onto
//! netlisp's. Backs the `convert-footprint` command and the library-import path.

const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const parser_mod = @import("../sexpr/parser.zig");
const printer_mod = @import("../sexpr/printer.zig");
const numeric = @import("../numeric.zig");
const board_layers = @import("../board_layers.zig");
const kicad_fmt = @import("../kicad_pcb/format.zig");
const Node = ast.Node;
const Span = ast.Span;
// ── Constants ─────────────────────────────────────────────────────
const shape_roundrect = "roundrect";
const silk_header = "  (silkscreen\n";
const fab_header = "  (fab\n";
const layer_silk = board_layers.f_silks;
const layer_fab = board_layers.f_fab;
const layer_crtyd = board_layers.f_crtyd;
const full_turn_deg: f64 = 360.0;
const rot_90_deg: f64 = 90.0;
const rot_180_deg: f64 = 180.0;
const rot_270_deg: f64 = 270.0;

/// Convert a KiCad .kicad_mod file to .sexp footprint format.
pub fn convertFootprint(allocator: std.mem.Allocator, source: []const u8) ConvertError![]const u8 {
    const nodes = try parser_mod.parse(allocator, source);
    defer parser_mod.freeNodes(allocator, nodes);

    if (nodes.len == 0) return error.InvalidFormat;
    const root = nodes[0];
    if (!root.isForm("footprint") and !root.isForm("module")) return error.InvalidFormat;

    const children = root.asList() orelse return error.InvalidFormat;
    if (children.len < 2) return error.InvalidFormat;

    // Get name, strip library prefix (e.g., "Lib:Name" -> "Name")
    const raw_name = children[1].asAtom() orelse children[1].asString() orelse return error.InvalidFormat;
    const name = stripLibPrefix(raw_name);

    // Extract description
    var description: []const u8 = "";
    for (children[2..]) |child| {
        if (child.isForm("descr")) {
            const cl = child.asList().?;
            if (cl.len >= 2) description = cl[1].asAtom() orelse cl[1].asString() orelse "";
        }
    }

    // Build output
    var buf: std.Io.Writer.Allocating = .init(allocator);
    defer buf.deinit();
    const w = &buf.writer;

    try w.writeAll("(footprint \"");
    try w.writeAll(name);
    try w.writeAll("\"\n");
    if (description.len > 0) {
        try w.writeAll("  (description \"");
        try w.writeAll(description);
        try w.writeAll("\")\n");
    }

    try validatePasteOwners(children[2..]);

    // Extract pads
    try w.writeByte('\n');
    for (children[2..]) |child| {
        if (child.isForm("pad")) {
            if (!pasteOnly(child)) try emitPad(w, child, children[2..]);
        }
    }

    // Extract courtyard from fp_rect on F.CrtYd layer
    try emitCourtyard(w, children[2..]);

    // Extract silkscreen and fabrication-layer geometry (lines, circles,
    // rects, polys). F.Fab carries the package body outline + pin-1 marker —
    // the richest preview geometry — which earlier conversions dropped.
    try emitLayerGeom(w, children[2..], layer_silk, silk_header);
    try emitLayerGeom(w, children[2..], layer_fab, fab_header);

    try w.writeAll(")\n");
    return buf.toOwnedSlice();
}

/// Write a pad's number/name into slot 1 of a `(pad …)` form as a QUOTED
/// token — the form `kicad_pcb/format.padNumberText` documents as the modern
/// generated shape, and the only one that survives a re-parse intact.
/// A bare token is read back by this project's own tokenizer, whose SI rules
/// (`si_unit_letters = "VAFHR"`) turn a digit-run followed by one of those
/// letters into a NUMBER: a castellated `5V` pad re-read as the float 5, a
/// dual-row `1A` as 1. `padNumberText` returns null for a float node, so such
/// a pad silently vanished from the KiCad writer's net diff and from the
/// netlist — the copper stayed, the binding did not. Pad names with a space
/// or an embedded quote were equally unrepresentable bare.
///
/// `num` is NOT re-escaped, and must not be: every value reaching here is
/// either a `.string` payload this project's own tokenizer produced (already
/// in the grammar's escaped form — a raw `"` would have ended the token, and
/// every `\` is followed by another byte of the same token), a `.atom` slice
/// (the atom charset admits neither `"` nor `\`), or the decimal rendering of
/// a bare int. Running `kicad_fmt.sexprEscape` over an already-escaped string
/// payload would DOUBLE-escape it — the same corruption the module header of
/// `import_kicad.zig` documents. Writing the slice straight back between
/// quotes re-parses to exactly the bytes the source carried.
fn writePadNum(w: anytype, num: []const u8) !void {
    try w.print("\"{s}\"", .{num});
}

fn emitPad(w: anytype, node: Node, siblings: []const Node) !void {
    const children = node.asList() orelse return;
    if (children.len < 4) return;

    // (pad "1" smd roundrect (at X Y [R]) (size W H) (layers ...) ...)
    // num_buf MUST be function-scoped: for a bare-int pad number the slice
    // returned below points into it, and that slice is used far later (the
    // `(pad …)` print + the custom-pad path). A block-local buffer would be
    // a dangling stack slice by then.
    var num_buf: [32]u8 = undefined;
    const num_str = children[1].asAtom() orelse children[1].asString() orelse blk: {
        if (children[1].asNumber()) |n| {
            // Reject a non-finite / out-of-range pad number before the
            // `@intFromFloat` (UB in the safety-off prod build). SKIPPING the
            // pad is the shared contract: `import_kicad.padNumText` does the
            // same, and so does the reader side (`render_html.pinIdStr`) —
            // falling back to "0" would invent a pad that shadows a real
            // `(pad 0 …)` and bind the wrong copper.
            const i = numeric.checkedInt(i64, n) orelse return;
            break :blk std.fmt.bufPrint(&num_buf, "{d}", .{i}) catch return;
        }
        return;
    };
    const pad_type = children[2].asAtom() orelse return;
    const shape = children[3].asAtom() orelse return;

    // Map types
    const out_type = mapPadType(pad_type);
    const out_shape = mapPadShape(shape);

    // Extract position, size, and drill
    var x: f64 = 0;
    var y: f64 = 0;
    var rotation: f64 = 0;
    var sx: f64 = 0;
    var sy: f64 = 0;
    var drill_x: f64 = 0;
    var drill_y: f64 = 0;
    var has_drill = false;
    var is_oval_drill = false;
    var rratio: f64 = 0;
    var has_rratio = false;

    for (children[4..]) |child| {
        if (child.isForm("at")) {
            const cl = child.asList().?;
            if (cl.len >= 3) {
                x = cl[1].asNumber() orelse 0;
                y = cl[2].asNumber() orelse 0;
                if (cl.len >= 4) rotation = cl[3].asNumber() orelse 0;
            }
        }
        if (child.isForm("size")) {
            const cl = child.asList().?;
            if (cl.len >= 3) {
                sx = cl[1].asNumber() orelse 0;
                sy = cl[2].asNumber() orelse 0;
            }
        }
        if (child.isForm("drill")) {
            const cl = child.asList().?;
            has_drill = true;
            // (drill D) or (drill oval DX DY)
            if (cl.len >= 2) {
                if (cl[1].asAtom()) |a| {
                    if (std.mem.eql(u8, a, "oval") and cl.len >= 4) {
                        is_oval_drill = true;
                        drill_x = cl[2].asNumber() orelse 0;
                        drill_y = cl[3].asNumber() orelse 0;
                    }
                } else {
                    drill_x = cl[1].asNumber() orelse 0;
                    drill_y = drill_x;
                }
            }
        }
        if (child.isForm("roundrect_rratio")) {
            const cl = child.asList().?;
            if (cl.len >= 2) {
                rratio = cl[1].asNumber() orelse 0;
                has_rratio = true;
            }
        }
    }

    // Custom pads carry their real copper shape in (primitives (gr_poly …)),
    // not the tiny anchor (size …). Emit the polygon (and a bbox-derived
    // pos/size for the rect-based consumers) instead of the anchor dot.
    if (std.mem.eql(u8, shape, "custom")) {
        if (findCustomPolyPts(children[4..])) |pts| {
            if (try emitCustomPolyPad(w, num_str, out_type, pts, x, y, rotation, has_drill, drill_x)) return;
        }
    }

    const rot_out = padRotOut(rotation);
    const out_sx = if (rot_out.swap) sy else sx;
    const out_sy = if (rot_out.swap) sx else sy;

    // {d:.4} matches KiCad's own metric-footprint precision: 0402 pads land
    // at ±0.485, 0.4 mm-pitch BGAs step by 0.1625 — quantising to 0.01 mm
    // shifts every coordinate by up to 5 µm and the error compounds across
    // an import→export round-trip.
    try w.writeAll("  (pad ");
    try writePadNum(w, num_str);
    try w.print(" {s} {s} (pos {d:.4} {d:.4}", .{ out_type, out_shape, x, y });
    if (rot_out.angle != 0) try w.print(" {d:.4}", .{rot_out.angle});
    try w.print(") (size {d:.4} {d:.4})", .{ out_sx, out_sy });
    if (has_drill) {
        if (is_oval_drill) {
            try w.print(" (drill oval {d:.4} {d:.4})", .{ drill_x, drill_y });
        } else {
            try w.print(" (drill {d:.4})", .{drill_x});
        }
    }
    // Preserve rratio so the proto sync emits the right cornerRoundingRatio —
    // 0.5 on a square pad is what makes a steel-spacer SMD ring render as a
    // visual circle even though the underlying shape is roundrect.
    if (has_rratio and std.mem.eql(u8, out_shape, shape_roundrect)) {
        try w.print(" (roundrect_rratio {d:.3})", .{rratio});
    }
    try emitPasteWindows(w, siblings, .{ .x = x, .y = y, .rotation = rot_out.angle, .w = out_sx, .h = out_sy }, node);
    try w.writeAll(")\n");
}

/// Find the `(pts …)` of the first `(gr_poly …)` inside a pad's
/// `(primitives …)` block. KiCad stores a custom pad's true copper outline
/// there (relative to the pad's `(at …)`); the anchor `(size …)` is just a
/// placeholder dot. Returns the `(xy …)` nodes, or null when the pad has no
/// polygon primitive.
fn findCustomPolyPts(pad_items: []const Node) ?[]const Node {
    for (pad_items) |it| {
        if (!it.isForm("primitives")) continue;
        const pl = it.asList() orelse continue;
        for (pl[1..]) |prim| {
            if (!prim.isForm("gr_poly")) continue;
            const gl = prim.asList() orelse continue;
            if (findFormItems(gl[1..], "pts")) |pts| return pts;
        }
    }
    return null;
}

/// How a plain pad's KiCad `at`-angle lands in the emitted `.sexp`. An exact
/// quarter-turn flattens into the axis-aligned model every consumer reads
/// natively: 90°/270° swap width and height — identical copper for the 2-fold
/// symmetric shapes emitted here — and 0°/180° are the identity. That is the
/// behavior every committed footprint was generated under (stock libraries
/// rotate pads in quarter turns), so those conversions stay unchanged. Any
/// other angle used to be dropped on the floor — a 315°-turned square emitted
/// as axis-aligned copper — and is now preserved as the third `(pos X Y ROT)`
/// token, converted into netlisp's frame: the two frames turn opposite ways
/// over the same y-down numbers, so the token is `mod(360 − kicad, 360)`, the
/// same bridge as `serve/sync.zig`'s `netlispRotToKicad`. `angle` 0 means "no
/// token" — a preserved angle is never 0 because 0 flattens. `import_kicad`'s
/// board-pad emitter shares this landing, feeding it the footprint-local
/// angle it recovers first (board files bake the footprint rotation into
/// every pad angle) — the two emitters must never disagree about which
/// angles flatten and which carry a token.
pub fn padRotOut(kicad_rot_deg: f64) struct { swap: bool, angle: f64 } {
    const rot_mod = @mod(kicad_rot_deg, full_turn_deg);
    if (rot_mod == rot_90_deg or rot_mod == rot_270_deg) return .{ .swap = true, .angle = 0 };
    if (rot_mod == 0 or rot_mod == rot_180_deg) return .{ .swap = false, .angle = 0 };
    return .{ .swap = false, .angle = @mod(full_turn_deg - rot_mod, full_turn_deg) };
}

/// Rotate a pad-local point by the pad's KiCad `at`-angle and translate by
/// the pad origin `(tx, ty)`, yielding footprint-absolute coordinates. KiCad's
/// angle is counter-clockwise AS DISPLAYED over y-down coordinates — `[[c, s],
/// [−s, c]]` on the raw numbers — the opposite sense from netlisp's own
/// `pose_math.rotate` matrix `[[c, −s], [s, c]]`. Baking with netlisp's matrix
/// on the un-negated angle mirrored every rotated custom pad; this is the same
/// relation the rest of the KiCad bridge encodes as `mod(360 − rot, 360)`
/// (`serve/sync.zig` `netlispRotToKicad`, `kicad_pcb/import_layout.zig`
/// `kicadRotToNetlisp`).
fn rotTranslate(lx: f64, ly: f64, kicad_rot_deg: f64, tx: f64, ty: f64) struct { x: f64, y: f64 } {
    if (kicad_rot_deg == 0) return .{ .x = lx + tx, .y = ly + ty };
    const rad = kicad_rot_deg * std.math.pi / 180.0;
    const c = @cos(rad);
    const s = @sin(rad);
    return .{ .x = lx * c + ly * s + tx, .y = ly * c - lx * s + ty };
}

/// Emit a custom pad as its real polygon: a bbox-derived `(pos …)`/`(size …)`
/// for the rectangle-based renderer/placement/router, plus a `(poly …)` of the
/// footprint-absolute outline points for polygon-aware consumers (footprint
/// preview, KiCad export). Returns false (caller falls back to the anchor) when
/// the primitive has fewer than 3 points.
fn emitCustomPolyPad(
    w: anytype,
    num_str: []const u8,
    out_type: []const u8,
    pts: []const Node,
    tx: f64,
    ty: f64,
    rotation: f64,
    has_drill: bool,
    drill: f64,
) !bool {
    var min_x: f64 = std.math.inf(f64);
    var min_y: f64 = std.math.inf(f64);
    var max_x: f64 = -std.math.inf(f64);
    var max_y: f64 = -std.math.inf(f64);
    var count: usize = 0;
    for (pts) |pt| {
        const p = xyPoint(pt, rotation, tx, ty) orelse continue;
        accumulateBBox(p.x, p.y, &min_x, &min_y, &max_x, &max_y);
        count += 1;
    }
    if (count < 3) return false;

    const cx = (min_x + max_x) / 2.0;
    const cy = (min_y + max_y) / 2.0;
    try w.writeAll("  (pad ");
    try writePadNum(w, num_str);
    try w.print(" {s} custom (pos {d:.3} {d:.3}) (size {d:.3} {d:.3})", .{
        out_type, cx, cy, max_x - min_x, max_y - min_y,
    });
    if (has_drill) try w.print(" (drill {d:.2})", .{drill});
    try w.writeAll("\n    (poly");
    for (pts) |pt| {
        const p = xyPoint(pt, rotation, tx, ty) orelse continue;
        try w.print(" ({d:.3} {d:.3})", .{ p.x, p.y });
    }
    try w.writeAll("))\n");
    return true;
}

/// Decode an `(xy LX LY)` node into a footprint-absolute point (after the
/// pad's rotation + translation), or null if it isn't a 2-coordinate `xy`.
fn xyPoint(pt: Node, rotation: f64, tx: f64, ty: f64) ?struct { x: f64, y: f64 } {
    if (!pt.isForm("xy")) return null;
    const pl = pt.asList() orelse return null;
    if (pl.len < 3) return null;
    const lx = pl[1].asNumber() orelse return null;
    const ly = pl[2].asNumber() orelse return null;
    const p = rotTranslate(lx, ly, rotation, tx, ty);
    return .{ .x = p.x, .y = p.y };
}

/// Read a `(name X Y …)` form returning the first two numeric children, or
/// `null` if absent. Used to extract `(start X Y)`, `(end X Y)`, `(center X
/// Y)` from inside fp_line / fp_circle / fp_rect bodies.
fn readPair(items: []const Node, name: []const u8) ?struct { x: f64, y: f64 } {
    for (items) |sub| {
        if (!sub.isForm(name)) continue;
        const sl = sub.asList() orelse continue;
        if (sl.len < 3) return null;
        const x = sl[1].asNumber() orelse return null;
        const y = sl[2].asNumber() orelse return null;
        return .{ .x = x, .y = y };
    }
    return null;
}

fn emitCourtyard(w: anytype, children: []const Node) !void {
    // fp_circle on F.CrtYd is what mounting-spacer / round-body footprints
    // (e.g. wurth WA-SMSI 9774020633R) use instead of a rectangular boundary.
    // Capture it before falling through to the rect / line-bbox paths below.
    for (children) |child| {
        if (try emitCourtyardCircle(w, child)) return;
    }
    for (children) |child| {
        if (try emitCourtyardRect(w, child)) return;
    }
    try emitCourtyardLineBBox(w, children);
}

fn emitCourtyardCircle(w: anytype, child: Node) !bool {
    if (!child.isForm("fp_circle")) return false;
    const cl = child.asList() orelse return false;
    if (!std.mem.eql(u8, getLayer(cl[1..]), layer_crtyd)) return false;
    const center = readPair(cl[1..], "center") orelse return false;
    const end = readPair(cl[1..], "end") orelse return false;
    const dx = end.x - center.x;
    const dy = end.y - center.y;
    const radius = @sqrt(dx * dx + dy * dy);
    try w.print("  (courtyard (circle ({d:.2} {d:.2}) {d:.3}))\n", .{ center.x, center.y, radius });
    return true;
}

fn emitCourtyardRect(w: anytype, child: Node) !bool {
    if (!child.isForm("fp_rect")) return false;
    const cl = child.asList() orelse return false;
    if (!std.mem.eql(u8, getLayer(cl[1..]), layer_crtyd)) return false;
    const start = readPair(cl[1..], "start") orelse return false;
    const end = readPair(cl[1..], "end") orelse return false;
    try w.print("  (courtyard (rect {d:.2} {d:.2} {d:.2} {d:.2}))\n", .{ start.x, start.y, end.x, end.y });
    return true;
}

fn emitCourtyardLineBBox(w: anytype, children: []const Node) !void {
    var min_x: f64 = std.math.inf(f64);
    var min_y: f64 = std.math.inf(f64);
    var max_x: f64 = -std.math.inf(f64);
    var max_y: f64 = -std.math.inf(f64);
    var found = false;
    for (children) |child| {
        if (try expandBBoxFromCrtydLine(child, &min_x, &min_y, &max_x, &max_y)) found = true;
    }
    if (found) {
        try w.print("  (courtyard (rect {d:.3} {d:.3} {d:.3} {d:.3}))\n", .{ min_x, min_y, max_x, max_y });
    }
}

fn expandBBoxFromCrtydLine(child: Node, min_x: *f64, min_y: *f64, max_x: *f64, max_y: *f64) !bool {
    if (!child.isForm("fp_line")) return false;
    const cl = child.asList() orelse return false;
    if (!std.mem.eql(u8, getLayer(cl[1..]), layer_crtyd)) return false;
    if (readPair(cl[1..], "start")) |p| accumulateBBox(p.x, p.y, min_x, min_y, max_x, max_y);
    if (readPair(cl[1..], "end")) |p| accumulateBBox(p.x, p.y, min_x, min_y, max_x, max_y);
    return true;
}

fn accumulateBBox(x: f64, y: f64, min_x: *f64, min_y: *f64, max_x: *f64, max_y: *f64) void {
    if (x < min_x.*) min_x.* = x;
    if (y < min_y.*) min_y.* = y;
    if (x > max_x.*) max_x.* = x;
    if (y > max_y.*) max_y.* = y;
}

/// Emit every graphic on `layer_name` (silkscreen or fabrication) as a single
/// block opened by `header`. fp_line/fp_circle/fp_rect/fp_poly map to
/// (line …)/(circle …)/(rect …)/(poly …); the block is only opened if at
/// least one matching graphic exists.
fn emitLayerGeom(w: anytype, children: []const Node, layer_name: []const u8, header: []const u8) !void {
    var open = false;
    for (children) |child| {
        try emitGeomLine(w, child, layer_name, &open, header);
        try emitGeomCircle(w, child, layer_name, &open, header);
        try emitGeomRect(w, child, layer_name, &open, header);
        try emitGeomPoly(w, child, layer_name, &open, header);
    }
    if (open) try w.writeAll("  )\n");
}

fn ensureBlockOpen(w: anytype, open: *bool, header: []const u8) !void {
    if (open.*) return;
    try w.writeAll(header);
    open.* = true;
}

fn emitGeomLine(w: anytype, child: Node, layer_name: []const u8, open: *bool, header: []const u8) !void {
    if (!child.isForm("fp_line")) return;
    const cl = child.asList() orelse return;
    if (!std.mem.eql(u8, getLayer(cl[1..]), layer_name)) return;
    const start = readPair(cl[1..], "start") orelse return;
    const end = readPair(cl[1..], "end") orelse return;
    try ensureBlockOpen(w, open, header);
    try w.print("    (line ({d:.2} {d:.2}) ({d:.2} {d:.2}))\n", .{ start.x, start.y, end.x, end.y });
}

fn emitGeomCircle(w: anytype, child: Node, layer_name: []const u8, open: *bool, header: []const u8) !void {
    if (!child.isForm("fp_circle")) return;
    const cl = child.asList() orelse return;
    if (!std.mem.eql(u8, getLayer(cl[1..]), layer_name)) return;
    const center = readPair(cl[1..], "center") orelse return;
    const end = readPair(cl[1..], "end") orelse return;
    const dx = end.x - center.x;
    const dy = end.y - center.y;
    const radius = @sqrt(dx * dx + dy * dy);
    try ensureBlockOpen(w, open, header);
    try w.print("    (circle ({d:.2} {d:.2}) {d:.2})\n", .{ center.x, center.y, radius });
}

fn emitGeomRect(w: anytype, child: Node, layer_name: []const u8, open: *bool, header: []const u8) !void {
    if (!child.isForm("fp_rect")) return;
    const cl = child.asList() orelse return;
    if (!std.mem.eql(u8, getLayer(cl[1..]), layer_name)) return;
    const start = readPair(cl[1..], "start") orelse return;
    const end = readPair(cl[1..], "end") orelse return;
    try ensureBlockOpen(w, open, header);
    try w.print("    (rect {d:.2} {d:.2} {d:.2} {d:.2})\n", .{ start.x, start.y, end.x, end.y });
}

fn emitGeomPoly(w: anytype, child: Node, layer_name: []const u8, open: *bool, header: []const u8) !void {
    if (!child.isForm("fp_poly")) return;
    const cl = child.asList() orelse return;
    if (!std.mem.eql(u8, getLayer(cl[1..]), layer_name)) return;
    const pts = findFormItems(cl[1..], "pts") orelse return;
    try ensureBlockOpen(w, open, header);
    try w.writeAll("    (poly");
    for (pts) |pt| {
        if (!pt.isForm("xy")) continue;
        const pl = pt.asList() orelse continue;
        if (pl.len < 3) continue;
        const x = pl[1].asNumber() orelse continue;
        const y = pl[2].asNumber() orelse continue;
        try w.print(" ({d:.2} {d:.2})", .{ x, y });
    }
    try w.writeAll(")\n");
}

/// Return the children (excluding the head atom) of the first `name` form
/// found in `items`, or null. Used to reach the `(xy …)` list inside `(pts …)`.
fn findFormItems(items: []const Node, name: []const u8) ?[]const Node {
    for (items) |it| {
        if (it.isForm(name)) {
            const l = it.asList() orelse return null;
            return l[1..];
        }
    }
    return null;
}

fn getLayer(items: []const Node) []const u8 {
    for (items) |item| {
        if (item.isForm("layer")) {
            const cl = item.asList().?;
            if (cl.len >= 2) return cl[1].asAtom() orelse cl[1].asString() orelse "";
        }
    }
    return "";
}

fn stripLibPrefix(name: []const u8) []const u8 {
    if (std.mem.indexOfScalar(u8, name, ':')) |idx| {
        return name[idx + 1 ..];
    }
    return name;
}

/// Translate a KiCad pad type token (`smd`/`thru_hole`/`np_thru_hole`) into
/// the project's compact form (`smd`/`thru`/`npth`); unknown inputs default
/// to `smd` so partial conversions still produce a valid footprint.
pub fn mapPadType(kicad: []const u8) []const u8 {
    if (std.mem.eql(u8, kicad, "smd")) return "smd";
    if (std.mem.eql(u8, kicad, "thru_hole")) return "thru";
    if (std.mem.eql(u8, kicad, "np_thru_hole")) return "npth";
    return "smd";
}

/// Normalise a KiCad pad shape name into the subset the project's footprint
/// renderer understands; unrecognised shapes fall back to `rect` so import
/// of an unfamiliar footprint still produces a usable approximation.
pub fn mapPadShape(kicad: []const u8) []const u8 {
    if (std.mem.eql(u8, kicad, shape_roundrect)) return shape_roundrect;
    if (std.mem.eql(u8, kicad, "circle")) return "circle";
    if (std.mem.eql(u8, kicad, "oval")) return "oval";
    if (std.mem.eql(u8, kicad, "rect")) return "rect";
    if (std.mem.eql(u8, kicad, "custom")) return "custom";
    return "rect";
}

pub const ConvertError = error{
    InvalidFormat,
    OutOfMemory,
    UnexpectedEof,
    UnexpectedRparen,
    UnexpectedCharacter,
    UnterminatedString,
    InvalidNumber,
    TooDeep,
    WriteFailed,
};

// spec: convert/footprint - Converts a KiCad footprint file into S-expression format
test "convert simple footprint" {
    const alloc = std.testing.allocator;
    const input =
        \\(footprint "R_0402_1005Metric"
        \\  (descr "Resistor SMD 0402")
        \\  (pad "1" smd roundrect
        \\    (at -0.51 0)
        \\    (size 0.54 0.64)
        \\    (layers "F.Cu" "F.Mask" "F.Paste")
        \\  )
        \\  (pad "2" smd roundrect
        \\    (at 0.51 0)
        \\    (size 0.54 0.64)
        \\    (layers "F.Cu" "F.Mask" "F.Paste")
        \\  )
        \\  (fp_rect
        \\    (start -0.93 -0.47)
        \\    (end 0.93 0.47)
        \\    (layer "F.CrtYd")
        \\  )
        \\)
    ;
    const output = try convertFootprint(alloc, input);
    defer alloc.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "\"R_0402_1005Metric\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "(pad \"1\" smd roundrect") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "(courtyard") != null);
}

// spec: convert/footprint - Bare-integer pad numbers survive the conversion (no dangling num_buf slice)
test "convert bare-int pad numbers do not dangle" {
    const alloc = std.testing.allocator;
    // KiCad-5 `(module …)` / re-saved boards spell numeric pads as bare
    // integers. Emit several so the print of the first pad's bare-int number
    // happens after later pads reuse the (formerly block-local) num_buf; the
    // hoisted buffer keeps every number valid.
    const input =
        \\(footprint "R_multi"
        \\  (pad 1 smd rect (at -1 0) (size 0.5 0.5) (layers "F.Cu"))
        \\  (pad 22 smd rect (at 0 0) (size 0.5 0.5) (layers "F.Cu"))
        \\  (pad 333 thru_hole circle (at 1 0) (size 0.9 0.9) (drill 0.5) (layers "*.Cu"))
        \\)
    ;
    const output = try convertFootprint(alloc, input);
    defer alloc.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "(pad \"1\" smd rect") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "(pad \"22\" smd rect") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "(pad \"333\" thru circle") != null);
    // No garbage/empty pad number leaked in (would look like "(pad  smd").
    try std.testing.expect(std.mem.indexOf(u8, output, "(pad \"\"") == null);
}

// spec: convert/footprint - Captures F.Fab body outline and silkscreen polygons into the footprint
test "convert captures F.Fab body outline and silkscreen polys" {
    const alloc = std.testing.allocator;
    const input =
        \\(footprint "X"
        \\  (pad "1" smd rect (at 0 0) (size 1 1) (layers "F.Cu"))
        \\  (fp_line (start -1 -1) (end 1 -1) (layer "F.Fab") (width 0.1))
        \\  (fp_poly (pts (xy -1 -1) (xy -1 1) (xy 1 1)) (layer "F.SilkS") (width 0) (fill solid))
        \\  (fp_circle (center 0 0) (end 0.5 0) (layer "F.Fab"))
        \\)
    ;
    const output = try convertFootprint(alloc, input);
    defer alloc.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "(fab\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "(line (-1.00 -1.00) (1.00 -1.00))") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "(circle (0.00 0.00) 0.50)") != null);
    // F.SilkS poly lands inside the silkscreen block, not the fab block.
    try std.testing.expect(std.mem.indexOf(u8, output, "(poly (-1.00 -1.00) (-1.00 1.00) (1.00 1.00))") != null);
}

// spec: convert/footprint - Expands a custom pad's gr_poly primitive into a real polygon outline with bbox-derived pos/size
test "convert custom pad expands gr_poly into polygon + bbox" {
    const alloc = std.testing.allocator;
    const input =
        \\(footprint "X"
        \\  (pad "1" smd custom
        \\    (at 1 1)
        \\    (size 0.25 0.25)
        \\    (layers "F.Cu" "F.Mask" "F.Paste")
        \\    (options (clearance outline) (anchor rect))
        \\    (primitives
        \\      (gr_poly (pts (xy -1 -1) (xy 1 -1) (xy 1 1) (xy -1 1)) (width 0))
        \\    )
        \\  )
        \\)
    ;
    const output = try convertFootprint(alloc, input);
    defer alloc.free(output);
    // The tiny 0.25×0.25 anchor is replaced by the polygon's bbox: 2×2 centred
    // on the pad origin (1,1) — local pts (±1,±1) + at(1,1) → abs (0..2, 0..2).
    try std.testing.expect(std.mem.indexOf(u8, output, "(pad \"1\" smd custom (pos 1.000 1.000) (size 2.000 2.000)") != null);
    // Outline is preserved in footprint-absolute coordinates.
    try std.testing.expect(std.mem.indexOf(u8, output, "(poly (0.000 0.000) (2.000 0.000) (2.000 2.000) (0.000 2.000))") != null);
}

// Regression: the footprint converter must preserve EAGLE-derived vendor pads.
test "convert footprint accepts dollar-sign pad identifiers" {
    const alloc = std.testing.allocator;
    const input =
        \\(footprint "VENDOR_RF"
        \\  (pad P$1 smd custom (at 0 0) (size 0.5 0.5)
        \\    (primitives (gr_poly (pts (xy -1 -1) (xy 1 -1) (xy 1 1) (xy -1 1)) (width 0.1))))
        \\  (pad P$2 smd rect (at 0 2) (size 0.5 1)))
    ;
    const output = try convertFootprint(alloc, input);
    defer alloc.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "(pad \"P$1\" smd custom") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "(pad \"P$2\" smd rect") != null);
}

// spec: convert/footprint - Bakes a custom pad's at-angle into the emitted polygon in KiCad's counter-clockwise display sense
test "convert custom pad bakes at-angle in KiCad's sense" {
    const alloc = std.testing.allocator;
    // A right triangle — deliberately asymmetric so a wrong-sense bake cannot
    // produce the same points — on a pad at (1, 1) turned 30° in KiCad's
    // frame. KiCad's angle is CCW as displayed over y-down numbers, so each
    // local (lx, ly) lands at (lx·c + ly·s + 1, −lx·s + ly·c + 1) with
    // c = cos 30° ≈ 0.8660254, s = sin 30° = 0.5:
    //   (0, 0) → (1.000, 1.000)
    //   (2, 0) → (2.732, 0.000)   — netlisp's matrix would put it at (2.732, 2.000)
    //   (0, 1) → (1.500, 1.866)
    const input =
        \\(footprint "X"
        \\  (pad "1" smd custom
        \\    (at 1 1 30)
        \\    (size 0.25 0.25)
        \\    (layers "F.Cu" "F.Mask" "F.Paste")
        \\    (options (clearance outline) (anchor rect))
        \\    (primitives
        \\      (gr_poly (pts (xy 0 0) (xy 2 0) (xy 0 1)) (width 0))
        \\    )
        \\  )
        \\)
    ;
    const output = try convertFootprint(alloc, input);
    defer alloc.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "(poly (1.000 1.000) (2.732 0.000) (1.500 1.866))") != null);
    // The mirrored point the un-negated bake produced.
    try std.testing.expect(std.mem.indexOf(u8, output, "(2.732 2.000)") == null);
    // bbox of the correctly-rotated points: x ∈ [1.000, 2.732], y ∈ [0.000, 1.866].
    try std.testing.expect(std.mem.indexOf(u8, output, "(pos 1.866 0.933) (size 1.732 1.866)") != null);
}

// spec: convert/footprint - Flattens a plain pad's exact quarter-turn at-angle into a width/height swap with no rotation token
test "convert flattens exact quarter-turn pad at-angle to size swap" {
    const alloc = std.testing.allocator;
    const input =
        \\(footprint "X"
        \\  (pad "1" smd rect (at -1 0 90) (size 0.5 1.0) (layers "F.Cu"))
        \\  (pad "2" smd rect (at 1 0 -90) (size 0.6 1.2) (layers "F.Cu"))
        \\  (pad "3" smd rect (at 0 1 180) (size 0.7 1.4) (layers "F.Cu"))
        \\  (pad "4" smd rect (at 0 -1 450) (size 0.8 1.6) (layers "F.Cu"))
        \\)
    ;
    const output = try convertFootprint(alloc, input);
    defer alloc.free(output);
    // 90° and −90° (= 270°) swap W×H; the two-number (pos …) shows no angle
    // token — identical copper, and identical output to every conversion the
    // committed library was generated under.
    try std.testing.expect(std.mem.indexOf(u8, output, "(pad \"1\" smd rect (pos -1.0000 0.0000) (size 1.0000 0.5000))") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "(pad \"2\" smd rect (pos 1.0000 0.0000) (size 1.2000 0.6000))") != null);
    // 180° is the identity for the 2-fold-symmetric shapes emitted here.
    try std.testing.expect(std.mem.indexOf(u8, output, "(pad \"3\" smd rect (pos 0.0000 1.0000) (size 0.7000 1.4000))") != null);
    // Angles reduce mod 360: 450° is the 90° swap.
    try std.testing.expect(std.mem.indexOf(u8, output, "(pad \"4\" smd rect (pos 0.0000 -1.0000) (size 1.6000 0.8000))") != null);
}

// spec: convert/footprint - Preserves a plain pad's non-quarter-turn at-angle as a netlisp-frame pos rotation token
test "convert preserves non-quarter pad at-angle in netlisp frame" {
    const alloc = std.testing.allocator;
    // Pad 1 is the in-tree shape that motivated this: DQN0004A-MFG's centre
    // pad, a 0.58 mm square at 315° — a diamond the old converter silently
    // emitted as an axis-aligned square.
    const input =
        \\(footprint "X"
        \\  (pad "1" smd rect (at 0 0 315) (size 0.58 0.58) (layers "F.Cu"))
        \\  (pad "2" smd rect (at 2 1 30) (size 1.2 0.6) (layers "F.Cu"))
        \\  (pad "3" smd rect (at -2 1 100) (size 0.9 1.8) (layers "F.Cu"))
        \\)
    ;
    const output = try convertFootprint(alloc, input);
    defer alloc.free(output);
    // The token is netlisp's frame — mod(360 − kicad, 360), the same bridge as
    // serve/sync.zig's netlispRotToKicad — and the size stays the pad's own
    // unrotated W×H, never swapped.
    try std.testing.expect(std.mem.indexOf(u8, output, "(pad \"1\" smd rect (pos 0.0000 0.0000 45.0000) (size 0.5800 0.5800))") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "(pad \"2\" smd rect (pos 2.0000 1.0000 330.0000) (size 1.2000 0.6000))") != null);
    // 100° used to fall in the old near-90° window and flatten to a 90° swap,
    // 10° wrong; it now keeps its real angle.
    try std.testing.expect(std.mem.indexOf(u8, output, "(pad \"3\" smd rect (pos -2.0000 1.0000 260.0000) (size 0.9000 1.8000))") != null);
}

// spec: convert/footprint - Emits the pad number as a quoted token so an SI-shaped or spaced pad name reads back unchanged
test "convert quotes pad numbers so SI-shaped names survive a re-parse" {
    const alloc = std.testing.allocator;
    // `5V` (castellated module) and `1A` (dual-row connector) are real pad
    // names. Written bare, this project's own tokenizer reads them as SI
    // values — `si_unit_letters = "VAFHR"` — so `5V` came back as the number
    // 5 and `1A` as 1; `padNumberText` rejects a float outright, so the pad
    // vanished from the net diff entirely. `3V3` already lexed as an atom and
    // must keep working; `P 1` can only be spelled quoted at all.
    const input =
        \\(footprint "CASTELLATED"
        \\  (pad "5V" smd rect (at 0 0) (size 1 1) (layers "F.Cu"))
        \\  (pad "1A" smd rect (at 1 0) (size 1 1) (layers "F.Cu"))
        \\  (pad "P 1" smd rect (at 2 0) (size 1 1) (layers "F.Cu"))
        \\  (pad "3V3" smd rect (at 3 0) (size 1 1) (layers "F.Cu"))
        \\  (pad "A\"B" smd rect (at 4 0) (size 1 1) (layers "F.Cu"))
        \\)
    ;
    const output = try convertFootprint(alloc, input);
    defer alloc.free(output);
    try std.testing.expect(std.mem.indexOf(u8, output, "(pad \"5V\" smd rect") != null);

    // Re-read the emitted text through the SAME reader the KiCad writer and
    // the netlist use: every pad name must come back byte-identical.
    var arena = std.heap.ArenaAllocator.init(alloc);
    defer arena.deinit();
    const a = arena.allocator();
    const nodes = try parser_mod.parse(a, output);
    const children = nodes[0].asList().?;
    const want = [_][]const u8{ "5V", "1A", "P 1", "3V3", "A\\\"B" };
    var seen: usize = 0;
    for (children[2..]) |child| {
        if (!child.isForm("pad")) continue;
        const cl = child.asList().?;
        try std.testing.expect(seen < want.len);
        try std.testing.expectEqualStrings(want[seen], kicad_fmt.padNumberText(a, cl[1]).?);
        seen += 1;
    }
    try std.testing.expectEqual(@as(usize, want.len), seen);
}

const PasteOwner = struct { x: f64, y: f64, rotation: f64, w: f64, h: f64 };
fn hasLayer(node: Node, layer: []const u8) bool {
    const children = node.asList() orelse return false;
    for (children) |child| if (child.isForm("layers")) {
        for (child.asList().?[1..]) |v| {
            const text = v.asString() orelse v.asAtom() orelse continue;
            if (std.mem.eql(u8, text, layer)) return true;
        }
    };
    return false;
}
fn pasteOnly(node: Node) bool {
    return node.isForm("pad") and hasLayer(node, board_layers.f_paste) and !hasLayer(node, board_layers.f_cu) and !hasLayer(node, "*.Cu");
}
fn pasteRect(node: Node, owner: PasteOwner) ?@import("../footprint_paste.zig").Aperture {
    const items = node.asList() orelse return null;
    if (items.len < 4 or !std.mem.eql(u8, items[3].asAtom() orelse "", "rect")) return null;
    var x: f64 = 0;
    var y: f64 = 0;
    var rot: f64 = 0;
    var w: f64 = 0;
    var h: f64 = 0;
    for (items) |item| {
        const v = item.asList() orelse continue;
        if (item.isForm("at") and v.len >= 3) {
            x = v[1].asNumber() orelse return null;
            y = v[2].asNumber() orelse return null;
            if (v.len >= 4) rot = v[3].asNumber() orelse return null;
        }
        if (item.isForm("size") and v.len >= 3) {
            w = v[1].asNumber() orelse return null;
            h = v[2].asNumber() orelse return null;
        }
    }
    const angle = owner.rotation * std.math.pi / 180;
    const dx = x - owner.x;
    const dy = y - owner.y;
    const px = dx * @cos(angle) + dy * @sin(angle);
    const py = -dx * @sin(angle) + dy * @cos(angle);
    const rel = padRotOut(rot + owner.rotation);
    if (rel.angle != 0) return null;
    const pw = if (rel.swap) h else w;
    const ph = if (rel.swap) w else h;
    if (pw <= 0 or ph <= 0 or @abs(px) + pw / 2 > owner.w / 2 + 1e-5 or @abs(py) + ph / 2 > owner.h / 2 + 1e-5) return null;
    return .{ .x = px, .y = py, .w = pw, .h = ph };
}
fn emitPasteWindows(w: anytype, siblings: []const Node, owner: PasteOwner, node: Node) !void {
    var started = false;
    for (siblings) |candidate| {
        if (!pasteOnly(candidate)) continue;
        if (pasteRect(candidate, owner)) |v| {
            if (!started) {
                try w.writeAll(" (paste");
                started = true;
            }
            try w.print(" (rect {d:.6} {d:.6} {d:.6} {d:.6})", .{ v.x, v.y, v.w, v.h });
        }
    }
    if (started) try w.writeByte(')') else if (!hasLayer(node, board_layers.f_paste) and hasLayer(node, board_layers.f_cu)) try w.writeAll(" no-paste");
}

fn pasteOwner(node: Node) ?PasteOwner {
    if (!node.isForm("pad") or !hasLayer(node, board_layers.f_cu)) return null;
    const fields = node.asList().?;
    if (fields.len < 4 or std.mem.eql(u8, fields[3].asAtom() orelse "", "custom")) return null;
    var p: PasteOwner = .{ .x = 0, .y = 0, .rotation = 0, .w = 0, .h = 0 };
    for (node.asList().?) |child| {
        const v = child.asList() orelse continue;
        if (child.isForm("at") and v.len >= 3) {
            p.x = v[1].asNumber() orelse return null;
            p.y = v[2].asNumber() orelse return null;
            if (v.len >= 4) p.rotation = v[3].asNumber() orelse return null;
        }
        if (child.isForm("size") and v.len >= 3) {
            p.w = v[1].asNumber() orelse return null;
            p.h = v[2].asNumber() orelse return null;
        }
    }
    const rot = padRotOut(p.rotation);
    p.rotation = rot.angle;
    if (rot.swap) std.mem.swap(f64, &p.w, &p.h);
    return p;
}
fn validatePasteOwners(siblings: []const Node) error{InvalidFormat}!void {
    for (siblings) |candidate| {
        if (!pasteOnly(candidate)) continue;
        var owners: usize = 0;
        for (siblings) |node| {
            const owner = pasteOwner(node) orelse continue;
            if (pasteRect(candidate, owner) != null) owners += 1;
        }
        // Reject unsupported or ambiguous stencil geometry instead of dropping it.
        if (owners != 1) return error.InvalidFormat;
    }
}

// spec: IC package builder - KiCad import rejects stencil openings without a unique supported copper owner
test "IC package KiCad unsupported and ambiguous stencil owners" {
    const opening = "(pad \"\" smd rect (at 0 0) (size 0.4 0.4) (layers \"F.Paste\"))";
    const copper = "(pad \"1\" smd rect (at 0 0) (size 2 2) (layers \"F.Cu\"))";
    const sources = .{
        "(footprint \"x\" " ++ opening ++ ")",
        "(footprint \"x\" " ++ copper ++ copper ++ opening ++ ")",
        "(footprint \"x\" (pad \"1\" smd custom (at 0 0) (size 2 2) (layers \"F.Cu\")) " ++ opening ++ ")",
    };
    inline for (sources) |source| try std.testing.expectError(error.InvalidFormat, convertFootprint(std.testing.allocator, source));
}
