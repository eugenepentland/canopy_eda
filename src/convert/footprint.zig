const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const parser_mod = @import("../sexpr/parser.zig");
const printer_mod = @import("../sexpr/printer.zig");
const Node = ast.Node;
const Span = ast.Span;

// ── Constants ─────────────────────────────────────────────────────
const SHAPE_ROUNDRECT = "roundrect";
const SILK_HEADER = "  (silkscreen\n";
const FAB_HEADER = "  (fab\n";
const LAYER_SILK = "F.SilkS";
const LAYER_FAB = "F.Fab";
const FULL_TURN_DEG: f64 = 360.0;
const ROT_45_DEG: f64 = 45.0;
const ROT_135_DEG: f64 = 135.0;
const ROT_225_DEG: f64 = 225.0;
const ROT_315_DEG: f64 = 315.0;

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
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll("(footprint \"");
    try w.writeAll(name);
    try w.writeAll("\"\n");
    if (description.len > 0) {
        try w.writeAll("  (description \"");
        try w.writeAll(description);
        try w.writeAll("\")\n");
    }

    // Extract pads
    try w.writeByte('\n');
    for (children[2..]) |child| {
        if (child.isForm("pad")) {
            try emitPad(w, child);
        }
    }

    // Extract courtyard from fp_rect on F.CrtYd layer
    try emitCourtyard(w, children[2..]);

    // Extract silkscreen and fabrication-layer geometry (lines, circles,
    // rects, polys). F.Fab carries the package body outline + pin-1 marker —
    // the richest preview geometry — which earlier conversions dropped.
    try emitLayerGeom(w, children[2..], LAYER_SILK, SILK_HEADER);
    try emitLayerGeom(w, children[2..], LAYER_FAB, FAB_HEADER);

    try w.writeAll(")\n");
    return buf.toOwnedSlice(allocator);
}

fn emitPad(w: anytype, node: Node) !void {
    const children = node.asList() orelse return;
    if (children.len < 4) return;

    // (pad "1" smd roundrect (at X Y [R]) (size W H) (layers ...) ...)
    const num_str = children[1].asAtom() orelse children[1].asString() orelse blk: {
        if (children[1].asNumber()) |n| {
            const i: i64 = @intFromFloat(n);
            var num_buf: [32]u8 = undefined;
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

    // Apply pad rotation: 90° or 270° swaps width and height
    const rot_mod = @mod(rotation, FULL_TURN_DEG);
    const is_rotated = (rot_mod > ROT_45_DEG and rot_mod < ROT_135_DEG) or (rot_mod > ROT_225_DEG and rot_mod < ROT_315_DEG);
    const out_sx = if (is_rotated) sy else sx;
    const out_sy = if (is_rotated) sx else sy;

    try w.print("  (pad {s} {s} {s} (pos {d:.2} {d:.2}) (size {d:.2} {d:.2})", .{
        num_str, out_type, out_shape, x, y, out_sx, out_sy,
    });
    if (has_drill) {
        if (is_oval_drill) {
            try w.print(" (drill oval {d:.2} {d:.2})", .{ drill_x, drill_y });
        } else {
            try w.print(" (drill {d:.2})", .{drill_x});
        }
    }
    // Preserve rratio so the proto sync emits the right cornerRoundingRatio —
    // 0.5 on a square pad is what makes a steel-spacer SMD ring render as a
    // visual circle even though the underlying shape is roundrect.
    if (has_rratio and std.mem.eql(u8, out_shape, SHAPE_ROUNDRECT)) {
        try w.print(" (roundrect_rratio {d:.3})", .{rratio});
    }
    try w.writeAll(")\n");
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
    if (!std.mem.eql(u8, getLayer(cl[1..]), "F.CrtYd")) return false;
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
    if (!std.mem.eql(u8, getLayer(cl[1..]), "F.CrtYd")) return false;
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
    if (!std.mem.eql(u8, getLayer(cl[1..]), "F.CrtYd")) return false;
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
    if (std.mem.eql(u8, kicad, SHAPE_ROUNDRECT)) return SHAPE_ROUNDRECT;
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
    try std.testing.expect(std.mem.indexOf(u8, output, "(pad 1 smd roundrect") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "(courtyard") != null);
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
