const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const parser_mod = @import("../sexpr/parser.zig");
const Node = ast.Node;
const Span = ast.Span;

const PinInfo = struct {
    number: []const u8,
    name: []const u8,
    electrical_type: []const u8,
    x: f64,
    y: f64,
    angle: f64,
};

/// Convert a KiCad .kicad_sym file to .sexp symbol format.
/// If filter is non-null, only convert the symbol matching that name.
pub fn convertSymbol(allocator: std.mem.Allocator, source: []const u8, filter: ?[]const u8) ![]const u8 {
    const nodes = try parser_mod.parse(allocator, source);
    defer parser_mod.freeNodes(allocator, nodes);

    if (nodes.len == 0) return error.InvalidFormat;
    const root = nodes[0];

    // Could be (kicad_symbol_lib ...) or (symbol ...) directly
    var symbols_to_process: std.ArrayListUnmanaged(Node) = .empty;
    defer symbols_to_process.deinit(allocator);

    if (root.isForm("kicad_symbol_lib")) {
        const children = root.asList().?;
        for (children[1..]) |child| {
            if (child.isForm("symbol")) {
                try symbols_to_process.append(allocator, child);
            }
        }
    } else if (root.isForm("symbol")) {
        try symbols_to_process.append(allocator, root);
    } else {
        return error.InvalidFormat;
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    for (symbols_to_process.items) |sym| {
        const sym_children = sym.asList() orelse continue;
        if (sym_children.len < 2) continue;
        const sym_name = sym_children[1].asAtom() orelse sym_children[1].asString() orelse continue;

        // Apply filter
        if (filter) |f| {
            if (!std.mem.eql(u8, sym_name, f)) continue;
        }

        try emitSymbol(allocator, w, sym_children, sym_name);
    }

    return buf.toOwnedSlice(allocator);
}

/// Generate a pinout file from a KiCad .kicad_sym file.
/// The pinout is the source of truth: pin_id → function_name, auto-generated, never hand-edited.
pub fn generatePinout(allocator: std.mem.Allocator, source: []const u8, filter: ?[]const u8) ![]const u8 {
    const nodes = try parser_mod.parse(allocator, source);
    defer parser_mod.freeNodes(allocator, nodes);

    if (nodes.len == 0) return error.InvalidFormat;
    const root = nodes[0];

    var symbols_to_process: std.ArrayListUnmanaged(Node) = .empty;
    defer symbols_to_process.deinit(allocator);

    if (root.isForm("kicad_symbol_lib")) {
        const children = root.asList().?;
        for (children[1..]) |child| {
            if (child.isForm("symbol")) {
                try symbols_to_process.append(allocator, child);
            }
        }
    } else if (root.isForm("symbol")) {
        try symbols_to_process.append(allocator, root);
    } else {
        return error.InvalidFormat;
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    for (symbols_to_process.items) |sym| {
        const sym_children = sym.asList() orelse continue;
        if (sym_children.len < 2) continue;
        const sym_name = sym_children[1].asAtom() orelse sym_children[1].asString() orelse continue;

        if (filter) |f| {
            if (!std.mem.eql(u8, sym_name, f)) continue;
        }

        var pins: std.ArrayListUnmanaged(PinInfo) = .empty;
        defer pins.deinit(allocator);
        collectPins(sym_children[2..], &pins, allocator) catch {};

        try w.writeAll(";; Auto-generated pinout — DO NOT EDIT\n");
        try w.writeAll(";; Source of truth for pin ID → function name mapping\n");
        try w.print("(pinout \"{s}\"\n", .{sym_name});
        for (pins.items) |pin| {
            try w.print("  (pin {s} \"{s}\")\n", .{ pin.number, pin.name });
        }
        try w.writeAll(")\n");
    }

    return buf.toOwnedSlice(allocator);
}

/// A footprint pad entry for merging with symbol pins.
const PadInfo = struct {
    id: []const u8,
    pad_type: []const u8,
    shape: []const u8,
    x: f64,
    y: f64,
    sx: f64,
    sy: f64,
};

/// Generate a combined package file from a KiCad symbol + footprint.
/// Each pin gets its function name (from symbol) and pad geometry (from footprint).
pub fn generatePackage(allocator: std.mem.Allocator, sym_source: []const u8, fp_source: []const u8, name: []const u8, filter: ?[]const u8) ![]const u8 {
    // Parse symbol pins
    const sym_nodes = try parser_mod.parse(allocator, sym_source);
    var sym_pins: std.ArrayListUnmanaged(PinInfo) = .empty;
    defer sym_pins.deinit(allocator);

    if (sym_nodes.len > 0) {
        const root = sym_nodes[0];
        var symbols: std.ArrayListUnmanaged(Node) = .empty;
        defer symbols.deinit(allocator);
        if (root.isForm("kicad_symbol_lib")) {
            for ((root.asList().?)[1..]) |child| {
                if (child.isForm("symbol")) try symbols.append(allocator, child);
            }
        } else if (root.isForm("symbol")) {
            try symbols.append(allocator, root);
        }
        for (symbols.items) |sym| {
            const sc = sym.asList() orelse continue;
            if (sc.len < 2) continue;
            const sn = sc[1].asAtom() orelse sc[1].asString() orelse continue;
            if (filter) |f| { if (!std.mem.eql(u8, sn, f)) continue; }
            collectPins(sc[2..], &sym_pins, allocator) catch {};
        }
    }

    // Build pin name map: pin_id → function_name
    var pin_names: std.StringHashMapUnmanaged([]const u8) = .empty;
    defer pin_names.deinit(allocator);
    for (sym_pins.items) |pin| {
        try pin_names.put(allocator, pin.number, pin.name);
    }

    // Parse footprint pads
    const fp_nodes = try parser_mod.parse(allocator, fp_source);
    var pads: std.ArrayListUnmanaged(PadInfo) = .empty;
    defer pads.deinit(allocator);

    if (fp_nodes.len > 0) {
        const fp_root = fp_nodes[0];
        if (fp_root.isForm("footprint") or fp_root.isForm("module")) {
            const fc = fp_root.asList().?;
            for (fc[2..]) |child| {
                if (child.isForm("pad")) {
                    const cl = child.asList() orelse continue;
                    if (cl.len < 4) continue;
                    const pad_id = cl[1].asAtom() orelse cl[1].asString() orelse continue;
                    const pad_type_raw = cl[2].asAtom() orelse continue;
                    const shape_raw = cl[3].asAtom() orelse continue;
                    var px: f64 = 0;
                    var py: f64 = 0;
                    var psx: f64 = 0;
                    var psy: f64 = 0;
                    for (cl[4..]) |sub| {
                        if (sub.isForm("at")) {
                            const sl = sub.asList().?;
                            if (sl.len >= 3) { px = sl[1].asNumber() orelse 0; py = sl[2].asNumber() orelse 0; }
                        }
                        if (sub.isForm("size")) {
                            const sl = sub.asList().?;
                            if (sl.len >= 3) { psx = sl[1].asNumber() orelse 0; psy = sl[2].asNumber() orelse 0; }
                        }
                    }
                    const footprint_conv = @import("footprint.zig");
                    try pads.append(allocator, .{
                        .id = pad_id,
                        .pad_type = footprint_conv.mapPadType(pad_type_raw),
                        .shape = footprint_conv.mapPadShape(shape_raw),
                        .x = px, .y = py, .sx = psx, .sy = psy,
                    });
                }
            }
        }
    }

    // Build pad map: pad_id → PadInfo
    var pad_map: std.StringHashMapUnmanaged(PadInfo) = .empty;
    defer pad_map.deinit(allocator);
    for (pads.items) |pad| {
        try pad_map.put(allocator, pad.id, pad);
    }

    // Emit combined package
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    errdefer buf.deinit(allocator);
    const w = buf.writer(allocator);

    try w.writeAll(";; Auto-generated package — DO NOT EDIT\n");
    try w.writeAll(";; Source of truth: pin function names + pad geometry\n");
    try w.print("(package \"{s}\"\n", .{name});

    // Emit all pins from symbol, with pad geometry if available
    for (sym_pins.items) |pin| {
        if (pad_map.get(pin.number)) |pad| {
            try w.print("  (pin {s} \"{s}\" (pad {s} {s} (pos {d:.2} {d:.2}) (size {d:.2} {d:.2})))\n", .{
                pin.number, pin.name,
                pad.pad_type, pad.shape, pad.x, pad.y, pad.sx, pad.sy,
            });
        } else {
            try w.print("  (pin {s} \"{s}\")\n", .{ pin.number, pin.name });
        }
    }

    // Emit any footprint pads that don't have a matching symbol pin (e.g., thermal pads)
    for (pads.items) |pad| {
        if (!pin_names.contains(pad.id)) {
            try w.print("  (pin {s} \"~\" (pad {s} {s} (pos {d:.2} {d:.2}) (size {d:.2} {d:.2})))\n", .{
                pad.id,
                pad.pad_type, pad.shape, pad.x, pad.y, pad.sx, pad.sy,
            });
        }
    }

    try w.writeAll(")\n");
    return buf.toOwnedSlice(allocator);
}

fn emitSymbol(allocator: std.mem.Allocator, w: anytype, sym_children: []const Node, sym_name: []const u8) !void {
    // Extract description from properties
    var description: []const u8 = "";
    var default_footprint: []const u8 = "";
    for (sym_children[2..]) |child| {
        if (child.isForm("property")) {
            const cl = child.asList().?;
            if (cl.len >= 3) {
                const key = cl[1].asAtom() orelse cl[1].asString() orelse continue;
                const val = cl[2].asAtom() orelse cl[2].asString() orelse continue;
                if (std.mem.eql(u8, key, "Description") or std.mem.eql(u8, key, "ki_description")) {
                    description = val;
                }
                if (std.mem.eql(u8, key, "Footprint")) {
                    default_footprint = val;
                }
            }
        }
    }

    // Collect all pins from main symbol and sub-symbols
    var pins: std.ArrayListUnmanaged(PinInfo) = .empty;
    defer pins.deinit(allocator);

    collectPins(sym_children[2..], &pins, allocator) catch {};

    // Compute body bounding box from rectangles
    var body_x1: f64 = -5;
    var body_y1: f64 = -5;
    var body_x2: f64 = 5;
    var body_y2: f64 = 5;
    computeBodyBBox(sym_children[2..], &body_x1, &body_y1, &body_x2, &body_y2);

    // Classify pins by side and assign order
    var left_pins: std.ArrayListUnmanaged(PinInfo) = .empty;
    defer left_pins.deinit(allocator);
    var right_pins: std.ArrayListUnmanaged(PinInfo) = .empty;
    defer right_pins.deinit(allocator);
    var top_pins: std.ArrayListUnmanaged(PinInfo) = .empty;
    defer top_pins.deinit(allocator);
    var bottom_pins: std.ArrayListUnmanaged(PinInfo) = .empty;
    defer bottom_pins.deinit(allocator);

    for (pins.items) |pin| {
        const side = classifyPinSide(pin, body_x1, body_y1, body_x2, body_y2);
        switch (side) {
            .left => try left_pins.append(allocator, pin),
            .right => try right_pins.append(allocator, pin),
            .top => try top_pins.append(allocator, pin),
            .bottom => try bottom_pins.append(allocator, pin),
        }
    }

    // Sort pins by position
    sortPinsByY(&left_pins);
    sortPinsByY(&right_pins);
    sortPinsByX(&top_pins);
    sortPinsByX(&bottom_pins);

    // Emit
    try w.writeAll("(symbol \"");
    try w.writeAll(sym_name);
    try w.writeAll("\"\n");
    if (description.len > 0 and !std.mem.eql(u8, description, "~")) {
        try w.writeAll("  (description \"");
        try w.writeAll(description);
        try w.writeAll("\")\n");
    }
    try w.writeByte('\n');

    try emitPinGroup(w, left_pins.items, "left");
    try emitPinGroup(w, right_pins.items, "right");
    try emitPinGroup(w, top_pins.items, "top");
    try emitPinGroup(w, bottom_pins.items, "bottom");

    try w.writeAll("  (body\n    (label \"");
    try w.writeAll(sym_name);
    try w.writeAll("\")))\n");
}

fn emitPinGroup(w: anytype, pin_list: []const PinInfo, side: []const u8) !void {
    for (pin_list, 0..) |pin, i| {
        const order = i + 1;
        const etype = mapElectricalType(pin.electrical_type);
        try w.print("  (pin {s} \"{s}\" {s} {s} {d})\n", .{
            pin.number, pin.name, etype, side, order,
        });
    }
}

fn collectPins(children: []const Node, pins: *std.ArrayListUnmanaged(PinInfo), allocator: std.mem.Allocator) !void {
    for (children) |child| {
        if (child.isForm("pin")) {
            if (extractPin(child)) |pin| {
                try pins.append(allocator, pin);
            }
        }
        // Recurse into sub-symbols (e.g., "R_0_1", "R_1_1")
        if (child.isForm("symbol")) {
            const cl = child.asList().?;
            if (cl.len > 2) {
                collectPins(cl[2..], pins, allocator) catch {};
            }
        }
    }
}

fn extractPin(node: Node) ?PinInfo {
    const children = node.asList() orelse return null;
    // (pin ELEC_TYPE STYLE (at X Y ANGLE) (length LEN) (name "N") (number "NUM"))
    if (children.len < 3) return null;

    const etype = children[1].asAtom() orelse return null;
    var x: f64 = 0;
    var y: f64 = 0;
    var angle: f64 = 0;
    var name: []const u8 = "~";
    var number: []const u8 = "0";

    for (children[2..]) |child| {
        if (child.isForm("at")) {
            const cl = child.asList().?;
            if (cl.len >= 3) {
                x = cl[1].asNumber() orelse 0;
                y = cl[2].asNumber() orelse 0;
                if (cl.len >= 4) angle = cl[3].asNumber() orelse 0;
            }
        }
        if (child.isForm("name")) {
            const cl = child.asList().?;
            if (cl.len >= 2) name = cl[1].asAtom() orelse cl[1].asString() orelse "~";
        }
        if (child.isForm("number")) {
            const cl = child.asList().?;
            if (cl.len >= 2) number = cl[1].asAtom() orelse cl[1].asString() orelse "0";
        }
    }

    return PinInfo{
        .number = number,
        .name = name,
        .electrical_type = etype,
        .x = x,
        .y = y,
        .angle = angle,
    };
}

fn computeBodyBBox(children: []const Node, x1: *f64, y1: *f64, x2: *f64, y2: *f64) void {
    var found = false;
    for (children) |child| {
        if (child.isForm("rectangle")) {
            const cl = child.asList() orelse continue;
            for (cl[1..]) |sub| {
                if (sub.isForm("start")) {
                    const sl = sub.asList().?;
                    if (sl.len >= 3) {
                        if (!found or (sl[1].asNumber() orelse 0) < x1.*) x1.* = sl[1].asNumber() orelse 0;
                        if (!found or (sl[2].asNumber() orelse 0) < y1.*) y1.* = sl[2].asNumber() orelse 0;
                        found = true;
                    }
                }
                if (sub.isForm("end")) {
                    const sl = sub.asList().?;
                    if (sl.len >= 3) {
                        if (!found or (sl[1].asNumber() orelse 0) > x2.*) x2.* = sl[1].asNumber() orelse 0;
                        if (!found or (sl[2].asNumber() orelse 0) > y2.*) y2.* = sl[2].asNumber() orelse 0;
                        found = true;
                    }
                }
            }
        }
        // Recurse into sub-symbols
        if (child.isForm("symbol")) {
            const cl = child.asList() orelse continue;
            if (cl.len > 2) computeBodyBBox(cl[2..], x1, y1, x2, y2);
        }
    }
}

const Side = enum { left, right, top, bottom };

fn classifyPinSide(pin: PinInfo, bx1: f64, by1: f64, bx2: f64, by2: f64) Side {
    // Use pin angle as primary indicator (KiCad convention)
    // angle 0 = pointing right = pin is on left side of body
    // angle 180 = pointing left = pin is on right side
    // angle 90 = pointing up = pin is on bottom
    // angle 270 = pointing down = pin is on top
    if (pin.angle == 0) return .left;
    if (pin.angle == 180) return .right;
    if (pin.angle == 90) return .bottom;
    if (pin.angle == 270) return .top;

    // Fallback: use position relative to body center
    const cx = (bx1 + bx2) / 2.0;
    const cy = (by1 + by2) / 2.0;
    const dx = @abs(pin.x - cx);
    const dy = @abs(pin.y - cy);

    if (dx > dy) {
        return if (pin.x < cx) .left else .right;
    } else {
        return if (pin.y < cy) .top else .bottom;
    }
}

fn sortPinsByY(list: *std.ArrayListUnmanaged(PinInfo)) void {
    std.mem.sortUnstable(PinInfo, list.items, {}, struct {
        fn lessThan(_: void, a: PinInfo, b: PinInfo) bool {
            return a.y < b.y;
        }
    }.lessThan);
}

fn sortPinsByX(list: *std.ArrayListUnmanaged(PinInfo)) void {
    std.mem.sortUnstable(PinInfo, list.items, {}, struct {
        fn lessThan(_: void, a: PinInfo, b: PinInfo) bool {
            return a.x < b.x;
        }
    }.lessThan);
}

fn mapElectricalType(kicad: []const u8) []const u8 {
    if (std.mem.eql(u8, kicad, "input")) return "input";
    if (std.mem.eql(u8, kicad, "output")) return "output";
    if (std.mem.eql(u8, kicad, "bidirectional")) return "bidi";
    if (std.mem.eql(u8, kicad, "passive")) return "passive";
    if (std.mem.eql(u8, kicad, "power_in")) return "power-in";
    if (std.mem.eql(u8, kicad, "power_out")) return "power-out";
    if (std.mem.eql(u8, kicad, "unconnected")) return "unconnected";
    if (std.mem.eql(u8, kicad, "no_connect")) return "unconnected";
    return "passive";
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

test "convert simple symbol" {
    const alloc = std.testing.allocator;
    const input =
        \\(kicad_symbol_lib (version 20211014) (generator canopy)
        \\  (symbol "R" (pin_numbers hide) (pin_names (offset 0))
        \\    (property "Reference" "R")
        \\    (property "Description" "Resistor")
        \\    (symbol "R_0_1"
        \\      (rectangle (start -1.016 -2.54) (end 1.016 2.54))
        \\    )
        \\    (symbol "R_1_1"
        \\      (pin passive line (at 0 3.81 270) (length 1.27)
        \\        (name "~") (number "1"))
        \\      (pin passive line (at 0 -3.81 90) (length 1.27)
        \\        (name "~") (number "2"))
        \\    )
        \\  )
        \\)
    ;
    const output = try convertSymbol(alloc, input, null);
    defer alloc.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "\"R\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "passive") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "(pin") != null);
}
