const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const Node = ast.Node;

/// One pin extracted from a `.kicad_sym` symbol: pad `number`, display
/// `name`, KiCad electrical type, and the `(at x y angle)` placement used
/// to classify which side of the symbol body the pin sits on.
pub const PinInfo = struct {
    number: []const u8,
    name: []const u8,
    electrical_type: []const u8,
    x: f64,
    y: f64,
    angle: f64,
};

/// One pad extracted from a `.kicad_mod` footprint: pad `id`, type, shape,
/// and the geometry (centre `x`/`y` plus `sx`/`sy` size) used when pairing
/// a footprint with its companion symbol during package conversion.
pub const PadInfo = struct {
    id: []const u8,
    pad_type: []const u8,
    shape: []const u8,
    x: f64,
    y: f64,
    sx: f64,
    sy: f64,
};

const Side = enum { left, right, top, bottom };

/// Render a parsed KiCad symbol tree as a project `(symbol …)` form:
/// extracts the description, gathers pins (recursing into KiCad's per-unit
/// sub-symbols), classifies them by side using the rectangle-derived body
/// bbox, and writes ordered pin groups followed by a body label.
pub fn emitSymbol(allocator: std.mem.Allocator, w: anytype, sym_children: []const Node, sym_name: []const u8) !void {
    // Extract description from properties
    var description: []const u8 = "";
    for (sym_children[2..]) |child| {
        if (child.isForm("property")) {
            const cl = child.asList().?;
            if (cl.len >= 3) {
                const key = cl[1].asAtom() orelse cl[1].asString() orelse continue;
                const val = cl[2].asAtom() orelse cl[2].asString() orelse continue;
                if (std.mem.eql(u8, key, "Description") or std.mem.eql(u8, key, "ki_description")) {
                    description = val;
                }
            }
        }
    }

    // Collect all pins from main symbol and sub-symbols
    var pins: std.ArrayListUnmanaged(PinInfo) = .empty;
    defer pins.deinit(allocator);

    try collectPins(sym_children[2..], &pins, allocator);

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

/// Write a sorted list of pins as `(pin NUM "NAME" etype side order)` lines,
/// numbering the `order` field 1..N so the schematic renderer lays them out
/// in the exact sequence given.
pub fn emitPinGroup(w: anytype, pin_list: []const PinInfo, side: []const u8) !void {
    for (pin_list, 0..) |pin, i| {
        const order = i + 1;
        const etype = mapElectricalType(pin.electrical_type);
        try w.print("  (pin {s} \"{s}\" {s} {s} {d})\n", .{
            pin.number, pin.name, etype, side, order,
        });
    }
}

/// Walk a KiCad symbol's child nodes, appending each `(pin …)` and recursing
/// into any nested `(symbol …)` sub-units (e.g. `R_0_1`, `R_1_1`) so a
/// multi-unit symbol contributes all of its pins to a single flat list.
pub fn collectPins(children: []const Node, pins: *std.ArrayListUnmanaged(PinInfo), allocator: std.mem.Allocator) !void {
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
                try collectPins(cl[2..], pins, allocator);
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

/// Expand the `x1`/`y1`/`x2`/`y2` bounding box to enclose every
/// `(rectangle …)` declared on the symbol (and any KiCad sub-units), so
/// `emitSymbol` can decide which side of the body each pin sits on.
pub fn computeBodyBBox(children: []const Node, x1: *f64, y1: *f64, x2: *f64, y2: *f64) void {
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

fn classifyPinSide(pin: PinInfo, bx1: f64, by1: f64, bx2: f64, by2: f64) Side {
    if (pin.angle == 0) return .left;
    if (pin.angle == 180) return .right;
    if (pin.angle == 90) return .bottom;
    if (pin.angle == 270) return .top;

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

/// Translate KiCad pin electrical-type tokens (`input`, `power_in`,
/// `bidirectional`, …) into the project's compact spelling
/// (`input`, `power-in`, `bidi`, …). Unknown values fall back to `passive`.
pub fn mapElectricalType(kicad: []const u8) []const u8 {
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
