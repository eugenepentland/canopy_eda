const std = @import("std");
const ast = @import("../sexpr/ast.zig");
const parser_mod = @import("../sexpr/parser.zig");
const Node = ast.Node;

/// Error set for the alt-function pinout helpers — covers the parse step,
/// allocator failures, plus the local `InvalidPinout`/`UnsupportedFormat`
/// errors thrown when input doesn't match the expected schema.
pub const AltError = std.mem.Allocator.Error || parser_mod.ParseError ||
    error{ InvalidPinout, UnsupportedFormat, MissingHeader, MissingPositionColumn, MissingFunctionColumn, InvalidXml };

/// One alternate-function row pulled from a CSV or ST open-pin-data XML:
/// `position` is the package pin id, `function` is the signal name to add
/// as `(alt …)`, and `etype` is the optional electrical type (e.g. `io`).
pub const AltEntry = struct {
    position: []const u8,
    function: []const u8,
    etype: []const u8,
};

/// Merge alternate-function rows (parsed from CSV) into a pinout .sexp source and return the
/// rewritten text. Rows are grouped by `position`; existing `(alt …)` children on those pins
/// are replaced. Pins whose position never appears in the CSV are left untouched.
pub fn mergePinoutWithAlts(
    allocator: std.mem.Allocator,
    pinout_source: []const u8,
    alts: []const AltEntry,
) AltError![]const u8 {
    const nodes = try parser_mod.parse(allocator, pinout_source);
    defer parser_mod.freeNodes(allocator, nodes);
    if (nodes.len == 0) return error.InvalidPinout;
    const top = nodes[0].asList() orelse return error.InvalidPinout;
    if (top.len < 2) return error.InvalidPinout;
    const head = top[0].asAtom() orelse return error.InvalidPinout;
    if (!std.mem.eql(u8, head, "pinout")) return error.InvalidPinout;
    const pinout_name = top[1].asString() orelse (top[1].asAtom() orelse return error.InvalidPinout);

    // Group alt entries by position for O(n) lookup.
    var by_position: std.StringHashMapUnmanaged(std.ArrayListUnmanaged(AltEntry)) = .empty;
    defer {
        var it = by_position.valueIterator();
        while (it.next()) |list| list.deinit(allocator);
        by_position.deinit(allocator);
    }
    for (alts) |e| {
        const gop = try by_position.getOrPut(allocator, e.position);
        if (!gop.found_existing) gop.value_ptr.* = .empty;
        try gop.value_ptr.append(allocator, e);
    }

    var buf: std.ArrayListUnmanaged(u8) = .empty;
    const w = buf.writer(allocator);
    try w.writeAll(";; Auto-generated pinout — DO NOT EDIT\n");
    try w.writeAll(";; Source of truth for pin ID → function name mapping\n");
    try w.print("(pinout \"{s}\"\n", .{pinout_name});

    for (top[2..]) |child| {
        const cl = child.asList() orelse continue;
        if (cl.len < 3) continue;
        const ch = cl[0].asAtom() orelse continue;
        if (!std.mem.eql(u8, ch, "pin")) continue;
        const pin_id = cl[1].asAtom() orelse cl[1].asString() orelse continue;
        const primary = cl[2].asString() orelse (cl[2].asAtom() orelse continue);

        const new_alts_opt = by_position.get(pin_id);
        if (new_alts_opt) |list| {
            try w.print("  (pin {s} \"{s}\"\n", .{ pin_id, primary });
            for (list.items) |e| {
                if (e.etype.len > 0) {
                    try w.print("    (alt \"{s}\" {s})\n", .{ e.function, e.etype });
                } else {
                    try w.print("    (alt \"{s}\")\n", .{e.function});
                }
            }
            try w.writeAll("  )\n");
        } else {
            // Preserve any existing alts verbatim.
            try w.print("  (pin {s} \"{s}\"", .{ pin_id, primary });
            if (cl.len > 3) {
                try w.writeByte('\n');
                for (cl[3..]) |alt_node| {
                    const al = alt_node.asList() orelse continue;
                    if (al.len < 2) continue;
                    const hd = al[0].asAtom() orelse continue;
                    if (!std.mem.eql(u8, hd, "alt")) continue;
                    const alt_name = al[1].asString() orelse (al[1].asAtom() orelse continue);
                    if (al.len >= 3) {
                        const etype = al[2].asAtom() orelse al[2].asString() orelse "";
                        if (etype.len > 0) {
                            try w.print("    (alt \"{s}\" {s})\n", .{ alt_name, etype });
                            continue;
                        }
                    }
                    try w.print("    (alt \"{s}\")\n", .{alt_name});
                }
                try w.writeAll("  )\n");
            } else {
                try w.writeAll(")\n");
            }
        }
    }
    try w.writeAll(")\n");
    return buf.toOwnedSlice(allocator);
}

/// Parse a long-format CSV: header row names the columns; required columns are
/// `position` and `function`. Optional: `etype`. Whitespace in cells is trimmed.
pub fn parseAltCsv(allocator: std.mem.Allocator, source: []const u8) AltError![]AltEntry {
    var rows: std.ArrayListUnmanaged(AltEntry) = .empty;

    var line_iter = std.mem.splitScalar(u8, source, '\n');
    const header_line = line_iter.next() orelse return rows.toOwnedSlice(allocator);

    var pos_idx: ?usize = null;
    var fn_idx: ?usize = null;
    var ety_idx: ?usize = null;
    {
        var col: usize = 0;
        var cell_iter = std.mem.splitScalar(u8, trimCr(header_line), ',');
        while (cell_iter.next()) |raw| : (col += 1) {
            const cell = std.mem.trim(u8, raw, " \t\"");
            if (std.ascii.eqlIgnoreCase(cell, "position")) pos_idx = col;
            if (std.ascii.eqlIgnoreCase(cell, "function")) fn_idx = col;
            if (std.ascii.eqlIgnoreCase(cell, "etype")) ety_idx = col;
        }
    }
    const p_idx = pos_idx orelse return error.MissingPositionColumn;
    const f_idx = fn_idx orelse return error.MissingFunctionColumn;

    while (line_iter.next()) |raw_line| {
        const line = trimCr(raw_line);
        if (line.len == 0) continue;
        var cells: std.ArrayListUnmanaged([]const u8) = .empty;
        defer cells.deinit(allocator);
        var cell_iter = std.mem.splitScalar(u8, line, ',');
        while (cell_iter.next()) |raw_cell| {
            try cells.append(allocator, std.mem.trim(u8, raw_cell, " \t\""));
        }
        if (cells.items.len <= @max(p_idx, f_idx)) continue;
        const pos = cells.items[p_idx];
        const fnm = cells.items[f_idx];
        if (pos.len == 0 or fnm.len == 0) continue;
        const ety = if (ety_idx) |ei| (if (ei < cells.items.len) cells.items[ei] else "") else "";
        try rows.append(allocator, .{
            .position = try allocator.dupe(u8, pos),
            .function = try allocator.dupe(u8, fnm),
            .etype = try allocator.dupe(u8, ety),
        });
    }
    return rows.toOwnedSlice(allocator);
}

fn trimCr(s: []const u8) []const u8 {
    if (s.len > 0 and s[s.len - 1] == '\r') return s[0 .. s.len - 1];
    return s;
}

/// Dispatch by content: an XML declaration or `<` as the first non-whitespace byte
/// routes through `parseAltXml`; anything else is treated as CSV.
pub fn parseAltSource(allocator: std.mem.Allocator, source: []const u8) AltError![]AltEntry {
    const trimmed = std.mem.trimLeft(u8, source, " \t\r\n");
    if (trimmed.len > 0 and trimmed[0] == '<') return parseAltXml(allocator, source);
    return parseAltCsv(allocator, source);
}

/// Parse ST's open-pin-data MCU XML (e.g. STM32N657L0HxQ.xml). For every I/O pin we
/// emit one row per `<Signal Name="…"/>`, skipping the implicit `GPIO` signal (that's
/// the primary, already in the pinout). Power / reset / self-closing pins are ignored.
pub fn parseAltXml(allocator: std.mem.Allocator, source: []const u8) AltError![]AltEntry {
    var rows: std.ArrayListUnmanaged(AltEntry) = .empty;

    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, source, cursor, "<Pin ")) |pin_start| {
        const tag_end = std.mem.indexOfScalarPos(u8, source, pin_start, '>') orelse break;
        const pin_tag = source[pin_start .. tag_end + 1];
        cursor = tag_end + 1;

        // Self-closing <Pin … /> (power pins) carry no signals.
        if (pin_tag.len >= 2 and pin_tag[pin_tag.len - 2] == '/') continue;

        const position = extractXmlAttr(pin_tag, "Position") orelse continue;
        const pin_type = extractXmlAttr(pin_tag, "Type") orelse "";

        // Only I/O pins have alternate functions worth validating.
        if (!std.ascii.eqlIgnoreCase(pin_type, "I/O") and
            !std.ascii.eqlIgnoreCase(pin_type, "MonoIO")) continue;

        const close_idx = std.mem.indexOfPos(u8, source, cursor, "</Pin>") orelse break;
        const body = source[cursor..close_idx];
        cursor = close_idx + "</Pin>".len;

        var sig_cursor: usize = 0;
        while (std.mem.indexOfPos(u8, body, sig_cursor, "<Signal")) |sig_start| {
            const sig_tag_end = std.mem.indexOfScalarPos(u8, body, sig_start, '>') orelse break;
            const sig_tag = body[sig_start .. sig_tag_end + 1];
            sig_cursor = sig_tag_end + 1;

            const sig_name = extractXmlAttr(sig_tag, "Name") orelse continue;
            if (std.mem.eql(u8, sig_name, "GPIO")) continue;

            try rows.append(allocator, .{
                .position = try allocator.dupe(u8, position),
                .function = try allocator.dupe(u8, sig_name),
                .etype = try allocator.dupe(u8, "io"),
            });
        }
    }
    return rows.toOwnedSlice(allocator);
}

/// Return the value of `name="…"` inside a single XML tag. Matches only when
/// the attribute name is preceded by whitespace, so `InstanceName` won't
/// accidentally match a query for `Name`.
fn extractXmlAttr(tag: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, tag, i, name)) |idx| {
        const after = idx + name.len;
        const word_boundary = idx > 0 and (tag[idx - 1] == ' ' or tag[idx - 1] == '\t' or tag[idx - 1] == '\n');
        if (!word_boundary or after >= tag.len or tag[after] != '=') {
            i = idx + 1;
            continue;
        }
        if (after + 1 >= tag.len or tag[after + 1] != '"') {
            i = after + 1;
            continue;
        }
        const val_start = after + 2;
        const val_end = std.mem.indexOfScalarPos(u8, tag, val_start, '"') orelse return null;
        return tag[val_start..val_end];
    }
    return null;
}

// spec: convert/alt-functions - Parses a long-format CSV with position/function/etype columns
test "parseAltCsv extracts rows" {
    const alloc = std.testing.allocator;
    const csv =
        \\position,function,etype
        \\C10,SPI3_SCK,io
        \\C10,USART3_TX,output
        \\B12,UART4_RX,input
    ;
    const rows = try parseAltCsv(alloc, csv);
    defer {
        for (rows) |r| {
            alloc.free(r.position);
            alloc.free(r.function);
            alloc.free(r.etype);
        }
        alloc.free(rows);
    }
    try std.testing.expectEqual(@as(usize, 3), rows.len);
    try std.testing.expectEqualStrings("C10", rows[0].position);
    try std.testing.expectEqualStrings("SPI3_SCK", rows[0].function);
    try std.testing.expectEqualStrings("io", rows[0].etype);
    try std.testing.expectEqualStrings("B12", rows[2].position);
}

test "parseAltCsv skips a row with too few columns" {
    const alloc = std.testing.allocator;
    // `function` is column 1; a single-cell data row can't index it, so the
    // `len <= max(p_idx, f_idx)` guard drops it. A `<` flip lets it through and
    // reads cells.items[1] out of bounds.
    const csv =
        \\position,function
        \\PA0
    ;
    const rows = try parseAltCsv(alloc, csv);
    defer alloc.free(rows);
    try std.testing.expectEqual(@as(usize, 0), rows.len);
}

// spec: convert/alt-functions - Parses ST open-pin-data XML into alt-function rows
test "parseAltXml extracts signals" {
    const alloc = std.testing.allocator;
    const xml =
        \\<?xml version="1.0" encoding="UTF-8"?>
        \\<Mcu xmlns="http://dummy.com">
        \\    <Pin Name="PA4" Position="W17" Type="I/O">
        \\        <Signal Name="SPI5_MOSI"/>
        \\        <Signal Name="USART6_RX"/>
        \\        <Signal IOModes="Input,Output,Analog,EXTI" Name="GPIO"/>
        \\    </Pin>
        \\    <Pin Name="VSS" Position="W19" Type="Power"/>
        \\    <Pin Name="NRST" Position="A1" Type="Reset">
        \\        <Signal Name="NRST"/>
        \\    </Pin>
        \\</Mcu>
    ;
    const rows = try parseAltXml(alloc, xml);
    defer {
        for (rows) |r| {
            alloc.free(r.position);
            alloc.free(r.function);
            alloc.free(r.etype);
        }
        alloc.free(rows);
    }
    // Only the two alt signals on PA4 — GPIO is filtered, Power/Reset pins skipped.
    try std.testing.expectEqual(@as(usize, 2), rows.len);
    try std.testing.expectEqualStrings("W17", rows[0].position);
    try std.testing.expectEqualStrings("SPI5_MOSI", rows[0].function);
    try std.testing.expectEqualStrings("io", rows[0].etype);
    try std.testing.expectEqualStrings("USART6_RX", rows[1].function);
}

// spec: convert/alt-functions - Merges CSV alternate-function rows into an existing pinout file
test "mergePinoutWithAlts rewrites pins" {
    const alloc = std.testing.allocator;
    const pinout =
        \\(pinout "test"
        \\  (pin C10 "PC10")
        \\  (pin B12 "PD0")
        \\  (pin A1 "VDD")
        \\)
    ;
    const alts = [_]AltEntry{
        .{ .position = "C10", .function = "SPI3_SCK", .etype = "io" },
        .{ .position = "C10", .function = "USART3_TX", .etype = "output" },
        .{ .position = "B12", .function = "UART4_RX", .etype = "input" },
    };
    const out = try mergePinoutWithAlts(alloc, pinout, &alts);
    defer alloc.free(out);
    try std.testing.expect(std.mem.indexOf(u8, out, "(alt \"SPI3_SCK\" io)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(alt \"USART3_TX\" output)") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "(alt \"UART4_RX\" input)") != null);
    // A1 had no alts in CSV and none originally — stays as a one-liner.
    try std.testing.expect(std.mem.indexOf(u8, out, "(pin A1 \"VDD\")") != null);
    // Round-trip: result must parse as a valid pinout.
    const reparsed = try parser_mod.parse(alloc, out);
    defer parser_mod.freeNodes(alloc, reparsed);
    try std.testing.expect(reparsed.len == 1);
}
