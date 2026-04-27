const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const parser_mod = @import("../sexpr/parser.zig");
const helpers = @import("symbol_helpers.zig");
const Node = ast.Node;

const PinInfo = helpers.PinInfo;
const PadInfo = helpers.PadInfo;

// ── Constants ─────────────────────────────────────────────────────
const KICAD_SYMBOL_LIB_FORM = "kicad_symbol_lib";

/// Convert a KiCad .kicad_sym file to .sexp symbol format.
/// If filter is non-null, only convert the symbol matching that name.
pub fn convertSymbol(allocator: std.mem.Allocator, source: []const u8, filter: ?[]const u8) ConvertError![]const u8 {
    const nodes = try parser_mod.parse(allocator, source);
    defer parser_mod.freeNodes(allocator, nodes);

    if (nodes.len == 0) return error.InvalidFormat;
    const root = nodes[0];

    var symbols_to_process: std.ArrayListUnmanaged(Node) = .empty;
    defer symbols_to_process.deinit(allocator);

    if (root.isForm(KICAD_SYMBOL_LIB_FORM)) {
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

        try helpers.emitSymbol(allocator, w, sym_children, sym_name);
    }

    return buf.toOwnedSlice(allocator);
}

/// Generate a pinout file from a KiCad .kicad_sym file.
pub fn generatePinout(allocator: std.mem.Allocator, source: []const u8, filter: ?[]const u8) ConvertError![]const u8 {
    const nodes = try parser_mod.parse(allocator, source);
    defer parser_mod.freeNodes(allocator, nodes);

    if (nodes.len == 0) return error.InvalidFormat;
    const root = nodes[0];

    var symbols_to_process: std.ArrayListUnmanaged(Node) = .empty;
    defer symbols_to_process.deinit(allocator);

    if (root.isForm(KICAD_SYMBOL_LIB_FORM)) {
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
        try helpers.collectPins(sym_children[2..], &pins, allocator);

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

/// Generate a combined package file from a KiCad symbol + footprint.
pub fn generatePackage(allocator: std.mem.Allocator, sym_source: []const u8, fp_source: []const u8, name: []const u8, filter: ?[]const u8) ConvertError![]const u8 {
    // Parse symbol pins
    const sym_nodes = try parser_mod.parse(allocator, sym_source);
    var sym_pins: std.ArrayListUnmanaged(PinInfo) = .empty;
    defer sym_pins.deinit(allocator);

    if (sym_nodes.len > 0) {
        const root = sym_nodes[0];
        var symbols: std.ArrayListUnmanaged(Node) = .empty;
        defer symbols.deinit(allocator);
        if (root.isForm(KICAD_SYMBOL_LIB_FORM)) {
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
            if (filter) |f| {
                if (!std.mem.eql(u8, sn, f)) continue;
            }
            try helpers.collectPins(sc[2..], &sym_pins, allocator);
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
                            if (sl.len >= 3) {
                                px = sl[1].asNumber() orelse 0;
                                py = sl[2].asNumber() orelse 0;
                            }
                        }
                        if (sub.isForm("size")) {
                            const sl = sub.asList().?;
                            if (sl.len >= 3) {
                                psx = sl[1].asNumber() orelse 0;
                                psy = sl[2].asNumber() orelse 0;
                            }
                        }
                    }
                    const footprint_conv = @import("footprint.zig");
                    try pads.append(allocator, .{
                        .id = pad_id,
                        .pad_type = footprint_conv.mapPadType(pad_type_raw),
                        .shape = footprint_conv.mapPadShape(shape_raw),
                        .x = px,
                        .y = py,
                        .sx = psx,
                        .sy = psy,
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

    for (sym_pins.items) |pin| {
        if (pad_map.get(pin.number)) |pad| {
            try w.print("  (pin {s} \"{s}\" (pad {s} {s} (pos {d:.2} {d:.2}) (size {d:.2} {d:.2})))\n", .{
                pin.number,   pin.name,
                pad.pad_type, pad.shape,
                pad.x,        pad.y,
                pad.sx,       pad.sy,
            });
        } else {
            try w.print("  (pin {s} \"{s}\")\n", .{ pin.number, pin.name });
        }
    }

    for (pads.items) |pad| {
        if (!pin_names.contains(pad.id)) {
            try w.print("  (pin {s} \"~\" (pad {s} {s} (pos {d:.2} {d:.2}) (size {d:.2} {d:.2})))\n", .{
                pad.id,
                pad.pad_type,
                pad.shape,
                pad.x,
                pad.y,
                pad.sx,
                pad.sy,
            });
        }
    }

    try w.writeAll(")\n");
    return buf.toOwnedSlice(allocator);
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

// spec: convert/symbol - Converts a KiCad symbol file into S-expression format
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
