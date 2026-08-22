//! JSON serialization for fixed, visible PCB keepout geometry. Kept separate
//! from the already-large PCB page handler so geometry policy stays reusable
//! by other views without growing the HTTP module.

const std = @import("std");
const optimizer = @import("../placement/optimizer.zig");
const perimeter_fence = @import("../placement/perimeter_fence.zig");

const point_fmt = "[{d},{d}]";

fn writeScriptJsonString(w: *std.Io.Writer, value: []const u8) std.Io.Writer.Error!void {
    try w.writeByte('"');
    var i: usize = 0;
    while (i < value.len) : (i += 1) {
        const c = value[i];
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            '<' => try w.writeAll("\\u003c"),
            0xE2 => {
                if (i + 2 < value.len and value[i + 1] == 0x80 and
                    (value[i + 2] == 0xA8 or value[i + 2] == 0xA9))
                {
                    try w.writeAll(if (value[i + 2] == 0xA8) "\\u2028" else "\\u2029");
                    i += 2;
                } else try w.writeByte(c);
            },
            else => if (c < 0x20) try w.print("\\u{x:0>4}", .{c}) else try w.writeByte(c),
        }
    }
    try w.writeByte('"');
}

/// Emit `"layers":["F.Cu","In1.Cu",…]` — every copper layer of `placement`'s
/// stack, named off the shared layer table. A keepout's layer key is ALWAYS an
/// array of KiCad layer names (the one shape every blob geometry uses); the
/// viewer prints "All layers" when the list covers the whole stack rather than
/// reading a magic `"all"` string that only this one producer emitted.
fn writeLayerNames(w: *std.Io.Writer, placement: optimizer.Placement) std.Io.Writer.Error!void {
    const table = placement.rules.layerTable();
    try w.writeAll("\"layers\":[");
    for (table.rows(), 0..) |*row, i| {
        if (i > 0) try w.writeByte(',');
        try writeScriptJsonString(w, row.kicadName());
    }
    try w.writeAll("],");
}

/// Emit the `keepouts` property for the PCB page blob. Net-class keepouts are
/// derived from live copper client-side; fixed regions carry exact polygons.
pub fn write(
    w: *std.Io.Writer,
    alloc: std.mem.Allocator,
    placement: optimizer.Placement,
) (std.mem.Allocator.Error || std.Io.Writer.Error)!void {
    try w.writeAll("\"keepouts\":[");
    const limit = perimeter_fence.keepoutLimit(placement);
    if (limit > 0) {
        const outer = perimeter_fence.outlinePoints(alloc, placement) catch &.{};
        defer if (placement.board_poly == null and outer.len > 0) alloc.free(outer);
        const inner = perimeter_fence.insetOutline(alloc, placement, limit) catch &.{};
        defer if (inner.len > 0) alloc.free(inner);
        if (outer.len >= 3 and inner.len >= 3) {
            const fence = placement.rules.perimeter_fence;
            const keepout = fence.keepout;
            try w.writeAll("{\"kind\":\"perimeter\",\"name\":\"Perimeter fence\",");
            try writeLayerNames(w, placement);
            try w.print(
                "\"clearance\":{d},\"edge_inset\":{d},\"edge_offset\":{d}," ++
                    "\"via_dia\":{d},\"via_drill\":{d},\"blocks\":[",
                .{ keepout.clearance, limit, fence.edge_offset, fence.via_dia, fence.via_drill },
            );
            var wrote = false;
            if (keepout.blocks.components) {
                try w.writeAll("\"components\"");
                wrote = true;
            }
            if (keepout.blocks.tracks) {
                if (wrote) try w.writeByte(',');
                try w.writeAll("\"tracks\"");
                wrote = true;
            }
            if (keepout.blocks.vias) {
                if (wrote) try w.writeByte(',');
                try w.writeAll("\"vias\"");
            }
            try w.writeAll("],\"allow_nets\":[");
            for (keepout.allow_nets, 0..) |net, i| {
                if (i > 0) try w.writeByte(',');
                try writeScriptJsonString(w, net);
            }
            try w.writeAll("],\"outer\":[");
            for (outer, 0..) |point, i| {
                if (i > 0) try w.writeByte(',');
                try w.print(point_fmt, .{ point[0], point[1] });
            }
            try w.writeAll("],\"inner\":[");
            for (inner, 0..) |point, i| {
                if (i > 0) try w.writeByte(',');
                try w.print(point_fmt, .{ point[0], point[1] });
            }
            try w.writeAll("]}");
        }
    }
    try w.writeAll("],");
}

// spec: Web Server - PCB blobs carry fixed perimeter keepout geometry together with its clearance, blocked feature families, and allowed nets
test "PCB blob carries typed fixed perimeter keepouts" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const alloc = arena_state.allocator();
    const placement = optimizer.Placement{
        .parts = &.{},
        .links = &.{},
        .loops = &.{},
        .stubs = &.{},
        .instances = &.{},
        .nets = &.{},
        .score = .{ .hpwl_mm = 0, .loop_mm = 0, .loop_caps = 0 },
        .minx = 0,
        .miny = 0,
        .maxx = 10,
        .maxy = 10,
        .generated = true,
        .board_rect = .{ .minx = 0, .miny = 0, .w = 10, .h = 10 },
        .rules = .{ .perimeter_fence = .{
            .via_dia = 0.4,
            .via_drill = 0.2,
            .spacing = 1,
            .edge_offset = 0.5,
            .keepout = .{
                .clearance = 0.3,
                .blocks = .{ .components = true, .tracks = true, .vias = true },
                .allow_nets = &.{"GND"},
            },
        } },
    };
    var aw: std.Io.Writer.Allocating = .init(alloc);
    try write(&aw.writer, alloc, placement);
    const json = aw.written();
    try std.testing.expect(std.mem.indexOf(u8, json, "\"name\":\"Perimeter fence\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"layers\":[\"F.Cu\",\"In1.Cu\",\"In2.Cu\",\"B.Cu\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"edge_inset\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"blocks\":[\"components\",\"tracks\",\"vias\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"allow_nets\":[\"GND\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"outer\":[[0,0],[10,0],[10,10],[0,10]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"inner\":[[1,1],[9,1],[9,9],[1,9]]") != null);
}
