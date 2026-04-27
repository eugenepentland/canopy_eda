const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const parser_mod = @import("../sexpr/parser.zig");
const printer_mod = @import("../sexpr/printer.zig");
const Node = ast.Node;
const Span = ast.Span;

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

    // Extract silkscreen lines and circles
    try emitSilkscreen(w, children[2..]);

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
    }

    // Apply pad rotation: 90° or 270° swaps width and height
    const rot_mod = @mod(rotation, 360.0);
    const is_rotated = (rot_mod > 45.0 and rot_mod < 135.0) or (rot_mod > 225.0 and rot_mod < 315.0);
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
    try w.writeAll(")\n");
}

fn emitCourtyard(w: anytype, children: []const Node) !void {
    // Look for fp_rect on F.CrtYd layer
    for (children) |child| {
        if (child.isForm("fp_rect")) {
            const cl = child.asList() orelse continue;
            var layer: []const u8 = "";
            var x1: f64 = 0;
            var y1: f64 = 0;
            var x2: f64 = 0;
            var y2: f64 = 0;

            for (cl[1..]) |sub| {
                if (sub.isForm("layer")) {
                    const sl = sub.asList().?;
                    if (sl.len >= 2) layer = sl[1].asAtom() orelse sl[1].asString() orelse "";
                }
                if (sub.isForm("start")) {
                    const sl = sub.asList().?;
                    if (sl.len >= 3) {
                        x1 = sl[1].asNumber() orelse 0;
                        y1 = sl[2].asNumber() orelse 0;
                    }
                }
                if (sub.isForm("end")) {
                    const sl = sub.asList().?;
                    if (sl.len >= 3) {
                        x2 = sl[1].asNumber() orelse 0;
                        y2 = sl[2].asNumber() orelse 0;
                    }
                }
            }

            if (std.mem.eql(u8, layer, "F.CrtYd")) {
                try w.print("  (courtyard (rect {d:.2} {d:.2} {d:.2} {d:.2}))\n", .{ x1, y1, x2, y2 });
                return;
            }
        }
    }

    // Fallback: derive courtyard bounding box from fp_line on F.CrtYd
    var min_x: f64 = std.math.inf(f64);
    var min_y: f64 = std.math.inf(f64);
    var max_x: f64 = -std.math.inf(f64);
    var max_y: f64 = -std.math.inf(f64);
    var found = false;

    for (children) |child| {
        if (child.isForm("fp_line")) {
            const cl = child.asList() orelse continue;
            const layer = getLayer(cl[1..]);
            if (std.mem.eql(u8, layer, "F.CrtYd")) {
                found = true;
                for (cl[1..]) |sub| {
                    if (sub.isForm("start") or sub.isForm("end")) {
                        const sl = sub.asList().?;
                        if (sl.len >= 3) {
                            const px = sl[1].asNumber() orelse continue;
                            const py = sl[2].asNumber() orelse continue;
                            if (px < min_x) min_x = px;
                            if (py < min_y) min_y = py;
                            if (px > max_x) max_x = px;
                            if (py > max_y) max_y = py;
                        }
                    }
                }
            }
        }
    }

    if (found) {
        try w.print("  (courtyard (rect {d:.3} {d:.3} {d:.3} {d:.3}))\n", .{ min_x, min_y, max_x, max_y });
    }
}

fn emitSilkscreen(w: anytype, children: []const Node) !void {
    var has_silk = false;

    for (children) |child| {
        if (child.isForm("fp_line")) {
            const cl = child.asList() orelse continue;
            const layer = getLayer(cl[1..]);
            if (std.mem.eql(u8, layer, "F.SilkS")) {
                if (!has_silk) {
                    try w.writeAll("  (silkscreen\n");
                    has_silk = true;
                }
                var sx: f64 = 0;
                var sy: f64 = 0;
                var ex: f64 = 0;
                var ey: f64 = 0;
                for (cl[1..]) |sub| {
                    if (sub.isForm("start")) {
                        const sl = sub.asList().?;
                        if (sl.len >= 3) {
                            sx = sl[1].asNumber() orelse 0;
                            sy = sl[2].asNumber() orelse 0;
                        }
                    }
                    if (sub.isForm("end")) {
                        const sl = sub.asList().?;
                        if (sl.len >= 3) {
                            ex = sl[1].asNumber() orelse 0;
                            ey = sl[2].asNumber() orelse 0;
                        }
                    }
                }
                try w.print("    (line ({d:.2} {d:.2}) ({d:.2} {d:.2}))\n", .{ sx, sy, ex, ey });
            }
        }
        if (child.isForm("fp_circle")) {
            const cl = child.asList() orelse continue;
            const layer = getLayer(cl[1..]);
            if (std.mem.eql(u8, layer, "F.SilkS")) {
                if (!has_silk) {
                    try w.writeAll("  (silkscreen\n");
                    has_silk = true;
                }
                var cx: f64 = 0;
                var cy: f64 = 0;
                var ex: f64 = 0;
                var ey: f64 = 0;
                for (cl[1..]) |sub| {
                    if (sub.isForm("center")) {
                        const sl = sub.asList().?;
                        if (sl.len >= 3) {
                            cx = sl[1].asNumber() orelse 0;
                            cy = sl[2].asNumber() orelse 0;
                        }
                    }
                    if (sub.isForm("end")) {
                        const sl = sub.asList().?;
                        if (sl.len >= 3) {
                            ex = sl[1].asNumber() orelse 0;
                            ey = sl[2].asNumber() orelse 0;
                        }
                    }
                }
                const dx = ex - cx;
                const dy = ey - cy;
                const radius = @sqrt(dx * dx + dy * dy);
                try w.print("    (circle ({d:.2} {d:.2}) {d:.2})\n", .{ cx, cy, radius });
            }
        }
    }
    if (has_silk) {
        try w.writeAll("  )\n");
    }
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
    if (std.mem.eql(u8, kicad, "roundrect")) return "roundrect";
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
