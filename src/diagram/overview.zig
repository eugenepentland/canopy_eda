//! The "Overview" view of the diagram engine: every block drawn as a chip,
//! grouped into four macro columns (hub / regulation / peripheral / I/O) by
//! category, with no edges. This is the at-a-glance system silhouette that
//! used to live in `render_system_svg.zig`; folding it into the engine means
//! the schematic page (as the default tab) and the markdown export both draw
//! it from the *one* graph the signal views already share.
//!
//! Chips are the graph's real-block nodes — a node with a non-empty `slug`.
//! Synthesised endpoints (antennas, crystals) carry no slug and are skipped,
//! so the silhouette stays "one chip per functional block", exactly as the
//! old system overview did.

const std = @import("std");
const types = @import("types.zig");
const rb = @import("../render_block_types.zig");

const Allocator = std.mem.Allocator;
const Graph = types.Graph;
const Node = types.Node;
const Writer = std.Io.Writer;

/// Tab metadata for the Overview pseudo-view. It is not a signal class, so it
/// lives outside `Graph.classes`; `render.zig` prepends it as the first tab.
pub const tab_key: []const u8 = "overview";
pub const tab_label: []const u8 = "Overview";
pub const tab_color: []const u8 = "#768390"; // neutral accent, distinct from any class

/// Macro column a chip sits in. Narrower than `rb.Category` so the silhouette
/// reads at a glance: MCU/hub left, regulation next, peripherals middle, I/O
/// right.
pub const Column = enum { hub, regulation, peripheral, io };

/// Map the fine-grained block category to one of the four macro columns.
pub fn columnFor(cat: rb.Category) Column {
    return switch (cat) {
        .mcu => .hub,
        .power => .regulation,
        .connector => .io,
        .memory, .peripheral, .sensor, .analog, .comms, .clock, .protection => .peripheral,
    };
}

fn columnTitle(c: Column) []const u8 {
    return switch (c) {
        .hub => "HUB",
        .regulation => "REGULATION",
        .peripheral => "PERIPHERALS",
        .io => "INPUT / OUTPUT",
    };
}

fn columnColor(c: Column) []const u8 {
    return switch (c) {
        .hub => "#1f6feb",
        .regulation => "#da3633",
        .peripheral => "#2ea043",
        .io => "#d29922",
    };
}

// ── geometry (ported from render_system_svg) ─────────────────────────────
const col_count: usize = 4;
const col_w: f64 = 270;
const col_gap: f64 = 12;
const col_pad: f64 = 10;
const header_h: f64 = 30;
const chip_h: f64 = 50;
const chip_gap: f64 = 6;
const chip_pad_x: f64 = 10;
const svg_pad_y: f64 = 8;
const svg_w: f64 = col_count * col_w + (col_count - 1) * col_gap;

const col_title_y_off: f64 = 20;
const empty_label_y_off: f64 = 32;
const chip_label_y_off: f64 = 18;
const chip_subtitle_y_off: f64 = 36;
const cat_char_width: f64 = 6.2;
const cat_reserve_pad: f64 = 10.0;
const label_char_width: f64 = 6.6;
const label_min_chars: usize = 6;
const sub_char_width: f64 = 5.6;
const sub_min_chars: usize = 8;

/// One placed chip: the graph node it stands for and its top-left corner +
/// width (height is the `chip_h` constant).
pub const Box = struct {
    gid: u32,
    x: f64,
    y: f64,
    w: f64,
    column: u8,
};

/// A laid-out overview: placed chips plus the canvas dimensions. `body_h` is
/// the column-background height (canvas minus the top/bottom pad).
pub const Layout = struct {
    boxes: []const Box,
    width: f64,
    height: f64,
    body_h: f64,
};

/// True when a node is a real on-page block (has a card slug) rather than a
/// synthesised endpoint (antenna / crystal carry an empty slug).
fn isBlock(n: Node) bool {
    return n.slug.len > 0 and !n.is_boundary;
}

/// True when the graph has at least one real-block node — i.e. the Overview
/// tab has content to show.
pub fn present(graph: *const Graph) bool {
    for (graph.nodes) |n| if (isBlock(n)) return true;
    return false;
}

/// Place every real-block node into its macro column and stack the chips.
/// Returns null when the graph has no real-block node.
pub fn layout(arena: Allocator, graph: *const Graph) Allocator.Error!?Layout {
    var cols: [col_count]std.ArrayListUnmanaged(u32) = .{ .empty, .empty, .empty, .empty };
    for (graph.nodes, 0..) |n, i| {
        if (!isBlock(n)) continue;
        const col = columnFor(n.category);
        try cols[@intFromEnum(col)].append(arena, @intCast(i));
    }

    var max_chips: usize = 0;
    var any = false;
    for (cols) |c| {
        if (c.items.len > 0) any = true;
        max_chips = @max(max_chips, c.items.len);
    }
    if (!any) return null;

    const body_h = header_h + @as(f64, @floatFromInt(max_chips)) * (chip_h + chip_gap) + col_pad;

    var boxes: std.ArrayListUnmanaged(Box) = .empty;
    for (cols, 0..) |c, ci| {
        const cx = @as(f64, @floatFromInt(ci)) * (col_w + col_gap) + col_pad;
        var y = svg_pad_y + header_h;
        for (c.items) |gid| {
            try boxes.append(arena, .{ .gid = gid, .x = cx, .y = y, .w = col_w - col_pad * 2, .column = @intCast(ci) });
            y += chip_h + chip_gap;
        }
    }

    return .{
        .boxes = try boxes.toOwnedSlice(arena),
        .width = svg_w,
        .height = body_h + svg_pad_y * 2,
        .body_h = body_h,
    };
}

// ── rendering ────────────────────────────────────────────────────────────

/// Emit the SVG inner-content (column backgrounds + titles + chips) for `lay`.
/// No `<svg>` wrapper — the caller supplies it (a tab panel or the export's
/// standalone block).
pub fn renderInner(arena: Allocator, w: *Writer, graph: *const Graph, lay: Layout) (Allocator.Error || Writer.Error)!void {
    // Column backgrounds + titles, then a "—" placeholder for empty columns.
    var counts = [_]usize{0} ** col_count;
    for (lay.boxes) |b| counts[b.column] += 1;
    var ci: usize = 0;
    while (ci < col_count) : (ci += 1) {
        const column: Column = @enumFromInt(ci);
        const x = @as(f64, @floatFromInt(ci)) * (col_w + col_gap);
        try w.print(
            "<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.0}\" height=\"{d:.1}\" rx=\"8\" class=\"dg-ov-col-bg\"/>",
            .{ x, svg_pad_y, col_w, lay.body_h },
        );
        try w.print(
            "<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"dg-ov-col-title\" fill=\"{s}\">{s}</text>",
            .{ x + col_pad, svg_pad_y + col_title_y_off, columnColor(column), columnTitle(column) },
        );
        if (counts[ci] == 0) {
            try w.print(
                "<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"dg-ov-empty\">\u{2014}</text>",
                .{ x + col_w / 2, svg_pad_y + header_h + empty_label_y_off },
            );
        }
    }
    for (lay.boxes) |b| try writeChip(arena, w, graph.nodes[b.gid], b);
}

fn writeChip(arena: Allocator, w: *Writer, node: Node, b: Box) (Allocator.Error || Writer.Error)!void {
    const color = rb.categoryColor(node.category);
    const has_link = node.slug.len > 0;
    const cat_name = @tagName(node.category);

    if (has_link) try w.print("<a href=\"#sec-{s}\" class=\"dg-ov-chip-link\">", .{node.slug});
    try w.writeAll("<g class=\"dg-ov-chip\">");
    try w.print(
        "<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.1}\" height=\"{d:.0}\" rx=\"5\" class=\"dg-ov-chip-rect\" stroke=\"{s}\"/>",
        .{ b.x, b.y, b.w, chip_h, color },
    );
    // Reserve room on the right for the category tag.
    const cat_reserve: f64 = @as(f64, @floatFromInt(cat_name.len)) * cat_char_width + cat_reserve_pad;
    const label_max: usize = @max(label_min_chars, @as(usize, @intFromFloat((b.w - chip_pad_x * 2 - cat_reserve) / label_char_width)));
    try w.print("<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"dg-ov-chip-label\">", .{ b.x + chip_pad_x, b.y + chip_label_y_off });
    try writeEscaped(w, try truncate(arena, node.label, label_max));
    try w.writeAll("</text>");
    try w.print("<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"dg-ov-chip-cat\" fill=\"{s}\">", .{ b.x + b.w - chip_pad_x, b.y + chip_label_y_off, color });
    try writeEscaped(w, cat_name);
    try w.writeAll("</text>");
    if (node.subtitle.len > 0) {
        const sub_max: usize = @max(sub_min_chars, @as(usize, @intFromFloat((b.w - chip_pad_x * 2) / sub_char_width)));
        try w.print("<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"dg-ov-chip-sub\">", .{ b.x + chip_pad_x, b.y + chip_subtitle_y_off });
        try writeEscaped(w, try truncate(arena, node.subtitle, sub_max));
        try w.writeAll("</text>");
    }
    try w.writeAll("</g>");
    if (has_link) try w.writeAll("</a>");
}

/// Standalone `<svg>` for the markdown export. Returns false when the graph has
/// no real-block node (the caller may emit a synthetic single-chip fallback).
pub fn renderStandaloneSvg(allocator: Allocator, w: *Writer, graph: *const Graph) (Allocator.Error || Writer.Error)!bool {
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lay = (try layout(arena, graph)) orelse return false;
    try w.writeAll("<div class=\"dg-ov-wrap\">");
    try w.print(
        "<svg viewBox=\"0 0 {d:.0} {d:.0}\" class=\"dg-ov-svg\" xmlns=\"http://www.w3.org/2000/svg\">",
        .{ lay.width, lay.height },
    );
    try renderInner(arena, w, graph, lay);
    try w.writeAll("</svg></div>");
    return true;
}

// ── text helpers ─────────────────────────────────────────────────────────

fn truncate(arena: Allocator, s: []const u8, max: usize) Allocator.Error![]const u8 {
    if (s.len <= max) return s;
    if (max <= 1) return s[0..max];
    return std.fmt.allocPrint(arena, "{s}\u{2026}", .{s[0 .. max - 1]});
}

fn writeEscaped(w: *Writer, s: []const u8) Writer.Error!void {
    for (s) |c| switch (c) {
        '<' => try w.writeAll("&lt;"),
        '>' => try w.writeAll("&gt;"),
        '&' => try w.writeAll("&amp;"),
        '"' => try w.writeAll("&quot;"),
        else => try w.writeByte(c),
    };
}

// ── CSS ──────────────────────────────────────────────────────────────────

/// CSS for the overview chips + columns. Embedded into the schematic page
/// (via `DIAGRAM_CSS`) and into the markdown export's `<style>` block.
pub const CSS =
    \\.dg-ov-wrap{margin:12px 0 4px;padding:10px;background:#0d1117;border:1px solid #21262d;border-radius:8px;overflow-x:auto;}
    \\.dg-ov-svg{display:block;width:100%;max-width:1160px;height:auto;}
    \\.dg-ov-col-bg{fill:#12161d;stroke:#21262d;stroke-width:1;}
    \\.dg-ov-col-title{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;font-size:11px;font-weight:700;letter-spacing:0.08em;}
    \\.dg-ov-empty{fill:#6e7681;font-size:14px;text-anchor:middle;font-family:-apple-system,BlinkMacSystemFont,sans-serif;}
    \\.dg-ov-chip-rect{fill:#0d1117;stroke-width:1.5;}
    \\.dg-ov-chip:hover .dg-ov-chip-rect{fill:#161b22;}
    \\.dg-ov-chip-label{fill:#c9d1d9;font-family:-apple-system,BlinkMacSystemFont,sans-serif;font-size:12px;font-weight:600;}
    \\.dg-ov-chip-cat{font-family:"SF Mono","Fira Code",monospace;font-size:10px;text-anchor:end;
    \\text-transform:uppercase;letter-spacing:0.04em;font-weight:700;}
    \\.dg-ov-chip-sub{fill:#8b949e;font-family:-apple-system,BlinkMacSystemFont,sans-serif;font-size:10px;}
    \\.dg-ov-chip-link{cursor:pointer;}
;

// ── tests ────────────────────────────────────────────────────────────────

const testing = std.testing;

fn mkNode(label: []const u8, cat: rb.Category, slug: []const u8) Node {
    return .{ .label = label, .subtitle = "", .category = cat, .slug = slug, .inputs = &.{}, .outputs = &.{} };
}

// spec: diagram/overview - Maps each block category to one of four macro columns
test "columnFor maps categories to macro columns" {
    try testing.expectEqual(Column.hub, columnFor(.mcu));
    try testing.expectEqual(Column.regulation, columnFor(.power));
    try testing.expectEqual(Column.io, columnFor(.connector));
    try testing.expectEqual(Column.peripheral, columnFor(.memory));
    try testing.expectEqual(Column.peripheral, columnFor(.clock));
}

// spec: diagram/overview - Places one chip per real block, grouped by column
test "layout buckets real-block nodes into their columns" {
    var nodes = [_]Node{
        mkNode("STM32", .mcu, "stm32"),
        mkNode("Buck", .power, "buck"),
        mkNode("Flash", .memory, "flash"),
        mkNode("USB-C", .connector, "usbc"),
    };
    var graph = Graph{ .nodes = &nodes, .edges = &.{} };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lay = (try layout(arena.allocator(), &graph)) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 4), lay.boxes.len);
    // Each chip lands in its mapped column.
    var col_of = [_]?u8{ null, null, null, null };
    for (lay.boxes) |b| col_of[b.gid] = b.column;
    try testing.expectEqual(@as(u8, @intFromEnum(Column.hub)), col_of[0].?);
    try testing.expectEqual(@as(u8, @intFromEnum(Column.regulation)), col_of[1].?);
    try testing.expectEqual(@as(u8, @intFromEnum(Column.peripheral)), col_of[2].?);
    try testing.expectEqual(@as(u8, @intFromEnum(Column.io)), col_of[3].?);
}

// spec: diagram/overview - Skips synthesised endpoints (no card slug) from the silhouette
test "layout skips synthesised endpoints without a slug" {
    var antenna = mkNode("TX1 antenna", .analog, "");
    antenna.is_boundary = true;
    var nodes = [_]Node{ mkNode("PA", .analog, "pa"), antenna, mkNode("Crystal", .clock, "") };
    var graph = Graph{ .nodes = &nodes, .edges = &.{} };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const lay = (try layout(arena.allocator(), &graph)) orelse return error.TestUnexpectedResult;
    // Only the real PA block becomes a chip; the antenna and crystal are skipped.
    try testing.expectEqual(@as(usize, 1), lay.boxes.len);
    try testing.expectEqual(@as(u32, 0), lay.boxes[0].gid);
    try testing.expect(present(&graph));
}

// spec: diagram/overview - Returns no layout when the graph has no real block
test "layout returns null with only synthesised endpoints" {
    var antenna = mkNode("ant", .analog, "");
    antenna.is_boundary = true;
    var nodes = [_]Node{antenna};
    var graph = Graph{ .nodes = &nodes, .edges = &.{} };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expect((try layout(arena.allocator(), &graph)) == null);
    try testing.expect(!present(&graph));
}

// spec: diagram/overview - Renders a clickable chip linking to the block's section card
test "renderStandaloneSvg emits a linked chip with its category tag" {
    var nodes = [_]Node{mkNode("STM32N6", .mcu, "stm32n6-core")};
    var graph = Graph{ .nodes = &nodes, .edges = &.{} };
    var aw: std.Io.Writer.Allocating = .init(testing.allocator);
    defer aw.deinit();
    const drawn = try renderStandaloneSvg(testing.allocator, &aw.writer, &graph);
    try testing.expect(drawn);
    const out = aw.written();
    try testing.expect(std.mem.indexOf(u8, out, "href=\"#sec-stm32n6-core\"") != null);
    try testing.expect(std.mem.indexOf(u8, out, ">STM32N6</text>") != null);
    try testing.expect(std.mem.indexOf(u8, out, ">mcu</text>") != null);
    try testing.expect(std.mem.indexOf(u8, out, "HUB") != null);
}
