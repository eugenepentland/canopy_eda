//! The board's copper stack as the PCB blob's `layer_table` array — the ONE
//! layer view the browser viewer reads.
//!
//! It is a sibling of `board_theme.writeBlobJson` (the palette half of the same
//! blob) and lives beside the other per-concern blob writers in `serve/`
//! (`drc_json`, `pcb_part_json`, `stuck_json`) rather than inside the page
//! module, because what it emits is decided entirely by `board_layers` — the
//! same table the router, the pour fill and the Gerber plan read.

const std = @import("std");
const board_layers = @import("../board_layers.zig");
const optimizer = @import("../placement/optimizer.zig");

/// What the blob prints for a stack row's `"net"`: the net a declared plane
/// pours, or the label the implicit model's inner planes carry ("GND" for the
/// ground plane, whose real membership is every ground-named net). Null on a
/// row nothing pours.
fn planeLabel(row: *const board_layers.Row) ?[]const u8 {
    if (row.kind != .plane) return null;
    return row.plane_net orelse "GND";
}

/// Emit the ONE layer view the browser reads: `layer_table`, one row per
/// PHYSICAL copper layer in top-to-bottom order, straight off the shared layer
/// table — so the viewer paints the stack the router and the Gerbers agree on.
///
/// A row is `{i,l,name,kind,net,c[,implicit]}`: `i` the 1-based physical stack
/// position, `l` the ROUTABLE signal index tracks persist (null on a
/// plane-claimed inner, which can hold no track), `kind` "signal"/"plane",
/// `net` the layer's poured net (null on a signal row), `c` the display hex,
/// and `implicit:true` only on an inner plane the LEGACY model assumed rather
/// than a `(stackup …)` declaring it. The routable-only list the viewer also
/// needs is derived client-side by filtering rows with a numeric `l` — one
/// wire shape, no chance of the two disagreeing.
///
/// Emits a trailing comma: this is one member of the blob object.
pub fn write(w: *std.Io.Writer, rules: optimizer.BoardRules) std.Io.Writer.Error!void {
    try writeNames(w);
    const table = rules.layerTable();
    try w.writeAll("\"layer_table\":[");
    for (table.rows()) |*row| {
        const index = row.stack.int();
        if (index > 1) try w.writeByte(',');
        try w.print("{{\"i\":{d},\"l\":", .{index});
        if (row.signal) |layer| try w.print("{d}", .{layer.int()}) else try w.writeAll("null");
        try w.print(",\"name\":\"{s}\",\"kind\":\"{s}\",\"net\":", .{ row.kicadName(), @tagName(row.kind) });
        if (planeLabel(row)) |net| try writeJsonStr(w, net) else try w.writeAll("null");
        try w.print(",\"c\":\"{s}\"", .{row.color()});
        if (!table.stack.declared and index > 1 and index < table.stackCount()) try w.writeAll(",\"implicit\":true");
        try w.writeByte('}');
    }
    try w.writeAll("],");
}

/// The blob's `layer_names` member: the FIXED layer spellings the viewer needs
/// and the copper table cannot carry — the two faces its side labels print, and
/// the technical/document layers its Appearance rows key on. Straight out of
/// `board_layers`, so the browser never spells a KiCad layer for itself.
///
/// Emitted by `write` immediately before `layer_table`, and only there: the two
/// members are one wire fact and a blob carrying the table without the names
/// would leave the viewer's fallback rows nameless.
///
/// Emits a trailing comma: this is one member of the blob object.
fn writeNames(w: *std.Io.Writer) std.Io.Writer.Error!void {
    try w.print(
        "\"layer_names\":{{\"f_cu\":\"{s}\",\"b_cu\":\"{s}\",\"f_silks\":\"{s}\",\"b_silks\":\"{s}\"," ++
            "\"edge_cuts\":\"{s}\",\"f_crtyd\":\"{s}\",\"b_crtyd\":\"{s}\"}},",
        .{
            board_layers.f_cu,    board_layers.b_cu,      board_layers.f_silks,
            board_layers.b_silks, board_layers.edge_cuts, board_layers.f_crtyd,
            board_layers.b_crtyd,
        },
    );
}

/// Minimal JSON string escaping for a net name (quotes and backslashes).
fn writeJsonStr(w: *std.Io.Writer, s: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    for (s) |c| {
        if (c == '"' or c == '\\') try w.writeByte('\\');
        try w.writeByte(c);
    }
    try w.writeByte('"');
}

// spec: Web Server - PCB blob layer rows take their names, colours and plane nets from the shared layer table
test "PCB blob layer tables are the shared layer table" {
    const planes = [_]optimizer.PlaneAt{ .{ .index = 2, .net = "GND" }, .{ .index = 5, .net = "V_3V3" } };
    const rules = optimizer.BoardRules{
        .plane_nets = &.{ "GND", "V_3V3" },
        .copper_layers = 6,
        .planes = .{ .declared = &planes },
    };
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try write(&aw.writer, rules);
    const json = aw.written();

    // Every physical row is emitted, named and coloured as the table says.
    const table = rules.layerTable();
    try std.testing.expectEqual(@as(usize, 6), std.mem.count(u8, json, "\"i\":"));
    try expectStackRows(json, &table);
    // A plane-claimed inner carries no routable index; the free ones do.
    try std.testing.expect(std.mem.indexOf(u8, json, "\"i\":2,\"l\":null,\"name\":\"In1.Cu\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"plane\",\"net\":\"GND\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"i\":3,\"l\":2,\"name\":\"In2.Cu\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"kind\":\"signal\",\"net\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"implicit\":true") == null);
}

// spec: Web Server - The PCB blob names the fixed copper, silkscreen, outline and courtyard layers beside its layer table, so the browser spells no KiCad layer of its own
test "PCB blob ships the fixed layer names beside its layer table" {
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try write(&aw.writer, .{});
    const json = aw.written();

    // Exact wire shape, and the names are KiCad's file spellings — `F.SilkS`,
    // not the `F.Silkscreen` the UI shows.
    const names = "\"layer_names\":{\"f_cu\":\"F.Cu\",\"b_cu\":\"B.Cu\",\"f_silks\":\"F.SilkS\"," ++
        "\"b_silks\":\"B.SilkS\",\"edge_cuts\":\"Edge.Cuts\",\"f_crtyd\":\"F.CrtYd\",\"b_crtyd\":\"B.CrtYd\"},";
    try std.testing.expect(std.mem.startsWith(u8, json, names));
    // One wire fact: the table never ships without the names in front of it.
    const at_names = std.mem.indexOf(u8, json, "\"layer_names\"").?;
    const at_table = std.mem.indexOf(u8, json, "\"layer_table\"").?;
    try std.testing.expect(at_names < at_table);

    // The viewer keys every layer spelling off this object rather than its own.
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "PCB.layer_names") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "LN.edge_cuts") != null);
}

/// Each table row's stack position, routable index, name, kind and colour
/// appear together in the blob's single layer table.
fn expectStackRows(json: []const u8, table: *const board_layers.LayerTable) !void {
    var buf: [128]u8 = undefined;
    for (table.rows()) |*row| {
        var idx_buf: [8]u8 = undefined;
        const sig = if (row.signal) |s| try std.fmt.bufPrint(&idx_buf, "{d}", .{s.int()}) else "null";
        const want = try std.fmt.bufPrint(&buf, "{{\"i\":{d},\"l\":{s},\"name\":\"{s}\",\"kind\":\"{s}\"", .{
            row.stack.int(), sig, row.kicadName(), @tagName(row.kind),
        });
        try std.testing.expect(std.mem.indexOf(u8, json, want) != null);
        const colour = try std.fmt.bufPrint(&buf, "\"c\":\"{s}\"", .{row.color()});
        try std.testing.expect(std.mem.indexOf(u8, json, colour) != null);
    }
}

// spec: Web Server - the PCB blob ships one layer-table row per physical copper layer and the viewer derives its routable list from it
test "PCB blob ships a single layer table the viewer derives both registries from" {
    const planes = [_]optimizer.PlaneAt{
        .{ .index = 1, .net = "GND" },
        .{ .index = 2, .net = "GND" },
        .{ .index = 4, .net = "GND" },
    };
    const rules = optimizer.BoardRules{ .plane_nets = &.{"GND"}, .copper_layers = 4, .planes = .{ .declared = &planes } };
    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try write(&aw.writer, rules);
    const json = aw.written();
    // ONE array, top→bottom, physical rows only — no second `layers`/`stack`.
    const head = "\"layer_table\":[{\"i\":1,\"l\":0,\"name\":\"F.Cu\",\"kind\":\"plane\",\"net\":\"GND\",\"c\":\"#C83434\"}";
    try std.testing.expect(std.mem.indexOf(u8, json, head) != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"layers\":[") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"stack\":[") == null);
    const plane_layer = "{\"i\":2,\"l\":null,\"name\":\"In1.Cu\",\"kind\":\"plane\",\"net\":\"GND\",\"c\":\"#C2C200\"}";
    const inner_layer = "{\"i\":3,\"l\":2,\"name\":\"In2.Cu\",\"kind\":\"signal\",\"net\":null,\"c\":\"#C200C2\"}";
    try std.testing.expect(std.mem.indexOf(u8, json, plane_layer) != null);
    try std.testing.expect(std.mem.indexOf(u8, json, inner_layer) != null);
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, json, "\"i\":"));

    // An undeclared board marks the two inner planes the legacy model assumed.
    var implicit: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer implicit.deinit();
    try write(&implicit.writer, .{ .planes = .{ .implicit_rail = "V_3V3" } });
    const legacy = implicit.written();
    try std.testing.expectEqual(@as(usize, 2), std.mem.count(u8, legacy, "\"implicit\":true"));
    try std.testing.expect(std.mem.indexOf(u8, legacy, "\"name\":\"In2.Cu\",\"kind\":\"plane\",\"net\":\"V_3V3\"") != null);
    // The viewer derives its routable registry by filtering rows with an `l`.
    const js = @embedFile("assets/pcb_board.js");
    try std.testing.expect(std.mem.indexOf(u8, js, "PCB.layer_table") != null);
    try std.testing.expect(std.mem.indexOf(u8, js, "typeof r.l===\"number\"") != null);
}
