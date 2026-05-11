const std = @import("std");
const review = @import("review.zig");

const PowerTree = review.PowerTree;
const PowerTreeNode = review.PowerTreeNode;

const Allocator = std.mem.Allocator;

// ── Layout constants ──────────────────────────────────────────────
const col_w: f64 = 200;
const col_gap: f64 = 60;
const node_h: f64 = 56;
const node_gap: f64 = 10;
const node_pad_x: f64 = 12;
const node_label_y: f64 = 22;
const node_voltage_y: f64 = 42;
const svg_pad_y: f64 = 12;
const svg_pad_x: f64 = 8;
const layer_title_h: f64 = 20;

/// Render the power-tree as an inline SVG. Nodes group by `layer` into
/// vertical columns (layer 0 leftmost). Edges (`upstream → rail`) draw as
/// straight lines from the right edge of an upstream node to the left edge
/// of a downstream node so reviewers can trace cascaded rails at a glance.
///
/// Emits nothing when `tree.nodes` is empty.
pub fn render(
    allocator: Allocator,
    tree: PowerTree,
    w: anytype,
) std.mem.Allocator.Error!void {
    if (tree.nodes.len == 0) return;

    // Group nodes by layer to compute placement.
    var max_layer: u32 = 0;
    for (tree.nodes) |n| {
        if (n.layer > max_layer) max_layer = n.layer;
    }
    const num_layers = max_layer + 1;

    // Per-layer node count for vertical placement.
    var counts = try allocator.alloc(u32, num_layers);
    defer allocator.free(counts);
    @memset(counts, 0);
    for (tree.nodes) |n| counts[n.layer] += 1;

    var max_count: u32 = 0;
    for (counts) |c| if (c > max_count) {
        max_count = c;
    };
    if (max_count == 0) max_count = 1;

    const svg_w = @as(f64, @floatFromInt(num_layers)) * col_w + @as(f64, @floatFromInt(num_layers - 1)) * col_gap + svg_pad_x * 2;
    const svg_h = layer_title_h + @as(f64, @floatFromInt(max_count)) * (node_h + node_gap) + svg_pad_y * 2;

    try w.writeAll("<div class=\"power-tree\">");
    try w.print(
        "<svg viewBox=\"0 0 {d:.0} {d:.0}\" class=\"power-tree-svg\" xmlns=\"http://www.w3.org/2000/svg\">",
        .{ svg_w, svg_h },
    );

    // Compute per-node (x, y) coordinates and stash for edge rendering.
    var positions = try allocator.alloc(struct { x: f64, y: f64 }, tree.nodes.len);
    defer allocator.free(positions);

    var row_ix = try allocator.alloc(u32, num_layers);
    defer allocator.free(row_ix);
    @memset(row_ix, 0);

    for (tree.nodes, 0..) |n, i| {
        const col_x = svg_pad_x + @as(f64, @floatFromInt(n.layer)) * (col_w + col_gap);
        const row_y = svg_pad_y + layer_title_h + @as(f64, @floatFromInt(row_ix[n.layer])) * (node_h + node_gap);
        positions[i] = .{ .x = col_x, .y = row_y };
        row_ix[n.layer] += 1;
    }

    // Build name → index lookup for edge endpoints.
    var name_idx: std.StringHashMapUnmanaged(usize) = .empty;
    defer name_idx.deinit(allocator);
    for (tree.nodes, 0..) |n, i| try name_idx.put(allocator, n.rail, i);

    // Edges first (so nodes draw on top).
    for (tree.edges) |e| {
        const from_idx = name_idx.get(e.from) orelse continue;
        const to_idx = name_idx.get(e.to) orelse continue;
        const fp = positions[from_idx];
        const tp = positions[to_idx];
        const x1 = fp.x + col_w;
        const y1 = fp.y + node_h / 2;
        const x2 = tp.x;
        const y2 = tp.y + node_h / 2;
        try w.print(
            "<path d=\"M {d:.1} {d:.1} C {d:.1} {d:.1} {d:.1} {d:.1} {d:.1} {d:.1}\" class=\"pt-edge\" fill=\"none\"/>",
            .{ x1, y1, x1 + col_gap / 2, y1, x2 - col_gap / 2, y2, x2, y2 },
        );
    }

    // Layer titles (only when a layer has content).
    for (counts, 0..) |c, layer| {
        if (c == 0) continue;
        const col_x = svg_pad_x + @as(f64, @floatFromInt(layer)) * (col_w + col_gap);
        try w.print(
            "<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"pt-layer-title\">Layer {d}</text>",
            .{ col_x + node_pad_x, svg_pad_y + layer_title_h - 4, layer },
        );
    }

    // Nodes.
    for (tree.nodes, 0..) |n, i| {
        const p = positions[i];
        try writeNode(w, n, p.x, p.y);
    }

    try w.writeAll("</svg></div>");
}

fn writeNode(w: anytype, n: PowerTreeNode, x: f64, y: f64) !void {
    try w.print(
        "<rect x=\"{d:.1}\" y=\"{d:.1}\" width=\"{d:.0}\" height=\"{d:.0}\" rx=\"8\" class=\"pt-node\"/>",
        .{ x, y, col_w, node_h },
    );
    try w.print(
        "<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"pt-node-label\">{s}</text>",
        .{ x + node_pad_x, y + node_label_y, n.rail },
    );
    if (n.nominal) |v| {
        try w.print(
            "<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"pt-node-voltage\">{d:.2}V",
            .{ x + node_pad_x, y + node_voltage_y, v },
        );
        if (n.source_ref_des.len > 0) {
            try w.print(" · {s}", .{n.source_ref_des});
        }
        try w.writeAll("</text>");
    } else if (n.source_ref_des.len > 0) {
        try w.print(
            "<text x=\"{d:.1}\" y=\"{d:.1}\" class=\"pt-node-voltage\">{s}</text>",
            .{ x + node_pad_x, y + node_voltage_y, n.source_ref_des },
        );
    }
}

// ── Tests ──────────────────────────────────────────────────────────────

// spec: render_power_tree_svg - Returns immediately on a block with zero declared rails
test "render emits nothing for empty tree" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);

    const tree: PowerTree = .{};
    try render(alloc, tree, buf.writer(alloc));
    try std.testing.expectEqual(@as(usize, 0), buf.items.len);
}

// spec: render_power_tree_svg - Renders a rounded-rect node per rail with name and nominal voltage
test "render emits one node per rail with label and voltage" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);

    const nodes = [_]PowerTreeNode{
        .{ .rail = "V3V3", .nominal = 3.3, .source_ref_des = "buck", .layer = 0 },
        .{ .rail = "V1V8", .nominal = 1.8, .source_ref_des = "ldo", .layer = 1 },
    };
    const edges = [_]review.PowerTreeEdge{
        .{ .from = "V3V3", .to = "V1V8" },
    };
    const tree: PowerTree = .{ .nodes = &nodes, .edges = &edges };
    try render(alloc, tree, buf.writer(alloc));

    const out = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, out, "V3V3") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "V1V8") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "3.30V") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "1.80V") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pt-node") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "pt-edge") != null);
}

// spec: render_power_tree_svg - Lays out one column per topological layer of the rail DAG
test "render groups nodes into one column per layer" {
    const alloc = std.testing.allocator;
    var buf: std.ArrayListUnmanaged(u8) = .empty;
    defer buf.deinit(alloc);

    const nodes = [_]PowerTreeNode{
        .{ .rail = "V5V", .nominal = 5.0, .layer = 0 },
        .{ .rail = "V3V3", .nominal = 3.3, .layer = 1 },
        .{ .rail = "V1V8", .nominal = 1.8, .layer = 2 },
    };
    const tree: PowerTree = .{ .nodes = &nodes };
    try render(alloc, tree, buf.writer(alloc));

    const out = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, out, "Layer 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Layer 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "Layer 2") != null);
}
